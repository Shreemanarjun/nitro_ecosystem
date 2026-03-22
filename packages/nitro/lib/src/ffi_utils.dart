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
