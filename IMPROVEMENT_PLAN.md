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

#### How it works today

`@NitroAsync` → `BridgeFunction.isAsync = true` → `dart_ffi_generator.dart` emits `NitroRuntime.callAsync(fn, args)` → `IsolatePool.dispatch` sends a `SendPort` message to a worker isolate → worker calls the FFI function (blocks) → reply sent back → `Future<T>` completes. Two isolate-message crossings even when the native side is non-blocking.

Streams already use the right pattern (`Dart_PostCObject_DL` → `ReceivePort`). Async methods need the same treatment.

#### Implementation plan

**Step 1 — New annotation (`nitro_annotations`)**

Add `@NitroNativeAsync` (or `@NitroAsync(native: true)`) to `packages/nitro_annotations/lib/src/annotations.dart`:

```dart
// Marks a @NitroAsync method whose native impl posts the result itself.
// No Dart isolate is spawned; Dart awaits a ReceivePort.
const nitroNativeAsync = NitroNativeAsync();
class NitroNativeAsync { const NitroNativeAsync(); }
```

**Step 2 — Bridge spec (`bridge_spec.dart`)**

Add `isNativeAsync` field to `BridgeFunction`. It is mutually exclusive with `isAsync` (spec extractor validates this).

**Step 3 — Spec extractor (`spec_extractor.dart`)**

Detect `@NitroNativeAsync` alongside `@NitroAsync`:

```dart
final isNativeAsync = nativeAsyncChecker.hasAnnotationOf(m);
if (isAsync && isNativeAsync) throw InvalidGenerationSourceError(
  'Cannot use both @NitroAsync and @NitroNativeAsync on the same method.');
```

**Step 4 — Dart FFI generator (`dart_ffi_generator.dart`)**

For `isNativeAsync` methods, emit a `ReceivePort`-based future instead of `callAsync`:

```dart
// Generated output for @NitroNativeAsync Future<String> fetchData(String q):
Future<String> fetchData(String q) async {
  checkDisposed();
  final _port = ReceivePort();
  _fetchDataPtr(_encodeString(q), _port.sendPort.nativePort);
  final _raw = await _port.first;
  _port.close();
  return _raw as String; // or unpack via RecordReader / Utf8 for complex types
}
```

The FFI lookup gains an extra `int64_t dart_port` final parameter:

```dart
late final void Function(Pointer<Utf8>, int) _fetchDataPtr =
    _dylib.lookupFunction<Void Function(Pointer<Utf8>, Int64),
                          void Function(Pointer<Utf8>, int)>('lib_fetch_data');
```

**Step 5 — C++ bridge generator (`cpp_bridge_generator.dart`)**

For `isNativeAsync` functions, generate a `void`-returning wrapper with a `dart_port` parameter. No `get_error` / `clear_error` suffix — errors are posted via the port:

```cpp
void lib_fetch_data(const char* q, int64_t dart_port) {
    if (!g_impl) {
        // Post error object back to Dart via port instead of thread-local error slot.
        Dart_CObject err { .type = Dart_CObject_kNull };
        Dart_PostCObject_DL(dart_port, &err);
        return;
    }
    // Native impl receives dart_port and posts result when ready.
    g_impl->fetchData(std::string(q), dart_port);
}
```

**Step 6 — C++ interface generator (`cpp_interface_generator.dart`)**

Add `int64_t dartPort` to the abstract method signature:

```cpp
virtual void fetchData(const std::string& query, int64_t dartPort) = 0;
```

**Step 7 — Swift generator (`swift_generator.dart`)**

Wrap the `async` Swift call in a `Task` that posts via `Dart_PostCObject_DL`:

```swift
// Generated Swift bridge stub:
@_cdecl("lib_fetch_data")
func lib_fetch_data(_ q: UnsafePointer<CChar>!, _ dartPort: Int64) {
    Task {
        let result = await impl.fetchData(String(cString: q))
        var obj = Dart_CObject(type: .string, value: .init(as_string: result))
        Dart_PostCObject_DL(dartPort, &obj)
    }
}
```

A small `nitro_post_helpers.h` header will wrap common `Dart_CObject` setup for strings, int64, doubles, and byte arrays.

**Step 8 — Kotlin generator (`kotlin_generator.dart`)**

Wrap the `suspend` call in a coroutine scope:

```kotlin
@JvmStatic fun lib_fetch_data(q: String, dartPort: Long) {
    scope.launch {
        val result = impl.fetchData(q)
        NitroBridge.postString(dartPort, result)
    }
}
```

`NitroBridge.postString` (a small Kotlin JNI helper added to the runtime) wraps `Dart_PostCObject_DL` via JNI.

**Step 9 — `NitroRuntime` (`nitro_runtime.dart`)**

Add `openNativeAsync<T>` for symmetry with `openStream`:

```dart
static Future<T> openNativeAsync<T>({
  required void Function(int dartPort) call,
  required T Function(dynamic) unpack,
}) {
  final port = ReceivePort();
  call(port.sendPort.nativePort);
  return port.first.then((raw) { port.close(); return unpack(raw); });
}
```

**Step 10 — Tests**

- `dart_ffi_generator_test.dart`: golden snapshot for a `@NitroNativeAsync` method confirming `ReceivePort` pattern and no `callAsync`.
- `cpp_bridge_generator_test.dart`: confirm `void` return, `int64_t dart_port` param, no `get_error`/`clear_error` suffix.
- Integration: a mock `g_impl` that calls `Dart_PostCObject_DL` directly to verify end-to-end.

**Migration path:** opt-in annotation — no existing `@NitroAsync` methods change. Ship as a minor version.

---

### 2. Eliminate the 3-call-per-sync-call overhead

Each generated `callSync` today triggers:
1. The actual native call — which internally starts with `${lib}_clear_error()`.
2. `${lib}_get_error()` FFI call — reads the thread-local `NitroError*`.
3. `${lib}_clear_error()` FFI call — only on the error path but always compiled in.

Replace with a single `int64` error-pointer **out-param** returned from the wrapper, or gate the error-check behind `NitroConfig.debugMode`. In release, error-checking should cost at most one branch on the return value.

#### How it works today

```
Dart:  _funcPtr(args)               ← FFI call 1 (actual work)
  C++:   lib_clear_error()          ← clears thread-local error slot
         g_impl->func(args)
         return result_or_default
Dart:  _getErrorPtr()               ← FFI call 2 (cross-boundary read)
Dart:  _clearErrorPtr()             ← FFI call 3 (only if hasError == 1)
```

FFI calls 2 and 3 cross the Dart↔native boundary on **every synchronous call** — even when the result is perfectly fine and `hasError == 0`. At 1000 calls/frame in a render loop this is measurable.

#### Two implementation approaches

**Approach A — `debugMode` gate (patch-level, non-breaking, ships first)**

Gate `checkError` in the generated Dart behind `NitroConfig.instance.debugMode`:

```dart
// dart_ffi_generator.dart emits:
String getName() {
  checkDisposed();
  final rawPtr = _getNamePtr();
  assert(() {                               // erased in release mode
    NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr);
    return true;
  }());
  return rawPtr.toDartString();
}
```

Using `assert(() { … }())` means the check is fully eliminated by `dart compile` in release builds — no branch, no pointer read, zero overhead. In debug/profile it retains full error surfacing.

Files to change:
- `dart_ffi_generator.dart` — wrap all `NitroRuntime.checkError(...)` calls in `assert(() { …; return true; }())`.
- `nitro_config.dart` — document that `checkError` runs only in debug/assert mode going forward.
- `nitro_runtime.dart` — no change needed; `checkError` still exists for the async pool path.

**Approach B — single-call out-param (major-version ABI change, eliminates extra FFI crossing entirely)**

Change the C wrapper to return `NitroError*` directly; actual result goes through an out-param:

```c
// Generated C (new convention):
NitroError* lib_get_name(char** out) {
    lib_clear_error();
    if (!g_impl) { nitro_report_error(...); return &g_nitro_error; }
    try {
        std::string r = g_impl->getName();
        *out = strdup(r.c_str());
        return nullptr;             // nullptr == no error
    } catch (const std::exception& e) {
        nitro_report_error("CppException", e.what(), nullptr, nullptr);
        return &g_nitro_error;
    }
}
```

Generated Dart:

```dart
String getName() {
  checkDisposed();
  final out = calloc<Pointer<Utf8>>();
  final errPtr = _getNamePtr(out);          // single FFI call
  if (errPtr != nullptr) {
    final ex = HybridException.fromErrPtr(errPtr);
    calloc.free(out);
    throw ex;
  }
  final result = out.value.toDartString();
  calloc.free(out);
  return result;
}
```

Files to change:
- `cpp_bridge_generator.dart` — new wrapper signature; `NitroError*` return; out-param for result.
- `dart_ffi_generator.dart` — `calloc` out-param allocation; single `_funcPtr(out, args)` call; branch on returned pointer.
- `hybrid_exception.dart` — add `HybridException.fromErrPtr(Pointer<NitroErrorFfi>)` factory.
- `nitro_runtime.dart` — remove `checkError` from sync paths; retain for isolate-pool async.

Breaking change: all generated `.bridge.g.cpp` and `.bridge.g.dart` must be regenerated. C ABI changes → major version bump.

#### Implementation sequence

```
PR A (patch)   — assert-gate checkError in dart_ffi_generator.dart
                 → zero overhead in release, full surfacing in debug
                 → ships independently, no ABI change

PR B (major)   — out-param ABI (Approach B)
                 → requires nitrogen generate re-run
                 → combine with other ABI-breaking changes if any
```

#### Expected improvement

| Scenario | Current | After PR A | After PR B |
|---|---|---|---|
| Sync call happy path | 2 FFI calls | 1 FFI call + 0 overhead | 1 FFI call |
| Sync call error path | 3 FFI calls | 3 FFI calls (assert = debug only) | 1 FFI call + decode |
| 1 000 getters/frame at 60 fps | ~2 ms FFI overhead | ~1 ms | ~0.5 ms |

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
