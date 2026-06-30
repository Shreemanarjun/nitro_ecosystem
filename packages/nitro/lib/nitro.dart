// Conditional exports: dart:ffi, dart:io, and the full NitroRuntime are
// unavailable on web (dart:js_interop replaces them). On web targets Nitro
// exports a stub that throws UnsupportedError for all FFI operations.
//
// The `dart.library.ffi` condition is true on every native platform (iOS,
// Android, macOS, Windows, Linux) and false on web.

export 'src/annotations.dart';
export 'src/nitro_result.dart';
export 'src/nitro_config.dart';
export 'src/hybrid_exception.dart';
// dart:convert is available everywhere — needed for Map<String,T> binary bridge.
export 'dart:convert' show jsonDecode, jsonEncode, utf8;
// Generated part files share the spec file imports; re-export typed_data so
// helper code can use Int64List, ByteData, and friends without extra imports.
export 'dart:typed_data';

// ── Native-only exports (dart:ffi, dart:io required) ─────────────────────────
// On web these are replaced by the web stub so the package remains importable.

export 'src/nitro_runtime.dart' if (dart.library.js_interop) 'src/nitro_runtime_web.dart';

export 'src/hybrid_object_base.dart' if (dart.library.js_interop) 'src/hybrid_object_base.dart';

export 'src/isolate_pool.dart' if (dart.library.js_interop) 'src/isolate_pool.dart';

export 'src/native_handle.dart' if (dart.library.js_interop) 'src/native_handle.dart';

export 'src/ffi_utils.dart' if (dart.library.js_interop) 'src/ffi_utils.dart';

export 'src/record_codec.dart' if (dart.library.js_interop) 'src/record_codec.dart';

// ── Collision-free nullable primitive types + FFI codec abstractions ──────────
// NitroNullableInt/Double/Bool — binary null flag, no sentinel collisions.
// NitroOptInt64/Float64/Bool — @Packed C-ABI structs (std::optional<T> equivalent).
// NitroOptArena — Arena extension for zero-cost nullable prim encoding.
// NitroFfiCodec<T> / NitroIntCodec etc. — JSIConverter<T> equivalent.
export 'src/nitro_nullable.dart' if (dart.library.js_interop) 'src/nitro_nullable.dart';

export 'src/nitro_ffi_codec.dart' if (dart.library.js_interop) 'src/nitro_ffi_codec.dart';

// ── NitroAnyValue / NitroAnyMap — heterogeneous type-safe bridge map ──────────
// Mirrors RN Nitro's AnyValue variant + AnyMap class.
// NitroAnyValue: sealed Dart class (null|bool|int|double|String|List|Map).
// NitroAnyMap: typed string-keyed map with binary wire codec.
export 'src/nitro_any_value.dart' if (dart.library.js_interop) 'src/nitro_any_value.dart';

// ── AnyNativeObject — opaque native impl ref (RN Nitro AnyHybridObject equiv.) ─
export 'src/any_native_object.dart';
// ── NitroInstanceRegistry — Dart-side resolve<T> for AnyNativeObject refs ────
export 'src/nitro_instance_registry.dart';

// ── NitroPromise<T> — composable async primitive ──────────────────────────────
// Mirrors RN Nitro's Promise<T> C++ class.
// .resolve()/.reject(), addOnResolvedListener(), .then<R>(), .andThen<R>().
export 'src/nitro_promise.dart';

// dart:isolate — ReceivePort/SendPort used by generated callback-release ports.
// Conditionally excluded on web where dart:isolate is unavailable.
export 'dart:isolate' if (dart.library.js_interop) 'src/isolate_stub.dart' show ReceivePort, SendPort;

// dart:ffi — unavailable on web; web code uses dart:js_interop instead.
export 'dart:ffi' if (dart.library.js_interop) 'src/ffi_stub.dart';

export 'package:ffi/ffi.dart' if (dart.library.js_interop) 'src/ffi_stub.dart';
