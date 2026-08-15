// Tests for NativeHandle — the raw-pointer wrapper used by @NitroOwned returns.
//
// The interesting surface is release(): generated code attaches a callback that
// frees native memory, and the documented contract is "safe to call multiple
// times". A second invocation would be a double free, so that is pinned here
// rather than left to the generated call sites to get right.
//
// Addresses are never dereferenced — only wrapped — so no allocation is needed.
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  group('NativeHandle', () {
    test('wraps a pointer and exposes its address', () {
      final h = NativeHandle<Void>(Pointer<Void>.fromAddress(0xDEAD));
      expect(h.address, 0xDEAD);
      expect(h.pointer.address, 0xDEAD);
    });

    test('fromAddress round-trips', () {
      final h = NativeHandle<Void>.fromAddress(0xBEEF);
      expect(h.address, 0xBEEF);
      expect(h.pointer, Pointer<Void>.fromAddress(0xBEEF));
    });

    test('a null pointer is representable (address 0)', () {
      final h = NativeHandle<Void>.fromAddress(0);
      expect(h.address, 0);
      expect(h.pointer, nullptr);
    });

    test('release() without a callback is a no-op — a borrowed handle', () {
      final h = NativeHandle<Void>.fromAddress(0x10);
      expect(h.release, returnsNormally);
    });

    test('release() invokes the callback once with the handle address', () {
      final calls = <int>[];
      final h = NativeHandle<Void>.fromAddress(0x1234)
        ..attachReleaseCallback(calls.add);

      h.release();
      expect(calls, [0x1234]);
    });

    // The double-free guard. Generated code may call release() explicitly while
    // a NativeFinalizer is also attached, so a second call must not re-free.
    test('release() is idempotent — the second call does not re-invoke', () {
      var count = 0;
      final h = NativeHandle<Void>.fromAddress(0x20)
        ..attachReleaseCallback((_) => count++);

      h.release();
      h.release();
      h.release();
      expect(count, 1, reason: 'a repeated release would be a double free');
    });

    test('attachReleaseCallback replaces a previously attached callback', () {
      final fired = <String>[];
      final h = NativeHandle<Void>.fromAddress(0x30)
        ..attachReleaseCallback((_) => fired.add('first'))
        ..attachReleaseCallback((_) => fired.add('second'));

      h.release();
      expect(fired, ['second']);
    });

    test('re-attaching after release arms the handle again', () {
      final fired = <String>[];
      final h = NativeHandle<Void>.fromAddress(0x40)
        ..attachReleaseCallback((_) => fired.add('a'));
      h.release();
      h.release(); // no-op

      h.attachReleaseCallback((_) => fired.add('b'));
      h.release();
      expect(fired, ['a', 'b']);
    });

    test('an exception from the callback still clears it (no re-entry)', () {
      var count = 0;
      final h = NativeHandle<Void>.fromAddress(0x50)
        ..attachReleaseCallback((_) {
          count++;
          throw StateError('native release failed');
        });

      expect(h.release, throwsA(isA<StateError>()));
      // The callback is cleared before it runs, so a retry cannot double-free.
      expect(h.release, returnsNormally);
      expect(count, 1);
    });

    test('toString shows the type parameter and hex address', () {
      final h = NativeHandle<Void>.fromAddress(0xABC);
      expect(h.toString(), 'NativeHandle<Void>(0xabc)');
    });

    test('distinct handles to the same address release independently', () {
      var a = 0;
      var b = 0;
      final h1 = NativeHandle<Void>.fromAddress(0x60)
        ..attachReleaseCallback((_) => a++);
      final h2 = NativeHandle<Void>.fromAddress(0x60)
        ..attachReleaseCallback((_) => b++);

      h1.release();
      expect(a, 1);
      expect(b, 0, reason: 'handles must not share release state');
      h2.release();
      expect(b, 1);
    });
  });
}
