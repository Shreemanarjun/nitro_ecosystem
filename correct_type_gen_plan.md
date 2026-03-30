# Correct Type Generation Plan

> We need to make sure all the types are generated in native side and dart side correctly.

> We need to add end to end integration test for all the types.

---

## Overview

This plan audits every type category across all 6 generators and adds a dedicated `type_coverage` module that exercises every type combination end-to-end on real devices/simulators.

---

## 1. Type Inventory

### 1.1 Primitives

| Dart | C++ (bridge) | Kotlin | Swift | FFI native | FFI Dart |
|------|-------------|--------|-------|-----------|---------|
| `int` | `int64_t` | `Long` | `Int64` | `Int64` | `int` |
| `double` | `double` | `Double` | `Double` | `Double` | `double` |
| `bool` | `int8_t` | `Boolean` | `Bool` | `Int8` | `int` → `bool` |
| `String` | `const char*` | `String` | `String` | `Pointer<Utf8>` | `Pointer<Utf8>` |
| `void` | `void` | `Unit` | `Void` | `Void` | `void` |

**Status: ✅ All generators handle these.**

### 1.2 TypedData (Zero-copy capable)

| Dart | C++ param | Kotlin (plain) | Kotlin (@ZeroCopy) | Swift | FFI |
|------|-----------|----------------|-------------------|-------|-----|
| `Uint8List` | `uint8_t* + int64_t len` | `ByteArray` | `java.nio.ByteBuffer` | `UnsafeMutablePointer<UInt8>?` | `Pointer<Uint8> + Int64` |
| `Int8List` | `int8_t* + len` | `ByteArray` | `java.nio.ByteBuffer` | `UnsafeMutablePointer<Int8>?` | `Pointer<Int8> + Int64` |
| `Int16List` | `int16_t* + len` | `ShortArray` | — | `UnsafeMutablePointer<Int16>?` | `Pointer<Int16> + Int64` |
| `Int32List` | `int32_t* + len` | `IntArray` | — | `UnsafeMutablePointer<Int32>?` | `Pointer<Int32> + Int64` |
| `Uint16List` | `uint16_t* + len` | `ShortArray` | — | `UnsafeMutablePointer<UInt16>?` | `Pointer<Uint16> + Int64` |
| `Uint32List` | `uint32_t* + len` | `IntArray` | — | `UnsafeMutablePointer<UInt32>?` | `Pointer<Uint32> + Int64` |
| `Float32List` | `float* + len` | `FloatArray` | `java.nio.ByteBuffer` | `UnsafeMutablePointer<Float>?` | `Pointer<Float> + Int64` |
| `Float64List` | `double* + len` | `DoubleArray` | — | `UnsafeMutablePointer<Double>?` | `Pointer<Double> + Int64` |
| `Int64List` | `int64_t* + len` | `LongArray` | — | `UnsafeMutablePointer<Int64>?` | `Pointer<Int64> + Int64` |
| `Uint64List` | `uint64_t* + len` | `LongArray` | — | `UnsafeMutablePointer<UInt64>?` | `Pointer<Uint64> + Int64` |

**Status: ✅ All 10 variants generated correctly. @ZeroCopy only applies to `Uint8List` and `Float32List` in Kotlin (ByteBuffer path); others fall through to array copy.**

### 1.3 @HybridEnum

- Dart: `int get nativeValue` extension, `int.toEnumName()` extension
- C++ JNI bridge: `int64_t` (JNI `J` sig) — maps to `Long` in Kotlin
- C++ direct: `enum ClassName` in interface header
- Kotlin: enum class with `nativeValue: Long` companion + `fromNative(Long)` factory
- Swift: Swift enum with `nativeValue: Int64` and `init(nativeValue:)`
- FFI: `Int64` native / `int` Dart, decode via `.toEnumName()`

**Status: ✅ Correct across all generators.**

Known gap: `@HybridEnum` values inside `@HybridRecord` fields are not supported (records only handle primitive/String/nested record fields).

### 1.4 @HybridStruct

Flat C memory layout — fields can be: `int`, `double`, `bool`, `String`, or any TypedData.

- Generated: `StructNameFfi` NativeStruct in Dart, `toNative()` / `toDart()` extensions
- Kotlin: data class with JNI field mappings
- Swift: Swift struct with `@_cdecl` C bridge
- C++ direct: plain C `struct` in header

**Status: ✅ Correct for primitive fields. `String` fields in a struct cause a C layout ambiguity (pointer vs inline bytes) — currently generates `const char*` in C. Rule: don't put `String` in a `@HybridStruct`; use `@HybridRecord` instead.**

### 1.5 @HybridRecord (binary-serialized)

Binary wire format: `[4-byte payload_len][fields...]` where each field is encoded by type.

| Field kind | Wire format |
|-----------|-------------|
| `int` | 8 bytes LE int64 |
| `double` | 8 bytes LE double |
| `bool` | 1 byte (0/1) |
| `String` | 4-byte LE length + UTF-8 bytes |
| nested `@HybridRecord` | inline fields (no extra length header) |
| `List<@HybridRecord T>` | 4-byte count + T fields repeated |
| `List<primitive>` | 4-byte count + element encoding |
| nullable any | 1-byte null-tag, then value if non-null |

**Status: ✅ Supported. Gaps:**
- `List<String>` — listed as `listPrimitive` but Kotlin/Swift serializers need to use `writeString`/`readString`; needs explicit test
- `List<int>` / `List<double>` / `List<bool>` — primitive list paths exist but lack generator tests per item type
- `Map<String, V>` — JSON string bridge; only `Map<String, dynamic>` decode works at Dart side

### 1.6 Nullable Types (`T?`)

- Dart FFI signatures preserve `?` for primitives/String/TypedData
- C++ interface: strips `?` (all by value/pointer)
- Kotlin: appends `?` for complex types, `Long?` for nullable int
- Swift: appends `?`
- `@HybridRecord` fields: 1-byte null tag on wire

**Status: ✅ Nullable primitives and record fields work. Gap: nullable `@HybridStruct` params/returns have no null-pointer guard in the C++ bridge.**

### 1.7 Async (`Future<T>` via `@nitroAsync`)

- Dart: `NitroRuntime.callAsync<T>` on background isolate
- Kotlin: `_asyncExecutor.submit { runBlocking { impl.method() } }.get()`
- Swift: `Task.detached { try await impl.method() }` (no error propagation to Dart on Swift yet)
- C++ direct: sync call wrapped in async dispatch at Dart side

**Status: ✅ Works for all return types except: async TypedData return (no generator path for async `Uint8List` return — falls through to `Pointer<Void>` which is wrong).**

### 1.8 Streams (`Stream<T>` via `@NitroStream`)

Item types supported:
- Primitives: `double`, `int`, `bool`, `String` — sent as raw Dart_CObject value via SendPort
- `@HybridStruct`: malloc'd pointer, address sent as int, Dart reconstructs + frees
- `@HybridRecord`: malloc'd binary buffer, address sent as int, Dart reconstructs + frees
- `@HybridEnum`: int value sent, Dart converts

**Status: ✅ Struct streams work. Gap: enum stream items, record stream items, and String stream items are untested in generators.**

### 1.9 Properties

- Read-only: generates only getter C symbol
- Write-only: generates only setter C symbol
- Read-write: both getter + setter

**Status: ✅ All property types work.**

### 1.10 Pointer Types (`Pointer<T>`)

Raw FFI pass-through — works as param and return. Not supported as record/struct field.

**Status: ✅**

---

## 2. Generator Gap Summary

### `spec_extractor.dart`
- [ ] `List<bool>` / `List<String>` / `List<double>` inside `@HybridRecord`: classifies as `listPrimitive` — correct in code but **needs tests**
- [ ] `@HybridEnum` field inside `@HybridRecord`: classified as `primitive` — wire encoder won't know to call `nativeValue` — **bug, needs `RecordFieldKind.enumValue`**

### `dart_ffi_generator.dart`
- [ ] Async `Uint8List` / `Float32List` return: `callAsyncType` falls through to wrong type — **bug**
- [ ] Stream `String` item: `unpackExpr` emits `rawPtr as String` — **bug**
- [ ] Stream `bool` item: `rawPtr as bool` — **bug**
- [ ] Nullable `@HybridStruct` param: no null guard before `.toNative(arena)` — **potential crash**

### `kotlin_generator.dart`
- [ ] Stream item type for `@HybridRecord`: `emit_streamName` external fun uses record class type but should use `ByteArray` wire type — **check if records can be stream items currently**

### `swift_generator.dart`
- [ ] Async methods: errors from `async throws` are silently dropped — **document limitation or add error forwarding**
- [ ] Stream `String` / `bool` / `enum` items: `@_cdecl` bridge type not verified — **needs test**

### `cpp_bridge_generator.dart` (JNI path)
- [ ] `bool` param via JNI: `int8_t` from Dart should map to `jboolean` (sig `Z`), not `jbyte` (sig `B`) — **potential type mismatch on Android**

---

## 3. Dedicated Integration Test Module: `type_coverage`

### 3.1 `type_coverage/lib/src/type_coverage.native.dart`

```dart
import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'type_coverage.g.dart';

// ── Enums ─────────────────────────────────────────────────────────────────────
@HybridEnum(startValue: 0)
enum Status { idle, running, error }

@HybridEnum(startValue: 10)
enum Priority { low, medium, high }

// ── Structs ───────────────────────────────────────────────────────────────────
@HybridStruct()
class Point {
  final double x;
  final double y;
  final double z;
  const Point({required this.x, required this.y, required this.z});
}

@HybridStruct(packed: true)
class PackedStats {
  final int count;
  final double average;
  final bool valid;
  const PackedStats({required this.count, required this.average, required this.valid});
}

@HybridStruct(zeroCopy: ['data'])
class RawBuffer {
  final Uint8List data;
  final int length;
  const RawBuffer({required this.data, required this.length});
}

// ── Records ───────────────────────────────────────────────────────────────────
@HybridRecord()
class SimpleRecord {
  final int id;
  final double value;
  final bool active;
  final String label;
  const SimpleRecord({required this.id, required this.value, required this.active, required this.label});
}

@HybridRecord()
class NestedRecord {
  final String name;
  final SimpleRecord inner;
  final List<SimpleRecord> items;
  const NestedRecord({required this.name, required this.inner, required this.items});
}

@HybridRecord()
class PrimitiveLists {
  final List<int> ints;
  final List<double> doubles;
  final List<bool> bools;
  final List<String> strings;
  const PrimitiveLists({required this.ints, required this.doubles, required this.bools, required this.strings});
}

@HybridRecord()
class NullableFields {
  final int? maybeInt;
  final String? maybeString;
  final SimpleRecord? maybeRecord;
  const NullableFields({this.maybeInt, this.maybeString, this.maybeRecord});
}

// ── Module ────────────────────────────────────────────────────────────────────
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class TypeCoverage extends HybridObject {
  static final TypeCoverage instance = _TypeCoverageImpl();

  // ── Primitives (sync) ──────────────────────────────────────────────────────
  int echoInt(int value);
  double echoDouble(double value);
  bool echoBool(bool value);
  String echoString(String value);
  void noOp();

  // ── Primitives (async) ────────────────────────────────────────────────────
  @nitroAsync Future<int> asyncInt(int value);
  @nitroAsync Future<double> asyncDouble(double value);
  @nitroAsync Future<bool> asyncBool(bool value);
  @nitroAsync Future<String> asyncString(String value);

  // ── Enum (sync + async) ───────────────────────────────────────────────────
  Status echoStatus(Status value);
  Priority echoPriority(Priority value);
  @nitroAsync Future<Status> asyncStatus(Status value);

  // ── Struct (sync + async) ─────────────────────────────────────────────────
  Point echoPoint(Point value);
  PackedStats echoPackedStats(PackedStats value);
  @nitroAsync Future<Point> asyncPoint(Point value);

  // ── TypedData ─────────────────────────────────────────────────────────────
  Uint8List echoBytes(Uint8List data, int length);
  Float32List echoFloats(Float32List data, int length);
  @ZeroCopy() RawBuffer echoRawBuffer(@ZeroCopy() Uint8List data, int length);

  // ── Records (sync + async) ────────────────────────────────────────────────
  SimpleRecord echoSimple(SimpleRecord value);
  NestedRecord echoNested(NestedRecord value);
  PrimitiveLists echoPrimitiveLists(PrimitiveLists value);
  NullableFields echoNullable(NullableFields value);
  @nitroAsync Future<SimpleRecord> asyncSimple(SimpleRecord value);
  @nitroAsync Future<NestedRecord> asyncNested(NestedRecord value);
  @nitroAsync Future<List<SimpleRecord>> asyncRecordList();
  @nitroAsync Future<Map<String, dynamic>> asyncMap();

  // ── Properties ────────────────────────────────────────────────────────────
  int get counter;
  set counter(int value);
  double get scale;
  set scale(double value);
  bool get enabled;
  set enabled(bool value);
  String get tag;
  set tag(String value);
  Status get currentStatus;
  set currentStatus(Status value);

  // ── Streams ───────────────────────────────────────────────────────────────
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<double> get doubleStream;

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<int> get intStream;

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<Point> get pointStream;
}
```

### 3.2 Native Implementation Stubs (echo pattern)

Each method returns its input. Properties backed by private fields. Streams emit a single fixed value then close.

**Kotlin** (`TypeCoverageImpl.kt`): implement `HybridTypeCoverageSpec` — each `echo*` method returns its param, properties are `var` fields.

**Swift** (`TypeCoverageImpl.swift`): conform to `HybridTypeCoverageProtocol` — same echo logic, streams via `Just(value).eraseToAnyPublisher()`.

---

## 4. Unit Test Gaps to Fill (in `nitro_generator/test/`)

### 4.1 `record_primitive_list_test.dart`
- `List<int>` field → Kotlin `writeInt64`/`readInt64`, Dart `r.readInt()`, Swift `w.writeInt64`
- `List<double>` field → write/read double
- `List<bool>` field → write/read bool (1 byte)
- `List<String>` field → write/read string (length-prefixed UTF-8)
- `SimpleRecord?` nullable field → 1-byte null tag in all 3 serializers

### 4.2 `dart_ffi_all_types_test.dart`
Assert `lookupFunction` signature AND body for:

| Method | Expected FFI sig | Expected body fragment |
|--------|-----------------|----------------------|
| `bool echoBool(bool)` | `Int8 Function(Int8)` | `value ? 1 : 0` param, `res != 0` return |
| `Status echoStatus(Status)` | `Int64 Function(Int64)` | `.nativeValue` param, `.toStatus()` return |
| `Point echoPoint(Point)` | `Pointer<Void> Function(Pointer<Void>)` | `.toNative(arena).cast<Void>()` |
| `Uint8List echoBytes(Uint8List, int)` | `Pointer<Uint8> Function(Pointer<Uint8>, Int64)` | `data.toPointer(arena), data.length` |
| `Future<bool> asyncBool(bool)` | async callAsync + `res != 0` |
| `Future<Status> asyncStatus(Status)` | async callAsync + `.toStatus()` |
| `bool get enabled` | `Int8 Function()` lookup | `res != 0` |
| `set enabled(bool)` | `Void Function(Int8)` lookup | `value ? 1 : 0` |
| `Status get currentStatus` | `Int64 Function()` | `.toStatus()` |
| `set currentStatus(Status)` | `Void Function(Int64)` | `.nativeValue` |

### 4.3 `kotlin_all_types_test.dart`
- `echoBool`: interface `fun echoBool(value: Boolean): Boolean`, JniBridge `_call(value: Boolean): Boolean`
- `echoStatus`: interface returns `Status`, JniBridge `_call` returns `Long` (`.nativeValue`)
- `echoSimple`: interface returns `SimpleRecord`, JniBridge `_call` returns `ByteArray`
- `asyncSimple`: async executor path + `ByteArray` return
- `asyncRecordList`: count-prefixed `ByteArray`
- Property `enabled`: `Boolean` get/set
- Property `currentStatus`: `Long` bridge type, enum convert on get/set

### 4.4 `swift_all_types_test.dart`
- Protocol signatures for bool, enum, struct, record, async, stream types
- `@_cdecl` C bridge: bool → `Int8`, enum → `Int64`, struct → `UnsafeMutableRawPointer?`, record → `UnsafeMutablePointer<UInt8>?`
- Async: `Task.detached` present in output
- Stream `doubleStream` / `intStream`: `AnyCancellable` + `PassthroughSubject` or `AnyPublisher`

---

## 5. Bugs to Fix Before Integration Tests

### Bug 1: Stream `String` / `bool` / `int` unpack in `dart_ffi_generator.dart`
**Location:** stream `unpackExpr` block (non-struct, non-record branch)
**Problem:** emits `(rawPtr) => rawPtr as $itemType` — breaks for String, bool
**Fix:** Add per-type unpack: `String` → decode from Utf8 pointer, `bool` → `rawPtr != 0`, `int` → already int

### Bug 2: Async `Uint8List` return type in `dart_ffi_generator.dart`
**Location:** `callAsyncType` computation
**Problem:** TypedData async return has no decode path after `callAsync` completes
**Fix:** Add `isTypedData` branch with proper list reconstruction

### Bug 3: `bool` JNI sig mismatch in `cpp_bridge_generator.dart`
**Location:** `_jniSigType` / `_jniGetter` functions
**Problem:** `bool` should use `jboolean` (sig `Z`, `GetBooleanField`) not `jbyte` (sig `B`)
**Fix:** Verify `bool` → `Z` / `GetBooleanField` in the JNI bridge for Android

### Bug 4: `@HybridEnum` field inside `@HybridRecord`
**Location:** `spec_extractor.dart` `_recordFieldKind`, all 4 record serializers
**Problem:** enum field classified as `primitive` — serializers don't know to call `.nativeValue`
**Fix:** Add `RecordFieldKind.enumValue` + update Dart/Kotlin/Swift/C++ record serializers

---

## 6. Implementation Order

### Phase 1 — Bug Fixes
1. Fix Bug 3 (`bool` JNI sig) in `cpp_bridge_generator.dart`
2. Fix Bug 1 (stream String/bool unpack) in `dart_ffi_generator.dart`
3. Fix Bug 2 (async TypedData return) in `dart_ffi_generator.dart`
4. Fix Bug 4 (enum field in record) in `spec_extractor.dart` + all record serializers

### Phase 2 — Unit Test Coverage
1. `record_primitive_list_test.dart` — List<bool/double/String/int> and nullable record fields
2. `kotlin_all_types_test.dart` — remaining Kotlin type coverage
3. `swift_all_types_test.dart` — remaining Swift type coverage
4. `dart_ffi_all_types_test.dart` — remaining Dart FFI type/mode combos

### Phase 3 — Integration Module
1. Create `type_coverage/` Flutter plugin package
2. Write `type_coverage.native.dart` spec (see §3.1)
3. Run `dart run nitro_generator:build_runner build` — inspect all generated files
4. Implement `TypeCoverageImpl.kt` (echo logic)
5. Implement `TypeCoverageImpl.swift` (echo logic)
6. Run `dart run nitrogen_cli link`

### Phase 4 — Integration Test App
1. Add `type_coverage/example/` with `flutter_integration_test`
2. Assert round-trip for every method in the spec
3. Run on Android emulator + iOS simulator

---

## 7. Type × Generator Coverage Matrix

✅ = tested  ⬜ = missing  — = not applicable

| Type | DartFFI | Kotlin | Swift | CppBridge | CppIface | Record |
|------|---------|--------|-------|-----------|---------|--------|
| int sync | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| int async | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| double sync | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| bool sync | ✅ | ⬜ | ⬜ | ⬜ | ✅ | — |
| bool async | ⬜ | ⬜ | ⬜ | ⬜ | — | — |
| String sync | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| void | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| enum sync return | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| enum async return | ✅ | ✅ | ⬜ | ⬜ | — | — |
| enum param | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| enum property | ✅ | ✅ | ⬜ | ⬜ | — | — |
| struct sync | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| struct async | ✅ | ⬜ | ⬜ | ⬜ | — | — |
| struct param | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| Uint8List | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| Float32List | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| @ZeroCopy | ✅ | ✅ | ⬜ | ✅ | — | — |
| record sync | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| record async | ✅ | ✅ | ✅ | ✅ | — | — |
| record param | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| List<record> | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| List<int> in record | ⬜ | ⬜ | ⬜ | — | — | ⬜ |
| List<double> in record | ⬜ | ⬜ | ⬜ | — | — | ⬜ |
| List<bool> in record | ⬜ | ⬜ | ⬜ | — | — | ⬜ |
| List<String> in record | ⬜ | ⬜ | ⬜ | — | — | ⬜ |
| nullable record field | ⬜ | ⬜ | ⬜ | — | — | ⬜ |
| Map<String,dynamic> | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| stream double | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| stream int | ✅ | ✅ | ⬜ | ⬜ | ⬜ | — |
| stream struct | ✅ | ✅ | ⬜ | ✅ | ✅ | — |
| stream String | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| stream enum | ⬜ | ⬜ | ⬜ | ⬜ | ⬜ | — |
| int property | ✅ | ✅ | ⬜ | ✅ | — | — |
| bool property | ✅ | ⬜ | ⬜ | ⬜ | — | — |
| String property | ✅ | ✅ | ⬜ | ✅ | — | — |
| enum property | ✅ | ✅ | ⬜ | ⬜ | — | — |
| struct property | ⬜ | ⬜ | ⬜ | ⬜ | — | — |
| record property | ✅ | ⬜ | ⬜ | ⬜ | — | — |

---

## 8. File Locations

```
type_coverage/
  lib/src/
    type_coverage.native.dart      ← spec (new)
    type_coverage.g.dart           ← generated
  android/src/main/kotlin/nitro/type_coverage_module/
    TypeCoverageImpl.kt            ← echo impl (new)
  ios/Classes/
    TypeCoverageImpl.swift         ← echo impl (new)
  example/integration_test/
    type_coverage_test.dart        ← e2e assertions (new)

packages/nitro_generator/test/
  record_primitive_list_test.dart  ← new unit tests
  dart_ffi_all_types_test.dart     ← new unit tests
  kotlin_all_types_test.dart       ← new unit tests
  swift_all_types_test.dart        ← new unit tests
```
