# nitrogen_cli ⚡

**CLI tool for Nitrogen plugins.** Scaffold, generate, and link Nitrogen FFI plugins from the command line.

![Nitrogen Dashboard](https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/images/nitro_cli.png)

⚡ **For Nitro docs visit: [nitro.shreeman.dev](https://nitro.shreeman.dev/)**

---

## Installation

```sh
# From this monorepo (local development):
dart pub global activate --source path packages/nitrogen_cli

# Or from pub.dev:
dart pub global activate nitrogen_cli
```

Add the Dart pub global bin to your `PATH` (one-time):

```sh
# ~/.zshrc or ~/.bashrc:
export PATH="$PATH:$HOME/.pub-cache/bin"
```

---

Running `nitrogen` without arguments launches an interactive TUI dashboard. From there you can init, generate, link, doctor, and update with live visual feedback.

---

## Commands

### `nitrogen init`

Scaffolds a complete Nitrogen plugin from scratch with pre-wired native configurations.

```sh
nitrogen init
# → prompts for plugin name, then generates everything
```

**What it creates:**

| File | Description |
|---|---|
| `lib/src/<name>.native.dart` | Starter spec — define your API here |
| `ios/Classes/<Name>Impl.swift` | Starter Swift implementation |
| `ios/Classes/Swift<Name>Plugin.swift` | Flutter plugin registrar |
| `ios/<name>.podspec` | Pre-configured: Swift 5.9, iOS 13.0, C++17, `HEADER_SEARCH_PATHS` |
| `ios/Package.swift` | Swift Package Manager support |
| `android/.../<Name>Impl.kt` | Starter Kotlin implementation |
| `android/.../<Name>Plugin.kt` | Flutter plugin registrar |
| `src/CMakeLists.txt` | NDK build file |
| `pubspec.yaml` | Pre-wired with `nitro` and `nitro_generator` |

**You only ever edit:** the spec, the Kotlin impl, and the Swift impl (or a single C++ impl). Everything else is generated.

---

### `nitrogen generate`

Runs `flutter pub get` + `build_runner build` and syncs all generated files to their native destinations.

```sh
nitrogen generate
```

**What it produces (per `.native.dart` spec):**

| Output | Description |
|---|---|
| `lib/src/*.g.dart` | Dart FFI implementation |
| `lib/src/generated/kotlin/*.bridge.g.kt` | Kotlin JNI bridge (`NativeImpl.kotlin`) |
| `lib/src/generated/swift/*.bridge.g.swift` | Swift `@_cdecl` bridge (`NativeImpl.swift`) |
| `lib/src/generated/cpp/*.bridge.g.h` | C header (all modes) |
| `lib/src/generated/cpp/*.bridge.g.cpp` | C++ bridge (all modes) |
| `lib/src/generated/cmake/*.CMakeLists.g.txt` | CMake fragment (all modes) |
| `lib/src/generated/cpp/*.native.g.h` | Abstract C++ interface (`NativeImpl.cpp`) |
| `lib/src/generated/cpp/test/*.mock.g.h` | GoogleMock stub (`NativeImpl.cpp`) |
| `lib/src/generated/cpp/test/*.test.g.cpp` | Test starter (`NativeImpl.cpp`) |

**NativeImpl.cpp awareness:** `.bridge.g.swift` files that contain only a "Not applicable" placeholder are never copied to `ios/Classes/`. Instead, the generated `.native.g.h` headers are synced there so Clang can resolve them during iOS builds.

After generation, `nitrogen generate` also runs `pod install` in any `ios/` directory it finds.

---

### `nitrogen link`

Wires native build files (CMake, Podspec, Kotlin plugin, Swift plugin, `.clangd`) to the generated code.

```sh
nitrogen link
```

**What it wires:**

- Adds `include(...)` for each `.CMakeLists.g.txt` into `src/CMakeLists.txt`
- Adds `System.loadLibrary("lib")` to `android/.../Plugin.kt`
- Skips `JniBridge.register(...)` for all-cpp plugins
- Sets `HEADER_SEARCH_PATHS` + `DEFINES_MODULE` in the iOS `.podspec` (and macOS `.podspec` when `macos/` exists)
- Injects bridge registration into `ios/*Plugin.swift` and `macos/*Plugin.swift` for Swift/Kotlin modules
- Skips Swift bridge registration step for all-cpp plugins
- Creates `ios/Classes/dart_api_dl.c` and `macos/Classes/dart_api_dl.c` forwarders if missing
- Copies `nitro.h` to both `ios/Classes/` and `macos/Classes/`
- Updates `.clangd` to include `generated/cpp/test/` for GoogleMock IDE support when cpp modules exist
- Strips redundant `#include "*.bridge.g.cpp"` directives from `src/` files

---

### `nitrogen doctor`

Deep health check of every layer of your native build. Read-only — no files are changed.

```sh
nitrogen doctor
```

**Sections checked:**

| Section | Key checks |
|---|---|
| **System Toolchain** | `clang++`, Xcode, Android NDK, Java |
| **pubspec.yaml** | `nitro`, `build_runner`, `nitro_generator` deps; iOS and macOS plugin platform config |
| **Generated Files** | Every expected output file — present, not stale |
| **CMakeLists.txt** | `NITRO_NATIVE`, `dart_api_dl.c`, `add_library(lib)` target |
| **Android** | `kotlin-android`, `kotlinOptions`, `generated/kotlin` sourceSets, `System.loadLibrary`, `JniBridge.register` |
| **iOS** | `.podspec` headers/C++17, Swift version, `dart_api_dl.c`, `nitro.h`, `NITRO_EXPORT`, `.bridge.g.mm` count |
| **macOS** | `.podspec` headers/C++17, Swift version, `dart_api_dl.c`, `nitro.h`, `NITRO_EXPORT`, `.bridge.g.mm` count, Swift plugin registration |
| **NativeImpl.cpp** *(cpp modules only)* | `${lib}_register_impl` wired up, `.clangd` includes test dir |

**NativeImpl.cpp awareness:**

- Android: when all specs use `NativeImpl.cpp`, Kotlin JNI bridge checks are shown as `ℹ info` (not required) instead of errors.
- iOS: Registry.register check skipped; checks for `.native.g.h` headers in `ios/Classes/` instead; no `.bridge.g.mm` warning.
- Generated files: `.bridge.g.kt` / `.bridge.g.swift` shown as `ℹ info` (placeholder) for cpp modules; `.native.g.h`, `.mock.g.h`, `.test.g.cpp` checked as required outputs.

**Exit codes:** `0` = all checks pass, `1` = one or more errors (suitable for CI).

```yaml
# .github/workflows/build.yml
- name: Nitrogen health check
  run: |
    dart pub global activate nitrogen_cli
    nitrogen doctor
```

---

## Platform Targeting

Each platform is configured independently via the `@NitroModule` annotation. All three platforms can be mixed and matched:

```dart
// iOS + Android Swift/Kotlin, macOS via direct C++
@NitroModule(lib: 'sensor', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp)
abstract class SensorModule extends HybridObject { ... }

// All three platforms using direct C++ (same implementation everywhere)
@NitroModule(lib: 'math', ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Math extends HybridObject { ... }

// iOS + macOS Swift, Android Kotlin
@NitroModule(lib: 'plugin', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)
abstract class MyPlugin extends HybridObject { ... }
```

> **Note:** `macos: NativeImpl.kotlin` is not valid — Kotlin is not a native macOS language. The generator will emit an `INVALID_MACOS_IMPL` error at build time.

---

## NativeImpl.cpp Workflow

For plugins where both platforms use direct C++:

```dart
// lib/src/math.native.dart
@NitroModule(lib: 'math', ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl();
  double add(double a, double b);
}
```

```sh
nitrogen generate   # → math.native.g.h (abstract C++ interface)
nitrogen link       # → wires CMake, podspec, .clangd
```

```cpp
// src/HybridMath.cpp  (you write this)
#include "math.native.g.h"

class HybridMathImpl : public HybridMath {
public:
    double add(double a, double b) override { return a + b; }
};

static HybridMathImpl g_math;

// Auto-register on shared library load — no manual init call needed.
// (Generated by nitrogen link via linkCppImplStubs)
__attribute__((constructor))
static void math_auto_register() {
    math_register_impl(&g_math);
}
```

```sh
nitrogen doctor     # → checks register_impl is wired, headers synced, .clangd up to date
```

---

## Spec Example (Swift/Kotlin path)

```dart
// lib/src/sensor.native.dart
import 'package:nitro/nitro.dart';
part 'sensor.g.dart';

@HybridEnum(startValue: 0)
enum DeviceStatus { idle, busy, error }

@HybridStruct(packed: true)
class SensorData {
  final double temperature;
  final double humidity;
  const SensorData({required this.temperature, required this.humidity});
}

@NitroModule(lib: 'sensor', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)
abstract class SensorModule extends HybridObject {
  static final SensorModule instance = _SensorModuleImpl();

  DeviceStatus getStatus();
  void updateSensors(SensorData data);

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorData> get sensorStream;
}
```

---

## Requirements

| Tool | Minimum |
|---|---|
| Dart SDK | 3.3.0+ |
| Flutter SDK | 3.22.0+ |
| Android NDK | 26.1+ |
| Kotlin | 1.9.0+ |
| iOS Deployment Target | 13.0+ |
| Xcode | 15.0+ |

---

## Related

- **[nitro](../nitro/README.md)** — Runtime (base classes, annotations, helpers)
- **[nitro_generator](../nitro_generator/README.md)** — build_runner code generator
- **[Getting started guide](../../docs/getting-started.md)** — step-by-step walkthrough
