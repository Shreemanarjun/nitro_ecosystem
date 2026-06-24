// ── Per-platform sealed types ─────────────────────────────────────────────────
// Each sealed class exposes only the NativeImpl constants that are valid for
// that platform. Sealed: external code cannot add new subtypes, so the set of
// valid implementations is closed and known at compile time.
//
// Recommended (explicit per-platform syntax):
//   @NitroModule(
//     ios:     AppleNativeImpl.swift,       // or .cpp
//     macos:   AppleNativeImpl.cpp,
//     android: AndroidNativeImpl.kotlin,    // or .cpp
//     windows: WindowsNativeImpl.cpp,
//     linux:   LinuxNativeImpl.cpp,
//     web:     WebNativeImpl.wasm,
//   )
//
// Backward-compatible shorthand (both forms produce identical const objects):
//   @NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)

/// Accepted by [NitroModule.ios] and [NitroModule.macos].
///
/// Valid constants:
/// - [AppleNativeImpl.swift] — Swift + @_cdecl C bridge
/// - [AppleNativeImpl.cpp]   — Direct C++ via CMake/FFI
sealed class AppleNativeImpl {
  /// Swift + @_cdecl C bridge. Valid on iOS and macOS.
  static const AppleNativeImpl swift = SwiftImpl._();

  /// Direct C++ via CMake/FFI. Valid on iOS and macOS.
  static const AppleNativeImpl cpp = CppImpl._();
}

/// Accepted by [NitroModule.android].
///
/// Valid constants:
/// - [AndroidNativeImpl.kotlin] — Kotlin + JNI bridge
/// - [AndroidNativeImpl.cpp]    — Direct C++ via CMake/FFI (bypasses JNI)
sealed class AndroidNativeImpl {
  /// Kotlin + JNI bridge. Valid on Android only.
  static const AndroidNativeImpl kotlin = KotlinImpl._();

  /// Direct C++ via CMake/FFI. Valid on Android (bypasses JNI overhead).
  static const AndroidNativeImpl cpp = CppImpl._();
}

/// Accepted by [NitroModule.windows].
///
/// Valid constant:
/// - [WindowsNativeImpl.cpp] — Direct C++ via CMake/MSVC (only option)
sealed class WindowsNativeImpl {
  /// Direct C++ via CMake/MSVC. The only valid implementation for Windows.
  static const WindowsNativeImpl cpp = CppImpl._();
}

/// Accepted by [NitroModule.linux].
///
/// Valid constant:
/// - [LinuxNativeImpl.cpp] — Direct C++ via CMake/GCC/Clang (only option)
sealed class LinuxNativeImpl {
  /// Direct C++ via CMake/GCC/Clang. The only valid implementation for Linux.
  static const LinuxNativeImpl cpp = CppImpl._();
}

/// Accepted by [NitroModule.web].
///
/// Valid constant:
/// - [WebNativeImpl.wasm] — WASM/JS interop bridge (dart:ffi unavailable on web)
sealed class WebNativeImpl {
  /// WASM/JS interop bridge. The only valid implementation for Web.
  static const WebNativeImpl wasm = WasmImpl._();
}

// ── NativeImpl sealed class hierarchy ─────────────────────────────────────────
// Backward-compatible shorthand. All NativeImpl.* constants are canonically
// identical to their per-platform equivalents:
//
//   NativeImpl.swift  ≡ AppleNativeImpl.swift
//   NativeImpl.kotlin ≡ AndroidNativeImpl.kotlin
//   NativeImpl.cpp    ≡ AppleNativeImpl.cpp ≡ AndroidNativeImpl.cpp
//                       ≡ WindowsNativeImpl.cpp ≡ LinuxNativeImpl.cpp
//   NativeImpl.wasm   ≡ WebNativeImpl.wasm

/// Backward-compatible shorthand namespace.
/// Prefer the per-platform constants ([AppleNativeImpl], [AndroidNativeImpl],
/// [WindowsNativeImpl], [LinuxNativeImpl], [WebNativeImpl]) for clarity.
sealed class NativeImpl {
  const NativeImpl._();

  /// Swift + @_cdecl C bridge. Valid on [NitroModule.ios] and [NitroModule.macos].
  /// Equivalent to [AppleNativeImpl.swift].
  static const swift = SwiftImpl._();

  /// Kotlin + JNI bridge. Valid on [NitroModule.android] only.
  /// Equivalent to [AndroidNativeImpl.kotlin].
  static const kotlin = KotlinImpl._();

  /// Direct C++ via CMake/FFI. Valid on all native platforms
  /// (iOS, Android, macOS, Windows, Linux).
  /// Equivalent to [AppleNativeImpl.cpp], [AndroidNativeImpl.cpp],
  /// [WindowsNativeImpl.cpp], [LinuxNativeImpl.cpp].
  static const cpp = CppImpl._();

  /// WASM/JS interop bridge. Valid on [NitroModule.web] only.
  /// dart:ffi is unavailable on web — use this for Web targets.
  /// Equivalent to [WebNativeImpl.wasm].
  static const wasm = WasmImpl._();

  /// Maps an analyzer-reported Dart type name to the corresponding [NativeImpl]
  /// constant. Used by codegen (`SpecExtractor`) and any tooling that needs to
  /// reconstruct a [NativeImpl] from a `DartObject` produced by the analyzer.
  ///
  /// Handles the **unambiguous** cases:
  /// - Concrete impl class names: `SwiftImpl`, `KotlinImpl`, `CppImpl`, `WasmImpl`.
  /// - Sealed marker names with a single valid impl: `WindowsNativeImpl`,
  ///   `LinuxNativeImpl`, `WebNativeImpl`.
  ///
  /// The sealed markers `AppleNativeImpl` and `AndroidNativeImpl` accept both
  /// a language-specific impl and `CppImpl`, so they require analyzer-level
  /// disambiguation (supertype inspection) and are intentionally **not**
  /// handled here — the caller must resolve them before calling.
  ///
  /// Returns `null` if [typeName] is unknown or ambiguous.
  static NativeImpl? fromTypeName(String? typeName) {
    switch (typeName) {
      case 'SwiftImpl':
        return NativeImpl.swift;
      case 'KotlinImpl':
        return NativeImpl.kotlin;
      case 'CppImpl':
        return NativeImpl.cpp;
      case 'WasmImpl':
        return NativeImpl.wasm;
      case 'WindowsNativeImpl':
      case 'LinuxNativeImpl':
        return NativeImpl.cpp;
      case 'WebNativeImpl':
        return NativeImpl.wasm;
      default:
        return null;
    }
  }
}

// ── Concrete implementation classes ───────────────────────────────────────────
// All have private constructors — only accessible via the sealed class constants.
// The generator uses `is CppImpl`, `is SwiftImpl`, etc. to determine bridging.

/// Swift + @_cdecl bridge. Valid on Apple platforms (iOS and macOS) only.
final class SwiftImpl extends NativeImpl implements AppleNativeImpl {
  const SwiftImpl._() : super._();
}

/// Kotlin + JNI bridge. Valid on Android only.
final class KotlinImpl extends NativeImpl implements AndroidNativeImpl {
  const KotlinImpl._() : super._();
}

/// Direct C++ via CMake/FFI. Valid on all native platforms.
/// Implements all native-platform sealed interfaces so it is accepted by
/// every [NitroModule] platform field except [NitroModule.web].
final class CppImpl extends NativeImpl
    implements
        AppleNativeImpl,
        AndroidNativeImpl,
        WindowsNativeImpl,
        LinuxNativeImpl {
  const CppImpl._() : super._();
}

/// WASM/JS interop bridge. Valid on Web only — dart:ffi is unavailable on web.
final class WasmImpl extends NativeImpl implements WebNativeImpl {
  const WasmImpl._() : super._();
}

// ── @NitroModule annotation ────────────────────────────────────────────────────

class NitroModule {
  /// Which implementation to use on iOS. `null` = not targeting iOS.
  final AppleNativeImpl? ios;

  /// Which implementation to use on Android. `null` = not targeting Android.
  final AndroidNativeImpl? android;

  /// Which implementation to use on macOS. `null` = not targeting macOS.
  /// Only [AppleNativeImpl.swift] or [AppleNativeImpl.cpp] are valid.
  final AppleNativeImpl? macos;

  /// Which implementation to use on Windows. `null` = not targeting Windows.
  /// Only [WindowsNativeImpl.cpp] is valid — Windows requires direct C++.
  final WindowsNativeImpl? windows;

  /// Which implementation to use on Linux. `null` = not targeting Linux.
  /// Only [LinuxNativeImpl.cpp] is valid — Linux requires direct C++.
  final LinuxNativeImpl? linux;

  /// Which implementation to use on Web. `null` = not targeting Web.
  /// Only [WebNativeImpl.wasm] is valid — dart:ffi is unavailable on web.
  final WebNativeImpl? web;

  /// Override the C symbol prefix (default: snake_case of the class name).
  final String? cSymbolPrefix;

  /// Override the shared library name (default: `lib{classname}`).
  final String? lib;

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

/// Value type that bridges with C-ABI struct layout.
///
/// Every `@HybridStruct` field crosses the FFI boundary on every call:
/// primitive fields (int, double, bool) are copied by value at zero cost;
/// **String fields** are heap-copied via `strdup`/`free` on both sides,
/// adding ~100–500 ns per call — the cost grows with string length.
///
/// **D4 guidance:** If your struct carries one or more String fields that are
/// frequently updated or compared, prefer `@HybridRecord` instead. Records
/// are binary-encoded once and decoded lazily, making them significantly
/// cheaper for text-heavy data (device names, error messages, config strings).
///
/// ✅ Use `@HybridStruct` for hot-path data where all fields are numeric
///    or boolean (sensor readings, camera frames, pixel coordinates).
/// ✅ Use `@HybridRecord` for structured data with String fields or
///    collections (device lists, configuration objects, API responses).
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
  /// Optional timeout in milliseconds. When set, the async method will throw
  /// a TimeoutException if the native call takes longer than [timeout] ms.
  /// null = no timeout.
  final int? timeout;
  const NitroAsync({this.timeout});
}

// Makes a method use the zero-hop native-async path. Return type must be Future<T>.
//
// Unlike @nitroAsync, no Dart isolate is ever spawned. Instead, Dart opens a
// ReceivePort and passes its native port ID to the C/Swift/Kotlin bridge. The
// native implementation runs its own async work (coroutine, Task, thread pool)
// and calls Dart_PostCObject_DL when done.
//
// Cut async overhead from ~930 µs (@nitroAsync) to ~146 µs.
// Cannot be combined with @nitroAsync on the same method.
const nitroNativeAsync = NitroNativeAsync();

class NitroNativeAsync {
  const NitroNativeAsync();
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

/// Marks that the native side heap-allocates the returned [NativeHandle] and
/// Dart takes ownership. The generator will:
///
/// 1. Emit `extern "C" void ${cSymbol}_release(void* handle)` in the C++
///    header — the user implements this to free their native object.
/// 2. Attach a [NativeFinalizer] on the Dart side that calls `_release` when
///    the [NativeHandle] is garbage-collected.
/// 3. Wire `NativeHandle._releaseCallback` so [NativeHandle.release] triggers
///    early cleanup.
///
/// Only valid on methods returning [NativeHandle]. Params and void returns are
/// rejected at validation time.
///
/// ```dart
/// @NitroOwned
/// NativeHandle<Void> acquireFrame();
/// ```
class NitroOwned {
  const NitroOwned();
}

/// Const shorthand for [@NitroOwned].
const nitroOwned = NitroOwned();
