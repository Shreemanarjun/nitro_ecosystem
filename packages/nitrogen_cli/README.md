# nitrogen_cli ⚡

**CLI tool for Nitrogen plugins.** Scaffold, generate, and link Nitrogen FFI plugins from the command line.

![Nitrogen Dashboard](https://zmozkivkhopoeutpnnum.supabase.co/storage/v1/object/public/images/nitro_cli.png)

⚡ **For Nitro docs visit: [nitro.shreeman.dev](https://nitro.shreeman.dev/)**

---

## Installation

```sh
# From this monorepo (local development):
# In packages/nitrogen_cli:
dart pub global activate --source path .

# Or for users (real package):
# dart pub global activate nitrogen_cli
```

Then add the Dart pub global bin to your `PATH` (one-time setup):

```sh
# Add to ~/.zshrc or ~/.bashrc:
export PATH="$PATH:$HOME/.pub-cache/bin"
```

---

If you run `nitrogen` without any arguments, it launches a beautiful interactive Text-based User Interface (TUI) dashboard.

From the dashboard, you can:
- **Initialize**: Scaffold new projects with step-by-step confirmation.
- **Generate**: Run the code generator and see live, scrollable output.
- **Link**: Wire bridges with immediate visual feedback.
- **Doctor**: Run production-ready checks and see a detailed health report.
- **Update**: Check for new versions on `pub.dev` and self-update the CLI.

---

## Commands

### `nitrogen init <PluginName>`

Scaffolds a complete Nitrogen plugin from scratch with optimized native configurations:

```sh
# Create a new plugin named "my_camera"
nitrogen init my_camera
```

**What it creates:**

| File | Description |
|---|---|
| `lib/src/my_camera.native.dart` | Starter spec — define your API here |
| `ios/Classes/MyCameraImpl.swift` | Starter Swift implementation — edit this |
| `ios/Classes/SwiftMyCameraPlugin.swift` | Flutter plugin registrar (auto-registers the impl) |
| `ios/Classes/my_camera.bridge.g.swift` | Symlink → generated Swift bridge (created by `generate`) |
| `ios/Classes/dart_api_dl.c` | Dart DL API forwarder (compiled as C, not C++) |
| `ios/my_camera.podspec` | Pre-configured: Swift 5.9, iOS 13.0, C++17, correct `HEADER_SEARCH_PATHS` |
| `ios/Package.swift` | Swift Package Manager support alongside CocoaPods |
| `android/.../MyCameraImpl.kt` | Starter Kotlin implementation — edit this |
| `android/.../MyCameraPlugin.kt` | Flutter plugin registrar |
| `src/CMakeLists.txt` | Android NDK build file |
| `pubspec.yaml` | Pre-wired with `nitro` and `nitro_generator` |

**You only edit three things:** the spec, the Kotlin impl, and the Swift impl. Everything else is generated or scaffolded once.

### `nitrogen generate`

Scans the current package for `*.native.dart` files and regenerates all outputs.

```sh
# From your plugin root:
nitrogen generate
```

**What it produces (per `*.native.dart` file):**

| Output | Description |
|---|---|
| `lib/src/*.g.dart` | Dart FFI implementation class |
| `lib/src/generated/kotlin/*.kt` | Kotlin JNI bridge + `HybridXxxSpec` interface |
| `lib/src/generated/swift/*.swift` | Swift `@_cdecl` bridge + `HybridXxxProtocol` protocol |
| `lib/src/generated/cpp/*.h` | C header with `extern "C"` declarations |
| `lib/src/generated/cpp/*.cpp` | C++ JNI & Apple bridge implementation |
| `lib/src/generated/cmake/*.txt` | CMake include for Android builds |

### `nitrogen link`

Ensures the native build files (CMake, Podspec) are correctly linked to Nitrogen's generated code. Use this when adding Nitrogen to an existing plugin.

```sh
nitrogen link
```

**What it wires:**
- Adds `include(...)` for each generated `.CMakeLists.g.txt` into `src/CMakeLists.txt`
- Adds `System.loadLibrary("...")` to the Android `Plugin.kt`
- Sets `HEADER_SEARCH_PATHS` in the iOS `.podspec` to `${PODS_ROOT}/../.symlinks/plugins/nitro/src/native` (works for both local path and pub.dev installs)
- Adds `DEFINES_MODULE => YES` to the podspec so the generated Swift bridge is visible
- Creates `ios/Classes/dart_api_dl.c` if missing (must be `.c`, not `.cpp`)
- Creates `ios/Classes/<Plugin>.bridge.g.swift` symlink if missing
- Creates `ios/Package.swift` for Swift Package Manager support if missing

### `nitrogen doctor`

Checks that all generated files are present and up to date, and that the build system is correctly wired. Safe to run at any time — read-only, no files are changed.

```sh
# From your plugin root:
nitrogen doctor
```

**What it checks (per `*.native.dart` spec):**

| Check | Pass | Fail |
|---|---|---|
| Generated `.g.dart` exists | ✔ | `MISSING` → run `nitrogen generate` |
| Generated `.bridge.g.kt` exists | ✔ | `MISSING` → run `nitrogen generate` |
| Generated `.bridge.g.swift` exists | ✔ | `MISSING` → run `nitrogen generate` |
| Generated `.bridge.g.h` exists | ✔ | `MISSING` → run `nitrogen generate` |
| Generated `.bridge.g.cpp` exists | ✔ | `MISSING` → run `nitrogen generate` |
| Generated `.CMakeLists.g.txt` exists | ✔ | `MISSING` → run `nitrogen generate` |
| No generated file is older than its spec | ✔ | `STALE` → run `nitrogen generate` |
| `add_library(lib)` in `src/CMakeLists.txt` | ✔ | `MISSING` → run `nitrogen link` |
| `System.loadLibrary("lib")` in `Plugin.kt` | ✔ | `MISSING` → run `nitrogen link` |
| `HEADER_SEARCH_PATHS` in `.podspec` | ✔ | `MISSING` → run `nitrogen link` |

**Example output (healthy plugin):**

```
Checking my_sensor...
  ✔  lib/src/my_sensor.g.dart
  ✔  lib/src/generated/kotlin/my_sensor.bridge.g.kt
  ✔  lib/src/generated/swift/my_sensor.bridge.g.swift
  ✔  lib/src/generated/cpp/my_sensor.bridge.g.h
  ✔  lib/src/generated/cpp/my_sensor.bridge.g.cpp
  ✔  lib/src/generated/cmake/my_sensor.CMakeLists.g.txt

Checking CMakeLists.txt...
  ✔  add_library(my_sensor) in src/CMakeLists.txt

Checking android Plugin.kt...
  ✔  System.loadLibrary("my_sensor") in Plugin.kt

Checking iOS podspec...
  ✔  HEADER_SEARCH_PATHS in my_sensor.podspec

my_sensor is healthy — all checks passed.
```

**Example output (with issues):**

```
Checking my_sensor...
  ✘  MISSING  lib/src/my_sensor.g.dart
       → run: nitrogen generate
  ✘  STALE   lib/src/generated/kotlin/my_sensor.bridge.g.kt
       → spec is newer than generated file — run build_runner

1 error(s) found.
```

**Exit codes:** `0` = all checks pass, `1` = one or more errors (suitable for CI).

**Recommended CI usage:**

```yaml
# .github/workflows/build.yml
- name: Check Nitrogen health
  run: |
    dart pub global activate --source path packages/nitrogen_cli
    cd my_sensor
    nitrogen doctor
```

---

## Complex Specification Example

Nitrogen supports complex types, nested structures, and multiple streams.

```dart
// lib/src/complex.native.dart
import 'package:nitro/nitro.dart';
part 'complex.g.dart';

@HybridEnum(startValue: 0)
enum DeviceStatus { idle, busy, error, fatal }

@HybridStruct(packed: true)
class SensorData {
  final double temperature;
  final double humidity;
  final int lastUpdate;
  const SensorData({required this.temperature, required this.humidity, required this.lastUpdate});
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class ComplexModule extends HybridObject {
  static final ComplexModule instance = _ComplexModuleImpl();

  int calculate(int seed, double factor, bool enabled);
  
  @nitroAsync
  Future<String> fetchMetadata(String url);

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

## Related packages

- **[nitro](../nitro/README.md)** — Runtime (base classes, annotations, helpers)
- **[nitro_generator](../nitrogen/README.md)** — build_runner code generator
- **[Getting started guide](../../docs/getting-started.md)** — step-by-step walkthrough for plugin authors
