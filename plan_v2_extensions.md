# Nitro Ecosystem — v2 Extension Plan

> Promoting two v1 non-goals to first-class features:
> 1. **Automatic C ABI Versioning** — catch breaking ABI changes at build time, not runtime
> 2. **Desktop Platform Support** — Windows, Linux, and macOS (beyond Android + iOS)

---

## Background

The current `plan.md` explicitly lists these as non-goals for v1:

```
- Windows / Linux / macOS desktop (Android + iOS only)
- Automatic C ABI versioning
```

Both are now promoted because:
- Desktop Flutter adoption is growing; plugin authors increasingly expect `ffiPlugin: true` to just work on all 6 platforms.
- ABI mismatches between generated headers and native implementations are the #1 silent failure mode: a regenerated `.h` + stale `.cpp` compiles fine but crashes at runtime.

---

## Feature A — Automatic C ABI Versioning

### Problem

Today, if a spec changes (e.g. a parameter type widens from `int32_t` → `int64_t`), the generator produces a new `.h` but the previously compiled `.so`/`.dylib` still exports the old symbol layout. The app crashes at runtime with `EXC_BAD_ACCESS` or a silent misread. There is no build-time signal.

### Goals

| # | Goal |
|---|------|
| A1 | Detect any ABI-incompatible change (type, arity, calling convention) before the app ships |
| A2 | Zero friction for plugin authors: the versioning is entirely generated, no manual tagging |
| A3 | Human-readable diff when a breaking change is detected |
| A4 | Opt-in "panic on ABI break" CI mode (`--strict-abi`) |
| A5 | Forward-compatible: non-breaking additions (new functions) are additive and warn, not error |

### ABI Change Classification

| Change type | ABI impact | Verdict |
|-------------|-----------|---------|
| Add a new function | Additive | ⚠️ WARN (old `.so` still loads, new symbol missing) |
| Remove a function | Breaking | 🔴 ERROR |
| Rename a function | Breaking | 🔴 ERROR |
| Change param type (same width) | Breaking | 🔴 ERROR |
| Change param type (different width) | Breaking | 🔴 ERROR |
| Change return type | Breaking | 🔴 ERROR |
| Reorder params | Breaking | 🔴 ERROR |
| Add optional param (nullable, default) | Additive | ⚠️ WARN |
| Change struct field order | Breaking | 🔴 ERROR |
| Add struct field | Breaking | 🔴 ERROR |
| Change calling convention | Breaking | 🔴 ERROR |

### Design: ABI Fingerprint File

The generator emits a new file alongside every spec:

**File:** `Foo_bridge.g.abi` (committed to VCS, next to generated `.h`)

```json
{
  "nitro_abi_version": 1,
  "spec": "Camera",
  "generated_at": "2026-04-01T10:00:00Z",
  "generator_version": "0.4.0",
  "functions": [
    {
      "c_symbol": "vc_capture_photo",
      "return": "void*",
      "params": [
        { "name": "output_dir", "type": "const char*" },
        { "name": "quality",    "type": "int64_t" }
      ],
      "fingerprint": "sha256:3a9f2c..."
    }
  ],
  "structs": [
    {
      "name": "CameraFrame",
      "packed": false,
      "fields": [
        { "name": "data",         "type": "uint8_t*" },
        { "name": "width",        "type": "int64_t"  },
        { "name": "height",       "type": "int64_t"  },
        { "name": "stride",       "type": "int64_t"  },
        { "name": "timestamp_ns", "type": "int64_t"  }
      ],
      "fingerprint": "sha256:7b1d4e..."
    }
  ],
  "abi_hash": "sha256:9c3f5a..."
}
```

**`abi_hash`** is a deterministic SHA-256 over the full sorted symbol table (names, types, offsets). It is independent of comments, formatting, and Dart-side changes.

### Design: ABI Guard Header (generated C)

The `CppHeaderGenerator` also emits a **compile-time ABI guard** in every `.g.h`:

```c
// Foo_bridge.g.h  — excerpt

// ── ABI guard ──────────────────────────────────────────────────────────────
// This constant is recomputed on every `nitrogen generate`.
// Link against a shared library compiled from a DIFFERENT spec version will
// produce a linker or runtime error rather than a silent mismatch.
#define FOO_NITRO_ABI_HASH 0x9c3f5a12UL

#ifdef FOO_NITRO_ABI_HASH_ACTUAL
  #if FOO_NITRO_ABI_HASH_ACTUAL != FOO_NITRO_ABI_HASH
    #error "Nitro ABI mismatch: regenerate with `nitrogen generate`"
  #endif
#endif
// ───────────────────────────────────────────────────────────────────────────

extern "C" {
  void* vc_capture_photo(const char* output_dir, int64_t quality);
  // ...
}
```

In the native implementation file (`FooImpl.cpp` or the JNI bridge), the generated `_bridge.g.cpp` defines `FOO_NITRO_ABI_HASH_ACTUAL` so the check fires at compile time:

```c
// Foo_bridge.g.cpp  (auto-generated, never hand-edited)
#define FOO_NITRO_ABI_HASH_ACTUAL 0x9c3f5a12UL
#include "Foo_bridge.g.h"   // triggers the static_assert if hashes differ
```

### Design: Generator ABI Diff Engine

When `nitrogen generate` runs and a `Foo_bridge.g.abi` already exists on disk, it performs a **diff** before overwriting:

```
$ nitrogen generate
[nitro] ABI diff: Camera
  🔴 BREAKING  vc_capture_photo  param[1] type changed: int32_t → int64_t
  ⚠️  ADDITIVE  vc_get_resolution  new symbol (callers with old .so will crash)
  ✅  UNCHANGED vc_start
  ✅  UNCHANGED vc_stop

Run with --force to accept and overwrite the ABI snapshot.
```

Without `--force`, generation fails if any 🔴 BREAKING changes are found. This prevents accidentally producing mismatched headers.

### Design: `nitrogen doctor --abi`

Extends the existing `doctor` command:

```
$ nitrogen doctor --abi
Checking Camera...
  abi_hash in Camera_bridge.g.abi: 9c3f5a12
  abi_hash in Camera_bridge.g.h:   9c3f5a12  ✅
  Camera_bridge.g.cpp compiled:    (not checkable at Dart level — see CMake target)
  Recommendation: add `nitro_abi_check` CMake target (see docs/abi_versioning.md)
```

### Implementation Breakdown

#### A.1 — `AbiFingerprinter` (new class in `nitro_generator`)

```
packages/nitro_generator/lib/src/abi/
├── abi_fingerprinter.dart     # BridgeSpec → ABI snapshot model
├── abi_snapshot.dart          # Data model: AbiSnapshot, AbiFunction, AbiStruct
├── abi_diff.dart              # Old AbiSnapshot × New AbiSnapshot → DiffResult
├── abi_serializer.dart        # AbiSnapshot → JSON (deterministic key order)
└── abi_hash.dart              # SHA-256 of canonical ABI string
```

**`AbiSnapshot` model:**

```dart
class AbiSnapshot {
  final String specName;
  final String generatorVersion;
  final DateTime generatedAt;
  final List<AbiFunction>  functions;
  final List<AbiStruct>    structs;
  final String             abiHash;   // sha256 of canonical form

  String toCanonical();   // deterministic string for hashing
  String toJson();
  factory AbiSnapshot.fromJson(String json);
  factory AbiSnapshot.fromBridgeSpec(BridgeSpec spec);
}

class AbiFunction {
  final String         cSymbol;
  final String         returnType;   // C type string
  final List<AbiParam> params;
  final String         fingerprint;  // sha256 of this function's signature
}

class AbiStruct {
  final String          name;
  final bool            packed;
  final List<AbiField>  fields;
  final String          fingerprint;
}
```

#### A.2 — `AbiDiffEngine`

```dart
class AbiDiffResult {
  final List<AbiBreakingChange>  breaking;
  final List<AbiAdditiveChange>  additive;
  final List<String>             unchanged;
  bool get hasBreaking => breaking.isNotEmpty;
}

class AbiBreakingChange {
  final String symbol;
  final String what;    // "param[1] type changed: int32_t → int64_t"
}
```

#### A.3 — `AbiGenerator` (new generator stage)

Fits into the existing pipeline after all other generators:

```dart
class AbiGenerator extends Generator<BridgeSpec> {
  @override
  Future<String?> generate(LibraryReader library, BuildStep step) async {
    // 1. Build new AbiSnapshot from spec
    // 2. Load existing .abi from disk if present
    // 3. Run AbiDiffEngine
    // 4. If breaking changes and --strict-abi → throw BuildException
    // 5. Write new .abi file
    // 6. Return null (no Dart output)
  }
}
```

#### A.4 — `CppHeaderGenerator` changes

- Appends `#define FOO_NITRO_ABI_HASH 0x…UL` section.
- `CppBridgeGenerator` prepends `#define FOO_NITRO_ABI_HASH_ACTUAL 0x…UL` before the `#include` of the header.

#### A.5 — CLI (`nitrogen generate`) changes

- Load `--strict-abi` flag from `nitro.yaml` or command line.
- On diff with breaking changes: print formatted diff and exit non-zero.
- `--force` bypasses the check and overwrites the snapshot.
- `nitrogen doctor --abi`: compares current spec fingerprint against the committed `.abi` file.

### File additions summary

| File | New / Modified |
|------|----------------|
| `packages/nitro_generator/lib/src/abi/abi_snapshot.dart` | NEW |
| `packages/nitro_generator/lib/src/abi/abi_diff.dart` | NEW |
| `packages/nitro_generator/lib/src/abi/abi_fingerprinter.dart` | NEW |
| `packages/nitro_generator/lib/src/abi/abi_serializer.dart` | NEW |
| `packages/nitro_generator/lib/src/abi/abi_hash.dart` | NEW |
| `packages/nitro_generator/lib/src/generators/abi_generator.dart` | NEW |
| `packages/nitro_generator/lib/src/generators/cpp_header_generator.dart` | MODIFY — emit ABI hash macro |
| `packages/nitro_generator/lib/src/generators/cpp_bridge_generator.dart` | MODIFY — define ABI_HASH_ACTUAL before include |
| `packages/nitrogen_cli/lib/src/commands/generate_command.dart` | MODIFY — diff + --strict-abi |
| `packages/nitrogen_cli/lib/src/commands/doctor_command.dart` | MODIFY — --abi flag |
| `packages/nitro_generator/test/abi_diff_test.dart` | NEW |

---

## Feature B — Desktop Platform Support (Windows / Linux / macOS)

### Problem

The current generator hard-codes Android (JNI/Kotlin) and iOS (Swift/@_cdecl) as the only targets. The `pubspec.yaml` plugin section only declares `android` and `ios`. Flutter supports 6 platforms; plugin authors writing pure-C++ logic (math, compression, ML) must today ship a separate wrapper for desktop.

### Goals

| # | Goal |
|---|------|
| B1 | Windows, Linux, macOS support via a shared **C++ implementation class** (no Kotlin/Swift required) |
| B2 | Single spec file produces desktop + mobile code |
| B3 | Plugin author writes **one** C++ implementation class that compiles on all 3 desktop platforms |
| B4 | CMake is the build system for all desktop platforms (Flutter's standard) |
| B5 | iOS macOS (`darwin` target) reuses the Swift generator; macOS desktop uses the C++ path |
| B6 | No breaking changes to existing Android + iOS plugins |

### Architecture Decision: "Desktop = C++ native implementation"

| Platform | Primary language | Bridge mechanism |
|----------|-----------------|-----------------|
| Android  | Kotlin          | JNI → C++ (existing) |
| iOS      | Swift           | @_cdecl → C++ (existing) |
| macOS desktop | C++        | Direct `dart:ffi` → C++ (new) |
| Linux    | C++             | Direct `dart:ffi` → C++ (new) |
| Windows  | C++             | Direct `dart:ffi` → C++ (new) |

For desktop, the generated C header (`Foo_bridge.g.h`) already defines everything needed. The plugin author writes a `FooImpl_desktop.cpp` that includes the header and implements each C function.

### Spec annotation changes

```dart
// Before (v1 — mobile only)
@HybridObject(
  ios: NativeImpl.swift,
  android: NativeImpl.kotlin,
)
abstract class Math extends HybridObject { ... }

// After (v2 — mobile + desktop)
@HybridObject(
  ios:     NativeImpl.swift,
  android: NativeImpl.kotlin,
  desktop: NativeImpl.cpp,   // NEW: windows + linux + macOS desktop
)
abstract class Math extends HybridObject { ... }

// Or per-platform override:
@HybridObject(
  ios:     NativeImpl.swift,
  android: NativeImpl.kotlin,
  windows: NativeImpl.cpp,
  linux:   NativeImpl.cpp,
  macos:   NativeImpl.cpp,
)
abstract class Math extends HybridObject { ... }
```

**Updated `NativeImpl` enum:**

```dart
enum NativeImpl {
  swift,      // iOS (existing)
  kotlin,     // Android (existing)
  cpp,        // Desktop: Windows / Linux / macOS  (NEW)
}
```

**Updated `HybridObject` annotation:**

```dart
class HybridObject {
  final NativeImpl ios;
  final NativeImpl android;
  final NativeImpl? windows;    // NEW — defaults to cpp if desktop is set
  final NativeImpl? linux;      // NEW
  final NativeImpl? macos;      // NEW — macOS desktop (not iOS)
  final NativeImpl? desktop;    // NEW — shorthand sets windows+linux+macos to cpp
  final String?    cSymbolPrefix;
  final String?    lib;

  const HybridObject({
    required this.ios,
    required this.android,
    this.windows,
    this.linux,
    this.macos,
    this.desktop,
    this.cSymbolPrefix,
    this.lib,
  });
}
```

### New generator: `CppImplStubGenerator`

For desktop targets, the generator produces a **C++ implementation stub** (analogous to what Swift/Kotlin generators do for mobile):

**File:** `Foo_impl.g.cpp` (committed, plugin author fills in the `// TODO` sections)

```cpp
// Foo_impl.g.cpp — Generated stub for desktop (Windows / Linux / macOS)
// Implement the TODO sections below. This file is generated ONCE; it will
// not be overwritten unless you delete it.
//
// Generated from: foo.native.dart
// nitro_generator: 0.4.0

#include "Foo_bridge.g.h"
#include <cstring>
#include <cstdlib>

// ─── State ────────────────────────────────────────────────────────────────────
// Put your implementation state here (object handles, library pointers, etc.)

// ─── Math::add ────────────────────────────────────────────────────────────────
double vc_add(double a, double b) {
  // TODO: implement
  return 0.0;
}

// ─── Math::subtract ──────────────────────────────────────────────────────────
double vc_subtract(double a, double b) {
  // TODO: implement
  return 0.0;
}
```

> **Overwrite policy:** Unlike `*.g.dart` / `*_bridge.g.kt` which are always regenerated, `*_impl.g.cpp` is only written if the file does **not** already exist. This matches the pattern that plugin authors fill in the stub.

### CMake integration

The existing `CMakeGenerator` is extended to understand desktop:

**`Foo_CMakeLists.g.txt` (updated for desktop multi-platform)**

```cmake
# Generated by nitro_generator — do not hand-edit
# Include from your plugin root CMakeLists.txt

cmake_minimum_required(VERSION 3.18)

set(NITRO_ABI_HASH "0x9c3f5a12")  # updated on each generate

# ── Source files ──────────────────────────────────────────────────────────────
set(NITRO_SOURCES
  src/Foo_bridge.g.cpp
  src/Foo_impl.g.cpp          # author fills this in
)

add_library(foo SHARED ${NITRO_SOURCES})

target_include_directories(foo PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)

# ── Platform-specific linking ─────────────────────────────────────────────────
if(ANDROID)
  target_link_libraries(foo android log)
elseif(WIN32)
  target_link_libraries(foo)               # nothing extra on Windows
elseif(UNIX AND NOT APPLE)
  target_link_libraries(foo dl pthread)    # Linux
elseif(APPLE)
  target_link_libraries(foo "-framework CoreFoundation")  # macOS desktop
endif()

# ── ABI guard ────────────────────────────────────────────────────────────────
target_compile_definitions(foo PRIVATE
  FOO_NITRO_ABI_HASH_ACTUAL=${NITRO_ABI_HASH}
)
```

### `pubspec.yaml` plugin section (generated / updated by `nitrogen link`)

`nitrogen link` is extended to write all 5 platforms:

```yaml
flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
      ios:
        ffiPlugin: true
      windows:          # NEW
        ffiPlugin: true
      linux:            # NEW
        ffiPlugin: true
      macos:            # NEW
        ffiPlugin: true
```

### `DartFfiGenerator` — desktop library loading

The runtime library loader already uses `DynamicLibrary.open()` on Android and `DynamicLibrary.process()` on iOS. Desktop needs per-OS logic:

```dart
// Generated in Foo.g.dart — updated _loadLib()
static DynamicLibrary _loadLib() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libfoo.so');
  }
  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  // Desktop ──────────────────────────────────────────────────────────────────
  if (Platform.isWindows) {
    return DynamicLibrary.open('foo.dll');
  }
  if (Platform.isLinux) {
    return DynamicLibrary.open('libfoo.so');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libfoo.dylib');
  }
  throw UnsupportedError('Platform not supported: ${Platform.operatingSystem}');
}
```

### Spec extractor change: platform targets in `BridgeSpec`

```dart
// BridgeSpec — updated
class BridgeSpec {
  // existing
  final String dartClassName;
  final String lib;
  final String namespace;
  final NativeImpl iosImpl;
  final NativeImpl androidImpl;
  // NEW
  final NativeImpl? windowsImpl;
  final NativeImpl? linuxImpl;
  final NativeImpl? macosImpl;

  bool get hasDesktop =>
    windowsImpl != null || linuxImpl != null || macosImpl != null;
}
```

### New generator stages activated for desktop

| Generator | When activated |
|-----------|---------------|
| `CppHeaderGenerator` | Always (unchanged — header is already platform-agnostic) |
| `CppBridgeGenerator` | Always (bridge `.cpp` works on all platforms) |
| `CppImplStubGenerator` | When `hasDesktop == true` — generates `*_impl.g.cpp` stub (once) |
| `CMakeGenerator` | Always — extended with platform guards |
| `KotlinGenerator` | When `androidImpl != null` (unchanged) |
| `SwiftGenerator` | When `iosImpl != null` (unchanged) |

### `SpecValidator` additions for desktop

```
ERROR   desktop: NativeImpl.swift — Swift is only valid for ios/macos (Apple only).
ERROR   desktop: NativeImpl.kotlin — Kotlin is only valid for android.
WARNING desktop target declared but spec has no CMakeLists.txt include — run `nitrogen link`.
```

### File additions summary

| File | New / Modified |
|------|----------------|
| `packages/nitro/lib/src/annotations.dart` | MODIFY — add `windows`, `linux`, `macos`, `desktop` to `HybridObject`; add `cpp` to `NativeImpl` if missing |
| `packages/nitro_generator/lib/src/spec_extractor.dart` | MODIFY — extract desktop platform targets into `BridgeSpec` |
| `packages/nitro_generator/lib/src/bridge_spec.dart` | MODIFY — add `windowsImpl`, `linuxImpl`, `macosImpl`, `hasDesktop` |
| `packages/nitro_generator/lib/src/generators/cpp_impl_stub_generator.dart` | NEW — writes `*_impl.g.cpp` once |
| `packages/nitro_generator/lib/src/generators/cmake_generator.dart` | MODIFY — multi-platform targets, ABI hash define |
| `packages/nitro_generator/lib/src/generators/dart_ffi_generator.dart` | MODIFY — desktop `_loadLib()` branches |
| `packages/nitro_generator/lib/src/spec_validator.dart` | MODIFY — desktop-specific rules |
| `packages/nitrogen_cli/lib/src/commands/link_command.dart` | MODIFY — emit windows/linux/macos ffiPlugin sections |
| `packages/nitro_generator/test/desktop_generator_test.dart` | NEW |
| `packages/nitro_generator/test/goldens/math_desktop.*` | NEW — golden files |
| `example/windows/`, `example/linux/`, `example/macos/` | NEW — Flutter desktop scaffolding for example plugin |

---

## Delivery Order

Both features can be developed in parallel after a shared foundation is set.

### Phase A — Shared foundation (1 week)

| Task | Owner |
|------|-------|
| Add `AbiSnapshot` data model + JSON serializer | nitro_generator |
| Add `AbiHash` SHA-256 utility | nitro_generator |
| Add `desktop` field parsing to `SpecExtractor` + `BridgeSpec` | nitro_generator |
| Unit tests for both foundations | |

### Phase B — ABI versioning (2 weeks)

| Week | Task |
|------|------|
| B-1 | `AbiDiffEngine` + `AbiGenerator` stage |
| B-1 | `CppHeaderGenerator` emits `#define FOO_NITRO_ABI_HASH` |
| B-1 | `CppBridgeGenerator` defines `FOO_NITRO_ABI_HASH_ACTUAL` |
| B-2 | CLI: `nitrogen generate` diff + `--strict-abi` flag |
| B-2 | CLI: `nitrogen doctor --abi` check |
| B-2 | Unit + integration tests, docs |

### Phase C — Desktop platform support (3 weeks)

| Week | Task |
|------|------|
| C-1 | Annotation changes + `SpecValidator` desktop rules |
| C-1 | `DartFfiGenerator` desktop `_loadLib()` branches |
| C-1 | `CMakeGenerator` desktop platform guards |
| C-2 | `CppImplStubGenerator` (once-only write) |
| C-2 | `nitrogen link` emits windows/linux/macos ffiPlugin sections |
| C-2 | Example plugin builds on macOS desktop |
| C-3 | Windows + Linux CI matrix |
| C-3 | Golden-file tests for all new generator outputs |
| C-3 | Docs: `docs/desktop_support.md` |

### Updated delivery table (appended to main plan)

| Week | Milestone |
|------|-----------|
| 13   | ABI snapshot model + hash engine + Foundation tests |
| 14   | ABI diff engine + header macros + CLI `--strict-abi` |
| 15   | ABI doctor + full integration test for ABI break scenario |
| 16   | Desktop annotation + BridgeSpec + CMake multi-platform |
| 17   | `CppImplStubGenerator` + DartFFI desktop loading + `nitrogen link` |
| 18   | Desktop example (macOS first), golden tests |
| 19   | Windows + Linux CI, full docs, pub.dev prep |

---

## Open Questions

1. **ABI hash granularity** — Hash per-symbol (cheap per-function caching) or one hash for the entire spec (simpler)? Current design does both: per-symbol fingerprints + top-level `abi_hash`.

2. **`--strict-abi` default** — Should the default be warn-only or error? Recommend: warn by default, error in CI via `nitro.yaml: abi_strict: true`.

3. **Desktop impl language** — Should macOS desktop be able to use Swift (it is Apple Silicon after all)? A `NativeImpl.swift` on `macos` could reuse `SwiftGenerator` + produce a `Package.swift` or `.xcframework`. Deferred to v2.1 unless there's demand.

4. **Windows calling conventions** — `dart:ffi` on Windows expects `__cdecl` (the default for `extern "C"`). No changes needed, but document explicitly.

5. **Linux packaging** — The generated `.so` needs to end up in the right place for `flutter build linux`. The `CMakeLists.g.txt` handles this via `install(TARGETS ...)` — clarify exact install path for Flutter's bundler.

6. **`.abi` file in `.gitignore`?** — No; it must be committed so `nitrogen doctor --abi` can diff between the committed snapshot and the current spec. Add a note to generated snippet.

7. **Struct layout portability** — C struct layout (padding, packing) can differ between MSVC (Windows) and GCC/Clang (Linux/macOS). The `@HybridStruct(packed: true)` annotation already handles explicit packing; the docs should warn about default padding on Windows.

---

## Non-goals for this extension (v2)

- Objective-C bridge (Swift is the iOS/macOS language)  
- WASM / web platform (separate design required due to `dart:ffi` unavailability)  
- iOS Simulator on Apple Silicon as a separate ABI target (handled naturally by the existing iOS path with `arm64-simulator` slice)  
- Versioned shared library soname bumping (OS-level `.so.1` symlinks) — the ABI hash guard is sufficient for our use case  
