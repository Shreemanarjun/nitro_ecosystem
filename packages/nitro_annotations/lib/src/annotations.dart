// ── Platform capability markers ───────────────────────────────────────────────
// These interfaces restrict which NativeImpl subtypes may be passed to each
// @NitroModule field. Passing an incompatible impl is a compile-time error.

/// Accepted by [NitroModule.ios] and [NitroModule.macos].
/// Implemented by [SwiftImpl] and [CppImpl].
abstract interface class AppleNativeImpl {}

/// Accepted by [NitroModule.android].
/// Implemented by [KotlinImpl] and [CppImpl].
abstract interface class AndroidNativeImpl {}

/// Accepted by [NitroModule.windows].
/// Only implemented by [CppImpl] — Windows requires direct C++.
abstract interface class WindowsNativeImpl {}

/// Accepted by [NitroModule.linux].
/// Only implemented by [CppImpl] — Linux requires direct C++.
abstract interface class LinuxNativeImpl {}

/// Accepted by [NitroModule.web].
/// Only implemented by [WasmImpl] — Web requires WASM/JS interop (no dart:ffi).
abstract interface class WebNativeImpl {}

// ── NativeImpl sealed class hierarchy ─────────────────────────────────────────
// Each subclass implements only the platform capability markers where it is
// valid. Use the static constants — do not construct subclasses directly.
//
//   NativeImpl.swift  → ios, macos only        (AppleNativeImpl)
//   NativeImpl.kotlin → android only           (AndroidNativeImpl)
//   NativeImpl.cpp    → all native platforms   (Apple + Android + Windows + Linux)
//   NativeImpl.wasm   → web only               (WebNativeImpl)

/// Sealed base. Use [NativeImpl.swift], [NativeImpl.kotlin],
/// [NativeImpl.cpp], or [NativeImpl.wasm].
sealed class NativeImpl {
  const NativeImpl._();

  /// Swift + @_cdecl C bridge. Valid on [NitroModule.ios] and [NitroModule.macos].
  static const swift = SwiftImpl._();

  /// Kotlin + JNI bridge. Valid on [NitroModule.android] only.
  static const kotlin = KotlinImpl._();

  /// Direct C++ via CMake/FFI. Valid on all native platforms:
  /// iOS, Android, macOS, Windows, and Linux.
  static const cpp = CppImpl._();

  /// WASM/JS interop bridge. Valid on [NitroModule.web] only.
  /// dart:ffi is not available on web — use this for Web targets.
  static const wasm = WasmImpl._();
}

/// Swift + @_cdecl bridge. Valid on Apple platforms (iOS and macOS) only.
final class SwiftImpl extends NativeImpl implements AppleNativeImpl {
  const SwiftImpl._() : super._();
}

/// Kotlin + JNI bridge. Valid on Android only.
final class KotlinImpl extends NativeImpl implements AndroidNativeImpl {
  const KotlinImpl._() : super._();
}

/// Direct C++ implementation via CMake/FFI. Valid on all native platforms.
final class CppImpl extends NativeImpl
    implements AppleNativeImpl, AndroidNativeImpl, WindowsNativeImpl, LinuxNativeImpl {
  const CppImpl._() : super._();
}

/// WASM/JS interop bridge. Valid on Web only — dart:ffi is unavailable on web.
final class WasmImpl extends NativeImpl implements WebNativeImpl {
  const WasmImpl._() : super._();
}

class NitroModule {
  final AppleNativeImpl? ios; // which language implements on iOS (null = not targeting iOS)
  final AndroidNativeImpl? android; // which language implements on Android (null = not targeting Android)
  final AppleNativeImpl? macos; // which language implements on macOS (null = not targeting macOS); NativeImpl.swift or NativeImpl.cpp only
  final WindowsNativeImpl? windows; // which language implements on Windows (null = not targeting Windows); NativeImpl.cpp only
  final LinuxNativeImpl? linux; // which language implements on Linux (null = not targeting Linux); NativeImpl.cpp only
  final WebNativeImpl? web; // which language implements on Web (null = not targeting Web); NativeImpl.wasm only
  final String? cSymbolPrefix; // override C prefix (default: snake_case classname)
  final String? lib; // override .so/.dylib name (default: lib{classname})

  const NitroModule({
    this.ios,
    this.android,
    this.macos,
    this.windows,
    this.linux,
    this.web,
    this.cSymbolPrefix,
    this.lib,
  });
}

class HybridStruct {
  // Fields named here are Uint8List delivered as zero-copy raw pointer.
  // A Finalizer calls the native unlock symbol when the Dart object is GC'd.
  final List<String> zeroCopy;
  final bool packed; // no C struct padding, default false

  const HybridStruct({this.zeroCopy = const [], this.packed = false});
}

class HybridEnum {
  final int startValue; // first case value, default 0
  const HybridEnum({this.startValue = 0});
}

// Makes a method async. Return type must be Future<T>.
// Dispatched on NitroRuntime's background isolate pool.
const nitroAsync = NitroAsync();

class NitroAsync {
  const NitroAsync();
}

// Makes a getter a native stream via SendPort dispatch.
// Only valid on abstract getters returning Stream<T>.
class NitroStream {
  final Backpressure backpressure;
  const NitroStream({this.backpressure = Backpressure.dropLatest});
}

// Marks a Uint8List param as zero-copy (passed as raw ptr, callee must not retain).
const zeroCopy = ZeroCopy();

class ZeroCopy {
  const ZeroCopy();
}

enum Backpressure {
  dropLatest, // best for sensors/camera: stale frames are useless
  block, // block native thread until Dart consumes
  bufferDrop, // ring buffer; oldest item dropped when full
}

/// Marks a Dart class as a rich, binary-serialized record type for use as
/// method parameters, return types, or stream items in a @NitroModule.
///
/// Unlike @HybridStruct (flat C-memory layout), @HybridRecord classes:
/// - Support nested objects, [List]s, and nullable fields
/// - Are bridged as a compact binary protocol — one allocation per call
/// - Get `fromReader` / `writeFields` auto-generated in the `.g.dart` part file
///
/// **Use @HybridStruct** for hot-path data (frames, sensor readings).
/// **Use @HybridRecord** for infrequent, complex data (device lists, config).
///
/// ```dart
/// @HybridRecord
/// class CameraDevice {
///   final String id;
///   final List<Resolution> resolutions;
///   const CameraDevice({required this.id, required this.resolutions});
/// }
/// ```
class HybridRecord {
  const HybridRecord();
}

const hybridRecord = HybridRecord();
