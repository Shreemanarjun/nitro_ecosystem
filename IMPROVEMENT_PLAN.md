# nitro_ecosystem — Performance & Stability Improvement Plan

Scope: `packages/nitro` (runtime, ~1.4k LOC), `packages/nitro_generator` (generators, ~6.9k LOC), `packages/nitrogen_cli` (link/init).
Groupings below are ordered roughly by impact-per-effort.

---

## Performance

### 1. Skip the isolate hop for native-async calls
`NitroRuntime.callAsync` (`packages/nitro/lib/src/nitro_runtime.dart`) routes every async call through `IsolatePool` or `Isolate.run`. For native methods that are already async (Kotlin coroutine, Swift `async`, C++ with a background thread), the cheap path is:

- Generated C++ executes the work on a native thread pool.
- Result is posted back via `Dart_PostCObject` to a `ReceivePort`.
- No Dart isolate is ever spawned.

**Keep** the isolate pool only for *synchronous* native work that would otherwise block the UI thread.

### 2. Eliminate the 3-call-per-sync-call overhead
Each generated `callSync` today triggers:
1. The actual native call
2. `getError()` FFI call
3. `clearError()` FFI call

Replace with a single `int64` error-pointer **out-param** returned from the wrapper, or gate the error-check behind `NitroConfig.debugMode`. In release, error-checking should cost at most one branch on the return value.

### 3. Thread-local error slot (not per-dylib)
`NitroRuntime.checkError` reads from a single shared slot per library (`nitro_runtime.dart:70`). Two concurrent async calls on the same module race on that slot.

- Move error state to TLS in the C++ bridge.
- Read via the same TLS key on the calling thread.
- Removes a silent data-race class that only shows up under load.

### 4. `RecordWriter` / `RecordReader` byte-copy hot spots
`packages/nitro/lib/src/record_codec.dart`:

- `writeInt/writeDouble/writeInt32` allocate a fresh `ByteData(N)` per field, then `BytesBuilder.add(asUint8List())`. Swap for a **preallocated growable `Uint8List`** with direct offset writes.
- `readString` uses `_bytes.sublist(...)` which **copies**. Use `utf8.decoder.convert(bytes, start, end)` to decode in place.
- `encodeIndexedList` builds per-item `RecordWriter` + `takeBytes()` — merge into a single buffer with a two-pass (size/write) approach to skip intermediate copies.

### 5. Pool scheduling micro-opt
`IsolatePool._leastBusyIndex` (`isolate_pool.dart:154`) is O(N) per dispatch. Fine for N=4; at 50k calls/s across a larger pool it adds up.

- Min-heap ordered by `_inflight`.
- Or: if all workers tied, fall back to round-robin via a single counter.

---

## Stability

### 6. ABI / version handshake between `.so` and Dart
No magic-number or version check exists between generated native code and the Dart runtime. A stale `.so` after a regeneration = silent struct-layout drift → segfault.

- Emit `extern "C" uint32_t nitro_abi_version()` in every generated module.
- Check inside `NitroRuntime.init` with a clear error ("regenerate via `dart run build_runner build`").
- Bump the version anytime struct/record layout, enum FFI width, or error-slot ABI changes.

### 7. Library-load race in `_libCache`
`NitroRuntime.loadLib` (`nitro_runtime.dart:38`) uses an unguarded `Map<String, DynamicLibrary>`. First-call races across isolates can cause double-open on some platforms.

- Synchronize the load, or use an `Expando` keyed on library name.
- Document: `NitroRuntime.init` should pre-load all libraries declared by the linked plugins.

### 8. Stream port-death handling
`NitroRuntime.openStream` attaches a `Finalizer` on the `StreamController`, but a native emitter thread that ignores the return value of `Dart_PostCObject` will loop forever against a dead port after hot restart.

- Audit every generated emitter: `if (!Dart_PostCObject(...)) break;`
- Add a golden test per generator that checks for the bail-out pattern.

### 9. JNI `AttachCurrentThread` lifecycle
Kotlin generator: verify the JNI code caches `JNIEnv*` per worker thread and **detaches on isolate shutdown**.

- Without detach, zombie attached threads keep the JVM alive, leak memory, and block app shutdown.
- Add an `IsolatePool.dispose()` hook that notifies each worker to detach before the isolate exits.

### 10. `@HybridStruct(zeroCopy: ...)` ownership contract
Zero-copy typed-list fields have no documented contract about when the native side may free the buffer while Dart still holds a `Uint8List` view.

- Options: always wrap in a finalizable holder, OR emit a compile-time generator error if the field isn't wrapped in one.
- Document in `doc/lifecycle.md` with explicit "native MUST NOT free until Dart releases" rule + finalizer guarantee.

### 11. Concurrent access on generated Kotlin/Swift impls
Generated method signatures give no concurrency guarantee. Two Dart calls from different isolates land on different JNI threads simultaneously.

- Either emit `synchronized { }` wrappers in Kotlin by default,
- Or document explicitly ("impls must be thread-safe; Nitro will call from any thread").

---

## Generator / build

This section is structured as a **contributor roadmap**. Each numbered item below is a short,
independent PR-sized task with clear boundaries, so new contributors can pick one without touching
unrelated code. Golden tests under `packages/nitro_generator/test/` guard against regressions —
keep them green as you move.

### 12. Split `cpp_bridge_generator.dart` (1586 lines)

The file has two top-level emitters (`_generateCppDirect` at line 21, `_generateJniSwift` at
line 380) and ~15 helpers starting at line 1285. The hand-written `StringBuffer.writeln`
emission style is how past bugs slipped in (enum return type as `Any?`, missing `int` JNI call,
`void` returning `nullptr`, struct param / return).

**Constraint:** do **not** change generator output during the split. Every sub-task below must
produce byte-identical output. Golden tests in `test/cpp_bridge_generator_test.dart` verify this.

Each sub-task is independent — complete one, open a PR, move on.

- **12.1** — Extract helpers (lines 1285–end) into `cpp_bridge/type_mappings.dart`.
  Pure functions, no state. ~300 LOC moved. Zero behavior change.
- **12.2** — Extract `_generateCppDirect` into `cpp_bridge/cpp_direct_emitter.dart`.
  ~350 LOC moved. Becomes a class with one public `emit(spec) -> String`.
- **12.3** — Extract `_generateJniSwift` header/prologue (the first ~200 lines of the function)
  into `cpp_bridge/jni_swift_prologue.dart`.
- **12.4** — Extract JNI method-call emission (the per-function loop inside `_generateJniSwift`)
  into `cpp_bridge/jni_method_emitter.dart`.
- **12.5** — Extract Swift C-bridge emission (the per-function Swift block) into
  `cpp_bridge/swift_shim_emitter.dart`.
- **12.6** — Extract struct / record / enum helpers into `cpp_bridge/type_emitter.dart`.
- **12.7** — Introduce a `CppEmitter` class that replaces `StringBuffer.writeln(...)` with
  explicit `emitLine`, `emitBlock`, `emitIndent`. This makes indentation explicit and
  testable. Do **not** change any output; just route everything through the new class.
- **12.8** — Replace hand-written `StringBuffer` logic for the function-bodies with a small
  template-string helper (e.g. `_tmpl('jint ${fname}(...)')`). Only after 12.1–12.7 are merged.

**Acceptance for each sub-task:**
- `dart test packages/nitro_generator/` passes.
- `git diff` on any generated `.bridge.g.cpp` under `my_camera/` and `nitro_battery/` is empty
  after `dart run build_runner build --delete-conflicting-outputs`.

### 13. `build.yaml` ↔ `builder.dart` output drift

`packages/nitro_generator/build.yaml` declares 6 outputs but `builder.dart` declares **9**
(three more: `.native.g.h`, `.mock.g.h`, `.test.g.cpp`). `build_runner` honors the
`buildExtensions` getter in code, so this works today, but the mismatch is a silent landmine:
anyone editing `build.yaml` (thinking it's the source of truth) will produce broken builds.

- **13.1** — Add the missing three entries to `build.yaml`. Trivial 3-line PR. No behavior
  change. Good first issue.
- **13.2** — Add a unit test in `nitro_generator/test/` that asserts `build.yaml`
  `build_extensions` equals `NitroGeneratorBuilder().buildExtensions`. Prevents future drift.

### 14. Incremental build granularity

The current `buildExtensions` (`lib/{{dir}}/{{file}}.native.dart` → 9 outputs) already gives
`build_runner` per-spec invalidation; this is **not** a single-builder-for-all-specs problem.

What's actually slow in practice:

- **14.1** — When a shared `@HybridRecord` / `@HybridStruct` / `@HybridEnum` type moves between
  spec files, all specs that import it rebuild. Document this in the generator README with
  the rule "keep shared types in a dedicated `types.native.dart`" so contributors don't
  accidentally spread shared types across module specs.
- **14.2** — The `try { ... } catch (e) { log.warning('nitrogen: Could not process...') }`
  in `builder.dart:94` swallows stack traces into a warning, which `build_runner` hides
  behind `--verbose`. Escalate to `log.severe` so failures surface immediately.
- **14.3** — `DartFormatter().format` is re-instantiated per spec per build (line 69).
  Hoist to a single `static final _formatter = DartFormatter();` on the builder class.

### 15. `spec_extractor` type-name lookup — **mostly done, verify and lock in**

`PLATFORM_EXPANSION_PLAN.md` called out replacing `NativeImpl.values[index]`. The switch in
`spec_extractor.dart:71` already does this with the concrete type names (`SwiftImpl`,
`KotlinImpl`, `CppImpl`, `WasmImpl`) plus a safety-net for `AppleNativeImpl` / `AndroidNativeImpl`
sealed-class returns. Remaining work:

- **15.1** — Add a test in `spec_extractor_test.dart` covering each of the four concrete type
  names **and** each sealed-class safety-net branch. Pins the current behavior.
- **15.2** — The default `_ => throw InvalidGenerationSourceError('Unknown NativeImpl: $typeName')`
  branch should include the spec file path and the field name for easier debugging. Small
  string-formatting change.
- **15.3** — Run the switch through a named helper `NativeImpl.fromTypeName(String)` exposed
  on `nitro_annotations` so `nitrogen_cli` and other consumers can share it. Keeps the single
  source of truth for the mapping.

### 16. `dart_api_dl.c` absolute-path fragility
`nitrogen link` writes a machine-specific absolute pub-cache path into `src/dart_api_dl.c`. CI / fresh clones break until re-link.

- Resolve path at **build time** from `.dart_tool/package_config.json`, not link time.
- Or commit a path-agnostic shim that resolves via CMake.

---

## DX / observability

### 17. Timeline integration
Extend the existing slow-call warning in `NitroRuntime.callAsync`:

- Emit `Timeline.startSync('nitro:<method>')` / `finishSync()` around every bridge call.
- Shows up in DevTools timeline alongside Flutter frames — immediately actionable.
- Gate behind `NitroConfig.debugMode` to avoid overhead in release.

### 18. Better error surface when nitrogen link hasn't been re-run
Common dev failure: added a new `.native.dart`, forgot `dart run nitrogen link`, got a missing-symbol crash at runtime.

- Generator can emit a checksum of the spec set.
- CLI `link` writes the checksum into `CMakeLists.txt`.
- Runtime `init` compares Dart-side checksum against native-side — prints a clear "run `nitrogen link`" message instead of segfaulting.

---

## Sequencing suggestion

**Phase A (correctness-leaning quick wins):**
7 (load race) → 13.1 (build.yaml sync) → 15 (extractor tests) → 6 (ABI version) → 18 (link checksum)

**Phase B (perf-leaning, low-risk):**
2 (single-call error path) → 4 (record_codec copies) → 17 (Timeline)

**Phase C (structural, contributor-friendly):**
12.1–12.8 (cpp_bridge_generator split, one sub-PR at a time) → 1 (skip isolate hop for native-async) → 3 (TLS error slot)

**Phase D (stability hardening):**
8 (stream port death) → 9 (JNI detach) → 10 (zero-copy contract) → 11 (thread-safety docs)

---

## Contributing to items 12–15

These are the entry-point tasks for new contributors. They share a few rules:

1. **One sub-task per PR.** Sub-tasks are designed to be independent; do not bundle them.
2. **Byte-identical output** for the generator split (item 12). Run
   `dart run build_runner build --delete-conflicting-outputs` in `my_camera/` and
   `nitro_battery/` and confirm `git diff` is empty on generated files before opening a PR.
3. **Golden tests first.** If you see untested generator output, add the golden test in a
   separate PR *before* the refactor PR. That way a reviewer can trust the refactor.
4. **No behavior changes smuggled into refactors.** If you spot a bug while splitting a file,
   open a separate issue / PR for the fix. Refactor PRs should be reviewable in under 15 min.
