# nitro_generator

A high-performance code generator for **Nitro Modules** (Nitrogen). Converts `.native.dart` interface specs into optimized native bindings for Android, iOS, and direct C++.

## Features

- **Three implementation paths**: Swift (`@_cdecl`), Kotlin (JNI), or direct C++ virtual dispatch — chosen per-module via `@NitroModule(ios:, android:)`.
- **NativeImpl.cpp**: generates an abstract C++ interface (`HybridX`), a direct virtual-dispatch bridge (no JNI/Swift), GoogleMock stubs, and a test starter — everything needed to implement and test in pure C++.
- **Type-safe**: strict Dart-to-native type mapping with validation before generation.
- **Zero-copy structs**: `@HybridStruct` passes packed C structs directly across the FFI boundary.
- **Binary records**: `@HybridRecord` uses a compact little-endian binary protocol (no JSON) for complex infrequent data.
- **Async**: `@nitroAsync` offloads blocking native calls to a background thread.
- **Streams**: `@NitroStream` with configurable backpressure strategies; C++ modules emit via `Dart_PostCObject_DL` from any thread.

## Usage

1. Define your API in a `.native.dart` file.
2. Choose the implementation path:

```dart
// Swift/Kotlin (platform-specific APIs)
@NitroModule(lib: 'camera', ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Camera extends HybridObject { ... }

// Direct C++ (shared logic, max performance)
@NitroModule(lib: 'math', ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject { ... }
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

### NativeImpl.cpp path (additional outputs)

| File | Description |
|---|---|
| `lib/src/generated/cpp/*.native.g.h` | Abstract `HybridX` C++ class — **subclass and implement this** |
| `lib/src/generated/cpp/test/*.mock.g.h` | GoogleMock `MockX` class for unit tests |
| `lib/src/generated/cpp/test/*.test.g.cpp` | Test starter with smoke test + `main()` |

For cpp modules, `.bridge.g.cpp` uses direct virtual dispatch (`g_impl->method()`) instead of JNI/Swift, and `.bridge.g.kt` / `.bridge.g.swift` contain a "Not applicable" placeholder.

## NativeImpl.cpp — Quick Start

```dart
// spec
@NitroModule(lib: 'math', ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject {
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

## Type Mapping (C++ direct path)

| Dart | C++ method signature | C bridge type |
|---|---|---|
| `int` | `int64_t` | `int64_t` |
| `double` | `double` | `double` |
| `bool` | `bool` | `int8_t` |
| `String` | `std::string` / `const std::string&` | `const char*` |
| `Uint8List` | `const uint8_t* buf, size_t buf_length` | `uint8_t*, int64_t` |
| `MyEnum` | `MyEnum` (C enum) | `int64_t` |
| `MyStruct` | `const MyStruct&` (param) / `MyStruct` (return) | `void*` |
| `MyRecord` | `NitroCppBuffer` | `void*, int64_t` |
| `Stream<T>` | `emit_name(T item)` helper | register/release port |

## Documentation

For full documentation and getting started guides, visit [nitro.shreeman.dev](https://nitro.shreeman.dev).

## License

MIT
