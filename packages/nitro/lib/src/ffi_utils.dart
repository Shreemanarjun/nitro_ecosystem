import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

T withArena<T>(T Function(Arena arena) action) {
  return using(action);
}

extension NitroUint8ListExtension on Uint8List {
  Pointer<Uint8> toPointer(Arena arena) {
    final ptr = arena<Uint8>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroInt8ListExtension on Int8List {
  Pointer<Int8> toPointer(Arena arena) {
    final ptr = arena<Int8>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroInt16ListExtension on Int16List {
  Pointer<Int16> toPointer(Arena arena) {
    final ptr = arena<Int16>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroInt32ListExtension on Int32List {
  Pointer<Int32> toPointer(Arena arena) {
    final ptr = arena<Int32>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroUint16ListExtension on Uint16List {
  Pointer<Uint16> toPointer(Arena arena) {
    final ptr = arena<Uint16>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroUint32ListExtension on Uint32List {
  Pointer<Uint32> toPointer(Arena arena) {
    final ptr = arena<Uint32>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroFloat32ListExtension on Float32List {
  Pointer<Float> toPointer(Arena arena) {
    final ptr = arena<Float>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroFloat64ListExtension on Float64List {
  Pointer<Double> toPointer(Arena arena) {
    final ptr = arena<Double>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroStringExtension on String {
  Pointer<Utf8> toPointer(Arena arena) {
    return toNativeUtf8(allocator: arena);
  }
}

extension NitroPointerExtension on Pointer<Utf8> {
  String toDartStringWithFree() {
    if (address == 0) return '';
    final str = toDartString();
    malloc.free(this);
    return str;
  }
}

/// A wrapper for native memory owned by C/Swift/Kotlin, mapped directly into
/// a Dart typed list without copying.
///
/// A [Finalizer] calls [_nativeRelease] when the Dart object is GC'd (or call
/// [release] explicitly to return the buffer sooner).
///
/// Choose the subclass that matches the element type of the native buffer:
/// - [ZeroCopyBuffer]        — `uint8_t*`  → [Uint8List]
/// - [ZeroCopyInt8Buffer]    — `int8_t*`   → [Int8List]
/// - [ZeroCopyInt16Buffer]   — `int16_t*`  → [Int16List]
/// - [ZeroCopyUint16Buffer]  — `uint16_t*` → [Uint16List]
/// - [ZeroCopyInt32Buffer]   — `int32_t*`  → [Int32List]
/// - [ZeroCopyUint32Buffer]  — `uint32_t*` → [Uint32List]
/// - [ZeroCopyFloat32Buffer] — `float*`    → [Float32List]
/// - [ZeroCopyFloat64Buffer] — `double*`   → [Float64List]
/// - [ZeroCopyInt64Buffer]   — `int64_t*`  → [Int64List]
abstract class _ZeroCopyBufferBase {
  final void Function() _nativeRelease;
  bool _released = false;

  _ZeroCopyBufferBase(this._nativeRelease);

  /// Explicitly releases native memory before GC.
  void release() {
    if (!_released) {
      _released = true;
      _releaseFinalizerToken();
      _nativeRelease();
    }
  }

  void _releaseFinalizerToken();

  void _assertNotReleased() {
    if (_released) throw StateError('ZeroCopyBuffer already released');
  }
}

/// Zero-copy buffer backed by `uint8_t*` — maps to [Uint8List].
class ZeroCopyBuffer extends _ZeroCopyBufferBase {
  final Pointer<Uint8> ptr;
  final int length;

  ZeroCopyBuffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) {
      _finalizer.attach(this, nativeRelease, detach: this);
    }
  }

  /// Zero-copy [Uint8List] view of native memory.
  Uint8List get bytes {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);

  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}

/// Zero-copy buffer backed by `int8_t*` — maps to [Int8List].
class ZeroCopyInt8Buffer extends _ZeroCopyBufferBase {
  final Pointer<Int8> ptr;
  final int length;

  ZeroCopyInt8Buffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) _finalizer.attach(this, nativeRelease, detach: this);
  }

  Int8List get values {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);
  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}

/// Zero-copy buffer backed by `int16_t*` — maps to [Int16List].
class ZeroCopyInt16Buffer extends _ZeroCopyBufferBase {
  final Pointer<Int16> ptr;
  final int length;

  ZeroCopyInt16Buffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) _finalizer.attach(this, nativeRelease, detach: this);
  }

  Int16List get values {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);
  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}

/// Zero-copy buffer backed by `uint16_t*` — maps to [Uint16List].
class ZeroCopyUint16Buffer extends _ZeroCopyBufferBase {
  final Pointer<Uint16> ptr;
  final int length;

  ZeroCopyUint16Buffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) _finalizer.attach(this, nativeRelease, detach: this);
  }

  Uint16List get values {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);
  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}

/// Zero-copy buffer backed by `int32_t*` — maps to [Int32List].
class ZeroCopyInt32Buffer extends _ZeroCopyBufferBase {
  final Pointer<Int32> ptr;
  final int length;

  ZeroCopyInt32Buffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) _finalizer.attach(this, nativeRelease, detach: this);
  }

  Int32List get values {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);
  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}

/// Zero-copy buffer backed by `uint32_t*` — maps to [Uint32List].
class ZeroCopyUint32Buffer extends _ZeroCopyBufferBase {
  final Pointer<Uint32> ptr;
  final int length;

  ZeroCopyUint32Buffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) _finalizer.attach(this, nativeRelease, detach: this);
  }

  Uint32List get values {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);
  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}

/// Zero-copy buffer backed by `float*` — maps to [Float32List].
///
/// Typical use: camera depth maps, audio PCM samples, ML model inputs/outputs.
class ZeroCopyFloat32Buffer extends _ZeroCopyBufferBase {
  final Pointer<Float> ptr;
  final int length;

  ZeroCopyFloat32Buffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) _finalizer.attach(this, nativeRelease, detach: this);
  }

  /// Zero-copy [Float32List] view of native memory.
  Float32List get floats {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);
  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}

/// Zero-copy buffer backed by `double*` — maps to [Float64List].
class ZeroCopyFloat64Buffer extends _ZeroCopyBufferBase {
  final Pointer<Double> ptr;
  final int length;

  ZeroCopyFloat64Buffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) _finalizer.attach(this, nativeRelease, detach: this);
  }

  Float64List get doubles {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);
  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}

/// Zero-copy buffer backed by `int64_t*` — maps to [Int64List].
class ZeroCopyInt64Buffer extends _ZeroCopyBufferBase {
  final Pointer<Int64> ptr;
  final int length;

  ZeroCopyInt64Buffer(this.ptr, this.length, void Function() nativeRelease) : super(nativeRelease) {
    if (ptr != nullptr) _finalizer.attach(this, nativeRelease, detach: this);
  }

  Int64List get values {
    _assertNotReleased();
    return ptr.asTypedList(length);
  }

  @override
  void _releaseFinalizerToken() => _finalizer.detach(this);
  static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
}
