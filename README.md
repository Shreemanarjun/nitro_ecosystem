# Nitrogen — Zero-overhead FFI Plugins for Flutter

Write one `.native.dart` spec file. Get type-safe Kotlin, Swift, C++, and Dart FFI — all generated.

No method channels. No JSON serialization. No copies.

---

## Quick demo

```dart
// lib/src/math.native.dart  ← you write this
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();

  double add(double a, double b);

  @nitroAsync
  Future<String> processExpression(String expr);

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorReading> get readings;
}
```

```sh
nitrogen generate
```

```
✓  lib/src/math.g.dart                    Dart FFI implementation
✓  lib/src/generated/kotlin/math.bridge.g.kt    Kotlin JNI bridge + interface
✓  lib/src/generated/swift/math.bridge.g.swift  Swift @_cdecl bridge + protocol
✓  lib/src/generated/cpp/math.bridge.g.h        C header
✓  lib/src/generated/cpp/math.bridge.g.cpp      C++ JNI + Apple bridge
✓  lib/src/generated/cmake/math.CMakeLists.g.txt CMake fragment
```

You fill in `MathImpl.kt` and `MathImpl.swift`. App calls `Math.instance.add(1, 2)`. Done.

---

## Why Nitrogen?

| | Method Channel | FFI (manual) | Nitrogen |
|---|---|---|---|
| Overhead per call | ~0.3 ms | ~0 ms | ~0 ms |
| Type safety | stringly-typed | manual | generated, strict |
| Async support | yes | manual isolates | generated |
| Streams | slow | manual SendPort | zero-copy |
| Zero-copy buffers | no | manual | via `@HybridStruct` |
| Code to write | lots | enormous | one spec file |

---

## Repository layout

```
nitro_ecosystem/
├── packages/
│   ├── nitro/            Runtime — base classes, annotations, FFI helpers
│   ├── nitro_generator/  build_runner code generator
│   └── nitrogen_cli/     CLI tool  (nitrogen init / generate / link / doctor)
├── nitro_battery/        Reference plugin — battery info, async structs, streams
├── my_camera/            Reference plugin — zero-copy camera frames at 30fps
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

[`my_camera`](my_camera/README.md) is a production-quality plugin that demonstrates every Nitrogen feature:

- Synchronous FFI call (`add`)
- Async native call (`getGreeting`)
- Zero-copy struct stream (`frames` at 30fps)
- `@HybridStruct` with `DirectByteBuffer` / `UnsafeMutablePointer` zero-copy fields

Use it as a template or read its source when you need a working example.

---

## License

MIT
