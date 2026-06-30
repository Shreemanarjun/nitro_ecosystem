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

Running `nitrogen` without arguments launches an interactive TUI dashboard. From there you can **init, generate, watch, link, doctor, migrate, clean, and update** with live visual feedback. The dashboard also provides one-click **Open in VS Code** and **Open in Antigravity** buttons.

```sh
nitrogen --version    # print installed version and exit
nitrogen -v           # same
```

---

## Headless / CI mode

Every command supports `--no-ui`. In headless mode all output is plain text prefixed with `[nitro]`, `[nitro:warn]`, or `[nitro:error]` — no ANSI codes, no interactive prompts.

**TTY auto-detection:** when stdout is not a terminal (piped output, CI runner), `--no-ui` activates automatically — you never need to pass it explicitly in CI.

```sh
nitrogen <command> --no-ui
```

---

## Commands

| Command | TUI dashboard | CLI |
|---|---|---|
| `nitrogen init` | ✅ menu item | ✅ |
| `nitrogen generate` | ✅ menu item | ✅ |
| `nitrogen watch` | ✅ menu item | ✅ |
| `nitrogen link` | ✅ menu item | ✅ |
| `nitrogen doctor` | ✅ menu item | ✅ |
| `nitrogen migrate` | ✅ menu item | ✅ |
| `nitrogen update` | ✅ menu item | ✅ |
| `nitrogen open` | ✅ editor buttons | ✅ |
| `nitrogen clean` | ✅ menu item | ✅ |

---

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
| `pubspec.yaml` | Pre-wired with `nitro: ^0.5.0` and `nitro_generator: ^0.5.0` |

**You only ever edit:** the spec, the Kotlin impl, and the Swift impl (or a single C++ impl). Everything else is generated.

---

### `nitrogen generate`

Runs `flutter pub get` + `build_runner build`, syncs all generated files to their native destinations, then runs `nitrogen link` inline so you never need to run link separately after a normal generate.

```sh
nitrogen generate                          # full generation + link
nitrogen generate --no-ui                  # headless / CI
nitrogen generate --fail-on-warn           # exit 2 on spec warnings
nitrogen generate --dry-run                # preview without writing
nitrogen generate --check                  # exit 3 if outputs are stale
nitrogen generate --targets dart,swift     # restrict output targets
nitrogen generate --verbose                # show per-phase timing
```

**Flags:**

| Flag | Alias | Default | Description |
|---|---|---|---|
| `--no-ui` | — | `false` | Headless plain-text output (auto-enabled in CI / non-TTY) |
| `--fail-on-warn` | — | `false` | Exit code 2 if spec has any warnings |
| `--dry-run` | — | `false` | Print what would be generated without writing any files |
| `--check` | — | `false` | Verify outputs are up to date; exits 3 if any file is stale |
| `--targets` | — | _(all)_ | Comma-separated list of output targets to generate (see table below) |
| `--verbose` | `-v` | `false` | Show per-phase timing: pub get duration, build_runner duration, total |

**`--targets` aliases:**

| Alias | Files generated |
|---|---|
| `dart` / `ffi` | `.g.dart` |
| `kotlin` / `android` | `.g.dart`, `.bridge.g.kt`, `.bridge.g.h`, `.bridge.g.cpp`, `.CMakeLists.g.txt` |
| `swift` | `.bridge.g.swift` |
| `ios` / `macos` / `apple` | `.g.dart`, `.bridge.g.swift`, `.bridge.g.h`, `.bridge.g.cpp`, `.CMakeLists.g.txt` |
| `cpp` / `cbridge` / `bridge` | `.bridge.g.h`, `.bridge.g.cpp` |
| `cmake` / `build` | `.CMakeLists.g.txt` |
| `native` / `cpp_native` | `.native.g.h`, `.mock.g.h`, `.test.g.cpp` |
| `test` | `.mock.g.h`, `.test.g.cpp` |
| `windows` / `linux` / `desktop` | `.g.dart`, `.bridge.g.h`, `.bridge.g.cpp`, `.CMakeLists.g.txt`, `.native.g.h` |

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Generation error |
| `2` | Spec warnings present and `--fail-on-warn` was passed |
| `3` | Stale outputs detected (only with `--check`) |

**Incremental generation:** `nitrogen generate` hashes `.native.dart` spec files against a cache at `.dart_tool/nitro/cache.json`. If nothing changed and all outputs exist, `build_runner` is skipped entirely. The cache is invalidated automatically on any spec modification.

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

After generation, `nitrogen generate` runs the full `nitrogen link` patching logic inline (CMake, Podspec, Swift, Kotlin, Windows, Linux, `.clangd`), then runs `pod install` in every Podfile directory found.

**CI examples:**

```yaml
# .github/workflows/build.yml
- name: Generate Nitrogen bindings
  run: |
    dart pub global activate nitrogen_cli
    nitrogen generate --no-ui --fail-on-warn   # exit 2 on spec warnings

- name: Verify bindings are not stale
  run: nitrogen generate --check --no-ui       # exit 3 if stale
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

**What it wires (11 steps):**

1. Discovers all modules by scanning `lib/**/*.native.dart` specs.
2. **CMakeLists** (`src/CMakeLists.txt`) — adds `NITRO_NATIVE` path, `dart_api_dl.c`, bridge `.cpp` files, `CMAKE_CXX_STANDARD`, per-module `add_library` targets; creates `src/HybridXxx.cpp` implementation stubs if missing.
3. **iOS Podspec** — normalises `source_files`, sets Swift version, iOS deployment target, `HEADER_SEARCH_PATHS`, `DEFINES_MODULE`, `CLANG_CXX_LANGUAGE_STANDARD`, adds `s.dependency 'nitro'`; copies `dart_api_dl.c`, `nitro.h`, and Swift bridges into `ios/Classes/`; ensures `ios/<name>/Package.swift` (SPM) exists.
4. **macOS Podspec** — same as iOS with macOS-specific paths and deployment target.
5. **Swift plugin registrars** — injects `Registry.register(...)` calls into `ios/*Plugin.swift` and `macos/*Plugin.swift` for Swift/Kotlin modules; removes stale registrations for modules that switched to `NativeImpl.cpp`.
6. **Android Kotlin** — injects `System.loadLibrary(...)` and `JniBridge.register(...)` into `android/.../*Plugin.kt`; adds missing imports; removes stale registrations for Android C++ modules.
7. **Android Gradle** — ensures `kotlin.srcDirs` includes `generated/kotlin`.
8. **Windows CMakeLists** — adds `NITRO_NATIVE`, `dart_api_dl.c`, bridge files, include dirs; creates Windows C++ impl stubs in `windows/src/` if missing.
9. **Linux CMakeLists** — same as Windows.
10. **`.clangd`** — adds `generated/cpp/test/` to IDE compile flags for GoogleMock support when any cpp module exists.
11. **Build system finalise** — if SPM (`Package.swift`) is detected, syncs Swift bridges into `Sources/` dirs and verifies the `FlutterFramework` symlink; otherwise runs `pod deintegrate` + `pod install` + `pod update`.

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
| **System Toolchain** | `clang++`, Xcode (macOS host), `ANDROID_NDK_HOME`, Java, `cmake`; MSVC `cl.exe` + Windows SDK (Windows host); `g++`/`clang++` + `libpthread` (Linux host) |
| **pubspec.yaml** | `nitro`, `build_runner`, `nitro_generator` deps; `android pluginClass`/`package`, `ios`/`macos pluginClass`/`ffiPlugin` |
| **Apple SPM** (macOS only) | Flat vs nested `Package.swift` layout; `FlutterFramework` symlink; `Sources/<PluginCpp>/` completeness (`dart_api_dl.c`, plugin forwarder `.cpp`, `include/nitro.h`, `.bridge.g.mm` files) |
| **Generated Files** | Every expected output per spec — present and not stale |
| **CMakeLists.txt** | `NITRO_NATIVE` variable, `dart_api_dl.c`, `add_library` targets, `HybridXxx.cpp` linked for native-cpp modules, redundant `#include` in `.cpp` files |
| **Android** | `kotlin-android` plugin, `kotlinOptions` block, `generated/kotlin` sourceSets, `kotlinx-coroutines`, `System.loadLibrary`, `JniBridge.register`, missing imports, stale C++ registrations |
| **iOS / macOS** | `.podspec` (`s.dependency 'nitro'`, `HEADER_SEARCH_PATHS`, `CLANG_CXX_LANGUAGE_STANDARD`, `swift_version`, `source_files`), `*Plugin.swift` + `Registry.register`, stale `.bridge.g.cpp` (must be `.mm`), `dart_api_dl.c`, `nitro.h` |
| **Windows / Linux** | `NITRO_NATIVE`, `dart_api_dl.c`, bridge `.cpp` inclusions, `add_library` targets with `HybridXxx.cpp` |
| **Direct C++ modules** | `${lib}_register_impl` wired up; `.clangd` includes `generated/cpp/test/` |

**Direct C++ awareness:**

- Android: when all specs use direct C++, Kotlin JNI bridge checks are shown as `ℹ info` (not required) instead of errors.
- iOS/macOS: `Registry.register` check skipped; checks for `.native.g.h` headers in `ios/Classes/` instead; no `.bridge.g.mm` warning.
- Generated files: `.bridge.g.kt` / `.bridge.g.swift` shown as `ℹ info` (placeholder) for cpp modules; `.native.g.h`, `.mock.g.h`, `.test.g.cpp` checked as required outputs.

**TUI key bindings (interactive mode):**

| Key | Action |
|---|---|
| `↑` / `↓` | Scroll check list |
| `PgUp` / `PgDn` | Scroll by page |
| `Home` / `End` | Jump to top / bottom |
| `c` / `C` | Copy full report to clipboard |
| `ESC` | Exit |

**Exit codes:** `0` = all checks pass, `1` = one or more errors.

```yaml
# .github/workflows/build.yml
- name: Nitrogen health check
  run: |
    dart pub global activate nitrogen_cli
    nitrogen doctor --no-ui   # exits 1 on any error
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

1. Detects current build system state (legacy = CocoaPods-only, mixed = partial SPM, modern = SPM-only). Reports success immediately if already modern.
2. Prompts for confirmation in interactive mode (skipped with `--no-ui`).
3. Optionally backs up existing `ios/*.podspec` and `example/ios/Podfile` into a timestamped `.nitrogen_backup_<ts>/` directory.
4. Creates `ios/<name>/Package.swift` (Flutter 3.41+ nested SPM layout) with `Sources/<ClassName>/` (Swift target) and `Sources/<ClassName>Cpp/` (C++ target) pointing back to `Classes/` via symlinks.
5. Creates `macos/<name>/Package.swift` when `macos/` exists (same structure).
6. Creates the full SPM `Sources/` directory structure for both platforms.
7. Cleans up `example/ios/Podfile.lock`. CocoaPods `.podspec` files are preserved for backward compatibility.
8. Verifies the new SPM layout is detected correctly.

After migration, run `nitrogen link` to sync generated files into the new SPM layout.

---

### `nitrogen watch`

Runs `build_runner watch` and automatically re-links generated files on every change. Equivalent to running `nitrogen generate` on every spec save.

```sh
nitrogen watch           # streaming TUI output
nitrogen watch --no-ui   # headless, raw build_runner lines with [nitro] prefix
```

**Flags:**

| Flag | Default | Description |
|---|---|---|
| `--no-ui` | `false` | Headless plain-text output |

**What it does:**

1. Kills any running `build_runner` and removes `.dart_tool/build/` to prevent lock-file hangs.
2. Performs an initial `nitrogen link` sync to ensure all files are wired before watching.
3. Starts a file watcher on the project root (250 ms debounce) that re-links bridge files whenever a `.native.dart` spec is added, removed, or renamed.
4. Streams `build_runner watch --delete-conflicting-outputs` output. After each `"Succeeded after"` line, automatically calls the link sync to copy new Swift bridges into `ios/Classes/` / `macos/Classes/`.
5. Logs `"Generation failed. Fix the errors to continue syncing."` on `"Failed after"` lines without exiting — the watcher keeps running.

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

**What it removes:**

- Generated source files: `*.g.dart`, `*.bridge.g.swift`, `*.bridge.g.kt`, `*.bridge.g.cpp`, `*.bridge.g.h`, `*.bridge.g.mm`, `*.CMakeLists.g.txt`, `*.native.g.h`, `*.mock.g.h`, `*.test.g.cpp`, `Hybrid*.hpp`, `Hybrid*.cpp`
- Build caches: `.dart_tool/build/lock`, `.dart_tool/build/asset_graph.json`
- Incremental generation cache: `.dart_tool/nitro/cache.json`

Hidden directories and the `build/` output directory are skipped during the file walk.

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

Opens the Nitrogen project root in your editor. In the TUI dashboard this maps to the **Open in VS Code** and **Open in Antigravity** buttons. As a CLI command it accepts an `--editor` flag.

```sh
nitrogen open                   # opens in VS Code (default)
nitrogen open --editor code     # explicit VS Code
nitrogen open -e antigravity    # Antigravity (AI-first editor)
nitrogen open --no-ui           # headless
```

**Flags:**

| Flag | Alias | Default | Allowed values | Description |
|---|---|---|---|---|
| `--editor` | `-e` | `code` | `code`, `antigravity` | Editor CLI command to invoke with the project path |
| `--no-ui` | — | `false` | — | Headless plain-text output |

**What it does:** locates the Nitro project root, then runs `<editor> <project_path>` via the shell. If the editor command is not found in `PATH`, it prints an error with a hint to add it.

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

## Spec Examples

### Comprehensive type showcase (Swift/Kotlin path)

```dart
// lib/src/sensor.native.dart
import 'package:nitro/nitro.dart';
part 'sensor.g.dart';

// ── Enum ───────────────────────────────────────────────────────────────────
@HybridEnum(startValue: 0)
enum DeviceStatus { idle, busy, error }

// Non-contiguous values (mirror an OS SDK enum):
@HybridEnum(nativeValues: [0, 50, 100])
enum Quality { low, medium, high }

// ── Zero-copy struct (hot-path numeric data) ───────────────────────────────
@HybridStruct(packed: true)
class SensorData {
  final double temperature;
  final double humidity;
  final int timestampMs;
  const SensorData({
    required this.temperature,
    required this.humidity,
    required this.timestampMs,
  });
}

// ── Binary-encoded record (complex / infrequent data) ─────────────────────
@HybridRecord()
class DeviceInfo {
  final String name;
  final DeviceStatus status;
  final List<String> capabilities;
  const DeviceInfo({
    required this.name,
    required this.status,
    required this.capabilities,
  });
}

// ── Discriminated union ───────────────────────────────────────────────────
@NitroVariant()
sealed class ScanResult { const ScanResult(); }

class ScanFound extends ScanResult {
  final DeviceInfo device;
  const ScanFound({required this.device});
}
class ScanTimeout extends ScanResult { const ScanTimeout(); }
class ScanError extends ScanResult {
  final String message;
  const ScanError({required this.message});
}

// ── Named tuple type ──────────────────────────────────────────────────────
@NitroTuple()
typedef SignalStrength = (int, String); // (dbm, label)

// ── Module ────────────────────────────────────────────────────────────────
@NitroModule(
  lib: 'sensor',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  macos: AppleNativeImpl.swift,
)
abstract class SensorModule extends HybridObject {
  static final SensorModule instance = _SensorModuleImpl();

  // Synchronous calls
  DeviceStatus getStatus();
  List<DeviceInfo> listDevices();
  void updateSensors(SensorData data);
  SignalStrength getSignal();

  // Nullable return
  DeviceInfo? findDevice(String id);
  int? getLastErrorCode();

  // Async — background isolate (~930 µs overhead)
  @nitroAsync
  Future<List<DeviceInfo>> scanDevices();

  // Native async — native posts result (~146 µs overhead)
  @nitroNativeAsync
  Future<String> connectDevice(String deviceId);

  // Exception-free error result
  @NitroResult()
  @nitroNativeAsync
  Future<NitroResultValue<DeviceInfo>> authenticate(String token);

  // Discriminated union return
  @nitroNativeAsync
  Future<ScanResult> scan(int timeoutMs);

  // Zero-copy buffer
  void sendRawPacket(@zeroCopy Uint8List data);

  // Named param with default
  void configure({Quality quality = Quality.medium, int retryCount = 3});

  // Stream with backpressure
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorData> get sensorStream;

  @NitroStream(backpressure: Backpressure.batch, batchMaxSize: 64)
  Stream<double> get audioSamples;

  // Callback parameter
  void onDeviceFound(void Function(DeviceInfo device) callback);
}
```

### Cross-file type sharing

```dart
// lib/src/types.native.dart  ← type-only file, no @NitroModule
import 'package:nitro/nitro.dart';
part 'types.g.dart';

@HybridEnum()
enum Protocol { ble, wifi, usb }

@HybridRecord()
class ConnectionOptions {
  final Protocol protocol;
  final int? timeoutMs;  // nullable int
  const ConnectionOptions({required this.protocol, this.timeoutMs});
}
```

```dart
// lib/src/scanner.native.dart
import 'package:nitro/nitro.dart';
import 'types.native.dart';  // import shared types
part 'scanner.g.dart';

@NitroModule(
  lib: 'scanner',
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
)
abstract class Scanner extends HybridObject {
  static final Scanner instance = _ScannerImpl();

  @nitroNativeAsync
  Future<List<DeviceInfo>> scan(ConnectionOptions options);
}
```

The generator emits correct `#include "types.bridge.g.h"` in `scanner.bridge.g.h` and avoids re-declaring imported types.

---

## Supported Types Quick Reference

| Dart spec type | C | Kotlin | Swift |
|---|---|---|---|
| `int` | `int64_t` | `Long` | `Int64` |
| `double` | `double` | `Double` | `Double` |
| `bool` | `int8_t` | `Boolean` | `Bool` |
| `String` | `const char*` | `String` | `String` |
| `int?` | `NitroOptInt64` (9B struct) | `Long?` | `Int64?` |
| `double?` | `NitroOptFloat64` (9B struct) | `Double?` | `Double?` |
| `bool?` | `NitroOptBool` (2B struct) | `Boolean?` | `Bool?` |
| `String?` | `const char*` (null = absent) | `String?` | `String?` |
| `Uint8List` / `Float32List` / … | `T* + int64_t len` | `ByteArray` / `FloatArray` | `UnsafeMutablePointer<T>?, Int64` |
| `@zeroCopy Uint8List` | `T*` (pinned, no copy) | `java.nio.ByteBuffer` | `UnsafeMutablePointer<UInt8>?` |
| `@HybridEnum` | `int64_t` | `Long` | `Int64` |
| `@HybridStruct` | `void*` (packed struct) | `ByteArray` | `UnsafePointer<T>?` |
| `@HybridRecord` | `uint8_t*, int64_t len` | `ByteArray` | `UnsafePointer<UInt8>?` |
| `@NitroVariant` | `uint8_t*, int64_t len` | `ByteArray` | `UnsafePointer<UInt8>?` |
| `@NitroTuple` | `uint8_t*, int64_t len` | `ByteArray` | `UnsafePointer<UInt8>?` |
| `@NitroCustomType` | `uint8_t*, int64_t len` | `ByteArray` | `UnsafePointer<UInt8>?` |
| `List<T>` | record codec | `List<T>` | `[T]` |
| `Map<String, T>` | JSON `const char*` | `Map<String, T>` | `[String: T]` |
| `NativeHandle<Void>` | `void*` | `Long` | `Int64` |
| `Future<T>` (`@nitroAsync`) | — | `suspend fun` | `async throws` |
| `Future<T>` (`@nitroNativeAsync`) | — | `fun` + `Long port` | `func` + `Int64 port` |
| `Stream<T>` | register/release port | `Flow<T>` | `AnyPublisher<T, Never>` |

---

## Special Notes

### `dart:isolate` not needed in spec files (0.5.0+)

Generated `.g.dart` files are `part of` the user's spec and cannot have their own imports. Before 0.5.0, callback specs required `import 'dart:isolate'` because generated code uses `ReceivePort` for callback-release ports. As of 0.5.0, `package:nitro/nitro.dart` re-exports `ReceivePort` and `SendPort` conditionally (with a web stub). Remove any manual import from spec files.

```dart
// ❌ Before 0.5.0:
import 'dart:isolate';
import 'package:nitro/nitro.dart';
part 'my_module.g.dart';

// ✅ 0.5.0+:
import 'package:nitro/nitro.dart';
part 'my_module.g.dart';
```

### Async overhead comparison

| Annotation | Overhead | Mechanism | When to use |
|---|---|---|---|
| `@nitroAsync` | ~930 µs | Dart isolate pool | Native API that blocks; no native async support |
| `@nitroNativeAsync` | ~146 µs | `Dart_PostCObject_DL` | Native already has async (coroutines, Swift async) |

### Known limitations

| ID | Limitation | Workaround |
|---|---|---|
| L6 | `@HybridStruct` / `@HybridRecord` cannot be returned from a callback parameter. | Return `void`; use a reverse method call or stream. |
| L7 | `TypedData?` (nullable `Uint8List`, etc.) is not supported. | Wrap in `@HybridRecord`: `class MaybeBuffer { final Uint8List? data; }` |
| L8 | Web — `dart:ffi` unavailable; streams/callbacks throw `UnsupportedError`. | Guard platform-specific code. |
| L10 | `Map<String, @HybridStruct>` is not supported. | Use `Map<String, @HybridRecord>`. |

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
