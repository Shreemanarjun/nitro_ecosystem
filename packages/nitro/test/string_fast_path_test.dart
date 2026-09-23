// The ASCII encode fast path (toNitroUtf8) and the word-at-a-time length scan
// behind toDartStringBorrowed / toDartStringFreedBy must be byte-for-byte what
// the plain package:ffi paths produced.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:nitro/src/ffi_utils.dart';
import 'package:test/test.dart';

Uint8List bytesOf(Pointer<Utf8> p) => Uint8List.fromList(p.cast<Uint8>().asTypedList(p.length + 1));

void main() {
  const samples = [
    '',
    'a',
    'Hello, Nitro!',
    'exactly8',
    '\u007f edge of ASCII',
    'héllo wörld',
    'mixed ascii then ü at the end',
    '日本語',
    '🚀 emoji',
    '﻿leading BOM',
    'lone \uD800 surrogate',
  ];

  group('toNitroUtf8', () {
    for (final s in [...samples, 'x' * 300]) {
      test('matches toNativeUtf8 for ${s.length > 20 ? '${s.substring(0, 20)}…' : s}', () {
        final fast = s.toNitroUtf8(allocator: malloc);
        final ref = s.toNativeUtf8(allocator: malloc);
        expect(bytesOf(fast), bytesOf(ref));
        malloc
          ..free(fast)
          ..free(ref);
      });
    }

    test('works with an Arena and falls back inside it', () {
      using((arena) {
        expect(bytesOf('ascii'.toNitroUtf8(allocator: arena)), bytesOf('ascii'.toNativeUtf8(allocator: arena)));
        expect(bytesOf('ünï'.toNitroUtf8(allocator: arena)), bytesOf('ünï'.toNativeUtf8(allocator: arena)));
      });
    });
  });

  group('NUL scan', () {
    test('every length 0..300 at every 8-byte alignment', () {
      for (var off = 0; off < 8; off++) {
        for (var len = 0; len <= 300; len++) {
          final base = calloc<Uint8>(len + 16);
          final p = Pointer<Uint8>.fromAddress(base.address + off);
          // Bytes 0x01..0x7f and 0x80..0xff stress the zero-byte bit trick.
          for (var i = 0; i < len; i++) {
            p[i] = i.isEven ? 0x01 + (i % 0x7f) : 0x80 | (i & 0x7f);
          }
          p[len] = 0;
          p[len + 1] = 0x41; // bytes after the NUL must not count
          // Byte 0 is never 0xEF, so no leading BOM: the plain decoder is the reference.
          final expected = const Utf8Decoder(allowMalformed: true).convert(Uint8List.fromList(p.asTypedList(len)));
          expect(p.cast<Utf8>().toDartStringBorrowed(), expected, reason: 'len=$len off=$off');
          calloc.free(base);
        }
      }
    });

    test('borrowed and freed decodes round-trip every sample', () {
      for (final s in samples) {
        final p = s.toNativeUtf8(allocator: malloc);
        expect(p.toDartStringBorrowed(), s == 'lone \uD800 surrogate' ? 'lone � surrogate' : s);
        expect(p.toDartStringFreedBy(malloc.free), s == 'lone \uD800 surrogate' ? 'lone � surrogate' : s);
      }
    });
  });
}
