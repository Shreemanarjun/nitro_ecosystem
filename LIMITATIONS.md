# Flutter Nitro — Limitations & Current Status

Comparison against React Native Nitro as the reference implementation.
Last updated: 2026-06-29. Generator unit tests: 3853. macOS integration tests: 594.

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

## Fully Supported (✅)

### Primitives & Nullables
- `int`, `double`, `bool`, `String`, `void` — all transports (sync, async, callback, stream, property)
- `int?`, `double?`, `bool?` — `NitroOptXxx` @Packed(1) structs; two-param callback approach
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
- `NitroAnyMap` / `NitroAnyValue` — heterogeneous typed map (7-case binary union)
- `NitroPromise<T>` — multi-subscriber observable; `.then`, `.andThen`, `.catchError`, `.all`, `.race`
- `NitroFfiCodec<T>` — user-extensible codec for custom optional types

### Flutter-Specific Advantages (no RN Nitro equivalent)
- `Backpressure.block/bufferDrop/batch` — RN Nitro has no native backpressure
- `@NitroNativeAsync` — RN Nitro uses Promise<T> from native thread
- `@NitroResult<T>` — RN Nitro uses JS exceptions
- Zero-copy `@HybridStruct` stream proxy — lazy field access with `NativeFinalizer`
- Non-contiguous `@HybridEnum` values — RN Nitro uses contiguous integers

---

## Known Limitations

### L1 — `Stream<@HybridRecord>` ✅
**Status:** Fully implemented and tested. Both non-nullable `Stream<R>` and nullable `Stream<R?>` are supported.  
**Wire format:** Kotlin calls `.encode()` → passes `ByteArray` (or `ByteArray?` for nullable) to JNI → C reads `GetByteArrayRegion` → `malloc` buffer → posts `kInt64` address → Dart `Pointer<Uint8>.fromAddress` → `RecordExt.fromNative(rawPtr)` → `malloc.free(rawPtr)`. Same pattern as `Stream<@NitroVariant>`.  
**Tests:** §23 (12 unit tests, non-nullable), §24 (8 unit tests, nullable) in `all_generators_type_coverage_test.dart`; 20 integration tests in `type_coverage_generator_test.dart`.  
**Merged:** 2026-06-29.

### L2 — Nested `@HybridStruct` fields ✅
**Status:** Fully implemented and tested. Struct fields can have another `@HybridStruct` as their type.  
**Wire format:** Nested struct is embedded as a typed pointer (`Pointer<NestedFfi>`) in the outer C shadow struct. Dart proxy reads via `.ref.toDart()`, assignment via `.toNative(arena)`.  
**Tests:** `test/nested_struct_test.dart` (39 tests) in `nitro_generator`.  
**Note:** Marked as limitation in error — implementation predates LIMITATIONS.md creation.

### L3 — `Backpressure.batch` for `@HybridRecord` and `@NitroVariant` ✅
**Status:** Fully implemented and tested. `@HybridRecord` and `@NitroVariant` batch streams are now supported. E005 updated to allow both types.  
**Wire format:** Native accumulates each item's raw field bytes (`writeFields(w).bytes`); flushes `[4B outer_len][4B count][item bytes×N]` as `kTypedData/kUint8`. Dart receives `Uint8List`, copies to `malloc`, decodes with `RecordReader.decodeList(ptr, (r) => TypeExt.fromReader(r))`, then frees. `@HybridStruct` still triggers E005 (no `encode()` method).  
**Tests:** §28 (19 tests, @HybridRecord batch), §29 (7 tests, @NitroVariant batch), §30 (4 contrast tests) in `record_variant_batch_test.dart`.  
**Merged:** 2026-06-29.

### L4 — `Map<String, @HybridRecord>` / `Map<String, @NitroVariant>` ✅
**Status:** Fully implemented and tested on macOS (§L4a + §L4b, 12 integration tests). W006 warning removed.  
**Wire format:** `[4B payload_len][4B count][for each: 4B key_len][key bytes][1B tag=5][4B blob_len][blob bytes]`. Blob = `record.encode()` = `[4B payload_len][field bytes]` (or `[4B payload_len][1B variant_tag][fields]`). Tags 1–4 unchanged (int64, float64, bool, string).  
- **Dart decode:** reads tag 5 → allocates Pointer, calls `XxxRecordExt.fromNative(ptr)` / `XxxVariantExt.fromNative(ptr)`, frees.  
- **Kotlin:** encode via `v.encode()`; decode via `decodeFrom(ByteBuffer)` (records) / `fromReader(RecordReader)` (variants).  
- **Swift:** `_nitroDecodeMapBinary` stores tag 5 as `Data`; caller uses `TypeName.fromNative(ptr)` (NOT `TypeNameRecordExt.fromNative` — that's the Dart extension naming, not Swift).  
- **Void-return functions** with map params handled in Kotlin (routing fix).  
**Bugs fixed during integration:**  
- `cpp_header_generator.dart`: `@NitroVariant` / `@HybridRecord` property getters/setters now emit `uint8_t*` / `const uint8_t*` (was falling through to `void*`).  
- `swift_function_emitter.dart`: Map record decode used `TcConfigRecordExt.fromNative()` (Dart naming) instead of `TcConfig.fromNative()` (Swift naming).  
- `swift_property_emitter.dart`: Variant property setter cast `UnsafePointer<UInt8>` → `UnsafeMutablePointer(mutating:)` for `NitroRecordReader`.  
**Tests:** §31–§38 (49 unit tests) in `map_record_variant_test.dart`; §L4a + §L4b (12 integration tests).  
**Merged:** 2026-06-29.

### L5 — `List<@HybridEnum?>` / `List<@NitroVariant?>` nullable items ✅
**Status:** Fully implemented and tested. Nullable items in enum and variant lists are supported.  
**Wire format:** `[4B payload_len][4B count][for each: 1B hasValue][item bytes (only if hasValue)]`. Non-nullable lists unchanged. New `BridgeType.recordListItemIsNullable` flag controls which format to use.  
**Tests:** §25 (10 tests, enum nullable), §26 (10 tests, variant nullable), §27 (4 contrast tests) in `nullable_list_items_test.dart`.  
**Merged:** 2026-06-29.

### L6 — `@HybridStruct` as callback return ⚠️
**Status:** Unsafe — intentionally not supported.  
**Limitation reason:** `NativeCallable` (used for callbacks) has no `Arena` lifetime. Returning a heap-allocated struct pointer from a callback would require the caller to free it, which is not tracked. Would need an explicit ownership protocol.  
**Workaround:** Wrap struct fields in a `@HybridRecord` (which uses `malloc` + known ownership).

### L7 — `TypedData?` (nullable typed arrays) ⚠️
**Status:** Excluded — documented design constraint.  
**Limitation reason:** TypedData uses two FFI parameters (pointer + length). Nullable would require a third "hasValue" param, complicating all callsites.  
**Workaround:** Use `Uint8List` (non-nullable) and an empty list for the "no data" case, or wrap in a `@HybridRecord`.

### L8 — Web / WASM ⚠️
**Status:** Partial. W007 warning emitted when `webImpl` is set and streams or `@NitroNativeAsync` functions are declared.  
**Limitation reason:** `Dart_PostCObject_DL` and FFI structs are not available on the web. Streams and native-async functions throw `UnsupportedError` at runtime.  
**Workaround:** Guard with `kIsWeb` check, or provide a web-specific stub implementation.

### L9 — Desktop (macOS / Windows / Linux) ✅
**Status:** Fully implemented. Generator now produces a concrete C++ implementation starter (`.impl.g.cpp`) for `NativeImpl.cpp` modules.  
**Generated files for `NativeImpl.cpp` modules:**
- `.native.g.h` — abstract `Hybrid${ClassName}` C++ interface (pure-virtual methods/properties/streams)
- `.impl.g.cpp` — **one-time editable starter** — concrete `${ClassName}Impl : public Hybrid${ClassName}` with `throw std::runtime_error("Not implemented: ...")` stubs; Nitrogen does NOT overwrite it after first generation
- `.bridge.g.h` / `.bridge.g.cpp` — C FFI bridge with `${lib}_register_impl` / `${lib}_get_impl` registration API
- `.mock.g.h` / `.test.g.cpp` — GoogleMock stub and test starter  
**Desktop registration:** Call `${lib}_register_impl(&myImpl)` from `RegisterWithRegistrar` (Windows/Linux Flutter plugin) or from the macOS plugin's `registerWithRegistrar:`.  
**Tests:** §39–§42 (25 tests) in `cpp_impl_generator_test.dart`.  
**Merged:** 2026-06-29.

### L10 — `Map<String, @HybridStruct>` ❌
**Status:** E008. Same restriction as L4 but for structs.  
**Limitation reason:** Struct values are `void*` pointers; the map encoder has no ownership protocol for pointer-valued entries.  
**Workaround:** Use `List<TheStruct>` with a separate keys list, or use a `@HybridRecord` with struct fields.

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
| E010 | Unknown type reference | Unrecognised param/return type |
| E011 | Unknown stream item type | `@HybridRecord` streams (L1) |
| E012 | Unknown property type | Unrecognised property type |
| E013 | Unknown `@HybridRecord` field type | Unresolved field reference |
| E014 | `@NitroVariant` case count 1–255 | 0 cases or > 255 cases |
| E015 | `@NitroResult` + `@NitroNativeAsync` conflict | Incompatible annotations |
| W007 | Web impl + streams/NativeAsync | Runtime unsupported on web |

---

## Open Limitations (remaining work)

| # | Limitation | Priority |
|---|-----------|---------|
| L6 | `@HybridStruct` as callback return — unsafe (no Arena in NativeCallable) | Low — workaround: use `@HybridRecord` |
| L7 | `TypedData?` (nullable typed arrays) — two-param FFI makes optional transport ambiguous | Low — workaround: non-nullable + empty list |
| L8 | Web / WASM — streams and `@NitroNativeAsync` throw at runtime | Medium — needs Dart-web-native alternative |
| L10 | `Map<String, @HybridStruct>` — struct pointer ownership not tracked in map encoder | Low — workaround: use `List<TheStruct>` |
