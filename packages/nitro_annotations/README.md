# nitro_annotations

[![Pub Version](https://img.shields.io/pub/v/nitro_annotations)](https://pub.dev/packages/nitro_annotations)

Pure-Dart annotations and enums for the **Nitrogen** ecosystem. Zero dependencies — compatible with Flutter, Dart Server, and CLI.

This package is used by `nitro_generator` to generate high-performance FFI bridges between Dart and native code (C++, Swift, or Kotlin).

## Annotations

### `@NitroModule`

Marks a class as a native module. The `ios` and `android` parameters select the implementation strategy for each platform:

```dart
// Swift (iOS) + Kotlin (Android) — platform-specific APIs
@NitroModule(lib: 'camera', ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Camera extends HybridObject { ... }

// Direct C++ on both platforms — shared logic, ~1µs latency
@NitroModule(lib: 'math', ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject { ... }
```

| `NativeImpl` | Generated bridge | When to use |
|---|---|---|
| `NativeImpl.swift` | Swift `@_cdecl` bridge | iOS platform APIs (AVFoundation, CoreBluetooth, …) |
| `NativeImpl.kotlin` | Kotlin JNI bridge | Android platform APIs (Camera2, BLE, …) |
| `NativeImpl.cpp` | Direct C++ virtual dispatch (no JNI/Swift) | Pure computation, shared C++ libs, maximum performance |

When **both** platforms use `NativeImpl.cpp`, the generator also produces:
- `*.native.g.h` — abstract `HybridX` C++ class to subclass
- `*.mock.g.h` — GoogleMock `MockX` class for unit tests
- `*.test.g.cpp` — test starter with smoke test

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

Wire format: `[4-byte length][fields in declaration order, little-endian]`.

### `@HybridEnum`

Maps a Dart enum to an `int64_t` at the C boundary.

```dart
@HybridEnum(startValue: 0)
enum DeviceStatus { idle, busy, error }
```

### `@nitroAsync`

Offloads a synchronous native call to a background thread, returning a `Future`.

```dart
@nitroAsync
Future<String> fetchData(String url);
```

### `@NitroStream`

Configures a native-to-Dart event stream with built-in backpressure.

```dart
@NitroStream(backpressure: Backpressure.dropLatest)
Stream<SensorData> get sensorStream;
```

**Backpressure strategies:**
- `Backpressure.dropLatest` — drop the newest item if the consumer is behind
- `Backpressure.dropOldest` — drop the oldest buffered item
- `Backpressure.block` — block the emitter until the consumer catches up

For `NativeImpl.cpp` modules, streams are emitted via `emit_<name>(item)` helpers defined on the `HybridX` class — callable from any C++ thread.

## Integration

If you are building a plugin using Nitro, depend on `package:nitro` (the runtime), which re-exports everything in this package for convenience.

If you are building metadata-based tools or generators, depend directly on `nitro_annotations` to keep your project cross-platform and minimize transitive dependencies.

---

For more details on the Nitrogen ecosystem, visit [nitro.shreeman.dev](https://nitro.shreeman.dev) or the [GitHub repository](https://github.com/Shreemanarjun/nitro_ecosystem).
