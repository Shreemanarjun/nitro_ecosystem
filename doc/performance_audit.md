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

## 5. Results — A–E worked one at a time, each with a benchmark case

All measured on macOS M4, profile mode, `bench.sh --mode quick`, isolating one
change at a time (baseline → +A → +A+C → +A+B+C). Two new harness cases were
added first so B and D are measurable: `nitro_cpp_map` (Map<String,int> echo)
and `nitro_native_async_scalar`/`nitro_async_scalar` (near-zero-payload async).
Correctness for the kept changes is gated by **679/679 nitro_type_coverage
integration tests on macOS** (maps §58/L4a/L4b, strings+BOM §57, dispose/multi-
instance §50), 4336 generator tests, and 121 nitro-runtime tests.

| Opt | Change | Case | Before → After | Verdict |
|---|---|---|---|---|
| **B** | Map encode: drop the element-wise `Uint8List.fromList([...spread])`; write `[4B len][payload]` straight to native | `nitro_cpp_map` | **9.30 → 3.45 µs (−62.9%)** | **KEPT — the win of the exercise** |
| **C** | String decode: per-byte `List<int>` loop → native `Utf8Decoder` (BOM preserved by stripping/re-prepending leading BOM bytes) | `nitro_string_roundtrip` | **0.654 → 0.552 µs (−15.6%)** | **KEPT** (new `string_decode_test.dart` locks BOM behavior) |
| **A** | C++ instance lookup: `mutex + shared_ptr` copy per call → lock-free single-id cache + borrowed raw `Hybrid*` | `nitro_cpp_add` | 0.272 → 0.258 µs (−5.1%) | **KEPT, but within noise** (control `raw_ffi_add` swung ±13–100% across runs). Removes real work (~20–30 ns) and matches RN Nitro's direct-pointer dispatch; sub-noise on this bench. |
| **D** | Native-async: pool the per-call `ReceivePort` + `calloc` error slot | `nitro_native_async_scalar` = 13.3 µs | — | **DECLINED (evidence-based).** The new scalar case shows native-async is **event-loop-delivery-bound** (`Dart_PostCObject`→Future), not alloc-bound; it is already 2× faster than the isolate-pool async (13.3 vs 27.7 µs). Pooling needs message multiplexing (replacing clean one-port-per-call routing) for a bounded ~1–2 µs at real concurrency risk. |
| **E** | Inline the sync fast path; reuse an instance-local `Arena` instead of a fresh one per call | (string/struct) | — | **DECLINED.** Safe arena reuse is blocked by **sync-callback reentrancy**: a call can re-enter another call on the same instance via a synchronous callback, and a shared/reset arena would corrupt in-flight pointers. The per-call arena's isolation is a correctness feature; the closure-elimination half also changes the error/logging contract on every generated method. Not justified.

Incidental fix found while adding the map case: the direct C++ emitter typed a
`Map<String,T>` param `void*` while the `.bridge.g.h` header typed it
`uint8_t*` — a conflicting-types compile error for any all-cpp map param. Fixed
to match (`cpp_direct_emitter.dart`); this was a latent generator bug, not
benchmark-specific.

### Follow-on: #1 — `List<@HybridRecord>` encode (the biggest single win)

Same data-path family as B, and the flagged worst allocator in the codec.
`RecordWriter.encodeIndexedList` built **one 256-byte `RecordWriter` per list
item**, took each item's bytes with a copy, then copied every item a second
time into a final writer (~2N copies + N allocations for an N-item list).
Replaced with a **single writer**: reserve the `[count][offset table]`, write
each item directly (recording its start offset), then backpatch the offset
table via a new `RecordWriter._patchInt64`. One writer, each item written once,
byte-identical `[count][8B×n offsets][items]` wire format.

| Opt | Case | Before → After | Verdict |
|---|---|---|---|
| **#1** | `nitro_cpp_record_list` (16-item `List<@HybridRecord>` echo) | **3.842 → 1.770 µs (−53.9%)** | **KEPT** — clean, controls flat |

Correctness: 6 new `indexed_list_codec_test.dart` round-trip tests (empty,
single, growing-mid-list, 16-item, random-access-hits-right-offset, unicode) +
**679/679 nitro_type_coverage integration on macOS** (§L1 `Stream<@HybridRecord>`,
§63 `List<@HybridEnum>`, §64 `List<@NitroVariant>`, `List<TcConfig>` round-trips
all pass on the real bridge).

**Running scoreboard of measured data-path wins** (all on the macOS C++ bridge,
each isolated with controls tracked):

| Path | Win |
|---|---|
| `List<@HybridRecord>` encode (#1) | **−53.9%** |
| `Map<String,int>` encode (B) | **−62.9%** |
| native → Dart string decode (C) | **−15.6%** |

The audit's core thesis is now measured three times over: the payoff is in the
data-marshalling paths, and it is large (−15% to −63%) and low-risk, while
scalar dispatch (A) stays below the noise floor on every platform.

### Community PR #38 reconciliation (5-run averaged)

A community perf PR (#38, issues #31–#37) landed against the same runtime
files. Its good parts were integrated on top of the C/#1 work and re-measured
with **5 independent benchmark runs averaged** (single runs proved too noisy —
one showed `buffer_pinned −11%` that averaging revealed as −1.6% within-noise).
Baseline = the committed runtime (`c589b80`); "after" = all session runtime perf
(C + #1 + the #38-reconciled changes). 148 nitro unit tests (incl. a new
21-case `nitro_promise_test.dart`) + **679/679 type_coverage integration on
macOS** gate correctness.

| Case | Base (5-run mean) | After (5-run mean) | Δ | Ranges overlap? |
|---|---|---|---|---|
| `nitro_string_roundtrip` (C, #31) | 0.643 µs | 0.525 µs | **−18.4%** | no — real |
| `nitro_cpp_record_list` (#1 + #34 `toNative`) | 3.779 µs | 1.667 µs | **−55.9%** | no — real |
| `nitro_native_async_scalar` (#33) | 13.367 µs | 13.295 µs | −0.5% | yes — noise |
| `nitro_async_record` (#33) | 27.850 µs | 27.715 µs | −0.5% | yes — noise |
| `nitro_buffer_pinned` (#32) | 515.9 µs | 507.7 µs | −1.6% | yes — noise |
| `nitro_cpp_add` / `raw_ffi_add` (ctrl) | 0.265 / 0.013 | 0.256 / 0.013 | −3.3 / −3.2% | ctrl moved too |

Adopted from #38 and kept: `_log` `.index` O(1) rank; `errPtr.ref` caching on
the error path (#37); ZeroCopy view caching (#32); `callAsync` + `openNativeAsync`
fast paths mirroring callSync (#33); `RecordWriter.toNative` copy-elimination
(#34); lazy `NitroPromise` listener lists (#36). These last four don't move
median latency in a tight loop (rows above) but cut per-call allocations — GC
pressure relief that matters in real apps, not micro-benchmarks. **Two #38
sub-changes were REJECTED, each caught by a test:**

- **#31 `utf8.decode` fast path** — bare `utf8.decode` is *strict* and throws
  `FormatException` on malformed bytes the old decoder mapped to `U+FFFD`. The
  local C fix (`Utf8Decoder(allowMalformed: true)`) is kept instead — same VM
  speed, no regression.
- **`Completer.sync()` in NitroPromise (#36) and `Error.throwWithStackTrace` in
  IsolatePool (#35)** — both interact with a sync completer to deliver a
  rejection *synchronously* before its handler is attached, surfacing un-awaited
  rejections as unhandled errors (and, in the pool, throwing into `dispose()`).
  The reject-path and dispose tests prove it; the async-completer /
  return-`Future.error` forms are kept.

The scoreboard's #1 figure firms up to **−55.9%** and C to **−18.4%** under
5-run averaging (both with non-overlapping ranges) — the single-run −53.9% /
−15.6% were in the right place but noisier.

**Takeaway:** the big, real wins were in the **data-marshalling paths** exactly
as the §4 analysis predicted — map encode (−63%) and string decode (−16%) —
both low-risk and validated. Scalar dispatch (A) and the async/arena paths
(D/E) are either sub-noise or blocked by correctness constraints, so they were
kept-with-caveat (A) or declined with rationale (D, E) rather than shipped for
uncertain benefit.

**These ARE C++-bridge numbers.** `benchmark_cpp` uses `AppleNativeImpl.cpp` on
macOS, so the `nitro_cpp_*` tier — including `nitro_cpp_map` and `nitro_cpp_add`
— is the C++ direct bridge (`cpp_direct_emitter.dart`), the exact path A and B
modify. The compiled `benchmark_cpp.bridge.g.mm` includes the generated
`.bridge.g.cpp` with A's lock-free instance cache and 15 `_nitro_get_instance`
call sites. (The `nitro_platform_*` tier is Swift — that's the only Apple-Swift
path.) So the map win is a genuine Dart↔C++ communication improvement on the
same code that Windows/Linux/all-cpp-Android ship.

### Second-platform validation — Android (OnePlus CPH2447, release)

The all-cpp `benchmark_cpp` on Android compiles the *same* generated
`benchmark_cpp.bridge.g.cpp` (A's cache) and runs the *same* Dart proxy (B's
`setRange` map encode), so a real-device run exercises both.

- **Correctness ✓** — an A-ON and an A-OFF release run both completed with all
  FNV and sieve tiers agreeing and the map echoing correctly. A+B+C are correct
  on a real, non-Apple C++ bridge.
- **Magnitude: inconclusive on-device.** Between the two release runs the map
  case swung 8.55 ↔ 4.05 µs and `nitro_cpp_add` 0.493 ↔ 0.464 µs — an 8→4 µs
  swing that A (a ~30 ns instance-lookup change) cannot possibly cause. It is
  Android core-scheduling / DVFS noise (which CPU the FFI thread lands on),
  the same variance documented in the release-mode `-O0` investigation. A
  single run per config can't resolve A's delta when the *map* alone varies 2×
  from scheduling; a clean A number would need many averaged runs with pinned
  affinity (a `simpleperf`/Perfetto session), which is out of scope here.

**Net for A:** it is a correct, principled change that removes a real
per-call `std::mutex` + `shared_ptr` copy and matches RN Nitro's direct-pointer
dispatch, but its ~20–30 ns delta is **below the measurement floor on every
platform available** (macOS thermal noise, Android core-scheduling noise). Kept
on merit, not claimed as a measured win. **B's −63%, by contrast, was measured
cleanly on the macOS C++ bridge** (large enough delta, controls tracked) and is
a Dart-side change that carries to Android identically.

---

## 6. Original ranked opportunities (pre-implementation notes, retained for context)

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

## 7. Recommendation

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
