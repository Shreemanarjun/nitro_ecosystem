# nitro_generator

A high-performance code generator for **Nitro Modules** (Nitrogen). Converts `.native.dart` interface specs into optimized native bindings for Android, iOS, and direct C++.

## Features

- **Three implementation paths**: Swift (`@_cdecl`), Kotlin (JNI), or direct C++ virtual dispatch — chosen per-module via `@NitroModule(...)`.
- **Direct C++ modules**: generate an abstract C++ interface (`HybridX`), a direct virtual-dispatch bridge (no JNI/Swift), GoogleMock stubs, and a test starter — everything needed to implement and test in pure C++.
- **Type-safe**: strict Dart-to-native type mapping with validation before generation.
- **Zero-copy structs**: `@HybridStruct` passes packed C structs directly across the FFI boundary.
- **Binary records**: `@HybridRecord` uses a compact little-endian binary protocol (no JSON) for complex infrequent data.
- **Async**: `@nitroAsync` offloads blocking native calls to a background thread.
- **Streams**: `@NitroStream` with configurable backpressure strategies; C++ modules emit via `Dart_PostCObject_DL` from any thread.
- **Default param literals**: Named params with default values (`{int timeout = 30}`, `{MyEnum quality = MyEnum.normal}`) are preserved in the generated Dart FFI signature — no boilerplate wrapper needed.
- **Cross-file type sharing**: `@HybridEnum`, `@HybridStruct`, and `@HybridRecord` types defined in one `.native.dart` can be imported and used in another; the generator tracks which declarations belong to which file and emits correct `#include` directives in the C header.
- **Source-map comments**: Each generated method in Swift, Kotlin, and C++ includes a `// source: file.native.dart:42` comment pointing back to the originating spec line.
- **Pre-generation validation**: The generator reports errors (E) and warnings (W) before emitting any code, so invalid specs surface early with clear messages.

## Usage

1. Define your API in a `.native.dart` file.
2. Choose the implementation path:

```dart
import 'package:nitro/nitro.dart';

// Swift/Kotlin (platform-specific APIs)
@NitroModule(
  lib: 'camera',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
)
abstract class Camera extends HybridObject {
  static final Camera instance = _CameraImpl();

  bool isAvailable();
}

// Direct C++ (shared logic, max performance)
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

3. Run the generator:

```sh
flutter pub run build_runner build
# or via the CLI:
nitrogen generate
```

## Generated Outputs

### Swift/Kotlin path

| File | Description |
|---|---|
| `lib/src/*.g.dart` | Dart FFI bindings |
| `lib/src/generated/kotlin/*.bridge.g.kt` | Kotlin JNI bridge + `HybridXxxSpec` interface |
| `lib/src/generated/swift/*.bridge.g.swift` | Swift `@_cdecl` bridge + `HybridXxxProtocol` |
| `lib/src/generated/cpp/*.bridge.g.h` | C header (`extern "C"` declarations) |
| `lib/src/generated/cpp/*.bridge.g.cpp` | C++ JNI & Apple bridge |
| `lib/src/generated/cmake/*.CMakeLists.g.txt` | CMake include fragment |

### Direct C++ path (additional outputs)

| File | Description |
|---|---|
| `lib/src/generated/cpp/*.native.g.h` | Abstract `HybridX` C++ class — **subclass and implement this** |
| `lib/src/generated/cpp/test/*.mock.g.h` | GoogleMock `MockX` class for unit tests |
| `lib/src/generated/cpp/test/*.test.g.cpp` | Test starter with smoke test + `main()` |

For C++ modules, `.bridge.g.cpp` uses direct virtual dispatch (`g_impl->method()`) instead of JNI/Swift, and `.bridge.g.kt` / `.bridge.g.swift` contain a "Not applicable" placeholder.

## Direct C++ — Quick Start

```dart
// spec
@NitroModule(lib: 'math', ios: AppleNativeImpl.cpp, android: AndroidNativeImpl.cpp)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();

  double add(double a, double b);
  String greet(String name);
  int get precision;
  set precision(int value);
}
```

After `nitrogen generate`, you get `math.native.g.h`:

```cpp
class HybridMath {
public:
    virtual ~HybridMath() = default;
    virtual double add(double a, double b) = 0;
    virtual std::string greet(const std::string& name) = 0;
    virtual int64_t get_precision() const = 0;
    virtual void set_precision(int64_t value) = 0;
protected:
    HybridMath() = default;
};
void math_register_impl(HybridMath* impl);
HybridMath* math_get_impl(void);
```

Your implementation:

```cpp
#include "math.native.g.h"
class HybridMathImpl : public HybridMath {
public:
    double add(double a, double b) override { return a + b; }
    std::string greet(const std::string& name) override { return "Hello, " + name; }
    int64_t get_precision() const override { return precision_; }
    void set_precision(int64_t v) override { precision_ = v; }
private:
    int64_t precision_ = 6;
};
static HybridMathImpl g_math;
// at startup: math_register_impl(&g_math);
```

Unit test with the generated mock:

```cpp
#include "math.mock.g.h"
TEST(MathTest, Add) {
    MockMath mock;
    math_register_impl(&mock);
    EXPECT_CALL(mock, add(::testing::_, ::testing::_)).WillOnce(::testing::Return(3.0));
    EXPECT_EQ(math_add(1.0, 2.0), 3.0);
    math_register_impl(nullptr);
}
```

## Default Param Literals

Named parameters with default values are preserved in generated Dart FFI bindings:

```dart
// .native.dart
@HybridEnum()
enum PrintQuality { draft, normal, high }

abstract class Printer {
  void print(String text, {PrintQuality quality = PrintQuality.normal, int copies = 1});
}
```

Generated Dart FFI:

```dart
// .g.dart  — callers get the default, no wrapper needed
void print(String text, {PrintQuality quality = PrintQuality.normal, int copies = 1}) {
  // Generated FFI body.
}
```

Enum, `int`, `double`, `bool`, and `String` default literals are all supported.

## Cross-File Type Sharing

Types declared in one spec can be used by another:

```dart
// enums.native.dart  — type-only file (no @NitroModule class)
@HybridEnum()
enum DeviceStatus { idle, active, error }

@HybridStruct()
class Reading { final double value; final int timestamp; }
```

```dart
// sensor.native.dart
import 'enums.native.dart';   // import the type file

@NitroModule(lib: 'sensor', ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class Sensor extends HybridObject {
  static final Sensor instance = _SensorImpl();

  DeviceStatus getStatus();
  Reading getReading();
}
```

The generator:
- Emits a type-only Swift/Kotlin/C++ output for `enums.native.dart` (enums + structs, no bridge scaffolding).
- Emits `#include "enums.bridge.g.h"` in `sensor.bridge.g.h` so C++ sees both files.
- Avoids re-declaring imported types in `sensor`'s native outputs.

## Spec Validation

Before emitting any code, the generator validates the spec and reports issues with clear codes:

| Code | Severity | Condition |
|---|---|---|
| **E001** | Error | `Map<K, V>` where `K` is not `String` — only `Map<String, V>` is supported |
| **E002** | Error | `@nitroAsync` / `@nitroNativeAsync` on a function whose return type is not `Future<T>` |
| **E014** | Error | `@NitroVariant` sealed class exceeds 255 cases |
| **W001** | Warning | Non-nullable `int`/`double`/`bool` named param with no `defaultLiteral` — callers must always pass it |
| **W002** | Warning | Non-nullable `@HybridEnum` named param with no default |
| **W003** | Warning | Non-nullable `@HybridStruct` named param with no default |
| **W004** | Warning | `Stream<T>` return declared without `@NitroStream` annotation |

Errors (`E*`) stop generation. Warnings (`W*`) produce output but flag the spec for review. Use `nitrogen generate --fail-on-warn` to treat warnings as errors in CI.

## Source-Map Comments

Every generated method includes a comment linking back to its spec origin:

```swift
// source: sensor.native.dart:12
public func getStatus() -> DeviceStatus {
    return .idle
}
```

```kotlin
// source: sensor.native.dart:12
fun getStatus(): DeviceStatus
```

```cpp
// source: sensor.native.dart:12
virtual DeviceStatus get_status() = 0;
```

This makes it easy to navigate from generated native code back to the Dart spec.

## Type Mapping (C++ direct path)

| Dart | C++ method signature | C bridge type |
|---|---|---|
| `int` | `int64_t` | `int64_t` |
| `double` | `double` | `double` |
| `bool` | `bool` | `int8_t` |
| `String` | `std::string` / `const std::string&` | `const char*` |
| `int?` | `std::optional<int64_t>` | `NitroOptInt64` (9-byte packed struct) |
| `double?` | `std::optional<double>` | `NitroOptFloat64` (9-byte packed struct) |
| `bool?` | `std::optional<bool>` | `NitroOptBool` (2-byte packed struct) |
| `String?` | `const char*` (null = absent) | `const char*` |
| `Uint8List` | `const uint8_t* buf, size_t buf_length` | `uint8_t*, int64_t` |
| `@HybridEnum MyEnum` | `MyEnum` (C enum) | `int64_t` |
| `@HybridStruct MyStruct` | `const MyStruct&` (param) / `MyStruct` (return) | `void*` |
| `@HybridRecord MyRecord` | `NitroCppBuffer` | `void*, int64_t` |
| `@NitroVariant MyVariant` | `NitroCppBuffer` | `void*, int64_t` |
| `@NitroTuple MyTuple` | `NitroCppBuffer` | `void*, int64_t` |
| `Stream<T>` | `emit_name(T item)` helper | register/release port |

## Documentation

For full documentation and getting started guides, visit [nitro.shreeman.dev](https://nitro.shreeman.dev).

## License

MIT
