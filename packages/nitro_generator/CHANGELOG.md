## 0.5.8

Closes every `@nitroNativeAsync` gap left deferred by 0.5.7 — `Map<String,V>`/
`NitroAnyMap` params on both platforms, bare `@HybridStruct` returns on
Kotlin, and `NitroAnyMap` entirely on Swift (previously unimplemented on
*any* dispatch path, not just native-async). **No breaking changes** —
regenerate your plugin to pick these up.

- **Confirmed, not fixed**: bare `@HybridStruct` *params* on Kotlin already worked correctly with zero changes needed — the JNI bridge already delivers a fully-typed Kotlin object at the `_call` boundary for structs (unlike records/variants/enums, which arrive as raw `ByteArray`/`Long`). Added regression tests to lock this in, since it was easy to miss.
- **`Map<String,V>`/`NitroAnyMap` native-async params (Kotlin + Swift)**: ported the sync path's per-value-type decode (int/double/bool/enum/record/variant/string) into two new native-async-specific decode helpers per platform, with per-param-namespaced temp variables so multiple map params on one function don't collide. Wired into the same `_buildCallParams`/callArgs-closure substitution point 0.5.7's param fixes used.
- **Bare `@HybridStruct` native-async returns on Kotlin**: previously had no wire format at all (structs are plain Kotlin data classes at the JNI boundary, not `ByteArray`-encoded, so nothing in the generic dispatch chain applied). Added a per-struct-type `post${Struct}ToPort` JNI helper (declared only for structs actually used in a native-async return position) that reuses the existing `pack_${Struct}_from_jni` conversion — the same one the sync-return/stream/callback paths already use — and posts the malloc'd result, with the address-0-for-null convention consistent with every other pointer-backed native-async return. The Dart-side unpack for this exact wire shape (`Pointer<${Struct}Ffi>.fromAddress(...)`) already existed and needed no changes.
- **`NitroAnyMap` on Swift — new feature, not a native-async-specific fix**: `isAnyMap` was never referenced anywhere in the Swift emitter before this — no encode, no decode, on sync, `@nitroAsync`, or native-async. Added a new recursive binary codec (`_nitroEncodeAnyMapBinary`/`_nitroDecodeAnyMapBinary` + `_nitroWriteAnyValue`/`_nitroReadAnyValue`) matching the exact wire contract Dart's `NitroAnyValue` and Kotlin's `NitroAnyMapCodec` already use (tags 0–6: null/bool/int64/float64/string/list/object), and wired it into all three dispatch paths' return handling plus native-async param decode. Also fixed `SwiftTypeMapper.cdeclParamType`/`cdeclReturnType`, which had no `isAnyMap` case and fell back to the protocol-level `Any` type — not C-ABI-compatible, so any `@_cdecl` function with an AnyMap param/return wouldn't have compiled even with the codec in place. In the process, found and fixed a latent bug in the *Dart* FFI generator's native-async unpack that affected AnyMap on **both** platforms (not just this Swift work): `isAnyMap` is a separate flag from `isRecord` (spec_extractor never sets both), so `_nativeAsyncUnpack`'s `isRecord` check never matched it and any `@nitroNativeAsync` method returning `NitroAnyMap` — Kotlin included — would have thrown `type 'int' is not a subtype of type 'NitroAnyMap'` the first time it was actually called, despite generating without error. `NSNull()` is used as Swift's in-memory null marker instead of `nil`, since `dict[k] = nil` deletes the key in a `[String: Any]` dictionary rather than storing a null value (Kotlin's `Map<String, Any?>` has no equivalent gotcha).
- Covered by 3 new Kotlin unit tests, 1 new C++ bridge test, and Swift/Dart-FFI tests for the AnyMap param, return, and codec-presence assertions, all in `native_async_test.dart`.
- **Three more bugs found end-to-end building `nitro_type_coverage` for all three platforms** with this batch of fixes wired in (Android/iOS/macOS, `§68` in the example app's integration test) — none reachable from `dart test` alone, same lesson as 0.5.7's real-device pass:
  - `spec_validator.dart`'s E010 "unknown type" check excluded `isRecord`/`isPointer`/`isNativeHandle` but not `isAnyMap`, so *any* function using `NitroAnyMap` — return, param, sync or async, not just native-async — failed generation outright with `unknown return type "NitroAnyMap"`. This is likely why NitroAnyMap saw so little real usage that the Swift gap above went unnoticed for as long as it did.
  - `KotlinTypeMapper.type()` had no `isAnyMap` case (only `retType()` did), so a `NitroAnyMap` *parameter*'s interface type was the generic `Any?` fallback while the *return* type was the more precise `Map<String, Any?>` — an avoidable asymmetry now fixed to match.
  - The C++ bridge's `_typeToC` matched `Map<String,T>` by name prefix for the `uint8_t*` C parameter type but not the literal name `NitroAnyMap`, so it fell to the generic `void*` default — while a *separately*-generated header declaration for the same parameter already correctly used `uint8_t*`, producing a C++ "conflicting types" compile error the moment a real `NitroAnyMap` native-async parameter was compiled.

## 0.5.7

Callback `NativeCallable` memory-leak fix. **No breaking changes** — regenerate
your plugin (`dart run build_runner build`) to pick it up; only the
generator's output changes, plus one small runtime addition
(`NitroRuntime.deferredClose`, used internally by generated code — not
something you call directly).

- **Fixed: every callback-typed parameter leaked a `NativeCallable` on every re-registration (Android, iOS, and desktop C++)** — a callback setter (e.g. `module.onDeviceFound((event) { ... })`) cached its native callback keyed by `(paramName, closure)`; since idiomatic Flutter code almost always passes a fresh closure literal, the cache key never matched a previous entry, so a new `NativeCallable` was allocated and never released on every single call. The generated cache is now a per-`(methodName.paramName)` slot: re-registering replaces the slot and closes the previous `NativeCallable` via the new `NitroRuntime.deferredClose` runtime helper (deferred to a microtask, after native has synchronously switched to the new function pointer). The old Kotlin/JNI-only `_release_$paramName` mechanism — declared but never actually invoked by any generated code — has been removed rather than completed on Swift/direct-C++, since replace-on-reassign leaves no gap for it to fill. A new `E016` validation error rejects a callback param on a plain `@NitroAsync` method (the registering call would run on a different isolate, breaking the ordering guarantee `deferredClose` relies on); `@NitroNativeAsync` and sync methods are unaffected. Covered by rewritten `callback_release_test.dart` and updated `callback_type_test.dart` assertions.
- **`benchmark` package: added a `@nitroNativeAsync` benchmark case and a CI regression gate for both async paths** — there was previously no benchmark coverage for `@nitroNativeAsync` at all. See `nitro`'s changelog for the corrected async performance figures this surfaced.
- **Fixed: `@nitroNativeAsync` methods returning a `@HybridRecord` discarded the result and always posted null (Kotlin and Swift)** — the native-async trampoline's return-type dispatch had no record-aware branch, so it fell through to a generic path: Kotlin ran the impl inside `runBlocking`, threw the result away, and unconditionally called `postNullToPort`; Swift attempted to coerce the record struct through the generic `Int64` branch (`(try? await ...) ?? 0`), which doesn't type-check for a struct. Both platforms now encode the record through the same wire format every other record-returning path uses (`result.encode()` on Kotlin, `result.toNative()` on Swift) and post it — a new native `postBytesToPort` JNI helper mallocs a buffer for the Kotlin `ByteArray` and posts its address; Swift posts the encoded pointer directly. Nullable records post address `0` (not `Dart_CObject_kNull`) on both platforms, since the Dart-side unpack for nullable records always does an unconditional `raw as int` cast before checking for a null pointer. Covered by new fixtures/tests in `native_async_test.dart` (record and nullable-record specs, Kotlin and Swift).
- **Fixed: `@nitroNativeAsync` methods with a non-primitive parameter (enum, `@HybridRecord`/`@NitroTuple`, `@NitroVariant`, `List<T>` of any of those, or a callback) generated Kotlin/Swift that failed to compile** — the record-return fix above surfaced a wider, pre-existing gap: `@NitroNativeAsync`'s trampoline only ever decoded nullable-primitive parameters; every other parameter category was forwarded as its raw undecoded bridge value (a `ByteArray`, `Long`, or raw pointer) into a call site expecting the fully-decoded type. Kotlin now shares the same param-resolution logic (`_buildCallParams`) and decode step (`_emitParamDecodes`) the synchronous/`@nitroAsync` path already used, plus a ported nullable-enum sentinel decode. Swift now pre-decodes records/tuples/variants/structs/lists into owned local values *before* `Task.detached` starts (mirroring the existing nullable-primitive `_dec`-local pattern — the Dart arena backing these pointers is freed synchronously right after the C function returns, before the detached `Task` ever runs) and wires up callback params (`callbackWrapper`) and TypedData params (the decoded local existed but was never referenced — dead code). `Map<String,V>`/`NitroAnyMap` and bare `@HybridStruct` parameters on Kotlin remain unfixed (deferred — architecturally entangled with return-type dispatch and Kotlin's struct-param representation needs its own investigation); Swift struct params are fixed as a side effect of reusing the existing sync-path decode expression. Covered by 21 new tests in `native_async_test.dart` (one consolidated spec covering every parameter category, both generators).
- **Fixed: several more `@nitroNativeAsync` return-type categories were discarded/miscoerced, plus a regression the record-return fix itself introduced** — following up on the return-type dispatch gap above:
  - **Regression fix**: `List<@HybridEnum>` / `List<@NitroVariant>` returns on Kotlin were being routed into the record-return fix's single-record fallback, generating `result.encode()` on a Kotlin `List` (not a member — compile error). They now get their own dedicated encoders mirroring `_emitEnumListBody`/`_emitVariantListBody`.
  - **Kotlin**: bare `@NitroVariant`, `Map<String,V>`, `NitroAnyMap`, and `@NitroCustomType` returns were all discarded and always posted null (no dispatch branch existed). All four now encode via the same wire formats their sync/`@nitroAsync` counterparts use and post via `postBytesToPort`; custom types post the impl's own byte array directly (no generator-side encoding exists for them).
  - **Swift**: bare `@NitroVariant`, bare `@HybridStruct`, `Map<String,V>`, TypedData, and `@NitroCustomType` returns all fell to the generic `(try? await ...) ?? 0` coercion, which doesn't type-check against a non-`Int64`-convertible Swift value (compile failure). All five now encode via their sync-path equivalents and post the resulting pointer as `kInt64` (mirroring the record-return fix's convention: a thrown/absent result posts address `0`, never `Dart_CObject_kNull`). `NitroAnyMap` return is deliberately **not** fixed on Swift — it has no working return-encode path anywhere in the Swift emitter (sync or `@nitroAsync` either), a pre-existing bug unrelated to native-async and out of scope here.
  - **Swift silent bugs** (compiled fine before, but wrong at runtime): `uint64?` returns collapsed a thrown/nil result to `0` via the generic fallback, indistinguishable from an actual `0` value — now uses the same pointer-encode approach as `int?`/`double?`/`DateTime?`. Nullable `AnyNativeObject` returns used `0` instead of the `-1` "no value" sentinel every other `AnyNativeObject` path (params, sync return) already uses.
  - Kotlin struct returns and `Map`/`AnyMap`/struct *parameters* remain open gaps — see the param-fix entry above and the generator's `native_async_test.dart` for what's covered.
  - Covered by 12 new tests in `native_async_test.dart` (one consolidated returns spec, both generators).
- **Fixed three more `@nitroNativeAsync` bugs, found by building and running the fixes above end-to-end** (Android/iOS/macOS) **in a real plugin (`nitro_type_coverage`) rather than only asserting generator-output strings** — the C++/JNI bridge and Dart FFI generator layers had never been exercised for these categories at all:
  - **C++/JNI signature builder crashed the generator outright** for any variant or custom-type native-async param (`Bad state: Unknown JNI signature type "TcEvent"`) — `_jniNativeAsyncSig` never threaded `variantNames`/`customTypeNames` through to `_jniParamSig` (its sync-path counterpart, `_jniSig`, already did). Worse than the Kotlin/Swift gaps above, which at least produced *something*.
  - **C++/JNI per-param marshaling for native-async never learned records, variants, custom types, `NativeHandle`, `AnyNativeObject`, or callbacks** — only `String`/struct/TypedData/`Map`/nullable-prim params were converted to their JNI-expected shape; everything else (including the enum C-parameter *declaration*, which needs `int64_t` not `void*`) was forwarded as a raw pointer/`void*` where the JNI method signature expected a `jbyteArray` or `int64_t`. Ported the exact conversions `_emitJniRegularFuncBody` (the sync/`@nitroAsync` path) already had for these categories.
  - **Dart FFI generator, param side**: a nullable enum native-async parameter was passed as the raw enum object instead of `.nativeValue`/`-1` — the native-async-only `plainCallArgs` helper (a duplicate of the correct arena-based `callArgs` logic) checked `spec.isEnumName(t)` without stripping the type's `?` suffix first, so it silently never matched and fell through to a raw passthrough.
  - **Dart FFI generator, return side**: bare `@NitroVariant` and `uint64?` native-async returns had no `unpack` branch — `raw` (the posted pointer address / packed-struct pointer) was cast directly to the wrong Dart type instead of being decoded. Variant crashed outright (`type 'int' is not a subtype of type 'TcEvent'`); `uint64?` was worse — it silently "succeeded" (since `uint64?` is `int?` under the hood) but returned the raw pointer address as if it were the decoded value.
  - Covered by 11 new tests in `native_async_test.dart` (`CppBridgeGenerator` and `DartFfiGenerator` groups) plus a new `§67` integration-test section in `nitro_type_coverage`'s example app, run and passing on Android, iOS, and macOS.

## 0.5.6

Android zero-copy memory-leak fix. **No breaking changes** — regenerate your
plugin (`dart run build_runner build`) to pick it up; the runtime packages are
unchanged.

- **Fixed: JNI global-reference leak on every zero-copy stream event (Android/Kotlin backends)** — for `@HybridStruct(zeroCopy: [...])` structs delivered through a `@NitroStream`, the generated C++ bridge pinned the backing Kotlin object with `NewGlobalRef` (stored in `g_zero_copy_refs`) so the borrowed buffer stays alive while Dart reads it — but the generated struct release function only `free()`d the C struct and never deleted the global ref. ART's global-reference table (51,200 slots) fills at the stream's frame rate and the process **aborts with `global reference table overflow` after ~25 minutes** of continuous streaming (measured with a 30 fps camera frame stream). The bridge now emits a `<libStem>_zero_copy_release` helper (declared in the JNI prologue) that erases the pinned ref, and the struct release function calls it before freeing. Covered by new `cpp_bridge_generator_test.dart` / `proxy_generation_test.dart` cases asserting the release path deletes the ref exactly once.

## 0.5.5

Desktop C++ (`NativeImpl.cpp` on Windows/Linux) repair release. The desktop
path had never been compiled end-to-end; wiring the full `nitro_type_coverage`
suite through it (with CI) surfaced and fixed the following. **No breaking
changes for published users** — the Kotlin, Swift, JNI, and Dart outputs are
byte-identical (modulo source-line comments); only the desktop C++ artifacts
(`*.native.g.h`, the desktop dispatch in `bridge.g.cpp`, `*.impl.g.cpp`)
changed, and no shipped plugin has a non-stub desktop implementation.

- **Fixed: `@NitroVariant` C++ decoder emitted invalid C++** — `auto x = *reinterpret_cast<...>(ptr), ptr += 8;` does not parse. The codec is rewritten on `NitroRecordReader`/`NitroRecordWriter`, now wire-correct for nullable fields (presence flags), enum fields (Dart `enum.index` — per-enum `nitro_<Enum>_fromIndex/toIndex` helpers are generated), inline record fields, `List<T>` fields, and TypedData fields. `nitro_encode_<V>` is now writer-based, with a `nitro_<V>_to_native` convenience for method returns.
- **Fixed: header/bridge/starter type-mapping drift** — `*.native.g.h`, the desktop dispatch, and `*.impl.g.cpp` were generated from three separate, diverged type mappings (mismatched `emit_*` signatures, raw function pointers vs `std::function`, `void*` vs typed buffers). All C++ artifacts now share `CppInterfaceGenerator`'s public type helpers.
- **Fixed: nullable property getters could not represent null** — `double?` getters returned plain `double`; they now return `std::optional<T>` end-to-end (getter, setter, dispatch encode).
- **Fixed: stream emitters posting `kNull` instead of values** — String, uint64, and all nullable-item streams now post real values (`kString`, `kInt64`, `kDouble`) with `kNull` reserved for `std::nullopt`. Record/variant `emit_*` now take non-owning payload views and the bridge copies into a malloc'd length-prefixed block. Batch streams post the `[count, items…]` kArray shape Dart expects.
- **Fixed: desktop dispatch gaps** — nullable String/enum/struct params and returns (previously crashed on null or failed to compile), `DateTime?`/`uint64?` NitroOpt handling, `Map<String, T>` ABI mismatch (`uint8_t*` vs `void*`), variant returns, `@NitroResult` blob encoding (`[1B tag][4B len][payload]`, impl signals errors by throwing), and `@NitroNativeAsync` nullable-primitive parameter decoding.
- **Fixed: callback ABI wrapping** — the desktop dispatch now adapts raw Dart `NativeCallable` function pointers (everything routed through Int64 registers: double bits, bool 0/1, flattened structs, malloc'd variant blobs, malloc'd Utf8 returns) into clean impl-facing `std::function` signatures (`std::function<std::string(int64_t)>`, `std::function<void(const TcPoint&)>`, …).
- **Fixed: struct-in-record C++ decode** — `@HybridStruct` fields inside records called a non-existent `T::fromReader` on plain C typedefs; free-function codecs (`nitro_<Struct>_fromReader/encodeInto`) are now generated.
- **Added: C++ record encoders** — every generated record struct now has `encodeInto(NitroRecordWriter&)` and `toNativeBuffer()` (mirroring `fromReader`/`fromNative`), so desktop impls can construct records without hand-rolling the wire format. `NitroNullableInt/Double/Bool` C++ structs are now emitted (they exist as library types on other platforms but had no C++ definition). Record structs are emitted in dependency order (by-value embedding compiles).
- **Added: `NitroRecordReader.readInt8` / `NitroRecordWriter.writeInt8/writeBytes/toNativeBuffer`** — required by the variant codec and blob helpers.
- **Fixed: `uint64`/`DateTime` mapped to `void*` in the C++ interface** — now `uint64_t` and `int64_t` (ms-epoch) respectively.
- **Changed (cosmetic, no behavior change): instance-key Utf8 pointer now allocated and freed with `calloc`** instead of `malloc` — `_instanceKey.toNativeUtf8(allocator: calloc)` + `calloc.free(_keyPtr)`. Note for anyone auditing this: `package:ffi`'s `malloc.free`/`calloc.free` both resolve to the same OS-level free (`CoTaskMemFree` on Windows, `free()` elsewhere) regardless of which allocator produced the pointer, so the prior `malloc`/`malloc.free` pairing was never a bug — this is a style-only change (zero-initialized allocation as defense in depth).

## 0.5.4

- **Fixed: `cpp_record_generator.dart` — library record types excluded from C++ forward declarations** — Types in `_nitroLibraryRecordTypes` (`NitroOptInt64`, `NitroOptFloat64`, `NitroOptBool`, `NitroNullableInt`, `NitroNullableDouble`, `NitroNullableBool`) are now filtered out before generating C++ struct forward declarations and definitions. These types are provided as C anonymous typedefs in the generated `bridge.g.h`; re-declaring them as named C++ structs caused a compilation error in multi-spec plugins.
- **Fixed: `swift_record_generator.dart` — library record types skipped in `NativeImpl.cpp` bridges** — When `emitBoilerplate: false` (cpp module bridge path), library record type struct definitions are now omitted. This prevents `NitroNullableInt` and similar types from being defined twice in the same Swift SPM module when a plugin contains both a Swift-backed and a C++-backed spec.
- **Fixed: `cpp_direct_emitter.dart` — Meyers' Singleton prevents static initialization order fiasco** — All C++ registry globals (`g_instances`, `g_instances_mtx`, `g_next_instance_id`, `g_factory`) are now generated as function-local statics accessed via wrapper functions. This guarantees thread-safe initialization before first use, preventing the SIOF crash (`std::__next_prime` abort) that occurred when `__attribute__((constructor))` callbacks fired before the globals were initialized.

## 0.5.3

- **Ecosystem sync** — Aligned with `nitrogen_cli` 0.5.3.

## 0.5.2

- **Ecosystem sync** — Aligned with `nitrogen_cli` 0.5.2.

## 0.5.1

- **New: Generator structural invariant tests for multi-spec Swift deduplication** — `swift_bridge_dedup_invariants_test.dart` (15 tests) verifies that generated Swift bridge files always conform to the structural contract relied upon by `nitrogen_cli`'s `stripSharedSwiftPreamble`: `NitroEncodable` is always emitted, it precedes the `/**` doc-comment that marks the spec-specific boundary, the declaration is unindented (so `line.startsWith(...)` matching works), and the preamble is correctly stripped across 2- and 3-spec plugins.
- **Ecosystem sync** — Aligned with `nitrogen_cli` 0.5.1.

## 0.5.0

- **Fixed: Nullable callback return types silently stripped of `?`** — `spec_extractor.dart` called `returnType.getDisplayString(withNullability: false)` for function (callback) types, silently dropping `?` from nullable return types. This caused three downstream bugs: (1) the generated helper accepted `T Function()` instead of `T? Function()`, producing a type mismatch at the call site; (2) `isNullableRet` was always `false` in `_callbackExceptionalReturn`, so all nullable callback returns used the wrong exceptional-return sentinel (e.g. `0` instead of `-1` for `AnyNativeObject?`); (3) `_callbackReturnExpression` never generated the null-guard wrapper for nullable returns, causing a `Null check operator used on a null value` crash at runtime. Fixed by changing to `getDisplayString()` (nullability preserved).
- **Fixed: Unused local variable `isNullable` warnings** — Removed dead `isNullable` variable declarations in `dart_callback_helpers.dart` (two sites) and `kotlin_callback_emitter.dart` where the variable was computed but never read (the `isNullableNitroPrim` check on the `BridgeType` was used directly instead).
- **Fixed: Local variable lint `no_leading_underscores_for_local_identifiers`** — Renamed `_isOptPrim` → `isOptPrim` and `_isOptPrimNA` → `isOptPrimNA` in `kotlin_function_emitter.dart`.
- **Fixed: Unnecessary string interpolation braces lint** — `'(${fieldTypes})'` → `'($fieldTypes)'` in `dart_record_generator.dart`.
- **Fixed: Unused/redundant imports in test** — Removed shadowed `bridge_spec.dart` import and unused `cpp_bridge_generator.dart` import from `tuple_type_test.dart`.

## 0.4.6

- **New Annotations** — Added generation support for `@NitroVariant`, `@NitroResult`, `@nitroNativeAsync`, `@zeroCopy`, and `@NitroOwned`.

## 0.4.5

- **Fixed: `@NitroOwned` Swift bridge emits `return nil` instead of `return ()`** — `_emitSyncBody` in `swift_function_emitter.dart` now checks `isNativeHandle` before the `isVoid` branch. Previously a `NativeHandle<T>`-returning function fell through to the `void` default and emitted `return ()`, causing a compile-time type error (`cannot convert '()' to 'UnsafeMutableRawPointer'`).
- **Fixed: `@NitroOwned` `_release` symbol compiled on all platforms** — The generated `${lib}_${method}_release` C function is now emitted in the **global section** of `.bridge.g.cpp` (before any `#ifdef __ANDROID__` / `#elif __APPLE__` platform guard). Previously it was inside the Apple-only block, so Android builds failed with `undefined symbol: …_release`. The function body uses an inner `#ifdef __ANDROID__` guard: no-op on Android (Kotlin handle is a `jlong`), `free(handle)` on Apple (Swift allocates via `UnsafeMutableRawPointer.allocate`).
- **Fixed: `@NitroVariant` Swift protocol uses concrete type, not `Any`** — `swift_protocol_registry_emitter.dart` now resolves variant parameter and return types to their concrete Swift enum name via `SwiftTypeMapper._variantNames`, so generated protocols carry `TcEvent` instead of `Any`. The `swift_type_mapper.dart` O(1) lookup set was also extended to cover all registered variant types.
- **Fixed: `@NitroResult` Swift protocol generates `throws -> T`** — Methods annotated with `@NitroResult` now emit a throwing Swift protocol signature (`throws -> InnerType`) rather than returning the raw `NitroResultValue` buffer. The `swift_variant_emitter.dart` extracts the inner type parameter and strips the `NitroResultValue<…>` wrapper for the protocol declaration.
- **Fixed: Duplicate `_release` removed from `swift_shim_emitter.dart`** — The now-redundant Apple-only `_release` emission that was previously added to `_emitSwiftBridgeSection` has been removed to avoid a duplicate-symbol linker error when building for Apple targets.
- **Added: Generator tests for `@NitroVariant`, `@NitroOwned`, and `@NitroResult`** — `nitro_variant_test.dart` gains 9 new test cases covering: concrete variant type in protocol, `@NitroResult` `throws` signature, `@NitroOwned` `return nil` guard, `_release` symbol name/placement/platform guard, and `BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true)` fixture (corrected from the erroneous `name: 'void'`).

## 0.4.4

- **Fixed: `List<@HybridStruct T>` return type wire format mismatch on iOS/macOS** — The Swift bridge now calls `NitroRecordWriter.encodeIndexedList` instead of `encodeList` for struct-list return values. The Dart `LazyRecordList.decode` expects the indexed format (`[int32 count][int64×n offsets][item bytes...]`); the old sequential format caused it to interpret item bytes as offset values, producing a `RangeError: Value not in range` at runtime when accessing any element.
- **Added: `NitroRecordWriter.encodeIndexedList` in the Swift codec template** — `record_generator.dart` now includes `encodeIndexedList` alongside `encodeList` in the `_swiftRecordWriterReader` constant, so every freshly generated Swift bridge has the method available without needing a manual patch.
- **Fixed: Swift generator emits correct call site for struct-list returns** — Both the sync and async `isRecordList` paths in `swift_generator.dart` now emit `encodeIndexedList` for `@HybridStruct`-element lists. Primitive-element lists (`List<int>`, `List<String>`, etc.) continue to use `encodeList` unchanged, since those are decoded by `RecordReader.decodePrimitiveList` (sequential format).
- **Tests: Updated 4 test assertions** — `struct_list_test.dart` (2) and `all_generators_type_coverage_test.dart` (2) updated from `encodeList` to `encodeIndexedList` for struct-list Swift output expectations.

## 0.4.3

- **Fixed: Optional primitive parameters (`int?`, `double?`, `bool?`) across the FFI bridge** — Dart now encodes `null` as a sentinel value (`-1` for `int?`/`bool?`, `NaN` for `double?`) when calling the C bridge, and Kotlin decodes those sentinels back to `null` before forwarding to your implementation. Previously, passing `null` for an optional primitive caused a JVM method descriptor mismatch crash at runtime.
- **Fixed: Nullable struct parameters in JNI bridges** — Null-checks are now emitted before calling `unpack_*_to_jni`, so passing a `null` struct reference no longer causes a segfault.
- **Fixed: Non-zero-copy `TypedData` fields in struct JNI bridges** — Non-ZC typed-data struct fields (e.g. `Uint8List` without `zeroCopy`) now correctly allocate a malloc'd C buffer from the Java array on unpack, and create a Java array from the C buffer on pack, with proper `DeleteLocalRef` cleanup.
- **Fixed: Type-only spec files generate correctly** — Specs that only declare enums/structs (no class bridge) now early-return and produce only type declarations instead of an empty or broken bridge file.
- **Fixed: Enum and record JVM method descriptors** — JNI method descriptor builder now emits `J` for enum params and `[B` for record params, matching what the JVM expects.
- **Fixed: Nullable type stripping in JNI descriptors** — `?` is stripped from type names before struct/enum descriptor lookup so `Point?` maps to the correct `L.../Point;` descriptor.
- **Fixed: Named parameters with default values in Dart FFI signature** — Generated bridge function signatures now include the default literal (e.g. `int copies = 1`) so callers can omit them.
- **Fixed: `StateError` on non-optional null struct/record returns** — A `StateError` is now thrown immediately when a native call returns `nullptr` for a non-nullable struct or record return type, instead of crashing later with a null-dereference.
- **Fixed: Cross-file type includes in C++ header** — When a spec references types from other `.native.dart` files, the generated header now emits the corresponding `#include` directives.
- **New: `specTest` testing API** — New `test/spec_tester.dart` and `test/spec_from_source.dart` helpers let you test any generator against an inline source string in one `specTest(...)` call — no `build_runner` or on-disk spec file needed. Supports per-language checks (`has`, `hasNot`, `before` ordering), `all:` cross-language assertions, `skip:`, and `debugPrint:`.
- **Tests: 65 new edge-case tests** — `spec_tester_test.dart` covers parsing defaults, annotation args, function kinds, parameters, sentinel encoding, properties, streams, enums, structs, error cases, and the specTest harness itself.

## 0.4.2

- **Fixed: Nullable return types in Swift bridge** — `spec_extractor.dart` `_makeBridgeType` now reads `type.nullabilitySuffix == NullabilitySuffix.question` and propagates `isNullable: true` into every returned `BridgeType`. Previously `isNullable` was always `false` for function return types, so methods like `int? maxLevel()` silently generated `return impl.maxLevel()` (invalid Swift — `Int64?` not assignable to `Int64`).
- **Fixed: Swift `@_cdecl` stubs for every nullable return kind** — `swift_generator.dart` now emits correct fallback code for all nullable return types: `int?` → `?? 0`, `double?` → `?? 0.0`, `bool?` → `?? false` then ternary `? 1 : 0`, `String?` → `strdup("") ??` guard, `Enum?` → `?.rawValue ?? 0`, `Struct?` → double-guard pattern (`guard let impl = …, let result = impl.method() else { return nil }`) with bare struct name in `UnsafeMutablePointer`, `Record?` → explicit impl guard + `?.toNative()`.
- **Fixed: Nullable type name stripping for `isString`/`isStruct`/`isRecord` detection** — Strip trailing `?` before matching against type names so nullable return types (e.g., `Point?`, `Reading?`) are routed to the correct generator branch.
- **Fixed: `knownTypeNames` propagation to `_extractFunctions` and `_extractPropertiesAndStreams`** — Struct and enum names are now included in the `knownTypeNames` set passed to `_makeBridgeType`, enabling correct type classification for user-defined return types.
- **Fixed: Swift typed-data pointer conversion** — Replaced the broken `!= nil ? param! …` pattern with the correct `.map { … } ?? fallback` idiom for `UnsafeBufferPointer` typed-data parameters.
- **Fixed: Dart FFI nullable `String?` parameter** — Added `!` null assertion in `toNativeUtf8` call for nullable String params so the generated code compiles correctly.
- **Fixed: JNI bridge class local-ref leak** — `cpp_bridge_generator.dart` `initialize()` now calls `env->DeleteLocalRef(localClass)` after `NewGlobalRef`, preventing a local reference from accumulating in the JNI frame on every re-initialization.
- **Tests: 10 new nullable return type tests** — `swift_generator_test.dart` covers `int?`, `double?`, `bool?`, `String?`, `Enum?`, `Struct?` (nullable + non-nullable), and `Record?` (nullable + non-nullable) return paths.
- **Ecosystem sync** — Aligned with `nitro`, `nitro_annotations`, and `nitrogen_cli` 0.4.2.

## 0.4.1

- **Fixed: Struct size calculation** — `@HybridStruct` field sizes are now computed correctly for nested struct types and aligned to pointer boundaries, preventing silent memory corruption when structs are passed across the FFI boundary.
- **Fixed: Optional parameter support** — Methods with optional positional or named parameters now generate correct Dart FFI signatures and C++ bridge stubs; previously optional params were treated as required, causing compile errors.
- **Fixed: C++ bridge release-mode compilation** — Generated `*.bridge.g.cpp` and `*.bridge.g.h` now include the `NITRO_EXPORT` macro from `nitro.h` unconditionally, fixing linker errors when building in release/archive mode with LTO.
- **Fixed: Mixed Apple platform linking** — Generated C++ bridges now emit correct per-platform `#if TARGET_OS_OSX` / `#else` guards for modules that use different implementation languages on iOS vs macOS (e.g. `ios: NativeImpl.swift` + `macos: NativeImpl.cpp`). Swift protocol generation handles mixed targets without emitting a `HybridXxxProtocol` for the wrong platform.
- **Fixed: Android stabilization** — C++ bridge generator no longer emits duplicate `JNI_OnLoad` registrations on multi-module builds; `build.yaml` input exclusions prevent stale outputs from prior runs.
- **Fixed: Generated code lint** — `_initSw` renamed to `initSw` in the generated Dart FFI impl constructor; eliminates the `no_leading_underscores_for_local_identifiers` warning in every generated `.g.dart` file.
- **Ecosystem sync** — Aligned with `nitro`, `nitro_annotations`, and `nitrogen_cli` 0.4.1.

## 0.4.0

- **New: Mixed Apple platform implementation targets** — A single module can now use different implementation languages per Apple platform. For example, `macos: NativeImpl.cpp` with `ios: NativeImpl.swift` generates a single bridge with `#if TARGET_OS_OSX` / `#else` guards — no manual patching required. Supports all combinations: both Swift, both C++, or mixed.
- **Fixed: Swift `@nitroNativeAsync` protocol signature** — Methods annotated with `@nitroNativeAsync` now correctly declare `async throws` in the generated `HybridXxxProtocol`.
- **SPM and CocoaPods support** — Generated C++ bridges compile correctly under both Swift Package Manager (`.mm` forwarder via `nitrogen link`) and CocoaPods (`ios/Classes/` and `macos/Classes/` forwarders).
- **Ecosystem sync** — Aligned with `nitro`, `nitro_annotations`, and `nitrogen_cli` 0.4.0.

## 0.3.3

- **Fixed: JNI crash (ART abort) with nested `@HybridStruct` fields** — `GetFieldID` was called with `"Ljava/lang/Object;"` for nested struct fields, posting a `NoSuchFieldError` that ART turned into a fatal runtime abort on the next JNI call. Fixed by generating the correct class descriptor (e.g. `Lnitro/nitro_ar_module/Vector3;`) in the constructor signature, `GetFieldID` calls, `pack_*_from_jni`, `unpack_*_to_jni`, and the release function. Both the already-generated file and the generator itself were fixed to prevent regression.
- **New: `@HybridStruct` types usable as `@HybridRecord` list fields** — `@HybridRecord() class PackageBoxes { final List<BoundingBox> boxes; }` now serializes correctly end-to-end.
  - `spec_extractor.dart`: `_recordFieldKind` now recognises `@HybridStruct`-annotated types, classifying `List<BoundingBox>` as `listRecordObject` (not `listPrimitive`).
  - `struct_generator.dart` `generateKotlin`: Every Kotlin `data class` for a struct now includes `companion object { decodeFrom(buf) / decode(bytes) }`, `writeFieldsTo(out, buf)`, and `encode(): ByteArray` so structs can be embedded inline in record binary payloads.
  - `record_generator.dart` `generateDartExtensions`: Auto-generates `RecordExt` extensions (with `fromNative`, `fromReader`, `writeFields`, `toNative`) for every `@HybridStruct` type referenced in a record field, including transitive closure for nested struct types.
- **Fixed: Kotlin record list field wire format** — The `writeIndexedList` helper (which discarded list items via `{ _ ->}` and referenced an undefined `it`) has been replaced with a simple `writeInt32(size) + forEach { e -> e.writeFieldsTo(out, buf) }`. The corresponding Kotlin read no longer skips a phantom offset table; both sides now use the same count-then-items format as the Dart codec.
- **Tests: 50 new tests in `struct_in_record_test.dart`** — Cover: Dart `RecordExt` for struct list items, Kotlin struct codec methods, Kotlin record using struct codecs, transitive nested-struct closure, `recordObject` (non-list) struct fields, all primitive field types, wire-format consistency, and negative cases (unreferenced structs produce no `RecordExt`).


## 0.3.2

- **Fixed: Nested struct fields generate typed pointers** — Fields whose type is another `@HybridStruct` now use `Pointer<NestedFfi>` instead of `Pointer<Void>`. `toDart()`, `toNative()`, `freeFields()`, and proxy lazy getters all handle nested pointers correctly.
- **Fixed: Proxy `super()` for nested struct fields** — Zero-value defaults are now generated recursively (e.g. `Vector3(x: 0.0, y: 0.0, z: 0.0)`) instead of `null`, which was invalid for non-nullable types.
- **New: Positional constructor param support** — `BridgeField` gains `isNamed` and `isRequired` flags. The generator emits positional args before named args in `toDart()` and proxy `super()`, matching the struct's actual constructor signature. The spec extractor reads these flags automatically.
- **Fixed: TypedData length-field matching is case-sensitive** — Only exact lowercase names (`length`, `size`, `stride`, `bytelength`, `bytelen`, `len`) match. A field named `Stride` (capital S) now correctly falls back to `asTypedList(0)`.
- **Tests: 135 new tests across 3 files** — `nested_struct_test.dart`, `struct_constructor_params_test.dart`, and `struct_field_types_test.dart` cover nested structs, all constructor styles, String/enum/TypedData fields, `freeFields()` combinations, zeroCopy, nullable stripping, and more.

## 0.3.1
- **New: macOS targeting in `BridgeSpec`** — `BridgeSpec` now accepts an optional `macosImpl` field (`NativeImpl?`) and exposes `targetsMacos` and `targetsAppleCpp` getters. `targetsAppleCpp` is true when either `ios` or `macos` (or both) use `NativeImpl.cpp`, enabling a single `#ifdef __APPLE__` guard in the C++ bridge instead of separate iOS/macOS guards.
- **New: `INVALID_MACOS_IMPL` validator error** — `SpecValidator` emits an error with code `INVALID_MACOS_IMPL` and severity `error` when `macos: NativeImpl.kotlin` is specified, since Kotlin is not a valid native language on macOS.
- **Improved: `isCppImpl` getter** — Updated to account for `macosImpl`; a spec is considered cpp-only when all specified platforms use `NativeImpl.cpp`.
- **Improved: `CppBridgeGenerator` platform guard** — The Apple-platform `#ifdef` block now uses `__APPLE__` (covers both iOS and macOS) instead of `__APPLE__ && TARGET_OS_IOS`, so generated C++ bridges compile correctly in both iOS and macOS targets.
- **New: Edge-case tests in `spec_validator_expansion_test.dart`** — 5 new cyclic struct detection edge cases: struct with no fields, struct with only primitive fields, two independent mutual cycles (each reported exactly once), four-struct transitive cycle, and a struct referencing a primitive type (not treated as cycle).
- **Fixed: stale `DeleteLocalRef` test assertions** — `cpp_bridge_generator_test.dart` and `edge_cases_test.dart` expected explicit `env->DeleteLocalRef(j_param)` calls that are no longer emitted; the generator now wraps every JNI call in `PushLocalFrame(16)` / `PopLocalFrame(nullptr)` which frees all local refs automatically. Tests updated to assert the `PushLocalFrame`/`PopLocalFrame` pattern and guard against regressing to manual `DeleteLocalRef`.
- **Fixed: record-return exception-ordering test snippet size** — the 400-char substring was too small to contain `GetByteArrayRegion` after the extra `PopLocalFrame` error paths were added; extended to 700 chars and added presence guards for both substrings.
- **New: Zero-copy proxy streaming** — `StructGenerator.generateDartProxies` now emits `final class ${Name}Proxy extends ${Name} implements Finalizable`. Every getter is `@override` and reads lazily from a `Pointer<${Name}Ffi>`; super fields are zeroed and never read. Because `Proxy <: ValueType`, `Stream<Proxy>` satisfies `Stream<Value>` via Dart covariant generics — no `.map()` or API change required.
- **New: Generated C release symbols** — `CppBridgeGenerator` emits a `void ${lib}_release_${Struct}(void* ptr)` function for every `@HybridStruct` inside `extern "C"` blocks on both the direct-C++ and JNI+Swift paths.
- **New: `NativeFinalizer` with generated release symbol** — Each proxy's `static NativeFinalizer? _finalizer` is lazily bound to `dylib.lookup('${lib}_release_${Struct}')` via an idempotent `static void _init(DynamicLibrary dylib)`. The impl constructor calls `${Name}Proxy._init(_dylib)` for each struct.
- **New: `isLeaf: true` on sync primitive bindings** — All synchronous FFI bindings with primitive-only return types (including read/write property accessors) are emitted with `.asFunction<...>(isLeaf: true)`, skipping the Dart VM safepoint transition.
- **New: Indexed `@HybridRecord` list encoding** — `DartFfiGenerator` encodes list record params with `RecordWriter.encodeIndexedList` and decodes list record returns with `LazyRecordList.decode`. Kotlin and Swift encode with a `writeIndexedList` helper; the decode path skips the offset table.
- **New: `_superDefault` helper in `StructGenerator`** — Returns a safe zero-value Dart literal for each field type so the proxy's `super(...)` call compiles without touching native data.
- **Breaking fix: struct stream override type** — Generated struct stream overrides now emit `Stream<${ValueType}>` (matching the spec) while using `openStream<${Proxy}>` internally. Previously the impl emitted `Stream<${Proxy}>` which was an invalid override.
- **Fixed: missing struct release symbols on Android** — Struct release functions (used by Dart's `NativeFinalizer`) were previously incorrectly guarded by platform preprocessor blocks in `CppBridgeGenerator`, causing them to be missing from Android builds. They are now generated in a common `extern "C"` block for all platforms.
- **Fixed: memory leaks in struct return paths** — Implemented deep release of heap-allocated native fields (e.g., native strings `char*` allocated via `strdup`) in the struct release functions.
- **Fixed: struct property getter leaks** — Updated the Dart FFI generator to correctly convert and deeply release struct properties, matching the safety logic used for method returns.
- **Fixed: struct release exports in C++ header** — `CppHeaderGenerator` now includes `NITRO_EXPORT` declarations for all struct release functions, ensuring they are correctly exported and visible to the Dart FFI layer.
- **New: `freeFields()` for FFI structs** — Generated FFI struct extensions now include a `freeFields()` method to safely release internal native resources.
- **Improved: memory safety in `toDart()`** — Struct conversion now performs an eager copy of `TypedData` fields (using `Uint8List.fromList`), preventing use-after-free errors when the native buffer is quickly released.
- **Improved: cleaner bridge code** — Struct release functions are now coalesced into a single `extern "C"` block in the generated bridge C++ source.
- **Tests: regression coverage for struct release** — Added unit tests to `cpp_header_generator_test.dart`, `cpp_bridge_generator_test.dart`, and `dart_ffi_generator_test.dart` to verify memory safety and correct symbol generation across all layers.

## 0.3.0

- **New: Direct C++ Implementation support** — Generator produces `*.native.g.h`, `*.mock.g.h`, and `*.test.g.cpp` when `@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)` is specified.
- **New: Thread-safe bridge** — `CppBridgeGenerator` uses `std::atomic` for `g_impl` and stream port storage; `CppBridgeGenerator` now uses direct virtual dispatch with no platform `#ifdef` blocks.
- **New: `std::optional<T>` for nullable types** — `CppInterfaceGenerator` emits nullable Dart types as `std::optional<T>`.
- **New: Precise `Pointer<T>` C++ mapping** — `Pointer<SomeEnum>` → `SomeEnum*`, `Pointer<SomeStruct>` → `SomeStruct*`, `Pointer<Void>` → `void*`.
- **New: `#ifndef` struct guards** — `generateCStructs` wraps each C struct in an include guard to prevent `typedef redefinition` errors in CocoaPods umbrella builds.
- **New: `BridgeSpec.isCppImpl`** — convenience getter for detecting pure-C++ modules.
- **Improved: FFI memory safety** — `DartFfiGenerator` emits `try { ... } finally { malloc.free(...); }` for all record/struct return paths.
- **Improved: `checkDisposed()` guards** — Added to all generated methods including `Fast` (leaf) functions; annotated `@pragma('vm:prefer-inline')`.
- **Fixed: Builder diagnostics** — `builder.printWarning` now shows actual file paths instead of literal placeholders.

- **New: Single-platform targeting** — `@NitroModule` now accepts optional `ios` and `android` parameters. A module can target iOS only, Android only, or both. Generators skip output for untargeted platforms.
- **New: `BridgeSpec.targetsIos` / `targetsAndroid`** — convenience getters derived from nullable `iosImpl`/`androidImpl`.
- **New: `NO_TARGET_PLATFORM` validation error** — `SpecValidator` emits an error when neither `ios` nor `android` is specified.
- **Improved: `BridgeSpec.isCppImpl`** — correctly handles single-platform C++ specs (`ios: NativeImpl.cpp` with `android` omitted, and vice versa).
- **Improved: `SwiftGenerator`** — returns a placeholder comment when iOS is not targeted instead of generating an empty/broken file.
- **Improved: `KotlinGenerator`** — returns a placeholder comment when Android is not targeted.
- **Improved: `CppBridgeGenerator`** — omits `#ifdef __ANDROID__` / `#elif __APPLE__` / `#endif` platform guards for single-platform specs; routes to the appropriate single-platform code path.
- **Tests: 72 new tests** — platform targeting unit tests, single-platform generator output, `isCppImpl` edge cases, additional validator rules, JNI parameter handling, CMake variable indirection, C++ mock and interface edge cases.
- **Tests: 100+ new regression tests** — Benchmark spec tests, `Pointer<T>` param/return tests, nullable type tests, and stream backpressure isolation tests across all generators.

## 0.2.3

- **Fix: Array<UInt8> to Data mismatch in Swift** — Updated the Swift generator to correctly bridge `Uint8List` parameters as `Data` when matching native Swift signatures, ensuring type-safe binary data transfer without manual casts.
- **Improved: Header Generator** — The generated C++ bridge headers now automatically include `nitro.h`.
- **Improved: Dependency Sync**: Synchronized the Nitro ecosystem to version 0.2.3.

## 0.2.2

- **Fix: stable annotation resolution** — updated `SpecExtractor` to use `TypeChecker.fromRuntime` for all Nitro annotations, ensuring they are correctly identified when re-exported through the `nitro` runtime package. This resolves "No @NitroModule annotated classes found" and "UNKNOWN_RETURN_TYPE" errors for enums/structs in complex specifications.
- **Improved: spec-level type registration** — ensured that all enums and structs defined in a spec library are correctly added to the valid type set before function, property, and stream validation.

## 0.2.1

- **Fix: non-zero-copy TypedData function parameters now produce correct JNI arrays** — previously the raw C pointer (`float*`, `int32_t*`, …) was passed directly as the JNI call argument, causing a crash at runtime. The generator now emits `NewFloatArray` / `NewIntArray` / `SetFloatArrayRegion` / etc. and passes the proper `jarray` reference. A `DeleteLocalRef` is emitted after the call in every return-type path.
- **Fix: removed redundant `env->ExceptionClear()` at JNI call sites** — `nitro_report_jni_exception` already calls `ExceptionClear()` internally; the duplicate call at each call site was a no-op and has been removed.
- **Fix: `_streamJobs` map now uses a composite `Pair<String, Long>` key** — keying only on `dartPort` meant two simultaneous subscriptions on different streams could theoretically overwrite each other's coroutine job if they received the same port value. The key is now `Pair(streamName, dartPort)`.
- **Polish: spec-path attribution in all generated files** — every generated file (Dart, Kotlin, Swift, C++, CMake) now includes `// Generated from: <spec>.native.dart` at the top, making it easy to trace any generated file back to its source spec when working with multiple modules.
- **Polish: `checkDisposed()` annotated `@pragma('vm:prefer-inline')`** — the single-field `_disposed` check is now inlined by the Dart VM/AOT compiler, eliminating the call overhead on every generated method invocation.
- **Performance: single-pass AST extraction in `SpecExtractor`** — `_extractRecordTypes` previously called `library.annotatedWith` twice (once to collect names, once to build types); it now collects class elements in one pass and reuses the list. `_extractProperties` and `_extractStreams` previously made two separate loops over `element.accessors`; they are now merged into a single combined pass.
- Decoupled from the `nitro` runtime package to resolve `pub.dev` platform warnings.
- Now depends on the pure-Dart `nitro_annotations` package.
- This ensures the generator is recognized as a cross-platform Dart package.

# 0.2.0

- **New: `@HybridRecord` Binary Bridge Generator** — Generated extensions now use a compact binary protocol (`uint8_t*` / `Pointer<Uint8>`) instead of UTF-8 JSON strings, significantly reducing serialization overhead.
  - **Breaking:** Extension methods renamed to standard codec names: `fromJson` → `fromNative` / `fromReader`, `toJson` → `writeFields` / `toNative`.
  - Full support for `@HybridRecord` in **Kotlin** (`.bridge.g.kt`) via `@Keep data class` with companion `decode`/`encode` methods. Swift support updated for `toNative` and `RecordReader` integrations.
- **New: Comprehensive Collection Bridging** — Added binary-first support for:
  - `List<primitive>` (int, double, bool, String) via `RecordWriter.encodePrimitiveList`.
  - `Map<String, T>` using the UTF-8 JSON path (dynamic values).
  - Nested lists and nullable record fields.
- **Improved: Swift Stream Stability** — Fixed a compiler error in `_register_*_stream` by heap-allocating `@HybridStruct` items before passing them to the C emit callback.
- **Improved: Code Quality & Lints** — Generated code now follows strict Dart linting rules:
  - Cleaned up unbraced for-loops and unused local variable declarations.
  - Renamed internal variables to follow public naming conventions (e.g., `_rawResult` → `rawResult`).
- **Testing**: Added 28+ regression tests for Kotlin record emission and updated 200+ existing tests to match the binary wire format.

## 0.1.3

- **Swift generator: fixed `@_cdecl` String type crash (`EXC_BAD_ACCESS`)** — `String` parameters now use `UnsafePointer<CChar>?` (C `const char*`) and return values use `UnsafeMutablePointer<CChar>?` (malloc'd `char*`), with `String(cString:)` conversion at the boundary and `strdup()` for returns so Dart's `toDartStringWithFree()` / `free()` pairs correctly.
- Swift generator: async `String`-returning methods use `DispatchSemaphore` + `Task.detached` with a `strdup(result)` return.
- Swift generator: `String` property getters return `strdup`-allocated C strings; setters accept `UnsafePointer<CChar>?` and convert with `String(cString:)`.

## 0.1.2

- Swift generator: replaced `@objc public static func _call_*` pattern with top-level `@_cdecl("_call_*") public func` stubs. Swift structs and Swift-only protocols cannot cross the Objective-C boundary.
- Swift generator: `bool` return type now maps to `Int8` (matching C's `int8_t`) instead of `Bool`.
- Swift generator: struct-returning functions now return `UnsafeMutableRawPointer?` (heap-allocated, caller frees) instead of `Any?`.

## 0.1.1

- Renamed package from `nitrogen` to `nitro_generator` to avoid a naming conflict on `pub.dev`.

## 0.1.0

- Initial release of Nitro code generator.
- Generates Dart FFI, Kotlin, Swift, and C++ bindings.
- Support for `HybridObject`, `HybridStruct`, and `HybridEnum`.
- Support for `@nitroAsync` methods.
- Support for `@NitroStream` with Backpressure strategies.
