# Cross-Platform Expansion Plan

## Current State

| Platform | `NativeImpl`  | Generator output     | Scaffold | Runtime load                  |
|----------|---------------|----------------------|----------|-------------------------------|
| iOS      | `swift`       | Swift + C bridge     | ✅       | `DynamicLibrary.process()`    |
| macOS    | _(none)_      | reuses iOS Swift gen | ❌       | `DynamicLibrary.process()`    |
| Android  | `kotlin`      | Kotlin JNI bridge    | ✅       | `DynamicLibrary.open(.so)`    |
| Windows  | _(none)_      | ❌ no generator      | ❌       | `DynamicLibrary.open(.dll)`   |
| Linux    | _(none)_      | ❌ no generator      | ❌       | `DynamicLibrary.open(.so)`    |
| Web      | _(none)_      | ❌                   | ❌       | ❌ FFI unavailable            |

---

## Phase 1 — macOS

**Effort: ~2 days. Risk: low — reuses the existing Swift generator unchanged.**

macOS already works at runtime (`DynamicLibrary.process()`, identical to iOS). The gaps are the annotation, the scaffold, and the generator's conditional blocks.

### 1a. Annotation — add `macos` field

`packages/nitro_annotations/lib/src/nitro_module.dart`

```dart
const class NitroModule {
  final NativeImpl? ios;
  final NativeImpl? android;
  final NativeImpl? macos;   // new
  const NitroModule({this.ios, this.android, this.macos});
}
```

### 1b. `BridgeSpec` — propagate `macosImpl`

`packages/nitro_generator/lib/src/bridge_spec.dart`

Add `NativeImpl? macosImpl` to `BridgeSpec`. The spec extractor reads the new annotation field and populates it.

### 1c. Dart FFI generator — explicit macOS branch

`packages/nitro_generator/lib/src/generators/dart_ffi_generator.dart`

The generated `_init()` already falls through to `DynamicLibrary.process()` for iOS and macOS, but it does so implicitly. Make it explicit:

```dart
if (Platform.isIOS || Platform.isMacOS) {
  lib = DynamicLibrary.process();
}
```

### 1d. Swift generator — macOS `platforms:` entry

`packages/nitro_generator/lib/src/generators/swift_generator.dart`

The `.podspec` output needs a macOS deployment target alongside iOS:

```ruby
s.platforms = { :ios => '13.0', :osx => '10.15' }
```

And `Package.swift` needs:

```swift
platforms: [.iOS(.v13), .macOS(.v10_15)],
```

### 1e. `nitrogen_cli` scaffold

`packages/nitrogen_cli/lib/commands/init_command.dart`

```bash
# before
flutter create --template=plugin_ffi --platforms=android,ios ...

# after
flutter create --template=plugin_ffi --platforms=android,ios,macos ...
```

Also generate `macos/Classes/${ClassName}Plugin.swift` — mirrors the iOS entry point verbatim.

### 1f. Tests

- Add `macosImpl: NativeImpl.swift` to spec helper builders in `test_utils.dart`.
- `platform_targeting_test.dart`: `macosImpl` alone, `macosImpl + iosImpl`, `macosImpl + androidImpl`.
- `spec_validator`: accept `macos` as a valid targeting field; reject `NativeImpl.kotlin` for macOS.

---

## Phase 2 — Windows and Linux

**Effort: ~3 days (Windows) + ~2 days (Linux). Risk: medium — requires a new generator.**

Windows and Linux have no JNI/Swift bridge. They use pure C++. `NativeImpl.cpp` exists but the generator, scaffold, and annotations are incomplete.

### 2a. Annotation — add `windows` and `linux` fields

`packages/nitro_annotations/lib/src/nitro_module.dart`

```dart
const class NitroModule {
  final NativeImpl? ios;
  final NativeImpl? android;
  final NativeImpl? macos;
  final NativeImpl? windows;   // new — only valid value: NativeImpl.cpp
  final NativeImpl? linux;     // new — only valid value: NativeImpl.cpp
  const NitroModule({this.ios, this.android, this.macos, this.windows, this.linux});
}
```

`SpecValidator` must reject `NativeImpl.swift` or `NativeImpl.kotlin` for these platforms with a clear error:

```
Error: windows only supports NativeImpl.cpp. Got NativeImpl.swift.
```

### 2b. `BridgeSpec` — add `windowsImpl`, `linuxImpl`

`packages/nitro_generator/lib/src/bridge_spec.dart`

Same pattern as `iosImpl` / `androidImpl`. Spec extractor reads both new fields.

### 2c. Dart FFI generator — desktop load paths

`packages/nitro_generator/lib/src/generators/dart_ffi_generator.dart`

The generated `_init()` currently lacks explicit Windows/Linux branches:

```dart
} else if (Platform.isWindows) {
  lib = DynamicLibrary.open('${spec.lib}.dll');
} else if (Platform.isLinux) {
  lib = DynamicLibrary.open('lib${spec.lib}.so');
}
```

Also verify `nitro_runtime.dart` matches — both must agree on the load path.

### 2d. New generator: `CppDesktopGenerator`

`packages/nitro_generator/lib/src/generators/cpp_desktop_generator.dart`

Emits the abstract C++ interface and registration stub for Windows/Linux (no JNI globals, no Objective-C blocks):

```cpp
// ${lib}.desktop.g.h
class ${ClassName} {
 public:
  virtual ~${ClassName}() = default;
  virtual double add(double a, double b) = 0;
  // ... one pure-virtual method per spec function/property
};

// Called once from the plugin entry point (${ClassName}Plugin.cpp)
void ${lib}_register_impl(${ClassName}* impl);
```

`CppBridgeGenerator` already has a `NativeImpl.cpp` path — audit it to confirm no JNI or Objective-C blocks are emitted when targeting Windows/Linux only.

### 2e. CMake generator — desktop compiler flags

`packages/nitro_generator/lib/src/generators/cmake_generator.dart`

```cmake
if(WIN32)
  target_compile_options(${NITRO_MODULE_NAME} PRIVATE /W3 /WX-)
  target_link_libraries(${NITRO_MODULE_NAME} PRIVATE flutter flutter_wrapper_plugin)
elseif(UNIX AND NOT APPLE)
  target_compile_options(${NITRO_MODULE_NAME} PRIVATE -Wall -Wextra)
  target_link_libraries(${NITRO_MODULE_NAME} PRIVATE flutter)
endif()
```

Confirm `dart_api_dl.c` is in the source list — it is required for `Dart_PostCObject` (streams).

### 2f. `nitrogen_cli` scaffold — desktop entry points

`packages/nitrogen_cli/lib/commands/init_command.dart`

Add `windows` and `linux` to `flutter create --platforms` when the developer opts in.

Generate per-platform files:
- `windows/CMakeLists.txt` — Flutter plugin wrapper
- `windows/${ClassName}Plugin.cpp` — calls `${lib}_register_impl(new My${ClassName}Impl())`
- `linux/CMakeLists.txt` — same shape, GNU flags
- `linux/${ClassName}_plugin.cc` — same registration pattern

### 2g. Tests

- `platform_targeting_test.dart`: `windowsImpl` alone, `linuxImpl` alone, all-platforms spec.
- `cmake_generator_test.dart`: MSVC flags emitted for Windows, GNU flags for Linux.
- `cpp_bridge_generator_test.dart`: No JNI block emitted when only `windowsImpl: NativeImpl.cpp`.
- `spec_validator_test.dart`: `NativeImpl.swift` on Windows produces a validation error.

---

## Phase 3 — Web

**Effort: Phase 3a ~1 week, Phase 3b 2+ weeks. Risk: high — fundamentally different execution model.**

Web has no `dart:ffi`. Two strategies, delivered in sequence.

### Phase 3a — JS interop stubs (near-term)

Generate a `*.web.dart` file with `@JS()` annotated externals that delegate to a hand-authored JavaScript module. This provides an escape hatch for plugins that can tolerate JS-boundary overhead.

**3a-i. Annotation**

```dart
const class NitroModule {
  // ...existing fields...
  final NativeImpl? web;   // new — only valid value: NativeImpl.js (see below)
}
```

Add `NativeImpl.js` to the enum in `packages/nitro_annotations/lib/src/native_impl.dart`.

**3a-ii. New generator: `JsInteropGenerator`**

`packages/nitro_generator/lib/src/generators/js_interop_generator.dart`

Emits `*.web.dart`:

```dart
// Generated — do not edit.
import 'package:js/js.dart';

@JS('${lib}.add')
external double _jsAdd(double a, double b);

class ${ClassName}Impl implements ${ClassName} {
  @override
  double add(double a, double b) => _jsAdd(a, b);
}
```

**3a-iii. Dart FFI generator — `kIsWeb` guard**

```dart
import 'package:flutter/foundation.dart' show kIsWeb;

static void _init() {
  if (kIsWeb) {
    // Delegates to JS interop layer — see *.web.dart
    return;
  }
  // ... existing FFI load logic
}
```

**3a-iv. Limitations to document**

- No zero-copy: all data crosses the JS boundary via serialisation.
- Streams require a JS `EventEmitter` equivalent — not auto-generated; developer provides glue.
- Only recommended for infrequent, low-bandwidth calls.

### Phase 3b — WASM + dart:ffi (long-term)

Flutter Web with `--wasm` (Flutter 3.22+) exposes `dart:ffi` access to WASM linear memory. C++ compiles to WASM via Emscripten and the same FFI bindings apply.

**Required additions:**

| Component | Change |
|---|---|
| CMake generator | Emscripten toolchain file; `EXPORTED_FUNCTIONS` list |
| `dart_ffi_generator.dart` | `if (kIsWasm)` path — skip `DynamicLibrary.open()` (WASM links statically) |
| Streams | Replace `Dart_PostCObject` with `dart:js_interop` callback; `Dart_PostCObject` is unavailable in WASM |
| Isolate pool | Disable on Web — WASM is single-threaded; `callAsync` falls back to sync execution |

**Gate:** Ship after Flutter stable declares WASM production-ready (tracked at flutter/flutter#128319).

---

## Phase 4 — Cross-cutting concerns

**Effort: ~1 day. No new generators — audit and polish.**

### 4a. `SpecValidator` — missing-platform warnings

```
Warning: BenchmarkCpp targets ios + android but not macos, windows, or linux.
  Hint: Add macos: NativeImpl.swift to @NitroModule to cover macOS.
```

Controlled by a new flag in `NitroConfig`: `warnOnMissingPlatforms` (default `true`).

### 4b. Generated `_init()` — actionable assertion

Replace the silent fall-through on unsupported platforms with a named assertion:

```dart
assert(
  Platform.isIOS || Platform.isAndroid || Platform.isMacOS ||
  Platform.isWindows || Platform.isLinux,
  '${spec.dartClassName} has no native implementation for the current platform. '
  'Add the platform to @NitroModule and regenerate.',
);
```

### 4c. `nitrogen_cli doctor` — per-platform toolchain checks

`packages/nitrogen_cli/lib/commands/doctor_command.dart`

| Platform | Check |
|----------|-------|
| iOS / macOS | Xcode + CocoaPods |
| Android | NDK + CMake |
| Windows | Visual Studio Build Tools (`cl.exe` on PATH) |
| Linux | `build-essential`, `cmake`, `ninja-build` |
| Web/WASM | Emscripten (`emcc` on PATH) |

### 4d. CI matrix

Add GitHub Actions jobs for each desktop platform. The generator tests (`jni_perf_test.dart`, `cmake_generator_test.dart`, etc.) are pure Dart and already run cross-platform — no new test logic needed.

```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
steps:
  - run: flutter test packages/nitro_generator/test/
  - run: flutter build ${{ matrix.platform }}   # macos / linux / windows
```

---

## Delivery order

```
Phase 1 — macOS          PR 1   ~2 days    (lowest risk, reuses Swift gen)
Phase 2a — Windows       PR 2   ~3 days
Phase 2b — Linux         PR 3   ~2 days    (mirrors Windows)
Phase 4 — Cross-cutting  PR 4   ~1 day     (validator, doctor, CI)
Phase 3a — Web stubs     PR 5   ~1 week
Phase 3b — WASM          PR 6   2+ weeks   (after Flutter WASM stabilises)
```

## File change summary

| File | Change |
|------|--------|
| `nitro_annotations/lib/src/nitro_module.dart` | Add `macos`, `windows`, `linux`, `web` fields |
| `nitro_annotations/lib/src/native_impl.dart` | Add `NativeImpl.js` |
| `nitro_generator/lib/src/bridge_spec.dart` | Add `macosImpl`, `windowsImpl`, `linuxImpl`, `webImpl` |
| `nitro_generator/lib/src/spec_extractor.dart` | Read new annotation fields into `BridgeSpec` |
| `nitro_generator/lib/src/spec_validator.dart` | Per-platform `NativeImpl` constraints; missing-platform warnings |
| `nitro_generator/lib/src/generators/dart_ffi_generator.dart` | Explicit macOS/Windows/Linux load paths; `kIsWeb` guard |
| `nitro_generator/lib/src/generators/swift_generator.dart` | `platforms:` macOS entry in podspec and Package.swift |
| `nitro_generator/lib/src/generators/cmake_generator.dart` | MSVC/GCC flags; Emscripten toolchain |
| `nitro_generator/lib/src/generators/cpp_bridge_generator.dart` | Verify Windows/Linux branch has no JNI/ObjC blocks |
| `nitro_generator/lib/src/generators/cpp_desktop_generator.dart` | **New** — abstract interface + registration stub |
| `nitro_generator/lib/src/generators/js_interop_generator.dart` | **New** — Web `@JS()` stub emitter |
| `nitro/lib/src/nitro_runtime.dart` | Explicit Windows/Linux/macOS load branches |
| `nitro/lib/src/nitro_config.dart` | `warnOnMissingPlatforms` flag |
| `nitrogen_cli/lib/commands/init_command.dart` | macOS/Windows/Linux in `flutter create --platforms` |
| `nitrogen_cli/lib/commands/doctor_command.dart` | Per-platform toolchain checks |
