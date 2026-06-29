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
