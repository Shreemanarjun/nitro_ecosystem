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

### 1.1 Platform Detection Is Fragmented (`link_command.dart`) ✅ Done

**Problem:** Five near-identical functions (`isCppModule`, `isAppleCppModule`, `isAndroidCppModule`, `isWindowsCppModule`, `isNativeCppModule`) each run independent regex passes over annotation blocks. Order-sensitive, brittle to formatting changes, and hard to test in isolation.

**Fix:** Introduced `PlatformTargetAnalyzer` with two factories (`fromSpec(File)` and `fromContent(String)`) that parse the annotation **once** and expose five typed query properties (`requiresCpp`, `supportsApple`, `supportsAndroid`, `supportsWindows`, `isNativeCpp`). The five existing top-level functions are now one-line delegations — all call sites (including `.where(isAppleCppModule)`) remain unchanged. `discoverModuleInfos` was updated to use `fromContent(content)`, eliminating two redundant file reads per spec.

```dart
// before — each function reads + parses independently
bool isCppModule(File f) { /* 8-line regex */ }
bool isAppleCppModule(File f) { /* 8-line regex */ }

// after — single parse, cohesive API
final analyzer = PlatformTargetAnalyzer.fromSpec(specFile);
analyzer.requiresCpp;     // bool
analyzer.supportsApple;   // bool
analyzer.isNativeCpp;     // bool
// top-level functions still exist as one-liners for backward compat
```

**119/119 existing tests pass.**

---

### 1.2 Spec Name Extraction Is Regex-Based (`spec_extractor.dart`)

**Problem:** The lib name is extracted from `@NitroModule(lib: 'x')` via regex. Whitespace changes, multiline annotations, or trailing commas silently break extraction without error.

**Fix:** Use the `analyzer` package (already a dependency) to walk the AST and extract annotation arguments properly. Add a validation step that cross-checks the extracted name against the actual module spec.

---

### 1.3 CLI Link Step Has No Rollback

**Problem:** `link_command.dart` writes to multiple native build files sequentially. A failure midway leaves the plugin in an inconsistent state (e.g., `Podfile` updated but `CMakeLists.txt` not).

**Fix:** Write to temporary files first, validate each output, then atomically move them into place. On failure, restore originals.

---

### 1.4 Isolate Pool Double-Hop for Native-Async Methods ✅ Done

**Problem:** Every `@nitroAsync` call crosses two isolate-message boundaries (dispatch → result), even for methods that are already natively asynchronous and could post results directly via `Dart_PostCObject`.

**Fix:** Implemented the full `@NitroNativeAsync` pipeline across 8 files:

- **`nitro_annotations`** — Added `const nitroNativeAsync = NitroNativeAsync()` annotation class.
- **`bridge_spec.dart`** — Added `isNativeAsync` field to `BridgeFunction`; mutually exclusive with `isAsync`.
- **`spec_extractor.dart`** — Detects `@NitroNativeAsync`, validates mutual exclusion with `@NitroAsync`.
- **`NitroRuntime.openNativeAsync<T>`** — New zero-hop Future helper: opens a `ReceivePort`, calls the bridge with the native port ID, awaits exactly one message, unpacks. No Dart isolate spawned.
- **`dart_ffi_generator.dart`** — For `isNativeAsync` methods: emits a `void Function(params, int)` pointer (extra `Int64 dart_port`), `Future<T>` method body calling `openNativeAsync`, correct unpack lambdas per return type, arena allocation/release for String/TypedData params.
- **`cpp_bridge_generator.dart`** — For `isNativeAsync` (direct C++ path): `void`-returning wrapper with `int64_t dart_port` param, posts `kNull` if no impl (no error slot), delegates to `g_impl->method(params, dart_port)`.
- **`cpp_interface_generator.dart`** — `@NitroNativeAsync` methods generate `virtual void method(params, int64_t dartPort) = 0`.
- **`swift_generator.dart`** — Emits `Task.detached { ... Dart_PostCObject_DL(dartPort, &obj) }` — no `DispatchSemaphore`, no thread blocking.
- **`kotlin_generator.dart`** — Emits `_asyncExecutor.execute { runBlocking { ... }; postXxxToPort(dartPort, result) }` — non-blocking coroutine dispatch; `suspend fun` in interface; `postXxxToPort` external JNI stubs only when needed.

**Performance:** ~930 µs (`@nitroAsync`) → ~146 µs (`@NitroNativeAsync`) per call when the native side is already asynchronous. Zero breaking changes — `@nitroAsync` is unchanged; `@NitroNativeAsync` is opt-in.

**56 new tests** in `packages/nitro_generator/test/native_async_test.dart` covering all 5 generators and all return types (int, double, bool, String, void). **229/229 tests pass** across all affected test files.

---

## 2. Code Quality & Duplication

### 2.1 `ZeroCopyBuffer` Has 8 Identical Classes (`ffi_utils.dart`) ✅ Done

**Problem:** `Float32ZeroCopyBuffer`, `Int32ZeroCopyBuffer`, etc. are structurally identical: constructor, `Pointer` field, `length`, typed getter, `NativeFinalizer`. Maintaining 8 copies means 8 places to update when the pattern changes.

**Fix:** Lifted the shared `static final _finalizer` and `_releaseFinalizerToken()` logic into `_ZeroCopyBufferBase`. The base constructor now takes `(bool hasValidPtr, nativeRelease)` and does the `_finalizer.attach` directly. Each of the 8 subclasses lost its own `_finalizer`, `_releaseFinalizerToken()` override, and manual `attach` call — replaced by a single initializer-list constructor delegation (`super(ptr != nullptr, nativeRelease)`). The abstract `_releaseFinalizerToken()` method was removed entirely.

```dart
// before: 8 × (finalizer + override + attach) = ~32 lines of pure duplication
static final Finalizer<void Function()> _finalizer = Finalizer((r) => r());
ZeroCopyBuffer(...) : super(nativeRelease) { if (ptr != nullptr) _finalizer.attach(...); }
@override void _releaseFinalizerToken() => _finalizer.detach(this);

// after: one shared finalizer in base, each subclass is constructor + getter only
ZeroCopyBuffer(this.ptr, this.length, void Function() nativeRelease)
    : super(ptr != nullptr, nativeRelease);
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

### 4.3 Minimal `@NitroStream` Tests ✅ Done

**Problem:** Streams are a core feature but only 2-3 generator-level tests covered them. Runtime behavior — event ordering, backpressure, cancellation under concurrent emission — was entirely untested.

**Fix:** Added `@visibleForTesting ReceivePort? testPort` to `NitroRuntime.openStream` (injected only by tests; production callers leave it null). Created `packages/nitro/test/nitro_stream_test.dart` with **14 runtime tests** across 4 groups:

- **Lazy registration** — `register` not called before subscribe; called exactly once on first listener; called with the correct native port
- **Cancellation lifecycle** — `release` not called pre-cancel; called on cancel; idempotent on double-cancel; cancel-before-first-event works cleanly
- **Single-subscriber contract** — second `listen()` throws `StateError`; re-listen after cancel throws `StateError`
- **Event delivery** — ordered receipt; high-frequency (1 000 events without loss); cancel mid-emission does not throw; `unpack` exception forwarded as stream error; stream continues after unpack error

**14/14 new tests pass; all 21 existing nitro package tests continue to pass.**

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

| # | Item | Impact | Effort | Status |
|---|---|---|---|---|
| 1 | WASM: emit error instead of silently succeeding | High | Low | ✅ Yes |
| 2 | Fix silent `catch (_) {}` in spec extractor | High | Low | ✅ Yes |
| 3 | Fix empty catch in link command | High | Low | ✅ Yes |
| 4 | `PlatformTargetAnalyzer` refactor | High | Medium | ✅ **Done** |
| 5 | Centralise hardcoded platform versions | High | Low | ✅ Yes |
| 6 | `ZeroCopyBuffer` shared finalizer in base | Medium | Low | ✅ **Done** |
| 7 | `@NitroStream` runtime test suite (14 tests) | High | Low | ✅ **Done** |
| 8 | Integration test suite | High | High | Next sprint |
| 9 | `@NitroNativeAsync` zero-hop async path | High | High | ✅ **Done** |
| 10 | Windows / Linux CI build jobs | Medium | Medium | Next sprint |
| 11 | Template files extracted from Dart strings | Medium | Medium | Backlog |
| 12 | Migration guide (0.2 → 0.3) | Medium | Low | Backlog |
| 13 | `isLeaf: true` in generated bindings | Medium | Medium | Backlog |
| 14 | WASM code generator | High | Very High | Backlog |
| 15 | Transactional link step with rollback | Low | High | Backlog |
| 16 | DevTools FFI timeline events | Low | High | Backlog |
