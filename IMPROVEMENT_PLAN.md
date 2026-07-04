# Flutter Nitro Ecosystem — Improvement Plan

> Derived from a deep comparison with the React Native Nitro reference implementation
> at `/Users/shreemanarjunsahu/Documents/GitHub/nitro`.
> Created: 2026-06-26 · Last audited: 2026-07-02
>
> Sprints 1–4 are complete (see below). Sprints 5–9 added 2026-07-02 after the
> 0.5.4 release: full RN Nitro parity achieved (L11–L16 closed, L15 N/A), so the
> plan shifts from feature parity to hygiene, performance, DX, and adoption.

---

## Where Flutter Already Wins Over RN Nitro

| Feature | Status |
|---------|--------|
| `SpecValidator` with explicit error codes (E001-E014+, W001-W006) | ✅ Flutter superior |
| `Backpressure` modes (dropLatest / buffer / batch / block) | ✅ Flutter superior |
| `@NitroNativeAsync` direct native-port path | ✅ Flutter superior |
| `@zeroCopy` TypedData without copying | ✅ Flutter superior |
| Full IR extraction before generation (enables cross-field validation) | ✅ Flutter superior |
| Binary map encoding (vs RN's JSON) — NaN/Infinity-safe, 3–5× faster | ✅ Flutter superior |
| `@NitroVariant` sealed/union types with binary wire codec | ✅ Flutter superior |

---

## Sprint 1 — Structural / DX

> Goal: make the generator easy to navigate, fix, and extend. No user-visible behaviour changes.

---

### P0 · Split Monolithic Generators ✅

**Before → After:**

| Generator | Before | Orchestrator now |
|-----------|--------|-----------------|
| `kotlin_generator.dart` | 1148 lines | **212 lines** |
| `swift_generator.dart` | 1229 lines | **119 lines** |
| `dart_ffi_generator.dart` | 1588 lines | **65 lines** |
| `record_generator.dart` | 1656 lines | **35 lines** |

**Actual file structure created:**

```
generators/languages/kotlin/
├── kotlin_generator.dart            212 lines — orchestrator
└── emitters/
    ├── kotlin_callback_emitter.dart
    ├── kotlin_function_emitter.dart 515 lines
    ├── kotlin_property_emitter.dart
    ├── kotlin_stream_emitter.dart
    ├── kotlin_type_mapper.dart      257 lines
    └── kotlin_variant_emitter.dart

generators/languages/swift/
├── swift_generator.dart             119 lines — orchestrator
└── emitters/
    ├── swift_function_emitter.dart  520 lines
    ├── swift_property_emitter.dart  115 lines
    ├── swift_stream_emitter.dart    145 lines
    ├── swift_type_mapper.dart       314 lines
    ├── swift_variant_emitter.dart   180 lines
    ├── swift_protocol_registry_emitter.dart  87 lines  [part]
    ├── swift_map_typed_data_emitter.dart      97 lines  [part]
    └── swift_cpp_module_generator.dart       139 lines  [part]

generators/languages/dart/
├── dart_ffi_generator.dart           65 lines — orchestrator
├── dart_ffi_return_helpers.dart     133 lines
└── emitters/                        [all part files]
    ├── dart_type_ffi_mapper.dart    158 lines
    ├── dart_map_encode_helpers.dart  90 lines
    ├── dart_record_ffi_helpers.dart 166 lines
    ├── dart_async_helpers.dart      298 lines
    ├── dart_callback_helpers.dart   263 lines
    ├── dart_impl_class_emitter.dart 200 lines
    ├── dart_function_emitter.dart   188 lines
    ├── dart_property_emitter.dart    50 lines
    ├── dart_stream_emitter.dart      89 lines
    └── dart_map_factory_emitter.dart 76 lines

generators/record_generator.dart       35 lines — orchestrator
generators/record/                     [all part files]
    ├── dart_record_generator.dart   393 lines
    ├── cpp_record_generator.dart    221 lines
    ├── kotlin_record_generator.dart 434 lines
    └── swift_record_generator.dart  565 lines
```

**Status:** ✅ DONE — 3114 tests pass.

---

### P3 · `TypeMapper` Abstraction ✅

`generators/type_mapper.dart` created with `abstract interface class TypeMapper`. `KotlinTypeMapper` and `SwiftTypeMapper` implement it.

**Status:** ✅ DONE

---

### P8 · `BridgeTypeKind` Enum ⚠️ PARTIAL

`BridgeTypeKind` enum exists with values `primitive`, `enumValue`, `struct_`, `record`, `recordList`, `primitiveList`, `typedData`, `map`, `function_`, `nativeHandle`, `pointer`, `stream`, `future`, `variant`.

**Gap:** `BridgeType.kind` getter lumps `struct_` and `enumValue` into `primitive` because `BridgeType` has no `spec` reference and can't call `spec.isEnumName(name)`. The getter currently returns:
```dart
return BridgeTypeKind.primitive; // int, double, bool, String, void, enums, structs ← wrong
```

**Fix needed:** Generators that dispatch on `.kind` will silently miss struct/enum cases. Either:
- Add `spec`-aware `BridgeType.resolvedKind(BridgeSpec spec)` method, or
- Have generators call `spec.isEnumName(t.name) ? BridgeTypeKind.enumValue : t.kind`

Until fixed, the `kind` getter should not be used for struct/enum dispatch without the fallback.

**Fix added:** `BridgeType.resolvedKind(BridgeSpec spec)` method now returns the correct `BridgeTypeKind.enumValue`, `BridgeTypeKind.struct_`, or `BridgeTypeKind.variant` when `spec` is available.

**Status:** ✅ DONE — `resolvedKind(spec)` implemented; `kind` getter still returns `primitive` as safe fallback for callers without spec context.

---

### P5 · E010–E013 Unknown Type Reference Validation ✅

Error codes E010 (function param/return), E011 (stream item), E012 (property), E013 (record field) implemented and tested.

**Status:** ✅ DONE

---

### P6 · `BridgeSpec` O(1) Type Index ⚠️ PARTIAL

Lazy maps `_enumIndex`, `_structIndex`, `_recordIndex`, `_variantIndex` added to `BridgeSpec` with `isEnumName`, `isStructName`, `isRecordName`, `isVariantName`, `enumByName`, `structByName`, `recordByName`, `variantByName`.

**Gap:** Many O(n) `.any(e => e.name == x)` lookups remain in:
- `spec_validator.dart`: 5 remaining (lines 404, 405, 479, 480, 847)
- `dart_ffi_helpers.dart` (part file): ~28 occurrences
- `dart_stream_emitter.dart`: 2 occurrences
- `record_generator.dart`: several
- `struct_generator.dart`: several
- C bridge generators: 11 occurrences

**Fix completed:** All O(n) `.any(e => e.name == x)` lookups replaced with `spec.isEnumName()` / `spec.isStructName()` / `spec.isRecordName()` across all generators and validators.

**Status:** ✅ DONE — zero `.any((e) => e.name == x)` lookups remain in any generator or validator file.

---

### P7 · `CodeWriter` Block / Join Helpers ✅

`block()`, `ifBlock()`, `when()`, `joinLines()`, `blank()` added to `CodeWriter`.

**Status:** ✅ DONE

---

## Sprint 2 — `@NitroVariant` (Sealed/Union Types) ✅

`@NitroVariant` fully implemented across Dart FFI, Swift, Kotlin. E014 validation. 20 tests in `nitro_variant_test.dart`.

**Gap:** C++ generators (`cpp_interface_generator.dart`, `cpp_bridge_generator.dart`, `cpp_mock_generator.dart`) do NOT generate `std::variant` for `@NitroVariant` types. RN Nitro does. This means C++ implementations can't use variants yet.

**Status:** ✅ DONE (Dart/Swift/Kotlin) — C++ variant codegen gap tracked as Sprint 4 P1.

---

## Sprint 3 — Binary Map Encoding ✅

`_nitroEncodeMapBinaryXxx` / `_nitroDecodeMapBinaryXxx` helpers generated for `Map<String,int|double|bool|String>` across all three native bridges. NaN/Infinity-safe via IEEE 754 float64. `Map<String,dynamic>` uses tagged binary with JSON fallback for unknown value types.

**Web bridge gap:** `web_bridge_generator.dart` still uses `jsonEncode`/`jsonDecode` for maps — intentional since JS interop goes through JSObject anyway.

**Status:** ✅ DONE (native bridges)

---

## Sprint 4 — Correctness & Coverage Gaps

> These items were identified during the 2026-06-26 audit.

---

### S4-P1 · C++ Variant Codegen ⬜

**Problem:** `@NitroVariant` generates Dart/Swift/Kotlin code but nothing in the C++ bridge generators. Any C++ native implementation that receives/returns a variant type has no generated codec.

**RN equivalent:** C++ uses `std::variant<A, B, C>` with a `from_native` free function.

**Affected files:**
- `cpp_interface_generator.dart` (472 lines)
- `cpp_bridge_generator.dart` (1131 lines)
- `cpp_mock_generator.dart` (337 lines)
- `record_generator.dart` — `generateCpp()` at line 447

**Solution:** Add `std::variant` typedef + `fromNative` / `writeFields` C++ helpers to the C++ header generator, mirroring the Kotlin/Swift pattern.

**Acceptance criteria:**
- `cpp_interface_generator.dart` emits `std::variant<CaseA, CaseB>` typedef for `@NitroVariant` types
- `record_generator.dart` `generateCpp()` emits `fromNative`/`writeFields` for variant cases
- New test in a C++ bridge test file

**Status:** ✅ DONE — `std::variant<>` typedef + case structs + `nitro_decode_Xxx` / `nitro_encode_Xxx` generated in `cpp_interface_generator.dart`. 8 new tests in `nitro_variant_test.dart`.

---

### S4-P2 · Complete O(1) Index Adoption ✅

**Problem:** P6 added indexes to `BridgeSpec` but many call sites still use O(n) `.any()` lookups. At generation time this is ~50ms overhead on large specs.

**Files to update:**
- `spec_validator.dart`: replace 5 remaining `.any()` calls
- `dart_ffi_helpers.dart`: replace ~28 `.any()` calls with `spec.isEnumName()` / `spec.isStructName()`
- `dart_stream_emitter.dart`: 2 calls
- `record_generator.dart`: several
- `struct_generator.dart`: several
- C bridge generators: 11 calls

**Acceptance criteria:**
- Zero `.any((e) => e.name == x)` lookups remain in any generator or validator
- All tests still pass

**Status:** ✅ DONE — all replaced, 3114 tests pass.

---

### S4-P3 · Fix BridgeTypeKind for struct_/enumValue ✅

**Problem:** `BridgeType.kind` returns `primitive` for both structs and enums. Generators that switch on `.kind` silently fall through for these types. This makes P8 incomplete.

**Solution options:**
1. Add `BridgeType.resolvedKind(BridgeSpec spec)` — returns `struct_` / `enumValue` when `spec.isStructName(name)` / `spec.isEnumName(name)`.
2. Alternatively, generators that already have `spec` can inline `spec.isEnumName(t.name) ? BridgeTypeKind.enumValue : t.kind`.

**Acceptance criteria:**
- `resolvedKind(spec)` returns `BridgeTypeKind.struct_` for struct types and `BridgeTypeKind.enumValue` for enum types
- At least one generator migrated to `switch (t.resolvedKind(spec))`
- All tests pass

**Status:** ✅ DONE — `resolvedKind(BridgeSpec spec)` implemented on `BridgeType`.

---

### S4-P4 · Split `record_generator.dart` (1656 lines) ⬜

**Problem:** `record_generator.dart` is the largest remaining file at 1656 lines. It contains Dart, C++, Kotlin, and Swift generation in one class.

**Target structure:**
```
generators/record_generator.dart          ← orchestrator
generators/record/
    dart_record_generator.dart            ← generateDartExtensions (lines 44–446)
    cpp_record_generator.dart             ← generateCpp (lines 447–662)
    kotlin_record_generator.dart          ← generateKotlin (lines 663–1093)
    swift_record_generator.dart           ← generateSwift (lines 1094–1656)
```

**Acceptance criteria:**
- Each record generator file < 500 lines
- Orchestrator < 50 lines
- All tests pass

**Status:** ✅ DONE — orchestrator 35 lines; 4 part files in `generators/record/` (393/221/434/565 lines). `RecordGenerator.recordBytesHint` kept as public delegate for external callers.

---

### S4-P5 · Split `dart_ffi_helpers.dart` (967 lines) ⬜

**Problem:** The `dart_ffi_helpers.dart` part file has 967 lines — it's just a renamed monolith. The plan originally called for `dart_type_mapper.dart`, `dart_callback_helpers.dart`, etc.

**Target split:**
```
dart/emitters/
    dart_type_ffi_mapper.dart    ← _typeToFFI, _typeToDartFFI, _toNativeType, _toDartType
    dart_callback_helpers.dart   ← _emitCallbackHelpers, _callbackArgExpr, _callbackNativeSignature, etc.
    dart_return_decode.dart      ← _emitReturnDecode, _emitTypedDataDecodeReturn, _decodeRecordExpr
    dart_map_encode_helpers.dart ← _emitMapBinaryHelpers, _collectMapValueTypes, _nitroMapPayload
    dart_ffi_helpers.dart        ← remaining: _cap, _paramList, _encodeRecordParam, isLeaf helpers
```

**Acceptance criteria:**
- No single file > 300 lines
- All part files pass analysis with no errors
- All tests pass

**Status:** ✅ DONE — 5 topic-specific part files (158/90/166/298/263 lines). Monolith `dart_ffi_helpers.dart` deleted.

---

### S4-P6 · `@NitroResult<T>` Support ⬜

**Problem:** The plan listed `@NitroResult<T>` as a Sprint 2 item but it was never started. RN Nitro has `Result<T, E>` types for native error propagation without exceptions.

**Dart annotation needed:**
```dart
class NitroResult<T> {
  const NitroResult();
}
```

**Wire format:** `[1B isError][payload bytes]` — success: record codec for T; error: string codec for message.

**Generator changes:**
- `spec_extractor.dart`: detect `@NitroResult<T>` type alias classes
- `bridge_spec.dart`: `BridgeResult` class + `BridgeSpec.results` list
- All 4 language generators: emit `Result<T>` / `sealed class Result` / `std::expected<T, E>`
- `spec_validator.dart`: E015 — nested Result types

**Status:** ✅ DONE — `@NitroResult` annotation + `NitroResultValue<T>` sealed types + E015 validation + Dart FFI codegen. 22 new tests in `nitro_result_test.dart`. Total: 3136 tests pass.

---

### S4-P7 · `jni_method_emitter.dart` Cleanup (1200 lines) ✅

**Problem:** `jni_method_emitter.dart` is 1200 lines and handles JNI bridge generation for all type combinations. It has the same structural problems as the old `swift_generator.dart`.

**Note:** This is lower priority since it works correctly and is rarely touched.

**Solution:** Extracted 7 named helper functions from `_emitJniMethods`, reducing the orchestrator from ~1130 lines to 42 lines:
- `_emitJniNativeAsyncFuncBody` — @nitroNativeAsync function bridge (~70 lines)
- `_emitJniRegularFuncBody` — regular sync/async function bridge (~395 lines)
- `_emitJniPropertyBridges` — property getter/setter bridges (~135 lines)
- `_emitJniStreamBridges` — stream register/release/emit bridges (~150 lines)
- `_emitJniCallbackInvokers` — callback invocation JNI methods (~150 lines)
- `_emitJniInitializeAndPostHelpers` — JNI initialize() + postXxxToPort (~175 lines)

**Status:** ✅ DONE — 3136 tests pass.

---

## Sprint 5 — Correctness & Release Hygiene

> Goal: zero known-failing tests, releases that cannot desync, CI that catches
> platform-specific regressions before users do. All items are small; do first.

### S5-P1 · Fix the one known-failing CLI test 🔴 ⬜

**Problem:** `nitrogen init — testing_project fixture structure › android Kotlin Plugin.kt uses JniBridge and registers impl` fails (verified 2026-07-02, 760/761 pass). The assertion expects `TestingProjectJniBridge.register(` but the generated plugin calls `registerFactory(`.

**Fix:** Decide which is canonical. The generator's `registerFactory(` is the current runtime contract, so update the test assertion — unless the fixture predates the factory pattern and other docs still say `register(`, in which case sweep those too.

**Acceptance:** `dart test` in `packages/nitrogen_cli` is 761/761 green.

### S5-P2 · Single source of truth for the version 🔴 ⬜

**Problem:** `nitroGeneratorVersion` in `generator_metadata.dart` is hand-edited and must match 4 pubspecs. The 0.5.3→0.5.4 bump shipped a CI failure because the constant lagged the pubspec (caught only by `generator_metadata_test.dart`).

**Fix:** A `tool/release.dart` script that takes the new version once and rewrites: 4 × `pubspec.yaml`, 4 × `CHANGELOG.md` headers (prompting for entries), and `generator_metadata.dart`. Keep the existing test as the CI backstop.

**Acceptance:** One command performs a full version bump; running the test suite immediately after passes.

### S5-P3 · CI platform matrix ⬜

**Problem:** Generator/CLI unit tests run in CI, but device verification is manual on macOS. Windows/Linux desktop codegen (L9) and Android JNI paths have no automated end-to-end coverage.

**Fix, in priority order:**
1. Linux + Windows CI runners for the 4159 generator unit tests (cheap, catches path/newline bugs).
2. An Android emulator job running `nitro_type_coverage` integration tests.
3. A macOS runner job for the multi-spec `testing_project` fixture (`nitrogen generate && flutter test integration_test`).

**Acceptance:** A PR that breaks JNI or desktop codegen fails CI without manual device testing.

### S5-P4 · Codec fuzz tests ⬜

**Problem:** The binary wire formats (`RecordReader`/`RecordWriter`, variant tags, map tag-5 blobs, `NitroAnyValue`) are covered by example-based tests only. Malformed/truncated buffers from a buggy native impl should fail loudly, not corrupt memory.

**Fix:** Property-based round-trip tests (random field shapes, lengths, nesting) plus truncated-buffer decode tests asserting a clean throw. Pure Dart, fast, no device needed.

**Acceptance:** ≥1 fuzz suite for records, variants, maps, and `NitroAnyValue`; truncation never reads out of bounds.

---

## Sprint 6 — Web Story (L8)

> The only remaining functional gap with user impact. Streams and
> `@NitroNativeAsync` currently throw `UnsupportedError` on web (W007).

### S6-P0 · Web bridge generator emits compilable code ✅ (analyzer-clean; compile blocked on S6-P1 groundwork)

**Shipped 2026-07-03:** `web_bridge_generator.dart` previously emitted files with ~50 analyzer errors for struct/record-bearing specs: it imported the spec's `.g.dart` **part file** (invalid) at a wrong relative path, pasted FFI codegen (`@Packed`/`Struct`/`Pointer`/`Arena`/`RecordWriter`) that the nitro web stub deliberately does not provide, and called nonexistent `Type.fromJson` codecs. Now:
- imports the spec library itself (`../../<spec>.native.dart` — output layout is fixed by build.yaml), plus exactly one source of `jsonEncode`/`Uint8List` (avoiding the `package:nitro` vs `dart:convert` ambiguity),
- structs/records cross as JSON strings with **inline** field-list marshalling (no fromJson dependency),
- functions with raw `Pointer`/`NativeHandle` signatures get honest `UnsupportedError` stubs (no `@JS` external) — `Pointer.fromAddress` can never exist on web,
- benchmark package: `dart analyze lib` went from 87 issues (~50 errors) to 0.

**Remaining architectural gap (this is S6-P1/P2):** the generated file still cannot COMPILE for a real web target because the spec library's FFI `.g.dart` part references `dart:ffi` types that don't resolve on web. True web support needs the abstract class emitted into a platform-neutral library with conditional impl imports.

### S6-P1 · Web streams via JS interop ⬜

**Design:** On web there is no `Dart_PostCObject_DL`, but there is also no isolate boundary to cross — the JS impl can invoke a Dart closure directly. Generate, in `web_bridge_generator.dart`: a JS-interop subscription API (`registerXxxStream(JSFunction onItem)`), a Dart `StreamController` wired to it, and teardown on `cancel()`. Backpressure modes degrade gracefully: document that `block` is unavailable on web (single-threaded), map `bufferDrop`/`dropLatest`/`batch` onto controller-side buffering.

**Acceptance:** `Stream<primitive>` and `Stream<String>` work in a `flutter test --platform chrome` suite; W007 narrows to only the genuinely unsupported combinations.

### S6-P2 · Web `@NitroNativeAsync` → Promise fallback ⬜

**Design:** `@NitroNativeAsync` exists to skip the isolate hop — meaningless on web. Instead of throwing, generate a fallback that awaits the JS `Promise` from the web impl directly. Same Dart signature, no user code change.

**Acceptance:** A spec with `@NitroNativeAsync` functions compiles and runs on web; the annotation is a no-op optimization hint there.

### S6-P3 · Decide-and-document the intentional exclusions ⬜

L6 (`@HybridStruct` callback return), L7 (`TypedData?`), L10 (`Map<String, @HybridStruct>`) stay excluded — each has a sound ownership/ABI reason and a documented workaround. Action: promote the workarounds from LIMITATIONS.md into the user docs (`doc/`) with copy-paste examples, and make validator errors E005/E008 link to them.

---

## Sprint 7 — Performance

### S7-P1 · Struct-by-value returns for nullable primitives ⬜

**Problem:** Sync functions returning `int?`/`double?`/`bool?` transport a pointer to a `NitroOptXxx` struct (malloc on native, free on Dart). C++ returns `std::optional<T>` by value on the stack; we can match it — Dart FFI supports struct-by-value returns.

**Fix:** For sync returns only: C signature `NitroOptInt64 f(...)` instead of `NitroOptInt64* f(...)`; Dart decodes via a `.decoded` extension with zero allocation. Params and async paths keep pointers (arena / posted address). Detailed design exists in the archived plan `~/.claude/plans/velvet-chasing-hammock.md` (Parts 2–6).

**Acceptance:** Zero malloc/free in the sync nullable-prim hot path; benchmark shows the delta; all transports still round-trip on device.

### S7-P2 · Benchmark automation & regression gate ✅

**Problem:** `benchmark/` exists but results are point-in-time (F7 baseline: 1.5 µs sync call). Nothing catches a perf regression at PR time.

**Shipped (2026-07-03):**
- `benchmark/example/lib/harness/bench_harness.dart` — headless suite: raw FFI floor, Nitro leaf/checked/Swift-Kotlin, MethodChannel, string/struct/`@nitroAsync`-record latency + 16–64 MiB buffer throughput. Warmup + batch timing + median-of-K methodology.
- `integration_test/benchmark_regression_test.dart` — two-level gate: `relative` (machine-independent bridge ratios: leaf ≤ 2.5× raw FFI, checked ≤ 4×, Nitro ≥ 5× faster than MethodChannel — CI-safe) and `all` (absolute µs vs `example/assets/baselines/<platform>.json`, ±35% tolerance).
- `tool/bench.sh` + `tool/format_report.dart` — one-command run: `flutter drive --profile`, markdown table, JSON archived to `benchmark/results/`, `--update-baseline` to re-record.
- `.github/workflows/ci_benchmark.yml` — relative-gated quick suite on every push to main, results table in the job summary.
- **Bugs fixed along the way** (all found by getting the benchmark app to build under SPM — the automation doubles as an end-to-end canary):
  1. `spm_utils.dart` `_findPackageSwift` preferred the flat `macos/Package.swift` over the nested `macos/<plugin>/Package.swift` when both exist — `nitrogen link` synced bridge forwarders into a Sources/ tree Xcode never builds, and the built tree kept stale relative includes. Nested is now checked first (the only layout the Flutter tool builds).
  2. `stripSharedSwiftPreamble` assumed the shared Swift preamble always starts at `public protocol NitroEncodable` — but the preamble is emitted PIECEWISE per spec (record-only specs carry only `NitroRecordWriter`/`Reader`; nullable-prim specs add `NitroOpt*`). Two record-only bridges in one SPM target → "'NitroRecordWriter' is ambiguous". Worse, when the window's `/**` end marker sat after spec-owned declarations, the strip deleted the spec's own structs — a stale globally-activated CLI did exactly this to the benchmark plugin's synced bridges, and the committed result broke CI ("cannot find type 'PackageDimensions' in scope"). New cumulative `dedupeSharedSwiftDecls(content, alreadyDefined)` block-level dedup in `utils.dart`; ALL THREE sync sites migrated (two in `link_command.dart` + the duplicated sync in `generate_command.dart` — `_syncSwiftBridgesToClasses`/`_syncBridgesToSpmSources`); 6 new tests. `bench.sh` now regenerates + relinks before building so benchmark runs (incl. CI) never depend on committed synced files. **Follow-up:** the Swift-bridge sync logic is duplicated between `generate_command.dart` and `link_command.dart` — unify into one shared helper so a policy change can never miss a copy again.
  3. `struct_generator.dart` emitted `_XxxC.fromSwiftPtr(...)` for NESTED `@HybridStruct` fields but never generated the `fromSwiftPtr` helper — Swift bridges with nested structs never compiled. Helper now emitted alongside `fromSwift`.
  4. `cpp_direct_emitter.dart` forwarded `Pointer<Uint8>` params as `void*` to a C++ interface typed `uint8_t*` (generated-vs-generated compile error). Call sites now `static_cast` raw-pointer params to the interface's typed pointer.
  5. Benchmark package: `benchmark.native.dart` (Swift/Kotlin) redeclared `BenchmarkPoint`/`Box`/`Stats` already declared by `benchmark_cpp.native.dart` — same-named public types from two specs collide in the single plugin Swift module. Swift spec trimmed to its purpose (dispatch-tier measurement). **Follow-up (validator):** emit a warning when two specs in one package declare the same type name and any Apple platform is targeted.

### S7-P2b · Cross-platform benchmark matrix + analysis report ✅

**Shipped 2026-07-04 (extends S7-P2):**
- **Harness runs on all six targets** — cases whose bridge tier doesn't exist on a platform (`MethodChannel` handler, platform bridge) are recorded as skipped instead of crashing; core Nitro-vs-raw-FFI gates stay mandatory everywhere. Platform-bridge label reflects reality (Kotlin/JNI on Android, Swift on Apple, C++ on desktop).
- **Windows + Linux plugin support in `benchmark/`**: standard plugin scaffolds with C++ (MSVC) and GTK MethodChannel handlers speaking the same channel protocol as Kotlin/Swift; plugin CMakes build all three Nitro module libraries via `add_subdirectory(../src)` and bundle them next to the executable; `src/CMakeLists.txt` gained WIN32/UNIX link-libs; `HybridBenchmark(Cpp).cpp` auto-registration made MSVC-safe (static-object pattern) and platform-guarded (`!__ANDroid__` so the C++ registry never shadows Kotlin); `Benchmark` spec now declares `linux: LinuxNativeImpl.cpp`; example app gained windows/linux runners.
- **Analysis report** (`tool/format_report.dart`): per-tier overhead in µs, calls-per-16.7ms-frame budget, Δ-vs-baseline column + drift section, practical guidance (hot loops, bridge tax, sync-vs-async, payload bandwidth), and a cross-platform median matrix built from archived reports.
- **CI matrix** (`ci_benchmark.yml`): macOS (required) + Linux (xvfb) + Windows jobs, each publishing the analysis to the job summary; desktop jobs `continue-on-error` until proven on runners.
- iOS/Android: fully wired (channel handlers existed); profile-mode numbers require physical devices — run `tool/bench.sh -d <device-id>` and `--update-baseline` to record.
- **Verified reference workload (FNV-1a 64-bit, `hashBuffer(data, rounds)`):** implemented identically on every tier and platform — C core in `src/nitro_workload.h` shared by the raw-FFI export, both C++ Nitro impls, and the MSVC/GTK channel handlers; same algorithm in Kotlin and Swift for both the Nitro platform bridge AND the channel handler (language held constant per platform, so channel-vs-Nitro isolates pure bridge cost). Harness asserts all tiers return the bit-identical hash before timing — a disagreeing tier fails the run, making the comparison provably fair. Measured (macOS, ~21µs of real work per call): raw FFI 21.05µs · Nitro 21.3µs (+0.28µs) · MethodChannel 52.2µs (+31µs) — the channel tax grows with payload, it never amortizes. Interfaces generated by `nitrogen generate`, wiring by `nitrogen link`.

### S7-P2c · @Native<F> direct-call bindings (revive properly) ⬜

A half-shipped optimization was removed 2026-07-04: `_emitNativeBindingDeclarations` emitted top-level `@Native<F>(isLeaf: true)` declarations (`_n_<symbol>`) for leaf functions with nullable-prim params, but the call-site wiring was never implemented — the declarations were dead code (analyzer `unused_element` in every affected plugin) while method bodies used the `lookupFunction` pointers. Verified non-breaking to remove: zero call sites in any generated file repo-wide, never wired since introduction (8d384b0), 4161 generator tests + 648 device integration tests green after removal. To revive: emit declarations AND route method bodies through them on statically-linked platforms (iOS/macOS via process()), keep pointer fallback elsewhere, and benchmark the delta (@Native direct call vs pointer dispatch) before shipping.

### S7-P3 · Generator scale profiling ⬜

**Problem:** Codegen time on large specs (50–100 modules, deep record graphs) is unmeasured. The O(1) index work (S4-P2) removed known hot spots, but there's no budget.

**Fix:** Synthetic large-spec generation test with a wall-clock budget (e.g., 100 modules < 5 s); profile and fix if exceeded.

---

## Sprint 8 — Developer Experience

### S8-P1 · `nitrogen watch` ⬜

File-watcher mode: on change to any `*.native.dart` spec, re-run generate (and link when bridges change), print a compact diff of regenerated files. Pairs with hot reload for a tight native-dev loop.

### S8-P2 · Diagnostics that teach ⬜

Every `SpecValidator` error/warning (E001–E015, W001–W007) gets: a stable docs URL printed with the error, a "did you mean" suggestion where applicable (e.g., E010 unknown type → closest known type name), and a `nitrogen doctor --explain E008` mode.

### S8-P3 · Published docs site ⬜

`doc/` has getting-started, consuming, lifecycle, platforms, migration guides — but only in-repo. Publish to GitHub Pages (or docs.page): guides + dartdoc API reference + the validator error code reference (linkable from S8-P2) + LIMITATIONS as a living page.

### S8-P4 · Spec templates ⬜

`nitrogen init --template <name>` scaffolds a complete working spec + impl for common shapes: `sensor-stream` (stream + backpressure), `crypto` (TypedData zero-copy), `device-info` (sync props), `media` (async + records + callbacks). Each template is CI-tested so they never rot.

---

## Sprint 9 — Ecosystem & Adoption

### S9-P1 · First-party plugin showcase ⬜

Polish and publish the flagship plugins to pub.dev with 160/160 pana scores: `nitro_battery` (simplest possible example), `nitro_torch`, `nitro_view` (PlatformView + FFI hybrid), `nitro_camera` (the stress test: streams, GL, recording — Android preview aspect-ratio fix in progress). Each README links back to the generator docs. These are the proof that the toolchain scales from hello-world to a camera stack.

### S9-P2 · Migration guide: method channels → Nitro ⬜

`doc/migration/` exists; expand into a step-by-step with a real before/after plugin (pick a popular method-channel plugin shape), including the perf table from S7-P2. This is the highest-leverage adoption document.

### S9-P3 · Comparison positioning page ⬜

One honest page: Nitro vs method channels vs pigeon vs ffigen vs RN Nitro — feature matrix (streams, backpressure, zero-copy, desktop, codegen safety) + measured numbers. LIMITATIONS.md already has the RN Nitro half; add the Flutter-native alternatives.

---

## Tracking

| Sprint | Item | Status |
|--------|------|--------|
| 1 | P0 Split generators | ✅ |
| 1 | P3 TypeMapper abstraction | ✅ |
| 1 | P8 BridgeTypeKind enum | ✅ |
| 1 | P5 E010-E013 unknown type validation | ✅ |
| 1 | P6 BridgeSpec O(1) index | ✅ |
| 1 | P7 CodeWriter helpers | ✅ |
| 2 | P1 @NitroVariant sealed types (Dart/Swift/Kotlin) | ✅ |
| 3 | P2 Binary map encoding | ✅ |
| 4 | S4-P1 C++ variant codegen | ✅ |
| 4 | S4-P2 Complete O(1) index adoption | ✅ |
| 4 | S4-P3 Fix BridgeTypeKind for struct_/enumValue | ✅ |
| 4 | S4-P4 Split record_generator.dart (1656 lines) | ✅ |
| 4 | S4-P5 Split dart_ffi_helpers.dart (967 lines) | ✅ |
| 4 | S4-P6 @NitroResult<T> support | ✅ |
| 4 | S4-P7 jni_method_emitter.dart cleanup | ✅ |
| 5 | S5-P1 Fix failing CLI test (registerFactory assertion) | ✅ |
| 5 | S5-P2 Version single source of truth (`tool/release.dart`) | ⬜ |
| 5 | S5-P3 CI platform matrix (Linux/Windows/Android emulator) | ⬜ |
| 5 | S5-P4 Binary codec fuzz tests | ⬜ |
| 6 | S6-P1 Web streams via JS interop | ⬜ |
| 6 | S6-P2 Web @NitroNativeAsync → Promise fallback | ⬜ |
| 6 | S6-P3 Document intentional exclusions (L6/L7/L10) | ⬜ |
| 7 | S7-P1 Struct-by-value nullable-prim sync returns | ⬜ |
| 7 | S7-P2 Benchmark automation + regression gate | ✅ |
| 7 | S7-P3 Generator scale profiling | ⬜ |
| 8 | S8-P1 `nitrogen watch` | ⬜ |
| 8 | S8-P2 Diagnostics with docs links + `--explain` | ⬜ |
| 8 | S8-P3 Published docs site | ⬜ |
| 8 | S8-P4 Spec templates (`init --template`) | ⬜ |
| 9 | S9-P1 First-party plugin showcase on pub.dev | ⬜ |
| 9 | S9-P2 Method-channel → Nitro migration guide | ⬜ |
| 9 | S9-P3 Comparison positioning page | ⬜ |
