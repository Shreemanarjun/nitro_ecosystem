# Nitrogen — Zero-overhead FFI Plugins for Flutter

Write one `.native.dart` spec file. Get type-safe Kotlin, Swift, C++, and Dart FFI — all generated.

No method channels. No manual FFI. No boilerplate.

---

## Quick demo

```dart
// lib/src/my_camera.native.dart  ← you write this

// Hot-path data: flat C struct, zero-copy Uint8List
@HybridStruct(zeroCopy: ['data'])
class CameraFrame {
  final Uint8List data;
  final int width;
  final int height;
  final int stride;
  final int timestampNs;
  const CameraFrame({...});
}

// Complex nested data: binary-bridged, auto fromNative/toNative generated
@HybridRecord
class Resolution {
  final int width;
  final int height;
  const Resolution({required this.width, required this.height});
}

@HybridRecord
class CameraDevice {
  final String id;
  final String name;
  final List<Resolution> resolutions; // nested list — no problem
  final bool isFrontFacing;
  const CameraDevice({...});
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class MyCamera extends HybridObject {
  static final MyCamera instance = _MyCameraImpl();

  double add(double a, double b);

  @nitroAsync
  Future<List<CameraDevice>> getAvailableDevices(); // ← clean Dart types

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<CameraFrame> get frames; // ← zero-copy at 60fps
}
```

```sh
nitrogen generate
```

```
✓  lib/src/my_camera.g.dart                          Dart FFI implementation
✓  lib/src/generated/kotlin/my_camera.bridge.g.kt    Kotlin JNI bridge + interface
✓  lib/src/generated/swift/my_camera.bridge.g.swift  Swift @_cdecl bridge + protocol
✓  lib/src/generated/cpp/my_camera.bridge.g.h        C header
✓  lib/src/generated/cpp/my_camera.bridge.g.cpp      C++ JNI + Apple bridge
✓  lib/src/generated/cmake/my_camera.CMakeLists.g.txt CMake fragment
```

You fill in `MyCameraImpl.kt` and `MyCameraImpl.swift`. Done.

---

## Why Nitrogen?

| | Method Channel | FFI (manual) | Nitrogen |
|---|---|---|---|
| Overhead per call | ~0.3 ms | ~0 ms | ~0 ms |
| Type safety | stringly-typed | manual | generated, strict |
| Async support | yes | manual isolates | `@nitroAsync` generated |
| Streams | slow | manual SendPort | zero-copy via `@NitroStream` |
| Hot-path structs | no | manual | `@HybridStruct` + zero-copy |
| Complex nested data | JSON + manual decode | manual | `@HybridRecord` binary bridge |
| Code to write | lots | enormous | one spec file |

---

## `@HybridRecord` wire format

`@HybridRecord` types cross the FFI boundary as a compact little-endian binary buffer (`uint8_t*`) rather than a JSON string. This avoids text serialization, intermediate `Map` allocations, and JSON parsing on both sides.

```
[4-byte payload length][fields in declaration order]

int      → 8 bytes, little-endian int64
double   → 8 bytes, little-endian float64
bool     → 1 byte  (0 = false, 1 = true)
String   → 4-byte UTF-8 length + UTF-8 bytes
nullable → 1-byte null tag (0 = null, 1 = present) + value if present
list     → 4-byte element count + elements back-to-back
nested record → fields written inline (no extra length prefix)
```

Native side receives a `ByteArray` (Kotlin) or `Data` (Swift) and reads fields in declaration order — no JSON parsing, no `HashMap` allocation, no GC pressure.

---

## Annotation reference

| Annotation | Purpose | Bridge strategy |
|---|---|---|
| `@NitroModule` | Marks a class as the module spec | — |
| `@HybridStruct` | Flat C-memory struct (primitives/strings) | C `struct*` pointer |
| `@HybridEnum` | Integer-backed enum | `int64_t` |
| `@HybridRecord` | Rich binary-serialized record (nested objects, `List<T>`) | `uint8_t*` binary |
| `@nitroAsync` | Method dispatched on background isolate | `NitroRuntime.callAsync` |
| `@NitroStream` | Native push stream via `Dart_PostCObject` | SendPort / `openStream` |
| `@ZeroCopy` | `Uint8List` passed as raw pointer (no copy) | `uint8_t*` |

### Choosing between `@HybridStruct` and `@HybridRecord`

| | `@HybridStruct` | `@HybridRecord` |
|---|---|---|
| Field types | Primitives, `String`, `Uint8List`, other structs | Anything: nested objects, `List<T>`, nullable fields |
| Bridge cost | Lowest (pointer pass, no encoding) | Low (binary encode/decode — no JSON) |
| Wire format | C struct in-memory layout | Compact little-endian binary |
| Zero-copy | Yes (`zeroCopy: ['field']`) | No (fields copied into binary buffer) |
| Ideal for | Camera frames, sensor readings, hot-path data | Device lists, config objects, infrequent complex data |

---

## Supported Dart types

| Dart type | C bridge | Kotlin | Swift |
|---|---|---|---|
| `int` | `int64_t` | `Long` | `Int64` |
| `double` | `double` | `Double` | `Double` |
| `bool` | `int8_t` | `Boolean` | `Bool` |
| `String` | `const char*` (malloc'd) | `String` | `String` |
| `Uint8List` | `uint8_t*` | `ByteArray` | `Data` |
| `int?`, `double?`, `bool?`, `String?` | same + null tag | same + null tag | same + null tag |
| `@HybridEnum` | `int64_t` | `Long` + `.nativeValue` | `Int64` rawValue |
| `@HybridStruct` | `YourStruct*` | `@Keep data class` | `public struct` |
| `@HybridRecord` | `uint8_t*` (binary) | `ByteArray` | `Data` |
| `List<@HybridRecord T>` | `uint8_t*` (binary array) | `ByteArray` | `Data` |
| `List<int \| double \| bool \| String>` | `uint8_t*` (binary array) | `ByteArray` | `Data` |
| `Map<String, T>` | `const char*` (JSON) | `String` (JSON) | `String` (JSON) |
| `Future<T>` | — | `suspend fun` | `async throws` |
| `Stream<T>` | SendPort registration | `Flow<T>` | `AnyPublisher<T, Never>` |

> **Native side for `@HybridRecord`:** receive/return a `ByteArray` / `Data`. Read and write
> fields in declaration order using sequential reads/writes. `fromNative` / `writeFields` are
> auto-generated on the Dart side — no manual parsing needed.

---

## Repository layout

```
nitro_ecosystem/
├── packages/
│   ├── nitro/            Runtime — base classes, annotations, FFI helpers, RecordWriter/RecordReader
│   ├── nitro_generator/  build_runner code generator
│   └── nitrogen_cli/     CLI tool  (nitrogen init / generate / link / doctor)
├── nitro_battery/        Reference plugin — battery info, async structs, streams
├── my_camera/            Reference plugin — zero-copy frames + device enumeration
└── docs/
    ├── getting-started.md   Step-by-step guide for plugin authors
    ├── consuming.md         How app developers use a Nitrogen plugin
    ├── publishing.md        How to release a plugin to pub.dev
    └── lifecycle.md         NativeFinalizer, NativeCallable, hot restart safety
```

---

## Documentation

| Guide | Audience |
|---|---|
| [Getting started](docs/getting-started.md) | Plugin author — build a plugin from scratch |
| [Consuming a plugin](docs/consuming.md) | App developer — add and use a Nitrogen plugin |
| [Publishing to pub.dev](docs/publishing.md) | Plugin author — release and version your plugin |
| [Lifecycle and resource management](docs/lifecycle.md) | Plugin author — NativeFinalizer, NativeCallable.listener, hot restart safety |

---

## Package overview

| Package | Role | Add to |
|---|---|---|
| [`nitro`](packages/nitro/README.md) | Runtime dependency | plugin `dependencies:` |
| [`nitro_generator`](packages/nitro_generator/README.md) | build_runner generator | plugin `dev_dependencies:` |
| [`nitrogen_cli`](packages/nitrogen_cli/README.md) | CLI (`generate`, `init`, `link`, `doctor`) | `dart pub global activate` |

---

## Reference plugin

[`my_camera`](my_camera/README.md) is a production-quality plugin demonstrating every Nitrogen feature:

- Synchronous FFI call (`add`)
- Async `@HybridRecord` binary list return (`getAvailableDevices` → `List<CameraDevice>`)
- Zero-copy struct stream (`frames` at 60fps via `@HybridStruct` + `@NitroStream`)

Use it as a template or read its source when you need a working example.

---

## License

MIT
