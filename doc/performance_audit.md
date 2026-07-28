# Performance audit — Flutter Nitro vs React Native Nitro (latest)

Date: 2026-07-28. Compares our runtime hot paths against React Native Nitro's
latest release (v0.36.1) and ranks concrete improvement opportunities, each
backed by a file:line and, where measured, benchmark evidence.

TL;DR: our runtime is already heavily optimized and at feature parity. RN
Nitro's newest perf work is JSI-specific and doesn't apply to us. The real
remaining wins are in the **data-marshalling paths** (Map/record/string), not
scalar dispatch — the scalar path is already near the FFI floor and resists
cheap improvement (measured).

---

## 1. What RN Nitro changed recently (v0.35.11 → v0.36.1)

| Commit | Kind | Applies to us? |
|---|---|---|
| `733cac0f` perf: Reuse cached `PropNameID`s in `Record<string,T>::toJSI` | perf | **No** — JSI-specific |
| `8e31e1ae` feat: variants of union-style enums | codegen | Already covered by `@NitroVariant` |
| `9c0172bd` fix: union inline joining not generating enums | codegen | N/A |
| Promise `_state` data-race fixes (`#1397/#1398/#1413`) | correctness | Our async path is isolate/port-based, not shared C++ Promise state |

**The perf commit in detail:** RN Nitro converts a `Record<string,T>` (a
`std::unordered_map`) to a JS object by calling `object.setProperty(rt, key, …)`
per entry. Each `setProperty` used to re-intern the key string into a JSI
`PropNameID`; they now cache the `PropNameID` per (runtime, key).

**Why it doesn't apply to us:** we don't touch JSI. `@HybridRecord` crosses the
bridge as a **positional binary blob** (no string keys on the wire at all), and
`Map<String,T>` encodes keys once into a length-prefixed byte buffer. There is
no per-property string interning to cache — our binary codec structurally
avoids the cost they just optimized. This is a positioning win, not a gap.

RN Nitro's whole hot-path perf philosophy is *cache reusable JSI identifiers/
objects* (`PropNameIDCache`, `JSICache`, `HybridObject::_objectCache` per
runtime, cached function references). The equivalent caches on our side already
exist (see §3).

---

## 2. Feature parity (from prior audits, unchanged)

All known RN Nitro feature gaps were closed by 2026-07-01 (see
`rn_nitro_comparison.md`): DateTime, tuples, uint64, `AnyNativeObject`,
`@NitroCustomType`, null variant cases, int-keyed maps. `BoxedHybridObject<T>`
is structurally N/A (Dart isolates have separate heaps). We additionally have
features RN Nitro lacks entirely: `Stream<T>` + 4 backpressure modes,
`@NitroNativeAsync` (zero-hop `Dart_PostCObject_DL`), `@NitroResult<T>`,
`@HybridStruct` zero-copy POD, non-contiguous enums, desktop generator.

---

## 3. Optimizations we ALREADY have (parity with, or ahead of, RN Nitro)

Confirmed present in the runtime — do not "re-discover" these:

- **`isLeaf: true` FFI bindings** for primitive-only / `*Fast` methods — skips
  the Dart VM safepoint transition (~50–200 ns/call). `dart_impl_class_emitter.dart:170`.
- **Per-instance error slot** (design "S8") — one `NitroError*` `calloc`'d per
  impl in its constructor and reused every sync call; `throwIfOutParamError`
  fast-path is a single `hasError == 0` byte read. Replaced the old
  3-FFI-call get/clear round-trip. `nitro_runtime.dart:272`.
- **Library cache + refcount** — `loadLib` memoizes the `DynamicLibrary`.
- **Isolate pool** for `@nitroAsync` with a persistent reply port and a
  per-worker `.asFunction()` binding cache keyed by pointer address.
- **Kotlin thread-local reusable decode buffers** (`_tlsOut`/`_tlsBuf` with
  `.reset()`) — no per-call allocation for nullable-prim/record decode.
- **JNI `jmethodID` cache** — every method ID resolved once at load
  (`g_mid_*`), not per call; `JNIEnv` via cheap TLS `GetEnv`.
- **Kotlin instance dispatch via `ConcurrentHashMap`** — lock-free reads.
- **`LazyRecordList`** — O(1) offset-indexed decode-on-access with a decoded-
  item cache and a `NativeFinalizer` cache keyed by free-fn address.
- **Static `Utf8Decoder`** reused in `RecordReader`.
- **Positional binary record codec** — avoids RN Nitro's per-property JSI
  string interning entirely.

---

## 4. The scalar sync path — measured, resists cheap improvement

macOS M4, profile mode (numbers in µs; see `benchmark/RESULTS.md`):

| | median | vs raw FFI |
|---|---|---|
| Raw FFI (leaf) | 0.013 | 1.0× (floor) |
| Nitro C++ (leaf) | 0.277 | +0.264 µs bridge tax |

The ~0.26 µs bridge tax on a scalar C++ call breaks down as:

**Dart side** — the generated proxy wraps the call:
`NitroRuntime.callSync(() { _addFastPtr(_instanceId, a, b, _nitroErr); }, methodName: 'addFast')`.
That is a closure + a generic wrapper on top of the direct FFI call the raw-FFI
tier makes.

**C++ side** (`cpp_direct_emitter.dart:141`) — every method entry does:
```cpp
auto _impl = _nitro_get_instance(instanceId);  // std::mutex lock + unordered_map::find + shared_ptr copy
```

### Experiment (done, null result)

Hypothesis: at the default `logLevel = error`, `callSync` fell through its
fast path (which only triggered at `none`) and allocated a
`'callSync(addFast)'` tag string per call. **Fixed** `callSync` to take the
allocation-free path at `error`/`warning` too (build the tag lazily only on a
thrown error) — `nitro_runtime.dart:378`.

**Measured impact: none** (0.265 → 0.277 µs, within noise). The Dart AOT
compiler already constant-folds the tag for const method names and inlines
tiny methods, so the allocation wasn't happening for `addFast`. The change is
kept (it is correct, and does remove the runtime tag build for **large,
un-inlined** method bodies — the common shape for real data-marshalling
methods — and makes the error-level fast path explicit), but it is **not**
claimed as a scalar-path win. All 113 `packages/nitro` tests pass, including
the dedicated `call_sync_test.dart` logging/threshold suite.

Takeaway: the scalar path is already close to the practical FFI floor for a
*safe* bridge; the remaining tax is structural (the FFI boundary with 4 args,
the closure/wrapper frame, and the C++ instance-lookup below). Cheap wins are
exhausted here.

---

## 5. Ranked improvement opportunities (each needs its own focused, measured effort)

Ordered by value ÷ risk. None are "free"; each is a generator change requiring
regeneration + the full test suite + re-measurement across platforms.

### A. C++ instance lookup — drop the mutex + `shared_ptr` from the read path
`cpp_direct_emitter.dart:141`. Every C++ method call takes a global
`std::mutex` and copies a `std::shared_ptr` (2 atomic RMWs) to resolve
`instanceId → impl`. RN Nitro captures the `HybridObject*` directly in the JSI
closure and pays none of this.
- **Fix:** return a borrowed raw `Hybrid*` (the map keeps the owning
  `shared_ptr`), and add a lock-free single-`id` cache (`std::atomic`) for the
  common singleton case, invalidated under the mutex on `destroy_instance`.
- **Value:** ~25–40 ns/call on the C++ tier (~10–15% of the tax). Modest but
  the most-confirmed per-call structural cost.
- **Risk:** medium — lifetime/threading; the raw-pointer hand-out relies on the
  Dart-side `NativeFinalizer` owning the lifetime (already true). Keep the map
  + null check as the safety net.

### B. `Map<String,T>` encode does 3 full buffer copies
`dart_map_factory_emitter.dart:38`, `dart_map_encode_helpers.dart:229`. Encoding
a map builds a `BytesBuilder`, then `Uint8List.fromList([...spread...])` (copy
2), then `alloc.setAll` into native memory (copy 3), plus a per-key
`utf8.encode`. Decode copies the whole payload again and does a per-entry
`malloc`/`free` for record values.
- **Fix:** size the payload once and write directly into a single native
  buffer (length prefix + entries), eliminating copies 2 and 3; decode in
  place over the native pointer.
- **Value:** high on **map-heavy** workloads (real apps passing config/JSON-
  like maps); scales with map size. Not visible on the current scalar
  benchmark (no map case — worth adding one).
- **Risk:** medium — codec wire format must stay byte-identical; well covered
  by `nitro_type_coverage`'s map tests.

### C. `_decodeUtf8NoBomStrip` builds a growable `List<int>` per byte
`ffi_utils.dart:160`. Every native→Dart string manually `strlen`s then appends
one code point at a time to a growable list, to preserve a leading BOM (a
deliberate fix — see `ffi_string_bom_fix.md`). `RecordReader` already uses the
fast `Utf8Decoder` elsewhere.
- **Fix:** decode with `Utf8Decoder` over a presized view and re-prepend the
  BOM only when the first bytes are `EF BB BF`, instead of the per-byte loop.
- **Value:** medium on **string-heavy** workloads; every returned string pays
  this today.
- **Risk:** low–medium — must keep the BOM-preservation behavior the existing
  tests lock.

### D. `@nitroNativeAsync` allocates a `ReceivePort` + `calloc` error slot per call
`nitro_runtime.dart:514`, `dart_async_helpers.dart:21`. Unlike the sync path
(reused error slot), each native-async call allocates a single-use
`ReceivePort`, a `Future` chain, and a fresh `NitroErrorFfi`.
- **Fix:** a small pool of reusable ports/error slots keyed to in-flight calls.
- **Value:** medium on async-heavy workloads; async calls are µs-scale so the
  relative cost is lower than on the sync path.
- **Risk:** medium-high — concurrency correctness (why the slot is per-call
  today).

### E. (Biggest raw win, highest blast radius) inline the sync fast path — drop the `callSync(() => withArena(...))` closure + fresh `Arena` per call
`dart_function_emitter.dart:212`, `ffi_utils.dart:8`. Methods with any
non-scalar param wrap each call in a closure passed to `callSync`, and
`withArena` allocates a fresh `Arena` (with an internal growable list) per call.
- **Fix:** generate a direct FFI call + inline `throwIfOutParamError`, wrapping
  in `callSync`/timeline only when a compile-time `bool.fromEnvironment`
  instrumentation flag is set; reuse an instance-local arena (reset, not
  realloc) for the single-buffer common case.
- **Value:** potentially the largest, and uniform across all platforms — but
  changes error/logging/timeline behavior on the hot path and touches every
  generated method.
- **Risk:** high — regenerate everything, re-verify the 5-platform matrix, and
  re-validate the instrumentation/logging contract.

---

## 6. Recommendation

The runtime is in good shape and ahead of RN Nitro on features. Do **not**
chase the scalar path further — it is at the practical floor and the obvious
lever (callSync tag alloc) measured as noise.

If pursuing wins, take them one at a time, each with a benchmark case that
exercises it and a before/after measurement, in this order: **A** (contained,
most-confirmed cost) → **C** (low risk, string-heavy) → **B** (high value on
map-heavy, add a map benchmark case first) → **D**/**E** (higher risk, do only
with a clear workload justifying them). Add `Map<String,T>` and native-async
cases to `benchmark/example/lib/harness/bench_harness.dart` before B/D so the
wins are measurable, the same way the scalar/FNV/sieve cases gate the others.
