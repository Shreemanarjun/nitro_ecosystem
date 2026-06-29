# Flutter Nitro — Limitations & Current Status

Comparison against React Native Nitro (`packages/react-native-nitro-modules`) as the reference implementation.  
Last updated: 2026-06-29. Generator unit tests: 3866. macOS integration tests: 601.

---

## Status Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Fully implemented and tested |
| 🔧 | Implemented, integration tests pending |
| 🚧 | In progress |
| ❌ | Not implemented |
| ⚠️ | Partial / platform-specific constraint |

---

## RN Nitro Feature Parity Map

| RN Nitro feature | Flutter Nitro equivalent | Status |
|-----------------|--------------------------|--------|
| `number` (`double`/`int`/`float`) | `int`, `double` | ✅ |
| `boolean` | `bool` | ✅ |
| `string` | `String` | ✅ |
| `bigint` (Int64) | `int` (Int64 wire) | ✅ |
| `bigint` (UInt64) | — | ❌ L13 |
| `T \| undefined` → `std::optional<T>` | `T?` → `NitroOptXxx` structs | ✅ |
| `T[]` → `std::vector<T>` | `List<T>` | ✅ |
| `Record<string, T>` → `std::unordered_map` | `Map<String, T>` | ✅ |
| `[A, B, C]` → `std::tuple<A, B, C>` | — | ❌ L12 |
| `A \| B \| C` → `std::variant<A,B,C>` | `@NitroVariant` | ✅ |
| `Date` → `std::chrono::time_point` | `DateTime` → `int64_t` ms-epoch | ✅ L11 |
| `ArrayBuffer` → `jsi::MutableBuffer` | `Uint8List` / TypedData | ✅ (via TypedData) |
| `AnyMap` → heterogeneous typed map | `NitroAnyMap` / `NitroAnyValue` | ✅ |
| `HybridObject<Platforms>` | `NativeImpl.swift` / `.kotlin` / `.cpp` | ✅ |
| `AnyHybridObject` (untyped ref) | — | ❌ L14 |
| `BoxedHybridObject<T>` (cross-runtime) | — | ❌ L15 |
| `CustomType<T>` + `JSIConverter<T>` | `NitroFfiCodec<T>` (partial) | ⚠️ L16 |
| `Promise<T>` | `Future<T>` / `@nitroAsync` / `NitroPromise<T>` | ✅ |
| Streams / Observables | `Stream<T>` via `@NitroStream` | ✅ (Flutter advantage) |
| `Sync<T>` callback tag | All callbacks are sync (NativeCallable) | ✅ (implicit) |
| Enum types | `@HybridEnum` | ✅ |
| Struct/record types | `@HybridStruct` + `@HybridRecord` | ✅ |
| Typed binary buffers | TypedData (`Uint8List` etc.) | ✅ |
| `HybridView` (native React component) | — (different paradigm) | N/A |
| Error handling via exceptions | `@NitroResult<T>` / `NitroError*` | ✅ (+ extra) |
| iOS + Android + macOS platforms | iOS + Android + macOS + Windows + Linux | ✅ (+ more) |
| Web | W007 warning, stub only | ⚠️ L8 |

---

## Fully Supported (✅)

### Primitives & Nullables
- `int`, `double`, `bool`, `String`, `void`, `DateTime` — all transports (sync, async, callback, stream, property)
- `int?`, `double?`, `bool?`, `DateTime?` — `NitroOptXxx` @Packed(1) structs; two-param callback approach
- `String?` — `nullptr` sentinel throughout

### Value Types
- `@HybridStruct` — zero-copy C POD structs; `NativeFinalizer`-backed lazy proxy for streams
- `@HybridRecord` — binary-encoded complex types; `[4B len][payload]` wire format
- `@HybridEnum` — `int64_t` wire; non-contiguous `nativeValues` (e.g., OS constants 0, 50, 100)
- `@NitroVariant` — sealed discriminated union; 1–255 cases; `[1B tag][fields]` wire

### Collections
- `List<primitive>` — all transports
- `List<@HybridEnum>` — sequential `[4B count][8B×N nativeValues]`
- `List<@HybridRecord>` — indexed offset-table `[4B count][8B×N offsets][items]`
- `List<@HybridStruct>` — `LazyRecordList` + zero-copy proxy decode
- `List<@NitroVariant>` — sequential `[4B count][tag+fields×N]`
- `Map<String, primitive>` — JSON bridge
- `Map<String, @HybridEnum>` — int64 value encoding
- `Map<String, @HybridRecord>` — binary blob encoding (tag 5)
- `Map<String, @NitroVariant>` — binary blob encoding (tag 5)

### TypedData (zero-copy)
- `Uint8List`, `Int8List`, `Int16List`, `Int32List`, `Uint16List`, `Uint32List`
- `Float32List`, `Float64List`, `Int64List`, `Uint64List`
- Passed as `pointer + byte_length`; optional `@zeroCopy` on `@HybridStruct` fields
- *Covers RN Nitro's `ArrayBuffer` use case for binary data transport*

### Async & Streams
- `Future<T>` with `@nitroAsync` — isolate dispatch, optional timeout
- `@NitroNativeAsync` — `Dart_PostCObject_DL` direct post (~5× faster than isolate path)
- `Stream<T>` via `@NitroStream` — four backpressure modes:
  - `Backpressure.dropLatest` — drops incoming when consumer is slow
  - `Backpressure.block` — serial queue, back-pressures producer
  - `Backpressure.bufferDrop` — bounded ring buffer, drops oldest
  - `Backpressure.batch` — aggregates items into arrays *(primitives + @HybridEnum only)*
- `Stream<@HybridStruct>` — zero-copy proxy stream
- `Stream<@NitroVariant>` — binary-encoded stream items
- `Stream<@HybridRecord>` — binary-encoded record stream (Kotlin `.encode()` → `ByteArray` → JNI → `kInt64` address → Dart `fromNative` + `malloc.free`)
- `Stream<T?>` nullable items — `int?`, `double?`, `bool?`, `String?`, `@HybridEnum?`, `@NitroVariant?`, `@HybridStruct?`, `@HybridRecord?`

### Callbacks
- `T Function(...)` as function parameter — full recursive type support
- Callback nullable primitive params (`int?`, `double?`, `bool?`) — two-param (isNull, value)
- Callback returns: `void`, `int`, `double`, `bool`, `String`, `@HybridEnum`, `@HybridRecord`, `@NitroVariant`

### Properties
- Getters and setters for all primitive types, enums, records, structs, variants

### Error Handling
- `@NitroResult<T>` — discriminated `[1B tag: 0=ok|1=err][payload]` result type
- `NitroError*` out-param for sync functions
- TLS error slot for async functions

### Special Types
- `NativeHandle<T>` / `@NitroOwned` — opaque pointer with automatic `NativeFinalizer` cleanup
- `NitroAnyMap` / `NitroAnyValue` — heterogeneous typed map (7-case binary union; covers RN Nitro's `AnyMap`)
- `NitroPromise<T>` — multi-subscriber observable; `.then`, `.andThen`, `.catchError`, `.all`, `.race`
- `NitroFfiCodec<T>` — user-extensible codec for custom optional types

### Flutter-Specific Advantages over RN Nitro
- **`Stream<T>` with backpressure** — RN Nitro has **no built-in streaming**; all streaming requires custom callbacks or polling
- **`Backpressure.block/bufferDrop/batch`** — RN Nitro has no native backpressure mechanism
- **`@NitroNativeAsync`** — `Dart_PostCObject_DL` direct post; RN Nitro always hops through JSI thread
- **`@NitroResult<T>`** — typed discriminated result; RN Nitro uses JS exception propagation
- **`@HybridStruct`** — zero-copy POD struct bridge with lazy proxy streams; RN Nitro has no equivalent (uses `Record<string,T>` or `CustomType`)
- **`@HybridRecord`** — binary-encoded type with offset-table decode; more efficient than JSI property access
- **Non-contiguous `@HybridEnum` values** — RN Nitro enums must be 0-based contiguous integers
- **Desktop (Windows/Linux) generator** — `.impl.g.cpp` editable C++ starter; RN Nitro targets mobile only
- **Four stream backpressure modes** — unique to Flutter Nitro

---

## Known Limitations (Resolved ✅)

### L1 — `Stream<@HybridRecord>` ✅
**Status:** Fully implemented and tested. Both non-nullable `Stream<R>` and nullable `Stream<R?>` are supported.  
**Wire format:** Kotlin calls `.encode()` → passes `ByteArray` (or `ByteArray?` for nullable) to JNI → C reads `GetByteArrayRegion` → `malloc` buffer → posts `kInt64` address → Dart `Pointer<Uint8>.fromAddress` → `RecordExt.fromNative(rawPtr)` → `malloc.free(rawPtr)`. Same pattern as `Stream<@NitroVariant>`.  
**Tests:** §23 (12 unit tests, non-nullable), §24 (8 unit tests, nullable); 20 integration tests.  
**Merged:** 2026-06-29.

### L2 — Nested `@HybridStruct` fields ✅
**Status:** Fully implemented and tested. Struct fields can have another `@HybridStruct` as their type.  
**Wire format:** Nested struct is embedded as a typed pointer (`Pointer<NestedFfi>`) in the outer C shadow struct. Dart proxy reads via `.ref.toDart()`, assignment via `.toNative(arena)`.  
**Tests:** `test/nested_struct_test.dart` (39 tests).

### L3 — `Backpressure.batch` for `@HybridRecord` and `@NitroVariant` ✅
**Status:** Fully implemented and tested.  
**Wire format:** Native accumulates raw field bytes; flushes `[4B outer_len][4B count][item bytes×N]` as `kTypedData/kUint8`. Dart decodes with `RecordReader.decodeList`. `@HybridStruct` still triggers E005.  
**Tests:** §28–§30 (30 unit tests) in `record_variant_batch_test.dart`.  
**Merged:** 2026-06-29.

### L4 — `Map<String, @HybridRecord>` / `Map<String, @NitroVariant>` ✅
**Status:** Fully implemented and tested on macOS. W006 warning removed.  
**Wire format:** `[4B payload_len][4B count][per entry: 4B key_len][key bytes][1B tag=5][4B blob_len][blob bytes]`. Tags 1–4 = int64/float64/bool/string; tag 5 = binary record/variant blob.  
**Key bug fixes (found during integration):** `cpp_header_generator.dart` was emitting `void*` for `@NitroVariant`/`@HybridRecord` properties (now `uint8_t*`); Swift map emitter used Dart extension naming `TcConfigRecordExt.fromNative` instead of `TcConfig.fromNative`; variant property setter needed `UnsafeMutablePointer(mutating:)` cast.  
**Tests:** §31–§38 (49 unit tests); §L4a + §L4b (12 integration tests).  
**Merged:** 2026-06-29.

### L5 — `List<@HybridEnum?>` / `List<@NitroVariant?>` nullable items ✅
**Status:** Fully implemented and tested.  
**Wire format:** `[4B payload_len][4B count][per item: 1B hasValue][item bytes if hasValue]`.  
**Tests:** §25–§27 (24 unit tests) in `nullable_list_items_test.dart`.  
**Merged:** 2026-06-29.

### L9 — Desktop (macOS / Windows / Linux) ✅
**Status:** Fully implemented. Generator produces a concrete C++ implementation starter (`.impl.g.cpp`) for `NativeImpl.cpp` modules.  
**Generated files:** `.native.g.h` (abstract interface), `.impl.g.cpp` (one-time editable starter with `throw std::runtime_error` stubs), `.bridge.g.h/.cpp` (C FFI bridge), `.mock.g.h/.test.g.cpp` (GoogleMock).  
**Tests:** §39–§42 (25 tests) in `cpp_impl_generator_test.dart`.  
**Merged:** 2026-06-29.

### L11 — `DateTime` bridge type ✅
**Status:** Fully implemented. RN Nitro maps JS `Date` ↔ `std::chrono::system_clock::time_point` via JSI; Flutter Nitro maps `DateTime` ↔ `int64_t` milliseconds-since-epoch.  
**Wire format:**
- Non-null `DateTime` → `int64_t` (same wire as `int`); Dart encodes `.millisecondsSinceEpoch`, decodes `DateTime.fromMillisecondsSinceEpoch()`
- `DateTime?` → `Pointer<NitroOptInt64>` 9-byte packed struct `[1B hasValue][8B Int64]` (same wire as `int?`)
- Swift: `Date` ↔ `Int64` via `Int64(v.timeIntervalSince1970 * 1000)` / `Date(timeIntervalSince1970: Double(v)/1000.0)`
- Kotlin: `Long` (non-null), `NitroOptInt64.decode(byteArray).nullable` (nullable)
- All transports: sync, `@nitroAsync`, `@NitroNativeAsync`, callback param/return, stream item, property getter/setter  

**Gap vs RN Nitro:** RN Nitro preserves sub-millisecond precision via `time_point` nanoseconds. Flutter Nitro is millisecond-precision (matches `DateTime` resolution). No practical difference for API use cases.  
**Tests:** §L11 (7 unit + 7 integration tests): `echoDateTime` (4 cases: epoch 0, UTC timestamp, negative ms, large positive) + `echoNullableDateTime` (3 cases: null, non-null, epoch-0 disambiguation).  
**Merged:** 2026-06-29.

---

## Known Limitations (Open)

### L6 — `@HybridStruct` as callback return ⚠️
**Status:** Unsafe — intentionally not supported.  
**Reason:** `NativeCallable` has no `Arena` lifetime. Returning a heap-allocated struct pointer from a callback has no tracked owner to free it.  
**Workaround:** Wrap struct fields in a `@HybridRecord` (malloc + known ownership).

### L7 — `TypedData?` (nullable typed arrays) ⚠️
**Status:** Excluded — documented design constraint.  
**Reason:** TypedData uses two FFI params (pointer + length). Nullable would require a third "hasValue" param, complicating all callsites.  
**Workaround:** Non-nullable `Uint8List` + empty list for the "no data" case, or wrap in `@HybridRecord`.

### L8 — Web / WASM ⚠️
**Status:** Partial. W007 warning emitted when `webImpl` is set and streams or `@NitroNativeAsync` functions are declared.  
**Reason:** `Dart_PostCObject_DL` and FFI structs are unavailable on web. Streams and native-async functions throw `UnsupportedError` at runtime.  
**Note:** RN Nitro also has no web support — web throws an error there too.  
**Workaround:** Guard with `kIsWeb`, or provide a web-specific stub implementation.

### L10 — `Map<String, @HybridStruct>` ❌
**Status:** E008 — intentionally blocked.  
**Reason:** Struct values are `void*` pointers; the map encoder has no ownership protocol for pointer-valued entries.  
**Workaround:** `List<TheStruct>` + separate key list, or a `@HybridRecord` with struct fields.

### L12 — Tuple types `(A, B, C)` ❌
**Status:** Not implemented. RN Nitro maps JS `[A, B, C]` ↔ `std::tuple<A, B, C>`.  
**Flutter Nitro gap:** No anonymous fixed-arity product type. The spec DSL has no tuple syntax.  
**Workaround:** Define a `@HybridRecord` with named fields — structurally identical but requires a name.  
**Note:** Tuples in RN Nitro are rarely used in practice (records/objects are more idiomatic). Low priority.

### L13 — `uint64_t` scalar parameter type ❌
**Status:** Not implemented. RN Nitro maps JS `bigint (UInt64)` ↔ `uint64_t`.  
**Flutter Nitro gap:** `int` in Dart is `int64_t` (signed). There is no `UInt64` scalar type for function params/returns. `Uint64List` exists for typed data buffers but not for individual values.  
**Workaround:** Pass as `int` and reinterpret bits; or use `Uint64List` with a single element.  
**Implementation path:** Add `uint64` as a recognised type; map to `Dart_TypedData_kUint64` on the Dart side and `uint64_t` on the C side. Swift: `UInt64`; Kotlin: `Long` (same bits, reinterpreted).

### L14 — `AnyHybridObject` (untyped hybrid object reference) ❌
**Status:** Not implemented. RN Nitro supports passing any `HybridObject` without knowing its concrete type.  
**Flutter Nitro gap:** All hybrid object references are typed at the spec level (`NativeImpl.swift` etc.). There is no "pass an opaque native object" mechanism.  
**Use case:** Plugin APIs that accept or return another plugin's native object without a shared type contract.  
**Workaround:** Use `NativeHandle<T>` / `@NitroOwned` for opaque pointer passing.  
**Implementation path:** Add an `AnyNativeImpl` wrapper type that erases the concrete type and passes a raw `void*` / `int64_t` instanceId.

### L15 — `BoxedHybridObject<T>` (cross-isolate object boxing) ❌
**Status:** Not implemented. RN Nitro supports boxing a `HybridObject` in one JSI runtime and unboxing it in another (for Reanimated worklets / dedicated threads).  
**Flutter Nitro gap:** Dart isolates have a completely different memory model. A native impl registered in isolate A is not accessible from isolate B.  
**Note:** This is a fundamental paradigm difference, not just a missing feature. In Flutter, cross-isolate communication is typically done via `SendPort`/`ReceivePort` with serialisable messages.  
**Workaround:** Keep all native calls in the main isolate; use `compute()` or isolate `spawn()` for pure Dart computation and ferry results back.

### L16 — `CustomType<T>` full generator integration ⚠️
**Status:** Partial. `NitroFfiCodec<T>` runtime exists; generator integration is not wired up.  
**Flutter Nitro gap:** In RN Nitro, specialising `JSIConverter<MyType>` lets the codegen automatically use `MyType` anywhere in a spec. In Flutter Nitro, `NitroFfiCodec<T>` defines the encode/decode logic but the generator doesn't recognise arbitrary `MyType` names in `.native.dart` specs — it will emit an E010 unknown type error.  
**Workaround:** Use `@HybridRecord` or `@NitroVariant` to model the custom type within the existing type system.  
**Implementation path:** Add a `@NitroCustomType(codec: MyCodec())` annotation; extend `spec_extractor.dart` to register the codec; emit `codec.encode(v, arena)` / `codec.decode(res)` in the generator where the type appears.

---

## Validator Error Code Reference

| Code | Condition | Blocks |
|------|-----------|--------|
| E001 | Map key must be `String` | Non-string map keys |
| E002 | `@nitroAsync` requires `Future<T>` or `void` return | Wrong return type |
| E003 | Nested maps forbidden | `Map<String, Map<...>>` |
| E004 | Stream cannot be a property | `@NitroProperty Stream<T>` |
| E005 | `Backpressure.batch` limited to primitives + `@HybridEnum` | Complex batch items (L3) |
| E006 | `batchMaxSize` must be > 0 | Invalid batch config |
| E008 | Map values must be primitives, `@HybridEnum`, `@HybridRecord`, or `@NitroVariant` | Complex map values (L10: `@HybridStruct`) |
| E010 | Unknown type reference | Unrecognised param/return type (L16: custom types) |
| E011 | Unknown stream item type | `@HybridRecord` streams (L1) |
| E012 | Unknown property type | Unrecognised property type |
| E013 | Unknown `@HybridRecord` field type | Unresolved field reference |
| E014 | `@NitroVariant` case count 1–255 | 0 cases or > 255 cases |
| E015 | `@NitroResult` + `@NitroNativeAsync` conflict | Incompatible annotations |
| W007 | Web impl + streams/NativeAsync | Runtime unsupported on web |

---

## Open Limitations Summary

| # | Limitation | RN Nitro parity? | Priority |
|---|-----------|------------------|---------|
| L6 | `@HybridStruct` as callback return — unsafe (no Arena) | N/A (RN uses JSI, no Arena) | Low |
| L7 | `TypedData?` — two-param FFI makes nullable ambiguous | N/A | Low |
| L8 | Web / WASM — streams + `@NitroNativeAsync` unsupported | Same in RN | Medium |
| L10 | `Map<String, @HybridStruct>` — no pointer ownership in map encoder | N/A | Low |
| L12 | Tuple types `(A, B, C)` | **Gap vs RN** (`[A,B,C] ↔ std::tuple`) | Low |
| L13 | `uint64_t` scalar | **Gap vs RN** (`bigint UInt64`) | Low |
| L14 | `AnyHybridObject` (untyped object ref) | **Gap vs RN** | Low |
| L15 | `BoxedHybridObject` / cross-isolate boxing | **Gap vs RN** (paradigm difference) | Very Low |
| L16 | `CustomType<T>` generator integration | **Gap vs RN** (`JSIConverter<T>` auto-recognized) | Medium |
