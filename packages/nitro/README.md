# nitro 🚀

**Zero-overhead native bindings for Flutter.** `nitro` is the runtime layer of the Nitrogen SDK — it provides the base classes, annotations, and Dart-side runtime primitives that make type-safe, zero-copy FFI plugins possible on iOS, Android, macOS, Windows, Linux, and Web with no method-channel overhead.

> **This package is the runtime dependency.** Plugin authors add it to their `pubspec.yaml`. App developers pull it in transitively through any Nitrogen-powered plugin. The code generator lives in [`nitro_generator`](https://pub.dev/packages/nitro_generator) and the CLI in [`nitrogen_cli`](https://pub.dev/packages/nitrogen_cli).

---

## Why Nitro?

| | Method Channel | FFI (manual) | **Nitro** |
|---|---|---|---|
| Overhead per call | ~0.3 ms | ~0 ms | **~0 ms** |
| Type safety | stringly-typed | manual | **generated, strict** |
| Async support | ✅ | manual isolates | **✅ generated** |
| Streams | ✅ slow | manual SendPort | **✅ zero-copy** |
| Zero-copy buffers | ❌ | manual | **✅ via `@HybridStruct`** |
| Code to write | lots | enormous | **3 files** |

---

## Requirements

| Tool | Minimum version |
|---|---|
| Flutter SDK | 3.22.0+ |
| Dart SDK | 3.3.0+ |
| Android NDK | 26.1+ (r26b) |
| Kotlin | 1.9.0+ |
| iOS Deployment Target | 13.0+ |
| Swift | 5.9+ (Xcode 15+) |
| Xcode | 15.0+ |

---

## Installation

In your plugin's `pubspec.yaml`:

```yaml
dependencies:
  nitro: ^0.5.0
```

Then run:

```sh
flutter pub get
```

---

## Core concepts

### 1. `HybridObject` — the base class

Every Nitrogen plugin's public API extends `HybridObject`. You never instantiate it directly; the code generator produces a `_XxxImpl` hidden class that does the real FFI work.

```dart
// lib/src/math.native.dart  ← the ONLY file you write
import 'package:nitro/nitro.dart';

part 'math.g.dart';  // ← generated

@NitroModule(ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();

  // Synchronous FFI call — executes in < 1 µs
  double add(double a, double b);

  // Async — dispatched on a background isolate, returns to main isolate
  @nitroAsync
  Future<String> compute(String expression);
}
```

### 2. Annotations

| Annotation | Where | Effect |
|---|---|---|
| `@NitroModule(...)` | class | Marks an abstract class as a Nitrogen module spec |
| `@HybridEnum(startValue:, nativeValues:)` | enum | Maps a Dart enum to `int64_t`; use `nativeValues` for non-contiguous OS enums |
| `@HybridStruct(packed:, zeroCopy:)` | class | Packed C struct — zero-copy across FFI; hot-path numeric data |
| `@HybridRecord()` | class | Binary-encoded type; supports strings, lists, nullables, nested records |
| `@NitroVariant()` | sealed class | Discriminated union (tagged union); each subclass is one variant case |
| `@NitroTuple()` | typedef | Named positional record; fields accessed via `$1`, `$2`, … |
| `@nitroAsync` | method | Offloads call to a background isolate; overhead ~930 µs |
| `@nitroNativeAsync` | method | Native side posts result via `Dart_PostCObject_DL`; overhead ~146 µs |
| `@NitroStream(backpressure:)` | getter | Streams native events to Dart via `Dart_PostCObject_DL` |
| `@NitroResult()` | method | Return type becomes `NitroResultValue<T>` (`NitroOk<T>` or `NitroErr`) |
| `@zeroCopy` | parameter | Marks a `TypedData` param as a raw native pointer (callee must not retain) |
| `@NitroOwned` | method | `NativeHandle` return; Dart takes ownership; `NativeFinalizer` calls `_release` |
| `@NitroCustomType(codec:, encodedSize:)` | class | User-defined FFI codec; generator emits `codec.encode/decode` at every call site |

Use explicit per-platform implementation constants for new specs:

```dart
@NitroModule(
  lib: 'camera',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  macos: AppleNativeImpl.swift,
  windows: WindowsNativeImpl.cpp,
  linux: LinuxNativeImpl.cpp,
  web: WebNativeImpl.wasm,
)
abstract class Camera extends HybridObject {
  static final Camera instance = _CameraImpl();

  bool isAvailable();
}
```

`NativeImpl.swift`, `NativeImpl.kotlin`, `NativeImpl.cpp`, and `NativeImpl.wasm` remain available as backward-compatible shorthand, but the platform-specific constants make invalid combinations visible in code review.

When a native method returns a large buffer (e.g. camera frame or audio samples), mark the class with `@HybridStruct` and list the `TypedData` fields that should be zero-copy:

```dart
@HybridStruct(zeroCopy: ['data'])
class CameraFrame {
  final Uint8List data;    // ← mapped as Pointer<Uint8>, no copy
  final int width;
  final int height;
  final int stride;        // bytes per row — auto-detected as byte-length
  final int timestampNs;

  CameraFrame(this.data, this.width, this.height, this.stride, this.timestampNs);
}
```

The generator produces a `final class _CameraFrameFfi extends Struct` with correct `@Int64()` annotations, and a `toDart()` extension that calls `data.asTypedList(stride)` — **zero allocations, zero copies**.

### 4. `@NitroStream` — native → Dart streaming

```dart
@NitroModule(ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class Camera extends HybridObject {
  static final Camera instance = _CameraImpl();

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<CameraFrame> get frames;  // 30fps camera frames, zero-copy
}
```

**Backpressure options:**

| Value | Behaviour |
|---|---|
| `Backpressure.dropLatest` | Drop new item if Dart hasn't consumed yet — best for sensors/camera |
| `Backpressure.block` | Block the native thread until Dart consumes |
| `Backpressure.bufferDrop` | Ring buffer — oldest item dropped when full |
| `Backpressure.batch` | Accumulate items before one bridge crossing |

### 5. Zero-copy proxy streaming for `@HybridStruct`

When a `@NitroStream` item type is a `@HybridStruct`, Nitrogen generates a
**proxy class** that *extends* the value type and overrides every getter to
read lazily from the native heap. No fields are copied until accessed:

```dart
// Generated by Nitrogen — do not edit (example: benchmark_cpp.g.dart)
final class BenchmarkBoxProxy extends BenchmarkBox implements Finalizable {
  final Pointer<BenchmarkBoxFfi> _native;

  // Lazy overrides — reads from native heap on demand.
  @override int get color    => _native.ref.color;
  @override double get width  => _native.ref.width;
  @override double get height => _native.ref.height;

  // NativeFinalizer backed by a generated C release symbol.
  // Native memory is freed automatically on GC — no manual free needed.
}
```

Because `BenchmarkBoxProxy extends BenchmarkBox`, `Stream<BenchmarkBoxProxy>`
satisfies `Stream<BenchmarkBox>` via Dart's covariant generics. The declared
stream type is **unchanged** — consumers write completely normal Dart code:

```dart
// Type annotation is Stream<BenchmarkBox> — same as the spec.
camera.boxStream.listen((box) {
  // box is BenchmarkBoxProxy at runtime (IS-A BenchmarkBox).
  // Reading any field is a single native-heap load — zero allocation.
  final color = box.color;   // → _native.ref.color
  final w     = box.width;   // → _native.ref.width
  // When box leaves scope, NativeFinalizer frees the native struct.
});

// Need an immutable copy to outlive the current scope?
final snapshot = (box as BenchmarkBoxProxy).toDartAndRelease();
// snapshot is a plain BenchmarkBox value; native memory freed immediately.
```

**Performance summary (boxStream @ 60 fps):**

| Approach | Field read | Allocation per item | Memory management |
|---|---|---|---|
| Old (`.toDart()` on arrival) | Eager — all fields copied | 1 Dart object | `malloc.free` in unpack |
| **New (proxy)** | **Lazy — only accessed fields** | **0 extra allocs** | **NativeFinalizer on GC** |

---

## Usage — app developer side

Once a Nitrogen plugin is added as a dependency, the API is completely type-safe Dart:

```dart
import 'package:my_camera/my_camera.dart';

// Sync call — instant
final sum = Math.instance.add(3.14, 2.71);

// Async call — runs on background isolate
final result = await Math.instance.compute('sqrt(144)');
print(result); // "12"

// Stream — zero-copy frames at 30 fps
MyCamera.instance.frames.listen((frame) {
  // frame.data is a Uint8List backed by native hardware memory — NO copy
  // frame.stride × frame.height = total bytes
  print('${frame.width}×${frame.height}  ${frame.data.length} bytes');
});
```

---

## Usage — plugin author side

You write **3 files only**:

### 1. `lib/src/my_plugin.native.dart` (Dart spec)

```dart
import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'my_plugin.g.dart';

@HybridStruct(zeroCopy: ['data'])
class ImageBuffer {
  final Uint8List data;
  final int stride;    // auto-detected as length source
  final int width;
  final int height;
  ImageBuffer(this.data, this.stride, this.width, this.height);
}

@NitroModule(ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class MyPlugin extends HybridObject {
  static final MyPlugin instance = _MyPluginImpl();

  int add(int a, int b);

  @nitroAsync
  Future<String> processImage(String path);

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<ImageBuffer> get frames;
}
```

Then run the generator (from your plugin root):

```sh
nitrogen generate
```

### 2. `android/.../MyPluginImpl.kt` (Kotlin implementation)

```kotlin
import nitro.myplugin_module.HybridMyPluginSpec
import nitro.myplugin_module.MyPluginJniBridge
import nitro.myplugin_module.ImageBuffer
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.delay

class MyPluginImpl : HybridMyPluginSpec {
    override fun add(a: Long, b: Long): Long = a + b

    override suspend fun processImage(path: String): String {
        delay(100) // simulate native work
        return "Processed: $path"
    }

    override val frames: Flow<ImageBuffer> = flow {
        val buf = java.nio.ByteBuffer.allocateDirect(1920 * 1080 * 4)
        while (true) {
            emit(ImageBuffer(buf, 1920L * 4L, 1920L, 1080L))
            delay(33) // ~30fps
        }
    }
}

class MyPluginPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        MyPluginJniBridge.register(MyPluginImpl())
    }
    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {}
}
```

### 3. `ios/Classes/MyPluginImpl.swift` (Swift implementation)

```swift
import Flutter
import UIKit
import Combine

public class MyPluginImpl: NSObject, HybridMyPluginProtocol {
    public func add(a: Int64, b: Int64) -> Int64 { a + b }

    public func processImage(path: String) async throws -> String {
        try await Task.sleep(nanoseconds: 100_000_000)
        return "Processed: \(path)"
    }

    private let framesSubject = PassthroughSubject<ImageBuffer, Never>()
    public var frames: AnyPublisher<ImageBuffer, Never> {
        framesSubject.eraseToAnyPublisher()
    }

    override init() {
        super.init()
        let stride: Int64 = 1920 * 4
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(stride * 1080))
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let frame = ImageBuffer(data: buf, stride: stride, width: 1920, height: 1080)
            self?.framesSubject.send(frame)
        }
    }
}

public class MyPluginPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        MyPluginRegistry.register(MyPluginImpl())
    }
}
```

---

## Type mapping reference

### Primitives

| Dart | C | Kotlin | Swift |
|---|---|---|---|
| `int` | `int64_t` | `Long` | `Int64` |
| `double` | `double` | `Double` | `Double` |
| `bool` | `int8_t` | `Boolean` | `Bool` |
| `String` | `const char*` | `String` | `String` |
| `void` | `void` | `Unit` | `Void` |

### Nullable primitives (0.5.0+)

Bridged as `@Packed(1)` C structs — same layout as C++ `std::optional<T>`. No sentinels, no heap allocation on sync paths.

| Dart | C struct | Size |
|---|---|---|
| `int?` | `NitroOptInt64 { uint8_t hasValue; int64_t value; }` | 9 B |
| `double?` | `NitroOptFloat64 { uint8_t hasValue; double value; }` | 9 B |
| `bool?` | `NitroOptBool { uint8_t hasValue; uint8_t value; }` | 2 B |
| `String?` | `const char*` (null = absent) | pointer |

### Buffers & collections

| Dart | C | Kotlin | Swift |
|---|---|---|---|
| `Uint8List`, `Float32List`, ... | `T* + int64_t len` | `ByteArray`, `FloatArray`, ... | `UnsafeMutablePointer<T>?, Int64` |
| `TypedData` + `@zeroCopy` | `T*` (raw pin) | `java.nio.ByteBuffer` | `UnsafeMutablePointer<T>?` |
| `List<primitive>` | `uint8_t*` (record codec) | `List<T>` | `[T]` |
| `Map<String, T>` | JSON (`const char*`) | `Map<String, T>` | `[String: T]` |

### Custom types

| Dart | C | Kotlin | Swift |
|---|---|---|---|
| `@HybridEnum` | `int64_t` | `Long` | `Int64` |
| `@HybridStruct` | `void*` (packed struct) | `ByteArray` | `UnsafePointer<T>?` |
| `@HybridRecord` | `uint8_t*, int64_t len` | `ByteArray` | `UnsafePointer<UInt8>?` |
| `@NitroVariant` | `uint8_t*, int64_t len` | `ByteArray` | `UnsafePointer<UInt8>?` |
| `@NitroTuple` | `uint8_t*, int64_t len` | `ByteArray` | `UnsafePointer<UInt8>?` |
| `NativeHandle<Void>` | `void*` | `Long` | `Int64` |

### Async & stream

| Dart | Kotlin | Swift |
|---|---|---|
| `@nitroAsync Future<T>` | `suspend fun` | `async throws` |
| `@nitroNativeAsync Future<T>` | fun with `Long port` | func with `Int64 port` |
| `@NitroResult() Future<NitroResultValue<T>>` | `suspend fun` → throws | `async throws -> T` |
| `@NitroStream Stream<T>` | `Flow<T>` | `AnyPublisher<T, Never>` |

---

## Repo structure

```
nitro_ecosystem/
├── packages/
│   ├── nitro/          ← this package (runtime: base classes, annotations, runtime)
│   ├── nitro_generator/ ← code generator (build_runner builder)
│   └── nitrogen_cli/   ← CLI tool (nitrogen generate / init / doctor)
└── my_camera/          ← example plugin built with Nitrogen
    ├── lib/src/
    │   ├── my_camera.native.dart   ← spec (author-written)
    │   └── my_camera.g.dart        ← generated FFI impl
    ├── android/                    ← Kotlin implementation
    └── ios/                        ← Swift implementation
```

---

## Special runtime types

### `AnyNativeObject` / `NitroAnyValue` / `NitroAnyMap`

For bridging dynamic / untyped data:

```dart
// Spec:
AnyNativeObject? getHandle();
NitroAnyMap getConfig();
```

| Type | Description |
|---|---|
| `AnyNativeObject` | Opaque native pointer stored as `int64_t`. Use `@NitroOwned` when Dart takes ownership. |
| `NitroAnyValue` | Dynamic variant: null / bool / int / double / String / List / Map. Equivalent to a JSON value. |
| `NitroAnyMap` | Typedef for `Map<String, NitroAnyValue>`. Equivalent to a JSON object. |

```dart
// Dart usage:
final config = module.getConfig();  // NitroAnyMap
final name = config['appName']?.asString;
final version = config['buildNumber']?.asInt;
```

> Prefer `@HybridRecord` when the schema is known — it is significantly faster than `NitroAnyMap`.

### `NitroPromise<T>`

A Dart-side future that the native side can resolve or reject. It wraps a `ReceivePort` and exposes a `.future` property:

```dart
// Generated for @nitroNativeAsync methods — you rarely use NitroPromise directly.
// Available for advanced patterns where native code needs to hold a Dart future reference.
final promise = NitroPromise<String>();
nativeLayer.doWork(promise.port.nativePort);
final result = await promise.future;
```

---

## Special Notes

### `dart:isolate` not needed for callback specs (0.5.0+)

Generated `.g.dart` files are `part of` the user's spec file and cannot have their own `import` directives. Before 0.5.0, specs that used callbacks (methods with function parameters) required `import 'dart:isolate'` because generated code uses `ReceivePort` for callback-release ports.

As of 0.5.0, `package:nitro/nitro.dart` re-exports `ReceivePort` and `SendPort` conditionally (with a web stub). Remove any manual `import 'dart:isolate'` from spec files:

```dart
// ❌ Before 0.5.0:
import 'dart:isolate';
import 'package:nitro/nitro.dart';
part 'my_module.g.dart';

// ✅ 0.5.0+:
import 'package:nitro/nitro.dart';
part 'my_module.g.dart';
```

### Nullable callback parameters use sentinels

`NativeCallable` function pointers (used for Dart callbacks passed to native) have no `Arena` lifetime in the callback body. `int?`, `double?`, and `bool?` callback parameters therefore use sentinel values (`Int64.min`, NaN bits, `-1`) rather than `NitroOptXxx` structs. To pass the full value range for these types, wrap them in a `@HybridRecord`:

```dart
@HybridRecord()
class MaybeCount { final int? value; const MaybeCount({this.value}); }

// Callback can now receive full int? range:
void onResult(MaybeCount result);
```

### `@zeroCopy` — callee must not retain

Buffers marked `@zeroCopy` point to pinned Dart managed memory. The native implementation must complete all work on the buffer **within the function call** — storing the pointer for use after the call returns causes undefined behaviour (the GC may move or free the buffer).

---

## Known Limitations

| ID | Limitation | Workaround |
|---|---|---|
| L6 | `@HybridStruct` / `@HybridRecord` cannot be **returned** from a callback parameter (function type). | Return `void` from callback; use a reverse method call or `Stream`. |
| L7 | `TypedData?` (nullable `Uint8List`, etc.) is not supported. The two-param C ABI (pointer + length) makes optional transport ambiguous. | Wrap in `@HybridRecord`: `class MaybeBuffer { final Uint8List? data; }` |
| L8 | Web (`WebNativeImpl.wasm`) — `dart:ffi` is unavailable. `ReceivePort`/`SendPort` are stubs. Streams and callbacks throw `UnsupportedError` on web. | Guard platform-specific code; use `@HybridRecord` or `NitroAnyMap` for data transfer on web. |
| L10 | `Map<String, @HybridStruct>` is not supported. | Use `Map<String, @HybridRecord>` instead. |
| L12 | `@NitroVariant` as a callback return type is not supported. | Return `void`; use a separate method or stream. |

---

## License

MIT
