## 0.2.2

- **Fix: `@HybridRecord` types not emitted in Kotlin bridge** — `RecordGenerator.generateKotlin()` is now implemented and called from `KotlinGenerator.generate()`. Previously, `@HybridRecord`-annotated classes (e.g. `CameraDevice`, `Resolution`) were missing from the generated `.bridge.g.kt` file, causing `Unresolved reference` compilation errors in Android builds.
  - Generates `@Keep data class` for every `@HybridRecord` type with the correct Kotlin field types (`Long`, `Double`, `Boolean`, `String`, `List<T>`).
  - Each class gets a companion `decode(ByteArray): T` method and an `encode(): ByteArray` method, using a little-endian `ByteBuffer` matching the Dart/Swift wire format.
- **Fix: `_toKotlinType` now resolves `@HybridRecord` class names** — previously returned `Any?` for any record type, causing the generated interface and `_call` methods to use the wrong type. Now returns the real class name.
- **Fix: lint — generated Dart code** — `dart_ffi_generator.dart` now emits:
  - `rawResult` instead of `_rawResult` (local variables must not start with underscore).
  - Braced for-loop bodies `{ stmt; }` instead of bare `stmt` in `record_generator.dart`.
- **Fix: lint — `dart_ffi_generator.dart`** — removed three unused `recordListItem` local variable declarations and fixed unnecessary string interpolation `'$callExpr'` → `callExpr`.
- **New: 28 regression tests** for `@HybridRecord` Kotlin bridge emission, covering data class declaration, field type mapping, `companion decode`, `encode`, list field handling, `_toKotlinType` resolution, interface/JniBridge integration, and non-record spec regression.
- 254 passing tests.

## 0.2.1

- **Fix: Swift stream emit for `@HybridStruct` items** — the generated `_register_*_stream` `@_cdecl` stub now heap-allocates the struct item and passes `UnsafeMutableRawPointer` to the emit callback instead of passing the Swift struct value directly. Previously this caused a Swift compiler error: `Cannot convert value of type 'T' to expected argument type 'UnsafeMutableRawPointer'` for any stream whose item type is a `@HybridStruct`.

## 0.2.0

- **New: `@HybridRecord` binary bridge** — generated extensions now use a compact binary protocol (`uint8_t*` / `Pointer<Uint8>`) instead of UTF-8 JSON strings (`Pointer<Utf8>`).
  - **Breaking:** generated extension methods renamed — `fromJson` → `fromNative` + `fromReader`, `toJson` → `writeFields` + `toNative`. Re-run `nitrogen generate` to update all generated `.g.dart` files.
  - `fromNative(Pointer<Uint8>)` — top-level decoder (with 4-byte length prefix).
  - `fromReader(RecordReader)` — inner decoder for use inside list elements.
  - `writeFields(RecordWriter)` — writes fields into an in-progress writer.
  - `toNative(Allocator)` — top-level encoder; seals the buffer and copies to native heap.
  - FFI lookup type changed from `Pointer<Utf8>` to `Pointer<Uint8>` for all `@HybridRecord` types (except `Map<String, T>` which retains the JSON path).
- **New: `List<primitive>` bridge** — `List<int>`, `List<double>`, `List<bool>`, `List<String>` now cross the FFI boundary as binary `uint8_t*` via `RecordWriter.encodePrimitiveList` / `RecordReader.decodePrimitiveList`.
- **New: `Map<String, T>` bridge** — `Map<String, dynamic>` and `Map<String, V>` are supported as a bridge type using the UTF-8 JSON text path (dynamic value type precludes binary encoding).
- **`SpecValidator`** — validator accepts `List<primitive>` and `Map<String, T>` return/param/property/stream types without emitting `UNKNOWN_*` errors; emits `SYNC_RECORD_RETURN` warning for synchronous `@HybridRecord` returns.
- 226 passing tests.

## 0.1.3

- **Swift generator: fixed `@_cdecl` String type crash (`EXC_BAD_ACCESS`)** — `String` parameters now use `UnsafePointer<CChar>?` (C `const char*`) and return values use `UnsafeMutablePointer<CChar>?` (malloc'd `char*`), with `String(cString:)` conversion at the boundary and `strdup()` for returns so Dart's `toDartStringWithFree()` / `free()` pairs correctly. Fixes an immediate crash on any method that takes or returns a `String`.
- Swift generator: async `String`-returning methods use `DispatchSemaphore` + `Task.detached` with a `strdup(result)` return, matching the synchronous C ABI required by `@_cdecl`.
- Swift generator: `String` property getters return `strdup`-allocated C strings; setters accept `UnsafePointer<CChar>?` and convert with `String(cString:)`.
- Swift generator: default fallback value for `String` returns changed from `""` to `strdup("")` to maintain consistent allocator pairing.
- Updated README: fixed the `@_cdecl("_call_processFile")` example to show the correct C pointer types instead of the old (crashing) `String` param/return pattern; added link to new `docs/swift-type-mapping.md`.

## 0.1.2

- Swift generator: replaced `@objc public static func _call_*` pattern with top-level `@_cdecl("_call_*") public func` stubs. Swift structs and Swift-only protocols cannot cross the Objective-C boundary; `@_cdecl` exports plain C symbols that the generated C++ shim can call with `extern "C"`.
- Swift generator: `bool` return type now maps to `Int8` (matching C's `int8_t`) instead of `Bool`.
- Swift generator: struct-returning functions now return `UnsafeMutableRawPointer?` (heap-allocated, caller frees) instead of `Any?`.
- Swift generator: async struct functions use `DispatchSemaphore` + `Task.detached` to bridge async Swift to the synchronous C ABI required by `@_cdecl`.
- Swift generator: `NitroBatteryRegistry` (and all registries) no longer inherit `NSObject` or use `@objc` — pure Swift classes.
- Added 10 new `SwiftGenerator` tests covering the above patterns.
- Fixed failing test that expected the old `@objc public static func _call_add(` pattern.

## 0.1.1

- Renamed package from `nitrogen` to `nitro_generator` to avoid a naming conflict on `pub.dev`.

## 0.1.0

- Initial release of Nitro code generator.
- Generates Dart FFI, Kotlin, Swift, and C++ bindings.
- Support for `HybridObject`, `HybridStruct`, and `HybridEnum`.
- Support for `@nitroAsync` methods.
- Support for `@NitroStream` with Backpressure strategies.
