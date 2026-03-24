import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

T withArena<T>(T Function(Arena arena) action) {
  using(action);
  // wait, the 'using' from package:ffi handles arena lifecycle.
  // Actually, 'withArena' is a common helper.
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
    final str = toDartString();
    malloc.free(this);
    return str;
  }
}

/// A wrapper for memory owned by the Native Side that is mapped directly into
/// a Dart Uint8List without copying (zero-copy buffer).
/// The memory is automatically released by a Finalizer when this object is GC'd.
class ZeroCopyBuffer {
  final Pointer<Uint8> ptr;
  final int length;
  final void Function() _nativeRelease;
  bool _released = false;

  ZeroCopyBuffer(this.ptr, this.length, this._nativeRelease) {
    if (ptr != nullptr) {
      _finalizer.attach(this, _nativeRelease, detach: this);
    }
  }

  /// The zero-copy backed memory map
  Uint8List get bytes {
    if (_released) throw StateError('ZeroCopyBuffer already released');
    return ptr.asTypedList(length);
  }

  /// Explicitly releases the hardware buffer memory before Garbage Collection
  void release() {
    if (!_released) {
      _released = true;
      _finalizer.detach(this);
      _nativeRelease();
    }
  }

  static final Finalizer<void Function()> _finalizer = Finalizer(
    (nativeRelease) => nativeRelease(),
  );
}
