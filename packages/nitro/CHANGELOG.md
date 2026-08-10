## 0.6.1

- **Fixed: `NitroCoalescer.dispose()` discarded results that were already posted, so the `Future` hung forever ([#47](https://github.com/Shreemanarjun/nitro_ecosystem/issues/47)).** A native post only enqueues on the port — delivery needs an event-loop turn — and `dispose()` is normally called in that same turn, so results that already existed were thrown away. `dispose()` now drains already-posted batches (bounded, exits as soon as nothing is pending) and completes anything genuinely lost with a `StateError` instead of dropping it. Stopping the native side first no longer has to be enough on its own.
- `dispose()` is idempotent, and `submit()` after disposal throws instead of returning a future that could never complete.
- Android `@zeroCopy` TypedData returns no longer fragment the JVM heap under sustained load — the fix is generator-side, so **regenerate** to pick it up, and see `nitro_generator` 0.6.1 ([#48](https://github.com/Shreemanarjun/nitro_ecosystem/issues/48)).
- **Behavior note:** because pending calls now fail rather than vanish, a `submit()` result that is never awaited surfaces as an unhandled error. Await the futures (or `.ignore()` deliberately dropped ones).

## 0.6.0

Sync bridge returns no longer allocate: native lends Dart a reusable per-thread
buffer instead of a fresh `malloc`/`strdup`, and Dart no longer frees it.
`@nitroAsync` / `@nitroNativeAsync` are unchanged.

**Regenerate after upgrading** — `nitrogen generate && nitrogen link`. Generated
code and the runtime changed together. See [migration/0.6.0.md](../../migration/0.6.0.md).

- Nullable primitives (`int?` / `double?` / `bool?` / `DateTime?` / `uint64?`): 15.0 ns → 0.2 ns per call.
- `@HybridStruct` returns: 16.1 ns → 1.0 ns. Inner fields are still owned and freed.
- `String` returns: 27.8 ns → 9.9 ns (32 B). New `toDartStringBorrowed()`.
- Multi-instance dispatch: the instance cache holds 8 entries instead of 1, so loops across several live instances stay lock-free — 7–8× faster, 48× under thread contention. Single-instance is unchanged.
- New `NitroCoalescer`: opt-in batching of concurrent `@nitroNativeAsync` completions over one port. A 64-in-flight burst drops 559 µs → ~99 µs ([#39](https://github.com/Shreemanarjun/nitro_ecosystem/issues/39)).
- A busy-spin completion path was tried and rejected: **+35 % latency**, because the spinning isolate starves the thread producing the result.

Verified on macOS, iOS and Android (679 integration tests per platform, 4342 generator tests).

## 0.5.17

- **Memory-leak & robustness fixes for instance lifecycle and native-async.** Verified on real devices (Android emulator, iOS simulator, macOS): under create → drop → GC churn, 499/500 keyed instances are collected and RSS stays bounded across single-instance, multi-instance, stream, and batch-stream soaks.
  - **`NitroRuntime.releaseLib` no longer throws on iOS/macOS.** `DynamicLibrary.process()`/`.executable()` (static linking) cannot be closed — `close()` throws `Bad state: ... can't be closed`. The close is now skipped on iOS/macOS (only the ref-counted cache entry is dropped). This was a latent crash on the instance-teardown path — the GC finalizer and `dispose()`.
  - **`@nitroNativeAsync` gained an opt-in timeout: `NitroConfig.nativeAsyncTimeoutMs`** (default `0` = wait forever, unchanged behavior). When `> 0`, a native impl that crashes or never posts a result now completes the `Future` with a `TimeoutException` and releases the `ReceivePort` + per-call error slot, instead of hanging and leaking both. `openNativeAsync` now guarantees teardown (port close + error-slot free via a `cleanup` callback) on **every** terminal path — success, native error, or timeout.
  - New tests: `native_async_leak_test.dart` (via [`ffi_leak_tracker`](https://pub.dev/packages/ffi_leak_tracker)) and `native_async_timeout_test.dart`.
- Released alongside `nitro_generator` 0.5.17 (generated multi-instance registries switched to a weak cache + GC finalizer that frees native memory on drop — **regenerate to pick it up**). See its changelog.

## 0.5.16

- **Runtime hot-path performance — allocation and copy reductions across the FFI marshalling layer.** All changes are internal (no API, no wire-format changes); regenerate is not required for the runtime wins. Measured on the macOS C++ bridge, 5 independent benchmark runs averaged (non-overlapping ranges):
  - **`List<@HybridRecord>` encode: −55.9%** (3.78 → 1.67 µs, 16-item list). `RecordWriter.encodeIndexedList` no longer builds one 256-byte `RecordWriter` per item and copies each item twice — a single writer reserves the offset table, writes each item once, and backpatches the offsets. Paired with `RecordWriter.toNative` now copying the payload once over a single typed-list view instead of taking a sublist and copying twice ([#34](https://github.com/Shreemanarjun/nitro_ecosystem/issues/34)).
  - **FFI string decode: −18.4%** (0.64 → 0.53 µs). `_decodeUtf8NoBomStrip` uses the VM-native `Utf8Decoder` (with `allowMalformed: true`) after stripping any leading BOM, instead of a per-byte code-point loop; the NUL scan uses an indexed load rather than allocating a `Pointer` per byte ([#31](https://github.com/Shreemanarjun/nitro_ecosystem/issues/31)).
  - **Fewer per-call allocations** (GC-pressure relief; not separately timeable in a tight loop): `ZeroCopy*Buffer` cache their typed-list view instead of rebuilding it on every `.bytes`/`.values` access ([#32](https://github.com/Shreemanarjun/nitro_ecosystem/issues/32)); `callAsync` and `openNativeAsync` gained the error-level fast path that skips the `Stopwatch` and tag-string allocation, mirroring `callSync` ([#33](https://github.com/Shreemanarjun/nitro_ecosystem/issues/33)); the error handlers cache the `errPtr.ref` struct view once instead of rebuilding it 12+ times on the throw path ([#37](https://github.com/Shreemanarjun/nitro_ecosystem/issues/37)); `_log`'s level check is an O(1) enum-index compare instead of two `indexOf` scans; `NitroPromise` allocates its listener lists lazily ([#36](https://github.com/Shreemanarjun/nitro_ecosystem/issues/36)).
- **Two proposed micro-optimizations were deliberately NOT adopted**, each because it changed observable behavior (new regression tests lock both):
  - A strict `utf8.decode()` fast path would have thrown `FormatException` on malformed bytes that bridge strings (raw data, not text) may contain; the lenient `allowMalformed: true` decoder is kept.
  - `Completer.sync()` in `NitroPromise` (#36) and `Error.throwWithStackTrace` in `IsolatePool` (#35) both deliver a rejection synchronously before its handler is attached — surfacing un-awaited rejections as unhandled errors, and throwing into `IsolatePool.dispose()`. The async-completer / `Future.error` forms are kept.
- Credit to the community performance report ([#31](https://github.com/Shreemanarjun/nitro_ecosystem/issues/31)–[#37](https://github.com/Shreemanarjun/nitro_ecosystem/issues/37)) and PR #38 for surfacing these hot paths. New tests: `indexed_list_codec_test.dart`, `string_decode_test.dart`, `nitro_promise_test.dart` (21 cases; the package's first NitroPromise coverage).

## 0.5.15

- **Ecosystem sync** — Released alongside `nitro_generator` 0.5.15 (Swift record initializers no longer use Swift 6.1+-only trailing commas — Xcode ≤ 16.2 compatible, [#22](https://github.com/Shreemanarjun/nitro_ecosystem/issues/22)) and `nitrogen_cli` 0.5.15 (hand-added desktop `pluginClass` entries preserved, [#23](https://github.com/Shreemanarjun/nitro_ecosystem/issues/23)). No functional changes to this package — regenerate and re-link to pick them up.

## 0.5.14

- **Ecosystem sync** — Released alongside `nitrogen_cli` 0.5.14's fixes for the 0.5.13 SPM umbrella-header regression ([#21](https://github.com/Shreemanarjun/nitro_ecosystem/issues/21)) and the reopened Plugin.kt import drop ([#16](https://github.com/Shreemanarjun/nitro_ecosystem/issues/16)). No functional changes to this package — see `nitrogen_cli`'s changelog and re-run `nitrogen link`.

## 0.5.13

- **Ecosystem sync** — Released alongside the nitro_webgpu feedback batch (issues [#13](https://github.com/Shreemanarjun/nitro_ecosystem/issues/13)–[#20](https://github.com/Shreemanarjun/nitro_ecosystem/issues/20)): `@NitroOwned(release:)`, `Future<NativeHandle>` native-async, `@mainThread`, nullable native-async kNull support, self-contained all-C++ Swift bridges, per-module SPM targets, user-owned Plugin.kt, and build_runner symlink-cycle guards. No functional changes to this package — see the `nitro_generator` and `nitrogen_cli` changelogs, and regenerate your plugin to pick them up.

## 0.5.12

- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.12's zero-copy TypedData fixes (missing `release_typed_data_return` definition on the pure-C++ path; Swift struct conversions dropping the synthesized length for `@zeroCopy` fields). No functional changes to this package — see `nitro_generator`'s changelog, and regenerate your plugin to pick them up.

## 0.5.11

- **Ecosystem sync** — Aligned with `nitrogen_cli` 0.5.11's desktop developer-experience fixes ([#10](https://github.com/Shreemanarjun/nitro_ecosystem/issues/10): pubspec `pluginClass` on FFI-only desktop platforms, [#11](https://github.com/Shreemanarjun/nitro_ecosystem/issues/11): example app-runner CMakeLists portability, [#12](https://github.com/Shreemanarjun/nitro_ecosystem/issues/12): per-platform separation transition) and `nitro_generator` 0.5.11's platform-matrix/no-duplicate-definition test lock. No functional changes to this package — run `nitrogen link` (with the updated CLI) to pick up the project-file repairs.

## 0.5.10

- **Windows heap-corruption fix (runtime side): native-owned memory is now freed by the native allocator, never by package:ffi's `malloc.free`** — package:ffi's `malloc`/`free` bind to `CoTaskMemAlloc`/`CoTaskMemFree` on Windows, but every pointer the native bridge hands to Dart (strdup'd strings, record blobs, struct copies, posted async results, stream items, the S8 error-slot's string fields) is allocated with C-runtime `malloc` — freeing those with `CoTaskMemFree` is undefined behavior and crashed the very first string-returning call on Windows. `nitro_generator` 0.5.10's regenerated bridges now export a `<lib>_nitro_free` symbol and route all such frees through it; this package adds the runtime halves:
  - `Pointer<Utf8>.toDartStringFreedBy(nativeFree)` — like `toDartStringWithFree()` (which remains, unchanged, for package:ffi-allocated strings) but releases via the caller-supplied free function.
  - `NitroRuntime.throwIfOutParamError` / `throwIfOutParamErrorAndFree` gained an optional `nativeFree:` parameter for the error struct's native strdup'd string fields (the struct itself stays `calloc`-allocated/freed by Dart, which is correct on every platform). Omitting it preserves the old behavior.
  - `LazyRecordList.decode` gained an optional `nativeFree:` finalizer parameter (a `Pointer<NativeFinalizerFunction>`) so lazily-decoded record-list buffers are also released by the native allocator when the list is GC'd; one `NativeFinalizer` is cached per module.
  All additions are backward-compatible optional parameters — previously generated code keeps compiling and behaving as before (on POSIX, where the old behavior was already correct).
- **Added: `NitroNativeAllocator`** — an [Allocator] backed by a module's exported `<lib>_nitro_alloc`/`<lib>_nitro_free` (plain C-runtime `malloc`/`free`). The reverse direction of the same Windows rule: values Dart produces that NATIVE code frees (String/record/variant *callback returns*, which the native wrapper releases with `free()`) must not come from package:ffi's CoTaskMem-backed allocators. Regenerated bridges pass it to `toNativeUtf8(allocator:)`/`toNative(...)` in callback trampolines; on Windows the old code froze the app at the first String-returning callback.
- **Dependency floor: `ffi: ^2.2.0`.**
- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.10's desktop C-bridge fixes: [#9](https://github.com/Shreemanarjun/nitro_ecosystem/issues/9) (`@NitroResult<record>` compile error, nullable record/variant param segfault on `@nitroNativeAsync`), plus a further cluster found via a real Windows/Linux CI build — `@nitroNativeAsync` desktop dispatch mishandling `List<T>`/`Map<K,V>`/callback params, a `@NitroCustomType` param declaration mismatch between the generated header and the dispatch body, the Windows allocator mismatch above, and a desktop record/variant stream-emit wire-format fix (double length prefix + leak). Also aligned with `nitrogen_cli` 0.5.10's new opt-in per-platform (Windows/Linux) native-implementation separation and its Android `consumer-rules.pro` generation (R8 `includedescriptorclasses` keep rules for the JNI bridge, so release-mode builds no longer risk stripping/renaming types referenced only from native code). See `nitro_generator`'s and `nitrogen_cli`'s changelogs, and regenerate/re-link your plugin to pick these up.

## 0.5.9

- **Added: `NitroRuntime.throwIfOutParamErrorAndFree`** — checks and frees a fresh-per-call `NitroErrorFfi` out-param slot, throwing a `HybridException` if it carries an error. Used internally by `nitro_generator`'s regenerated `@nitroNativeAsync` call sites to propagate a thrown native exception back to Dart, which previously was silently discarded (a `Future<void>` native-async method's thrown exception was completely invisible — the call always "succeeded"). Differs from the existing `throwIfOutParamError` (used by sync calls, which reuse one instance-owned slot safe only because sync calls on an isolate are serialized): native-async calls aren't serialized, so each call gets its own `calloc`'d struct, and this variant also frees the struct itself either way (the sync variant doesn't, since the instance-owned slot outlives every call). Not typically called directly by plugin authors.
- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.9's `@nitroNativeAsync` error-propagation fix. See `nitro_generator`'s changelog, and regenerate your plugin to pick it up.

## 0.5.8

- **Ecosystem sync** — Aligned with `nitro_generator` 0.5.8's `@nitroNativeAsync` fixes (`Map<String,V>`/`NitroAnyMap` params on Kotlin and Swift, bare `@HybridStruct` returns on Kotlin, and `NitroAnyMap` support on Swift). No functional changes to this package — see `nitro_generator`'s changelog, and regenerate your plugin to pick it up.

## 0.5.7

- **Added: `NitroRuntime.deferredClose`** — closes a replaced callback `NativeCallable` on the next microtask turn, after native has synchronously switched over to its replacement. Used internally by `nitro_generator`'s regenerated callback-setter helpers to fix a leak where every re-registration of a callback-typed parameter (e.g. a listener setter called with a fresh closure) allocated a new `NativeCallable` that was never released. Not typically called directly by plugin authors.
- **`IsolatePool` worker: cache `getError`/`clearError` `.asFunction()` bindings** — `_workerMain` was rebinding a fresh Dart closure around the same unchanged `Pointer<NativeFunction<...>>` on every single `@nitroAsync` dispatch. Now cached by pointer address inside each worker. Low-risk internal change; no API impact.
- **Corrected long-stale async performance figures across READMEs and `doc/advanced/async.md`** — the oft-repeated "`@nitroAsync` ~930 µs, `@nitroNativeAsync` ~146 µs" numbers predated the "Isolate Pool 2.0" persistent-reply-port optimization (0.3.1) and were never updated afterward. Measured current numbers (macOS, `benchmark` package): `@nitroAsync` ~28 µs, `@nitroNativeAsync` ~27 µs — both roughly at parity with a Flutter method channel round-trip (~27 µs). `doc/advanced/async.md`'s claim that `IsolatePool` defaults to `Platform.numberOfProcessors` workers was also wrong — the real default is `1`; a bigger pool only helps concurrent throughput, not single-call latency, since the least-busy-worker scheduler is O(1) regardless of pool size. The `benchmark` package now has a dedicated `nitro_native_async_record` case (there was previously no benchmark coverage for `@nitroNativeAsync` at all) and a CI regression gate comparing both async paths against the method-channel baseline.
- **Ecosystem sync** — Also aligned with `nitro_generator` 0.5.7's callback `NativeCallable` leak fix (entirely in its generated Dart/Kotlin/C++ output — see its changelog, and regenerate your plugin to pick up both fixes).

## 0.5.6

- **Ecosystem sync** — Aligned with the 0.5.6 release. No changes to this package; the 0.5.6 fix (a JNI global-reference leak on Android zero-copy stream events that aborted the process after ~25 minutes of continuous streaming) is entirely in `nitro_generator`'s generated C++ bridge — see its changelog, and regenerate your plugin to pick it up.

## 0.5.5

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.5.5. No changes to this package's runtime code; the 0.5.5 fixes are entirely in the desktop C++ (`NativeImpl.cpp` on Windows/Linux) generator path and the `nitrogen link`/`nitrogen doctor` CLI — see `nitro_generator`'s and `nitrogen_cli`'s changelogs for details.

## 0.5.4

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.5.4.

## 0.5.3

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.5.3.

## 0.5.2

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.5.2.

## 0.5.1

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.5.1.

## 0.5.0

- **Fixed: `ReceivePort` available in generated `part` files without extra imports** — `nitro.dart` now re-exports `ReceivePort` and `SendPort` from `dart:isolate` (conditionally, with a web stub). Generated `.g.dart` files are `part of` the user's spec file and cannot have their own `import` directives; they use `ReceivePort` for the callback-release port. Previously, specs that used callbacks required an explicit `import 'dart:isolate'` in the spec file.
- **New: `lib/src/isolate_stub.dart`** — Web stub for `ReceivePort`/`SendPort` used by the conditional `dart:isolate` re-export.

## 0.4.6

- **Ecosystem sync** — Updated annotations and generator support.

## 0.4.5

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.4.5.

## 0.4.4

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.4.4.

## 0.4.3

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.4.3.

## 0.4.2

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.4.2.

## 0.4.1

- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.4.1.
- **Improved: `build_runner` constraint** — Updated dev dependency to `^2.15.0` for compatibility with the upgraded `analyzer` and `source_gen` used by `nitro_generator` 0.4.1.

## 0.4.0

- **New: `NitroRuntime.callSync` observability** — `callSync` now has the same developer experience as `callAsync`: verbose call/completion logs, slow-call warnings, error logs with stack traces, and a zero-allocation fast path when logging is disabled.
- **SPM and CocoaPods support** — The runtime library is compatible with both Swift Package Manager and CocoaPods. Plugins built with `nitrogen link` work in either build system with no code changes.
- **Ecosystem sync** — Aligned with `nitro_annotations`, `nitro_generator`, and `nitrogen_cli` 0.4.0.

## 0.3.3
- **Improved: Ecosystem Sync** — Synchronized to version 0.3.3.



## 0.3.2

- **Improved: Ecosystem Sync** — Synchronized to version 0.3.2.
- **Improved: Nested `@HybridStruct` integration** — Works seamlessly with `nitro_generator` 0.3.2, which now generates correct `Pointer<NestedFfi>` types, recursive `freeFields()`, and typed `toNative()`/`toDart()` for nested struct fields.
- **Improved: Struct constructor styles** — Generated FFI extensions respect positional and named constructor parameters as declared in your `.native.dart` spec, so `toDart()` calls always match the actual constructor signature.

## 0.3.1

- **Improved: `IsolatePool` — persistent reply port** — replaced per-call `ReceivePort` allocation with a single pool-level port kept alive for the pool's lifetime. Each call is tagged with a monotonically-increasing `callId`; a `Map<int, Completer>` demuxes responses without any OS port operation per call.
- **Improved: `IsolatePool` — least-busy scheduling** — replaced round-robin with a per-worker in-flight counter; the dispatcher always picks the worker with the fewest pending calls, preventing a slow JNI/FFI call from blocking the next task.
- **Improved: `IsolatePool` — `Completer.sync()`** — reply completers use `Completer.sync()` to deliver values in the same microtask as the port message, removing one extra microtask hop per async call.
- **Improved: `IsolatePool.dispose()`** — now idempotent; in-flight calls are completed with `StateError` so awaiting code never hangs; the reply port is closed and worker shutdown is signalled gracefully.
- **New: `IsolatePool` tests** — 21 tests covering pool creation, return values, error propagation, callId uniqueness, least-busy scheduling, dispose idempotency, in-flight cancellation, and stress scenarios.

- **New: `LazyRecordList<T>`** — `record_codec.dart` gains a `ListBase<T>` implementation backed by a raw `Pointer<Uint8>` and a pre-parsed offset table. Items are decoded on first access and cached; a `NativeFinalizer` backed by `malloc.nativeFree` frees the buffer on GC.
- **New: `RecordWriter.encodeIndexedList<T>`** — serialises a list of records into the indexed wire format: `[int32 count | int64[count] byte_offsets | item_blobs...]`, enabling O(1) random access by the Dart reader.
- **New: `RecordWriter.encodeIndexedPrimitiveList<T>`** — same indexed format for primitive-typed lists.
- **New: `RecordReader.fromPayloadOffset(Pointer<Uint8>, int)`** — constructs a reader at an arbitrary byte offset within an existing payload, used by `LazyRecordList` to decode individual items on demand.

## 0.3.0

- **Breaking: C++ Interface Pointer Generation** — The C++ bridge generator now generates `void*` interface pointers instead of concrete class pointers for `HybridObject` types.
  - **Impact**: Existing C++ code that directly casts these pointers to concrete types will break and require updates.
  - **Benefit**: This change ensures compatibility with the new C++ build system and allows for more flexible native module integration.
- **Improved: Memory Safety**: FFI generated code now uses `try-finally` blocks for all async and sync record/struct return paths, ensuring `malloc.free` is called even if decoding fails.
- **Improved: Thread Safety**: The `HybridObject` implementation now enforces `checkDisposed()` guards on all native methods, including `Fast` variants, to prevent use-after-dispose crashes.
- **Fixed: Fail-Fast Initialization**: `NitroRuntime` now explicitly validates return codes from native initialization (e.g., `Dart_InitializeApiDL`). If initialization fails, a `StateError` is thrown immediately instead of failing silently later.

## 0.2.3

- **Improved: Native Visibility Visibility**: Updated `nitro.h` to include `NITRO_EXPORT` macros by default, ensuring all native symbols are correctly exported for FFI across iOS, Android, macOS, and Windows.
- **Improved: Dependency Sync**: Synchronized the Nitro ecosystem to version 0.2.3.

## 0.2.2

- **Improved: annotation compatibility** — verified full compatibility with Nitrogen 0.2.2's stable annotation resolution system, ensuring re-exported `@NitroModule`, `@HybridStruct`, and `@HybridEnum` annotations are correctly identified by the code generator.
- Added explicit `void` support in return types for all `HybridObject` methods.

## 0.2.1

- Moved all annotations to the separate `nitro_annotations` package to improve generator platform compatibility.
- Re-exported `nitro_annotations` for backward compatibility.
- Added explicit support for `macos`, `windows`, and `linux` to the plugin configuration to resolve `pub.dev` platform detection warnings.

# 0.2.0

- **New: Binary `RecordWriter` and `RecordReader` Codec** — Compact little-endian protocol for `@HybridRecord` types, replacing JSON text serialization with direct binary field access over raw `uint8_t*` buffers.
  - Wire format: `int64` (8B), `float64` (8B), `bool` (1B), `String` (4-byte length + UTF-8), nullable (1-byte tag), and `list` (4-byte count).
  - High-performance `encodeList` / `decodeList` for collections of records or primitives.
  - Retains `dart:convert` re-exports for `Map<String, T>` which still uses the JSON path.
- **New: `IsolatePool` & `NitroRuntime.init()`** — Fixed-size pool of persistent worker isolates with round-robin dispatch. Pre-warmed by `init()` to eliminate the ~1–5 ms `Isolate.spawn` overhead on every `callAsync`.
- **New: `NitroConfig` Runtime Singleton** — Configurable runtime behavior:
  - `debugMode`: Enables verbose logging of bridge calls, streams, isolates, and lifecycles.
  - `logLevel`: Granular control (`none`, `error`, `warning`, `verbose`).
  - `logHandler`: Custom sink for logs (e.g., Firebase, Sentry, Crashlytics).
  - `slowCallThresholdUs`: Configurable warning threshold for long-running async calls (default 16ms).
- **Improved: `NitroRuntime` Robustness** — Stream unpack errors are now always logged at `error` level with stack traces, ensuring they are never silently swallowed. Added `debugLabel` to streams for easier debugging.
- **Fix: Style & Linting** — Renamed internal state variables (e.g., `_released` → `released`) to follow Dart conventions for local variables.

## 0.1.0

- Initial release of Nitro runtime.
- Support for `HybridObject`, `HybridStruct`, and `HybridEnum`.
- Support for synchronous and asynchronous bridge calls.
- Unified FFI bridge support for Android and iOS.
