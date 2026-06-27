# nitro_annotations

[![Pub Version](https://img.shields.io/pub/v/nitro_annotations)](https://pub.dev/packages/nitro_annotations)

Pure-Dart annotations and enums for the **Nitrogen** ecosystem. Zero dependencies — compatible with Flutter, Dart Server, and CLI.

This package is used by `nitro_generator` to generate high-performance FFI bridges between Dart and native code (C++, Swift, or Kotlin).

## Annotations

### `@NitroModule`

Marks a class as a native module. The parameters select the implementation strategy for each platform using sealed platform types:

```dart
// Swift (iOS) + Kotlin (Android) — platform-specific APIs
@NitroModule(
  lib: 'camera',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
)
abstract class Camera extends HybridObject {
  bool isAvailable();
}

// Direct C++ on both platforms — shared logic, ~1µs latency
@NitroModule(
  lib: 'math',
  ios: AppleNativeImpl.cpp,
  android: AndroidNativeImpl.cpp,
  macos: AppleNativeImpl.cpp,
  windows: WindowsNativeImpl.cpp,
  linux: LinuxNativeImpl.cpp,
)
abstract class Math extends HybridObject {
  double add(double a, double b);
}
```

| Implementation Constant | Generated bridge | When to use |
|---|---|---|
| `AppleNativeImpl.swift` | Swift `@_cdecl` bridge | iOS/macOS platform APIs |
| `AndroidNativeImpl.kotlin` | Kotlin JNI bridge | Android platform APIs |
| `*NativeImpl.cpp` | Direct C++ virtual dispatch | Pure computation, shared C++ libs, maximum performance, Windows, Linux |
| `WebNativeImpl.wasm` | WASM/JS interop bridge | Web targets |

*(Note: `NativeImpl.*` is supported as a backward-compatible shorthand)*

### `@HybridStruct`

Generates a packed C struct for zero-copy data transfer across the FFI boundary. All fields must be primitive (`int`, `double`, `bool`) or other `@HybridStruct` types.

```dart
@HybridStruct(packed: true)
class SensorData {
  final double temperature;
  final double humidity;
  const SensorData({required this.temperature, required this.humidity});
}
```

### `@HybridRecord`

Generates a compact binary-encoded type for complex, infrequent data transfer. Supports nested records, lists, nullable fields, and `String` — without JSON parsing overhead.

```dart
@HybridRecord()
class UserProfile {
  final String name;
  final int age;
  final List<String> tags;
  const UserProfile({required this.name, required this.age, required this.tags});
}
```

### `@HybridEnum`

Maps a Dart enum to an `int64_t` at the C boundary.

```dart
@HybridEnum(startValue: 0)
enum DeviceStatus { idle, busy, error }
```

### `@NitroVariant`

Marks a Dart sealed class as a discriminated union type (sum type / tagged union).

```dart
@NitroVariant()
sealed class FilterResult { const FilterResult(); }

class FilterAccepted extends FilterResult {
  final String id;
  const FilterAccepted({required this.id});
}
class FilterRejected extends FilterResult { const FilterRejected(); }
```

### Async Execution

**`@nitroAsync`**
Offloads a synchronous native call to a background thread, returning a `Future`.
```dart
@nitroAsync
Future<String> fetchData(String url);
```

**`@nitroNativeAsync`**
Uses the zero-hop native-async path. Dart passes its native port ID to the bridge, and the native implementation runs its own async work and posts back the result.
```dart
@nitroNativeAsync
Future<String> fetchDataNative(String url);
```

### Result Types

**`@NitroResult`**
Marks a method's return type as a discriminated success/error result. The method's return type must be `Future<NitroResultValue<T>>` or `NitroResultValue<T>`.

```dart
@nitroResult
Future<NitroResultValue<String>> login(String user, String password);
```

### Streams

**`@NitroStream`**
Configures a native-to-Dart event stream with built-in backpressure.

```dart
@NitroStream(backpressure: Backpressure.dropLatest)
Stream<SensorData> get sensorStream;
```

**Backpressure strategies:**
- `Backpressure.dropLatest` — drop the newest item if the consumer is behind
- `Backpressure.bufferDrop` — ring buffer; oldest item dropped
- `Backpressure.block` — block the emitter until the consumer catches up
- `Backpressure.batch` — accumulate items before a single bridge crossing

### Advanced Data Ownership

**`@zeroCopy`**
Marks a `Uint8List` param as zero-copy (passed as raw pointer, callee must not retain).
```dart
void processPixels(@zeroCopy Uint8List data);
```

**`@nitroOwned`**
Marks that the native side heap-allocates the returned `NativeHandle` and Dart takes ownership, releasing it automatically.
```dart
@nitroOwned
NativeHandle<Void> acquireFrame();
```

## Integration

If you are building a plugin using Nitro, depend on `package:nitro` (the runtime), which re-exports everything in this package for convenience.

If you are building metadata-based tools or generators, depend directly on `nitro_annotations` to keep your project cross-platform and minimize transitive dependencies.

---

For more details on the Nitrogen ecosystem, visit [nitro.shreeman.dev](https://nitro.shreeman.dev) or the [GitHub repository](https://github.com/Shreemanarjun/nitro_ecosystem).
