# Nitrogen — Zero-overhead FFI Plugins for Flutter

[![nitro](https://img.shields.io/pub/v/nitro?label=nitro)](https://pub.dev/packages/nitro)
[![nitro_annotations](https://img.shields.io/pub/v/nitro_annotations?label=nitro_annotations)](https://pub.dev/packages/nitro_annotations)
[![nitro_generator](https://img.shields.io/pub/v/nitro_generator?label=nitro_generator)](https://pub.dev/packages/nitro_generator)
[![nitrogen_cli](https://img.shields.io/pub/v/nitrogen_cli?label=nitrogen_cli)](https://pub.dev/packages/nitrogen_cli)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Write one `.native.dart` spec file. Get type-safe Kotlin, Swift, **or C++** — all generated.

No method channels. No manual FFI. No boilerplate.

📖 **Full docs, live examples, and API reference: [nitro.shreeman.dev](https://nitro.shreeman.dev)**

---

## Why Nitrogen?

| | Method Channel | Manual FFI | **Nitrogen** |
|---|---|---|---|
| Call overhead | ~107 µs | ~0 µs (floor) | **~0.03 µs checked / ~0.014 µs `@nitroFast` (macOS)** |
| Type safety | stringly-typed | hand-written, error-prone | **generated from one Dart spec, strict** |
| Async | ✅ | manual isolates | **✅ generated (`@nitroAsync` / `@nitroNativeAsync`)** |
| Streams + backpressure | ✅ slow | manual `SendPort` plumbing | **✅ zero-copy, 4 backpressure strategies** |
| Zero-copy buffers | ❌ | manual `Pointer<T>` | **✅ `@HybridStruct(zeroCopy: [...])`, `@zeroCopy`** |
| Desktop (Windows/Linux) | method channel only | manual FFI | **✅ same spec, direct C++** |
| Code you write | a lot, on every platform | enormous, unsafe | **3 files: spec + Kotlin impl + Swift impl (or 1 C++ impl)** |

---

## Packages

| Package | Role | `pubspec.yaml` section |
|---|---|---|
| [`nitro`](packages/nitro/README.md) | Runtime — base classes, FFI helpers, codec | `dependencies` |
| [`nitro_annotations`](packages/nitro_annotations/README.md) | All annotations (zero deps, works without Flutter) | `dependencies` |
| [`nitro_generator`](packages/nitro_generator/README.md) | build_runner code generator | `dev_dependencies` |
| [`nitrogen_cli`](packages/nitrogen_cli/README.md) | CLI — `init`, `generate`, `link`, `doctor` | `dart pub global activate` |

```yaml
# pubspec.yaml
dependencies:
  nitro: ^0.7.6

dev_dependencies:
  nitro_generator: ^0.7.6
  build_runner: ^2.4.0
```

```sh
dart pub global activate nitrogen_cli  # one-time
```

### Requirements

| Tool | Minimum version |
|---|---|
| Flutter SDK | 3.35.0+ (any release bundling Dart 3.11.3) |
| Dart SDK | 3.11.3+ (`sdk: ^3.11.3` in every package) |
| Android NDK | 26.1+ (r26b) |
| Kotlin | 1.9.0+ |
| iOS Deployment Target | 13.0+ |
| Swift | 5.9+ (Xcode 15+) |
| Xcode | 15.0+ |
| Windows (desktop C++) | Visual Studio 2022 + CMake 3.14+ |
| Linux (desktop C++) | GCC/Clang + CMake 3.10+ |
| Web (WASM) | Emscripten SDK (`emcc` on PATH) — only for `web: WebNativeImpl.wasm` |

---

## Quick Start

### 1. Scaffold a plugin

```sh
nitrogen init --name math
# Scaffolds the Flutter FFI plugin `math`: starter spec (lib/src/math.native.dart),
# Kotlin + Swift impl files, CMake/Podspec wiring. Edit that spec in place.
```

### 2. Define your API in a `.native.dart` spec

```dart
// lib/src/math.native.dart
import 'package:nitro/nitro.dart';
import 'math.platform.g.dart'; // generated: createMathInstance, ensureMathReady
part 'math.g.dart';

// One spec, every target. Omit a platform to skip it.
@NitroModule(
  lib: 'math',
  ios: AppleNativeImpl.swift,        // or AppleNativeImpl.cpp
  macos: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin, // or AndroidNativeImpl.cpp
  windows: WindowsNativeImpl.cpp,
  linux: LinuxNativeImpl.cpp,
  web: WebNativeImpl.wasm,           // C++ built with Emscripten
)
abstract class Math extends HybridObject {
  // `_MathImpl()` exists only in native-only specs; with `web:` the instance
  // comes from the platform shim.
  static final Math instance = createMathInstance();

  double add(double a, double b);
  String greet(String name);
  int get precision;
  set precision(int value);
}
```

### 3. Generate native bindings

```sh
nitrogen generate
# Runs build_runner, then copies the Swift bridge into ios/Classes and macos/Classes.
# Android, Windows, Linux and web build straight from lib/src/generated/.
```

### 4. Implement on each platform

**Kotlin (`android/src/main/kotlin/com/example/math/MathImpl.kt`):**
```kotlin
package com.example.math

import nitro.math_module.HybridMathSpec

class MathImpl : HybridMathSpec {
    override fun add(a: Double, b: Double): Double = a + b
    override fun greet(name: String): String = "Hello, $name"
    override var precision: Long = 6
}
```

**Swift (`ios/Classes/MathModuleImpl.swift`, the scaffolded file — `nitrogen link` registers `MathModuleImpl`):**
```swift
import Foundation

class MathModuleImpl: NSObject, HybridMathProtocol {
    func add(a: Double, b: Double) -> Double { a + b }
    func greet(name: String) -> String { "Hello, \(name)" }
    var precision: Int64 = 6
}
```

**C++ (`src/HybridMath.cpp` for macOS-C++ and web; `windows/src/HybridMath.cpp` and `linux/src/HybridMath.cpp` are the desktop copies init seeds):**
```cpp
#include "math.native.g.h"

class HybridMathImpl final : public HybridMath {
    double add(double a, double b) override { return a + b; }
    std::string greet(const std::string& name) override { return "Hello, " + name; }
    int64_t get_precision() const override { return _precision; }
    void set_precision(int64_t v) override { _precision = v; }
    int64_t _precision = 6;
};

static HybridMathImpl g_math_impl;
static struct _RegisterMath { _RegisterMath() { math_register_impl(&g_math_impl); } } _registerMath;
```
`nitrogen generate` also drops an editable starter with every TODO at `lib/src/generated/cpp/math.impl.g.cpp` (never overwritten). Web compiles the same file with Emscripten via `web/build_web.sh`.

### 5. Wire the build system

```sh
nitrogen link    # wires CMake, Podspec, .clangd
nitrogen doctor  # health-check every layer
```

### 6. Use from Dart

```dart
final sum = Math.instance.add(3.14, 2.71);
print(Math.instance.greet('World')); // "Hello, World"
```

### Or: the interactive dashboard

Running `nitrogen` with no arguments launches a TUI dashboard covering every command above (`init`, `generate`, `watch`, `link`, `doctor`, `migrate`, `clean`, `update`) with live progress, plus one-click **Open in VS Code** / **Open in Antigravity** buttons:

![Nitrogen Dashboard](https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/images/nitro_cli.png)

Every command also works headlessly for CI — pass `--no-ui`, or just pipe the output (non-TTY auto-detects and switches to plain-text `[nitro]`/`[nitro:warn]`/`[nitro:error]` logging):

```sh
nitrogen generate --no-ui --fail-on-warn   # exit 2 on spec warnings
nitrogen doctor --no-ui                    # exit 1 on any health-check error
```

---

## Implementation Paths

| Platform field | Constant | Bridge | When to use |
|---|---|---|---|
| `ios:` / `macos:` | `AppleNativeImpl.swift` | Swift `@_cdecl` | iOS/macOS platform APIs |
| `ios:` / `macos:` | `AppleNativeImpl.cpp` | Direct C++ | Shared C++ logic |
| `android:` | `AndroidNativeImpl.kotlin` | Kotlin JNI | Android platform APIs |
| `android:` | `AndroidNativeImpl.cpp` | Direct C++ | Shared C++ logic |
| `windows:` | `WindowsNativeImpl.cpp` | Direct C++ | Windows desktop |
| `linux:` | `LinuxNativeImpl.cpp` | Direct C++ | Linux desktop |
| `web:` | `WebNativeImpl.wasm` | WASM/JS interop | Web |

`NativeImpl.swift`, `.kotlin`, `.cpp`, `.wasm` are backward-compatible shorthands. The explicit per-platform constants catch invalid combinations (e.g. Kotlin on macOS) at compile time.

Web compiles the same C++ impl as the native C++ targets by default. `nitrogen link` also seeds `web/src/Hybrid<Class>.cpp` from the generated starter — every method with its signature, plus wasm self-registration. Implement it, delete its `TODO: implement all pure-virtual methods` line, and re-run `nitrogen link`: that module's WASM is then built from it instead. While the line is there the file is inert, so existing plugins are unaffected.

### Direct C++ path

When both `ios:` and `android:` use `*NativeImpl.cpp`, a single C++ class serves all platforms with no JNI or Swift shim:

```dart
@NitroModule(
  lib: 'math',
  ios: AppleNativeImpl.cpp,
  android: AndroidNativeImpl.cpp,
  macos: AppleNativeImpl.cpp,
  windows: WindowsNativeImpl.cpp,
  linux: LinuxNativeImpl.cpp,
)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();
  double add(double a, double b);
}
```

After `nitrogen generate`, subclass the abstract C++ interface:

```cpp
// src/HybridMathImpl.cpp  (you write this)
#include "math.native.g.h"

class HybridMathImpl : public HybridMath {
public:
    double add(double a, double b) override { return a + b; }
};

static HybridMathImpl g_math;
__attribute__((constructor))
static void math_auto_register() { math_register_impl(&g_math); }
```

---

## All Annotations

### Reference: what each annotation does, when to use it

| Annotation | Target | Does | Use when |
|---|---|---|---|
| `@NitroModule(ios:, android:, macos:, windows:, linux:, web:, lib:)` | class | Declares the bridge class and the implementation language per platform | Always; one per `HybridObject` class |
| `@HybridEnum(startValue:, nativeValues:)` | enum | Crosses as an int; `startValue` offsets contiguous codes, `nativeValues` maps non-contiguous ones | Fixed value sets |
| `@HybridStruct` | class | Fixed-layout POD, zero-copy over FFI; numeric fields only | Small numeric records on hot paths |
| `@HybridRecord` | class | Binary-encoded object; nested records, lists, maps, strings, nullables | General DTOs a struct cannot express |
| `@NitroVariant` | sealed class | Tagged union (one byte tag + fields) | Events/states with alternatives |
| `@NitroTuple` | typedef record | `(int, String)`-style record crosses as a record | Positional pairs without a class |
| `@NitroCustomType(codec:, encodedSize:)` | class | User codec (`NitroFfiCodec` / `NitroWireCodec`) | Types outside the built-in set |
| `@nitroFast` | sync method, or `@nitroNativeAsync` method | `isLeaf` binding, bare body, no error-slot check, no diagnostics; ~13 ns/call; on a `@nitroNativeAsync` method: `Future<T>` completed inline from a sync native impl, no port (0.18 µs vs 16 µs); declare `FutureOr<T>` and the value comes back with no Future at all (0.018 µs) | Per-token/per-byte loops; native never throws, blocks or calls back |
| `@nitroAsync` / `@NitroAsync(timeout:)` | method | The sync export (Kotlin, Swift or C++) runs on the bridge's worker pool and completes through the shared completion port (~24 µs). A `timeout:`, struct/nullable-primitive returns and callback parameters use the isolate pool instead (~28 µs) | Native work that blocks (>50 µs) and must stay off the UI isolate |
| `@nitroNativeAsync` | method | Native runs on its own thread and posts the result to the library's shared completion port; no isolate; ~12 µs alone, ~2 µs per call in a burst. `FutureOr<T>` returns the bridge future without an `async` wrapper | Native APIs that are already asynchronous (completion handlers); add `@nitroFast` when the answer is ready at call time |
| `@mainThread` | method | Kotlin/Swift impl runs on the platform main thread; no effect on C++ | UIKit / Android View APIs; pair with an async annotation |
| `@NitroStream(backpressure:)` | `Stream<T>` getter/method | Native → Dart events, coalesced by the bridge on every backend: items that arrive while Dart is busy travel in one message, in order, none dropped. The mode (`dropLatest`, `block`, `bufferDrop`, `batch`) shapes the Kotlin/Swift producer's buffer | Push data; `batch` when the producer should not buffer at all |
| `@zeroCopy` | typed-data param/return | Borrowed buffer, no copy | Large buffers (frames, audio, files) |
| `@NitroOwned(release:)` | `NativeHandle` return | Handle freed by a finalizer (`free` or a custom release) | Opaque native objects Dart owns |
| `@NitroResult` | method | Returns `NitroResultValue<T>` instead of throwing | Expected failures on hot paths |
| `@NitroEntryPoint` | top-level function | Runnable in a headless engine (Android/iOS) or spawned isolate; native-initiated jobs | Background work, WorkManager/BGTask, app-killed scenarios |

Choosing: plain sync method by default; `@nitroFast` when a profiler shows the
call itself; `@nitroNativeAsync` when native is asynchronous anyway;
`@nitroAsync` only when native blocks; `@NitroStream` for push; `@NitroResult`
when failure is a normal outcome.

### `@NitroModule` — define your native API

```dart
@NitroModule(
  lib: 'camera',             // shared library name
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  macos: AppleNativeImpl.cpp,
  windows: WindowsNativeImpl.cpp,
  linux: LinuxNativeImpl.cpp,
  web: WebNativeImpl.wasm,   // compiles the C++ impl to WASM
)
abstract class Camera extends HybridObject {
  static final Camera instance = createCameraInstance(); // from camera.platform.g.dart
  bool isAvailable();
}
```

Every platform is optional — declare only the ones you ship.

> **Targeting web?** Two things differ from a native-only spec (where
> `static final Camera instance = _CameraImpl();` works). The instance comes from
> the generated platform shim, and the WASM module must be loaded before first use:
>
> ```dart
> import 'camera.platform.g.dart';                  // createCameraInstance, ensureCameraReady
>
> static final Camera instance = createCameraInstance();
>
> await ensureCameraReady();   // no-op on native; loads the .wasm on web
> ```
>
> See [migration/0.7.0.md](migration/0.7.0.md) for the full web setup.

### `@HybridEnum` — enum at the C boundary

Maps a Dart enum to `int64_t`. Values are contiguous from `startValue` by default; use `nativeValues` for non-contiguous OS enums.

```dart
@HybridEnum(startValue: 0)
enum DeviceStatus { idle, busy, error }

// Non-contiguous (e.g. mirror an OS SDK enum with gaps):
@HybridEnum(nativeValues: [0, 50, 100])
enum Quality { low, medium, high }
```

### `@HybridStruct` — zero-copy C struct

Passes all fields as a packed C struct across the FFI boundary in a single call. Best for hot-path numeric data (frames, sensor readings). Fields may be `int`, `double`, `bool`, `DateTime`, `String`, TypedData, a `@HybridEnum`, or another `@HybridStruct` — and any of them may be nullable.

```dart
@HybridStruct(packed: true)
class SensorReading {
  final double temperature;
  final double humidity;
  final int timestampMs;
  const SensorReading({required this.temperature, required this.humidity, required this.timestampMs});
}
```

> **Note:** `String` fields in a `@HybridStruct` cost ~100–500 ns each (heap copy via `strdup`). If your struct carries string fields used frequently, prefer `@HybridRecord`.

> **Nullable fields:** a pointer-shaped field (`String?`, TypedData, nested struct) encodes absence as `nullptr`. A nullable scalar or enum has no spare bit, so it gains a synthesized `int8_t <field>HasValue` byte in the C struct — the same convention as the `NitroOptInt64`/`Float64`/`Bool` parameter wrappers. Structs without nullable scalars are unaffected.

### `@HybridRecord` — binary-encoded complex data

For infrequent, complex transfers (device lists, configs, API responses). Supports strings, nested records, lists, and nullable fields — encoded as a compact little-endian binary protocol (no JSON).

```dart
@HybridRecord()
class UserProfile {
  final String name;
  final int age;
  final List<String> tags;
  const UserProfile({required this.name, required this.age, required this.tags});
}

// Wire format (little-endian):
// [4B payload_len][4B utf8_len][utf8_bytes][8B int64][4B count][...]
```

### `@NitroVariant` — discriminated union (sealed class)

Marks a sealed class as a tagged union. Each concrete subclass is one variant case. Cases with fields encode them using the `@HybridRecord` binary codec.

```dart
@NitroVariant()
sealed class FilterResult { const FilterResult(); }

class FilterAccepted extends FilterResult {
  final String id;
  const FilterAccepted({required this.id});
}
class FilterRejected extends FilterResult { const FilterRejected(); }

// Usage:
final result = await filter.apply(input);
switch (result) {
  case FilterAccepted(:final id): print('accepted: $id');
  case FilterRejected(): print('rejected');
}
```

> **Limit:** `@NitroVariant` supports up to 255 cases. Exceeding this is rejected at generation time.

### `@NitroTuple` — named positional record type

Annotate a Dart 3 positional record `typedef`. Fields are accessed via `$1`, `$2`, etc. in Dart; Kotlin gets a `data class` and Swift a `struct`.

```dart
@NitroTuple()
typedef Point2D = (double, double);

@NitroTuple()
typedef NamedPair = (String, int);

@NitroModule(lib: 'geometry', ios: AppleNativeImpl.cpp, android: AndroidNativeImpl.cpp)
abstract class Geometry extends HybridObject {
  static final Geometry instance = _GeometryImpl();
  @nitroAsync // a record returned synchronously is allowed but warns (SYNC_RECORD_RETURN)
  Future<Point2D> midpoint(Point2D a, Point2D b);
}

// Usage:
final mid = await Geometry.instance.midpoint((1.0, 2.0), (3.0, 4.0));
print('${mid.$1}, ${mid.$2}'); // "2.0, 3.0"
```


### `@NitroEntryPoint` — run Dart in the background from native

Marks a top-level function in the spec file. Generated per entry:
`run<Name>InBackground(...)` (same signature; `Future<T>` or `Stream<T>`), a
`@pragma('vm:entry-point')` wrapper, `has<Class>BackgroundHost()`,
`active<Class>BackgroundJobs()`.

```dart
// SyncReport and Account are @HybridRecord types of the same spec.
@nitroEntryPoint
Future<SyncReport> syncInbox(Account account, {int retries = 3}) async { /* any Dart */ }
```

- Arguments/results: any record-wire type in any parameter shape (records,
  structs, variants, tuples, enums, lists, `String`/`int`/enum-keyed maps,
  typed data, `DateTime`, `NitroAnyMap`, `@NitroCustomType`); `NativeHandle`,
  `Pointer` and `AnyNativeObject` cross by address/id (same process, caller
  keeps ownership); `void` callbacks with positional parameters become proxies
  — every call is posted back to the submitting isolate and runs there.
  Shapes: sync, `Future<T>`, `Stream<T>` (cancel stops the producer), `void`.
- Errors: `NitroBackgroundException` (a `HybridException`) with `entry`,
  `message`, remote `stackTrace`, `isStartFailure`.
- Each job runs in its own isolate. Android/iOS spawn engines from one
  `FlutterEngineGroup` per library; the job id is the entrypoint argument, so
  an engine runs exactly the job it was started for and is destroyed when it
  finishes. Concurrent jobs run in parallel; a failure tears down only its own
  engine.

Native-initiated (no Dart submitter; entry takes one `String`, persists its
result):

```kotlin
FooJniBridge.runInBackground(context, "syncInbox", accountId) { jobId, error -> … }
val error = FooJniBridge.runInBackgroundAndWait(context, "syncInbox", accountId, timeoutMs = 60_000) // worker thread only
```

```swift
FooBackground.run(entry: "syncInbox", text: accountId) { jobId, error in … }
let error = await FooBackground.run(entry: "syncInbox", text: accountId)
```

| Platform | Dart-initiated | Native-initiated | App killed |
|---|---|---|---|
| Android | headless engine | receiver / service / WorkManager | yes — OS starts the process |
| iOS | headless engine | URL scheme, BGTaskScheduler, silent push | yes when iOS launches the app; not after a user swipe-kill |
| macOS, Linux, Windows, C++-only | spawned isolate | no | — |
| Web | `UnsupportedError` | no | — |

Limits: native-initiated entries take exactly one `String` and their return
value is dropped; an Android receiver returns before the job ends (use
`runInBackgroundAndWait` in a worker for long jobs); iOS does not extend the
background window; `runInBackgroundAndWait` must not run on the main thread.
Failures are logged (`Nitro` tag / `NSLog`).

### `@nitroAsync` — background-thread dispatch

Offloads a synchronous native call to Nitrogen's pre-warmed isolate pool and returns a `Future`. Overhead: **~28 µs** on macOS (persistent-worker isolate dispatch — roughly at parity with a method channel round-trip; see [Performance](#performance)).

```dart
@nitroAsync
Future<String> processImage(String path);

// With timeout:
@NitroAsync(timeout: 5000)
@zeroCopy // a naked TypedData return is rejected (INVALID_RETURN_TYPE)
Future<Uint8List> fetchData(String url);
```

### `@nitroNativeAsync` — zero-hop native async

The native side runs its own async work (Swift `async/await`, Kotlin coroutine, C++ thread pool) and calls `Dart_PostCObject_DL` to post the result directly. Dart opens a `ReceivePort` and awaits it — no Dart isolate is spawned. Overhead: **~27 µs** on macOS — no isolate hop, so no dispatch overhead beyond the native call itself.

```dart
@nitroNativeAsync
Future<String> fetchDataNative(String url);

@nitroNativeAsync
Future<int> heavyComputation(int n);
```

**Swift implementation** — the generated protocol method is `async throws`; the bridge posts the result:
```swift
func fetchDataNative(url: String) async throws -> String {
    let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
    return String(decoding: data, as: UTF8.self)
}
```

**Kotlin implementation** — a `suspend fun`; the bridge launches it and posts the result:
```kotlin
override suspend fun fetchDataNative(url: String): String = httpClient.get(url).bodyAsText()
```

> **Use `@nitroNativeAsync` when:** the native side already has async infrastructure (coroutines, Swift async, thread pool) — it skips the isolate hop entirely. `@nitroAsync` exists for the opposite case: a blocking native call with no async infrastructure of its own, dispatched off the main isolate via a persistent worker pool.

### `@NitroStream` — native-to-Dart event stream

Configures a native-to-Dart event stream with built-in backpressure. The native side emits items from any thread; Dart receives them as a typed `Stream<T>`.

```dart
@NitroStream(backpressure: Backpressure.dropLatest)
Stream<SensorReading> get sensorStream;

@NitroStream(backpressure: Backpressure.batch, batchMaxSize: 64)
Stream<double> get audioSamples;
```

**Backpressure strategies:**

| Strategy | Behaviour | When to use |
|---|---|---|
| `Backpressure.dropLatest` | Kotlin/Swift: the producer's buffer keeps the newest item when the bridge is behind | Camera frames, sensors — stale data is useless |
| `Backpressure.bufferDrop` | Kotlin/Swift: ring buffer of `batchMaxSize`, oldest dropped when full | Logging, monitoring — prefer recent, tolerate loss |
| `Backpressure.block` | Kotlin/Swift: the producer suspends while its buffer is full | Reliable delivery, emitter is interruptible |
| `Backpressure.batch` | No producer-side buffer; every item goes straight to the bridge | High-frequency primitives (IMU, audio samples); bursts of structs or records |

Since 0.7.7 every stream is delivered through the library's completion batcher: items native emits while Dart is still handling the previous message travel together in the next one, in order, none dropped. The mode shapes only the Kotlin/Swift side, where the producer's `Flow`/Combine buffer applies it before the item reaches the bridge; C++ producers deliver every item.

#### Zero-copy proxy streaming for `@HybridStruct` items

When a `@NitroStream` item type is a `@HybridStruct`, the generator emits a **proxy class** that extends the value type and reads every field lazily from native heap memory — no fields are copied until accessed, and a `NativeFinalizer` frees the native struct automatically on GC:

```dart
// Declared type is unchanged — Stream<SensorReading>, not some proxy type.
sensorModule.sensorStream.listen((reading) {
  // reading is SensorReadingProxy at runtime (IS-A SensorReading).
  // Reading a field is a single native-heap load — zero allocation.
  print(reading.temperature); // → native heap load, no copy, no malloc

  // Need an immutable copy that outlives this callback?
  final snapshot = (reading as SensorReadingProxy).toDartAndRelease();
});
```

| Approach | Field read | Allocation per item | Memory management |
|---|---|---|---|
| Eager `.toDart()` on arrival | All fields copied upfront | 1 Dart object | Manual `malloc.free` in unpack |
| **Zero-copy proxy (default)** | **Lazy — only accessed fields** | **0 extra allocations** | **`NativeFinalizer` on GC** |

### `@NitroResult` — method-level error return

The native implementation signals failure by returning an error tag + message instead of throwing. Dart receives `NitroResultValue<T>` (either `NitroOk<T>` or `NitroErr`) — exception-free error handling.

```dart
@NitroResult()
@nitroAsync // @NitroResult cannot combine with @nitroNativeAsync (E015)
Future<NitroResultValue<String>> login(String user, String password);

// Dart usage — no try/catch needed:
final result = await auth.login('alice', 'secret');
switch (result) {
  case NitroOk(:final value): print('token: $value');
  case NitroErr(:final message): print('failed: $message');
}
```

### `@zeroCopy` — zero-copy buffer parameter

Marks a `Uint8List` parameter as a raw native pointer. The callee must **not retain** the pointer past the function call — it points to pinned Dart memory.

```dart
void processPixels(@zeroCopy Uint8List pixels);
// C symbol: void <lib>_process_pixels(int64_t instanceId, uint8_t* pixels, size_t pixels_length, NitroError*)
// C++ impl: void processPixels(const uint8_t* pixels, size_t pixels_length)
// Kotlin:   fun processPixels(pixels: ByteBuffer)
// Swift:    func processPixels(pixels: Data)
```

### `@NitroOwned` — native heap pointer with auto-release

The native side heap-allocates a resource and Dart takes ownership. A `NativeFinalizer` calls the generated `_release` C symbol when the `NativeHandle` is GC'd.

```dart
@NitroOwned()
NativeHandle<Void> acquireFrame();

// Usage:
final frame = camera.acquireFrame();
// frame is automatically released when GC'd.
// Or release eagerly:
frame.release();
```

### `@NitroCustomType` — user-defined FFI codec

Registers a Dart class as a custom bridge type with a user-provided `NitroFfiCodec`. The generator emits `codec.encode()` / `codec.decode()` calls wherever the type appears in a spec. Native implementations receive raw bytes.

```dart
class ColorCodec extends NitroFfiCodec<Color> {
  const ColorCodec();
  @override int get encodedSize => 5; // 1B hasValue + 4B RGBA
  @override Pointer<Uint8> encode(Color? v, Arena alloc) {
    final p = alloc<Uint8>(5);
    p[0] = v != null ? 1 : 0;
    if (v != null) { p[1] = v.r; p[2] = v.g; p[3] = v.b; p[4] = v.a; }
    return p;
  }
  @override Color? decode(Pointer<Uint8> ptr) {
    if (ptr[0] == 0) return null;
    return Color(ptr[1], ptr[2], ptr[3], ptr[4]);
  }
}

@NitroCustomType(codec: ColorCodec, encodedSize: 5)
class Color {
  final int r, g, b, a;
  const Color(this.r, this.g, this.b, this.a);
}
```

---

## Complete Type Support

### Primitive scalars

| Dart | C | Kotlin | Swift |
|---|---|---|---|
| `int` | `int64_t` | `Long` | `Int64` |
| `double` | `double` | `Double` | `Double` |
| `bool` | `int8_t` | `Boolean` | `Bool` |
| `String` | `const char*` / `std::string` | `String` | `String` |
| `void` | `void` | `Unit` | `Void` |
| `DateTime` | `int64_t` (ms since epoch) | `Long` | `Date` |

**Sized numerics** — use these when the native side needs an exact width:

| Dart | C | Kotlin | Swift |
|---|---|---|---|
| `int8` / `int16` / `int32` | `int8_t` / `int16_t` / `int32_t` | `Byte` / `Short` / `Int` | `Int8` / `Int16` / `Int32` |
| `uint8` / `uint16` / `uint32` | `uint8_t` / `uint16_t` / `uint32_t` | `Byte` / `Short` / `Int` | `UInt8` / `UInt16` / `UInt32` |
| `uint64` | `uint64_t` | `Long` (same bits) | `UInt64` |
| `float` | `float` | `Float` | `Float` |
| `intptr` / `size` | `intptr_t` / `size_t` | `Long` | `Int` |

All are plain `int`/`double` in Dart — the alias only pins the C width.

### Nullable primitives

Nullable primitives are bridged using `@Packed(1)` structs — the same in-memory layout as C++ `std::optional<T>`. No sentinels, no heap allocation on sync paths.

| Dart | C struct | Wire size |
|---|---|---|
| `int?` | `NitroOptInt64 { uint8_t hasValue; int64_t value; }` | 9 bytes |
| `double?` | `NitroOptFloat64 { uint8_t hasValue; double value; }` | 9 bytes |
| `bool?` | `NitroOptBool { uint8_t hasValue; uint8_t value; }` | 2 bytes |
| `String?` | `const char*` (null pointer = absent) | pointer |

> **Note:** `int?`, `double?`, and `bool?` inside callback parameters use sentinel values (not `NitroOptXxx` structs) because `NativeCallable` function pointers have no `Arena` available. Full-range nullable prim callbacks should wrap params in a `@HybridRecord`.

### TypedData buffers

All variants are supported: `Uint8List`, `Int8List`, `Int16List`, `Uint16List`, `Int32List`, `Uint32List`, `Int64List`, `Uint64List`, `Float32List`, `Float64List`.

Each TypedData param expands to `(pointer + length)` at the C boundary:

```dart
// Dart spec:
void processAudio(Float32List samples);
// C++ impl: void processAudio(const float* samples, size_t samples_length)
// Kotlin:   fun processAudio(samples: FloatArray)
// Swift:    func processAudio(samples: [Float])
```

### Collections

| Dart | Encoding |
|---|---|
| `List<int>` / `List<double>` / `List<bool>` / `List<String>` | `@HybridRecord` binary codec |
| `List<@HybridRecord>` | Indexed binary blob (`LazyRecordList<T>` — O(1) random access) |
| `List<@HybridEnum>` | `@HybridRecord` binary codec |
| `List<@NitroVariant>` | `@HybridRecord` binary codec |
| `Map<String, T>` | Binary, one type tag per value |
| `Map<String, T?>` | Same wire; null is tag 0 (`int`/`double`/`bool`/`String` values) |
| `Map<int, T>` / `Map<intN, T>` | Binary, fixed-width keys, **untagged** values |
| `Map<@HybridEnum, T>` | Binary, enum raw value as the key |
| `Map<String, @HybridRecord>` | Binary tag-5 blob |
| `Map<String, @NitroVariant>` | Binary tag-5 blob |

### Custom types

| Annotation | C type | Use case |
|---|---|---|
| `@HybridEnum` | `int64_t` | Enum constants |
| `@HybridStruct` | `void*` (packed struct) | Hot-path numeric structs |
| `@HybridRecord` | `uint8_t*` (binary blob) | Complex / infrequent data |
| `@NitroVariant` | `uint8_t*` (tag + payload) | Discriminated unions |
| `@NitroTuple` | `uint8_t*` (binary blob) | Named positional record |
| `@NitroCustomType` | `uint8_t*` (codec bytes) | Any user-defined type |
| `NativeHandle<Void>` | `void*` | Opaque pointer with auto-release |

### Special runtime types

| Type | Description |
|---|---|
| `AnyNativeObject` | Opaque native object handle (pointer stored as `int64`) |
| `NitroAnyValue` | Dynamic variant: null / bool / int / double / String / List / Map |
| `NitroAnyMap` | String-keyed map class of `NitroAnyValue` entries with typed getters/setters — equivalent to a JSON object |
| `NitroPromise<T>` | Dart-side future that a native side can resolve/reject; wraps a `ReceivePort` |

---

## Default Parameter Values

Named parameters with default values are preserved in generated Dart FFI bindings — callers get the default, no wrapper needed:

```dart
@HybridEnum()
enum PrintQuality { draft, normal, high }

abstract class Printer extends HybridObject {
  void print(String text, {PrintQuality quality = PrintQuality.normal, int copies = 1});
}
```

Generated Dart FFI (callers see the defaults):
```dart
void print(String text, {PrintQuality quality = PrintQuality.normal, int copies = 1}) { ... }
```

Supported default literal types: `int`, `double`, `bool`, `String`, `@HybridEnum`.

---

## Cross-File Type Sharing

Types defined in one `.native.dart` can be imported and used in another. The generator tracks ownership and emits correct `#include` directives:

```dart
// types.native.dart  ← type-only file (no @NitroModule)
import 'package:nitro/nitro.dart';
part 'types.g.dart';

@HybridEnum()
enum DeviceStatus { idle, busy, error }

@HybridRecord()
class DeviceInfo {
  final String name;
  final DeviceStatus status;
  const DeviceInfo({required this.name, required this.status});
}
```

```dart
// scanner.native.dart
import 'package:nitro/nitro.dart';
import 'types.native.dart';  // import shared types
part 'scanner.g.dart';

@NitroModule(lib: 'scanner', ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class Scanner extends HybridObject {
  static final Scanner instance = _ScannerImpl();
  @nitroAsync
  Future<List<DeviceInfo>> scanDevices();
}
```

---

## Error Handling

### Exceptions from native

All bridge paths catch native errors and rethrow as `HybridException`:

```dart
try {
  await myModule.doWork();
} on HybridException catch (e) {
  print('Native error: ${e.message}');
}
```

- **Kotlin/JNI path**: Java `Exception` → `HybridException`
- **Swift path**: Swift `Error` + `NSException` → `HybridException`
- **C++ direct path**: `std::exception` → `nitro_report_error()` → `HybridException`

### Exception-free error results (`@NitroResult`)

For fallible operations that should not throw, `@NitroResult()` gives you a typed result:

```dart
@NitroResult()
@nitroAsync
Future<NitroResultValue<UserProfile>> fetchUser(String id);

// Dart switch is exhaustive — no uncaught exceptions:
final r = await api.fetchUser('123');
switch (r) {
  case NitroOk(:final value): useProfile(value);
  case NitroErr(:final message): showError(message);
}
```

---

## NitroAnyValue / NitroAnyMap

`NitroAnyValue` is a dynamic variant type. It bridges arbitrary JSON-like data without a schema:

```dart
// Spec:
NitroAnyMap getMetadata(String key);

// Dart usage:
final meta = module.getMetadata('config');
final name = meta.getString('name');   // String?
final count = meta.getInt('count');    // int?
```

Use `NitroAnyMap` (a class wrapping a string-keyed map of `NitroAnyValue` entries, with typed getters/setters like `getString` / `setInt` and `NitroAnyMap.fromDynamic` / `toDynamic` conversions) when the native side returns a dictionary with mixed value types. Prefer `@HybridRecord` when the schema is known — it is significantly faster.

---

## Performance

### Call latency (OnePlus CPH2447, Android 16, profile build, medians, device cooled below 46 °C)

| Bridge | Latency | vs Method Channel |
|---|---|---|
| Method Channel | 122.8 µs | 1.0× |
| **Nitrogen `@nitroFast`** | 0.023 µs | 5,434× |
| **Nitrogen (Direct C++, checked)** | 0.050 µs | 2,456× |
| **Nitrogen (Kotlin/JNI, checked)** | 1.2 µs | 105.5× |
| `@nitroAsync` (bridge dispatch) | 115.5 µs | 1.1× |
| `@nitroAsync` (isolate pool) | 127.2 µs | 1.0× |
| `@nitroNativeAsync`, same-thread post | 34.1 µs | 3.6× |
| `@nitroNativeAsync`, cross-thread post | 122.1 µs | 1.0× |
| `@nitroFast @nitroNativeAsync`, `FutureOr<int>` | 0.030 µs | 4,093× |

Sync calls on the phone sit within 1–2× of the raw `dart:ffi` floor (0.040 µs).
Anything that wakes a sleeping thread pays this phone's scheduler latency,
~115–125 µs per hop, the same order as a MethodChannel round-trip; bridge
dispatch and the isolate pool land on the same floor. Measure with the phone
cool: throttled (prime core at 0.86 GHz, thermal status 1) the cross-thread
cases read 2–3× higher and swing between runs. Batching is what moves the
needle on a device: a 256-item `Stream<int>` burst is 5,703 µs posted per item,
368 µs with `Backpressure.batch`.

### Call latency (iPhone 12, iOS 26.6, profile build, medians)

| Bridge | Latency | vs Method Channel |
|---|---|---|
| Method Channel | 24.6 µs | 1.0× |
| **Nitrogen `@nitroFast`** | 0.044 µs | 564× |
| **Nitrogen (Direct C++, checked)** | 0.052 µs | 473× |
| **Nitrogen (Swift, checked)** | 0.052 µs | 473× |
| `@nitroAsync` (bridge dispatch) | 29.2 µs | 0.8× |
| `@nitroNativeAsync`, same-thread post | 12.4 µs | 2.0× |
| `@nitroNativeAsync`, cross-thread post | 29.1 µs | 0.8× |
| `@nitroFast @nitroNativeAsync`, `FutureOr<int>` | 0.014 µs | 1,759× |

Cross-thread completions cost ~29 µs on the phone, the same as a MethodChannel
hop; a 256-item `Stream<int>` burst is 1,328 µs posted per item, 122 µs with
`Backpressure.batch`.

### Call latency (macOS, Apple Silicon, profile build)

Measured against a raw `dart:ffi` leaf call as the theoretical floor — the entire delta is codegen safety (instance registry, error slot, typed marshalling), not JIT/AOT noise:

| Bridge | Latency | vs raw FFI | vs Method Channel |
|---|---|---|---|
| Raw FFI (leaf) | 0.008 µs | 1.0× (floor) | 3300× faster |
| **Nitrogen `@nitroFast`** | **0.014 µs** | 1.7× | **1900× faster** |
| **Nitrogen (Direct C++, checked)** | **0.027 µs** | 3.4× | **990× faster** |
| **Nitrogen (Swift, checked)** | **0.032 µs** | 4.0× | **830× faster** |
| Method Channel | 26.7 µs | 3300× | 1× |

At 60 fps, that's **~600,000** checked Nitrogen calls per frame budget vs **~625** for a method channel — three orders of magnitude more headroom for per-frame native work (sensors, codecs, game state).

### Async overhead (macOS, `computeStats`/`computeStatsNative` benchmark cases)

| Annotation | Latency | vs Method Channel | Mechanism |
|---|---|---|---|
| Method Channel | 26.8 µs | 1× | — |
| `@nitroAsync` | ~24 µs | ~0.9× | Bridge worker pool + shared completion port, no isolate (any backend) |
| `@NitroAsync(timeout:)` | ~28 µs | ~1.05× | Persistent-worker isolate pool dispatch |
| `@nitroNativeAsync` | ~25 µs | ~0.9× | Native post to the shared completion port, no isolate hop |

`@nitroAsync` no longer touches an isolate: a generated `<sym>_dispatch` twin runs the sync export (JNI, Swift shim or C++) on the bridge's worker pool and posts the result. The isolate pool remains for `timeout:` and a few return kinds; it uses a persistent reply port and least-busy worker scheduling; its overhead is the isolate message round-trip. Every completion goes through one shared port per library, so calls that finish while Dart is still busy arrive together: 64 in flight cost 133 µs instead of 1015 µs. `@nitroNativeAsync` skips that hop entirely because native already owns the async work; use it whenever the native side has its own async infrastructure (coroutines, Swift `async`, a thread pool). Use `@nitroAsync` for the opposite case — a *blocking* native call that just needs to run off the main isolate.

### High-bandwidth throughput (1 GB `@zeroCopy Uint8List`, Android)

| Bridge | Time | Throughput |
|---|---|---|
| Method Channel | ~117 ms | ~854 MB/s |
| Nitrogen (Swift/Kotlin) | ~59 ms | ~1,676 MB/s |
| Nitrogen (Direct C++) | ~8 ms | ~11,792 MB/s |

### High-bandwidth throughput (16 MiB `@zeroCopy Uint8List`, macOS)

| Bridge | Bandwidth | vs Method Channel |
|---|---|---|
| Method Channel (copies every byte) | 4,623 MB/s | 1× |
| Nitrogen pinned buffer (zero-copy) | 31,876 MB/s | **6.9× bandwidth** |

The gap is the copy itself: Method Channel always serializes the buffer; Nitrogen pins the Dart-managed memory and hands native code a direct pointer — no copy, regardless of payload size.

---

### Every way of calling through Nitro vs raw FFI (macOS, Apple Silicon, profile, min µs)

Source: `benchmark/example`, `flutter drive --profile`; same C function behind every tier. Ratios are gated in `benchmark_regression_test.dart`.

| tier | what the generated code does | µs/call | vs raw |
|---|---|---|---|
| raw `dart:ffi` (`isLeaf`) | hand-rolled lookup, floor | 0.008 | 1.0× |
| `addFast` — **Fast, bare leaf body** | direct call, no closure, no error check | 0.014 | 1.7× |
| `add` — checked | isLeaf binding, inline body between `syncStart`/`syncEnd`, error-slot check | 0.027 | 3.4× |
| raw `dart:ffi` pointer argument | hand-rolled `touch_ptr(void*)` | 0.011 | 1.0× |
| `touchHandleFast(NativeHandle)` | Fast + handle param (leaf) | 0.011 | 1.0× |
| `touchHandle(NativeHandle)` | checked, handle param (leaf since #52) | 0.019 | 1.7× |
| Swift/Kotlin platform impl (`add`) | checked, JNI/Swift shim | 0.032 | — |
| `@HybridStruct` round-trip | scratch arena + struct clone | 0.097 | — |
| `String` round-trip | scratch arena + ASCII fast path | 0.202 | — |
| `List<@HybridRecord>` round-trip | scratch `RecordWriter`, view-free copy | 0.934 | — |
| `Map<String,int>` round-trip | one-pass binary map codec, ASCII key fast path | 1.66 | — |
| `@nitroAsync` record | bridge worker pool + shared completion port | 24.1 | — |
| `@nitroNativeAsync` record | native thread + shared completion port | 23.9 | — |
| `@nitroNativeAsync` scalar | same-thread post + isolate wake | 10.9 | — |
| `@nitroFast @nitroNativeAsync` scalar — **inline completion** | sync bridge call, `Future` completed inline, no port | 0.21 | — |
| same, declared `FutureOr<int>` | value returned directly, no Future, no microtask | 0.018 | 1.5× |
| `@nitroNativeAsync` ×64 in flight | one message per Dart wake (was one per call: 978 µs) | 126 | — |
| `Stream<int>` burst ×256, `dropLatest` | coalesced by the bridge since 0.7.7 (was one message per item: 1045) | 138 | — |
| `Stream<int>` burst ×256, `batch` | coalesced by the bridge batcher | 105 | — |
| `Stream<@HybridStruct>` burst ×256, `batch` | coalesced, struct proxies (was 1212 per item) | 189 | — |
| MethodChannel `add` | codec + platform thread hop | 26.7 | — |


### Hot paths: `@nitroFast`

```dart
@nitroFast
double add(double a, double b);                  // generated: return _addPtr(_instanceId, a, b, _nitroErr);
@nitroFast
int writeByte(NativeHandle<Void> writer, int b);
```

- Binding `isLeaf: true`; body is a direct call: no `callSync` closure, no
  error-slot check, no logging/slow-call/timeline. `checkDisposed()` kept.
- Contract for native: never throw, never call back into Dart, never block.
- Scalars, enums, nullable scalars and `NativeHandle` parameters are the
  intended shapes; String/record/typed-data arguments keep the arena path.
- Handle returns never bind leaf (wrapper + finalizer allocation).
- Composes with `@nitroNativeAsync`: the Dart signature stays `Future<T>`, the
  bridge call is synchronous and the future is completed inline — no port, no
  post, no isolate wake. The native side is then a plain sync method (Kotlin
  `fun`, Swift `func`, C++ method). Measured on macOS (profile): 16.2 µs (port
  post) → 0.18 µs per call.
  ```dart
  @nitroFast
  @nitroNativeAsync
  Future<int> decodeToken(int id);   // generated: Future<int> decodeToken(int id) async { ...; return res; }
  ```
- Not allowed on `@nitroAsync`, plain `Future` or `Stream` methods (`FAST_NOT_SYNC`).
- The `...Fast` name suffix is the legacy spelling and still works.
- Measured: 175 ns → 19 ns per call (AOT), hand-rolled `isLeaf` 20 ns.

## Spec Validation

The generator validates your spec before emitting any code:

| Code | Severity | Condition |
|---|---|---|
| **E001** | Error | Unsupported `Map` key — only `String`, `int`/`intN`, and `@HybridEnum` keys are allowed |
| **E002** | Error | `@nitroAsync` on a non-`Future` return type |
| **E003** | Error | Nested `Map` return type |
| **E004** | Error | `Stream<T>` used as a property type |
| **E006** | Error | `batchMaxSize` is not > 0 |
| **E008** | Error | `Map<String, @HybridStruct>` value type (see L10) |
| **E010**–**E013** | Error | Unknown return / stream-item / property / `@HybridRecord` field type |
| **E014** | Error | `@NitroVariant` with 0 cases or more than 255 |
| **E015** | Error | `@NitroResult` combined with `@NitroNativeAsync` |
| **E016** | Error | Callback parameter on a plain `@nitroAsync` method |
| **E017** | Error | Web + `@HybridStruct` field with no wasm32 layout (record/variant/map) |
| **E018** | Error | Nullable `Map` value the wire cannot carry — use `NitroAnyMap` |
| **E020** | Error | Two `@HybridEnum` cases share a native value |
| **W001** | Warning | Non-nullable `int`/`double`/`bool` named param with no default |
| **W002** | Warning | Non-nullable `@HybridEnum` named param with no default |
| **W003** | Warning | Non-nullable `@HybridStruct` named param with no default |
| **W004** | Warning | `Stream<T>` getter without `@NitroStream` annotation |
| **W005** | Warning | `Map<String, @HybridRecord>` stream item type is not type-safe |
| **W008** | Warning | Web + `@nitroAsync` — runs inline on the main thread |
| **W009** | Warning | Web + `@zeroCopy` — one bulk copy, not a true zero-copy view |

Named codes (same severities, reported by `nitrogen generate` and `SpecValidator`):

| Code | Severity | Condition |
|------|----------|-----------|
| **NO_TARGET_PLATFORM** | Error | `@NitroModule` names no platform |
| **INVALID_MACOS_IMPL** / **INVALID_WINDOWS_IMPL** / **INVALID_LINUX_IMPL** / **INVALID_WEB_IMPL** | Error | Impl kind not supported on that platform (macOS: no Kotlin; Windows/Linux: C++ only; web: WASM only) |
| **MISSING_ANDROID_TARGET** / **MISSING_IOS_TARGET** | Warning | Only one mobile platform targeted |
| **DUPLICATE_SYMBOL** | Error | Two members map to the same C symbol |
| **INVALID_OWNED** | Error | `@NitroOwned` not on a `NativeHandle<T>` return, on `void`, on a parameter, or with a bad `release` |
| **MAIN_THREAD_NO_EFFECT** | Warning | `@mainThread` on a C++ implementation |
| **FAST_NOT_SYNC** | Error | `@nitroFast` / `Fast` suffix on a `@nitroAsync`, plain `Future` or `Stream` method (it composes with `@nitroNativeAsync`) |
| **UNSUPPORTED_FUNCTION_TYPE** | Error | Function-typed return, property, or callback parameter/return type not in the ABI |
| **INVALID_ZERO_COPY** / **INVALID_ZERO_COPY_RETURN** | Error | `@zeroCopy` on a non-TypedData field/return, or with `@NitroNativeAsync` |
| **INVALID_RETURN_TYPE** / **INVALID_PROPERTY_TYPE** / **INVALID_STRUCT_FIELD_TYPE** | Error | Naked TypedData return/property, `void` property, or unsupported struct field type |
| **SYNC_STRUCT_RETURN** / **SYNC_RECORD_RETURN** | Warning | Struct or `@HybridRecord` returned synchronously (async avoids a copy on the caller's thread) |
| **STRUCT_STRING_FIELD** | Warning | `@HybridStruct` with `String` fields (use `@HybridRecord`) |
| **CYCLIC_STRUCT** | Error | `@HybridStruct` types reference each other in a cycle |
| **ENTRY_POINT_NO_NATIVE_TARGET** | Error | `@NitroEntryPoint` in a web-only spec |
| **ENTRY_POINT_DUPLICATE** | Error | Same entry name declared twice |
| **ENTRY_POINT_UNSUPPORTED_TYPE** | Error | Entry parameter/return type with no by-value meaning: `Stream` parameter, nested `Future`, callback returning non-void or with named parameters |

Errors stop generation. Pass `--fail-on-warn` to also stop on warnings (recommended in CI).

---

## Special Notes

### `dart:isolate` no longer needed in spec files (0.5.0+)

Specs that use **callbacks** (methods with function parameters) previously required `import 'dart:isolate'` in the spec file because generated `.g.dart` part files use `ReceivePort` for the callback-release port.

As of 0.5.0, `package:nitro/nitro.dart` re-exports `ReceivePort` and `SendPort` conditionally (with a web stub). You no longer need this import:

```dart
// ❌ Before 0.5.0 — required for callback specs:
import 'dart:isolate';

// ✅ 0.5.0+ — not needed; covered by package:nitro/nitro.dart
import 'package:nitro/nitro.dart';
```

### `@HybridRecord` wire format

```
[4B payload length][fields in declaration order]

int      → 8 bytes, little-endian int64
double   → 8 bytes, IEEE 754 float64
bool     → 1 byte  (0 = false, 1 = true)
String   → [4B UTF-8 length][UTF-8 bytes]
nullable → [1B null tag][value bytes if present]
list     → [4B count][elements]
```

### Nullable primitive wire format

`int?`, `double?`, and `bool?` use `@Packed(1)` Dart FFI structs that are binary-compatible with C++ `std::optional<T>`. No heap allocation on sync paths:

```c
// Generated in C bridge header:
typedef struct __attribute__((packed)) { uint8_t hasValue; int64_t  value; } NitroOptInt64;
typedef struct __attribute__((packed)) { uint8_t hasValue; double   value; } NitroOptFloat64;
typedef struct __attribute__((packed)) { uint8_t hasValue; uint8_t  value; } NitroOptBool;
```

---

## Testing against a spec

Every bridge class gets a generated `<Class>Defaults` mixin: each spec member
with a `throw UnimplementedError('<Class>.<member>')` body. Fakes apply it so a
new spec member fails at call time, not at compile time:

```dart
class FakeEditor extends Editor with EditorDefaults {
  @override
  int wordCount(String text) => text.split(' ').length;
}
```

Works on web; the C++ twin is the generated `*.mock.g.h`.

## Known Limitations

> Upgrading? **0.7.6 requires `nitrogen generate`** — the generator version is part of the bridge checksum; 0.7.6 adds `@NitroEntryPoint` background invocation.
> See [migration/0.7.1.md](migration/0.7.1.md) (nullable struct fields, nullable map values) and [migration/0.7.0.md](migration/0.7.0.md) (web/WASM).

| ID | Limitation | Workaround |
|---|---|---|
| L6 | `@HybridStruct` and `@HybridRecord` cannot be **returned** from a callback (function parameter). Callbacks that need to return complex data should return `void` and call back via a method. | Use a method channel or reverse callback pattern |
| L7 | `TypedData?` (nullable `Uint8List`, etc.) is not supported in sync/async params or returns. The two-param C ABI (pointer + length) makes optional transport ambiguous. | Use a `@HybridRecord` wrapper: `@HybridRecord() class MaybeBuffer { final Uint8List? data; }` |
| ~~L8~~ | Resolved in 0.7.0: web is fully supported — the C++ impl compiles to WASM (Emscripten) and the generated `dart:js_interop` bridge speaks the same binary wire format, including streams and `@nitroNativeAsync`. | See [migration/0.7.0.md](migration/0.7.0.md) to add web to a plugin |
| L10 | `Map<String, @HybridStruct>` is not supported. | Use `Map<String, @HybridRecord>` instead |
| L13 | A nullable map value only works for `int`/`double`/`bool`/`String` on a String-keyed map. An int-keyed map's values carry no type tag, and enum/record/variant values are dropped rather than kept as null (E018). | Use `NitroAnyMap`, which tags every value and carries nulls |
| L12 | `@NitroVariant` callbacks (function parameters returning a variant) are not supported. | Return `void` from callback; use a reverse method call |

---

## CLI Reference

```sh
nitrogen              # no args → interactive TUI dashboard
nitrogen init    [--name <name>] [--org <id>] [--platforms <list>]
nitrogen generate [--no-ui] [--fail-on-warn] [--check] [--dry-run] [--targets <list>]
nitrogen link    [--yes] [--no-ui]
nitrogen doctor  [--no-ui]
nitrogen watch   [--no-ui]
nitrogen clean
nitrogen migrate [--dry-run] [--no-backup]
nitrogen update
nitrogen open    [--editor code|antigravity]
```

Every command accepts `--no-ui` for CI (auto-enabled when stdout isn't a TTY). See [`packages/nitrogen_cli/README.md`](packages/nitrogen_cli/README.md) for full flag documentation and CI examples.

---

## License

MIT
