# Flutter Nitro Ecosystem — Improvement Plan

> Derived from a deep comparison with the React Native Nitro reference implementation
> at `/Users/shreemanarjunsahu/Documents/GitHub/nitro`.
> Created: 2026-06-26 · Last audited: 2026-06-26

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
    ├── dart_ffi_helpers.dart        967 lines  — all static helpers
    ├── dart_impl_class_emitter.dart 200 lines
    ├── dart_function_emitter.dart   188 lines
    ├── dart_property_emitter.dart    50 lines
    ├── dart_stream_emitter.dart      89 lines
    └── dart_map_factory_emitter.dart 76 lines
```

**Note:** The `dart_ffi_helpers.dart` part file is 967 lines — a future candidate for splitting into `dart_type_mapper.dart`, `dart_callback_helpers.dart`, etc.

**Status:** ✅ DONE — 3106 tests pass.

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

**Status:** ⚠️ PARTIAL — enum and getter exist; `struct_`/`enumValue` not resolvable without spec context.

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

**Fix needed:** Replace remaining `.any(e => e.name == x)` with `spec.isEnumName(x)` / `spec.isStructName(x)`.

**Status:** ⚠️ PARTIAL — indexes exist on BridgeSpec; not fully adopted in all generators.

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

**Status:** ⬜ TODO

---

### S4-P2 · Complete O(1) Index Adoption ⬜

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

**Status:** ⬜ TODO

---

### S4-P3 · Fix BridgeTypeKind for struct_/enumValue ⬜

**Problem:** `BridgeType.kind` returns `primitive` for both structs and enums. Generators that switch on `.kind` silently fall through for these types. This makes P8 incomplete.

**Solution options:**
1. Add `BridgeType.resolvedKind(BridgeSpec spec)` — returns `struct_` / `enumValue` when `spec.isStructName(name)` / `spec.isEnumName(name)`.
2. Alternatively, generators that already have `spec` can inline `spec.isEnumName(t.name) ? BridgeTypeKind.enumValue : t.kind`.

**Acceptance criteria:**
- `resolvedKind(spec)` returns `BridgeTypeKind.struct_` for struct types and `BridgeTypeKind.enumValue` for enum types
- At least one generator migrated to `switch (t.resolvedKind(spec))`
- All tests pass

**Status:** ⬜ TODO

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

**Status:** ⬜ TODO

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
- All 3106 tests pass

**Status:** ⬜ TODO

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

**Status:** ⬜ TODO (complex — estimate 3–4 sessions)

---

### S4-P7 · `jni_method_emitter.dart` Cleanup (1200 lines) ⬜

**Problem:** `jni_method_emitter.dart` is 1200 lines and handles JNI bridge generation for all type combinations. It has the same structural problems as the old `swift_generator.dart`.

**Note:** This is lower priority since it works correctly and is rarely touched.

**Status:** ⬜ TODO (low priority)

---

## Tracking

| Sprint | Item | Status |
|--------|------|--------|
| 1 | P0 Split generators | ✅ |
| 1 | P3 TypeMapper abstraction | ✅ |
| 1 | P8 BridgeTypeKind enum | ⚠️ PARTIAL |
| 1 | P5 E010-E013 unknown type validation | ✅ |
| 1 | P6 BridgeSpec O(1) index | ⚠️ PARTIAL |
| 1 | P7 CodeWriter helpers | ✅ |
| 2 | P1 @NitroVariant sealed types (Dart/Swift/Kotlin) | ✅ |
| 3 | P2 Binary map encoding | ✅ |
| 4 | S4-P1 C++ variant codegen | ⬜ |
| 4 | S4-P2 Complete O(1) index adoption | ⬜ |
| 4 | S4-P3 Fix BridgeTypeKind for struct_/enumValue | ⬜ |
| 4 | S4-P4 Split record_generator.dart (1656 lines) | ⬜ |
| 4 | S4-P5 Split dart_ffi_helpers.dart (967 lines) | ⬜ |
| 4 | S4-P6 @NitroResult<T> support | ⬜ |
| 4 | S4-P7 jni_method_emitter.dart cleanup | ⬜ |
