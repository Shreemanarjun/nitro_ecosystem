## 0.2.0

- **New: Binary `RecordWriter` and `RecordReader` Codec** — Compact little-endian protocol for `@HybridRecord` types, replacing JSON text serialization with direct binary field access over raw `uint8_t*` buffers.
  - Wire format: `int64` (8B), `float64` (8B), `bool` (1B), `String` (4-byte length + UTF-8), nullable (1-byte tag), and `list` (4-byte count).
  - High-performance `encodeList` / `decodeList` for collections of records or primitives.
  - Retains `dart:convert` re-exports for `Map<String, T>` which still uses the JSON path.
- **New: `IsolatePool` & `NitroRuntime.init()`** — Fixed-size pool of persistent worker isolates with round-robin dispatch. Pre-warmed by `init()` to eliminate the ~1–5 ms `Isolate.spawn` overhead on every `callAsync`.
- **New: `NitroConfig` Runtime Singleton** — Configurable runtime behavior:
  - `debugMode`: Enables verbose logging of bridge calls, streams, isolates, and lifecycles.
  - `logLevel`: Granular control (`none`, `error`, `warning`, `verbose`).
  - `logHandler`: Custom sink for logs (e.g., Firebase, Sentry, Crashlytics).
  - `slowCallThresholdUs`: Configurable warning threshold for long-running async calls (default 16ms).
- **Improved: `NitroRuntime` Robustness** — Stream unpack errors are now always logged at `error` level with stack traces, ensuring they are never silently swallowed. Added `debugLabel` to streams for easier debugging.
- **Fix: Style & Linting** — Renamed internal state variables (e.g., `_released` → `released`) to follow Dart conventions for local variables.

## 0.1.0

- Initial release of Nitro runtime.
- Support for `HybridObject`, `HybridStruct`, and `HybridEnum`.
- Support for synchronous and asynchronous bridge calls.
- Unified FFI bridge support for Android and iOS.
