# Swift Type Mapping in Nitrogen

Nitrogen bridges Dart ↔ C++ ↔ Swift through a two-layer type system. Understanding the
two layers prevents the most common iOS crashes.

---

## The two layers

```
Dart (dart:ffi)
      │  Pointer<Utf8>, Int64, Double, …
      ▼
C++ bridge  (.bridge.g.mm — #ifdef __APPLE__)
      │  extern "C"  const char*, int32_t, double, …
      ▼
@_cdecl Swift function  (generated in .bridge.g.swift)
      │  UnsafePointer<CChar>?, Int64, Double, …  ← C-ABI types
      ▼
Swift protocol method  (you implement in *Impl.swift)
            String, Int, Double, Bool, …          ← native Swift types
```

The **`@_cdecl` layer** must use C-ABI-compatible types. These are NOT the same as the
natural Swift types used in your protocol implementation.

---

## Full type mapping table

| Dart spec type | C (`bridge.g.cpp`) | `@_cdecl` Swift param | `@_cdecl` Swift return | Protocol / impl Swift |
|---|---|---|---|---|
| `double` | `double` | `Double` | `Double` | `Double` |
| `int` | `int64_t` | `Int64` | `Int64` | `Int64` |
| `bool` | `int8_t` | `Int8` | `Int8` | `Bool` |
| `String` | `const char*` | `UnsafePointer<CChar>?` | `UnsafeMutablePointer<CChar>?` | `String` |
| `TypedData` | `T*` + `int64_t` | `UnsafeMutablePointer<T>?` | *(not a return type)* | `Data` or `[T]` |
| `@HybridEnum` | `int32_t` | `Int32` | `Int32` | `Enum.rawValue` |
| `@HybridStruct` | `void*` | *(not a param type)* | `UnsafeMutableRawPointer?` | struct value |
| `void` | `void` | *(no param)* | `Void` | `Void` |

> **Rule of thumb:** `@_cdecl` functions must only use types that exist in C.
> Swift's `String`, `Bool`, and struct types **do not** exist in C.
> The generator converts them at the `@_cdecl` boundary automatically.

---

## Why `String` is special

Swift's `String` is a fat value type — in memory it is a 3-word struct:

```
┌──────────────────────────────────────────────────────┐
│  pointer to heap-allocated UTF-16 storage (8 bytes)  │
│  count (8 bytes)                                     │
│  flags / small-string inline storage (8 bytes)       │
└──────────────────────────────────────────────────────┘
```

C's `const char*` is a single 8-byte pointer to a null-terminated byte array — completely
different layout.

When C calls a `@_cdecl` function and passes a `const char*`, Swift interprets those 8
bytes as the **beginning of a 24-byte String struct**. It immediately reads adjacent
stack/heap memory as count and flags — **undefined behaviour → EXC_BAD_ACCESS**.

The generator therefore uses:

| Direction | Correct `@_cdecl` type | Why |
|---|---|---|
| C → Swift (parameter) | `UnsafePointer<CChar>?` | matches C's `const char*`; convert with `String(cString:)` |
| Swift → C (return value) | `UnsafeMutablePointer<CChar>?` | matches C's `char*`; allocated with `strdup()` |

---

## Memory ownership for String returns

The Dart FFI side calls `toDartStringWithFree()` on every returned `Pointer<Utf8>`:

```dart
// Generated in .g.dart:
final result = _getGreetingPtr(name.toNativeUtf8(allocator: arena));
return (result as Pointer<Utf8>).toDartStringWithFree();
//                                 ^^^^^^^^^^^^^^^^^^^^
//                           calls free() on the returned pointer
```

The Swift `@_cdecl` function must therefore return a **`malloc`-allocated** C string so
that Dart's `free()` pairs correctly with it. `strdup()` uses `malloc` internally:

```swift
// ✓ Correct — strdup uses malloc; Dart calls free()
@_cdecl("_call_getGreeting")
public func _call_getGreeting(_ name: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let nameStr = name.map { String(cString: $0) } ?? ""
    guard let impl = MyRegistry.impl else { return strdup("") }
    // … async bridging …
    return strdup(result)
}

// ✗ Wrong — Swift String is not a C pointer; Dart reads garbage memory
@_cdecl("_call_getGreeting")
public func _call_getGreeting(_ name: String) -> String {   // ← CRASH
    …
}
```

> **Never allocate the return string with Swift's `String`-to-pointer APIs** (e.g.
> `withCString`, `withUTF8`). Those point into stack or Swift-managed memory that becomes
> invalid after the function returns. Use `strdup()` so ownership passes to the caller.

---

## Bool conversion

`Bool` is a 1-byte C `int8_t` in the C ABI. The generated bridge converts at both ends:

```swift
// @_cdecl param — receives Int8 from C, converts to Bool for protocol
@_cdecl("_call_set_enabled")
public func _call_set_enabled(_ value: Int8) {
    MyRegistry.impl?.enabled = value != 0
}

// @_cdecl return — receives Bool from protocol, returns Int8 to C
@_cdecl("_call_get_enabled")
public func _call_get_enabled() -> Int8 {
    return (MyRegistry.impl?.enabled ?? false) ? 1 : 0
}
```
Your protocol implementation always uses `Bool` — the Int8 conversion is invisible.

---

## Typed Lists (`Float32List`, `Int32List`, etc.)

Typed lists are bridged as a pair of a raw C pointer and an explicit `int64_t` length parameter.
The Swift `@_cdecl` function receives the pointer and length, then reconstructs an
`UnsafeBufferPointer` to create a native Swift array or `Data` object.

| Dart type | C bridge params | `@_cdecl` Swift params | protocol / impl Swift |
|---|---|---|---|
| `Uint8List` | `uint8_t*, int64_t` | `UnsafeMutablePointer<UInt8>?, Int64` | `Data` |
| `Float32List` | `float*, int64_t` | `UnsafeMutablePointer<Float>?, Int64` | `[Float]` |
| `Int32List` | `int32_t*, int64_t` | `UnsafeMutablePointer<Int32>?, Int64` | `[Int32]` |

```swift
// @_cdecl layer — receives pointer and length
@_cdecl("_call_processWeights")
public func _call_processWeights(_ ptr: UnsafeMutablePointer<Float>?, _ len: Int64) {
    guard let ptr = ptr else { return }
    // Reconstruct buffer without copying
    let buffer = UnsafeBufferPointer(start: ptr, count: Int(len))
    let weights = Array(buffer)
    MyRegistry.impl?.processWeights(weights)
}
```

This ensures ABI safety. Swift's `[Float]` is a fat struct that cannot be passed directly
from C; passing just the pointer would lose the length information.

---

## Async String bridging

For `@nitroAsync Future<String>` methods, the bridge must block the calling C thread
(Dart's background isolate thread) with a `DispatchSemaphore` until the Swift
`async throws` function completes:

```swift
@_cdecl("_call_readLabel")
public func _call_readLabel() -> UnsafeMutablePointer<CChar>? {
    guard let impl = MyRegistry.impl else { return strdup("") }
    let sema = DispatchSemaphore(value: 0)
    var result = ""
    Task.detached {
        result = (try? await impl.readLabel()) ?? ""
        sema.signal()
    }
    sema.wait()          // safe — Dart calls this on a background isolate thread,
                         // not the main thread, so no deadlock
    return strdup(result)
}
```

> **Why `Task.detached`?** `Task {}` (unstructured) inherits the current actor context.
> Since `@_cdecl` functions have no actor, `Task.detached` ensures the async work runs on
> the Swift concurrency cooperative thread pool, not on the calling C thread.

---

## Read-write String properties

```swift
// Getter — returns strdup-allocated C string
@_cdecl("_call_get_label")
public func _call_get_label() -> UnsafeMutablePointer<CChar>? {
    return strdup(MyRegistry.impl?.label ?? "")
}

// Setter — receives C string, converts to Swift String before assigning
@_cdecl("_call_set_label")
public func _call_set_label(_ value: UnsafePointer<CChar>?) {
    MyRegistry.impl?.label = value.map { String(cString: $0) } ?? ""
}
```

---

## Struct returns

`@HybridStruct` types are heap-allocated and returned as `UnsafeMutableRawPointer?`:

```swift
@_cdecl("_call_getSensorData")
public func _call_getSensorData() -> UnsafeMutableRawPointer? {
    guard let result = MyRegistry.impl?.getSensorData() else { return nil }
    let ptr = UnsafeMutablePointer<SensorData>.allocate(capacity: 1)
    ptr.initialize(to: result)
    return UnsafeMutableRawPointer(ptr)
}
```

The Dart side unpacks the returned `void*` back into the struct layout using the generated
`Struct` subclass in `.g.dart`.

---

## Quick reference: `@_cdecl` vs protocol types

```swift
// ── Generated bridge stub (@_cdecl layer) ─────────────────────────────────────
@_cdecl("_call_process")
public func _call_process(
    _ name: UnsafePointer<CChar>?,   // String param → C const char*
    _ count: Int64,                  // int param    → C int64_t
    _ flag: Int8                     // bool param   → C int8_t
) -> UnsafeMutablePointer<CChar>? {  // String return → C char* (malloc'd)
    let nameStr = name.map { String(cString: $0) } ?? ""
    let flagBool = flag != 0
    return strdup(MyRegistry.impl?.process(name: nameStr, count: count, flag: flagBool) ?? "")
}

// ── Your protocol implementation (*Impl.swift) ─────────────────────────────────
public class MyImpl: NSObject, HybridMyProtocol {
    public func process(name: String, count: Int64, flag: Bool) -> String {
        // ← always uses clean Swift types. The C conversion is invisible here.
        return "processed \(count) items from \(name): flag=\(flag)"
    }
}
```

---

## Checklist for Swift plugin authors

When implementing `*Impl.swift`:

- [x] Your protocol methods use **native Swift types** (`String`, `Bool`, `Double`, etc.)
- [x] You do **not** touch `@_cdecl` functions — they are generated
- [x] You return plain Swift `String` values — `strdup` wrapping happens in the bridge
- [x] Async methods are `async throws` — the semaphore blocking is in the bridge

If you see a `@_cdecl` function in code you didn't generate, and it uses `String` as a
parameter or return type — that is the old broken pattern. Regenerate with `nitrogen generate`.

---

## Diagnosing a `@_cdecl` String crash

**Symptom:** `EXC_BAD_ACCESS` immediately on the first call to any method that takes or
returns a `String`.

**Cause:** The `@_cdecl` function was generated with `String` param/return instead of
`UnsafePointer<CChar>?` / `UnsafeMutablePointer<CChar>?`. C passes an 8-byte pointer;
Swift tries to read it as a 24-byte fat String struct.

**Fix:**

```sh
# Re-run the generator — fixed since nitro_generator 0.1.8
nitrogen generate
```

Then `pod install` and rebuild. If you have a manually edited `bridge.g.swift`, look for
any `@_cdecl` function that uses `String` as a parameter or return type and apply the
conversions shown above.
