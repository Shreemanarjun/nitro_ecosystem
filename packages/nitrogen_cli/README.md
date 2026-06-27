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

## Headless / CI mode

Every command supports `--no-ui`. In headless mode all output is plain text prefixed with `[nitro]`, `[nitro:warn]`, or `[nitro:error]` — no ANSI codes, no interactive prompts.

**TTY auto-detection:** when stdout is not a terminal (piped output, CI runner), `--no-ui` activates automatically — you never need to pass it explicitly in CI.

```sh
nitrogen <command> --no-ui
```

---

## Commands

### `nitrogen init`

Scaffolds a complete Nitrogen plugin from scratch with pre-wired native configurations.

```sh
nitrogen init                                    # interactive TUI form
nitrogen init --name my_plugin                  # skip form, show progress TUI
nitrogen init --no-ui --name my_plugin          # headless / CI
nitrogen init --no-ui --name my_plugin \
              --org com.example \
              --platforms android,ios,macos
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--name`, `-n` | — | Plugin name (skips interactive form) |
| `--org` | `com.example` | Android/iOS organisation identifier |
| `--dir`, `-d` | `.` | Parent directory to create the plugin in |
| `--platforms`, `-p` | `android,ios,macos,windows,linux` | Comma-separated target platforms |
| `--no-ui` | `false` | Headless output. Requires `--name` |

**What it creates:**

| File | Description |
|---|---|
| `lib/src/<name>.native.dart` | Starter spec — define your API here |
| `ios/Classes/<Name>Impl.swift` | Starter Swift implementation |
| `ios/Classes/Swift<Name>Plugin.swift` | Flutter plugin registrar |
| `ios/<name>.podspec` | Pre-configured: Swift 5.9, iOS 13.0, C++17, `HEADER_SEARCH_PATHS` |
| `ios/<name>/Package.swift` | Swift Package Manager support (nested Flutter 3.41+ layout) |
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

# Headless / CI — no ANSI codes, plain [nitro] prefix lines
nitrogen generate --no-ui

# Treat spec validation warnings as errors (exit code 2)
nitrogen generate --fail-on-warn
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Headless plain-text output |
| `--fail-on-warn` | `false` | Exit code 2 if spec has warnings |

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Generation error |
| `2` | Spec warnings present and `--fail-on-warn` was passed |

**What it produces (per `.native.dart` spec):**

| Output | Description |
|---|---|
| `lib/src/*.g.dart` | Dart FFI implementation |
| `lib/src/generated/kotlin/*.bridge.g.kt` | Kotlin JNI bridge (`AndroidNativeImpl.kotlin`) |
| `lib/src/generated/swift/*.bridge.g.swift` | Swift `@_cdecl` bridge (`AppleNativeImpl.swift`) |
| `lib/src/generated/cpp/*.bridge.g.h` | C header (all modes) |
| `lib/src/generated/cpp/*.bridge.g.cpp` | C++ bridge (all modes) |
| `lib/src/generated/cmake/*.CMakeLists.g.txt` | CMake fragment (all modes) |
| `lib/src/generated/cpp/*.native.g.h` | Abstract C++ interface (`*NativeImpl.cpp`) |
| `lib/src/generated/cpp/test/*.mock.g.h` | GoogleMock stub (`*NativeImpl.cpp`) |
| `lib/src/generated/cpp/test/*.test.g.cpp` | Test starter (`*NativeImpl.cpp`) |

**Direct C++ awareness:** `.bridge.g.swift` files that contain only a "Not applicable" placeholder are never copied to `ios/Classes/`. Instead, the generated `.native.g.h` headers are synced there so Clang can resolve them during iOS builds.

After generation, `nitrogen generate` also runs `pod install` in any `ios/` directory it finds.

**CI example:**

```yaml
# .github/workflows/build.yml
- name: Generate Nitrogen bindings
  run: |
    dart pub global activate nitrogen_cli
    nitrogen generate --no-ui --fail-on-warn   # exit 2 if spec has warnings
```

---

### `nitrogen link`

Wires native build files (CMake, Podspec, Kotlin plugin, Swift plugin, `.clangd`) to the generated code.

```sh
nitrogen link             # interactive TUI with confirmation prompt
nitrogen link --yes       # skip confirmation prompt, show TUI
nitrogen link --no-ui     # headless (implies --yes)
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--yes`, `-y` | `false` | Skip the "Proceed?" confirmation prompt |
| `--no-ui` | `false` | Headless plain-text output (implies `--yes`) |

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
nitrogen doctor           # interactive TUI
nitrogen doctor --no-ui   # headless, one line per check
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Plain-text output with `[nitro:ok]` / `[nitro:warn]` / `[nitro:error]` prefixes |

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
| **Direct C++ modules** | `${lib}_register_impl` wired up, `.clangd` includes test dir |

**Direct C++ awareness:**

- Android: when all specs use direct C++, Kotlin JNI bridge checks are shown as `ℹ info` (not required) instead of errors.
- iOS: Registry.register check skipped; checks for `.native.g.h` headers in `ios/Classes/` instead; no `.bridge.g.mm` warning.
- Generated files: `.bridge.g.kt` / `.bridge.g.swift` shown as `ℹ info` (placeholder) for cpp modules; `.native.g.h`, `.mock.g.h`, `.test.g.cpp` checked as required outputs.

**Exit codes:** `0` = all checks pass, `1` = one or more errors (suitable for CI).

```yaml
# .github/workflows/build.yml
- name: Nitrogen health check
  run: |
    dart pub global activate nitrogen_cli
    nitrogen doctor --no-ui
```

---

### `nitrogen migrate`

Migrates a CocoaPods-only plugin to the Swift Package Manager nested layout (Flutter 3.41+).

```sh
nitrogen migrate              # interactive TUI with preview
nitrogen migrate --dry-run    # preview changes without writing files
nitrogen migrate --no-backup  # skip backup step
nitrogen migrate --no-ui      # headless, skips interactive confirmation
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--[no-]backup` | `true` | Create a `.nitrogen_backup_<ts>/` snapshot before migrating |
| `--dry-run` | `false` | Show what would change without writing any files |
| `--no-ui` | `false` | Headless plain-text output (skips confirmation prompt) |

**What it does:**

1. Optionally backs up existing `ios/*.podspec` and `example/ios/Podfile`
2. Creates `ios/<name>/Package.swift` (Flutter 3.41+ nested SPM layout)
3. Creates `macos/<name>/Package.swift` when `macos/` exists
4. Leaves CocoaPods cleanup/linking to `nitrogen link`, so you can inspect the generated SPM files first

---

### `nitrogen watch`

Runs `build_runner watch` and re-links generated files on every change.

```sh
nitrogen watch           # streaming TUI output
nitrogen watch --no-ui   # headless, raw build_runner lines with [nitro] prefix
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Headless plain-text output |

---

### `nitrogen clean`

Deletes all Nitrogen-generated files and the `build_runner` cache.

```sh
nitrogen clean           # interactive output
nitrogen clean --no-ui   # headless
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Headless plain-text output |

**What it removes:** all `*.g.dart`, `*.bridge.g.swift`, `*.bridge.g.kt`, `*.bridge.g.cpp`, `*.bridge.g.h`, `*.bridge.g.mm`, `*.CMakeLists.g.txt`, `*.native.g.h`, `*.mock.g.h`, `*.test.g.cpp` files and the `.dart_tool/build/` cache.

---

### `nitrogen update`

Self-updates the nitrogen CLI to the latest version on pub.dev (or `git pull` if path-activated).

```sh
nitrogen update           # interactive TUI
nitrogen update --no-ui   # headless
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Headless plain-text output |

**What it does:**
1. Checks the current activation (`dart pub global list`)
2. Fetches the latest version from pub.dev
3. Runs `dart pub global activate nitrogen_cli` (hosted) or `git pull --ff-only` (path-activated)

---

### `nitrogen open`

Opens the generated spec file in your editor.

```sh
nitrogen open             # interactive editor picker
nitrogen open --no-ui     # headless
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Headless plain-text output |

---

## Platform Targeting

Each platform is configured independently via the `@NitroModule` annotation. New specs should use the explicit platform constants:

```dart
// iOS + Android Swift/Kotlin, macOS via direct C++
@NitroModule(
  lib: 'sensor',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  macos: AppleNativeImpl.cpp,
)
abstract class SensorModule extends HybridObject {
  static final SensorModule instance = _SensorModuleImpl();

  bool isReady();
}

// Shared direct C++ implementation everywhere native C++ is supported
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

// iOS + macOS Swift, Android Kotlin
@NitroModule(
  lib: 'plugin',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  macos: AppleNativeImpl.swift,
)
abstract class MyPlugin extends HybridObject {
  static final MyPlugin instance = _MyPluginImpl();

  String platformVersion();
}
```

`NativeImpl.*` remains available as backward-compatible shorthand. The explicit constants are clearer because invalid combinations, such as Kotlin on macOS, are rejected by Dart's type system before generation.

---

## Direct C++ Workflow

For plugins where both platforms use direct C++:

```dart
// lib/src/math.native.dart
@NitroModule(
  lib: 'math',
  ios: AppleNativeImpl.cpp,
  android: AndroidNativeImpl.cpp,
  macos: AppleNativeImpl.cpp,
)
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

@NitroModule(
  lib: 'sensor',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  macos: AppleNativeImpl.swift,
)
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
