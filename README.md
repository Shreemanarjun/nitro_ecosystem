# Nitrogen — Zero-overhead FFI Plugins for Flutter

Write one `.native.dart` spec file. Get type-safe Kotlin, Swift, **or C++** — all generated.

No method channels. No manual FFI. No boilerplate.

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
  nitro: ^0.5.0

dev_dependencies:
  nitro_generator: ^0.5.0
  build_runner: ^2.4.0
```

```sh
dart pub global activate nitrogen_cli  # one-time
```

---

## Quick Start

### 1. Scaffold a plugin

```sh
nitrogen init my_plugin
# Creates a fully-wired Flutter plugin with a starter spec, Kotlin impl, and Swift impl.
```

### 2. Define your API in a `.native.dart` spec

```dart
// lib/src/math.native.dart
import 'package:nitro/nitro.dart';
part 'math.g.dart';

@NitroModule(
  lib: 'math',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();

  double add(double a, double b);
  String greet(String name);
  int get precision;
  set precision(int value);
}
```

### 3. Generate native bindings

```sh
nitrogen generate
# Runs build_runner, then syncs generated files to ios/Classes/ and android/src/
```

### 4. Implement on each platform

**Kotlin (`android/.../MathImpl.kt`):**
```kotlin
class MathImpl : HybridMathSpec {
    override fun add(a: Double, b: Double): Double = a + b
    override fun greet(name: String): String = "Hello, $name"
    override var precision: Long = 6
}
```

**Swift (`ios/Classes/MathImpl.swift`):**
```swift
class MathImpl: NSObject, HybridMathProtocol {
    func add(a: Double, b: Double) -> Double { a + b }
    func greet(name: String) -> String { "Hello, \(name)" }
    var precision: Int64 = 6
}
```

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

### `@NitroModule` — define your native API

```dart
@NitroModule(
  lib: 'camera',             // shared library name
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  macos: AppleNativeImpl.cpp,
)
abstract class Camera extends HybridObject {
  static final Camera instance = _CameraImpl();
  bool isAvailable();
}
```

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

Passes all fields as a packed C struct across the FFI boundary in a single call. Best for hot-path numeric data (frames, sensor readings). Fields may be `int`, `double`, `bool`, or another `@HybridStruct`.

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
  Point2D midpoint(Point2D a, Point2D b);
}

// Usage:
final mid = Geometry.instance.midpoint((1.0, 2.0), (3.0, 4.0));
print('${mid.$1}, ${mid.$2}'); // "2.0, 3.0"
```

### `@nitroAsync` — background-thread dispatch

Offloads a synchronous native call to Nitrogen's pre-warmed isolate pool and returns a `Future`. Overhead: **~930 µs** (isolate dispatch round-trip).

```dart
@nitroAsync
Future<String> processImage(String path);

// With timeout:
@NitroAsync(timeout: 5000)
Future<Uint8List> fetchData(String url);
```

### `@nitroNativeAsync` — zero-hop native async

The native side runs its own async work (Swift `async/await`, Kotlin coroutine, C++ thread pool) and calls `Dart_PostCObject_DL` to post the result directly. Dart opens a `ReceivePort` and awaits it — no Dart isolate is spawned. Overhead: **~146 µs** (6× faster than `@nitroAsync`).

```dart
@nitroNativeAsync
Future<String> fetchDataNative(String url);

@nitroNativeAsync
Future<int> heavyComputation(int n);
```

**Swift implementation** (uses native `async`):
```swift
// Generated protocol method:
func fetchDataNative(url: String, port: Int64) {
    Task {
        let result = await URLSession.shared.dataTask(url: URL(string: url)!)
        Nitro.postString(to: port, value: String(data: result.0, encoding: .utf8)!)
    }
}
```

**Kotlin implementation** (uses coroutines):
```kotlin
override fun fetchDataNative(url: String, port: Long) {
    scope.launch {
        val result = httpClient.get(url).bodyAsText()
        NitroBridge.postString(port, result)
    }
}
```

> **Use `@nitroNativeAsync` when:** the native side already has async infrastructure (coroutines, Swift async, thread pool) and you want to avoid the ~800 µs isolate dispatch overhead.

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
| `Backpressure.dropLatest` | Drop the newest item if Dart is behind | Camera frames, sensors — stale data is useless |
| `Backpressure.bufferDrop` | Ring buffer; oldest item dropped when full | Logging, monitoring — prefer recent, tolerate loss |
| `Backpressure.block` | Block the emitter until Dart consumes | Reliable delivery, emitter is interruptible |
| `Backpressure.batch` | Accumulate up to `batchMaxSize` before one bridge crossing | High-frequency primitives (IMU, audio samples) |

### `@NitroResult` — method-level error return

The native implementation signals failure by returning an error tag + message instead of throwing. Dart receives `NitroResultValue<T>` (either `NitroOk<T>` or `NitroErr`) — exception-free error handling.

```dart
@NitroResult()
@nitroNativeAsync
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
// C: void processPixels(const uint8_t* pixels, int64_t pixels_length)
// Kotlin: fun processPixels(pixels: ByteBuffer)
// Swift: func processPixels(pixels: UnsafeMutablePointer<UInt8>?, pixelsLength: Int64)
```

### `@NitroOwned` — native heap pointer with auto-release

The native side heap-allocates a resource and Dart takes ownership. A `NativeFinalizer` calls the generated `_release` C symbol when the `NativeHandle` is GC'd.

```dart
@NitroOwned
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
// C bridge: void processAudio(const float* samples, int64_t samples_length)
// Kotlin:   fun processAudio(samples: FloatArray)
// Swift:    func processAudio(samples: UnsafeMutablePointer<Float>?, samplesLength: Int64)
```

### Collections

| Dart | Encoding |
|---|---|
| `List<int>` / `List<double>` / `List<bool>` / `List<String>` | `@HybridRecord` binary codec |
| `List<@HybridRecord>` | Indexed binary blob (`LazyRecordList<T>` — O(1) random access) |
| `List<@HybridEnum>` | `@HybridRecord` binary codec |
| `List<@NitroVariant>` | `@HybridRecord` binary codec |
| `Map<String, T>` | JSON via `dart:convert` (String key only) |
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
| `NitroAnyMap` | `Map<String, NitroAnyValue>` — equivalent to a JSON object |
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
  List<DeviceInfo> scanDevices();
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
AnyNativeObject? getMetadata(String key);

// Dart usage:
final meta = module.getMetadata('config');
if (meta is Map<String, NitroAnyValue>) {
  final name = meta['name']?.asString;
  final count = meta['count']?.asInt;
}
```

Use `NitroAnyMap` (a typedef for `Map<String, NitroAnyValue>`) when the native side returns a dictionary with mixed value types. Prefer `@HybridRecord` when the schema is known — it is significantly faster.

---

## Performance

### Call latency (OnePlus 11, Android 14, release)

| Bridge | Latency | vs Method Channel |
|---|---|---|
| Method Channel | 107.7 µs | 1× |
| **Nitrogen (Swift/Kotlin)** | **2.1 µs** | **51×** |
| **Nitrogen (Direct C++)** | **1.7 µs** | **64×** |

### Async overhead

| Annotation | Overhead | Mechanism |
|---|---|---|
| `@nitroAsync` | ~930 µs | Dart isolate pool dispatch |
| `@nitroNativeAsync` | ~146 µs | Native `Dart_PostCObject_DL` |

### High-bandwidth throughput (1 GB `@zeroCopy Uint8List`)

| Bridge | Time | Throughput |
|---|---|---|
| Method Channel | ~117 ms | ~854 MB/s |
| Nitrogen (Swift/Kotlin) | ~59 ms | ~1,676 MB/s |
| Nitrogen (Direct C++) | ~8 ms | ~11,792 MB/s |

---

## Spec Validation

The generator validates your spec before emitting any code:

| Code | Severity | Condition |
|---|---|---|
| **E001** | Error | `Map<K, V>` where `K` is not `String` |
| **E002** | Error | `@nitroAsync` on a non-`Future` return type |
| **E014** | Error | `@NitroVariant` with more than 255 cases |
| **W001** | Warning | Non-nullable `int`/`double`/`bool` named param with no default |
| **W002** | Warning | Non-nullable `@HybridEnum` named param with no default |
| **W003** | Warning | Non-nullable `@HybridStruct` named param with no default |
| **W004** | Warning | `Stream<T>` getter without `@NitroStream` annotation |

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
part 'my_spec.g.dart';
```

### `@HybridStruct` stream items use zero-copy proxies

When a `@NitroStream` item type is a `@HybridStruct`, Nitrogen generates a **proxy class** that extends the value type and reads fields lazily from native heap memory. No fields are copied until accessed:

```dart
// Stream<SensorReading> — spec type unchanged
sensorModule.sensorStream.listen((reading) {
  // reading is SensorReadingProxy at runtime — reads from native heap
  print(reading.temperature); // → native heap load, zero allocation
});

// Need a copy to outlive the current scope?
final snapshot = (reading as SensorReadingProxy).toDartAndRelease();
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

## Known Limitations

| ID | Limitation | Workaround |
|---|---|---|
| L6 | `@HybridStruct` and `@HybridRecord` cannot be **returned** from a callback (function parameter). Callbacks that need to return complex data should return `void` and call back via a method. | Use a method channel or reverse callback pattern |
| L7 | `TypedData?` (nullable `Uint8List`, etc.) is not supported in sync/async params or returns. The two-param C ABI (pointer + length) makes optional transport ambiguous. | Use a `@HybridRecord` wrapper: `@HybridRecord() class MaybeBuffer { final Uint8List? data; }` |
| L8 | Web (`WebNativeImpl.wasm`) does not support `dart:ffi`. `ReceivePort` and `SendPort` are replaced by stubs that throw `UnsupportedError`. Streams and callbacks are unavailable on web. | Use `package:nitro/nitro.dart`'s conditional re-exports; guard platform-specific code |
| L10 | `Map<String, @HybridStruct>` is not supported. | Use `Map<String, @HybridRecord>` instead |
| L12 | `@NitroVariant` callbacks (function parameters returning a variant) are not supported. | Return `void` from callback; use a reverse method call |

---

## CLI Reference

```sh
nitrogen init    [--name <name>] [--org <id>] [--platforms <list>]
nitrogen generate [--no-ui] [--fail-on-warn]
nitrogen link    [--yes] [--no-ui]
nitrogen doctor  [--no-ui]
nitrogen watch   [--no-ui]
nitrogen clean
nitrogen migrate [--dry-run] [--no-backup]
nitrogen update
```

See [`packages/nitrogen_cli/README.md`](packages/nitrogen_cli/README.md) for full flag documentation and CI examples.

---

## License

MIT
