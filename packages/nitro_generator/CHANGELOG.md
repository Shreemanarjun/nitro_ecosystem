## 0.2.0

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
