# Platform Expansion Plan: Windows, Linux, and Web

## Overview

Extend Nitro to support Windows, Linux, and Web platforms while keeping all existing
`@NitroModule(ios, android, macos)` annotations fully backward-compatible.

**Delivery order:** Phase 1 → Phase 2 (Windows) → Phase 2 (Linux) → Phase 4 (test infra) → Phase 3 (Web)

---

## Design: Sealed Class Hierarchy for `NativeImpl`

`NativeImpl` is redesigned as a **sealed class** with per-platform subclasses.
Each subclass implements only the platform capability markers where it is valid.
This makes invalid combinations a **compile-time error**, not a runtime surprise.

```
NativeImpl (sealed)
├── SwiftImpl   implements AppleNativeImpl
├── KotlinImpl  implements AndroidNativeImpl
├── CppImpl     implements AppleNativeImpl, AndroidNativeImpl,
│                          WindowsNativeImpl, LinuxNativeImpl
└── WasmImpl    implements WebNativeImpl
```

`NitroModule` annotation fields are typed with the marker interfaces:

```dart
class NitroModule {
  final AppleNativeImpl?   ios;      // SwiftImpl or CppImpl only
  final AndroidNativeImpl? android;  // KotlinImpl or CppImpl only
  final AppleNativeImpl?   macos;    // SwiftImpl or CppImpl only
  final WindowsNativeImpl? windows;  // CppImpl only (only impl of WindowsNativeImpl)
  final LinuxNativeImpl?   linux;    // CppImpl only (only impl of LinuxNativeImpl)
  final WebNativeImpl?     web;      // WasmImpl only (only impl of WebNativeImpl)
}
```

**Compile-time guarantees:**

| Usage | Result |
|-------|--------|
| `@NitroModule(android: NativeImpl.wasm)` | ERROR — `WasmImpl` is not `AndroidNativeImpl` |
| `@NitroModule(ios: NativeImpl.kotlin)` | ERROR — `KotlinImpl` is not `AppleNativeImpl` |
| `@NitroModule(windows: NativeImpl.swift)` | ERROR — `SwiftImpl` is not `WindowsNativeImpl` |
| `@NitroModule(web: NativeImpl.cpp)` | ERROR — `CppImpl` is not `WebNativeImpl` |
| `@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)` | OK |
| `@NitroModule(windows: NativeImpl.cpp, linux: NativeImpl.cpp)` | OK |

**`BridgeSpec` internal fields** remain typed as `NativeImpl?` (the sealed base), not the marker
interfaces. This allows generators to do `is CppImpl` / `is SwiftImpl` pattern matching, and the
runtime `SpecValidator` retains its defensive checks as a secondary safety net.

**`SpecExtractor` reconstruction** switches from index-based `NativeImpl.values[index]`
(fragile — enum reordering silently breaks it) to **type-name-based** reconstruction:
```dart
return switch (object.type?.element?.name) {
  'SwiftImpl'  => NativeImpl.swift,
  'KotlinImpl' => NativeImpl.kotlin,
  'CppImpl'    => NativeImpl.cpp,
  'WasmImpl'   => NativeImpl.wasm,
  _            => throw InvalidGenerationSourceError('Unknown NativeImpl subclass: $typeName'),
};
```
Adding new platform impls in the future just adds a new `case` — no index ordering risk.

---

## Phase 1 — Foundation

Non-breaking annotation changes, `BridgeSpec` extension, validation rules, and CLI updates.
No generators change yet. Existing annotations compile unchanged.

### 1.1 `packages/nitro_annotations/lib/src/annotations.dart`

**Replace the enum** with sealed class hierarchy + platform capability markers:

```dart
// Platform capability marker interfaces (used as annotation field types)
abstract interface class AppleNativeImpl {}
abstract interface class AndroidNativeImpl {}
abstract interface class WindowsNativeImpl {}
abstract interface class LinuxNativeImpl {}
abstract interface class WebNativeImpl {}

sealed class NativeImpl {
  const NativeImpl._();
  static const swift  = SwiftImpl._();
  static const kotlin = KotlinImpl._();
  static const cpp    = CppImpl._();
  static const wasm   = WasmImpl._();
}

final class SwiftImpl extends NativeImpl implements AppleNativeImpl {
  const SwiftImpl._() : super._();
}
final class KotlinImpl extends NativeImpl implements AndroidNativeImpl {
  const KotlinImpl._() : super._();
}
final class CppImpl extends NativeImpl
    implements AppleNativeImpl, AndroidNativeImpl, WindowsNativeImpl, LinuxNativeImpl {
  const CppImpl._() : super._();
}
final class WasmImpl extends NativeImpl implements WebNativeImpl {
  const WasmImpl._() : super._();
}
```

**Update `NitroModule`** — add three new fields using marker interface types:

```dart
class NitroModule {
  final AppleNativeImpl?   ios;
  final AndroidNativeImpl? android;
  final AppleNativeImpl?   macos;
  final WindowsNativeImpl? windows;   // NEW — only NativeImpl.cpp is valid
  final LinuxNativeImpl?   linux;     // NEW — only NativeImpl.cpp is valid
  final WebNativeImpl?     web;       // NEW — only NativeImpl.wasm is valid
  final String?            cSymbolPrefix;
  final String?            lib;
  const NitroModule({...});
}
```

**Backward compatibility:** Existing `@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.cpp)` compiles unchanged. `NativeImpl.swift`, `.kotlin`, `.cpp` are now static const getters returning the same-named sealed subclass instances — the call-site API is identical.

### 1.2 `packages/nitro_generator/lib/src/bridge_spec.dart`

- Add fields `windowsImpl`, `linuxImpl`, `webImpl` (all `NativeImpl?`)
- Add getters `targetsWindows`, `targetsLinux`, `targetsWeb`
- Add `targetsDesktopCpp` (true when Windows or Linux uses cpp)
- Update `targetsAppleCpp` to use `is CppImpl` (more idiomatic with sealed classes)
- Extend `isCppImpl` to include Windows/Linux, **explicitly exclude web**:

```dart
bool get isCppImpl =>
    (iosImpl     == null || iosImpl     is CppImpl) &&
    (androidImpl == null || androidImpl is CppImpl) &&
    (macosImpl   == null || macosImpl   is CppImpl) &&
    (windowsImpl == null || windowsImpl is CppImpl) &&
    (linuxImpl   == null || linuxImpl   is CppImpl) &&
    // webImpl intentionally excluded — web is never a dart:ffi C++ target
    (iosImpl != null || androidImpl != null || macosImpl  != null ||
     windowsImpl != null || linuxImpl != null);
```

### 1.3 `packages/nitro_generator/lib/src/spec_extractor.dart`

Replace index-based `_getNativeImpl` with type-name-based switch (no index fragility):

```dart
static NativeImpl _getNativeImpl(DartObject object) {
  final typeName = object.type?.element?.name;
  return switch (typeName) {
    'SwiftImpl'  => NativeImpl.swift,
    'KotlinImpl' => NativeImpl.kotlin,
    'CppImpl'    => NativeImpl.cpp,
    'WasmImpl'   => NativeImpl.wasm,
    _ => throw InvalidGenerationSourceError(
      'Unknown NativeImpl subclass: "$typeName". '
      'Expected SwiftImpl, KotlinImpl, CppImpl, or WasmImpl.',
    ),
  };
}
```

Read three new annotation fields using the existing pattern:
```dart
final windowsImpl = annotation.read('windows').isNull ? null
    : _getNativeImpl(annotation.read('windows').objectValue);
final linuxImpl   = annotation.read('linux').isNull   ? null
    : _getNativeImpl(annotation.read('linux').objectValue);
final webImpl     = annotation.read('web').isNull     ? null
    : _getNativeImpl(annotation.read('web').objectValue);
```

Pass all three into the `BridgeSpec(...)` constructor call.

### 1.4 `packages/nitro_generator/lib/src/spec_validator.dart`

- **Extend `NO_TARGET_PLATFORM`** — cover all six platform fields:
```dart
if (spec.iosImpl == null && spec.androidImpl == null && spec.macosImpl == null &&
    spec.windowsImpl == null && spec.linuxImpl == null && spec.webImpl == null) {
  // NO_TARGET_PLATFORM error
}
```
Update the hint message to mention all six platforms.

- **Keep `INVALID_MACOS_IMPL`** as a defensive runtime check (user code is compile-time safe,
  but BridgeSpec is an internal class that could be constructed directly in tests):
```dart
if (spec.macosImpl is KotlinImpl) {
  // INVALID_MACOS_IMPL error
}
```

- **Add `INVALID_WINDOWS_IMPL`** (defensive — type system prevents this at annotation level):
```dart
if (spec.windowsImpl != null && spec.windowsImpl is! CppImpl) {
  // INVALID_WINDOWS_IMPL error
}
```

- **Add `INVALID_LINUX_IMPL`** (defensive):
```dart
if (spec.linuxImpl != null && spec.linuxImpl is! CppImpl) {
  // INVALID_LINUX_IMPL error
}
```

- **Add `INVALID_WEB_IMPL`** (defensive — the most dangerous one to miss at runtime,
  since `CppImpl` on web would generate `dart:ffi` code that fails to compile):
```dart
if (spec.webImpl != null && spec.webImpl is! WasmImpl) {
  // INVALID_WEB_IMPL error — mentions that dart:ffi is unavailable on web
}
```

### 1.5 `packages/nitrogen_cli/lib/commands/link_command.dart`

Extend the `isCppModule()` regex to include `windows` and `linux`:

```dart
// Before:
RegExp(r'\b(?:ios|android|macos)\s*:\s*NativeImpl\.cpp\b').hasMatch(annotation);

// After:
RegExp(r'\b(?:ios|android|macos|windows|linux)\s*:\s*NativeImpl\.cpp\b').hasMatch(annotation);
```

### Phase 1 — Test Changes

**Modify `packages/nitro_generator/test/test_utils.dart`** — add new spec helpers:

```dart
/// Windows-only with C++ (no iOS, Android, macOS, Linux).
BridgeSpec windowsOnlyCppSpec() => BridgeSpec(
  dartClassName: 'WinProcessor',
  lib: 'win_processor',
  namespace: 'win_processor',
  windowsImpl: NativeImpl.cpp,
  sourceUri: 'win_processor.native.dart',
  functions: [...],
);

/// Linux-only with C++.
BridgeSpec linuxOnlyCppSpec() => BridgeSpec(..., linuxImpl: NativeImpl.cpp, ...);

/// Windows + Linux shared C++ (no Apple, no Android).
BridgeSpec windowsLinuxCppSpec() => BridgeSpec(..., windowsImpl: NativeImpl.cpp, linuxImpl: NativeImpl.cpp, ...);

/// All five native C++ platforms.
BridgeSpec allNativeCppSpec() => BridgeSpec(..., iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp,
    macosImpl: NativeImpl.cpp, windowsImpl: NativeImpl.cpp, linuxImpl: NativeImpl.cpp, ...);

/// Web-only WASM spec.
BridgeSpec webOnlySpec() => BridgeSpec(..., webImpl: NativeImpl.wasm, ...);

/// Cross-platform: all five native platforms + web (maximum coverage).
BridgeSpec fullCrossPlatformSpec() => BridgeSpec(..., iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp,
    macosImpl: NativeImpl.cpp, windowsImpl: NativeImpl.cpp, linuxImpl: NativeImpl.cpp,
    webImpl: NativeImpl.wasm, ...);

/// Helper: returns specs for all single-platform C++ variants.
List<BridgeSpec> allCppPlatformSpecs() => [
  iosOnlyCppSpec(),
  androidOnlyCppSpec(),
  macosOnlyCppSpec(),
  windowsOnlyCppSpec(),
  linuxOnlyCppSpec(),
];
```

**Modify `packages/nitro_generator/test/platform_targeting_test.dart`** — add groups:

- `BridgeSpec — Windows/Linux targeting` (mirrors existing macOS targeting group):
  - `windowsImpl set → targetsWindows=true`
  - `windowsImpl set → isCppImpl=true`
  - `linuxImpl set → targetsLinux=true`
  - `windows + linux → isCppImpl=true, targetsIos=false`
  - `allNativeCppSpec → isCppImpl=true, all targets true`

- `BridgeSpec.isCppImpl — web excluded`:
  - `webImpl only → isCppImpl=false`
  - `webImpl + windowsImpl cpp → isCppImpl=true` (web doesn't disqualify)
  - `webImpl only → NO_TARGET_PLATFORM not raised` (web counts)

- `SpecValidator — Windows/Linux/Web impl constraints`:
  - `windowsImpl: NativeImpl.cpp → no INVALID_WINDOWS_IMPL`
  - `windowsImpl: NativeImpl.swift (forced via BridgeSpec) → INVALID_WINDOWS_IMPL error`
  - `linuxImpl: NativeImpl.cpp → no INVALID_LINUX_IMPL`
  - `linuxImpl: NativeImpl.kotlin (forced via BridgeSpec) → INVALID_LINUX_IMPL error`
  - `webImpl: NativeImpl.wasm → no INVALID_WEB_IMPL`
  - `webImpl: NativeImpl.cpp (forced via BridgeSpec) → INVALID_WEB_IMPL error`
  - `windows-only → no NO_TARGET_PLATFORM error`
  - `linux-only → no NO_TARGET_PLATFORM error`
  - `web-only → no NO_TARGET_PLATFORM error`

- `SpecValidator — defensive sealed class checks`:
  - Note: "These tests exercise runtime validator; the annotation API prevents these at
    compile time. Tests use BridgeSpec directly to force the invalid states."

**New `packages/nitro_generator/test/sealed_native_impl_test.dart`** — type-safety smoke tests:

- `NativeImpl.swift is SwiftImpl` → true
- `NativeImpl.kotlin is KotlinImpl` → true
- `NativeImpl.cpp is CppImpl` → true
- `NativeImpl.wasm is WasmImpl` → true
- `NativeImpl.cpp is AppleNativeImpl` → true (CppImpl implements it)
- `NativeImpl.cpp is AndroidNativeImpl` → true
- `NativeImpl.cpp is WindowsNativeImpl` → true
- `NativeImpl.cpp is LinuxNativeImpl` → true
- `NativeImpl.swift is AndroidNativeImpl` → false (SwiftImpl does NOT)
- `NativeImpl.kotlin is AppleNativeImpl` → false
- `NativeImpl.wasm is AppleNativeImpl` → false
- `NativeImpl.wasm is WindowsNativeImpl` → false
- `NativeImpl.wasm is AndroidNativeImpl` → false
- Exhaustive switch compiles and covers all cases: `switch(impl) { case SwiftImpl(): ... case KotlinImpl(): ... case CppImpl(): ... case WasmImpl(): ... }`

**Modify `packages/nitrogen_cli/test/link_command_test.dart`** — add new isCppModule cases:
- `windows: NativeImpl.cpp → isCppModule=true`
- `linux: NativeImpl.cpp → isCppModule=true`
- `windows + linux both cpp → isCppModule=true`

---

## Phase 2 — Windows and Linux

Generator platform guards, CMake cross-platform linking, CLI link/init/doctor.
Windows and Linux follow an identical pattern — implement Windows first, then replicate for Linux.

### 2.1 `packages/nitro_generator/lib/src/generators/cpp_bridge_generator.dart`

Extend platform guard logic in `_generateCppDirect()`:

| Targeted platforms | Guard emitted |
|--------------------|---------------|
| Windows only | `#ifdef _WIN32` |
| Linux only | `#ifdef __linux__` |
| Windows + Linux | `#if defined(_WIN32) \|\| defined(__linux__)` |
| Apple only | `#ifdef __APPLE__` |
| Android + Windows | `#if defined(__ANDROID__) \|\| defined(_WIN32)` |
| All five native C++ platforms | *(no guard)* |

`NITRO_EXPORT` in `nitro.h` already has `__declspec(dllexport)` for `_WIN32` — no changes to
generated C++ content are needed beyond the guards.

### 2.2 `packages/nitro_generator/lib/src/generators/cmake_generator.dart` (both copies)

Two copies exist — both must be updated:
- `packages/nitro_generator/lib/src/generators/cmake_generator.dart` (imported by `builder.dart`)
- `packages/nitro_generator/lib/src/generators/build/cmake_generator.dart` (audit for callers)

Replace hard-coded Android link libraries with cross-platform conditional:

```cmake
if(ANDROID)
    target_link_libraries(${MODULE_TARGET} android log)
elseif(WIN32)
    # No extra system libs on Windows
elseif(UNIX AND NOT APPLE)
    target_link_libraries(${MODULE_TARGET} dl pthread)
endif()
```

### 2.3 `packages/nitrogen_cli/lib/commands/link_command.dart`

**New `linkWindows()`** function:
1. Skip if `windows/` directory does not exist
2. Read `windows/CMakeLists.txt`
3. Insert `NITRO_NATIVE` variable resolved via `resolveNitroNativePath()`
4. Add `dart_api_dl.c` to source list
5. Add generated `.bridge.g.cpp` to source list
6. Add `target_include_directories` with nitro native path, `src/`, `generated/cpp/`
7. Add `set_source_files_properties(dart_api_dl.c PROPERTIES LANGUAGE C)` — MSVC must
   compile it as C, not C++ (void* casts are valid in C but not C++)

**New `linkLinux()`** — identical structure targeting `linux/`.

**Update `linkCppImplStubs()`** — emit cross-platform registration stub
(`__attribute__((constructor))` is not available on MSVC):

```cpp
#if defined(_WIN32)
// Windows: MSVC does not support __attribute__((constructor))
static const int _nitro_reg = []() {
    ${lib}_register_impl(&g_impl);
    return 0;
}();
#else
__attribute__((constructor))
static void ${lib}_auto_register() { ${lib}_register_impl(&g_impl); }
#endif
```

### 2.4 `packages/nitrogen_cli/lib/commands/init_command.dart`

- Add `--platforms` flag (e.g. `nitrogen init my_plugin --platforms=ios,android,macos,windows,linux`)
- Parameterize the `flutter create --platforms=...` argument
- Add `_configureWindows(String pluginName)` and `_configureLinux(String pluginName)` steps

### 2.5 `packages/nitrogen_cli/lib/commands/doctor_command.dart`

**Windows checks** (gated on `Platform.isWindows`):
- Visual Studio Build Tools: `where cl`
- CMake: `cmake --version`
- Windows SDK: check `WINDOWSSDKDIR` env var

**Linux checks** (gated on `Platform.isLinux`):
- C++ compiler: `g++ --version` or `clang++ --version`
- CMake: `cmake --version`
- pkg-config: `pkg-config --version`
- Ninja (warn, not error): `ninja --version`

### Phase 2 — New Tests

- `cmake_generator_test.dart`: Windows/Linux CMake cross-platform link blocks
- `cpp_bridge_generator_test.dart`: `#ifdef _WIN32`, `#ifdef __linux__`, combined guards
- `link_command_test.dart`: Windows/Linux CMakeLists patching, skip when directory absent

---

## Phase 3 — Web / WASM

Web is architecturally separate — `dart:ffi` does not exist on web.

**Scope:** Generator produces the Dart-side JS interop layer (`@JS()` external declarations).
Users compile their C++ to WASM via Emscripten separately (out of scope for codegen).

### 3.1 Split `packages/nitro/lib/src/nitro_runtime.dart`

Must use **conditional exports** (not `kIsWeb` — a runtime check does not prevent `dart:ffi`
from being imported at compile time on web, which is a compile error):

```
packages/nitro/lib/src/
├── nitro_runtime.dart          ← conditional export entry point
├── nitro_runtime_native.dart   ← existing DynamicLibrary logic
└── nitro_runtime_web.dart      ← NEW: dart:js_interop path
```

```dart
// nitro_runtime.dart
export 'nitro_runtime_stub.dart'
    if (dart.library.ffi)         'nitro_runtime_native.dart'
    if (dart.library.js_interop)  'nitro_runtime_web.dart';
```

### 3.2 New `packages/nitro_generator/lib/src/generators/web_bridge_generator.dart`

Generates the Dart-side JS interop file for a `NativeImpl.wasm` spec. Output:
```dart
@JS('NitroModules.${spec.lib}')
library;
import 'dart:js_interop';

@JS() external double mathAdd(double a, double b);
@JS() external String mathGetGreeting(String name);
```

### 3.3 `packages/nitro_generator/lib/src/generators/dart_ffi_generator.dart`

When `spec.webImpl != null`, emit `kIsWeb`-conditional factory alongside native class:
```dart
class _${Class}Impl extends $Class { /* FFI impl */ }
class _${Class}WebImpl extends $Class { /* @JS extern delegates */ }
$Class create${Class}() => kIsWeb ? _${Class}WebImpl() : _${Class}Impl();
```

### 3.4 `packages/nitro_generator/lib/builder.dart`

Add `lib/.../generated/web/{{file}}.web.g.dart` to `buildExtensions`. Dispatch to
`WebBridgeGenerator.generate(spec)` when targeting web.

### Phase 3 — New Tests

- `web_bridge_generator_test.dart`: `@JS()` externals, `kIsWeb` factory, non-web specs excluded
- `nitro_runtime_web_test.dart`: `loadLib()` returns `WebNitroModule`, conditional export works

---

## Phase 4 — Test Infrastructure

### 4.1 Parameterized helpers in `test_utils.dart`

`allCppPlatformSpecs()` returns one spec per C++ platform so generators can be tested
uniformly across all five native targets in a single loop.

### 4.2 New `spec_roundtrip_test.dart`

All valid platform combos pass validation. Invalid combos
(`windowsImpl: NativeImpl.kotlin forced via BridgeSpec`) trigger the correct error codes.

### 4.3 CI Matrix (documentation)

All generator and validator tests are pure Dart — they run on any host OS without a native
toolchain. New Windows/Linux platform guards are tested by asserting the generated text strings,
not by native compilation.

---

## Risk Register

| # | Risk | Impact | Mitigation |
|---|------|--------|------------|
| 1 | `SpecExtractor._getNativeImpl` encounters unknown type | Throws `InvalidGenerationSourceError` with confusing message | Type-name switch has exhaustive `_` case with clear error message |
| 2 | `isCppImpl` accidentally includes `web` | C++ bridge generator emits `dart:ffi` code → web compile failure | `INVALID_WEB_IMPL` validator + `isCppImpl` explicitly excludes `webImpl` |
| 3 | `kIsWeb` used instead of conditional export | `dart:ffi` imported at compile time on web → compile error | Phase 3.1 mandates conditional export split |
| 4 | Windows `__attribute__((constructor))` missing on MSVC | Plugin silently fails to register impl; null-ptr crash on first call | Cross-platform stub in Phase 2.3; doctor check validates stub |
| 5 | `dart_api_dl.c` compiled as C++ on MSVC | Void* cast errors → build failure | `set_source_files_properties` in Windows CMake (Phase 2.3) |
| 6 | Two copies of `CMakeGenerator` diverge | One copy gets Windows/Linux fixes; other emits wrong output | Both copies updated in Phase 2.2; audit `build/` copy for callers |
| 7 | `NativeImpl` sealed class used in exhaustive switch elsewhere | Adding `WasmImpl` breaks existing `switch` without `_` case | Sealed classes give compile-time exhaustiveness warnings for switches missing a case |

---

## File Change Summary

| Package | File | Phase | Change type |
|---------|------|-------|-------------|
| `nitro_annotations` | `lib/src/annotations.dart` | 1 | Modify |
| `nitro_generator` | `lib/src/bridge_spec.dart` | 1 | Modify |
| `nitro_generator` | `lib/src/spec_extractor.dart` | 1 | Modify |
| `nitro_generator` | `lib/src/spec_validator.dart` | 1 | Modify |
| `nitro_generator` | `lib/src/generators/cpp_bridge_generator.dart` | 2 | Modify |
| `nitro_generator` | `lib/src/generators/cmake_generator.dart` | 2 | Modify |
| `nitro_generator` | `lib/src/generators/build/cmake_generator.dart` | 2 | Modify |
| `nitro_generator` | `lib/src/generators/dart_ffi_generator.dart` | 3 | Modify |
| `nitro_generator` | `lib/src/generators/web_bridge_generator.dart` | 3 | **New** |
| `nitro_generator` | `lib/builder.dart` | 3 | Modify |
| `nitro` | `lib/src/nitro_runtime.dart` | 3 | Split |
| `nitro` | `lib/src/nitro_runtime_native.dart` | 3 | **New** |
| `nitro` | `lib/src/nitro_runtime_web.dart` | 3 | **New** |
| `nitrogen_cli` | `lib/commands/link_command.dart` | 1, 2 | Modify |
| `nitrogen_cli` | `lib/commands/init_command.dart` | 2, 3 | Modify |
| `nitrogen_cli` | `lib/commands/doctor_command.dart` | 2, 3 | Modify |
| `nitro_generator` | `test/test_utils.dart` | 1, 4 | Modify |
| `nitro_generator` | `test/platform_targeting_test.dart` | 1 | Modify |
| `nitro_generator` | `test/sealed_native_impl_test.dart` | 1 | **New** |
| `nitro_generator` | `test/cmake_generator_test.dart` | 2 | Modify |
| `nitro_generator` | `test/cpp_bridge_generator_test.dart` | 2 | Modify |
| `nitro_generator` | `test/spec_roundtrip_test.dart` | 4 | **New** |
| `nitro_generator` | `test/web_bridge_generator_test.dart` | 3 | **New** |
| `nitrogen_cli` | `test/link_command_test.dart` | 1, 2 | Modify |
| `nitrogen_cli` | `test/doctor_command_test.dart` | 4 | Modify |
| `nitro` | `test/nitro_runtime_web_test.dart` | 3 | **New** |
