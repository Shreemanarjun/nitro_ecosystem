/// Everything a generated `*.web.bridge.g.dart` needs, resolved to the WEB
/// implementations unconditionally.
///
/// Generated web bridges import THIS library instead of `package:nitro/nitro.dart`:
/// the main barrel's conditional exports resolve per-platform (native under
/// the analyzer), while a web bridge must always see the web runtime —
/// `NitroRuntime.loadWebModule`, `NitroWasmModule`, `WasmArena`, the
/// framed-bytes `RecordReader`/`RecordWriter`, and friends.
///
/// Do NOT import this from code that also runs natively — use
/// `package:nitro/nitro.dart` there.
library;

// Web runtime surface.
export 'src/web/nitro_runtime_web.dart';
export 'src/web/nitro_wasm_module.dart';
export 'src/web/port_registry.dart';
export 'src/web/nitro_error_web.dart';
export 'src/web/ffi_utils_web.dart';
export 'src/web/record_codec_web.dart';
export 'src/web/native_handle_web.dart';
export 'src/web/nitro_coalescer_web.dart';

// Platform-neutral pieces the generated code references.
export 'src/annotations.dart';
export 'src/hybrid_exception.dart';
export 'src/hybrid_object_base.dart';
export 'src/any_native_object.dart';
export 'src/nitro_instance_registry.dart';
export 'src/nitro_any_value.dart';
export 'src/nitro_promise.dart';
export 'src/nitro_result.dart';
export 'src/shared/nitro_bytes.dart';
export 'src/shared/nitro_nullable_core.dart';
export 'src/shared/nitro_wire_codec.dart';
export 'dart:convert' show jsonDecode, jsonEncode, utf8;
export 'dart:typed_data';
