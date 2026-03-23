# nitrogen_cli ⚡

**CLI tool for Nitrogen plugins.** Scaffold, generate, and link Nitrogen FFI plugins from the command line.

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

## Interactive TUI Dashboard

If you run `nitrogen` without any arguments, it launches a beautiful interactive Text-based User Interface (TUI) dashboard.

![Nitrogen Dashboard](https://raw.githubusercontent.com/Shreemanarjun/nitro_ecosystem/main/packages/nitrogen_cli/doc/dashboard_screenshot.png)

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
- Optimized `src/CMakeLists.txt` for Android.
- `ios/Classes/my_camera.cpp` forwarder.
- Pre-configured `ios/my_camera.podspec` (Swift 5.9, iOS 13.0, C++17).
- Starter `lib/src/my_camera.native.dart` spec.
- `pubspec.yaml` pre-wired with `nitro` and `nitro_generator`.

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
- Adds `HEADER_SEARCH_PATHS` pointing to `lib/src/generated/cpp/` in the iOS `.podspec`

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
