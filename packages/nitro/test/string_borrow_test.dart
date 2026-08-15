// Tests for the two string-decode contracts on Pointer<Utf8>.
//
//   toDartStringBorrowed()  — sync bridge returns. Native lends a reusable
//                             per-thread buffer; Dart decodes and frees nothing.
//   toDartStringFreedBy()   — @nitroAsync / owned returns. Dart releases the
//                             buffer through the module's own free.
//
// Getting this pair wrong is expensive and silent: dropping the free leaks on
// every call (an iOS RSS soak caught ~48 MB / 20k calls), and freeing a
// borrowed buffer aborts the allocator. Neither had direct coverage.
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

/// Allocates a NUL-terminated UTF-8 buffer the caller owns.
Pointer<Utf8> _alloc(List<int> bytes) {
  final p = calloc<Uint8>(bytes.length + 1);
  p.asTypedList(bytes.length).setAll(0, bytes);
  p[bytes.length] = 0;
  return p.cast<Utf8>();
}

Pointer<Utf8> _allocStr(String s) => _alloc(utf8.encode(s));

void main() {
  group('toDartStringBorrowed', () {
    test('decodes ASCII', () {
      final p = _allocStr('hello');
      addTearDown(() => calloc.free(p));
      expect(p.toDartStringBorrowed(), 'hello');
    });

    test('decodes multi-byte UTF-8', () {
      const s = 'Hello ⚡ World —日本語';
      final p = _allocStr(s);
      addTearDown(() => calloc.free(p));
      expect(p.toDartStringBorrowed(), s);
    });

    test('decodes an empty string', () {
      final p = _allocStr('');
      addTearDown(() => calloc.free(p));
      expect(p.toDartStringBorrowed(), '');
    });

    test('a null pointer decodes to empty, not a crash', () {
      expect(Pointer<Utf8>.fromAddress(0).toDartStringBorrowed(), '');
    });

    // The defining property: borrowed means the caller still owns the buffer.
    // If this ever started freeing, the tear-down free below would be a double
    // free and the reread would return garbage.
    test('does not release the buffer — it stays readable and ours to free', () {
      final p = _allocStr('borrowed');
      addTearDown(() => calloc.free(p));

      expect(p.toDartStringBorrowed(), 'borrowed');
      // Bytes are still intact after decoding.
      final raw = p.cast<Uint8>().asTypedList(8);
      expect(raw, utf8.encode('borrowed'));
      // And decoding again yields the same value.
      expect(p.toDartStringBorrowed(), 'borrowed');
    });

    test('reflects a native buffer that was overwritten between calls', () {
      // Mirrors the real pattern: one per-thread slot reused across calls.
      final p = calloc<Uint8>(16);
      addTearDown(() => calloc.free(p));

      void write(String s) {
        final b = utf8.encode(s);
        p.asTypedList(b.length).setAll(0, b);
        p[b.length] = 0;
      }

      write('first');
      expect(p.cast<Utf8>().toDartStringBorrowed(), 'first');
      write('second');
      expect(p.cast<Utf8>().toDartStringBorrowed(), 'second');
    });

    // Bridge strings are raw data, not text streams, so a leading BOM is
    // content and must survive the decode.
    test('preserves a leading U+FEFF (BOM) instead of stripping it', () {
      final p = _alloc([0xEF, 0xBB, 0xBF, ...utf8.encode('data')]);
      addTearDown(() => calloc.free(p));
      expect(p.toDartStringBorrowed(), '﻿data');
    });

    test('preserves repeated leading BOMs', () {
      final p = _alloc([
        0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, //
        ...utf8.encode('x'),
      ]);
      addTearDown(() => calloc.free(p));
      expect(p.toDartStringBorrowed(), '﻿﻿x');
    });

    test('tolerates malformed UTF-8 rather than throwing', () {
      // Bridge payloads are bytes; a lone continuation byte must not blow up.
      final p = _alloc([0x41, 0x80, 0x42]);
      addTearDown(() => calloc.free(p));
      expect(p.toDartStringBorrowed, returnsNormally);
    });
  });

  group('toDartStringFreedBy', () {
    test('decodes and then releases through the supplied free', () {
      final p = _allocStr('owned');
      final freed = <int>[];

      final s = p.toDartStringFreedBy((ptr) {
        freed.add(ptr.address);
        calloc.free(ptr);
      });

      expect(s, 'owned');
      expect(freed, [p.address], reason: 'must release exactly the buffer given');
    });

    test('a null pointer decodes to empty without calling free', () {
      var calls = 0;
      final s = Pointer<Utf8>.fromAddress(0).toDartStringFreedBy((_) => calls++);
      expect(s, '');
      expect(calls, 0, reason: 'freeing a null pointer would be a bug');
    });

    test('preserves a leading BOM, same as the borrowed path', () {
      final p = _alloc([0xEF, 0xBB, 0xBF, ...utf8.encode('data')]);
      expect(p.toDartStringFreedBy(calloc.free), '﻿data');
    });

    // The two paths must agree on content and differ only in ownership.
    test('borrowed and freed decode identically', () {
      const samples = ['', 'ascii', 'emoji ⚡', '﻿bom', '日本語'];
      for (final s in samples) {
        final a = _allocStr(s);
        final b = _allocStr(s);
        final borrowed = a.toDartStringBorrowed();
        final owned = b.toDartStringFreedBy(calloc.free);
        expect(borrowed, owned, reason: 'decode differs for "$s"');
        expect(borrowed, s);
        calloc.free(a);
      }
    });
  });
}
