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
  /// Allocates a native buffer and copies this list's content.
  /// If you need true zero-copy, you should use NativePointer.
  Pointer<Uint8> toPointer(Arena arena) {
    final ptr = arena<Uint8>(length);
    ptr.asTypedList(length).setAll(0, this);
    return ptr;
  }
}

extension NitroStringExtension on String {
  Pointer<Utf8> toPointer(Arena arena) {
    return this.toNativeUtf8(allocator: arena);
  }
}

extension NitroPointerExtension on Pointer<Utf8> {
  String toDartStringWithFree() {
    final str = this.toDartString();
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

  static final Finalizer<void Function()> _finalizer =
      Finalizer((nativeRelease) => nativeRelease());
}
