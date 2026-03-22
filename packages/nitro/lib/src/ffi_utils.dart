import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// Arena allocator scope for synchronous FFI calls.
T withArena<T>(T Function(Arena arena) body) {
  final arena = Arena();
  try {
    return body(arena);
  } finally {
    arena.releaseAll();
  }
}

extension StringToNative on String {
  /// Converts a Dart string to a native UTF-8 string.
  Pointer<Utf8> toNativeUtf8({Allocator allocator = malloc}) {
    // ffi: ^2.1.0's toNativeUtf8 is usually an extension on String but needs allocation.
    // It's actually provided by package:ffi.
    return (this as dynamic).toNativeUtf8(allocator: allocator);
  }
}

extension NativeToString on Pointer<Utf8> {
  /// Converts a native UTF-8 string to a Dart string.
  String toDartString() {
    return (this as dynamic).toDartString();
  }
}

class ZeroCopyBuffer {
  final Pointer<Uint8> ptr;
  final int length;
  
  ZeroCopyBuffer(this.ptr, this.length);

  // Uint8List get bytes => ptr.asTypedList(length);
  // Note: asTypedList is a method on Pointer<Uint8>.
  
  void release() {
    // explicit early release before GC
  }
}
