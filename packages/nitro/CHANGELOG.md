## 0.2.2

- **New: `NitroConfig`** — a singleton configurable at runtime, replacing hardcoded behaviour:
  - `debugMode` — enables verbose logging of every bridge call, stream event, isolate dispatch, and lifecycle transition.
  - `logLevel` — controls verbosity: `none`, `error` (default), `warning`, `verbose`. Stream unpack failures now always log at `error` level regardless of `logLevel` — never silently swallowed again.
  - `logHandler` — replace the default `print`-based logger with any custom sink (e.g. `package:logging`, Crashlytics, Firebase).
  - `isolatePoolSize` — number of pre-warmed worker isolates for `callAsync` (default `1`). Set to `0` to restore the legacy `Isolate.run`-per-call behaviour.
  - `slowCallThresholdUs` — emits a `warning` log for any `callAsync` that takes longer than this threshold (default `16000 µs` = one frame at 60 fps).
- **New: `IsolatePool`** — fixed-size pool of persistent worker isolates with round-robin dispatch. Eliminates the ~1–5 ms `Isolate.spawn` overhead on every `callAsync`. Pre-warmed by `NitroRuntime.init()`.
- **`NitroRuntime.callAsync`** — now dispatches to the pool when available; falls back to `Isolate.run` when poolSize is 0 or `init()` has not been called.
- **`NitroRuntime.openStream`** — stream unpack errors are now always logged at `NitroLogLevel.error` with an event count, error, and stack trace, _in addition_ to being forwarded to `controller.addError`. Added optional `debugLabel` parameter for identifying streams in logs.
- **`NitroRuntime.init`** accepts an optional `isolatePoolSize` parameter to configure the pool size at init time.

## 0.2.1


- **Fix: lint — renamed local variable `_released` to `released`** in `NitroRuntime.openStream` — local variables must not start with an underscore (convention reserved for private class members).

## 0.2.0

- **New: `RecordWriter` and `RecordReader` binary codec** — compact little-endian binary protocol for `@HybridRecord` types. Eliminates JSON text serialization in favour of sequential field reads/writes over a raw `uint8_t*` buffer.
  - Wire format: `int64` (8 B), `float64` (8 B), `bool` (1 B), `String` (4-byte length + UTF-8), nullable (1-byte null tag + value), `list` (4-byte count + elements).
  - `RecordWriter.encodeList` / `encodePrimitiveList` for `List<@HybridRecord T>` and `List<primitive>`.
  - `RecordReader.decodeList` / `decodePrimitiveList` as counterparts.
  - All classes exported from `package:nitro/nitro.dart`.
- **`dart:convert` re-export retained** — `jsonEncode` / `jsonDecode` remain available for `Map<String, T>` bridges which still use the JSON text path.

## 0.1.0

- Initial release of Nitro runtime.
- Support for `HybridObject`, `HybridStruct`, and `HybridEnum`.
- Support for synchronous and asynchronous bridge calls.
- Unified FFI bridge support for Android and iOS.
