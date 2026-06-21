/// Stub for dart:ffi types on web.
///
/// On web platforms dart:ffi is unavailable. This file exports enough of the
/// dart:ffi/ffi.dart public API as stubs so that shared Dart code that imports
/// `package:nitro/nitro.dart` can still parse and analyse on the web target
/// even though none of the FFI types are actually usable at runtime.
///
/// Any attempt to USE these types at runtime on web will throw via
/// [NitroRuntime]'s web stub.
library;

// No actual exports — the conditional export in nitro.dart switches to this
// file on web, which silently provides nothing. Types from dart:ffi (Pointer,
// NativeFunction, Uint8, etc.) are NOT re-exported because they don't exist
// on web and web code should never reference them directly.
//
// If your code needs to share types across native + web, wrap them in
// conditional imports inside your own library.
