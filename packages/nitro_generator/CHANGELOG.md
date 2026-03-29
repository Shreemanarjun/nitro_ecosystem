## 0.2.7

- **New: Benchmark regression tests** — Added `benchmark_spec_test.dart` with 56+ tests that mirror the real `benchmark.native.dart` and `benchmark_cpp.native.dart` specs, covering KotlinGenerator, SwiftGenerator, DartFfiGenerator, CppInterfaceGenerator, and CppBridgeGenerator output for all types used by the benchmark (primitives, structs, @HybridRecord, TypedData, Pointer<T>, streams).
- **New: `CppInterfaceGenerator` Pointer<T> param/return tests** — Added `cpp_interface_pointer_test.dart` with 22 tests covering all Pointer<T> combinations: Pointer<Void> → `void*`, Pointer<int> → `int64_t*`, Pointer<double> → `double*`, Pointer<EnumName> → `EnumName*`, Pointer<StructName> → `StructName*`, Pointer<RecordName> → `NitroCppBuffer*`, Pointer<String> → `std::string*`, null inner → `void*`, nullable inner types, multiple pointer params.
- **New: Nullable type handling tests** — Added `nullable_types_test.dart` with 23 tests covering `String?`, `int?`, `double?`, `bool?` type name stripping in CppInterfaceGenerator, nullable type preservation in DartFfiGenerator Dart signatures, and nullable record field handling in Kotlin (null-safe decode pattern, `?` suffix) and Dart (`readNullTag()` pattern).
- **New: Stream backpressure tests** — Added `stream_backpressure_test.dart` with 15 tests asserting all three `Backpressure` enum values (`dropLatest`, `block`, `bufferDrop`) propagate correctly through DartFfiGenerator, KotlinGenerator, and SwiftGenerator outputs. Includes isolation tests confirming each value does not appear in outputs for the other two.
- **Fixed: `benchmark_spec_test.dart` atomic/port assertions** — Corrected stream port storage assertions to match the actual `static int64_t g_port_X = 0;` pattern (plain int64_t, not std::atomic), consistent with the generator's single-write startup model.

## 0.2.6

- **Improved: `CppInterfaceGenerator` Pointer type mapping** — `_cppReturnType`, `_cppParamType`, `_cppScalarType`, and `_cppMethodParams` now inspect `BridgeType.pointerInnerType` to emit precise C++ pointer types. `Pointer<SomeEnum>` → `SomeEnum*`, `Pointer<SomeStruct>` → `SomeStruct*`, `Pointer<Void>` → `void*`; unknown inner types fall back to `void*` as before.
- **Improved: Test precision for `checkDisposed()` guards** — The "methods have checkDisposed() guard" and "property getter has checkDisposed() in block body" tests now assert the guard appears *immediately after* the named member's opening brace (e.g. `double add(double a, double b) {\n    checkDisposed();`) rather than anywhere in the file, preventing false positives.
- **New: Regression test for raw `Pointer<Uint8>` FFI mapping** — Added a test in `dart_ffi_generator_test.dart` that exercises the `Pointer<Uint8>` param path end-to-end, asserting the generated lookup signature and call site both contain `Pointer<Uint8>`.

## 0.2.5

- **New: Thread-Safe Bridge Implementation** — `CppBridgeGenerator` now utilizes `std::atomic` for implementation registration (`g_impl`) and stream port management (`g_port_`). This ensures safe access across multiple native threads and Dart isolates.
- **New: nullability preservation in C++** — The `CppInterfaceGenerator` now leverages `BridgeType` metadata to emit `std::optional<T>` for nullable Dart types, improving type safety on the native side.
- **Improved: FFI Memory Safety** — Updated `DartFfiGenerator` to emit robust `try { ... } finally { malloc.free(...); }` blocks for all record and struct return paths. This prevents memory leaks if Dart decoding throws an exception.
- **Improved: Code Generation Reliability** — Added `checkDisposed()` guards to all generated methods, including `Fast` (leaf) functions.
- **Fixed: Builder diagnostics** — Corrected string interpolation in `builder.printWarning` to show actual file paths instead of literal placeholders.

## 0.2.4

- **Fixed: `typedef redefinition` when multiple modules share a struct** — `generateCStructs` now wraps each C struct in a `#ifndef NITRO_STRUCT_<NAME>_DEFINED` / `#define` / `#endif` guard. When two bridge headers (e.g. `benchmark.bridge.g.h` and `benchmark_cpp.bridge.g.h`) both declare the same struct (e.g. `BenchmarkPoint`) and are compiled into the same translation unit via the CocoaPods umbrella header, the second definition becomes a no-op instead of a fatal `typedef redefinition` error.
- **New: NativeImpl.cpp — Direct C++ Implementation** — When `@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp)` is used, the generator now produces three additional files:
  - `*.native.g.h` — abstract `HybridX` C++ class with pure-virtual methods, properties, and stream emit helpers. The user subclasses this and registers their instance via `${lib}_register_impl()`.
  - `*.mock.g.h` — GoogleMock `MockX : public HybridX` class with `MOCK_METHOD` declarations for every method and property. Enables unit-testing C++ logic without a running Flutter app.
  - `*.test.g.cpp` — test starter with a smoke test (verifies registration/unregistration) and a commented example for the first method. Ready to build with CMake + GoogleTest.
- **New: `CppBridgeGenerator` — direct-dispatch path** — For cpp modules, `.bridge.g.cpp` now uses direct virtual dispatch (`g_impl->method()`) instead of JNI/Swift. No `#ifdef __ANDROID__`, no `#elif __APPLE__`. Includes Dart API DL init, thread-local error state, and stream emit helpers that post to Dart via `Dart_PostCObject_DL`.
- **New: `BridgeSpec.isCppImpl`** — getter returning `true` when `ios == NativeImpl.cpp && android == NativeImpl.cpp`.
- **New: `builder.dart` outputs** — Three new output extensions registered: `*.native.g.h`, `test/*.mock.g.h`, `test/*.test.g.cpp`. Non-cpp modules receive a "Not applicable" comment placeholder (satisfying build_runner's static extension requirement).
- **Improved: Type mapping (C++ direct path)**:
  - `String` → `std::string` / `const std::string&` in C++ interface; `const char*` at C boundary
  - TypedData → `const T* ptr, size_t length` in C++ interface; `T*, int64_t length` at C boundary
  - Enum → C enum type in interface; `int64_t` with `static_cast` at C boundary
  - Struct → `const T&` param / by-value return in interface; `void*` at C boundary
  - Record → `NitroCppBuffer` (pointer + size) in interface
- **Improved: Test Coverage** — 41 new edge-case tests covering: all TypedData pointer mappings, struct/record/enum params and returns, void methods, getter-only properties, multi-stream modules, lib names with dashes, header guard format, `extern "C"` registration API, GoogleMock MOCK_METHOD signatures, test starter example generation, `BridgeSpec.isCppImpl` edge cases.

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
