# Nitro Ecosystem — Improvement Roadmap

> Analysis of the current codebase across architecture, code quality, testing, documentation, and platform support. Issues are grouped by impact tier.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Code Quality & Duplication](#2-code-quality--duplication)
3. [Error Handling](#3-error-handling)
4. [Test Coverage](#4-test-coverage)
5. [Platform Support](#5-platform-support)
6. [Documentation](#6-documentation)
7. [Performance](#7-performance)
8. [Dependency Management](#8-dependency-management)
9. [Missing Features](#9-missing-features)
10. [Priority Matrix](#10-priority-matrix)

---

## 1. Architecture

### 1.1 Platform Detection Is Fragmented (`link_command.dart`)

**Problem:** Five near-identical functions (`isCppModule`, `isAppleCppModule`, `isAndroidCppModule`, `isWindowsCppModule`, `isNativeCppModule`) each run independent regex passes over annotation blocks. Order-sensitive, brittle to formatting changes, and hard to test in isolation.

**Fix:** Introduce a `PlatformTargetAnalyzer` class that parses the annotation block once and exposes typed query methods.

```dart
// before — scattered across 200+ lines
bool isCppModule(String specContent) => _regex1.hasMatch(specContent);
bool isAppleCppModule(String specContent) => _regex2.hasMatch(specContent);

// after — single-parse, cohesive API
final analyzer = PlatformTargetAnalyzer.fromSpec(specContent);
analyzer.requiresCpp;          // bool
analyzer.supportsApple;        // bool
analyzer.targetedPlatforms;   // Set<NativePlatform>
```

---

### 1.2 Spec Name Extraction Is Regex-Based (`spec_extractor.dart`)

**Problem:** The lib name is extracted from `@NitroModule(lib: 'x')` via regex. Whitespace changes, multiline annotations, or trailing commas silently break extraction without error.

**Fix:** Use the `analyzer` package (already a dependency) to walk the AST and extract annotation arguments properly. Add a validation step that cross-checks the extracted name against the actual module spec.

---

### 1.3 CLI Link Step Has No Rollback

**Problem:** `link_command.dart` writes to multiple native build files sequentially. A failure midway leaves the plugin in an inconsistent state (e.g., `Podfile` updated but `CMakeLists.txt` not).

**Fix:** Write to temporary files first, validate each output, then atomically move them into place. On failure, restore originals.

---

### 1.4 Isolate Pool Double-Hop for Native-Async Methods

**Problem:** Every `@nitroAsync` call crosses two isolate-message boundaries (dispatch → result), even for methods that are already natively asynchronous and could post results directly via `Dart_PostCObject`.

**Fix:** Already tracked in `IMPROVEMENT_PLAN.md`. Annotate native-async methods with `@NitroNativeAsync` so the generator emits direct `Dart_PostCObject` paths, cutting async overhead from ~930 µs to ~146 µs (per CHANGELOG).

---

## 2. Code Quality & Duplication

### 2.1 `ZeroCopyBuffer` Has 8 Identical Classes (`ffi_utils.dart`)

**Problem:** `Float32ZeroCopyBuffer`, `Int32ZeroCopyBuffer`, etc. are structurally identical: constructor, `Pointer` field, `length`, typed getter, `NativeFinalizer`. Maintaining 8 copies means 8 places to update when the pattern changes.

**Fix:** Extract a generic `ZeroCopyBuffer<T extends TypedData>` base class with shared finalizer logic. Each concrete class becomes a one-liner factory.

```dart
// current: 8 × ~30 LOC = 240 LOC of duplication
// target: 1 base class + 8 two-line subclasses
```

---

### 2.2 Native Templates Are Raw Strings (`scaffold_templates.dart`)

**Problem:** Kotlin and Swift scaffold templates live as multi-hundred-line string literals inside Dart source. Syntax highlighting, formatting, and refactoring tools can't help. Indentation bugs are invisible.

**Fix:** Move templates to `lib/src/templates/*.kt.template` / `*.swift.template` asset files. Load them at build time via `dart:io` or bundle them as a `package:` resource. Alternatively, define templates as a small DSL (structured data → rendered string).

---

### 2.3 Unused `async` on Command `execute()` Methods

**Problem:** Most `execute()` overrides are declared `async` but never `await` anything meaningful. This adds an unnecessary microtask frame on every invocation.

**Fix:** Make them synchronous where there is no actual async work. Where async is needed, await only at the specific call site.

---

### 2.4 Hardcoded Platform Versions

| Location | Value | Risk |
|---|---|---|
| `scaffold_templates.dart:263` | `swift-tools-version: 5.9` | Breaks when Xcode minimum changes |
| `link_command.dart:~1390` | `ndkVersion = "34"` | Stale after Flutter NDK bump |
| CMake generators | `CMAKE_CXX_STANDARD 17` | May need 20 for newer APIs |
| Podspec template | `iOS 13.0` | Implicit; not parameterizable |

**Fix:** Centralise these in a `VersionConstants` class or a YAML config file (`nitrogen_versions.yaml`) that the CLI reads. Let `nitrogen doctor` warn when local values are behind the Flutter-required minimum.

---

## 3. Error Handling

### 3.1 Silent Swallowing in Spec Extractor

**Problem:**
```dart
// spec_extractor.dart line ~33
} catch (_) {}
```
JSON parse errors during spec extraction are silently discarded. The caller receives `null` and may continue with incorrect state.

**Fix:** At minimum log a warning. Prefer re-throwing a typed `SpecParseException` so callers can present a meaningful error to the user.

---

### 3.2 Empty Catch in Link Command

**Problem:** At least one `try/catch` in `link_command.dart` (~line 1390) catches all exceptions when resolving the Nitro native path, discards the error, and continues. This can produce cryptic downstream failures.

**Fix:** Either handle the specific exceptions (e.g., `FileSystemException`) or rethrow with context.

---

### 3.3 Null Bounds Checking in C++ Record Decoder

**Problem:** `@HybridRecord` nullable fields rely on tag bytes in the binary stream. The C++ decoder does not bounds-check remaining bytes before reading a tag, which can cause out-of-bounds reads on malformed data.

**Fix:** Add `if (offset + 1 > length) throw std::runtime_error(...)` before each tag read in the generated C++ decoder.

---

### 3.4 No Validation of File Permissions in `doctor`

**Problem:** `doctor_command.dart` checks file existence but not read/write permissions. A locked `Podfile` passes the doctor check but fails at link time.

**Fix:** Add `FileSystemEntity.stat()` checks and surface permission warnings explicitly.

---

## 4. Test Coverage

### 4.1 No Integration Tests

**Problem:** There are ~21,900 LOC of unit tests, but no end-to-end test that runs `nitrogen init` → `nitrogen generate` → `nitrogen link` on a real (temp) Flutter project.

**Fix:** Add an integration test suite in `test_projects/` that:
1. Creates a temp Flutter plugin
2. Runs the full CLI pipeline
3. Asserts that generated files compile (at least for Dart FFI and Kotlin)

---

### 4.2 No Windows / Linux Build Tests

**Problem:** CMakeLists generation is tested for correctness of content but no test verifies the generated output actually compiles on Windows (MSVC) or Linux (GCC/Clang).

**Fix:** Add GitHub Actions jobs that build the generated Windows and Linux stubs on the respective runners.

---

### 4.3 Minimal `@NitroStream` Tests

**Problem:** Streams are a core feature but only 2-3 tests cover them. Event ordering, backpressure, and cancellation under concurrent emission are not tested.

**Fix:** Add dedicated stream tests: single subscriber, multi-subscriber, cancel-before-first-event, high-frequency emission.

---

### 4.4 No Memory / Finalizer Stress Tests

**Problem:** `ZeroCopyBuffer` and `LazyRecordList` rely on `NativeFinalizer`. Under GC pressure or rapid allocation/deallocation these can cause double-free or use-after-free bugs.

**Fix:** Add a stress test that allocates and discards 10,000 `ZeroCopyBuffer` instances and verifies that the finalizer fires the correct number of times (trackable via a native counter).

---

### 4.5 `IsolatePool` Concurrency Not Tested

**Problem:** High-contention scenarios (many concurrent dispatches saturating the pool) are not covered. Error slot races are possible.

**Fix:** Add a test that fires 1,000 concurrent `dispatch()` calls and asserts all results arrive, all errors are surfaced correctly, and no deadlock occurs.

---

## 5. Platform Support

### 5.1 Web / WASM — Annotations Exist, Generator Does Not

**Problem:** `WasmImpl` is defined in `nitro_annotations` and the spec validator accepts it, but `nitro_generator` has no WASM code generator. `nitrogen link` has no WASM linking step. Any developer targeting Web receives no output without an obvious error.

**Fix (phased):**
1. **Immediate:** Make the spec validator emit a clear `TODO: WasmImpl code generation is not yet implemented` error instead of silently succeeding.
2. **Medium-term:** Implement `wasm_generator.dart` that produces `dart:js_interop` bindings.
3. **Long-term:** Add `nitrogen link --platform web` that patches `index.html` / `pubspec.yaml` WASM assets.

---

### 5.2 Windows / Linux Are Spec-Only

**Problem:** Windows and Linux can generate CMakeLists fragments, but there are no example plugins, no actual build CI, and no documented end-to-end workflow. They are effectively stubs.

**Fix:**
1. Add a `nitro_desktop` example plugin targeting Windows and Linux.
2. Add CI matrix jobs that build the generated stubs on Windows (MSVC) and Linux (GCC).
3. Write a `doc/platforms/desktop.md` guide.

---

### 5.3 No macOS-Only Example

**Problem:** The `my_camera` plugin covers iOS and Android. macOS support (added in 0.3.1) has no dedicated example or smoke test.

**Fix:** Add a `nitro_macos_example` plugin that exercises at least one `SwiftImpl` and one `CppImpl` on macOS.

---

## 6. Documentation

### 6.1 No Migration Guide Between Versions

**Problem:** The CHANGELOG describes changes but provides no step-by-step migration for breaking changes (e.g., 0.2.x → 0.3.1 macOS additions, any rename of annotation fields).

**Fix:** Add `doc/migration/0.2-to-0.3.md` (and future equivalent files) with a before/after diff for every breaking change.

---

### 6.2 Windows / Linux Build Guide Missing

**Problem:** `doc/` has guides for getting started, consuming, and publishing — all iOS/Android focused. There is no Windows or Linux build guide.

**Fix:** Add `doc/platforms/windows.md` and `doc/platforms/linux.md` covering:
- Required toolchain (MSVC / GCC)
- How generated CMakeLists hooks into Flutter's build
- Known limitations

---

### 6.3 `NativeFinalizer` Usage Guide Missing

**Problem:** Library authors extending `HybridObject` need to know when/how to use `NativeFinalizer` for their own native resources. There is no guide.

**Fix:** Add `doc/advanced/memory_management.md` covering `dispose()`, `NativeFinalizer`, and when each applies.

---

### 6.4 No `@nitroAsync` Performance / Error Semantics Guide

**Problem:** Developers choosing between sync and async methods have no guidance on the performance cost of the isolate hop, or how errors propagate across isolate boundaries.

**Fix:** Add a section in `doc/advanced/async.md` covering:
- The isolate pool model
- Overhead per async call (reference the CHANGELOG benchmarks)
- Error propagation and how to surface native errors back to Dart

---

### 6.5 GoogleMock Integration Barely Documented

**Problem:** `nitro_generator` produces `*Mock.hpp` files for C++ tests, but there is no guide explaining how to use them with GoogleTest/GoogleMock in a native project.

**Fix:** Add `doc/advanced/cpp_testing.md` with a minimal CMake + GoogleTest setup that uses the generated mock.

---

## 7. Performance

### 7.1 Symbol Lookup on Every Call

**Problem:** Each FFI call resolves the native symbol via `DynamicLibrary.lookup()`. If the library is not cached, this re-opens the shared library on every invocation.

**Fix:** Cache the `DynamicLibrary` handle and resolved `NativeFunction` pointers at first use (lazy init with `late final`). Expose a `NitroRuntime.preload()` method so apps can warm the cache at startup.

---

### 7.2 `isLeaf: true` Not Used on Pure-Native Methods

**Problem:** Dart FFI's `isLeaf: true` annotation bypasses the Dart VM safepoint mechanism, reducing call overhead by up to 30% for functions that don't call back into Dart. It is not used anywhere in the generated bindings.

**Fix:** Annotate generated FFI calls that make no Dart callbacks with `isLeaf: true`. Add a generator option to opt out for methods that do call back into Dart.

---

## 8. Dependency Management

### 8.1 `nocterm_unrouter` Is Pre-1.0

**Problem:** `nocterm_unrouter: ^0.1.0` is an unstable pre-release. Its API can change in any minor version.

**Fix:** Pin to an exact version (`0.1.x`) and upgrade deliberately, or absorb the dependency inline if it is small enough.

---

### 8.2 `analyzer` Version Pinning

**Problem:** `analyzer: ^6.4.1` is a large transitive dependency that tracks the Dart SDK. Minor version bumps can introduce AST API changes that silently break spec extraction.

**Fix:** Pin to an exact minor (`6.4.x`) and update with each Dart SDK release as part of a deliberate compatibility check.

---

### 8.3 No Root Lock File Strategy Documented

**Problem:** Each package has its own `pubspec.lock`, but the Dart workspace does not produce a unified lock. Developers may pick up different transitive versions depending on which package they run `pub get` from.

**Fix:** Document the recommended `pub get` order (workspace root first) and add a CI check that verifies all packages resolve to consistent transitive versions.

---

## 9. Missing Features

| Feature | Priority | Notes |
|---|---|---|
| WASM code generator | High | `WasmImpl` is a no-op today |
| `nitrogen doctor` permission checks | High | Catches locked files before link fails |
| `nitrogen migrate` command | Medium | Automates breaking-change migrations |
| DevTools timeline events for FFI calls | Medium | Enables profiling in Flutter DevTools |
| Nullable return types on async methods | Medium | Already in `IMPROVEMENT_PLAN.md` |
| `NitroRuntime.preload()` | Medium | Explicit warm-up for apps with cold-start constraints |
| `isLeaf: true` in generated bindings | Medium | ~30% call overhead reduction on pure-native paths |
| Windows / Linux end-to-end examples | Medium | Required to call those platforms production-ready |
| Transactional link step with rollback | Low | Prevents inconsistent state on partial failure |
| Hot Reload workaround guide | Low | Document the limitation; provide reload-safe patterns |
| Security hardening guide | Low | Buffer size validation, integer overflow in C++ bridges |

---

## 10. Priority Matrix

| # | Item | Impact | Effort | Do First? |
|---|---|---|---|---|
| 1 | WASM: emit error instead of silently succeeding | High | Low | ✅ Yes |
| 2 | Fix silent `catch (_) {}` in spec extractor | High | Low | ✅ Yes |
| 3 | Fix empty catch in link command | High | Low | ✅ Yes |
| 4 | `PlatformTargetAnalyzer` refactor | High | Medium | ✅ Yes |
| 5 | Centralise hardcoded platform versions | High | Low | ✅ Yes |
| 6 | Integration test suite | High | High | Next sprint |
| 7 | Isolate pool `@NitroNativeAsync` optimization | High | High | Next sprint |
| 8 | Windows / Linux CI build jobs | Medium | Medium | Next sprint |
| 9 | `ZeroCopyBuffer` generic base class | Medium | Low | Next sprint |
| 10 | Template files extracted from Dart strings | Medium | Medium | Backlog |
| 11 | Migration guide (0.2 → 0.3) | Medium | Low | Backlog |
| 12 | `isLeaf: true` in generated bindings | Medium | Medium | Backlog |
| 13 | WASM code generator | High | Very High | Backlog |
| 14 | Transactional link step with rollback | Low | High | Backlog |
| 15 | DevTools FFI timeline events | Low | High | Backlog |
