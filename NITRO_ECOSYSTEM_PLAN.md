# Nitro Ecosystem — Generator & CLI Improvement Plan

> Covers the `nitrogen` code generator (`packages/nitro_generator`) and its CLI
> (`packages/nitrogen_cli`) across all plugins in this repo.
> Ground truth: `BridgeSpec` / `BridgeType` / `BridgeParam` models in
> `packages/nitro_generator/lib/src/bridge_spec.dart`.
> Sections are prioritised P0 → P3. Address in order.

---

## Table of Contents

1. [Background & Problem Statement](#1-background--problem-statement)
2. [Generator Architecture Reference](#2-generator-architecture-reference)
3. [Complete Type Inventory](#3-complete-type-inventory)
4. [Type → Target Language Mapping](#4-type--target-language-mapping)
5. [Generator Correctness — P0 Bugs](#5-generator-correctness--p0-bugs)
6. [Generator Correctness — P1 Gaps](#6-generator-correctness--p1-gaps)
7. [Validation Pass (Pre-Codegen)](#7-validation-pass-pre-codegen)
8. [Test Plan — Per-Generator, Per-Type](#8-test-plan--per-generator-per-type)
   - [8.1 DartFfiGenerator](#81-dartffigenerator)
   - [8.2 SwiftGenerator](#82-swiftgenerator)
   - [8.3 KotlinGenerator](#83-kotlingenerator)
   - [8.4 CppInterfaceGenerator](#84-cppinterfacegenerator)
   - [8.5 CppBridgeGenerator / CppHeaderGenerator](#85-cppbridgegenerator--cppheadergenerator)
   - [8.6 RecordGenerator](#86-recordgenerator)
   - [8.7 StructGenerator](#87-structgenerator)
   - [8.8 EnumGenerator](#88-enumgenerator)
   - [8.9 Platform-Targeting Tests](#89-platform-targeting-tests)
   - [8.10 Validation / Error Tests](#810-validation--error-tests)
9. [New Spec Helpers for test_utils.dart](#9-new-spec-helpers-for-test_utilsdart)
10. [CLI Design — Dual-Mode Architecture](#10-cli-design--dual-mode-architecture)
11. [Terminal UI Spec](#11-terminal-ui-spec)
12. [Headless / CI Mode Spec](#12-headless--ci-mode-spec)
13. [Watch Mode](#13-watch-mode)
14. [Incremental Generation](#14-incremental-generation)
15. [Developer Experience Improvements](#15-developer-experience-improvements)
16. [Implementation Roadmap](#16-implementation-roadmap)
17. [Appendix A: Historical Workarounds](#appendix-a-historical-workarounds)
18. [Appendix B: Files Affected Per Plugin](#appendix-b-files-affected-per-plugin)

---

## 1. Background & Problem Statement

Nitro's generator reads annotated Dart spec files (`*.native.dart`) and emits
bridge code for every target platform:

| Output | Generator class | File pattern |
|---|---|---|
| Dart FFI glue | `DartFfiGenerator` | `*.g.dart` |
| Swift (iOS + macOS) | `SwiftGenerator` | `*.bridge.g.swift` |
| Kotlin (Android) | `KotlinGenerator` | `*.bridge.g.kt` |
| C++ interface | `CppInterfaceGenerator` | `Hybrid*.hpp` |
| C++ bridge | `CppBridgeGenerator` | `Hybrid*.cpp` |
| C++ header | `CppHeaderGenerator` | `*.hpp` |
| C++ mock | `CppMockGenerator` | `Mock*.hpp` |
| Record (Dart + Kotlin) | `RecordGenerator` | inside `*.g.dart` + `*.bridge.g.kt` |
| Enum (all targets) | `EnumGenerator` | inlined into each bridge file |
| Struct (all targets) | `StructGenerator` | inlined into each bridge file |

### Known friction points (discovered in `nitro_printing`)

| Issue | Impact | First seen |
|---|---|---|
| Default values stripped from `{int param = 5}` optional named params | **Compile error** in generated Dart | `testPrinterConnection`, `getPrinterStatusDetail` |
| No pre-codegen validation — invalid signatures reach native compilers | Platform build fails with cryptic error | every complex signature |
| Raw `build_runner` output — no structure | Hard to spot errors in large projects | every run |
| No `--check` mode | Cannot enforce "generated files are fresh" in CI | — |
| Full regeneration every run | Slow for `nitro_vani` (7 spec files) | — |

---

## 2. Generator Architecture Reference

### Key models (`bridge_spec.dart`)

```
BridgeSpec
├── dartClassName, lib, namespace, sourceUri
├── iosImpl, androidImpl, macosImpl, windowsImpl, linuxImpl, webImpl: NativeImpl?
│   ├── NativeImpl.swift → SwiftGenerator
│   ├── NativeImpl.kotlin → KotlinGenerator
│   ├── NativeImpl.cpp → CppInterfaceGenerator / CppBridgeGenerator
│   └── NativeImpl.wasm → (web generator)
├── structs: List<BridgeStruct>
├── enums: List<BridgeEnum>
├── functions: List<BridgeFunction>
├── streams: List<BridgeStream>
├── properties: List<BridgeProperty>
└── recordTypes: List<BridgeRecordType>

BridgeType
├── name: String                  — Dart type name, '?' suffix = nullable
├── isNullable: bool
├── isFuture: bool
├── isStream: bool
├── isRecord: bool                — @HybridRecord, List<@HybridRecord>, Map<String,V>
├── isPointer: bool               — raw FFI Pointer<T>
├── pointerInnerType: String?
├── recordListItemType: String?   — T when name is List<T>
├── recordListItemIsPrimitive: bool
├── isMap: bool                   — Map<String,V>
└── isTypedData: bool (computed)  — Uint8List, Int8List, Float32List, ...

BridgeParam
├── name: String
├── type: BridgeType
├── isNamed: bool                 — curly-brace named param
├── isOptional: bool              — can be omitted by caller
└── defaultLiteral: String?       — *** MISSING — this is Bug 5.1 ***

BridgeField (struct fields)
├── name: String
├── type: BridgeType
├── zeroCopy: bool
├── isNamed: bool                 — named constructor param
└── isRequired: bool

BridgeProperty
├── dartName, type: BridgeType
├── getSymbol, setSymbol: String
└── hasGetter, hasSetter: bool

BridgeStream
├── dartName: String
├── registerSymbol, releaseSymbol: String
├── itemType: BridgeType
└── backpressure: Backpressure    — dropLatest | block | dropOldest
```

### Platform capability matrix

| Platform | Swift | Kotlin | C++ |
|---|---|---|---|
| iOS | ✓ | — | ✓ |
| Android | — | ✓ | ✓ |
| macOS | ✓ | — | ✓ |
| Windows | — | — | ✓ |
| Linux | — | — | ✓ |
| Web | — | — | WASM |

---

## 3. Complete Type Inventory

Every type that can appear in a `BridgeType.name`. Tests must cover
each type as: **param**, **return**, **stream item**, **struct field**,
**record field**, and **property type** where applicable.

### 3.1 Scalar primitives

| Dart | Swift | Kotlin | C++ |
|---|---|---|---|
| `bool` | `Bool` | `Boolean` | `bool` |
| `int` | `Int64` | `Long` | `int64_t` |
| `double` | `Double` | `Double` | `double` |
| `String` | `String` | `String` | `std::string` / `const std::string&` |
| `void` (return only) | `Void` | `Unit` | `void` |

### 3.2 Nullable scalars

Append `?` to any primitive name. The `?` must be:
- **Preserved** in generated Dart signatures
- **Stripped** in C++ interface (nullable is not representable at C level)
- **Propagated** as `T?` in Swift optional, `T?` in Kotlin nullable

| Dart | Swift | Kotlin | C++ (stripped) |
|---|---|---|---|
| `bool?` | `Bool?` | `Boolean?` | `bool` |
| `int?` | `Int64?` | `Long?` | `int64_t` |
| `double?` | `Double?` | `Double?` | `double` |
| `String?` | `String?` | `String?` | `const std::string&` |

### 3.3 TypedData

All `isTypedData == true` types. Each bridges as a byte-array in native code.

| Dart type | Swift | Kotlin | C++ |
|---|---|---|---|
| `Uint8List` | `Data` | `ByteArray` | `std::vector<uint8_t>` |
| `Uint8List` + `@ZeroCopy()` | `Data` (zero-copy) | `ByteArray` | `ArrayBuffer` |
| `Int8List` | `Data` | `ByteArray` | `std::vector<int8_t>` |
| `Int16List` | `Data` | `ByteArray` | `std::vector<int16_t>` |
| `Int32List` | `Data` | `ByteArray` | `std::vector<int32_t>` |
| `Uint16List` | `Data` | `ByteArray` | `std::vector<uint16_t>` |
| `Uint32List` | `Data` | `ByteArray` | `std::vector<uint32_t>` |
| `Float32List` | `Data` | `ByteArray` | `std::vector<float>` |
| `Float64List` | `Data` | `ByteArray` | `std::vector<double>` |
| `Int64List` | `Data` | `ByteArray` | `std::vector<int64_t>` |
| `Uint64List` | `Data` | `ByteArray` | `std::vector<uint64_t>` |

### 3.4 Enums (`@HybridEnum`)

| Dart | Swift | Kotlin | C++ |
|---|---|---|---|
| `enum Foo { a, b }` | `enum Foo: Int64` | `enum class Foo(val nativeValue: Long)` | `enum class Foo : int64_t` |
| Enum return (sync) | `-> Foo` | `fun f(): Foo` | `virtual Foo f() = 0` |
| Enum return (async) | `async throws -> Foo` | `suspend fun f(): Foo` | — |
| Nullable enum param | `_ m: Foo?` | `m: Foo?` | `Foo m` (stripped) |
| Enum property | `var mode: Foo { get set }` | `var mode: Foo` | `virtual Foo getMode() = 0` |

### 3.5 Structs (`@HybridStruct`)

| Pattern | Swift | Kotlin | C++ |
|---|---|---|---|
| Flat struct (primitives) | `struct Foo` | `data class Foo` | `struct Foo` |
| Struct with nested struct | `struct Outer` containing `Inner` | same | same |
| Deeply nested A→B→C | recursive struct defs | same | same |
| Struct as function param | `_ f: Foo` | `f: FooStruct` | `const Foo& f` |
| Struct as return type | `-> Foo` | `: FooStruct` | `virtual Foo f() = 0` |
| Nullable struct param | `_ f: Foo?` | `f: FooStruct?` | `const Foo& f` (stripped) |
| Struct with `@ZeroCopy()` field | `Data` field (no copy) | `ByteArray` | `ArrayBuffer` field |
| Packed struct | `@packed` equivalent | same | `#pragma pack(1)` |

### 3.6 Records (`@HybridRecord`)

Records bridge as JSON blobs. `isRecord == true` on `BridgeType`.

| Pattern | Dart extension | Kotlin |
|---|---|---|
| Flat record (primitives) | `readFrom(ByteBuffer)` extension | `data class` with `decodeFrom` |
| Record with `List<primitive>` | JSON array decode | `ArrayList<Long>` etc. |
| Record with `List<@HybridRecord>` | nested list decode | `decodeFrom` loop |
| Nullable record field | `readNullTag()` | `buf.get().toInt() == 0` check |
| `Future<List<@HybridRecord>>` return | JSON list decode | coroutine + list |
| Nullable `@HybridRecord?` field | null-tag + conditional decode | same |

### 3.7 Maps

`Map<String, V>` with `isMap == true`. Bridges as a JSON string.

| Pattern | Status |
|---|---|
| `Map<String, String>` param | Supported via JSON encoding |
| `Map<String, int>` param | Supported via JSON encoding |
| `Map<String, bool>` param | Supported via JSON encoding |
| `Map<String, @HybridRecord>` | ✅ **DONE** 2026-05-23 — `map_hybrid_record_test.dart` (9 tests); isMap takes precedence over isRecord → JSON path |
| `Map<K, V>` where K is not String | Should emit E001 (unsupported) |

### 3.8 Pointers

`isPointer == true`. Raw FFI `Pointer<T>`.

| Dart | C++ | Dart FFI |
|---|---|---|
| `Pointer<Uint8>` | `uint8_t*` | `ffi.Pointer<ffi.Uint8>` |
| `Pointer<Void>` | `void*` | `ffi.Pointer<ffi.Void>` |
| `Pointer<Int32>` | `int32_t*` | `ffi.Pointer<ffi.Int32>` |

### 3.9 Async (`@nitroAsync`)

`isFuture == true` on return type.

| Pattern | Swift | Kotlin | Dart impl |
|---|---|---|---|
| `Future<void>` | `async throws` | `suspend Unit` | DispatchSemaphore |
| `Future<bool>` | `async throws -> Bool` | `suspend Boolean` | same |
| `Future<int>` | `async throws -> Int64` | `suspend Long` | same |
| `Future<double>` | `async throws -> Double` | `suspend Double` | same |
| `Future<String>` | `async throws -> String` | `suspend String` | same |
| `Future<Uint8List>` | `async throws -> Data` | `suspend ByteArray` | same |
| `Future<@HybridStruct>` | `async throws -> Foo` | `suspend FooStruct` | same |
| `Future<@HybridEnum>` | `async throws -> Foo` | `suspend Foo` | same |
| `Future<List<@HybridRecord>>` | — | `suspend List<Foo>` | JSON decode |
| `Future<Map<String,V>>` | — | `suspend Map<String,V>` | JSON decode |
| `@nitroAsync` on non-`Future` | **should be E002 error** | — | — |

### 3.10 Streams (`@NitroStream`)

`isStream == true`. `BridgeStream` has a `backpressure` field.

| Item type | Swift AnyPublisher | Kotlin Flow | Backpressure modes |
|---|---|---|---|
| `double` | `AnyPublisher<Double, Never>` | `Flow<Double>` | dropLatest, block, dropOldest |
| `int` | `AnyPublisher<Int64, Never>` | `Flow<Long>` | same |
| `bool` | `AnyPublisher<Bool, Never>` | `Flow<Boolean>` | same |
| `String` | `AnyPublisher<String, Never>` | `Flow<String>` | same |
| `Uint8List` | `AnyPublisher<Data, Never>` | `Flow<ByteArray>` | same |
| `@HybridStruct` | `AnyPublisher<Foo, Never>` | `Flow<FooStruct>` | same |
| `@HybridEnum` | `AnyPublisher<Foo, Never>` | `Flow<Foo>` | same |
| `Stream<T>` without `@NitroStream` | should be W004 | — | — |

### 3.11 Properties

`BridgeProperty`. Can be getter-only or getter+setter.

| Type | Swift protocol | Kotlin interface | C++ interface |
|---|---|---|---|
| `bool` (get+set) | `var x: Bool { get set }` | `var x: Boolean` | `virtual bool getX() = 0; virtual void setX(bool) = 0;` |
| `int` (get-only) | `var x: Int64 { get }` | `val x: Long` | `virtual int64_t getX() = 0;` |
| `double` (get+set) | `var x: Double { get set }` | `var x: Double` | same pattern |
| `String` (get+set) | `var x: String { get set }` | `var x: String` | same pattern |
| `@HybridEnum` (get+set) | `var x: Foo { get set }` | `var x: Foo` | same pattern |
| `@HybridStruct` (get-only) | `var x: Foo { get }` | `val x: FooStruct` | same pattern |

### 3.12 Optional Named Params — Full Subtype Matrix

This is where Bug 5.1 lives. All combinations:

| Dart param style | `BridgeParam` model | Currently works? |
|---|---|---|
| `int x` positional required | `isNamed=false, isOptional=false` | ✓ |
| `String name` positional required | same | ✓ |
| `{int? x}` nullable named optional | `isNamed=true, isOptional=true, type.name='int?'` | ✓ |
| `{String? s}` nullable named optional | same with `String?` | ✓ |
| `{int x = 5}` non-nullable named with default | `isNamed=true, isOptional=true` but **`defaultLiteral` field missing** | **Bug 5.1** |
| `{bool flag = true}` | same | **Bug 5.1** |
| `{double d = 1.0}` | same | **Bug 5.1** |
| `{EnumType e = E.v}` | same, enum type | **Bug 5.2** |
| `{StructType s = S()}` | same, struct type | **Bug 5.3** |
| Mixed: positional + named nullable | composite | ✓ |
| Mixed: positional + named with default | composite | **Bug 5.1** |

---

## 4. Type → Target Language Mapping

Reference table showing the exact generated symbol for every Dart type.

### 4.1 Dart → Swift

| Dart | Swift param | Swift return | Notes |
|---|---|---|---|
| `bool` | `_ x: Bool` | `-> Bool` | C stub: `Int8` (0/1) |
| `int` | `_ x: Int64` | `-> Int64` | |
| `double` | `_ x: Double` | `-> Double` | |
| `String` | `_ x: String` | `-> String` | C stub: `UnsafePointer<CChar>` |
| `void` | — | no return | |
| `bool?` | `_ x: Bool?` | `-> Bool?` | |
| `int?` | `_ x: Int64?` | `-> Int64?` | |
| `double?` | `_ x: Double?` | `-> Double?` | |
| `String?` | `_ x: String?` | `-> String?` | |
| `Uint8List` | `_ x: Data` | `-> Data` | |
| `Uint8List` (zero-copy) | `_ x: Data` | `-> Data` | no-copy path |
| `@HybridStruct Foo` | `_ x: Foo` | `-> Foo` | |
| `@HybridStruct Foo?` | `_ x: Foo?` | `-> Foo?` | |
| `@HybridEnum Foo` | `_ x: Foo` | `-> Foo` | |
| `@HybridEnum Foo?` | `_ x: Foo?` | `-> Foo?` | |
| `Future<T>` | — | `async throws -> T` | DispatchSemaphore + Task.detached |
| `Stream<T>` | — | `AnyPublisher<T, Never>` | Combine |

### 4.2 Dart → Kotlin

| Dart | Kotlin param | Kotlin return | Notes |
|---|---|---|---|
| `bool` | `x: Boolean` | `: Boolean` | JNI bridge returns `Long` (0/1) |
| `int` | `x: Long` | `: Long` | |
| `double` | `x: Double` | `: Double` | |
| `String` | `x: String` | `: String` | |
| `void` | — | `: Unit` | |
| `bool?` | `x: Boolean?` | `: Boolean?` | |
| `int?` | `x: Long?` | `: Long?` | |
| `double?` | `x: Double?` | `: Double?` | |
| `String?` | `x: String?` | `: String?` | |
| `Uint8List` | `x: ByteArray` | `: ByteArray` | |
| `@HybridStruct Foo` | `x: FooStruct` | `: FooStruct` | `data class FooStruct` |
| `@HybridEnum Foo` | `x: Foo` | `: Foo` | `enum class Foo(val nativeValue: Long)` |
| `Future<T>` | — | `suspend : T` | coroutine |
| `Stream<T>` | — | `val x: Flow<T>` | Kotlin Flow |

### 4.3 Dart → C++ (interface)

| Dart | C++ param | C++ return | Notes |
|---|---|---|---|
| `bool` | `bool x` | `bool` | |
| `int` | `int64_t x` | `int64_t` | |
| `double` | `double x` | `double` | |
| `String` | `const std::string& x` | `std::string` | |
| `void` | — | `void` | |
| `bool?` | `bool x` | `bool` | `?` stripped |
| `int?` | `int64_t x` | `int64_t` | `?` stripped |
| `double?` | `double x` | `double` | `?` stripped |
| `String?` | `const std::string& x` | `std::string` | `?` stripped |
| `Uint8List` | `const std::vector<uint8_t>& x` | `std::vector<uint8_t>` | |
| `@HybridStruct Foo` | `const Foo& x` | `Foo` | |
| `@HybridStruct Foo?` | `const Foo& x` | `Foo` | `?` stripped |
| `@HybridEnum Foo` | `Foo x` | `Foo` | |
| `@HybridEnum Foo?` | `Foo x` | `Foo` | `?` stripped |
| `Pointer<Uint8>` | `uint8_t*` | — | raw pointer |
| `Pointer<Void>` | `void*` | — | raw pointer |

---

## 5. Generator Correctness — P0 Bugs

### 5.1 Default value propagation (`int`, `double`, `bool`, `String`)

**Root cause:** `BridgeParam` has no `defaultLiteral: String?` field.
The `spec_extractor.dart` reads the param type and name but discards
the `= 5` literal when building the `BridgeParam`.

**The bug:**
```dart
// Dart spec:
@nitroAsync
Future<bool> testPrinterConnection(String printerId, {int timeoutSeconds = 5});

// Generated _Impl class (WRONG — Dart compile error):
@override
Future<bool> testPrinterConnection(String printerId, {int timeoutSeconds}) { ... }
// non-nullable named param with no default = compile error
```

**Fix option A — add `defaultLiteral` to `BridgeParam` and propagate:**
```dart
// bridge_spec.dart:
class BridgeParam {
  // ...existing fields...
  final String? defaultLiteral;   // ← new field: '5', 'true', 'PrintQuality.normal', etc.
}

// DartFfiGenerator emits:
// {int timeoutSeconds = 5}     when defaultLiteral = '5'
// {bool flag = true}           when defaultLiteral = 'true'
```

**Fix option B — emit validation error instead of invalid code:**
```
ERROR  nitro_printing.native.dart:109 [E007]
  Optional named param `timeoutSeconds` has type `int` (non-nullable) with no
  default value the generator can propagate.
  Fix: use `int? timeoutSeconds` and handle the default in native code.
```

**Workaround (current):** use `{int? timeoutSeconds}` (nullable) and handle
`timeoutSeconds ?? 5` in native Swift/Kotlin code. See Appendix A.

**Affects:** all non-nullable optional named params — `bool`, `double`, `String`,
enum, struct.

---

### 5.2 Enum-typed default params

Same root cause as 5.1 but for `@HybridEnum` types:

```dart
// Spec:
Future<PrintResult> printText(String text, {PrintQuality quality = PrintQuality.normal});

// Expected generated code:
@override
Future<PrintResult> printText(String text, {PrintQuality quality = PrintQuality.normal}) { ... }
```

`defaultLiteral` must hold the string `'PrintQuality.normal'` and emit verbatim.

---

### 5.3 Struct-typed default params

```dart
// Works today (nullable):
Future<PrintResult> printDocument(PrintDocument doc, {PrintSettings? settings});

// Does NOT work (non-nullable with default constructor call):
Future<PrintResult> printDocument(PrintDocument doc, {PrintSettings settings = PrintSettings()});
// Generator must emit `{PrintSettings settings = PrintSettings()}` in Dart impl
```

---

## 6. Generator Correctness — P1 Gaps

### 6.1 `@nitroAsync` on non-`Future` method

```dart
@nitroAsync        // ← wrong: annotating a sync method
bool isPrintingSupported();
```

Currently silently ignored or produces a broken bridge. Must emit E002.

---

### 6.2 `Map<K,V>` where K ≠ `String`

```dart
@nitroAsync
Future<bool> setData(Map<int, String> meta);  // K is int — unsupported
```

Only `Map<String, V>` is bridgeable (as JSON). Other key types must emit E001
at validation time, not a cryptic Kotlin/Swift compile error later.

---

### 6.3 Mixed positional + named params with default

```dart
@nitroAsync
Future<PrintResult> printRaw(
  Uint8List data,          // positional
  int copies, {            // positional
  PrintSettings? settings, // named nullable — works
  bool verify = false,     // named + default — Bug 5.1
});
```

All four param kinds combined in one method. Generator must handle the mixture
on all targets: Dart FFI, Swift, Kotlin.

---

### 6.4 `Stream<T>` without `@NitroStream` annotation

```dart
Stream<double> onData();  // ← no @NitroStream — will not be bridged
```

Must emit W004 at validation time.

---

### 6.5 Source-map comments in generated files

Every generated method should reference its spec line:

```swift
// Generated from nitro_printing.native.dart:109
func testPrinterConnection(printerId: String, timeoutSeconds: Int64?) async throws -> Bool
```

```kotlin
// Generated from nitro_printing.native.dart:109
suspend fun testPrinterConnection(printerId: String, timeoutSeconds: Long?): Boolean
```

---

### 6.6 All TypedData variants

`BridgeType.isTypedData` covers 11 typed-list types (§3.3). Currently only
`Uint8List` is tested. The remaining 10 variants need generator tests to confirm
the correct C type, Java type, and Swift type are emitted.

---

## 7. Validation Pass (Pre-Codegen)

Run before writing any file. Emit all errors at once.

| Code | Severity | Check |
|---|---|---|
| W001 | warn | Non-nullable optional param with no `defaultLiteral` — Bug 5.1 |
| W002 | warn | Enum-typed optional param with no default — Bug 5.2 |
| W003 | warn | Struct-typed optional param with no default — Bug 5.3 |
| W004 | warn | `Stream<T>` return without `@NitroStream` |
| W005 | warn | `@nitroAsync` on `Future<void>` with no await body likely (informational) |
| E001 | error | Unsupported type — `Map<K,V>` where K ≠ String, or `dynamic`, `Object` |
| E002 | error | `@nitroAsync` on non-`Future` return type |
| E003 | error | Duplicate method name in same spec (no Dart overloads) |
| E004 | error | `@HybridStruct` with mutable fields (`var`) — structs must be `final` |
| E005 | error | `@ZeroCopy()` on non-TypedData field |
| E006 | error | Circular struct dependency (A→B→A) |
| E007 | error | Non-nullable named optional param with no default (emitting invalid Dart) |

### Error format (headless)

```
[nitro] error  nitro_printing.native.dart:109 [E007] non-nullable optional param `timeoutSeconds: int` has no default — use `int?` or add `@NitroDefault(5)`
[nitro] warn   nitro_printing.native.dart:55  [W004] Stream<double> onData() missing @NitroStream annotation — will not be bridged
[nitro] done   0 files generated (1 error, 1 warning) — fix errors and re-run
```

---

## 8. Test Plan — Per-Generator, Per-Type

All tests live in `packages/nitro_generator/test/`.
Each subsection lists the **target test file**, **existing coverage**, and
**missing tests to add**. Spec helpers go in `test_utils.dart` (§9).

---

### 8.1 DartFfiGenerator

**File:** `dart_ffi_generator_test.dart`

#### Param types — what generated Dart signature looks like

| Type | Expected Dart signature | Covered? |
|---|---|---|
| `bool` positional | `bool x` | ✓ |
| `int` positional | `int x` | ✓ |
| `double` positional | `double x` | ✓ |
| `String` positional | `String x` | ✓ |
| `int?` named optional | `{int? x}` | ✓ (optional_param_test) |
| `String?` named optional | `{String? x}` | ✓ (optional_param_test) |
| `bool?` named optional | `{bool? x}` | need test |
| `double?` named optional | `{double? x}` | need test |
| `{int x = 5}` non-nullable default | `{int x = 5}` | **missing — Bug 5.1** |
| `{bool flag = true}` | `{bool flag = true}` | **missing — Bug 5.1** |
| `{double d = 1.0}` | `{double d = 1.0}` | **missing — Bug 5.1** |
| `{EnumType e = E.v}` | `{EnumType e = E.v}` | **missing — Bug 5.2** |
| `Uint8List` | `Uint8List x` | ✓ |
| `Int8List` | `Int8List x` | need test |
| `Float32List` | `Float32List x` | need test |
| `@HybridStruct` param | `Foo x` | ✓ |
| Nullable struct `Foo?` | `Foo? x` | need test |
| `@HybridEnum` param | `Foo x` | need test |
| `Pointer<Uint8>` | `ffi.Pointer<ffi.Uint8> x` | ✓ (pointer_support_test) |

#### Return types — what generated Dart `_Impl` returns

| Type | Expected | Covered? |
|---|---|---|
| `bool` sync | `bool` | ✓ |
| `int` sync | `int` | ✓ |
| `double` sync | `double` | ✓ |
| `String` sync | `String` | ✓ |
| `Future<void>` async | `Future<void>` | ✓ (native_async_test) |
| `Future<bool>` async | `Future<bool>` | ✓ |
| `Future<int>` async | `Future<int>` | ✓ |
| `Future<double>` async | `Future<double>` | ✓ |
| `Future<String>` async | `Future<String>` | ✓ |
| `Future<Uint8List>` async | `Future<Uint8List>` | ✓ (`dart_ffi_param_return_test`) |
| `Future<@HybridStruct>` async | `Future<Foo>` | ✓ (`dart_ffi_param_return_test`) |
| `Future<@HybridEnum>` async | `Future<Foo>` | ✓ (dart_ffi_generator_test) |
| `Future<List<@HybridRecord>>` async | `Future<List<Foo>>` | ✓ (dart_ffi_generator_record_test) |
| `@HybridEnum` sync | `Foo` | ✓ |
| `@HybridStruct` sync | `Foo` | ✓ |
| `String?` | `String?` | ✓ (nullable_types_test) |
| `int?` | `int?` | ✓ (nullable_types_test) |

#### New tests to add in `dart_ffi_generator_test.dart`

```dart
// 1. Async Uint8List return
test('Future<Uint8List> return emits Uint8List in async wrapper', () {
  final out = DartFfiGenerator.generate(asyncUint8ListReturnSpec());
  expect(out, contains('Future<Uint8List>'));
});

// 2. Async struct return
test('Future<@HybridStruct> return emits correct Future<T>', () {
  final out = DartFfiGenerator.generate(asyncStructReturnSpec());
  expect(out, contains('Future<Reading>'));
});

// 3. Nullable struct param
test('nullable struct param emits Foo? in Dart signature', () {
  final out = DartFfiGenerator.generate(nullableStructParamSpec());
  expect(out, contains('Foo? x'));
});

// 4. Non-nullable default param (Bug 5.1) — expect W001 or correct output
test('named param with int default emits {int x = 5} in Dart signature', () {
  final out = DartFfiGenerator.generate(defaultIntParamSpec());
  expect(out, contains('{int x = 5}'));  // verifies Bug 5.1 is fixed
});

// 5. Bool and double nullable named params
test('{bool? flag} named param emits curly-brace bool?', () {
  final out = DartFfiGenerator.generate(optionalBoolParamSpec());
  expect(out, contains('{bool? flag}'));
});

test('{double? d} named param emits curly-brace double?', () {
  final out = DartFfiGenerator.generate(optionalDoubleParamSpec());
  expect(out, contains('{double? d}'));
});

// 6. TypedData variants
for (final (typeName, _) in typedDataVariants) {
  test('$typeName param emits correct Dart type', () {
    final out = DartFfiGenerator.generate(typedDataParamSpec(typeName));
    expect(out, contains('$typeName x'));
  });
}
```

---

### 8.2 SwiftGenerator

**File:** `swift_generator_test.dart`

#### Existing coverage (verified)

- Protocol name, imports (`Foundation`, `Combine`)
- Sync `double` function, async `async throws`
- `AnyPublisher<Double, Never>` for streams
- `{ get set }` / `{ get }` for properties
- `@_cdecl` stubs, registry class
- `Bool` return → `Int8` C stub with `? 1 : 0`
- `DispatchSemaphore` + `Task.detached` for async struct

#### Missing Swift tests

| Type | Expected Swift output | Test to add |
|---|---|---|
| `int?` param | `_ x: Int64?` | `swift_nullable_param_test.dart` |
| `bool?` param | `_ x: Bool?` | same |
| `String?` param | `_ x: String?` | same |
| `int?` return | `-> Int64?` | same |
| `@HybridEnum` param | `_ x: Foo` | `swift_enum_param_test.dart` |
| Nullable enum `Foo?` param | `_ x: Foo?` | same |
| Enum property getter | `var mode: Foo { get }` | same |
| Enum property getter+setter | `var mode: Foo { get set }` | same |
| `Future<@HybridEnum>` return | `async throws -> Foo` | same |
| `Future<Uint8List>` return | `async throws -> Data` | `swift_async_types_test.dart` |
| `Future<String>` return | `async throws -> String` | same |
| `Uint8List` (zero-copy) | `Data` field, zero-copy path | `swift_zero_copy_test.dart` |
| `Int8List` param | `Data` | `swift_typed_data_test.dart` |
| `Float32List` param | `Data` | same |
| `Float64List` param | `Data` | same |
| `Stream<bool>` | `AnyPublisher<Bool, Never>` | `swift_stream_types_test.dart` |
| `Stream<String>` | `AnyPublisher<String, Never>` | same |
| `Stream<Uint8List>` | `AnyPublisher<Data, Never>` | same |
| `Stream<@HybridStruct>` | `AnyPublisher<Foo, Never>` | same |
| `Stream<@HybridEnum>` | `AnyPublisher<Foo, Never>` | same |
| Backpressure `block` | different buffer strategy | `stream_backpressure_test.dart` |
| Backpressure `dropOldest` | different buffer strategy | same |
| macOS Swift (distinct from iOS) | identical protocol, separate file path | `swift_macos_test.dart` |
| `{int? x}` named param in Swift | `x: Int64? = nil` | `swift_optional_param_test.dart` |
| Read-only `String` property | `var x: String { get }` | `swift_property_types_test.dart` |
| Read-write `bool` property | `var x: Bool { get set }` | same |

---

### 8.3 KotlinGenerator

**File:** `kotlin_generator_test.dart`

#### Existing coverage (verified)

- Package `nitro.X`, interface name, `JniBridge` object
- Sync `Double` / `Boolean` functions
- `enum class` with `nativeValue`, JniBridge `_call` returns `Long`
- `Flow<CameraFrame>` stream
- `val` for read-only, `var` for read-write properties

#### Missing Kotlin tests

| Type | Expected Kotlin output | Test to add |
|---|---|---|
| `bool` param | `x: Boolean` | need test |
| `int?` param | `x: Long?` | `kotlin_nullable_test.dart` |
| `bool?` param | `x: Boolean?` | same |
| `String?` param | `x: String?` | same |
| `int?` return | `: Long?` | same |
| `Uint8List` param | `x: ByteArray` | `kotlin_typed_data_test.dart` |
| `Float32List` param | `x: ByteArray` | same |
| `@HybridEnum` param | `x: Foo` | `kotlin_enum_param_test.dart` |
| Nullable enum `Foo?` param | `x: Foo?` | same |
| `Future<@HybridEnum>` return | `suspend : Foo` | same |
| `Future<Uint8List>` return | `suspend : ByteArray` | `kotlin_async_types_test.dart` |
| `Future<@HybridStruct>` return | `suspend : FooStruct` | same |
| `Future<List<@HybridRecord>>` | coroutine + list decode | existing record test |
| `Stream<bool>` | `Flow<Boolean>` | `kotlin_stream_types_test.dart` |
| `Stream<String>` | `Flow<String>` | same |
| `Stream<Uint8List>` | `Flow<ByteArray>` | same |
| `Stream<@HybridStruct>` | `Flow<FooStruct>` | same |
| `Stream<@HybridEnum>` | `Flow<Foo>` | same |
| `{int? x}` named param | `x: Long? = null` | `kotlin_optional_param_test.dart` |
| JniBridge `_call` for `bool` return | returns `Long` (0/1) | need test |
| JniBridge `_call` for `Uint8List` return | `ByteArray` handling | need test |
| `suspend fun` for `Future<void>` | `: Unit` | need test |
| Read-only `bool` property | `val x: Boolean` | `kotlin_property_types_test.dart` |
| Read-write `int` property | `var x: Long` | same |
| Read-write `String` property | `var x: String` | same |

---

### 8.4 CppInterfaceGenerator

**File:** `cpp_interface_generator_test.dart`

#### Existing coverage (verified)

- `virtual` pure functions, `= 0`
- Enum, struct, stream in interface
- Nullable type stripping (in `nullable_types_test.dart`)
- Pointer type (in `pointer_support_test.dart`)

#### Missing C++ interface tests

| Type | Expected C++ | Test to add |
|---|---|---|
| `bool` return | `virtual bool f() = 0;` | need test |
| `int` return | `virtual int64_t f() = 0;` | need test |
| `String` return | `virtual std::string f() = 0;` | need test |
| `String` param | `virtual void f(const std::string& x) = 0;` | need test |
| `Uint8List` param | `virtual void f(const std::vector<uint8_t>& x) = 0;` | `cpp_typed_data_test.dart` |
| `Float32List` param | `virtual void f(const std::vector<float>& x) = 0;` | same |
| `Float64List` param | `virtual void f(const std::vector<double>& x) = 0;` | same |
| `Int8List` param | `virtual void f(const std::vector<int8_t>& x) = 0;` | same |
| `Uint8List` return | `virtual std::vector<uint8_t> f() = 0;` | same |
| `@HybridStruct` return | `virtual Foo f() = 0;` | need test |
| `@HybridStruct` param | `virtual void f(const Foo& x) = 0;` | need test |
| `@HybridEnum` param | `virtual void f(Foo x) = 0;` | need test |
| `@HybridEnum` return | `virtual Foo f() = 0;` | need test |
| Nullable struct `Foo?` param | `virtual void f(const Foo& x) = 0;` (stripped) | ✓ nullable_types_test |
| `Pointer<Uint8>` param | `virtual void f(uint8_t* x) = 0;` | ✓ pointer_support_test |
| `Pointer<Void>` param | `virtual void f(void* x) = 0;` | ✓ pointer_support_test |
| `Pointer<Int32>` param | `virtual void f(int32_t* x) = 0;` | need test |
| Getter-only property | `virtual int64_t getX() const = 0;` | need test |
| Getter+setter property | `virtual void setX(int64_t v) = 0;` | need test |

---

### 8.5 CppBridgeGenerator / CppHeaderGenerator

**Files:** `cpp_bridge_generator_test.dart`, `cpp_header_generator_test.dart`, `cpp_bridge_types_test.dart`

#### ✅ DONE 2026-05-23 — `cpp_bridge_types_test.dart` (40 tests)

| Type | Expected output | Status |
|---|---|---|
| `Uint8List` param marshalling (JNI) | `NewByteArray` + `SetByteArrayRegion` | ✅ |
| `Uint8List` param marshalling (cpp direct) | `uint8_t*` + `int64_t` length | ✅ |
| `Float32List` param marshalling (JNI) | `NewFloatArray` + `SetFloatArrayRegion` | ✅ |
| `Float32List` param marshalling (cpp direct) | `float*` + `int64_t` length | ✅ |
| `@NitroNativeAsync` function (JNI) | void + dart_port + `CallStaticVoidMethod` | ✅ |
| `@NitroNativeAsync` function (cpp direct) | void + dart_port forwarded to `g_impl` | ✅ |
| Enum param in cpp direct | `static_cast<EnumType>(param)` | ✅ |
| Enum param in JNI path | passed to `CallStaticVoidMethod` | ✅ |
| 7 TypedData variants in cpp direct | correct C pointer types | ✅ |
| `@nitroAsync` bool/String return (cpp direct) | calls `g_impl`, uses `strdup` for String | ✅ |

---

### 8.6 RecordGenerator

**Files:** `record_generator_test.dart`, `dart_ffi_generator_record_test.dart`

#### Existing coverage (verified)

- Flat record Dart extension
- Kotlin `data class` with `decodeFrom`
- Nullable primitive field (null-tag check)
- Nullable record-object field (`readNullTag()`)
- `List<@HybridRecord>` return type

#### Missing record tests

| Type | Expected | Test to add |
|---|---|---|
| Record with `bool` field | Dart `bool` / Kotlin `Boolean` | `record_bool_field_test.dart` |
| Record with `double` field | Dart `double` / Kotlin `Double` | same |
| Record with `Uint8List` field | Dart `Uint8List` / Kotlin `ByteArray` | same |
| Record with nullable `int?` field | Dart `int?` / Kotlin `Long?` null-check | ✓ nullable_types_test |
| `Map<String, String>` field | JSON decode in both Dart + Kotlin | `record_map_field_test.dart` |
| Deeply nested `List<List<T>>` | nested JSON decode | `record_deep_list_test.dart` |
| `List<String>` field | Kotlin `ArrayList<String>` | `record_list_primitives_test.dart` |
| `List<double>` field | Kotlin `ArrayList<Double>` | same |
| `List<bool>` field | Kotlin `ArrayList<Boolean>` | same |
| Swift record extension | `readFrom` in Swift | `record_swift_test.dart` |

---

### 8.7 StructGenerator

**Files:** `struct_generator_test.dart`, `struct_field_types_test.dart`,
`struct_generator_edge_cases_test.dart`

#### Existing coverage (verified)

- Flat struct in Swift/Kotlin/C++
- Nested struct (nestedStructSpec — `Vector3`, `Quaternion`, `PackageDimensions`)
- Deeply nested (deeplyNestedStructSpec — Leaf→Mid→Root)
- `@ZeroCopy()` field
- Packed struct
- Positional / named / mixed constructor params

#### Missing struct tests

| Type | Expected | Test to add |
|---|---|---|
| Struct with `bool` field | Swift `Bool`, Kotlin `Boolean`, C++ `bool` | `struct_bool_field_test.dart` |
| Struct with `String` field | Swift `String`, Kotlin `String`, C++ `std::string` | `struct_string_field_test.dart` |
| Struct with `Uint8List` field (no zero-copy) | `Data` / `ByteArray` / `std::vector<uint8_t>` | `struct_typed_data_field_test.dart` |
| Struct with `Float32List` field | same pattern with `float` | same |
| Struct with nullable `int?` field | `Int64?` / `Long?` / `int64_t` | `struct_nullable_field_test.dart` |
| Struct with nullable `String?` field | `String?` / `String?` / `std::string` | same |
| Struct with `@HybridEnum` field | enum type in all targets | `struct_enum_field_test.dart` |
| Struct with `@HybridStruct` field (1-level) | ✓ nested_struct_test | — |
| Struct with `@HybridStruct` field (3-level) | ✓ struct_guard_test | — |
| Circular struct dependency A→B→A | emit E006 error | `struct_circular_test.dart` |
| Struct as function param across all 5 C++ platforms | same code | parameterize existing tests |

---

### 8.8 EnumGenerator

**File:** `enum_generator_test.dart`

#### Existing coverage (verified)

- `enum class` in Kotlin with `nativeValue`
- C-level `int64_t` enum mapping
- Swift enum cases

#### Missing enum tests

| Type | Expected | Test to add |
|---|---|---|
| Enum as named optional param `{Foo? e}` | Swift: `e: Foo? = nil`, Kotlin: `e: Foo? = null` | `enum_optional_param_test.dart` |
| Enum with non-zero `startValue` | first case = startValue in all targets | ✓ (test_utils `cppEnumSpec`) |
| Enum property (getter-only) | Swift `{ get }`, Kotlin `val`, C++ getter | `enum_property_test.dart` |
| Enum property (getter+setter) | Swift `{ get set }`, Kotlin `var`, C++ getter+setter | same |
| `Future<@HybridEnum>` return in Kotlin | `suspend : Foo` | `kotlin_async_enum_test.dart` |
| `Future<@HybridEnum>` return in Swift | `async throws -> Foo` | `swift_async_enum_test.dart` |
| `Stream<@HybridEnum>` | `Flow<Foo>` / `AnyPublisher<Foo, Never>` | `stream_enum_struct_test.dart` (partially ✓) |
| Nullable enum `Foo?` in Dart FFI | `Foo?` preserved | need test |

---

### 8.9 Platform-Targeting Tests

**File:** `platform_targeting_test.dart`

#### Tests to add

```dart
// All TypedData param types compile across all 5 C++ platforms
for (final spec in allCppPlatformSpecs()) {
  for (final (typeName, cType) in typedDataCppMappings) {
    test('$typeName param → $cType on ${spec.dartClassName}', () {
      final out = CppInterfaceGenerator.generate(
        spec.withFunction(typedDataParamFn(typeName)),
      );
      expect(out, contains(cType));
    });
  }
}

// Swift generator works for both iOS and macOS targets independently
test('macOS Swift generator emits same protocol as iOS', () {
  final iosOut = SwiftGenerator.generate(simpleSpec()); // iosImpl: swift
  final macosOut = SwiftGenerator.generate(macosSimpleSpec()); // macosImpl: swift
  expect(iosOut, equals(macosOut)); // protocol is identical
});

// iOS C++ vs iOS Swift produce different bridge types
test('iOS C++ spec does not emit SwiftGenerator output', () {
  final spec = iosOnlyCppSpec();
  expect(spec.iosIsCpp, isTrue);
  // C++ interface should be emitted, not Swift protocol
  final cppOut = CppInterfaceGenerator.generate(spec);
  expect(cppOut, contains('class Hybrid'));
});

// Web WASM spec does not emit any native bridge
test('web-only spec has no native targets', () {
  final spec = webOnlySpec();
  expect(spec.targetsIos, isFalse);
  expect(spec.targetsAndroid, isFalse);
  expect(spec.targetsWindows, isFalse);
});
```

---

### 8.10 Validation / Error Tests

**File:** `spec_validator_test.dart` (extend existing)

```dart
group('Validation — default value bugs', () {
  test('W001: non-nullable int named param with no defaultLiteral emits W001', () {
    final spec = specWithDefaultlessIntNamedParam();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'W001'), isTrue);
  });

  test('W002: enum-typed named param with no defaultLiteral emits W002', () {
    final spec = specWithEnumNamedParam();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'W002'), isTrue);
  });

  test('W003: struct-typed named param with no defaultLiteral emits W003', () {
    final spec = specWithStructNamedParam();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'W003'), isTrue);
  });
});

group('Validation — type errors', () {
  test('E001: Map<int, String> (non-String key) emits E001', () {
    final spec = specWithMapIntKey();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'E001'), isTrue);
  });

  test('E001: dynamic param emits E001', () {
    final spec = specWithDynamicParam();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'E001'), isTrue);
  });

  test('E002: @nitroAsync on bool return emits E002', () {
    final spec = specWithNitroAsyncOnSync();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'E002'), isTrue);
  });

  test('E005: @ZeroCopy on String field emits E005', () {
    final spec = specWithZeroCopyOnString();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'E005'), isTrue);
  });

  test('E006: circular struct A → B → A emits E006', () {
    final spec = circularStructSpec();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'E006'), isTrue);
  });

  test('W004: Stream<T> without @NitroStream emits W004', () {
    final spec = streamWithoutAnnotationSpec();
    final errors = SpecValidator.validate(spec);
    expect(errors.any((e) => e.code == 'W004'), isTrue);
  });
});

group('Validation — passes (no false positives)', () {
  test('nullable named param {int? x} has no warning', () {
    final spec = specWithNullableIntNamedParam();
    final errors = SpecValidator.validate(spec);
    expect(errors.where((e) => e.severity == Severity.error), isEmpty);
  });

  test('Map<String, String> with isMap=true has no E001', () {
    final spec = specWithStringMapParam();
    final errors = SpecValidator.validate(spec);
    expect(errors.where((e) => e.code == 'E001'), isEmpty);
  });
});
```

---

## 9. New Spec Helpers for test_utils.dart

Add these to `packages/nitro_generator/test/test_utils.dart` alongside the
existing helpers. Each helper creates a minimal `BridgeSpec` for one type pattern.

```dart
// ── TypedData helpers ─────────────────────────────────────────────────────────

/// Typed-data variants and their expected C++ element types.
const typedDataCppMappings = [
  ('Uint8List',   'std::vector<uint8_t>'),
  ('Int8List',    'std::vector<int8_t>'),
  ('Int16List',   'std::vector<int16_t>'),
  ('Int32List',   'std::vector<int32_t>'),
  ('Uint16List',  'std::vector<uint16_t>'),
  ('Uint32List',  'std::vector<uint32_t>'),
  ('Float32List', 'std::vector<float>'),
  ('Float64List', 'std::vector<double>'),
  ('Int64List',   'std::vector<int64_t>'),
  ('Uint64List',  'std::vector<uint64_t>'),
];

BridgeSpec typedDataParamSpec(String typeName) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'send',
      cSymbol: 'mod_send',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'x', type: BridgeType(name: typeName))],
    ),
  ],
);

// ── Optional param helpers ────────────────────────────────────────────────────

BridgeSpec optionalBoolParamSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'run',
      cSymbol: 'mod_run',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'flag',
          type: BridgeType(name: 'bool?'),
          isNamed: true,
          isOptional: true,
        ),
      ],
    ),
  ],
);

BridgeSpec optionalDoubleParamSpec() => BridgeSpec(/* ... same pattern with double? */);

/// Spec with `{int x = 5}` — non-nullable int with a defaultLiteral.
/// Used to verify Bug 5.1 fix.
BridgeSpec defaultIntParamSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'connect',
      cSymbol: 'mod_connect',
      isAsync: true,
      returnType: BridgeType(name: 'bool'),
      params: [
        BridgeParam(
          name: 'x',
          type: BridgeType(name: 'int'),
          isNamed: true,
          isOptional: true,
          defaultLiteral: '5',     // ← new field, verifies Bug 5.1
        ),
      ],
    ),
  ],
);

/// Spec with {EnumType e = E.value} — Bug 5.2.
BridgeSpec defaultEnumParamSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  enums: [
    BridgeEnum(name: 'Quality', startValue: 0, values: ['low', 'normal', 'high']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'print',
      cSymbol: 'mod_print',
      isAsync: true,
      returnType: BridgeType(name: 'bool'),
      params: [
        BridgeParam(
          name: 'quality',
          type: BridgeType(name: 'Quality'),
          isNamed: true,
          isOptional: true,
          defaultLiteral: 'Quality.normal',   // ← Bug 5.2
        ),
      ],
    ),
  ],
);

// ── Async return type helpers ─────────────────────────────────────────────────

BridgeSpec asyncUint8ListReturnSpec() => BridgeSpec(
  dartClassName: 'Mod', lib: 'mod', namespace: 'mod',
  iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getData', cSymbol: 'mod_get_data',
      isAsync: true, returnType: BridgeType(name: 'Uint8List'), params: [],
    ),
  ],
);

BridgeSpec asyncStructReturnSpec() => BridgeSpec(
  dartClassName: 'Mod', lib: 'mod', namespace: 'mod',
  iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  structs: [
    BridgeStruct(name: 'Reading', packed: false, fields: [
      BridgeField(name: 'value', type: BridgeType(name: 'double')),
    ]),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fetch', cSymbol: 'mod_fetch',
      isAsync: true, returnType: BridgeType(name: 'Reading'), params: [],
    ),
  ],
);

// ── Stream item type helpers ──────────────────────────────────────────────────

BridgeSpec streamSpec(String itemTypeName, {Backpressure backpressure = Backpressure.dropLatest}) =>
    BridgeSpec(
      dartClassName: 'Streamer', lib: 'streamer', namespace: 'streamer',
      iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin,
      sourceUri: 'streamer.native.dart',
      streams: [
        BridgeStream(
          dartName: 'events',
          registerSymbol: 'streamer_register_events_stream',
          releaseSymbol: 'streamer_release_events_stream',
          itemType: BridgeType(name: itemTypeName),
          backpressure: backpressure,
        ),
      ],
    );

// ── Validation error spec helpers ─────────────────────────────────────────────

BridgeSpec specWithDefaultlessIntNamedParam() => BridgeSpec(/* ... */);
BridgeSpec specWithEnumNamedParam() => BridgeSpec(/* ... */);
BridgeSpec specWithStructNamedParam() => BridgeSpec(/* ... */);
BridgeSpec specWithMapIntKey() => BridgeSpec(/* isMap=true but key type = int */);
BridgeSpec specWithDynamicParam() => BridgeSpec(/* type.name = 'dynamic' */);
BridgeSpec specWithNitroAsyncOnSync() => BridgeSpec(/* isAsync=true, returnType=bool */);
BridgeSpec specWithZeroCopyOnString() => BridgeSpec(/* zeroCopy=true on String field */);
BridgeSpec circularStructSpec() => BridgeSpec(/* A has field of type B, B has field of type A */);
BridgeSpec streamWithoutAnnotationSpec() => BridgeSpec(/* Stream<T> function, no NitroStream flag */);
BridgeSpec specWithNullableIntNamedParam() => BridgeSpec(/* {int? x} — must pass validation */);
BridgeSpec specWithStringMapParam() => BridgeSpec(/* Map<String,String> with isMap=true */);

// ── macOS Swift spec helper ───────────────────────────────────────────────────

BridgeSpec macosSimpleSpec() => BridgeSpec(
  dartClassName: 'MyCamera',
  lib: 'my_camera',
  namespace: 'my_camera_module',
  macosImpl: NativeImpl.swift,   // macOS only
  sourceUri: 'my_camera.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'add', cSymbol: 'my_camera_add', isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'a', type: BridgeType(name: 'double')),
        BridgeParam(name: 'b', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);
```

---

## 10. CLI Design — Dual-Mode Architecture

### Philosophy

The CLI is a first-class tool, not a `build_runner` wrapper. Two modes:

| Mode | Trigger | Output | Use case |
|---|---|---|---|
| **Terminal UI** (default) | `nitro generate` | Rich ANSI TUI | Local development |
| **Headless** | `nitro generate --no-ui` | Structured plain text | CI, scripts, IDE plugins |

Both modes have identical semantics. Exit codes are identical.
TTY auto-detection: if `stdout` is not a TTY, headless mode activates automatically.

### Command surface

```
nitro <command> [options]

Commands:
  generate        Generate bridge code from *.native.dart spec files
  doctor          Check environment (Dart SDK, flutter, nitro version, platform SDKs)
  clean           Delete all *.g.dart and *.bridge.g.* files + cache
  link            Register generated bridges with platform build systems

Options (generate):
  --watch         Rebuild on file changes (debounced 250ms)
  --no-ui         Headless output, no ANSI escape codes
  --output-dir    Override output directory for all generated files
  --verbose       Show per-file timing, full warning details
  --fail-on-warn  Exit non-zero on any warning (strict CI mode)
  --dry-run       Show what would be generated, write nothing
  --check         Compare existing files to what would be generated; exit 3 if stale
  --spec          Path glob for spec files (default: lib/**/*.native.dart)
  --targets       Comma-separated: dart,swift,kotlin,cpp (default: all)

Global options:
  --version       Print nitro version
  --help          Show help
```

---

## 11. Terminal UI Spec

Activated by default when `stdout` is a TTY.

```
┌─ Nitro Generator v0.4.0 ───────────────────────── dart 3.4 / flutter 3.22 ─┐
│                                                                              │
│  Scanning: lib/**/*.native.dart                              3 spec file(s) │
│                                                                              │
│  ▶ nitro_printing.native.dart                                                │
│    ├ Dart             nitro_printing.g.dart                      ✓  42ms    │
│    ├ Swift (iOS)      ios/Classes/nitro_printing.bridge.g.swift  ✓  38ms    │
│    ├ Swift (macOS)    macos/Classes/nitro_printing.bridge.g.swift ✓  11ms   │
│    └ Kotlin           android/…/nitro_printing.bridge.g.kt       ✓  29ms    │
│                                                                              │
│  ⚠  1 warning                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ W001  nitro_printing.native.dart:109                                │    │
│  │   Default value `5` for `timeoutSeconds` (type int) was dropped.   │    │
│  │   The generated impl will not compile.                              │    │
│  │   Fix → change to `int? timeoutSeconds` and handle default natively │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Generated 4 files in 120ms — 0 errors, 1 warning                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Colour coding

| Symbol | Colour | Meaning |
|---|---|---|
| `✓` | Green | File generated successfully |
| `⚠` | Yellow | Warning — generated but has issue |
| `✗` | Red | Error — file not generated |
| `▶` | Blue | Spec file currently being processed |
| `…` spinner | Cyan | In progress |

Degrades to headless automatically when stdout is not a TTY.

---

## 12. Headless / CI Mode Spec

Activated by `--no-ui` or when stdout is not a TTY.

```
[nitro] scanning: 3 spec file(s)
[nitro] ok    nitro_printing.g.dart (42ms)
[nitro] ok    ios/Classes/nitro_printing.bridge.g.swift (38ms)
[nitro] ok    macos/Classes/nitro_printing.bridge.g.swift (11ms)
[nitro] ok    android/…/nitro_printing.bridge.g.kt (29ms)
[nitro] warn  nitro_printing.native.dart:109 [W001] default value `5` for `timeoutSeconds` (int) dropped — use `int? timeoutSeconds`
[nitro] done  4 files, 0 errors, 1 warning (120ms)
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, no errors |
| `1` | One or more errors (file not generated) |
| `2` | Warnings only (only non-zero when `--fail-on-warn`) |
| `3` | `--check` mode: generated files are stale |
| `4` | Environment error (Dart SDK not found, etc.) |

### GitHub Actions integration

```yaml
- name: Generate Nitro bridges
  run: nitro generate --no-ui --fail-on-warn

- name: Check bridges are committed
  run: nitro generate --no-ui --check
```

---

## 13. Watch Mode

```
nitro generate --watch

[nitro] watching lib/**/*.native.dart for changes. Ctrl+C to stop.

[12:34:01] change: nitro_printing.native.dart
[12:34:01] generating…
[12:34:01] ok    nitro_printing.g.dart (39ms)
[12:34:01] ok    ios/Classes/nitro_printing.bridge.g.swift (34ms)
[12:34:01] ok    android/…/nitro_printing.bridge.g.kt (27ms)
[12:34:01] done  3 files, 0 errors (100ms)
```

- **Debounce**: 250ms after last filesystem event
- **Incremental**: only regenerate bridges for the changed spec file
- **Error persistence**: keep watching after generation error
- **Signal handling**: `SIGINT`/`Ctrl+C` → clean exit; `SIGHUP` → restart watch

---

## 14. Incremental Generation

**Problem:** Full regeneration on every run is slow for multi-spec projects.

**Solution:** Content-hash (SHA-256) based caching.

```
.dart_tool/nitro/
  cache.json    ← { "specFile": { "hash": "abc123", "outputFiles": [...] } }
```

**Algorithm:**
1. Hash every `*.native.dart` spec file.
2. Compare against `cache.json`.
3. Only regenerate bridges for changed spec files.
4. Update `cache.json` after generation.
5. `--clean` / `nitro clean` deletes `cache.json` to force full regen.

| Scenario | Full regen | Incremental |
|---|---|---|
| 1 spec changed out of 7 | 7× cost | 1× cost |
| No changes | 7× cost | Near zero |

---

## 15. Developer Experience Improvements

### `nitro doctor`

```
nitro doctor

  ✓ Dart 3.4.0
  ✓ Flutter 3.22.0
  ✓ nitro 0.4.0
  ✓ nitrogen_cli 0.4.0
  ✓ Xcode 16.2 (iOS + macOS available)
  ✓ Android NDK r26c
  ✗ CMake 3.28 — not found (required for C++ targets)
    Fix: brew install cmake
  ⚠ nitrogen_cli 0.4.0 < 0.4.1 (latest)
    Run: dart pub global activate nitrogen_cli
```

### `nitro clean`

```
nitro clean
  Deleted: nitro_printing.g.dart
  Deleted: ios/Classes/nitro_printing.bridge.g.swift
  Deleted: android/…/nitro_printing.bridge.g.kt
  Deleted cache (.dart_tool/nitro/cache.json)
  3 generated files removed.
```

### `--dry-run`

Shows what would be generated without writing any file.

### `--check` (CI freshness gate)

```
nitro generate --check
  ✓ nitro_printing.g.dart
  ✗ ios/Classes/nitro_printing.bridge.g.swift — STALE (spec changed)
  1 file(s) out of date. Re-run `nitro generate` and commit.
```
Exit code `3`.

### `--targets` (partial generation)

```
# Only regenerate Dart + Kotlin — skip Swift for faster Android-only iteration
nitro generate --targets dart,kotlin
```

### `--verbose` (per-phase timing)

```
nitro generate --verbose
  nitro_printing.native.dart
    parse spec          3ms
    validate            1ms
    emit dart          38ms
    emit swift (ios)   34ms
    emit kotlin        27ms
    write files         4ms
    total             107ms
```

---

## 16. Implementation Roadmap

### Phase 1 — P0: Generator correctness

| Task | Status | Done when |
|---|---|---|
| Add `defaultLiteral: String?` to `BridgeParam` | ✅ **DONE** 2026-05-22 | field exists in model |
| `spec_extractor.dart` captures default literal from Dart AST | ✅ **DONE** 2026-05-22 | `p.defaultValueCode` propagated |
| `DartFfiGenerator` emits `{int x = 5}` when `defaultLiteral` set | ✅ **DONE** 2026-05-22 | `optional_param_defaults_test` passes |
| `SwiftGenerator` emits `x: Int64 = 5` when `defaultLiteral` set | ⚠️ N/A — Swift protocols don't allow default values | — |
| `KotlinGenerator` emits `x: Long = 5` when `defaultLiteral` set | ⚠️ N/A — Dart side manages defaults for bridge | — |
| Same for bool, double, String defaults | ✅ **DONE** 2026-05-22 | all tested in `optional_param_defaults_test` |
| Same for enum defaults (Bug 5.2) | ✅ **DONE** 2026-05-23 | `dart_ffi_param_return_test.dart` Bug 5.2 group (3 tests) |
| Validation emits W001 when `defaultLiteral` is null on non-nullable optional param | ✅ **DONE** 2026-05-22 | 7 W001 tests in `spec_validator_test` pass |
| All new spec helpers in `test_utils.dart` added (§9) | ✅ **DONE** 2026-05-23 | `typedDataCppMappings`, `streamSpec`, `specWithDefaultlessIntNamedParam`, `specWithEnumNamedParam` added |
| All P0 missing tests from §8.1–8.3 added | ✅ **DONE** 2026-06-19 | full generator suite green (`2646` passing) |

### Phase 2 — P1: Type completeness

| Task | Status | Done when |
|---|---|---|
| All 10 TypedData variant tests — Swift | ✅ **DONE** 2026-05-22 | `type_mapping_swift_test` (64 tests) |
| All 10 TypedData variant tests — Kotlin | ✅ **DONE** 2026-05-22 | `type_mapping_kotlin_test` (50 tests) |
| All 10 TypedData variant tests — C++ | ✅ **DONE** 2026-05-22 | `cpp_type_mapping_test` (35 tests) |
| All stream item types tested (§3.10) — Swift + Kotlin | ✅ **DONE** 2026-05-22 | `stream_all_types_test` (27 tests) |
| All property types tested (§3.11) — Swift + Kotlin + C++ | ✅ **DONE** 2026-05-22 | `property_all_types_test` (42 tests) |
| Async return types fully tested (§3.9) — Swift + Kotlin + Dart | ✅ **DONE** 2026-06-19 | `async_return_types_test`, `dart_ffi_param_return_test`, `swift_typed_data_async_test`; async TypedData returns now verify decode/copy/free path |
| Nullable param/return types tested — Swift + Kotlin | ✅ **DONE** 2026-05-22 | Sections 3–4 of `type_mapping_swift/kotlin_test` |
| Struct with every field type variant (§3.5) | ✅ **DONE** 2026-05-23 | `struct_field_types_test.dart` kitchen-sink covers all types in Swift/Kotlin/C++ |
| Record with every field type variant (§3.6) | ✅ **DONE** 2026-05-23 | `record_field_types_test.dart` (56 tests): bool/double/Uint8List/List<T>/Swift boilerplate |
| Source-map comments emitted in all generators | ✅ **DONE** 2026-05-23 | `source_map_comments_test.dart` (13 tests); Swift/Kotlin/C++ emit `// source: file:line` when lineNumber non-null |

### Phase 2.5 — P1: Generator facade architecture

| Task | Status | Done when |
|---|---|---|
| Move native generators from flat files into language folders | ✅ **DONE** 2026-06-19 | `generators/languages/{dart,kotlin,swift,c_bridge,cpp_native,cmake}/` owns language-specific generators |
| Add facade/model layer for generator isolation and future language support | ✅ **DONE** 2026-06-19 | `native_generator_facade.dart`, `native_generator_model.dart`, and per-language `*_generator_bundle.dart` files |
| Add typed writer/model for generated code assembly | ✅ **DONE** 2026-06-19 | `code_writer.dart` with `CodeNode`, `CodeFile`, `CodeLine`, `CodeBlock`, `CodeWriter` |
| Remove raw `StringBuffer(` usage from language generator emitters | ✅ **DONE** 2026-06-19 | `rg "StringBuffer\\(" packages/nitro_generator/lib/src/generators/languages` returns no matches |
| Fix required `BridgeFunction(isAsync: ...)` constructor fallout in existing tests | ✅ **DONE** 2026-06-19 | full generator suite compiles and passes |
| Add tests for facade and typed writer isolation | ✅ **DONE** 2026-06-19 | `code_writer_test.dart`, `native_generator_facade_test.dart` |
| Verify generator suite after architecture move | ✅ **DONE** 2026-06-19 | direct Dart SDK test run: `2646: All tests passed!` |

### Phase 3 — P1: CLI modes

| Task | Status | Done when |
|---|---|---|
| `nitro generate --no-ui` headless mode | ✅ **DONE** 2026-05-23 | `[nitro]` prefix lines, no ANSI; `generate_command.dart` |
| TTY auto-detection | ✅ **DONE** 2026-05-23 | `_headless` getter checks `!stdout.hasTerminal`; auto-activates in CI |
| `--check` mode | 🔲 TODO | exit code 3 when stale |
| `--fail-on-warn` flag | ✅ **DONE** 2026-05-23 | exit code 2 on `[WARNING]` lines; `runStreamingInspected` in `ui.dart` |
| `--dry-run` flag | 🔲 TODO | no files written, paths listed |

### Phase 4 — P1: Validation pass

| Task | Status | Done when |
|---|---|---|
| `SpecValidator.validate()` returns typed `ValidationIssue` list | ✅ Already exists | — |
| W001: non-nullable named param with no default | ✅ **DONE** 2026-05-22 | 7 tests passing |
| E001: unsupported Map key type | ✅ **DONE** 2026-05-23 | `spec_validator_complete_test.dart` (8 E001 tests) |
| E002: `@nitroAsync` on non-Future return | ✅ **DONE** 2026-05-23 | `spec_validator_complete_test.dart` (9 E002 tests) |
| E005: `@ZeroCopy` on non-TypedData | ✅ **DONE** (exists as INVALID_ZERO_COPY) | `spec_validator_test.dart` covers it |
| W002/W003: enum/struct-typed default param | ✅ **DONE** 2026-05-23 | `spec_validator_complete_test.dart` (16 W002/W003 tests) |
| W004: `Stream<T>` without `@NitroStream` | ✅ **DONE** 2026-05-23 | `spec_validator_complete_test.dart` W004 group (8 tests); `BridgeStream.isAnnotated` flag in bridge_spec + extractor |
| Validation runs before any file is written | ✅ **DONE** 2026-05-23 | `builder_validation_gate_test.dart` (13 tests) |

### Phase 5 — P2: Terminal UI

| Task | Status | Done when |
|---|---|---|
| Full TUI with per-file progress | 🔲 TODO | layout matches §11 spec |
| Spinner during in-progress generation | 🔲 TODO | animated while writing |
| Colour-coded results | 🔲 TODO | per §11 colour table |
| Error detail box with fix hint | 🔲 TODO | W001/E001 shown with actionable message |

### Phase 6 — P2: Performance

| Task | Status | Done when |
|---|---|---|
| Content-hash incremental generation | 🔲 TODO | only changed spec regenerated |
| `nitro clean` command | ✅ **DONE** 2026-05-23 | `clean_command.dart`; deletes `*.g.dart`, `*.bridge.g.swift`, `*.bridge.g.kt`, `Hybrid*.hpp/cpp`, `*.bridge.g.h`, build_runner lock+graph |
| `--targets` partial generation | 🔲 TODO | only specified platforms emitted |
| `--watch` with 250ms debounce | 🔲 TODO | triggers correctly on single file save |

### Phase 7 — P3: Developer tools

| Task | Status | Done when |
|---|---|---|
| `nitro doctor` environment check | ✅ **DONE** (pre-existing) | `doctor_command.dart`; checks Xcode, clang++, Android NDK, CMake, build system wiring |
| `--verbose` timing breakdown | ✅ **DONE** 2026-05-23 | `-v`/`--verbose` flag; `⏱  pub get/build_runner/total: Xs` after each phase |
| Struct-typed default params (Bug 5.3) | ✅ **DONE** 2026-05-23 | `dart_ffi_param_return_test.dart` Bug 5.3 group (2 tests); same `defaultLiteral` mechanism as 5.1/5.2 |
| `Map<String,V>` where V is `@HybridRecord` | ✅ **DONE** 2026-05-23 | `map_hybrid_record_test.dart` (9 tests) — already tracked in §3.7 |

---

## Appendix A: Historical Workarounds

Phase 1 default-literal bugs are fixed. Keep these patterns only as fallback
guidance for older generated code or projects pinned to an older Nitro version.

### Optional param with int/double/bool default → nullable

```dart
// Instead of:
@nitroAsync
Future<bool> testPrinterConnection(String printerId, {int timeoutSeconds = 5});

// Write:
@nitroAsync
Future<bool> testPrinterConnection(String printerId, {int? timeoutSeconds});
// Handle `timeoutSeconds ?? 5` in Swift/Kotlin native implementations.
```

### Enum-typed optional → nullable enum

```dart
// Instead of:
Future<PrintResult> printText(String text, {PrintQuality quality = PrintQuality.normal});

// Write:
Future<PrintResult> printText(String text, {PrintQuality? quality});
// Handle `quality ?? PrintQuality.normal` in native code.
```

### Unsupported `Map<K,V>` → struct or JSON string

```dart
// Instead of:
Future<bool> setMetadata(Map<String, String> meta);

// Option A — @HybridRecord (preserves type safety):
@HybridRecord()
class MetadataMap { final List<String> keys; final List<String> values; }
Future<bool> setMetadata(MetadataMap meta);

// Option B — JSON string (simple, but untyped):
Future<bool> setMetadata(String metaJson);   // caller: jsonEncode(map)
```

---

## Appendix B: Files Affected Per Plugin

| Plugin | Spec file | Generated files |
|---|---|---|
| `nitro_printing` | `lib/src/nitro_printing.native.dart` | `nitro_printing.g.dart`, `*.bridge.g.swift` (iOS + macOS), `*.bridge.g.kt` |
| `nitro_torch` | `lib/src/nitro_torch.native.dart` | same pattern |
| `nitro_vani_audio` | `lib/src/audio_capture.native.dart` | `audio_capture.g.dart`, `*.bridge.g.swift`, `*.bridge.g.kt` |
| `nitro_vani_core` | `lib/src/vani_core.native.dart` | `vani_core.g.dart`, `HybridVaniCore.hpp`, `HybridVaniCore.cpp` |

---

## Appendix C: Test File Index

### Pre-existing tests

| Test file | What it covers |
|---|---|
| `dart_ffi_generator_test.dart` | Dart _Impl class generation for all types |
| `dart_ffi_generator_record_test.dart` | Record type Dart generation |
| `swift_generator_test.dart` | Swift protocol + @_cdecl stubs |
| `kotlin_generator_test.dart` | Kotlin interface + JniBridge |
| `cpp_interface_generator_test.dart` | C++ pure-virtual interface |
| `cpp_bridge_generator_test.dart` | C++ bridge impl |
| `cpp_header_generator_test.dart` | C++ header file |
| `cpp_mock_generator_test.dart` | C++ mock class |
| `record_generator_test.dart` | @HybridRecord Dart + Kotlin |
| `struct_generator_test.dart` | @HybridStruct all targets |
| `struct_field_types_test.dart` | Every field type in structs |
| `struct_constructor_params_test.dart` | Positional/named/mixed constructor |
| `enum_generator_test.dart` | @HybridEnum all targets |
| `nullable_types_test.dart` | `T?` in all generators |
| `optional_param_test.dart` | `{T? x}` named optional params |
| `stream_backpressure_test.dart` | dropLatest / block / dropOldest |
| `stream_enum_struct_test.dart` | Stream with enum/struct item types |
| `nested_struct_test.dart` | Nested @HybridStruct |
| `platform_targeting_test.dart` | Per-platform code emission |
| `spec_validator_test.dart` | Validation errors; W001 added 2026-05-22 |
| `pointer_support_test.dart` | `Pointer<T>` raw FFI |
| `zero_copy_typed_test.dart` | `@ZeroCopy()` TypedData |
| `typed_list_bridge_test.dart` | TypedData in bridge |
| `edge_cases_test.dart` | Empty spec, no-function spec, etc. |

### New tests added 2026-06-19 (architecture/facade; suite: 2646 passing — 0 failures)

| Test file | What it covers |
|---|---|
| `code_writer_test.dart` | Typed code writer primitives: lines, blank lines, raw snippets, blocks, and file assembly |
| `native_generator_facade_test.dart` | Facade/bundle dispatch and language-target isolation for generated native outputs |
| Existing generator tests updated | `BridgeFunction(isAsync: ...)` required constructor argument added across helpers/tests; all existing generator coverage compiles |

### New tests added 2026-06-19 (performance/correctness; focused suites green)

| Test file | What it covers |
|---|---|
| `dart_ffi_param_return_test.dart` | Async `Uint8List` and `Float32List` returns decode from a malloc-owned `[int64 byteLength][payload]` envelope and free native memory |
| `swift_typed_data_async_test.dart` | Swift async/sync TypedData returns allocate the same C-`malloc` length-prefixed envelope for Dart |
| `cpp_bridge_types_test.dart` | JNI TypedData returns copy JVM primitive arrays into the length-prefixed envelope |
| `jni_perf_test.dart` | Assert-gated `NitroRuntime.checkError`, cached JNI IDs, arena lifetime, and unknown JNI type failure |
| `lazy_record_list_test.dart` | `RecordWriter` growable buffer and `RecordReader` in-place scalar/string decode performance guards |
| `link_command_test.dart` | Contextual errors for malformed `package_config.json` while resolving Nitro native paths |

### New tests added 2026-05-23 (total: ~119 new tests; suite: 1991 passing — 0 failures)

| Test file | Tests | What it covers |
|---|---|---|
| `spec_validator_complete_test.dart` | 41 | E001 (non-String Map key), E002 (async non-Future), W002 (enum named param), W003 (struct named param), W004 (Stream without @NitroStream), mixed |
| `record_field_types_test.dart` | 56 | bool/double/Uint8List fields; List<String/double/bool>; Swift struct boilerplate; multi-field ordering |
| `source_map_comments_test.dart` | 13 | Swift protocol + @_cdecl stubs, Kotlin interface + JniBridge, C++ virtual methods — `// source: file:line` present/absent |
| `map_hybrid_record_test.dart` | 9 | Map<String,@HybridRecord> return + param → JSON path (Pointer<Utf8>, jsonDecode/jsonEncode, no RecordExt) |

### New tests added 2026-05-22 (total: 278 new tests; suite: 1864 passing)

| Test file | Tests | What it covers |
|---|---|---|
| `type_mapping_swift_test.dart` | 64 | All Swift type mappings: scalars, 10 TypedData variants, nullable, enum, struct, properties, async, macOS |
| `type_mapping_kotlin_test.dart` | 50 | All Kotlin type mappings: scalars, 10 TypedData variants, nullable params, enum, struct, properties, Flow, suspend |
| `stream_all_types_test.dart` | 27 | Stream item types Swift (AnyPublisher + @_cdecl) and Kotlin (Flow) for all 7 item types |
| `async_return_types_test.dart` | 28 | Future<T> in Swift (async throws + semaphore), Kotlin (suspend + runBlocking), Dart FFI |
| `optional_param_defaults_test.dart` | 24 | Named param handling, Bug 5.1 documented & fixed (defaultLiteral), nullable workaround |
| `property_all_types_test.dart` | 42 | Property types (bool/int/double/String/enum/struct) in Swift, Kotlin, and C++; read-only vs read-write |
| `cpp_type_mapping_test.dart` | 35 | C++ interface: all scalar types, 10 TypedData → pointer+length, nullable stripping, enum/struct, boilerplate |

---

*Plan authored 2026-05-22. Updated 2026-06-19 with Phase 2.5 generator facade architecture and latest passing suite count.
Ground-truthed against `packages/nitro_generator/` source.
Revisit §4 Type Mapping tables after each Nitro generator release.*
