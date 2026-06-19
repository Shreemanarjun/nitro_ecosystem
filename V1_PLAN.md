# Nitro Ecosystem — V1 Master Plan

> Single source of truth, merged from: `plan.md`, `new_plan.md`, `cross.md`,
> `PLATFORM_EXPANSION_PLAN.md`, `correct_type_gen_plan.md`, `IMPROVEMENTS.md`, `IMPROVEMENT_PLAN.md`.
>
> **Scope:** `packages/nitro` (runtime), `packages/nitro_generator` (generators),
> `packages/nitrogen_cli` (CLI), `packages/nitro_annotations` (annotations).

---

## Master Status Table

### Foundation

| ID | Item | Status |
|----|------|--------|
| F1 | Runtime + annotations (`nitro` package) | ✅ Done |
| F2 | `SpecExtractor` + `BridgeSpec` AST | ✅ Done |
| F3 | All generators (Dart FFI, Kotlin, Swift, C++ bridge, C++ interface, CMake) | ✅ Done |
| F4 | `nitrogen link` CLI — multi-module auto-discovery | ✅ Done |
| F5 | JNI Local Frames (`PushLocalFrame` / `PopLocalFrame`) | ✅ Done |
| F6 | Isolate Pool 2.0 (persistent result ports + callId routing) | ✅ Done |
| F7 | Performance baseline (1.5 µs sync / 8 ms 1 GB struct / 25 TB/s unsafe ptr) | ✅ Done |
| F8 | JNI name mangling (`_jniMangle` + `_jniMethodName`) | ✅ Done |
| F9 | `my_camera` example plugin (3 modules, streams, structs, enums) | ✅ Done |
| F10 | Generator unit tests (no `dart:mirrors`) | ✅ Done |
| F11 | `SpecValidator` | ✅ Done |
| F12 | `nitrogen doctor` CLI | ✅ Done |
| F13 | Golden-file snapshot tests | ✅ Done |
| F14 | iOS / Android E2E verified | ✅ Done |
| F15 | `PlatformTargetAnalyzer` refactor (single-parse API) | ✅ Done |
| F16 | `@NitroNativeAsync` zero-hop async path (8 generators) | ✅ Done |
| F17 | `ZeroCopyBuffer` shared `NativeFinalizer` base class | ✅ Done |
| F18 | `@NitroStream` runtime test suite (14 tests) | ✅ Done |
| F19 | §3.3 Null bounds checking in C++ record decoder (`readNullTag()`) | ✅ Done |
| F20 | JNI method/class IDs cached in `JNI_OnLoad` | ✅ Done |
| F21 | `runBlocking` → `ReceivePort`-based async handoff in Kotlin | ✅ Done |
| F22 | `nitro_report_jni_exception` caches method IDs | ✅ Done |
| F23 | `_streamJobs` map → `ConcurrentHashMap` | ✅ Done |
| F24 | `ByteArrayOutputStream` pool-based reuse in record encode | ✅ Done |
| F25 | Generator facade + per-language folder architecture (`languages/*` bundles + shared model) | ✅ Done |
| F26 | Shared typed `CodeWriter` infrastructure; language generators no longer use raw `StringBuffer(` emitters | ✅ Done |

### Performance

| ID | Item | Priority | Status |
|----|------|----------|--------|
| P1 | `FindClass()` inside `unpack_*_to_jni` — cache `jclass` + `jmethodID` as statics | 🔴 High | ✅ Done |
| P2 | TypedData params: `NewDirectByteBuffer` zero-copy path (not just fields) | 🟡 Medium | ⬜ Pending |
| P3 | `NitroRuntime.checkError` — assert-gate in release (Approach A, non-breaking) | 🟡 Medium | ✅ Done |
| P4 | Generator inner loops: pre-build `Set<String>` for O(1) type lookups | 🟡 Medium | ✅ Done |
| P5 | `RecordWriter` preallocated growable buffer; `readString` in-place decode | 🟡 Medium | ✅ Done |
| P6 | `IsolatePool._leastBusyIndex` → min-heap or round-robin | 🟢 Low | ⬜ Pending |
| P7 | `isLeaf: true` on pure-native FFI calls (~30% call overhead reduction) | 🟡 Medium | ✅ Done |
| P8 | `checkDisposed()` → `@pragma('vm:prefer-inline')` + assert variant | 🟢 Low | ⬜ Pending |

### Stability & Correctness

| ID | Item | Priority | Status |
|----|------|----------|--------|
| S1 | ABI / version handshake between `.so` and Dart runtime | 🔴 High | ⬜ Pending |
| S2 | Library-load race in `_libCache` (unguarded `Map` across isolates) | 🔴 High | ⬜ Pending |
| S3 | Stream port-death: `if (!Dart_PostCObject(...)) break;` in emitters | 🟡 Medium | ⬜ Pending |
| S4 | JNI `AttachCurrentThread` detach on isolate shutdown | 🟡 Medium | ⬜ Pending |
| S5 | `@HybridStruct(zeroCopy)` ownership contract — finalizer guarantee docs | 🟡 Medium | ⬜ Pending |
| S6 | Concurrent access on Kotlin/Swift impls — docs or `synchronized` wrapper | 🟡 Medium | ⬜ Pending |
| S7 | Thread-local error slot (TLS per thread, not shared per library) | 🟡 Medium | ⬜ Pending |
| S8 | Out-param ABI (Approach B, major-version): single FFI call eliminates 2nd/3rd call | 🟢 Low | ⬜ Pending |

### Type Coverage & Bug Fixes

| ID | Item | Priority | Status |
|----|------|----------|--------|
| T1 | **Bug:** Stream `String`/`bool`/`int` unpack — `rawPtr as T` is wrong | 🔴 Critical | ✅ Done |
| T2 | **Bug:** Async `Uint8List`/`Float32List` return has no decode path | 🔴 Critical | ✅ Done |
| T3 | **Bug:** `bool` JNI sig uses `jbyte` (sig `B`) instead of `jboolean` (sig `Z`) | 🔴 Critical | ✅ Done |
| T4 | **Bug:** `@HybridEnum` field inside `@HybridRecord` serialized as raw int (not `.nativeValue`) | 🔴 Critical | ✅ Done |
| T5 | **Bug:** Nullable `@HybridStruct` param has no null-pointer guard in C++ bridge | 🟡 Medium | ✅ Done |
| T6 | **Bug:** `withArena` wraps async body — arena freed before `await` completes (use-after-free) | 🔴 Critical | ✅ Done |
| T7 | Unit tests: `List<bool/double/String/int>` inside record serializers (all 4 generators) | 🟡 Medium | ✅ Done |
| T8 | Unit tests: Kotlin all-types coverage (bool, enum, struct, record async) | 🟡 Medium | ✅ Done |
| T9 | Unit tests: Swift all-types coverage (bool, enum, struct, stream types) | 🟡 Medium | ✅ Done |
| T10 | Unit tests: Dart FFI all-types coverage (bool, enum, typed-data async, properties) | 🟡 Medium | ✅ Done |
| T11 | Integration module: `type_coverage` plugin (echo all types on device) | 🔴 High | ⬜ Pending |

### Platform Expansion

| ID | Item | Priority | Status |
|----|------|----------|--------|
| PX1 | Sealed `NativeImpl` class hierarchy + platform capability markers | 🔴 High | ⬜ Pending |
| PX2 | `NitroModule` annotation: add `macos`, `windows`, `linux`, `web` fields | 🔴 High | ⬜ Pending |
| PX3 | `BridgeSpec`: add `macosImpl`, `windowsImpl`, `linuxImpl`, `webImpl` | 🔴 High | ⬜ Pending |
| PX4 | `SpecExtractor`: type-name switch (replace index-based `NativeImpl.values[index]`) | 🔴 High | ⬜ Pending |
| PX5 | `SpecValidator`: per-platform `NativeImpl` constraints + missing-platform warnings | 🟡 Medium | ⬜ Pending |
| PX6 | `link_command`: extend `isCppModule` regex to include `windows`/`linux` | 🟡 Medium | ⬜ Pending |
| PX7 | macOS: `Platform.isMacOS` explicit branch in `dart_ffi_generator` | 🟡 Medium | ⬜ Pending |
| PX8 | macOS: `.podspec` + `Package.swift` platforms entry | 🟡 Medium | ⬜ Pending |
| PX9 | macOS: scaffold `macos/Classes/` entry point in `init_command` | 🟡 Medium | ⬜ Pending |
| PX10 | Windows/Linux: `DynamicLibrary.open` paths (`.dll` / `lib*.so`) | 🟡 Medium | ⬜ Pending |
| PX11 | Windows/Linux: `CppBridgeGenerator` platform guards (`#ifdef _WIN32` etc.) | 🟡 Medium | ⬜ Pending |
| PX12 | Windows/Linux: `CMakeGenerator` cross-platform link libs and MSVC/GCC flags | 🟡 Medium | ⬜ Pending |
| PX13 | Windows/Linux: `linkWindows()` / `linkLinux()` in `link_command` | 🟡 Medium | ⬜ Pending |
| PX14 | Windows/Linux: `init_command` `--platforms` flag; per-platform entry points | 🟡 Medium | ⬜ Pending |
| PX15 | Windows/Linux: `doctor_command` toolchain checks (MSVC, GCC, CMake) | 🟢 Low | ⬜ Pending |
| PX16 | Windows: MSVC-safe `__attribute__((constructor))` cross-platform stub | 🟡 Medium | ⬜ Pending |
| PX17 | Web: conditional export split `nitro_runtime_native.dart` / `nitro_runtime_web.dart` | 🔴 High | ⬜ Pending |
| PX18 | Web: `WebBridgeGenerator` (`@JS()` external declarations) | 🟡 Medium | ⬜ Pending |
| PX19 | Web: `dart_ffi_generator` `kIsWeb`-conditional factory | 🟡 Medium | ⬜ Pending |
| PX20 | `SpecValidator`: emit clear error for `WasmImpl` (not silently succeed) | 🔴 High | ⬜ Pending |

### Generator & Build Quality

| ID | Item | Priority | Status |
|----|------|----------|--------|
| G1 | Split `cpp_bridge_generator.dart` (1586 lines) — 8 sub-PRs, byte-identical output | 🟡 Medium | 🟨 Partial |
| G2 | `build.yaml` ↔ `builder.dart` sync: add 3 missing output extensions | 🔴 High | ⬜ Pending |
| G3 | `build.yaml` drift test: assert `buildExtensions` keys match code | 🟡 Medium | ⬜ Pending |
| G4 | `builder.dart` log escalation: `log.warning` → `log.severe` for stack traces | 🟡 Medium | ⬜ Pending |
| G5 | `DartFormatter` hoisted to `static final _formatter` (not re-instantiated per spec) | 🟢 Low | ⬜ Pending |
| G6 | `dart_api_dl.c` absolute-path fragility — resolve at build time from package config | 🔴 High | ⬜ Pending |
| G7 | `SpecExtractor` single-pass AST visitor (replace multiple loops over same element list) | 🟢 Low | ⬜ Pending |
| G8 | `_jniSigType` / `_jniGetter` unknown type: throw `StateError` with type name | 🔴 High | ✅ Done |
| G9 | `LOGE("Method not found")` — include method name + JNI sig in log line | 🟡 Medium | ⬜ Pending |
| G10 | Stale-generation detection: emit `// nitro_generator: x.y.z` comment in outputs | 🟡 Medium | ⬜ Pending |
| G11 | Coroutine imports in Kotlin emitted unconditionally — make conditional | 🟢 Low | ⬜ Pending |
| G12 | `callAsync` returns `dynamic` — type to `callAsync<T>` with structured result | 🟡 Medium | ⬜ Pending |
| G13 | Spec-path attribution in generated file headers | 🟢 Low | ⬜ Pending |
| G14 | Fix silent `catch (_) {}` in spec extractor — rethrow as `SpecParseException` | 🔴 High | ⬜ Pending |
| G15 | Fix empty catch in `link_command.dart` Nitro-native path resolution | 🔴 High | ✅ Done |
| G16 | Centralise hardcoded platform versions (`swift-tools: 5.9`, `ndkVersion 34`, etc.) | 🟡 Medium | ⬜ Pending |
| G17 | Facade-oriented generator bundles by language (`dart`, `kotlin`, `swift`, `c_bridge`, `cpp_native`, `cmake`) | 🟡 Medium | ✅ Done |
| G18 | Replace raw language-generator `StringBuffer` emitters with typed writer/model layer | 🟡 Medium | ✅ Done |

### Native Handle (Raw Pointer Escape Hatch)

> Allows users to receive or pass raw native pointers and do their own type conversion without going through any generated codec.

| ID | Item | Priority | Status |
|----|------|----------|--------|
| NH1 | `NativeHandle<T>` runtime class (`packages/nitro/lib/src/native_handle.dart`) | 🔴 High | ⬜ Pending |
| NH2 | `@NitroOwned` annotation — auto-attach `NativeFinalizer` + emit `_release` extern | 🔴 High | ⬜ Pending |
| NH3 | `BridgeType.isNativeHandle` + `nativeHandleTypeParam` in `bridge_spec.dart` | 🔴 High | ⬜ Pending |
| NH4 | `SpecExtractor`: detect `NativeHandle<T>` return/param types + `@NitroOwned` | 🔴 High | ⬜ Pending |
| NH5 | `SpecValidator`: `@NitroOwned` only on `NativeHandle` return types (not params) | 🟡 Medium | ⬜ Pending |
| NH6 | `dart_ffi_generator`: `Pointer<Void>` in FFI lookup, wrap/unwrap `NativeHandle<T>` at call site; `@NitroOwned` emits `NativeFinalizer` attachment | 🔴 High | ⬜ Pending |
| NH7 | `kotlin_generator`: `NativeHandle` → `Long` in JNI interface + bridge | 🔴 High | ⬜ Pending |
| NH8 | `swift_generator`: `NativeHandle` → `UnsafeMutableRawPointer?` in protocol + C bridge | 🔴 High | ⬜ Pending |
| NH9 | `cpp_bridge_generator`: `NativeHandle` → `void*` pass-through, no codec; `@NitroOwned` emits `extern "C" void ${sym}_release(void*)` declaration | 🔴 High | ⬜ Pending |
| NH10 | `cpp_interface_generator`: `NativeHandle` → `void*` in abstract method signature | 🔴 High | ⬜ Pending |
| NH11 | Unit tests: `native_handle_test.dart` — all generators, `@NitroOwned` wiring, no-codec pass-through | 🟡 Medium | ⬜ Pending |
| NH12 | Docs: `doc/advanced/native_handle.md` — usage guide, lifetime rules, cast patterns | 🟡 Medium | ⬜ Pending |

### Developer Experience

| ID | Item | Priority | Status |
|----|------|----------|--------|
| D1 | Timeline integration: `Timeline.startSync` / `finishSync` around bridge calls | 🟡 Medium | ⬜ Pending |
| D2 | Better error on missing `nitrogen link` (checksum handshake at runtime init) | 🟡 Medium | ⬜ Pending |
| D3 | `nitrogen doctor` file-permission checks (read/write, not just existence) | 🔴 High | ⬜ Pending |
| D4 | `@HybridStruct` String field docs: rule "use `@HybridRecord` instead" | 🟢 Low | ⬜ Pending |
| D5 | Zero-copy `@zeroCopy` annotation support for TypedData return values | 🟡 Medium | ⬜ Pending |
| D6 | Null-safety for TypedData fields: null guard before `GetDirectBufferAddress` | 🔴 High | ⬜ Pending |
| D7 | `SpecValidator` missing-platform warning (opt-in `warnOnMissingPlatforms` flag) | 🟢 Low | ⬜ Pending |
| D8 | Generated `_init()` actionable assertion on unsupported platform | 🟡 Medium | ⬜ Pending |

### Test Coverage

| ID | Item | Priority | Status |
|----|------|----------|--------|
| TC1 | Integration test suite: `nitrogen init` → `generate` → `link` on temp project | 🔴 High | ✅ Done |
| TC2 | Windows/Linux CI build jobs on GitHub Actions | 🟡 Medium | ⬜ Pending |
| TC3 | Memory/finalizer stress test: 10k `ZeroCopyBuffer` alloc/discard | 🟡 Medium | ⬜ Pending |
| TC4 | `IsolatePool` concurrency: 1 000 concurrent dispatches, no deadlock | 🟡 Medium | ⬜ Pending |
| TC5 | `spec_roundtrip_test.dart`: all platform combos pass validation | 🟡 Medium | ⬜ Pending |
| TC6 | `sealed_native_impl_test.dart`: type hierarchy smoke tests | 🟡 Medium | ⬜ Pending |

### Documentation

| ID | Item | Priority | Status |
|----|------|----------|--------|
| DC1 | Migration guide: `0.2 → 0.3` (`doc/migration/0.2-to-0.3.md`) | 🟡 Medium | ⬜ Pending |
| DC2 | Windows/Linux build guide (`doc/platforms/windows.md`, `linux.md`) | 🟡 Medium | ⬜ Pending |
| DC3 | `NativeFinalizer` usage guide (`doc/advanced/memory_management.md`) | 🟡 Medium | ⬜ Pending |
| DC4 | `@nitroAsync` performance & error semantics guide (`doc/advanced/async.md`) | 🟡 Medium | ⬜ Pending |
| DC5 | GoogleMock C++ testing guide (`doc/advanced/cpp_testing.md`) | 🟢 Low | ⬜ Pending |
| DC6 | Zero-copy ownership contract (`doc/lifecycle.md` — buffer lifetime rules) | 🔴 High | ⬜ Pending |

---

## 1. Foundation — Completed

All items below are shipped and tested. See `plan.md` status section and individual commit history for details.

- **Runtime** (`packages/nitro`): `NitroModule`, `HybridStruct`, `HybridEnum`, `NitroStream`, `NitroAsync`, `NitroNativeAsync`, `Backpressure`, `NitroRuntime.openStream`, `NitroRuntime.openNativeAsync<T>`, `IsolatePool`.
- **Generators**: `DartFfiGenerator`, `KotlinGenerator`, `SwiftGenerator`, `CppBridgeGenerator`, `CppInterfaceGenerator`, `CMakeGenerator`, `RecordGenerator` (Dart/Kotlin/Swift/C++ codecs).
- **CLI**: `nitrogen generate`, `nitrogen init`, `nitrogen link` (multi-module, auto-discovers all `.native.dart`), `nitrogen doctor`.
- **`@NitroNativeAsync`** (F16): Zero-hop async — native thread posts result directly via `Dart_PostCObject_DL`. ~930 µs → ~146 µs per call. 75 tests.
- **C++ Record Decoder** (F19): `NitroRecordReader` with `_require(n)` + explicit bounds-checked `readNullTag()`. `std::optional<T>` for nullable fields. 42 tests.
- **JNI** (F5, F8, F20, F22, F23): Scoped local frames, correct `_jniMangle` escaping, all IDs cached in `JNI_OnLoad`, exception helper caches IDs, `_streamJobs` → `ConcurrentHashMap`.
- **Generator architecture** (F25, F26, G17, G18): native generators are routed through `NativeGeneratorFacade` and per-language bundles under `packages/nitro_generator/lib/src/generators/languages/`; old flat generator files were removed. Shared `CodeWriter`/`CodeNode` infrastructure backs language emitters, and `rg "StringBuffer\\(" packages/nitro_generator/lib/src/generators/languages` is clean as of 2026-06-19.

---

## 2. Performance

### P1 — `FindClass()` inside `unpack_*_to_jni`
✅ **Done 2026-06-19.** `unpack_*_to_jni` now uses cached `jclass` and constructor IDs populated through the JNI cache path. Covered by `jni_perf_test.dart`.

### P2 — TypedData zero-copy params
`NewFloatArray` + `SetFloatArrayRegion` allocates + copies on every call. Offer `NewDirectByteBuffer` path for `Uint8List` and `Float32List` params when the Dart side owns the buffer for the duration of the call (not just fields via `@zeroCopy`).

### P3 — `NitroRuntime.checkError` assert-gate (Approach A, non-breaking)
✅ **Done 2026-06-19.** Generated sync Dart FFI calls now gate `NitroRuntime.checkError` inside `assert(() { …; return true; }())`, keeping debug checks while erasing the call in release. Covered by `jni_perf_test.dart`.

### P4 — Generator O(n²) type lookups
✅ **Done 2026-06-19.** The language generators now pre-build enum/struct/record lookup sets near the top of their emitters instead of repeatedly scanning `spec.enums`, `spec.structs`, and `spec.recordTypes` in hot generation loops.

### P5 — `RecordWriter` / `RecordReader` hot spots
✅ **Done 2026-06-19.** `RecordWriter` uses a growable `Uint8List` buffer with direct offset writes; `RecordReader` uses a single `ByteData.sublistView` and in-place UTF-8 string decode. Covered by `lazy_record_list_test.dart`.

### P6 — `IsolatePool` scheduling
`_leastBusyIndex` is O(N) per dispatch. Replace with min-heap ordered by `_inflight`, or fall back to round-robin when all workers are tied.

### P7 — `isLeaf: true`
✅ **Done 2026-06-19.** Pure sync native FFI calls that do not allocate arena state, return records/structs/typed data, or call back into Dart are emitted with `isLeaf: true`. Covered by `dart_ffi_generator_test.dart` and `benchmark_spec_test.dart`.

### P8 — `checkDisposed()` overhead
Add `@pragma('vm:prefer-inline')` and an `assert`-only variant for debug builds.

---

## 3. Stability & Correctness

### S1 — ABI version handshake
No magic-number check between generated native code and the Dart runtime. A stale `.so` silently produces struct-layout drift → segfault.

**Fix:** Emit `extern "C" uint32_t nitro_abi_version()` in every generated module. Check inside `NitroRuntime.init` — print "run `nitrogen generate`" on mismatch.

### S2 — Library-load race
`NitroRuntime.loadLib` uses an unguarded `Map<String, DynamicLibrary>`. First-call races across isolates can double-open on some platforms.

**Fix:** Synchronize the load, or use an `Expando` keyed on library name.

### S3 — Stream port-death
A native emitter that ignores the return value of `Dart_PostCObject` loops forever against a dead port after hot restart.

**Fix:** `if (!Dart_PostCObject_DL(port, &obj)) break;` in every generated emitter. Golden test per generator checking for the bail-out pattern.

### S4 — JNI `AttachCurrentThread` lifecycle
Without `DetachCurrentThread` on isolate shutdown, zombie attached threads keep the JVM alive and block app shutdown.

**Fix:** Add `IsolatePool.dispose()` hook that signals each worker to detach before the isolate exits.

### S5 — Zero-copy buffer ownership
`@HybridStruct(zeroCopy: ...)` fields have no documented contract about when native may free while Dart holds a `Uint8List` view.

**Fix:** Wrap in a finalizable holder, OR emit a compile-time generator error if not wrapped. Document in `doc/lifecycle.md`.

### S6 — Concurrent Kotlin/Swift impls
Two Dart calls from different isolates can land on different JNI threads simultaneously with no synchronisation guarantee.

**Fix:** Either emit `synchronized {}` wrappers in Kotlin by default, or document "impls must be thread-safe; Nitro calls from any thread."

### S7 — Thread-local error slot
`NitroRuntime.checkError` reads from a single shared slot per library. Two concurrent async calls on the same module race on that slot.

**Fix:** Move error state to TLS in the C++ bridge; read via the same TLS key on the calling thread.

### S8 — Out-param ABI (Approach B, major-version)
Replace `get_error` / `clear_error` round-trips with a `NitroError*` return + result out-param. Single FFI call in all cases. Requires regenerating all `.bridge.g.cpp` and `.bridge.g.dart`. Combine with other ABI-breaking changes.

---

## 4. Type Coverage & Bug Fixes

### Type Inventory Summary

| Type | DartFFI | Kotlin | Swift | CppBridge | CppIface | Record |
|------|---------|--------|-------|-----------|---------|--------|
| int sync/async | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| double sync/async | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| bool sync | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| bool async | ⬜ | ⬜ | ⬜ | ⬜ | — | — |
| String sync/async | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| void | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| enum sync | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| enum async | ✅ | ✅ | ⬜ | ⬜ | — | — |
| enum param/property | ✅ | ✅ | ⬜ | ✅/⬜ | ✅ | — |
| struct sync/async | ✅ | ✅/⬜ | ⬜ | ✅/⬜ | ✅ | — |
| Uint8List / Float32List | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| @ZeroCopy | ✅ | ✅ | ⬜ | ✅ | — | — |
| record sync/async | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| List\<record\> | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| List\<int/double/bool/String\> in record | ✅ T7 | ✅ T8 | ✅ T9 | — | — | ✅ T7 |
| nullable record field | ⬜ | ⬜ | ⬜ | — | — | ⬜ |
| Map\<String,dynamic\> | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| stream double | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| stream int | ✅ | ✅ | ⬜ | ⬜ | ⬜ | — |
| stream String/bool | ✅ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| stream enum | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| async Uint8List return | ✅ | — | ✅ | ✅ | — | — |
| enum field in @HybridRecord | ✅ T4 | ✅ T4 | ✅ T4 | ✅ T4 | — | ✅ T4 |

### Critical Bugs

**T1 — Stream `String`/`bool`/`int` unpack (`dart_ffi_generator.dart`)**
✅ **Done 2026-06-19.** Primitive stream unpack keeps primitive messages as primitives, while record/struct streams convert integer addresses into typed pointers before decode/free. Covered by `record_stream_unpack_test.dart` and `stream_all_types_test.dart`.

**T2 — Async `Uint8List`/`Float32List` return (`dart_ffi_generator.dart`)**
✅ **Done 2026-06-19.** Async typed-data returns use a malloc-owned `[int64 byteLength][payload bytes]` envelope. Dart decodes to `Uint8List`/`Float32List` and frees the native buffer; Swift and JNI C bridge returns allocate the same envelope. Covered by `dart_ffi_param_return_test.dart`, `swift_typed_data_async_test.dart`, and `cpp_bridge_types_test.dart`.

**T3 — `bool` JNI sig mismatch (`cpp_bridge_generator.dart`)**
✅ **Done 2026-06-19.** `bool` maps to `Z` / `jboolean` / `GetBooleanField` throughout JNI bridge generation. Covered by `kotlin_jni_nullable_primitive_test.dart`.

**T4 — `@HybridEnum` field inside `@HybridRecord`**
✅ **Done 2026-06-19.** `spec_extractor.dart` now classifies enum record fields and `List<Enum>` record fields as dedicated enum field kinds. Dart/Kotlin/Swift/C++ record serializers write `nativeValue` / `rawValue` and decode native integers back to enum values. Covered by `record_field_types_test.dart` plus the focused record generator suite.

**T5 — Nullable `@HybridStruct` param (C++ bridge)**
✅ **Done 2026-06-19.** C++ direct and Apple C++ dispatch bridges now guard nullable struct `void*` params before `*static_cast<const T*>`, report `NullPointerException` through `nitro_report_error`, and return the correct default for the exported C function. Covered by `cpp_bridge_generator_test.dart`.

**T6 — `withArena` async use-after-free (`dart_ffi_generator.dart`)**
✅ **Done 2026-06-19.** Async generated methods create an `Arena`, await the native call, and release in `finally`, so arena-allocated params live through the async boundary. Covered by `jni_perf_test.dart`.

### Integration Test Module: `type_coverage`

```
type_coverage/
  lib/src/type_coverage.native.dart      ← spec (all types, echo pattern)
  android/src/main/kotlin/nitro/…/TypeCoverageImpl.kt
  ios/Classes/TypeCoverageImpl.swift
  example/integration_test/type_coverage_test.dart

packages/nitro_generator/test/
  record_primitive_list_test.dart
  dart_ffi_all_types_test.dart
  kotlin_all_types_test.dart
  swift_all_types_test.dart
```

The spec exercises every method × type × modifier combination (sync, async, property, stream; enum, struct, record, TypedData, nullable, List).

---

## 5. Platform Expansion

### Design: Sealed `NativeImpl` Hierarchy (PX1–PX6)

Replace the `enum NativeImpl` with a sealed class hierarchy. Platform capability marker interfaces typed on `NitroModule` fields enforce valid combinations **at compile time**.

```dart
// packages/nitro_annotations/lib/src/annotations.dart

abstract interface class AppleNativeImpl {}
abstract interface class AndroidNativeImpl {}
abstract interface class WindowsNativeImpl {}
abstract interface class LinuxNativeImpl {}
abstract interface class WebNativeImpl {}

sealed class NativeImpl {
  static const swift  = SwiftImpl._();
  static const kotlin = KotlinImpl._();
  static const cpp    = CppImpl._();
  static const wasm   = WasmImpl._();
}

final class SwiftImpl  extends NativeImpl implements AppleNativeImpl   { ... }
final class KotlinImpl extends NativeImpl implements AndroidNativeImpl  { ... }
final class CppImpl    extends NativeImpl
    implements AppleNativeImpl, AndroidNativeImpl, WindowsNativeImpl, LinuxNativeImpl { ... }
final class WasmImpl   extends NativeImpl implements WebNativeImpl      { ... }

class NitroModule {
  final AppleNativeImpl?   ios;
  final AndroidNativeImpl? android;
  final AppleNativeImpl?   macos;
  final WindowsNativeImpl? windows;   // NEW
  final LinuxNativeImpl?   linux;     // NEW
  final WebNativeImpl?     web;       // NEW
  ...
}
```

**Compile-time guarantees:** `@NitroModule(windows: NativeImpl.swift)` → compile error.
**Backward compat:** `NativeImpl.swift`, `.kotlin`, `.cpp` are the same static const getters — no call-site changes.

`SpecExtractor._getNativeImpl` switches from index-based to type-name-based:
```dart
return switch (object.type?.element?.name) {
  'SwiftImpl'  => NativeImpl.swift,
  'KotlinImpl' => NativeImpl.kotlin,
  'CppImpl'    => NativeImpl.cpp,
  'WasmImpl'   => NativeImpl.wasm,
  _ => throw InvalidGenerationSourceError('Unknown NativeImpl: $typeName'),
};
```

### Phase 1 — macOS (PX7–PX9)
Reuses the existing Swift generator unchanged.
- `NitroModule.macos` field already in design above.
- `dart_ffi_generator`: explicit `if (Platform.isIOS || Platform.isMacOS)` branch.
- `.podspec`: `s.platforms = { :ios => '13.0', :osx => '10.15' }`.
- `Package.swift`: `platforms: [.iOS(.v13), .macOS(.v10_15)]`.
- `init_command`: `flutter create --platforms=android,ios,macos`.

### Phase 2 — Windows & Linux (PX10–PX16)
Both platforms use `NativeImpl.cpp` only.

**CMake cross-platform link libs:**
```cmake
if(ANDROID)
    target_link_libraries(${MODULE_TARGET} android log)
elseif(WIN32)
    # No extra system libs
elseif(UNIX AND NOT APPLE)
    target_link_libraries(${MODULE_TARGET} dl pthread)
endif()
```

**MSVC-safe registration stub:**
```cpp
#if defined(_WIN32)
static const int _nitro_reg = []() {
    ${lib}_register_impl(&g_impl);
    return 0;
}();
#else
__attribute__((constructor))
static void ${lib}_auto_register() { ${lib}_register_impl(&g_impl); }
#endif
```

**Note:** `dart_api_dl.c` must be compiled as C (not C++) on MSVC — add `set_source_files_properties(dart_api_dl.c PROPERTIES LANGUAGE C)`.

**`CppBridgeGenerator` platform guards:**

| Targeted platforms | Guard |
|--------------------|-------|
| Windows only | `#ifdef _WIN32` |
| Linux only | `#ifdef __linux__` |
| Windows + Linux | `#if defined(_WIN32) \|\| defined(__linux__)` |
| Apple only | `#ifdef __APPLE__` |
| All 5 native C++ | *(no guard)* |

**`doctor_command` checks:**
- Windows: `where cl` (MSVC), `cmake --version`, `WINDOWSSDKDIR` env.
- Linux: `g++ --version` or `clang++ --version`, `cmake --version`, `pkg-config`.

### Phase 3 — Web / WASM (PX17–PX20)

`dart:ffi` is unavailable on web. Must use conditional exports — `kIsWeb` alone does not prevent `dart:ffi` from being imported at compile time.

**Conditional export split:**
```dart
// nitro_runtime.dart
export 'nitro_runtime_stub.dart'
    if (dart.library.ffi)        'nitro_runtime_native.dart'
    if (dart.library.js_interop) 'nitro_runtime_web.dart';
```

**`WebBridgeGenerator`** emits `@JS()` external declarations:
```dart
@JS('NitroModules.${spec.lib}')
library;
import 'dart:js_interop';
@JS() external double mathAdd(double a, double b);
```

**Immediate:** `SpecValidator` must emit a clear error for `WasmImpl` (not silently succeed).

---

## 6. Generator & Build Quality

### G1 — Split / structure `cpp_bridge_generator.dart`
🟨 **Partial 2026-06-19.** The old flat generator file has moved to `languages/c_bridge/cpp_bridge_generator.dart`, JNI type mapping helpers live in `generators/cpp_bridge/type_mappings.dart`, and the emitter now uses the shared `CodeWriter`. The remaining optional work is a finer split into smaller c_bridge emitter files while preserving byte-identical output.

| Sub-task | Extract | File |
|----------|---------|------|
| G1.1 | Helpers (lines 1285–end) | ✅ `cpp_bridge/type_mappings.dart` |
| G1.2 | `_generateCppDirect` | `cpp_bridge/cpp_direct_emitter.dart` |
| G1.3 | JNI prologue (~200 lines) | `cpp_bridge/jni_swift_prologue.dart` |
| G1.4 | JNI per-function loop | `cpp_bridge/jni_method_emitter.dart` |
| G1.5 | Swift C-bridge blocks | `cpp_bridge/swift_shim_emitter.dart` |
| G1.6 | Struct/record/enum helpers | `cpp_bridge/type_emitter.dart` |
| G1.7 | `CodeWriter` class (explicit writer API) | ✅ replaces raw `StringBuffer.writeln` in language generators |
| G1.8 | Template-string helper for function bodies | after G1.1–G1.7 merged |

### G17–G18 — Generator facade and typed writer
✅ **Done 2026-06-19.**

- Shared architecture: `native_generator_facade.dart`, `native_generator_model.dart`, and language bundles under `generators/languages/*`.
- Language folders: `dart`, `kotlin`, `swift`, `c_bridge`, `cpp_native`, and `cmake`.
- Old top-level flat generator files were removed; top-level `generators/` now contains shared infrastructure plus `enum`, `record`, and `struct` emitters.
- Tests: `code_writer_test.dart`, `native_generator_facade_test.dart`, plus the full generator suite (`2654` passing).

### G2–G5 — Build system
- **G2:** Add 3 missing extensions to `build.yaml` (`.native.g.h`, `.mock.g.h`, `.test.g.cpp`).
- **G3:** Unit test asserting `build.yaml` keys == `NitroGeneratorBuilder().buildExtensions`.
- **G4:** Escalate `log.warning(...)` to `log.severe(...)` in `builder.dart` catch block.
- **G5:** `static final _formatter = DartFormatter()` — hoist off the per-build hot path.

### G6 — `dart_api_dl.c` path fragility
`nitrogen link` writes a machine-specific absolute pub-cache path. Breaks on CI / fresh clones.
Fix: resolve at build time from `.dart_tool/package_config.json`, or commit a path-agnostic CMake shim.

### G8 — `_jniSigType` unknown type silent fallthrough
✅ **Done 2026-06-19.** Unknown JNI signature types now throw a `StateError` with the type name during generation instead of silently mapping to object. Covered by `jni_perf_test.dart`.

### G9–G13 — Small quality wins
- **G9:** `LOGE` includes method name + JNI sig when `GetStaticMethodID` returns null.
- **G10:** `// nitro_generator: x.y.z` in generated file headers enables stale-detection lint.
- **G11:** Kotlin coroutine imports only emitted when spec has async/stream functions.
- **G12:** `callAsync` typed as `callAsync<T>` with structured result envelope.
- **G13:** Every generated header includes `// Generated from: camera.native.dart`.

### G14–G16 — Error handling & config
- **G14:** `spec_extractor.dart` bare `catch (_) {}` → rethrow `SpecParseException` with file path.
- **G15:** ✅ **Done 2026-06-19.** `link_command.dart` Nitro-native path resolution now throws contextual `StateError`s for malformed or unreadable `package_config.json`. Covered by `link_command_test.dart`.
- **G16:** Centralise `swift-tools-version: 5.9`, `ndkVersion = "34"`, `CMAKE_CXX_STANDARD 17`, `iOS 13.0` in a `VersionConstants` class or `nitrogen_versions.yaml`.

---

## 7. Developer Experience

### D1 — Timeline integration
Emit `Timeline.startSync('nitro:<method>')` / `finishSync()` around every bridge call. Gate behind `NitroConfig.debugMode`. Shows up in DevTools alongside Flutter frames.

### D2 — Missing `nitrogen link` error surface
Generator emits a checksum of the spec set. `link` writes the checksum into `CMakeLists.txt`. `NitroRuntime.init` compares and prints "run `nitrogen link`" instead of segfaulting.

### D3 — `nitrogen doctor` permission checks
`FileSystemEntity.stat()` checks on `Podfile`, `CMakeLists.txt`, `Plugin.kt`. Surface permission warnings before link fails.

### D5 — Zero-copy return values
`@zeroCopy` annotation works for struct fields and params, but a function returning `Uint8List` still copies via `GetByteArrayRegion`. Extend `@zeroCopy` to return types.

### D6 — Nullable TypedData null guard
If a Kotlin `ByteBuffer` field is `null`, `GetDirectBufferAddress` returns `null`. C++ side assigns the null pointer with no check.
Fix: emit null guard in generated bridge → `nitro_report_error` path.

### D7 — Missing-platform warnings
`SpecValidator` warning: "Camera targets ios + android but not macos." Controlled by `NitroConfig.warnOnMissingPlatforms` (default `true`).

### D8 — Unsupported-platform assertion
Replace silent fall-through in generated `_init()` with a named `assert(Platform.isIOS || Platform.isAndroid || ...)` that names the class and instructs the developer to add the platform.

---

## 8. `NativeHandle<T>` — Raw Pointer Escape Hatch

### Problem

`Pointer<T>` is recognized in `BridgeType` and the Dart FFI generator but Kotlin and Swift generators have **no handling** for `isPointer` — raw pointer types silently break across JNI/Swift. There is also no lifetime wrapper; returned pointers have no `NativeFinalizer` attached. Users who need raw access to a native object (e.g. an opaque camera handle, a GPU buffer pointer, a C++ object created and owned by native) have no clean path — they must fight the codec and manage lifetimes manually.

### Solution: `NativeHandle<T>` + `@NitroOwned`

**`NativeHandle<T>`** is a new first-class type in the `nitro` runtime. The type parameter `T extends NativeType` is a Dart-side hint only (no runtime constraint); the wire format is always a raw `int64` pointer address.

```dart
// packages/nitro/lib/src/native_handle.dart

class NativeHandle<T extends NativeType> {
  final Pointer<T> pointer;
  int get address => pointer.address;

  const NativeHandle(this.pointer);
  NativeHandle.fromAddress(int addr) : pointer = Pointer<T>.fromAddress(addr);

  // Manual early release — only meaningful when @NitroOwned attaches a finalizer.
  void release() => _releaseCallback?.call(address);

  // Internal — set by generated code when @NitroOwned is present.
  void Function(int)? _releaseCallback;
}
```

**`@NitroOwned`** is a new annotation in `nitro_annotations`. It marks that the native side heap-allocates the returned handle and the generator should:
1. Emit `extern "C" void ${cSymbol}_release(void* handle)` in the C++ header.
2. Attach a `NativeFinalizer` on the Dart side that calls `${cSymbol}_release` when the `NativeHandle` is GC'd.
3. Wire the `_releaseCallback` so `handle.release()` triggers early free.

```dart
// packages/nitro_annotations/lib/src/annotations.dart
const nitroOwned = NitroOwned();
class NitroOwned { const NitroOwned(); }
```

### Spec usage

```dart
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Camera extends HybridObject {
  // Borrow — caller does NOT own; handle is valid only for this call.
  NativeHandle<Void> peekLatestFrame();

  // Own — native heap-allocates; Dart NativeFinalizer calls _release on GC.
  @NitroOwned
  NativeHandle<Void> acquireFrame();

  // Pass handle back to native — no codec, pure pointer pass-through.
  void processFrame(NativeHandle<Void> handle);

  // Type-hinted variant — T is documentation only, no runtime difference.
  @NitroOwned
  NativeHandle<CameraFrameNative> acquireTypedFrame();
}
```

User then does their own conversion on the Dart side:
```dart
final handle = cam.acquireFrame();                         // NativeHandle<Void>
final framePtr = handle.pointer.cast<CameraFrameNative>(); // Pointer<CameraFrameNative>
final frame = framePtr.ref;                                // CameraFrameNative (Dart NativeStruct)
handle.release();                                          // early free; or let GC do it
```

### Cross-platform generator output

| Platform | Param type | Return type | Notes |
|----------|-----------|-------------|-------|
| C++ interface | `void*` | `void*` | Pure pass-through; no codec touched |
| C++ bridge | `void*` | `void*` | `@NitroOwned`: also emits `void ${sym}_release(void*)` extern decl |
| Kotlin (JNI) | `Long` | `Long` | Pointer address cast to `Long`; JNI sig `J` |
| Swift | `UnsafeMutableRawPointer?` | `UnsafeMutableRawPointer?` | `@_cdecl` bridge uses same type |
| Dart FFI lookup | `Pointer<Void>` | `Pointer<Void>` | Unwrapped to `int`/rewrapped to `NativeHandle<T>` at call site |

### `@NitroOwned` generated wiring (Dart FFI side)

```dart
// Generated for: @NitroOwned NativeHandle<Void> acquireFrame()
static final _acquireFrameReleasePtr =
    _dylib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('camera_acquire_frame_release');
static final _acquireFrameFinalizer =
    NativeFinalizer(_acquireFrameReleasePtr.cast());

NativeHandle<Void> acquireFrame() {
  checkDisposed();
  final raw = _acquireFramePtr();
  NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr);
  final handle = NativeHandle<Void>.fromAddress(raw.address);
  _acquireFrameFinalizer.attach(handle, raw.cast(), detach: handle);
  handle._releaseCallback = (addr) {
    _acquireFrameReleasePtr.asFunction<void Function(Pointer<Void>)>()(
        Pointer<Void>.fromAddress(addr));
    _acquireFrameFinalizer.detach(handle);
  };
  return handle;
}
```

### `@NitroOwned` C++ header output

```cpp
// Generated in camera.native.g.h alongside the abstract interface:

/// Release a handle acquired from acquireFrame().
/// Called automatically by Dart's NativeFinalizer; also callable manually.
extern "C" NITRO_EXPORT void camera_acquire_frame_release(void* handle);
```

The user implements it in their `.cpp` file:
```cpp
void camera_acquire_frame_release(void* handle) {
    delete static_cast<CameraFrame*>(handle);
}
```

### `SpecValidator` rules

```
ERROR   @NitroOwned on a void return type — nothing to release
ERROR   @NitroOwned on a non-NativeHandle return type — use @NitroOwned only with NativeHandle<T>
ERROR   @NitroOwned on a parameter — ownership annotation only applies to return values
WARNING NativeHandle<T> param with no matching @NitroOwned return — consider documenting borrow contract
```

### File changes

| File | Change |
|------|--------|
| `packages/nitro/lib/src/native_handle.dart` | **New** — `NativeHandle<T>` class |
| `packages/nitro/lib/nitro.dart` | Export `native_handle.dart` |
| `packages/nitro_annotations/lib/src/annotations.dart` | Add `@NitroOwned` |
| `packages/nitro_generator/lib/src/bridge_spec.dart` | `BridgeType.isNativeHandle`, `nativeHandleTypeParam`; `BridgeFunction.isOwned` |
| `packages/nitro_generator/lib/src/spec_extractor.dart` | Detect `NativeHandle<T>` + `@NitroOwned` |
| `packages/nitro_generator/lib/src/spec_validator.dart` | `@NitroOwned` validation rules |
| `packages/nitro_generator/lib/src/generators/languages/dart/dart_ffi_generator.dart` | Wrap/unwrap `NativeHandle<T>`; `@NitroOwned` finalizer wiring |
| `packages/nitro_generator/lib/src/generators/languages/kotlin/kotlin_generator.dart` | `NativeHandle` → `Long` |
| `packages/nitro_generator/lib/src/generators/languages/swift/swift_generator.dart` | `NativeHandle` → `UnsafeMutableRawPointer?` |
| `packages/nitro_generator/lib/src/generators/languages/c_bridge/cpp_bridge_generator.dart` | `void*` pass-through; `@NitroOwned` release extern |
| `packages/nitro_generator/lib/src/generators/languages/cpp_native/cpp_interface_generator.dart` | `void*` in abstract method |
| `packages/nitro_generator/test/native_handle_test.dart` | **New** — all generators, `@NitroOwned` wiring |
| `doc/advanced/native_handle.md` | **New** — usage guide, lifetime rules, cast patterns |

---

## 9. Test Coverage

### Immediate unit test gaps (from §4 type coverage):
- `record_primitive_list_test.dart` — `List<int/double/bool/String>` fields in all 4 serializers, nullable record field
- `dart_ffi_all_types_test.dart` — bool, enum, struct, TypedData async, property types
- `kotlin_all_types_test.dart` — bool, enum, struct async, record async, TypedData, properties
- `swift_all_types_test.dart` — all types + stream item types

### Integration test suite (TC1):
```
1. dart create --template=package temp_plugin
2. dart run nitrogen_cli init Temp
3. dart run nitrogen_cli generate
4. dart run nitrogen_cli link
5. flutter build apk --release     (Android compile check)
6. flutter build ios --no-codesign (iOS compile check, macOS runner)
```

### Platform expansion tests (TC5–TC6):
- `spec_roundtrip_test.dart`: all valid platform combos + invalid combos trigger correct error codes.
- `sealed_native_impl_test.dart`: `NativeImpl.cpp is WindowsNativeImpl` → true; `NativeImpl.swift is AndroidNativeImpl` → false; exhaustive switch compiles.

---

## 10. Documentation

| Doc | Path | Content |
|-----|------|---------|
| Migration guide | `doc/migration/0.2-to-0.3.md` | Before/after diff for every breaking change |
| Windows guide | `doc/platforms/windows.md` | MSVC toolchain, CMake hooks, limitations |
| Linux guide | `doc/platforms/linux.md` | GCC/Clang, CMake hooks |
| Memory management | `doc/advanced/memory_management.md` | `dispose()`, `NativeFinalizer`, zero-copy ownership |
| Async guide | `doc/advanced/async.md` | Isolate pool vs `@NitroNativeAsync`, overhead, error propagation |
| C++ testing | `doc/advanced/cpp_testing.md` | GoogleTest + generated mock setup |
| Lifecycle | `doc/lifecycle.md` | Zero-copy buffer lifetime — "native MUST NOT free until Dart releases" |

---

## 11. Delivery Sequencing

### Phase A — Critical bug fixes (ship first)
T3 (bool JNI sig) → T1 (stream unpack) → T2 (async TypedData) → T6 (withArena use-after-free) → ✅ T4 (enum in record) → ✅ T5 (nullable struct guard) → G8 (jniSigType throw) → G14 (spec extractor catch) → G15 (link empty catch)

### Phase B — Foundation for platform expansion
PX1 (sealed NativeImpl) → PX2–PX4 (BridgeSpec + SpecExtractor + SpecValidator) → PX20 (WASM error) → PX6 (link_command) → PX7–PX9 (macOS)

### Phase C — Performance wins (low risk, non-breaking)
P3 (assert-gate checkError) → ✅ P4 (O(1) type lookups) → P7 (isLeaf) → P1 (JNI struct unpack caching) → P5 (RecordWriter buffer)

### Phase D — Platform expansion (Windows/Linux/Web)
PX10–PX16 (Windows + Linux generators, CMake, CLI) → PX17–PX19 (Web conditional export + WebBridgeGenerator)

### Phase E — Quality & observability
✅ G17–G18 (generator facade + typed writer) → G1.2–G1.6/G1.8 (optional finer c_bridge split) → G2–G5 (build system) → D1 (Timeline) → D2 (link checksum) → S1 (ABI version)

### Phase F — Stability hardening
S3 (stream port-death) → S4 (JNI detach) → S2 (load race) → S7 (TLS error slot) → TC1–TC4 (integration + stress tests)

### Phase G — Type coverage integration
✅ T7–T10 (unit tests) → T11 (type_coverage plugin) → ✅ TC1 (integration test suite)

### Phase H — Native Handle
NH1 (`NativeHandle<T>` runtime class) → NH2 (`@NitroOwned` annotation) → NH3–NH4 (`BridgeSpec` + `SpecExtractor`) → NH5 (`SpecValidator`) → NH6–NH10 (all 5 generators) → NH11 (tests) → NH12 (docs)

---

## Non-Goals for V1

- C++ as primary implementation language on iOS/Android (Swift + Kotlin are V1 targets; `NativeImpl.cpp` for direct C++ is supported but not the recommended path)
- WASM production-ready output (blocked on Flutter stable WASM: flutter/flutter#128319)
- Automatic C ABI versioning via toolchain (S1 covers runtime check; full toolchain version pinning is V2)
- Pigeon-compatible platform channel fallback (pure FFI only)

---

## File Change Index

> Quick reference — which source file is affected by each plan item.

| Plan IDs | Primary file(s) |
|----------|-----------------|
| P3, G12 | `generators/languages/dart/dart_ffi_generator.dart` |
| P1, T3, T5, G8, G9 | `generators/languages/c_bridge/cpp_bridge_generator.dart` |
| P5 | `nitro/lib/src/record_codec.dart` |
| P6 | `nitro/lib/src/isolate_pool.dart` |
| P7 | `generators/languages/dart/dart_ffi_generator.dart` (FFI `lookupFunction` calls) |
| S1 | `generators/languages/c_bridge/cpp_bridge_generator.dart`, `nitro_runtime.dart` |
| S2 | `nitro_runtime.dart` |
| S3 | all generator emitters |
| S4 | `isolate_pool.dart`, Kotlin generator |
| S7 | `generators/languages/c_bridge/cpp_bridge_generator.dart` (TLS), `nitro_runtime.dart` |
| T1, T2, T6 | `generators/languages/dart/dart_ffi_generator.dart` |
| T4 | `spec_extractor.dart`, all 4 record generators |
| PX1 | `nitro_annotations/lib/src/annotations.dart` |
| PX2, PX3 | `bridge_spec.dart` |
| PX4 | `spec_extractor.dart` |
| PX5, PX20 | `spec_validator.dart` |
| PX6 | `nitrogen_cli/lib/commands/link_command.dart` |
| PX7–PX9, PX10, PX11 | `generators/languages/c_bridge/cpp_bridge_generator.dart`, `generators/languages/dart/dart_ffi_generator.dart` |
| PX12 | `generators/languages/cmake/cmake_generator.dart` |
| PX13, PX14 | `link_command.dart`, `init_command.dart` |
| PX15 | `doctor_command.dart` |
| PX17 | `nitro/lib/src/nitro_runtime.dart` (split → `_native` / `_web`) |
| PX18 | `generators/web_bridge_generator.dart` (new) |
| G1 | `generators/languages/c_bridge/cpp_bridge_generator.dart` → optional smaller `c_bridge/` sub-modules |
| G2, G3 | `build.yaml`, `test/build_yaml_drift_test.dart` |
| G4, G5 | `builder.dart` |
| G6 | `nitrogen_cli/lib/commands/link_command.dart`, CMake shim |
| G7 | `spec_extractor.dart` |
| G10, G11, G13 | `generators/languages/kotlin/kotlin_generator.dart`, all generators (headers) |
| G14 | `spec_extractor.dart` |
| G15 | `nitrogen_cli/lib/commands/link_command.dart` |
| G16 | new `VersionConstants` class or `nitrogen_versions.yaml` |
| D1 | `generators/languages/dart/dart_ffi_generator.dart`, `nitro_runtime.dart` |
| D2 | `generators/languages/c_bridge/cpp_bridge_generator.dart`, `link_command.dart`, `nitro_runtime.dart` |
| D3 | `nitrogen_cli/lib/commands/doctor_command.dart` |
| D5 | `generators/languages/dart/dart_ffi_generator.dart`, `generators/languages/c_bridge/cpp_bridge_generator.dart` |
| D6 | `generators/languages/c_bridge/cpp_bridge_generator.dart` (JNI path), `generators/languages/kotlin/kotlin_generator.dart` |
| NH1 | `nitro/lib/src/native_handle.dart` (new) |
| NH2 | `nitro_annotations/lib/src/annotations.dart` |
| NH3, NH4, NH5 | `bridge_spec.dart`, `spec_extractor.dart`, `spec_validator.dart` |
| NH6 | `generators/languages/dart/dart_ffi_generator.dart` |
| NH7 | `generators/languages/kotlin/kotlin_generator.dart` |
| NH8 | `generators/languages/swift/swift_generator.dart` |
| NH9 | `generators/languages/c_bridge/cpp_bridge_generator.dart` |
| NH10 | `generators/languages/cpp_native/cpp_interface_generator.dart` |
| NH11 | `test/native_handle_test.dart` (new) |
| NH12 | `doc/advanced/native_handle.md` (new) |
