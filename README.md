# Nitrogen — Zero-overhead FFI Plugins for Flutter

Write one `.native.dart` spec file. Get type-safe Kotlin, Swift, **or C++** — all generated.

No method channels. No manual FFI. No boilerplate.

---

## ⚡ What Nitrogen Does

Nitrogen bridges Flutter and native code with **zero overhead** and **full type-safety**. You define your API once in Dart, and the generator produces all the native plumbing automatically.

```dart
// lib/src/math.native.dart
import 'package:nitro/nitro.dart';
part 'math.g.dart';

@NitroModule(lib: 'math', ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();
  double add(double a, double b);
  String greet(String name);
  int get precision;
  set precision(int value);
}
```

Run `nitrogen generate` → get Dart FFI, a C++ abstract interface, GoogleMock test headers, and a ready-to-use CMake build — on **both** platforms, from **one** spec.

---

## 🏗️ Three Implementation Paths

Choose the native layer that fits your use-case — all driven by the same spec:

| `ios` / `android` | What Nitrogen generates | When to use |
|---|---|---|
| `NativeImpl.swift` / `NativeImpl.kotlin` | Swift `@_cdecl` bridge + Kotlin JNI bridge | Platform-specific APIs (camera, sensors, BLE) |
| `NativeImpl.cpp` / `NativeImpl.cpp` | Abstract C++ interface + direct virtual-dispatch bridge | Pure-computation, shared C++ libs, max performance |

### NativeImpl.cpp — Direct C++ Path

When both platforms use `NativeImpl.cpp`, the generated bridge talks directly to a `HybridX` C++ virtual interface — no JNI, no Swift. The same implementation works on Android and iOS:

```cpp
// src/HybridMath.cpp  (you write this)
#include "math.native.g.h"   // generated abstract interface

class HybridMathImpl : public HybridMath {
public:
    double add(double a, double b) override { return a + b; }
    std::string greet(const std::string& name) override { return "Hello, " + name; }
    int64_t get_precision() const override { return precision_; }
    void set_precision(int64_t v) override { precision_ = v; }
private:
    int64_t precision_ = 6;
};

// Call once at plugin startup (e.g. JNI_OnLoad / applicationDidFinishLaunching)
static HybridMathImpl g_math;
void setup() { math_register_impl(&g_math); }
```

No platform ifdefs. No JNI boilerplate. No Swift interop layer.

---

## 📊 Performance

| | Method Channel | Raw FFI | **Nitrogen (Swift/Kotlin)** | **Nitrogen (C++ direct)** |
|---|---|---|---|---|
| **Latency (iOS)** | ~30µs | **~0.12µs** | **~0.30µs** | **~0.18µs** |
| **Latency (Android)** | ~114µs | ~1.9µs | **~2.2µs** | **~1.8µs** |
| **Type Safety** | None | None | Full (generated) | Full (generated) |
| **Boilerplate** | Medium | Extreme | Minimal | Minimal |

### API Benchmarking (iPhone 17 Pro Max, iOS 26.3, Debug)
Test: **50 iterations** of `add(double, double)`.

| Bridge Type | Latency (Avg) | Speedup vs Channel |
|---|---|---|
| **Method Channel** | 29.160 µs | 1.0x |
| **Nitro (Swift/Kotlin)** | 0.300 µs | 97.2x |
| **Nitro (Direct C++)** | 0.180 µs | 162.0x |
| **Nitro (Leaf Call)** | **0.140 µs** | **208.3x** |
| **Nitro (Unsafe Ptr)** | **0.140 µs** | **208.3x** |
| **Raw FFI (Baseline)** | **0.120 µs** | **240.2x** |

### High-Bandwidth Throughput (iPhone 17 Pro Max, iOS 26.3)
Test: **1 GB** zero-copy `Uint8List` transfer (incl. 4KB-step memory-access checksum).

| Bridge Type | Time (1GB) | Throughput (MB/s) |
|---|---|---|
| **Method Channel** | ~567ms | 1,805.9 MB/s |
| **Nitro (Swift/Kotlin)** | ~719ms | 1,422.6 MB/s |
| **Nitro (Direct C++)** | ~192ms | 5,326.1 MB/s |
| **Nitro (Leaf Call)** | **~108ms** | **9,455.9 MB/s** |
| **Nitro (Unsafe Ptr)** | **~71µs** | **14,422,535 MB/s** |
| **Raw FFI (Baseline)** | **~95ms** | **10,693.1 MB/s** |

> [!NOTE]
> Nitro's **Unsafe Ptr** mode bypasses pinning costs, achieving **~14.4 TB/s** in memory-bound throughput tests, effectively matching the theoretical hardware floor of the M-series memory controllers.

---

---

## ✨ Developer Experience

The **Nitrogen CLI** eliminates all manual plumbing:

```sh
# Scaffold a complete plugin in seconds
nitrogen init my_camera

# Generate all native bindings from your spec
nitrogen generate

# Wire the build system (CMake, Podspec, .clangd)
nitrogen link

# Health-check every layer of your native build
nitrogen doctor
```

The CLI understands `NativeImpl.cpp` modules: it skips irrelevant Swift/Kotlin steps, syncs `.native.g.h` headers to `ios/Classes/`, and adds GoogleMock includes to `.clangd` for IDE mock support.

---

## 🗂️ Generated Files (per `.native.dart` spec)

### Swift/Kotlin path (`NativeImpl.swift` / `NativeImpl.kotlin`)

| File | Description |
|---|---|
| `lib/src/*.g.dart` | Dart FFI implementation |
| `lib/src/generated/kotlin/*.bridge.g.kt` | Kotlin JNI bridge |
| `lib/src/generated/swift/*.bridge.g.swift` | Swift `@_cdecl` bridge |
| `lib/src/generated/cpp/*.bridge.g.h` | C header |
| `lib/src/generated/cpp/*.bridge.g.cpp` | C++ JNI + Apple bridge |
| `lib/src/generated/cmake/*.CMakeLists.g.txt` | CMake include fragment |

### C++ direct path (`NativeImpl.cpp` on both platforms)

All of the above, **plus**:

| File | Description |
|---|---|
| `lib/src/generated/cpp/*.native.g.h` | Abstract `HybridX` C++ interface — **subclass this** |
| `lib/src/generated/cpp/test/*.mock.g.h` | GoogleMock `MockX` class for unit tests |
| `lib/src/generated/cpp/test/*.test.g.cpp` | Test starter with smoke test + `main()` |

The `.bridge.g.cpp` for a cpp module uses direct virtual dispatch (`g_impl->method()`) instead of JNI/Swift — no `#ifdef __ANDROID__`, no `#elif __APPLE__`.

---

## 🔬 Testing C++ Modules

The generated GoogleMock header lets you unit-test your logic without a running Flutter app:

```cpp
// In your test file (or use the generated *.test.g.cpp starter)
#include "math.mock.g.h"

TEST(MathTest, Add) {
    MockMath mock;
    math_register_impl(&mock);
    EXPECT_CALL(mock, add(::testing::An<double>(), ::testing::An<double>()))
        .WillOnce(::testing::Return(42.0));
    double result = math_add(1.0, 2.0);  // calls through C bridge → mock
    EXPECT_EQ(result, 42.0);
    math_register_impl(nullptr);
}
```

Build with `cmake --build <build-dir> --target math_test`.

---

## 📦 Package Overview

| Package | Role | Add to |
|---|---|---|
| [`nitro`](packages/nitro/README.md) | Runtime (base classes, FFI helpers) | `dependencies:` |
| [`nitro_annotations`](packages/nitro_annotations/README.md) | Annotations (`@NitroModule`, `@HybridStruct`, …) | `dependencies:` |
| [`nitro_generator`](packages/nitro_generator/README.md) | build_runner code generator | `dev_dependencies:` |
| [`nitrogen_cli`](packages/nitrogen_cli/README.md) | CLI (`init`, `generate`, `link`, `doctor`) | `dart pub global activate` |

---

## 🔌 Type Support

### Scalars
`int`, `double`, `bool`, `String`, `void`

### Collections & Buffers
`Uint8List`, `Int8List`, `Int16List`, `Int32List`, `Uint16List`, `Uint32List`, `Float32List`, `Float64List`, `Int64List`, `Uint64List`

TypedData params expand to `pointer + size_t length` in the C++ interface.

### Custom Types
- **`@HybridStruct`** — packed C struct, zero-copy across FFI boundary
- **`@HybridEnum`** — enum mapped to `int64_t` at the C boundary
- **`@HybridRecord`** — compact binary-encoded type (no JSON), for infrequent complex transfers

### Async & Streams
- **`@nitroAsync`** — offloads synchronous native call to a background thread
- **`@NitroStream`** — native-to-Dart event stream with configurable backpressure (`dropLatest`, etc.)

Stream support in the C++ direct path uses `Dart_PostCObject_DL` — thread-safe emit from any C++ thread.

---

## Zero-Copy Proxy Streaming

For `@HybridStruct` stream items, Nitrogen generates a **proxy class** that *extends* the value type with `@override` lazy getters. This eliminates all eager field copying on the hot path:

```
@HybridStruct BenchmarkBox (color, width, height)
        │
        └── generated: BenchmarkBoxProxy extends BenchmarkBox
                           @override int get color    => _native.ref.color
                           @override double get width  => _native.ref.width
                           @override double get height => _native.ref.height
```

The stream signature stays `Stream<BenchmarkBox>` — no API change needed. Consumers receive a `BenchmarkBoxProxy` at runtime (IS-A `BenchmarkBox`), but every field access reads directly from native heap memory via the `Pointer<BenchmarkBoxFfi>`:

```dart
// Works exactly like before — type annotation unchanged.
BenchmarkCpp.instance.boxStream.listen((box) {
  // box is BenchmarkBoxProxy at runtime — IS-A BenchmarkBox.
  // These reads go straight to native memory. Zero copy. Zero allocation.
  renderBox(Color(box.color), box.width, box.height);
  // When box leaves scope, NativeFinalizer calls the generated C release
  // function — no manual malloc.free() needed.
});
```

Memory is managed by a `NativeFinalizer` backed by a **generated C release symbol** (`${lib}_release_${StructName}`), so native memory is freed automatically when the proxy is GC'd. Call `(box as BenchmarkBoxProxy).toDartAndRelease()` for an eager snapshot if you need to outlive the current frame.

---

## `@HybridRecord` Wire Format

`@HybridRecord` types cross the FFI boundary as a compact little-endian binary buffer rather than JSON:

```text
[4-byte payload length][fields in declaration order]

int      → 8 bytes, little-endian int64
double   → 8 bytes, IEEE 754 float64
bool     → 1 byte  (0 = false, 1 = true)
String   → 4-byte UTF-8 length + UTF-8 bytes
nullable → 1-byte null tag + value if present
list     → 4-byte count + elements
```

---

## Exception Handling

- **Kotlin/JNI path**: Java exceptions caught in JNI bridge → `HybridException` in Dart
- **Swift path**: Swift errors + `NSException` caught in `@_cdecl` bridge
- **C++ direct path**: `std::exception` caught in generated bridge → `nitro_report_error()` → `HybridException` in Dart

```dart
try {
  await myModule.doWork();
} on HybridException catch (e) {
  print('Native error: ${e.message}');
}
```

---

## License

MIT
