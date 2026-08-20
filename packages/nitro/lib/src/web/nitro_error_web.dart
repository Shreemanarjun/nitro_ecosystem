import 'dart:typed_data';

import '../hybrid_exception.dart';
import 'nitro_wasm_module.dart';

/// The C `NitroError` out-param struct read from WASM linear memory.
///
/// wasm32 layout (verified against an Emscripten build — 20 bytes):
/// ```
/// offset 0  : int8   hasError
/// offset 4  : uint32 name        (char*, strdup'd by the bridge)
/// offset 8  : uint32 message     (char*)
/// offset 12 : uint32 code        (char*, may be 0)
/// offset 16 : uint32 stackTrace  (char*, may be 0)
/// ```
/// The struct itself is Dart-allocated (module `malloc`); the string fields
/// are strdup'd by the C bridge and must be freed with the module's
/// `<lib>_nitro_free`.
final class WebNitroErrorSlot {
  static const int sizeInBytes = 20;

  final NitroWasmModule module;

  /// Heap offset of the struct — pass this where the C signature takes
  /// `NitroError*`.
  final int ptr;

  WebNitroErrorSlot._(this.module, this.ptr);

  /// Allocates a zeroed slot in [module]'s heap.
  factory WebNitroErrorSlot.alloc(NitroWasmModule module) {
    final ptr = module.malloc(sizeInBytes);
    module.writeBytes(ptr, Uint8List(sizeInBytes));
    return WebNitroErrorSlot._(module, ptr);
  }

  /// Frees the slot itself (NOT the string fields — [throwIfError] handles
  /// those when an error is present).
  void free() => module.free(ptr);

  /// Checks the slot after a bridge call. If an error is present: copies the
  /// string fields into Dart, frees them with the module's `nitro_free`,
  /// resets the slot for the next call, and throws a [HybridException].
  ///
  /// No-op (a single 20-byte read) when there is no error.
  void throwIfError() {
    final bytes = module.readBytes(ptr, sizeInBytes);
    if (bytes[0] == 0) return;
    final bd = ByteData.sublistView(bytes);
    final namePtr = bd.getUint32(4, Endian.little);
    final msgPtr = bd.getUint32(8, Endian.little);
    final codePtr = bd.getUint32(12, Endian.little);
    final stackPtr = bd.getUint32(16, Endian.little);

    final name = namePtr != 0 ? module.readCString(namePtr) : 'NativeException';
    final message = msgPtr != 0 ? module.readCString(msgPtr) : 'An unknown native exception occurred.';
    final code = codePtr != 0 ? module.readCString(codePtr) : null;
    final stack = stackPtr != 0 ? module.readCString(stackPtr) : null;

    module.nitroFree(namePtr);
    module.nitroFree(msgPtr);
    module.nitroFree(codePtr);
    module.nitroFree(stackPtr);
    module.writeBytes(ptr, Uint8List(sizeInBytes));

    throw HybridException(
      name: name,
      message: message,
      code: code,
      stackTrace: stack,
    );
  }

  /// Variant for per-call slots (`@nitroNativeAsync`): checks, then frees the
  /// slot itself whether or not an error was present.
  void throwIfErrorAndFree() {
    try {
      throwIfError();
    } finally {
      free();
    }
  }
}
