// Conditional exports: dart:ffi, dart:io, and the full NitroRuntime are
// unavailable on web (dart:js_interop replaces them). On web targets Nitro
// exports a stub that throws UnsupportedError for all FFI operations.
//
// The `dart.library.ffi` condition is true on every native platform (iOS,
// Android, macOS, Windows, Linux) and false on web.

export 'src/annotations.dart';
export 'src/nitro_config.dart';
export 'src/hybrid_exception.dart';
// dart:convert is available everywhere — needed for Map<String,T> JSON bridge.
export 'dart:convert' show jsonDecode, jsonEncode;

// ── Native-only exports (dart:ffi, dart:io required) ─────────────────────────
// On web these are replaced by the web stub so the package remains importable.

export 'src/nitro_runtime.dart'
    if (dart.library.js_interop) 'src/nitro_runtime_web.dart';

export 'src/hybrid_object_base.dart'
    if (dart.library.js_interop) 'src/hybrid_object_base.dart';

export 'src/isolate_pool.dart'
    if (dart.library.js_interop) 'src/isolate_pool.dart';

export 'src/native_handle.dart'
    if (dart.library.js_interop) 'src/native_handle.dart';

export 'src/ffi_utils.dart'
    if (dart.library.js_interop) 'src/ffi_utils.dart';

export 'src/record_codec.dart'
    if (dart.library.js_interop) 'src/record_codec.dart';

// dart:ffi — unavailable on web; web code uses dart:js_interop instead.
export 'dart:ffi'
    if (dart.library.js_interop) 'src/ffi_stub.dart';

export 'package:ffi/ffi.dart'
    if (dart.library.js_interop) 'src/ffi_stub.dart';
