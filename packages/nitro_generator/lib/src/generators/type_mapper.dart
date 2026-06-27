import '../bridge_spec.dart';

/// Abstract type mapper — maps a [BridgeType] to a target-language type string.
///
/// Each language provides its own implementation
/// (`KotlinTypeMapper`, `SwiftTypeMapper`, etc.). Generators receive
/// a `TypeMapper` by injection so the concrete implementation can be
/// swapped (or mocked in tests) without touching the generator.
///
/// The four methods correspond to the four code surfaces that every Nitro
/// generator must serve:
/// - [forKotlin] — Kotlin/JVM type (interface + JniBridge _call methods)
/// - [forSwift]  — Swift type (protocol + @_cdecl stubs)
/// - [forDart]   — Dart/FFI type (dart:ffi + the user-facing Dart class)
/// - [forC]      — C/C++ type (header declarations + inline casts)
///
/// Implementations only need to provide the languages they support.
/// Unsupported languages may throw [UnimplementedError].
abstract interface class TypeMapper {
  /// Kotlin/JVM type string for [t].
  ///
  /// [forParam] switches to the JNI `_call` bridge type (primitive descriptors,
  /// no `Long?`/`Boolean?` boxing). Defaults to the interface/protocol type.
  String forKotlin(BridgeType t, {bool forParam = false});

  /// Swift type string for [t].
  ///
  /// [forCDecl] switches to the `@_cdecl` C-ABI-compatible type
  /// (e.g. `Int8` instead of `Bool`, `UnsafePointer<CChar>?` instead of `String`).
  String forSwift(BridgeType t, {bool forCDecl = false});

  /// Dart/FFI type string for [t].
  ///
  /// [forNative] switches to the native FFI type
  /// (`Pointer<Uint8>`, `Int64`, etc.); default returns the user-facing Dart type.
  String forDart(BridgeType t, {bool forNative = false});

  /// C/C++ type string for [t].
  String forC(BridgeType t);
}
