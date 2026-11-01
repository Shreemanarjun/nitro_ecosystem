
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  group('zero-copy registry', () {
    test('a NitroBuffer view resolves to its native pointer; a heap list does not', () {
      final buf = NitroBuffer(1024);
      try {
        expect(nitroZeroCopyPtr(buf.bytes), buf.pointer.cast<Void>());
        expect(nitroZeroCopyPtr(Uint8List(1024)), isNull);
      } finally {
        buf.dispose();
      }
    });

    test('identity-keyed: a sublist / copy / second view of a registered view is NOT registered', () {
      final buf = NitroBuffer(64);
      try {
        expect(nitroZeroCopyPtr(buf.bytes.sublist(0, 16)), isNull);
        expect(nitroZeroCopyPtr(Uint8List.fromList(buf.bytes)), isNull);
        expect(nitroZeroCopyPtr(Uint8List.sublistView(buf.bytes, 0, 16)), isNull);
      } finally {
        buf.dispose();
      }
    });

    test('view(n) is registered to the base pointer with the requested length', () {
      final buf = NitroBuffer(256);
      try {
        final v = buf.view(100);
        expect(v.length, 100);
        expect(nitroZeroCopyPtr(v), buf.pointer.cast<Void>());
        expect(() => buf.view(257), throwsRangeError);
      } finally {
        buf.dispose();
      }
    });

    test('register / unregister an arbitrary native view', () {
      final p = malloc<Uint8>(8);
      try {
        final v = nitroRegisterZeroCopyView(p.asTypedList(8), p.cast());
        expect(nitroZeroCopyPtr(v), p.cast<Void>());
        nitroUnregisterZeroCopyView(v);
        expect(nitroZeroCopyPtr(v), isNull);
      } finally {
        malloc.free(p);
      }
    });
  });

  group('NitroBuffer', () {
    test('bytes is writable, native-backed, and the same object every call', () {
      final buf = NitroBuffer(16);
      try {
        buf.bytes[3] = 42;
        expect(buf.pointer[3], 42, reason: 'the write landed in native memory');
        expect(identical(buf.bytes, buf.bytes), isTrue);
        expect(buf.capacity, 16);
      } finally {
        buf.dispose();
      }
    });

    test('ensureCapacity grows + preserves + re-registers; no-op when already large enough', () {
      final buf = NitroBuffer(4);
      try {
        buf.bytes.setAll(0, [1, 2, 3, 4]);
        final old = buf.bytes;
        buf.ensureCapacity(2);
        expect(identical(buf.bytes, old), isTrue, reason: 'no-op grow keeps the view');
        buf.ensureCapacity(1024);
        expect(buf.capacity, 1024);
        expect(buf.bytes.sublist(0, 4), [1, 2, 3, 4]);
        expect(nitroZeroCopyPtr(buf.bytes), buf.pointer.cast<Void>());
        expect(nitroZeroCopyPtr(old), isNull, reason: 'the stale view is unregistered');
      } finally {
        buf.dispose();
      }
    });

    test('dispose frees, unregisters, is idempotent; later use throws', () {
      final buf = NitroBuffer(8);
      final v = buf.bytes;
      buf.dispose();
      buf.dispose();
      expect(buf.isDisposed, isTrue);
      expect(nitroZeroCopyPtr(v), isNull);
      expect(() => buf.bytes, throwsStateError);
      expect(() => buf.view(1), throwsStateError);
      expect(() => buf.pointer, throwsStateError);
    });
  });
}
