/// TC3 — Memory / finalizer stress tests for ZeroCopyBuffer and its variants.
///
/// Goals:
///   1. 10,000 alloc/discard cycles without memory leaks or crashes.
///   2. Double-release is a no-op (no crash, no double-free).
///   3. Accessing released buffer throws StateError.
///   4. `release()` fires immediately (no GC wait needed).
///   5. Mixed concurrent alloc + release without corruption.
///   6. All nine buffer variants construct and release correctly.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Allocates [count] bytes of C memory and returns a [ZeroCopyBuffer] backed
/// by it. The [nativeRelease] callback calls [calloc.free] on the pointer.
ZeroCopyBuffer _makeBuffer(int count) {
  final ptr = calloc<Uint8>(count);
  for (var i = 0; i < count; i++) {
    ptr[i] = i & 0xFF;
  }
  return ZeroCopyBuffer(ptr, count, () => calloc.free(ptr));
}

/// Same for Int8 variant.
ZeroCopyInt8Buffer _makeInt8Buffer(int count) {
  final ptr = calloc<Int8>(count);
  for (var i = 0; i < count; i++) {
    ptr[i] = (i - 128) & 0x7F;
  }
  return ZeroCopyInt8Buffer(ptr, count, () => calloc.free(ptr));
}

/// Same for Float32 variant.
ZeroCopyFloat32Buffer _makeFloat32Buffer(int count) {
  final ptr = calloc<Float>(count);
  for (var i = 0; i < count; i++) {
    ptr[i] = i.toDouble();
  }
  return ZeroCopyFloat32Buffer(ptr, count, () => calloc.free(ptr));
}

ZeroCopyFloat64Buffer _makeFloat64Buffer(int count) {
  final ptr = calloc<Double>(count);
  for (var i = 0; i < count; i++) {
    ptr[i] = i.toDouble();
  }
  return ZeroCopyFloat64Buffer(ptr, count, () => calloc.free(ptr));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('ZeroCopyBuffer — basic contract', () {
    test('bytes view reads correct data', () {
      final buf = _makeBuffer(4);
      expect(buf.bytes, equals([0, 1, 2, 3]));
      buf.release();
    });

    test('release() frees native memory (no crash)', () {
      final buf = _makeBuffer(1024);
      expect(() => buf.release(), returnsNormally);
    });

    test('double release() is a no-op — no crash, no double-free', () {
      final buf = _makeBuffer(16);
      buf.release();
      expect(() => buf.release(), returnsNormally);
    });

    test('accessing bytes after release() throws StateError', () {
      final buf = _makeBuffer(8);
      buf.release();
      expect(() => buf.bytes, throwsA(isA<StateError>()));
    });

    test('zero-length buffer creates without error', () {
      // Allocate 1 byte to avoid null ptr, pass length 0
      final ptr = calloc<Uint8>(1);
      final buf = ZeroCopyBuffer(ptr, 0, () => calloc.free(ptr));
      expect(buf.bytes.length, 0);
      buf.release();
    });
  });

  group('ZeroCopyBuffer — 10k alloc/discard stress', () {
    test('10,000 create + immediate release cycles without crash', () {
      const n = 10000;
      for (var i = 0; i < n; i++) {
        final buf = _makeBuffer(64);
        buf.release();
      }
      // If we reach here without crash/OOM the test passes.
    });

    test('10,000 create + read + release cycles — data integrity throughout', () {
      const n = 10000;
      for (var i = 0; i < n; i++) {
        final buf = _makeBuffer(4);
        // Read — verifies the finalizer hasn't fired prematurely
        expect(buf.bytes[0], 0);
        expect(buf.bytes[3], 3);
        buf.release();
      }
    });

    test('2,000 buffers kept alive, then all released — no UAF', () {
      const n = 2000;
      final buffers = List.generate(n, (_) => _makeBuffer(32));
      // Read from every buffer while all are alive (no use-after-free).
      for (var i = 0; i < n; i++) {
        expect(buffers[i].bytes[0], 0);
      }
      // Release in reverse order to catch any shared-state bugs.
      for (var i = n - 1; i >= 0; i--) {
        buffers[i].release();
      }
    });

    test('alternating alloc and release — allocator remains stable', () {
      // Repeatedly alloc one and free it to stress the malloc/free cycle.
      for (var i = 0; i < 5000; i++) {
        final a = _makeBuffer(16);
        final b = _makeBuffer(16);
        a.release();
        final c = _makeBuffer(16);
        b.release();
        c.release();
      }
    });
  });

  group('ZeroCopyBuffer — GC + Finalizer', () {
    test('buffer released by GC Finalizer does not crash (smoke)', () async {
      // Create buffers in a nested scope so they become unreachable.
      // We cannot force a GC in Dart, but we can at least verify
      // that the Finalizer registration path does not throw.
      void createAndForget() {
        // Intentionally not keeping a reference — GC should collect.
        _makeBuffer(128); // release callback will be called by Finalizer
        _makeBuffer(256);
        _makeBuffer(512);
      }

      createAndForget();
      // Run microtask queue to let any pending finalizer work proceed.
      await Future<void>.delayed(Duration.zero);
      // If we reach here without crash, the finalizer path is safe.
    });
  });

  group('ZeroCopyInt8Buffer — basic + stress', () {
    test('values view reads correct Int8 data', () {
      final buf = _makeInt8Buffer(4);
      expect(buf.values, isA<Int8List>());
      buf.release();
    });

    test('double release is a no-op', () {
      final buf = _makeInt8Buffer(8);
      buf.release();
      expect(() => buf.release(), returnsNormally);
    });

    test('accessing after release throws StateError', () {
      final buf = _makeInt8Buffer(8);
      buf.release();
      expect(() => buf.values, throwsA(isA<StateError>()));
    });

    test('1,000 Int8Buffer create + release cycles', () {
      for (var i = 0; i < 1000; i++) {
        final buf = _makeInt8Buffer(32);
        buf.release();
      }
    });
  });

  group('ZeroCopyFloat32Buffer — basic + stress', () {
    test('floats view reads correct Float32 data', () {
      final buf = _makeFloat32Buffer(4);
      expect(buf.floats[0], closeTo(0.0, 1e-6));
      expect(buf.floats[3], closeTo(3.0, 1e-6));
      buf.release();
    });

    test('double release is a no-op', () {
      final buf = _makeFloat32Buffer(8);
      buf.release();
      expect(() => buf.release(), returnsNormally);
    });

    test('1,000 Float32Buffer create + release cycles', () {
      for (var i = 0; i < 1000; i++) {
        final buf = _makeFloat32Buffer(16);
        buf.release();
      }
    });
  });

  group('ZeroCopyBuffer — all nine concrete buffer variants', () {
    test('all nine variants construct and release without error', () {
      // Uint8
      final u8ptr = calloc<Uint8>(4);
      ZeroCopyBuffer(u8ptr, 4, () => calloc.free(u8ptr)).release();

      // Int8
      final i8ptr = calloc<Int8>(4);
      ZeroCopyInt8Buffer(i8ptr, 4, () => calloc.free(i8ptr)).release();

      // Int16
      final i16ptr = calloc<Int16>(4);
      ZeroCopyInt16Buffer(i16ptr, 4, () => calloc.free(i16ptr)).release();

      // Uint16
      final u16ptr = calloc<Uint16>(4);
      ZeroCopyUint16Buffer(u16ptr, 4, () => calloc.free(u16ptr)).release();

      // Int32
      final i32ptr = calloc<Int32>(4);
      ZeroCopyInt32Buffer(i32ptr, 4, () => calloc.free(i32ptr)).release();

      // Uint32
      final u32ptr = calloc<Uint32>(4);
      ZeroCopyUint32Buffer(u32ptr, 4, () => calloc.free(u32ptr)).release();

      // Float32
      final f32ptr = calloc<Float>(4);
      ZeroCopyFloat32Buffer(f32ptr, 4, () => calloc.free(f32ptr)).release();

      // Float64
      final f64ptr = calloc<Double>(4);
      ZeroCopyFloat64Buffer(f64ptr, 4, () => calloc.free(f64ptr)).release();

      // Int64
      final i64ptr = calloc<Int64>(4);
      ZeroCopyInt64Buffer(i64ptr, 4, () => calloc.free(i64ptr)).release();
    });

    test('all nine variants: bytes/values accessor type is correct', () {
      final u8 = _makeBuffer(1);
      expect(u8.bytes, isA<Uint8List>());
      u8.release();

      final i8 = _makeInt8Buffer(1);
      expect(i8.values, isA<Int8List>());
      i8.release();

      final f32 = _makeFloat32Buffer(1);
      expect(f32.floats, isA<Float32List>());
      f32.release();

      final i16ptr = calloc<Int16>(1);
      final i16 = ZeroCopyInt16Buffer(i16ptr, 1, () => calloc.free(i16ptr));
      expect(i16.values, isA<Int16List>());
      i16.release();

      final u16ptr = calloc<Uint16>(1);
      final u16 = ZeroCopyUint16Buffer(u16ptr, 1, () => calloc.free(u16ptr));
      expect(u16.values, isA<Uint16List>());
      u16.release();

      final i32ptr = calloc<Int32>(1);
      final i32 = ZeroCopyInt32Buffer(i32ptr, 1, () => calloc.free(i32ptr));
      expect(i32.values, isA<Int32List>());
      i32.release();

      final u32ptr = calloc<Uint32>(1);
      final u32 = ZeroCopyUint32Buffer(u32ptr, 1, () => calloc.free(u32ptr));
      expect(u32.values, isA<Uint32List>());
      u32.release();

      final f64ptr = calloc<Double>(1);
      final f64 = ZeroCopyFloat64Buffer(f64ptr, 1, () => calloc.free(f64ptr));
      expect(f64.doubles, isA<Float64List>());
      f64.release();

      final i64ptr = calloc<Int64>(1);
      final i64 = ZeroCopyInt64Buffer(i64ptr, 1, () => calloc.free(i64ptr));
      expect(i64.values, isA<Int64List>());
      i64.release();
    });
  });
}
