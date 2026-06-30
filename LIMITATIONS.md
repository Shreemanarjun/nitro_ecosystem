# Flutter Nitro — Limitations & Current Status

Comparison against React Native Nitro (`packages/react-native-nitro-modules`) as the reference implementation.  
Last updated: 2026-06-29. Generator unit tests: 3982. macOS integration tests: 601.

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
| `bigint` (UInt64) | `uint64` (same bits; Dart `int`, C `uint64_t`, Kotlin `Long`, Swift `UInt64`) | ✅ L13 |
| `T \| undefined` → `std::optional<T>` | `T?` → `NitroOptXxx` structs | ✅ |
| `T[]` → `std::vector<T>` | `List<T>` | ✅ |
| `Record<string, T>` → `std::unordered_map` | `Map<String, T>` | ✅ |
| `[A, B, C]` → `std::tuple<A, B, C>` | `@NitroTuple` typedef `(A, B, C)` — positional record, same binary wire as @HybridRecord | ✅ L12 |
| `A \| B \| C` → `std::variant<A,B,C>` | `@NitroVariant` | ✅ |
| `Date` → `std::chrono::time_point` | `DateTime` → `int64_t` ms-epoch | ✅ L11 |
| `ArrayBuffer` → `jsi::MutableBuffer` | `Uint8List` / TypedData | ✅ (via TypedData) |
| `AnyMap` → heterogeneous typed map | `NitroAnyMap` / `NitroAnyValue` | ✅ |
| `HybridObject<Platforms>` | `NativeImpl.swift` / `.kotlin` / `.cpp` | ✅ |
| `AnyHybridObject` (untyped ref) | `AnyNativeObject` → `int64_t` instanceId | ✅ L14 |
| `BoxedHybridObject<T>` (cross-runtime) | — (Dart isolate paradigm difference) | N/A L15 |
| `CustomType<T>` + `JSIConverter<T>` | `@NitroCustomType(codec:)` + `NitroFfiCodec<T>` | ✅ L16 |
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
- `int`, `double`, `bool`, `String`, `void`, `DateTime`, `uint64` — all transports (sync, async, callback, stream, property)
- `int?`, `double?`, `bool?`, `DateTime?`, `uint64?` — `NitroOptXxx` @Packed(1) structs; two-param callback approach
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
- `Stream<AnyNativeObject>` — non-null items post `kInt64` instanceId; decoded as `AnyNativeObject(message as int)`
- `Stream<T?>` nullable items — `int?`, `uint64?`, `double?`, `bool?`, `String?`, `@HybridEnum?`, `@NitroVariant?`, `@HybridStruct?`, `@HybridRecord?`, `AnyNativeObject?` (nullable posts `kNull`; Kotlin `Long?`; Swift nullable pointer)
- `Stream<uint64>` / `Stream<uint64?>` — non-null posts `kInt64` (bit-reinterpreted); nullable posts `kNull`; Dart unpack: `message as int`

### Callbacks
- `T Function(...)` as function parameter — full recursive type support
- Callback nullable primitive params (`int?`, `double?`, `bool?`) — two-param (isNull, value)
- Callback params: `AnyNativeObject` (non-null, decoded as `AnyNativeObject(arg)`) and `AnyNativeObject?` (nullable, `-1` null sentinel)
- Callback returns: `void`, `int`, `double`, `bool`, `String`, `@HybridEnum`, `@HybridRecord`, `@NitroVariant`, `AnyNativeObject` (encoded as `.instanceId`; `-1` for null)

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
- `NitroFfiCodec<T>` + `@NitroCustomType` — user-extensible codec for custom types; generator emits `codec.encode()/decode()` automatically
- `AnyNativeObject` — opaque untyped native object reference via `int64_t` instanceId; nullable uses `-1` sentinel; every generated impl exposes `asAnyNativeObject` getter; `FooNativeRef` extension on abstract class delegates without cast; `NitroInstanceRegistry.register/unregister` wired into generated constructor/dispose for GC-safe typed downcast via `NitroInstanceRegistry.resolve<T>(ref)`

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

### L12 — Tuple types `(A, B, C)` ✅
**Status:** Implemented. Annotate a Dart 3 positional record typedef with `@NitroTuple()` — same binary wire format as `@HybridRecord` (4B length prefix + sequential fields).  
**Dart type:** `(T1, T2, T3)` positional record, accessed via `$1`, `$2`, `$3`.  
**Wire format:** Identical to `@HybridRecord` — sequential field encoding, `uint8_t*` / `void*` on C boundary.  
**Generator output:**
- Dart: standalone free functions `_nitroDecode_<Name>` / `_nitroDecodeNullable_<Name>` / `_nitroEncode_<Name>` (typedef cannot have extension methods)
- Kotlin: `data class <Name>(val field0: T0, val field1: T1, ...)` with `decode`/`encode` helpers
- Swift: `struct <Name>` with `fromNative`/`toNative` helpers (identical to @HybridRecord codegen)
- C: `void*` parameter/return (same as @HybridRecord)

**Example:**
```dart
@NitroTuple()
typedef MyPair = (int, String);

@NitroModule(...)
abstract class Counter {
  MyPair getPair();
  void setPair(MyPair v);
}
```

**Remaining:** `spec_extractor.dart` wiring for `@NitroTuple` on typedefs (requires `analyzer` AST traversal for Dart 3 record types). Generator is fully functional when `BridgeRecordType(isTuple: true, ...)` is provided directly.  
**Tests:** 33 unit tests in `test/tuple_type_test.dart`.  
**Merged:** 2026-06-29.

### L13 — `uint64_t` scalar parameter type ✅
**Status:** Fully implemented. Dart type `uint64` maps to `uint64_t` (C), `UInt64` (Swift), `Long` (Kotlin JVM — same bits), `Uint64` FFI / `int` Dart.  
**Wire format:**
- Non-null `uint64` → `uint64_t` / `UInt64` / `jlong` (bit-reinterpretation; values > 2^63-1 appear negative in Dart `int` but bits are preserved)
- `uint64?` → reuses `NitroOptInt64` 9-byte packed struct `[1B hasValue][8B uint64_t bits]` (same layout as `int?`; bit-compatible)
- All transports: sync param/return, `@nitroAsync`, callback param/return, stream item (`Stream<uint64>` / `Stream<uint64?>`), property getter/setter  

**Tests:** 24 unit tests in `test/uint64_type_test.dart` covering Dart FFI types, C header types, Kotlin interface, JNI bridge sig, stream emit, and async transport.  
**Merged:** 2026-06-29.

### L14 — `AnyHybridObject` (untyped hybrid object reference) ✅
**Status:** Fully implemented as `AnyNativeObject`.  
**Wire format:** `int64_t` instanceId (non-null); `-1` null sentinel for `AnyNativeObject?`. Every generated impl class exposes `AnyNativeObject get asAnyNativeObject => AnyNativeObject(_instanceId)` to vend a type-erased reference.  
**Kotlin:** `Long` / `Long?`; JNI `CallStaticLongMethod`. **Swift:** `Int64` in `@_cdecl` function; `-1` for null. **C:** `int64_t`.  
**All transports:** sync function param/return, async, property, nullable, callback param/return, stream item.  
**Improvements (2026-06-29):**
- `assert(instanceId >= 0)` guard in `AnyNativeObject` const constructor — catches negative IDs at debug time
- `FooNativeRef` extension emitted on the abstract class so callers use `foo.asAnyNativeObject` without an `as _FooImpl` cast
- `NitroInstanceRegistry.register(_instanceId, this)` in constructor + `unregister` in `dispose()` — enables `NitroInstanceRegistry.resolve<Foo>(ref)` typed downcast with no native roundtrip; backed by `WeakReference` + `Finalizer` for GC safety
- `Stream<AnyNativeObject>` / `Stream<AnyNativeObject?>` — Dart decodes `kInt64` as `AnyNativeObject(message as int)`; Kotlin `Long`/`Long?`; Swift `Int64`/`UnsafePointer<Int64>?`
- Callback param: `AnyNativeObject` decoded as `AnyNativeObject(arg0)`; nullable `arg0 == -1 ? null : AnyNativeObject(arg0)`
- Callback return: encoded as `.instanceId`; nullable `_v == null ? -1 : _v.instanceId`; exceptional returns `0` / `-1`
- `spec_validator.dart` now accepts `AnyNativeObject` in both callback param and return type whitelists  

**Tests:** 41 unit tests in `test/any_native_object_test.dart`; 32 integration tests in `nitro_type_coverage`.  
**Merged:** 2026-06-29.

### L15 — `BoxedHybridObject<T>` (cross-isolate object boxing) N/A
**Status:** Not implementable — paradigm difference, not a missing feature.  
**Reason:** RN Nitro's `BoxedHybridObject<T>` boxes a JSI `HybridObject` for use in a different JSI runtime (e.g., Reanimated worklets). Dart isolates have entirely separate heaps; a native impl registered in isolate A cannot be referenced by isolate B because the instanceId registry is isolate-local.  
**Workaround:** Keep all native calls in the main isolate; use `compute()` / isolate `spawn()` for pure Dart work, ferrying serialisable data back. For shared state, use `NativeHandle<T>` to pass a raw native pointer that both isolates can use via platform channel.

### L16 — `CustomType<T>` generator integration ✅
**Status:** Fully implemented.  
**How it works:** Annotate a Dart class with `@NitroCustomType(codec: MyCodec(), encodedSize: N)`. The generator detects the annotation in `spec_extractor.dart`, registers the type name in `BridgeSpec.customTypes`, and emits `const MyCodec().encode(v, arena)` for params and `const MyCodec().decode(res)` for returns.  
**Wire format:** `Pointer<Uint8>` / `ByteArray` (identical to `@HybridRecord`). Params use the codec's `encodedSize` for `NewByteArray`; returns use `GetArrayLength` then `GetByteArrayRegion`.  
**User API:** Subclass `NitroFfiCodec<T>` and implement `encodedSize`, `encode(T? value, Arena alloc) → Pointer<Uint8>`, `decode(Pointer<Uint8> ptr) → T?`. Kotlin protocol receives/returns `ByteArray`; Swift protocol receives/returns `[UInt8]`.  
**Parallel to RN Nitro:** `JSIConverter<MyType>` specialisation — same pattern, different ABI.  
**Tests:** 18 unit tests in `test/nitro_custom_type_test.dart`.  
**Merged:** 2026-06-29.

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
| ~~L12~~ | ~~Tuple types `(A, B, C)`~~ | ~~**Gap vs RN**~~ | ✅ Done |
| ~~L13~~ | ~~`uint64_t` scalar~~ | ~~**Gap vs RN**~~ | ✅ Done |
