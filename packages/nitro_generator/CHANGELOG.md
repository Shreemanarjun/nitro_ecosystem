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
