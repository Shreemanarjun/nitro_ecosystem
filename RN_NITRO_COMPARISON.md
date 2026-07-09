# RN Nitro vs Flutter Nitro — Thorough Comparison

> Generated: 2026-06-28  
> RN Nitro version: `0.35.10` (`packages/react-native-nitro-modules`)  
> Flutter Nitro version: `0.4.6` (`packages/nitro_ecosystem`)

---

## 1. Architecture Overview

| | RN Nitro | Flutter Nitro |
|---|---|---|
| **Bridge layer** | JSI (C++ `jsi::Runtime` template API) | Dart FFI (C ABI) |
| **Type system** | C++ templates (`JSIConverter<T>` specializations) — works at compile time, no codegen | Dart codegen — generator writes marshalling code per method |
| **Object tracking** | `jsi::NativeState` attached to JS object; GC holds `shared_ptr<HybridObject>` | `int64_t instanceId`; `NitroInstanceRegistry` (Dart WeakReference + Finalizer) |
| **Prototype system** | One shared JS prototype per C++ type per Runtime; methods registered as function pointers | Normal Dart class dispatch; no prototype |
| **Android path** | fbjni → `JHybridXxxSpec` (inherits both C++ spec and JNI bridge) | Generated `.bridge.g.cpp` — C calls `env->CallXxxMethod` per method |
| **iOS path** | Swift C++ interop: User Swift → `HybridXxxSpec_cxx.swift` (generated) → `HybridXxxSpecSwift.hpp` (C++) → JSI | `@_cdecl` Swift C functions in generated bridge; simpler 2-layer stack |
| **Lifetime** | GC-driven; `dispose()` for explicit release | Explicit `dispose()`; `NativeFinalizer` for `@NitroOwned` handles |

**Key architectural divergence**: RN Nitro's `JSIConverter<T>` is a single C++ template that is automatically recursive — `optional<vector<variant<A,B>>>` works without codegen. Flutter Nitro's generator must explicitly handle every composite type. This is why Flutter Nitro needs ~3000 unit tests for the generator, while RN Nitro's correctness is enforced by C++ type checking.

---

## 2. Type System Parity — Full Table

### Primitives

| Type | RN Nitro | Flutter Nitro | Notes |
|---|---|---|---|
| `double` / `number` | `double` | `double` | Identical |
| `int` / `number` | `int` (via `static_cast<int>`) | `int` (Int64) | RN truncates to 32-bit; Flutter is always 64-bit |
| `int64_t` / `Int64` | `int64_t` via BigInt | `int` (Int64) | RN needs BigInt in JS; Flutter int is already 64-bit |
| `uint64_t` / `UInt64` | `uint64_t` via BigInt | `uint64` custom type | Both supported |
| `bool` | `bool` | `bool` | Identical |
| `string` / `String` | `std::string` | `String` | Identical |
| `void` | `std::monostate` | `void` | Identical |
| `null` (explicit) | `NullType` sentinel | N/A | RN has explicit null type; Flutter uses `?` |
| `Date` | `std::chrono::time_point` ↔ `new Date(ms)` | `DateTime` ↔ `int64_t` ms epoch | Same millisecond precision |

### Optionals / Nullables

| | RN Nitro | Flutter Nitro |
|---|---|---|
| **Mechanism** | `std::optional<T>` — C++ value type, stack-allocated `{bool; T}` | `NitroOptXxx` `@Packed(1)` Dart structs (identical memory layout) |
| **Param wire** | Stack copy into C++ optional on every call | `Pointer<NitroOptXxx>` — Arena-allocated, 1 alloc per call |
| **Return wire** | Optional returned by value (stack), zero malloc | Currently `Pointer<NitroOptXxx>` (plan exists to switch to struct-by-value) |
| **Recursive** | Automatic — `optional<vector<T>>` works via templates | Codegen handles each combination explicitly |
| **Sentinel** | `std::nullopt` ↔ JS `undefined` | `hasValue=0` byte |

RN Nitro wins on zero-malloc optional handling. Flutter's plan would close this gap for sync returns.

### Collections

| Type | RN Nitro | Flutter Nitro | Flutter Advantage |
|---|---|---|---|
| `T[]` / `List<T>` | `std::vector<T>` — full element copy both ways; `canConvert` only checks first element | `List<T>` — sequential codec | `LazyRecordList<T>` for records: O(1) access, decode-on-demand |
| `Record<K,V>` / `Map<String,T>` | `std::unordered_map<string,T>` — iterate all keys | `Map<String,T>` — value type limited to `@HybridEnum/Record/Variant` | RN more flexible in value types |
| `[A,B]` tuple | `std::tuple<A,B>` — fixed-length JS Array | `@NitroTuple typedef (A, B)` — same binary as `@HybridRecord` | Dart 3 record syntax is ergonomic |
| TypedArrays | `ArrayBuffer` only (must unwrap `.buffer` from Uint8Array) | All 10 TypedData types (`Uint8List`, `Int32List`, `Float64List`, etc.) | **Flutter wins** — no `.buffer` unwrapping |

### Variants / Unions

| | RN Nitro | Flutter Nitro |
|---|---|---|
| **Mechanism** | `std::variant<A,B,C>` — `canConvert()` tries each type in order | `@NitroVariant` sealed class — `[1B tag][payload]` binary |
| **Disambiguation** | JS duck-typing at runtime; first `canConvert` match wins | Tag byte — O(1), type-safe |
| **Max cases** | Unlimited (`std::variant` can hold any N) | 255 cases (E014) |
| **Codegen required** | No (C++ templates handle it) | Yes — generator emits decode/encode for each case |

### Records / Structs

| | RN Nitro | Flutter Nitro |
|---|---|---|
| **C-ABI struct** | Plain TypeScript `interface` → C++ POD struct | `@HybridStruct` — C ABI, all-numeric fields, zero-copy option |
| **Rich record** | `CustomType<T>` + user `JSIConverter<T>` specialization | `@HybridRecord` — binary codec: nullable, nested, lists, embedded structs |
| **Zero-copy** | `ArrayBuffer` zero-copy via `MutableBufferNativeState` (automatic) | `@zeroCopy` annotation required; `@HybridStruct(zeroCopy: ['field'])` |

### Callbacks

| | RN Nitro | Flutter Nitro |
|---|---|---|
| **Sync callbacks** | `Sync<T>` tag — stays on JS thread | All callbacks are sync (NativeCallable) |
| **Async callbacks** | Default for `void`/`Promise<T>` return — dispatches via `CallInvoker` | No async callback concept |
| **Thread safety** | `AsyncJSCallback` is thread-safe (holds `weak_ptr<Dispatcher>`) | `NativeCallable.listener()` is thread-safe |
| **Callback return** | Sync: any type; Async: `Promise<T>` | `void`, `int`, `double`, `bool`, `String`, `@HybridEnum`, `@HybridRecord`, `@NitroVariant`, `AnyNativeObject` |
| **NOT supported** | — | `@HybridStruct` as callback return (L6 — no Arena lifetime) |

### Enums

| | RN Nitro | Flutter Nitro |
|---|---|---|
| **String enums** | `type X = 'a' \| 'b'` → C++ string-backed enum | `@HybridEnum` with String cases |
| **Number enums** | `enum X { A, B }` → C++ int-backed enum | `@HybridEnum` with int cases |
| **Non-contiguous** | Not supported — must be 0-based contiguous | `@HybridEnum(nativeValues: [0, 50, 100])` |

### AnyMap / AnyValue

| | RN Nitro | Flutter Nitro |
|---|---|---|
| **Types** | `null\|bool\|double\|int64_t\|string\|AnyArray\|AnyObject` | `null\|bool\|int\|double\|String\|List\|Map` |
| **Wire format** | JSI-marshaled (no custom binary — uses JSI converters) | Binary: `[1B tag][payload]` per value; `[4B len][count][pairs]` for map |
| **`uint64` in AnyValue** | Not supported (`int64_t` only) | Not supported (`int` = Int64 only) |
| **`ArrayBuffer` in AnyValue** | Not supported | Not supported |

---

## 3. Async / Promise / Stream

### RN Nitro

```
Promise<T>::async(fn)
  → ThreadPool (3–10 threads)
  → resolve via Dispatcher::runAsync
  → CallInvoker::invokeAsync (queued to next JS turn)
  → JS Promise resolves
```

- All hybrid methods run **synchronously on the JS thread** by design
- Background work: native creates a `Promise<T>`, calls `resolve()` from thread pool
- `AsyncJSCallback<void(T)>` dispatches to JS thread via `CallInvoker::invokeAsync`
- **Backpressure**: None. `ThreadPool::_tasks` is unbounded. `CallInvoker` queue is unbounded
- **Streaming**: None. Callbacks are the only native→JS push mechanism

### Flutter Nitro

```
@nitroAsync        → IsolatePool (least-busy worker, binary min-heap) → ~28 µs (macOS)
@NitroNativeAsync  → Dart_PostCObject_DL (native-driven)              → ~27 µs (macOS)

Stream<T>          → @NitroStream → ReceivePort → Dart_PostCObject_DL per item
  Backpressure: dropLatest / block / bufferDrop / batch
```

- Four async patterns: `@nitroAsync`, `@NitroNativeAsync`, `NitroPromise<T>` (Dart-only), `@NitroResult<T>`
- `@NitroNativeAsync` skips the isolate hop entirely because native drives its own async — the two mechanisms are close in raw latency (both dominated by the message round-trip / native work), but `@NitroNativeAsync` has one fewer moving part
- Built-in streaming with 4 backpressure modes — the single largest gap vs RN Nitro
- `IsolatePool` uses a **shared single reply port** and **least-busy scheduling** — zero per-call port creation overhead

| Annotation | Mechanism | Overhead (macOS) | When to Use |
|---|---|---|---|
| `@nitroAsync` | IsolatePool dispatch → worker isolate → FFI | ~28 µs | Native function is blocking; want Dart isolate isolation |
| `@NitroAsync(timeout: N)` | Same + timeout | ~28 µs | Blocking call with deadline |
| `@nitroNativeAsync` | `ReceivePort.nativePort` → `Dart_PostCObject_DL` | ~27 µs | Native already manages its own async (Swift async, Kotlin coroutine, C++ thread pool) |
| `NitroPromise<T>` | Dart `Completer<T>` wrapper | negligible | Composable async primitives in user code; not a bridge annotation |
| `@NitroResult<T>` | Sync or async; discriminated success/error tagged buffer | — | Error signaling without exceptions |

---

## 4. Platform Coverage

| Platform | RN Nitro | Flutter Nitro |
|---|---|---|
| iOS | ✓ Swift + C++ | ✓ Swift + C++ |
| Android | ✓ Kotlin + C++ | ✓ Kotlin + C++ |
| macOS | ✓ Swift + C++ | ✓ Swift + C++ |
| Windows | ✗ | ✓ C++ only |
| Linux | ✗ | ✓ C++ only |
| Web | ✗ | ✗ (stub; streams/NitroNativeAsync throw at runtime, W007 warning) |
| RN Worklets | ✓ `BoxedHybridObject` | N/A |
| Dart Isolates | N/A | ✓ IsolatePool (`@nitroAsync`) |

---

## 5. Generator / Codegen

| | RN Nitro (Nitrogen) | Flutter Nitro (nitro_generator + nitrogen_cli) |
|---|---|---|
| **IDL** | `.nitro.ts` TypeScript files (ts-morph) | Dart abstract classes + annotations (build_runner + analyzer) |
| **Config** | `nitro.json` (Zod-validated) | `@NitroModule()` annotation (no external JSON) |
| **Generator language** | TypeScript | Dart |
| **Test coverage** | — | 3000+ unit tests |
| **Generated: Shared** | `HybridXxxSpec.hpp` (C++ abstract) | `xxx.native.g.h` (C header) |
| **Generated: iOS** | Swift protocol + bridge class + C++ wrapper + Cxx umbrella header | Swift protocol (`Xxx.swift`) + modulemap |
| **Generated: Android** | Kotlin abstract class + fbjni C++ bridge class (`JHybridXxxSpec.hpp/cpp`) | Kotlin interface (`Xxx.kt`) + JNI C bridge (`xxx.bridge.g.h/.cpp`) |
| **Generated: Desktop** | ✗ | C++ abstract header + editable `.impl.g.cpp` starter + GoogleMock stubs + CMake |
| **Generated: Web** | ✗ | `xxx.web.dart` stub |
| **Autolinking** | Ruby podspec + Gradle + CMake + `*OnLoad.cpp` | CMake `CMakeLists_generated.cmake` + nitrogen link command |

Key difference: Flutter Nitro's generator is a `build_runner` builder — `flutter pub run build_runner build` regenerates everything. RN Nitro's `nitrogen` is a standalone CLI that generates once and the output is checked in.

---

## 6. Error Handling

| | RN Nitro | Flutter Nitro |
|---|---|---|
| **Sync errors** | C++ `throw` → JSI catches `std::exception` → `jsi::JSError` | Pre-allocated `NitroError*` out-param; `throwIfOutParamError()` reads 1 byte |
| **Swift errors** | Generated `Result<T,Error>` wrapper; rethrown in C++ | Same `Result<T,Error>` wrapper via `@_cdecl` bridge |
| **Kotlin errors** | `jni::JniException` translates `Throwable` ↔ `std::exception_ptr` | JNI bridge posts exception as `NitroError` out-param |
| **Async errors** | `Promise<T>::reject(exception_ptr)` → JS `Promise.reject(Error)` | `Completer.completeError()` via IsolatePool result |
| **Discriminated results** | ✗ — exceptions only | `@NitroResult<T>` → `NitroResultValue<T>` sealed: `[1B tag][payload]` |
| **Success path cost** | Exception handling at every sync call boundary | 1-byte `hasError` read; zero overhead on success |

---

## 7. Wire Formats at a Glance

### RN Nitro
- **Primitives**: direct JSI register (C++ ABI optimized by Hermes)
- **`std::optional<T>`**: `{bool has_value; T value}` — stack value, zero malloc
- **`std::vector<T>`**: full element-by-element copy via JSI Array
- **`std::variant<A,B>`**: try `canConvert()` in order; first match wins
- **`ArrayBuffer`**: `jsi::MutableBuffer` → zero-copy via `MutableBufferNativeState`
- **`AnyValue`**: JSI-marshaled through `JSIConverter<variant<...>>`
- **`Promise<T>`**: C++ state machine → JS `new Promise((resolve,reject)=>...)`

### Flutter Nitro
- **Primitives**: direct C ABI register
- **`T?`**: `@Packed(1)` struct `{uint8_t hasValue; T value}` as `Pointer<NitroOptXxx>` (Arena)
- **`@HybridRecord`**: `[4B len][fields: sequential LE binary]` as `Pointer<Uint8>`
- **`@NitroVariant`**: `[1B tag][optional payload: record codec]` as `Pointer<Uint8>`
- **`@HybridStruct`**: C ABI layout; pointer + length for `@zeroCopy` fields
- **TypedData**: `(Pointer<Uint8>, Int64 length)` — two C params; `@zeroCopy` for zero-copy
- **`NitroAnyValue`**: `[1B tag][payload]`; map = `[4B len][count][key-value pairs]`
- **`@NitroTuple`**: identical to `@HybridRecord` binary codec
- **Stream items**: `Dart_PostCObject_DL` — `kInt64/kDouble/kBool/kString/kNull/kTypedData`

---

## 8. What RN Nitro Has That Flutter Nitro Doesn't

1. **JSI zero-copy ArrayBuffer (automatic)**: `NativeArrayBuffer` → `jsi::ArrayBuffer` attaches `MutableBufferNativeState` — zero copy without any annotation. Flutter requires `@zeroCopy`.

2. **`BoxedHybridObject`**: Transfers a `HybridObject` to a different JSI runtime (React Native Worklets, Reanimated). No Flutter equivalent — Dart isolates have separate heaps.

3. **`HybridView`**: Native UI component exposure (React Native's platform view system integrated with HybridObject). Flutter has its own PlatformView system separate from FFI.

4. **`CachedProp<T>`**: Caches last JS value for native UI component props using `jsi::Value::strictEquals` to skip re-conversion on unchanged props.

5. **Template-recursive type codec**: `JSIConverter<optional<vector<variant<A,B>>>>` works without any codegen. Flutter must explicitly generate each combination.

6. **`canConvert()` duck-typing for variants**: Variant disambiguation uses runtime JS type inspection. Flutter uses a codegen'd tag byte (safer, but less flexible for dynamic JS values).

7. **`BorrowingReference`**: Custom invalidatable smart pointer for JSI objects that becomes `has_value() == false` when the Runtime is destroyed, preventing use-after-free. Flutter uses `Finalizer`.

---

## 9. What Flutter Nitro Has That RN Nitro Doesn't

1. **`Stream<T>` with 4 backpressure modes** — the single largest gap in RN Nitro. `dropLatest`, `block`, `bufferDrop`, `batch`. Batch mode reduces bridge crossing cost to 1 per N items for high-frequency sensors.

2. **`@NitroNativeAsync`** (~27 µs on macOS): Native drives its own async via `Dart_PostCObject_DL`. No Dart isolate spawn — one fewer moving part than `@nitroAsync` (~28 µs), and no worker-pool contention under concurrent load. Composable with Swift `async`, Kotlin coroutines, C++ thread pools.

3. **`@HybridRecord`**: Binary-encoded rich types with arbitrary nesting, nullable fields, `List<T>`, embedded structs. RN Nitro has no equivalent — only C++ POD structs or custom `JSIConverter<T>`.

4. **`LazyRecordList<T>`**: Indexed binary format + decode-on-demand + `NativeFinalizer`. O(1) random access to `List<@HybridRecord>` without eagerly decoding all elements. RN Nitro copies `std::vector<T>` element-by-element.

5. **`@NitroVariant` (tagged binary)**: O(1) decode via tag byte. RN Nitro's `std::variant` tries each `canConvert()` in order — O(N) worst case.

6. **Non-contiguous `@HybridEnum`**: `@HybridEnum(nativeValues: [0, 50, 100])`. RN Nitro only supports 0-based contiguous enums.

7. **All TypedData variants**: `Uint8List`, `Int8List`, `Int16List`, `Uint16List`, `Int32List`, `Uint32List`, `Float32List`, `Float64List`, `Int64List`, `Uint64List` — all directly bridgeable. RN Nitro only exposes raw `ArrayBuffer` and requires JS-side `.buffer` unwrapping.

8. **`@NitroResult<T>`**: Discriminated result type — `NitroOk<T>` vs `NitroErr<T>`. Binary wire `[1B tag][payload]`. Zero exception overhead on the success path.

9. **`@NitroOwned` + `NativeFinalizer`**: Explicit ownership transfer from native to Dart with automatic GC-safe cleanup. RN Nitro relies entirely on `shared_ptr` + JSI GC.

10. **`@NitroCustomType` + `NitroFfiCodec<T>`**: User-extensible Dart codec — `extend NitroFfiCodec<Color>`, implement `encode/decode`, done. RN Nitro's `CustomType<T>` + `JSIConverter<T>` requires C++ template specialization.

11. **Desktop (Windows + Linux)**: Generator outputs C++ abstract header, editable `.impl.g.cpp` starter, GoogleMock stubs, CMake wiring. RN Nitro targets mobile/macOS only.

12. **`IsolatePool` with binary min-heap scheduling**: Persistent worker isolates, shared single reply port, O(log N) least-busy dispatch, `Completer.sync()` for zero microtask overhead. RN Nitro's `ThreadPool` is simpler (std::queue, no adaptive scheduling).

13. **S8 out-param error pattern**: Pre-allocated `NitroError*` per module. Success path = 1 byte read. RN Nitro throws C++ exceptions (expensive).

14. **`AnyNativeObject` typed downcast**: `NitroInstanceRegistry.resolve<T>(ref)` — zero native call, pure Dart type check. RN Nitro uses `dynamic_pointer_cast<T>` (C++ RTTI).

15. **`@NitroTuple`**: Dart 3 positional record typedef as bridge type. `(int, String)` as a first-class parameter/return type with generated codec.

---

## 10. Performance Summary

| Operation | RN Nitro | Flutter Nitro | Winner |
|---|---|---|---|
| Sync primitive call | JSI dispatch + C++ virtual | FFI + C ABI + optional JNI | RN (fewer layers on iOS) |
| Nullable param | Stack `optional<T>` — zero malloc | `Pointer<NitroOptXxx>` — Arena alloc | RN |
| Nullable return | Stack value — zero malloc | `Pointer<NitroOptXxx>` (plan: struct-by-value) | RN (until plan implemented) |
| Async (isolate) | N/A | IsolatePool ~28 µs (macOS) | Flutter (has a mechanism) |
| Async (native-driven) | CallInvoker ~1 JS turn | `Dart_PostCObject_DL` ~27 µs (macOS) | Flutter |
| Stream (per item) | N/A (callbacks only) | `Dart_PostCObject_DL` per item | Flutter (unique feature) |
| Stream batch | N/A | 1 bridge crossing per N items | Flutter |
| Vector/List copy | `std::vector<T>` — full copy | `LazyRecordList<T>` — decode-on-demand | Flutter for records/variants |
| Error (success path) | Exception handling on every call | 1-byte read | Flutter |
| Variant decode | O(N) `canConvert` tries | O(1) tag byte | Flutter |
| ArrayBuffer zero-copy | Automatic via `MutableBufferNativeState` | Requires `@zeroCopy` annotation | RN |

---

## 11. Open Gaps in Flutter Nitro

| ID | Gap | Notes |
|---|---|---|
| L6 | `@HybridStruct` as callback return | Unsafe — no Arena available in NativeCallable body |
| L7 | `TypedData?` (nullable typed arrays) | Requires 3rd FFI param; excluded by design |
| L8 | Web / WASM full support | Streams + `@NitroNativeAsync` throw at runtime |
| L10 | `Map<String, @HybridStruct>` | No pointer ownership in map encoder; use `List` instead |

---

## 12. Verdict

**RN Nitro's core strength** is its **C++ template type system** — `JSIConverter<T>` is zero-codegen, infinitely recursive, and automatically zero-copy for `ArrayBuffer`. The bridge is essentially invisible at the type level. Optional handling is zero-malloc by construction.

**Flutter Nitro's strengths** are **richer runtime semantics**:
- Native streaming with 4 backpressure modes (the biggest functional gap in RN Nitro)
- `@NitroNativeAsync` for native-driven async at ~27 µs on macOS, no isolate hop
- `@HybridRecord` binary codec for rich structured data without C++ POD constraints
- `LazyRecordList<T>` O(1) access to native lists with decode-on-demand
- All 10 TypedData variants (not just ArrayBuffer)
- Windows + Linux desktop support
- Non-contiguous enums, discriminated results, explicit ownership transfer
- Dart-native codec extension (`NitroFfiCodec<T>`) vs C++ template specialization

The open gaps (`@HybridStruct` callback returns, `TypedData?`, full Web support) are correctness and safety decisions, not fundamental limitations.
