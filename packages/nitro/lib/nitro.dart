// Conditional exports: dart:ffi, dart:io, and dart:isolate are unavailable on
// web, where dart:js_interop over an Emscripten-compiled WASM module replaces
// them. Every `if (dart.library.js_interop)` pair below switches a native
// (dart:ffi) edge for its web twin; files without a condition are pure Dart
// compiled identically on every platform.

export 'src/annotations.dart';
export 'src/nitro_result.dart';
export 'src/nitro_config.dart';
export 'src/hybrid_exception.dart';
export 'src/hybrid_object_base.dart';
// dart:convert is available everywhere — needed for Map<String,T> binary bridge.
export 'dart:convert' show jsonDecode, jsonEncode, utf8;
// Generated part files share the spec file imports; re-export typed_data so
// helper code can use Int64List, ByteData, and friends without extra imports.
export 'dart:typed_data';

// ── Platform-neutral core (shared by the FFI and WASM edges) ─────────────────
export 'src/shared/nitro_bytes.dart';
export 'src/shared/record_codec_base.dart';
export 'src/shared/nitro_wire_codec.dart';

// ── AnyValue / registry / promise — pure Dart ─────────────────────────────────
export 'src/nitro_any_value.dart';
export 'src/any_native_object.dart';
export 'src/nitro_instance_registry.dart';
export 'src/nitro_promise.dart';

// ── Native (dart:ffi) edges and their web twins ───────────────────────────────

export 'src/nitro_runtime.dart' if (dart.library.js_interop) 'src/web/nitro_runtime_web.dart';

export 'src/isolate_pool.dart' if (dart.library.js_interop) 'src/web/isolate_pool_web.dart';

export 'src/nitro_coalescer.dart' if (dart.library.js_interop) 'src/web/nitro_coalescer_web.dart';

export 'src/native_handle.dart' if (dart.library.js_interop) 'src/web/native_handle_web.dart';

export 'src/ffi_utils.dart' if (dart.library.js_interop) 'src/web/ffi_utils_web.dart';

export 'src/record_codec.dart' if (dart.library.js_interop) 'src/web/record_codec_web.dart';

// NitroNullableInt/Double/Bool are pure (shared core, exported by both
// branches); the native branch adds the NitroOpt* packed structs, pointer
// codecs, and Arena pack extensions.
export 'src/nitro_nullable.dart' if (dart.library.js_interop) 'src/web/nitro_nullable_web.dart';

// NitroFfiCodec<T> (Pointer-based custom-type codec) is native-only; web
// custom types use the platform-neutral NitroWireCodec<T> exported above.
export 'src/nitro_ffi_codec.dart' if (dart.library.js_interop) 'src/web/ffi_codec_stub.dart';

// NitroErrorFfi out-param struct (native) / WebNitroErrorSlot (web).
export 'src/nitro_error_ffi.dart' if (dart.library.js_interop) 'src/web/nitro_error_web.dart';

// Pointer codec for NitroAnyMap (native-only; web frames writeTo/readFrom).
export 'src/nitro_any_value_ffi.dart' if (dart.library.js_interop) 'src/web/any_value_stub.dart';

// ── Web-only runtime surface (no-op empty library on native) ─────────────────
export 'src/native_web_stub.dart' if (dart.library.js_interop) 'src/web/nitro_web.dart';

// dart:isolate — ReceivePort/SendPort used by generated callback-release ports.
// Conditionally excluded on web where dart:isolate is unavailable.
export 'dart:isolate' if (dart.library.js_interop) 'src/isolate_stub.dart' show ReceivePort, SendPort;

// dart:ffi — unavailable on web; the stub provides marker types (NativeType,
// Void, ...) so platform-neutral specs like `NativeHandle<Void>` compile.
export 'dart:ffi' if (dart.library.js_interop) 'src/ffi_stub.dart';

export 'package:ffi/ffi.dart' if (dart.library.js_interop) 'src/ffi_stub.dart';
