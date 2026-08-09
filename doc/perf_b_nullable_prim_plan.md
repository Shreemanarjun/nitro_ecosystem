# Improvement B — nullable-primitive returns without a per-call malloc

Status: **IMPLEMENTED & VERIFIED.** Improvement A (N-way instance cache) is also
done — see `benchmark/tool/bench_instance_cache.cpp`.

**Result:** sync nullable-primitive returns now borrow a per-thread scratch slot;
`@nitroAsync` keeps malloc (it decodes on another isolate thread). Microbench
`benchmark/tool/bench_opt_return.cpp` (build with `-fno-builtin-malloc
-fno-builtin-free`, else LLVM elides the allocation and the test is meaningless):
marshalling **15.03 ns -> 0.22 ns** per call single-threaded (~67x, ~14.8 ns saved
per call), **3.61 ns -> 0.06 ns** under 4-thread allocator contention.
Verified: 4340 generator tests + 679 macOS end-to-end integration tests pass; the
only remaining `NitroOpt` mallocs are `async_nullable_{int,double,bool}`, which
are exactly the ones Dart still frees.

## The cost today

Every `int?` / `double?` / `bool?` / `DateTime?` / `uint64?` **return** heap-allocates:

```cpp
auto* _out = (NitroOptInt64*)malloc(sizeof(NitroOptInt64));   // cpp_direct
uint8_t* ni_result = (uint8_t*)malloc(sizeof(NitroOptInt64)); // JNI (+ GetByteArrayRegion)
uint8_t* _res = (uint8_t*)malloc(9);                          // mixed/Swift
```

and Dart frees it immediately after a 2-field read:

```dart
final _intResult = res.decoded;
_nitroFree(res);            // explicit free — no NativeFinalizer
```

So each call pays a malloc + free (~40–80 ns) to move ≤16 bytes.

## The fix

Return a pointer to a **reusable per-thread scratch slot** instead of malloc'd
memory, and drop the Dart free. Emit once per bridge file:

```cpp
// Reusable per-thread scratch for nullable-primitive returns. Dart decodes the
// value immediately after the call returns (a 2-field read — no callbacks, no
// reentry, no allocation), so one slot per thread suffices. 16 bytes covers
// NitroOptInt64/NitroOptFloat64 (1B tag + 7B pad + 8B value) and NitroOptBool.
alignas(8) static thread_local uint8_t _g_opt_ret[16];
```

Each site then replaces only its allocation expression (`(NitroOptInt64*)_g_opt_ret`,
`(jbyte*)_g_opt_ret`, `uint8_t* _res = _g_opt_ret;`). `thread_local` is already
proven in these bridges (`static thread_local NitroError g_nitro_error`).

## HARD CONSTRAINT — sync only, never @nitroAsync

`@nitroAsync` dispatches through `NitroRuntime.callAsync` → `Isolate.run`
(`packages/nitro/lib/src/nitro_runtime.dart:523,545`), so the native call runs on
a **helper isolate thread** while the returned pointer is decoded on the **main
isolate**:

```dart
final optPtr = await NitroRuntime.callAsync<Pointer<NitroOptInt64>>(...); // thread A
final _intResult = optPtr.decoded;                                       // main thread
```

A TLS slot written on thread A is **not** visible as the same storage on the main
thread — it would silently decode garbage. Therefore:

| Path | Return storage | Dart frees? |
|---|---|---|
| sync methods (`!func.isAsync`) | TLS slot | **no** |
| property getters (always sync) | TLS slot | **no** |
| `@nitroAsync` methods | `malloc` (unchanged) | **yes** (unchanged) |
| `@nitroNativeAsync` | `malloc` + post (unchanged) | **yes** (unchanged) |

Async keeps malloc because it must — and a malloc is noise next to an isolate hop,
so no win is lost. The whole gain is on the sync hot path.

## All-or-nothing across platforms

The Dart free site is platform-independent (one `.g.dart` serves cpp/JNI/Swift).
So **every** native sync path must stop mallocing in the same change, or the
platforms that still malloc will leak silently.

## Exact edit sites

**Native — guard each on `!func.isAsync` (getters unconditional):**

| File | Lines | What |
|---|---|---|
| `…/c_bridge/cpp_bridge/cpp_direct_emitter.dart` | 568 (method), 653 (getter) | `($nitroType*)malloc(sizeof($nitroType))` → `($nitroType*)_g_opt_ret` |
| `…/c_bridge/cpp_bridge/jni_method_emitter.dart` | ~545, 570, 594, 619, 632, 645, 734 | `malloc(...)` + `GetByteArrayRegion(..., (jbyte*)X)` → write into `_g_opt_ret` |
| `…/c_bridge/cpp_bridge_generator.dart` | 793, 799, 805, 811 (methods); 915, 921 (getters) | `malloc(9)` / `malloc(2)` → `_g_opt_ret` |

Plus the `_g_opt_ret` declaration emitted once per bridge file in each of the three generators.

**Dart — add `bool optIsBorrowed = false` to `_emitReturnDecode`:**

- Definition: `…/dart/emitters/dart_async_helpers.dart:242`
- Emit `_nitroFree(...)` only when `!optIsBorrowed`, at the nullable-prim cases:
  `330` boolNullable, `337` intNullable, `340` doubleNullable, `356` dateTimeNullable
  (+ `uint64Nullable`, see `_asyncResVarName` at `:402–406` for the full kind list).
- Pass `optIsBorrowed: true` from the **sync** callers only:
  `dart_function_emitter.dart:240`, `:253`, and `dart_property_emitter.dart:20`.
- Leave the **async** callers unchanged (`dart_function_emitter.dart:169`, `:191`).

## Verification required (in order)

1. `flutter test` in `packages/nitro_generator` — update shape assertions in
   `cpp_bridge_generator_test.dart`, `nullable_return_branches_test.dart`,
   `optional_primitive_sentinel_test.dart`, `kotlin_jni_nullable_primitive_test.dart`,
   `all_generators_type_coverage_test.dart`, `property_all_types_test.dart`.
2. Regenerate `benchmark/` **and** `nitro_plugins/nitro_type_coverage/` (`flutter pub run build_runner build --delete-conflicting-outputs`).
3. Run `nitro_type_coverage` integration tests on **macOS (Swift)** and **Android
   (JNI)** — they cover every nullable-prim type end-to-end and would catch
   corruption or a missed site.
4. Microbench: add an `echoNullableInt`-style method to `benchmark_cpp`
   (spec + C++ impl — it currently has none) and a `nitro_cpp_nullable_int`
   harness case; compare pre/post. Pattern: `benchmark/tool/bench_instance_cache.cpp`.

## Improvement C — struct returns (IMPLEMENTED & VERIFIED)

Same sync/async split as B. Sync methods + property getters copy the struct into a
function-local `static thread_local <St> _g_ret_st;` and return its address;
`@nitroAsync` keeps `malloc`. Dart still calls `structPtr.ref.freeFields(_nitroFree)`
(inner heap fields — strings, nested structs — remain heap-owned); only the SHELL
free `_nitroFree(structPtr)` is dropped on sync paths, gated by the same
`optIsBorrowed` flag.

Sites: `cpp_direct_emitter.dart` (method guarded on `func.isAsync` + getter),
`cpp_bridge_generator.dart` (method guarded + getter), `jni_method_emitter.dart`
(struct return, guarded), and the `ReturnKind.struct` case in `dart_async_helpers.dart`.

Microbench `benchmark/tool/bench_struct_return.cpp` (same `-fno-builtin-malloc
-fno-builtin-free` requirement): **16.09 ns -> 0.99 ns** per call single-threaded
(~16x), **4.29 ns -> 0.25 ns** at 4 threads. Verified: 4341 generator tests + 679
macOS end-to-end integration tests pass. Five tests asserted the old contract and
were updated (`edge_cases_test.dart`, `dart_ffi_generator_test.dart`,
`generator_edge_cases_test.dart`, `all_generators_type_coverage_test.dart` x2) —
note specs containing BOTH sync and async struct returns still legitimately emit
`_nitroFree(structPtr)` for the async one.

## Remaining backlog (after C)
- **F** — string returns: length-prefixed so Dart skips the `strlen` re-walk.
- **E** — Android/JNI benchmark harness (per-op ns + GC counts) — prerequisite for D.
- **D** — JNI: reuse one thread-local direct `ByteBuffer` instead of per-call
  `NewByteArray`; kills the JVM byte[] garbage seen as RSS growth while profiling
  the coalescer. Biggest Android throughput/GC win; needs E to measure.
