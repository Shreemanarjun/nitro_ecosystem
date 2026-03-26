## 0.2.3

- **Improved: Native Visibility Visibility**: Updated `nitro.h` to include `NITRO_EXPORT` macros by default, ensuring all native symbols are correctly exported for FFI across iOS, Android, macOS, and Windows.
- **Improved: Dependency Sync**: Synchronized the Nitro ecosystem to version 0.2.3.

## 0.2.2

- **Improved: annotation compatibility** — verified full compatibility with Nitrogen 0.2.2's stable annotation resolution system, ensuring re-exported `@NitroModule`, `@HybridStruct`, and `@HybridEnum` annotations are correctly identified by the code generator.
- Added explicit `void` support in return types for all `HybridObject` methods.

## 0.2.1

- Moved all annotations to the separate `nitro_annotations` package to improve generator platform compatibility.
- Re-exported `nitro_annotations` for backward compatibility.
- Added explicit support for `macos`, `windows`, and `linux` to the plugin configuration to resolve `pub.dev` platform detection warnings.

# 0.2.0

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
