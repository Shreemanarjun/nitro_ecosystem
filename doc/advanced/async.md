# Async Guide: `@nitroAsync` and `@NitroNativeAsync`

Nitro provides two async paths with different performance characteristics.
Choose based on whether Dart needs to process the result or native code can
post it directly.

---

## At a glance

| | `@nitroAsync` | `@NitroNativeAsync` |
|---|---|---|
| **Return type** | `Future<T>` | `Future<T>` (Dart side) |
| **Dispatch** | Bridge worker pool (since 0.7.6); isolate pool only for `timeout:` and a few return/parameter shapes | Native thread of your choice |
| **Completion** | Shared completion port (`NitroCompletionBatch`) | Native posts to the same shared completion port |
| **Overhead** | ~24 µs (macOS; ~28 µs on the isolate pool), roughly at parity with a method channel round-trip | ~25 µs (macOS), no isolate hop |
| **Error path** | `NitroError` slot, checked in Dart | Native posts `kNull` on error |
| **Best for** | Work that returns complex types | I/O-bound, fire-and-forget |

---

## `@nitroAsync` — bridge-dispatched async

### Usage

```dart
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class FileProcessor extends HybridObject {
  @nitroAsync
  Future<Uint8List> readFile(String path);

  @nitroAsync
  Future<bool> writeFile(String path, Uint8List data);
}
```

### How it works

1. Dart calls the generated `_Impl.readFile(path)`.
2. The generated `${lib}_read_file_dispatch` twin runs the sync export on the bridge's worker pool (`NitroWorkerPool`) — no isolate hop. Calls with a `timeout:`, `@NitroResult`, `@zeroCopy`, `@mainThread`, typed `Map`/`NativeHandle`/`Pointer` returns, or function/pointer/custom-type parameters go through the adaptive isolate pool instead.
3. The native function runs on that worker thread — **never blocks the UI thread**.
4. The result is posted through the shared completion port (`NitroCompletionBatch`), batched with any other completions that arrived while Dart was busy.
5. The `Future` completes on the calling isolate.
6. `NitroRuntime.checkError` is called; any `NitroError` becomes a Dart exception.

### Performance

```
UI isolate → bridge worker pool → native call → shared completion port → UI isolate
Measured total round-trip: ~24 µs on macOS (~28 µs for the isolate-pool shapes; near-zero
native work — see the README "Async overhead" table), roughly at parity with a method channel.
```

Isolate-pool dispatch (the shapes listed above) uses the adaptive pool described below: one persistent worker that grows toward the CPU count under load and retires the extra workers when idle.

### Error handling

```dart
try {
  final bytes = await processor.readFile('/nonexistent');
} on HybridException catch (e) {
  print('Native error: ${e.message}'); // from nitro_report_error()
}
```

On the native side, report errors via:

**Kotlin:**
```kotlin
override suspend fun readFile(path: String): ByteArray {
    if (!File(path).exists()) {
        throw IllegalArgumentException("File not found: $path")
    }
    return File(path).readBytes()
}
```

**Swift:**
```swift
func readFile(path: String) async throws -> Data {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw NSError(domain: "FileError", code: 404,
                      userInfo: [NSLocalizedDescriptionKey: "File not found: \(path)"])
    }
    return data
}
```

**C++:**
```cpp
std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("File not found: " + path);
    return {std::istreambuf_iterator<char>(f), {}};
}
```

---

## `@NitroNativeAsync` — native-post async

### Usage

```dart
abstract class AudioCapture extends HybridObject {
  @NitroNativeAsync
  Future<Uint8List> captureAudio(int durationMs);
}
```

### How it works

1. Dart calls `captureAudio(durationMs)`.
2. The generated `_Impl` calls `NitroRuntime.openNativeAsync<Uint8List>(...)`, which opens a `ReceivePort` and returns a `Future`.
3. The C bridge calls `${lib}_capture_audio(durationMs, dart_port)` — the extra `dart_port` param carries the Dart port address.
4. Native code runs asynchronously (on its own thread/queue), then calls `Dart_PostCObject_DL(dart_port, &result)` when done.
5. The `ReceivePort` fires → `Future` completes.

**No Dart isolate is spawned.** The entire dispatch overhead is a single C function call — measured at ~25 µs end-to-end on macOS (see `benchmark`'s `nitro_native_async_record` case), essentially the same as the underlying native work itself since there's no isolate hop to add latency.

### When to use

- When the native side already manages its own thread/queue (audio callbacks, camera capture, network I/O).
- When Dart only needs the final result, not intermediate progress.
- When you need to skip the isolate hop entirely — `@NitroNativeAsync` measures ~25 µs end-to-end on macOS vs ~24 µs for `@nitroAsync` on the same near-zero-work benchmark case; the real win is architectural (one fewer moving part, no worker-pool contention under concurrent load), not a large fixed-cost gap.

### Error handling

`@NitroNativeAsync` propagates a thrown exception back to Dart as a real `HybridException`, mirroring the `NitroError*` out-param mechanism the sync/`@nitroAsync` paths already use (see `nitro_generator`'s S8 mechanism) — with one difference: since native-async calls aren't serialized (several can be in flight concurrently on the same instance), Dart allocates a **fresh** `NitroErrorFfi` struct per call instead of reusing one instance-owned slot.

On **Kotlin** and **Swift**, this is fully automatic — if your `suspend fun`/`async throws func` implementation throws, the generated trampoline catches it and reports the exception's name and message; Dart's `Future` rejects with a `HybridException` instead of silently completing with `null`/a default value.

On the **C++ desktop-direct** path (`NativeImpl.cpp` on Windows/Linux, or macOS via `NativeImpl.cpp`), the framework doesn't own your async completion thread — the generated wrapper only catches a *synchronous* throw from your method (before it returns). If your implementation does real work on a background thread, you're responsible for populating the `NitroError*` parameter yourself before posting, exactly like `Dart_PostCObject_DL`/`dart_port` posting is already your responsibility (see the C++ example below).

### Resolving a nullable result from C++ (`Future<T?>`)

For a nullable return type, post **either** of these — both decode to Dart `null`:

```cpp
// Option A — a Dart null:
Dart_CObject nullObj; nullObj.type = Dart_CObject_kNull;
Dart_PostCObject_DL(dartPort, &nullObj);

// Option B — int64 zero (a "null pointer address"):
Dart_CObject zero; zero.type = Dart_CObject_kInt64; zero.value.as_int64 = 0;
Dart_PostCObject_DL(dartPort, &zero);
```

Posting null (either form) for a **non-nullable** return type rejects the `Future` with a descriptive `StateError` naming the method, instead of an opaque type-cast error.

### Native implementation pattern

**Swift** — write a normal `async throws` function; the generator handles dispatch, posting, and error reporting:
```swift
func captureAudio(durationMs: Int64) async throws -> Data {
    return try await recordFor(ms: durationMs) // a thrown error is caught and reported to Dart automatically
}
```

**Kotlin** — write a normal `suspend fun`; same automatic dispatch/posting/error-reporting:
```kotlin
override suspend fun captureAudio(durationMs: Long): Uint8List {
    return recordFor(durationMs) // a thrown exception is caught and reported to Dart automatically
}
```

**C++ (desktop-direct, `NativeImpl.cpp`)** — the generated wrapper passes `dart_port` *and* `NitroError* _nitro_err` straight through; you're responsible for both posting the result and reporting errors from your own async completion:
```cpp
void captureAudio(int64_t durationMs, NitroError* _nitro_err, int64_t dart_port) {
    std::thread([=]() {
        try {
            auto audio = recordFor(durationMs);
            auto buf = audio.toNative();
            Dart_CObject obj;
            obj.type = Dart_CObject_kInt64;
            obj.value.as_int64 = (int64_t)(uintptr_t)buf;
            Dart_PostCObject_DL(dart_port, &obj);
        } catch (const std::exception& e) {
            if (_nitro_err) {
                _nitro_err->hasError = 1;
                _nitro_err->name = strdup("CppException");
                _nitro_err->message = strdup(e.what());
            }
            Dart_CObject obj = { Dart_CObject_kNull };
            Dart_PostCObject_DL(dart_port, &obj);
        }
    }).detach();
}
```

---

## Choosing between the two

```
Does native code already manage its own thread/queue?
    YES → @NitroNativeAsync  (no Dart isolate overhead)
    NO  →
        Does the result need complex Dart-side decoding (struct, record)?
            YES → @nitroAsync  (IsolatePool handles decode on worker)
            NO  → Either works; @nitroAsync is simpler to error-handle
```

---

## IsolatePool sizing (automatic)

The `@nitroAsync` isolate pool sizes itself — there is **no knob**. It starts
with a single persistent worker (so a sequential workload pays no idle isolate
cost) and grows **adaptively and proportionally**: when in-flight calls
outnumber workers, it spawns the shortfall in parallel — up to the CPU count
(`Platform.numberOfProcessors`) — so a concurrent workload reaches full width in
a single spawn window rather than one worker at a time. After an idle period
(no dispatches for ~30s) it **shrinks** back to a single worker, releasing the
extra isolates; the next burst regrows it. A fixed pool neither grows nor
shrinks.

Scheduling is a **central work-queue**: at most one call is in flight per
worker, and extra calls wait in a shared queue that any worker drains the moment
it frees up (or spawns). So there is no head-of-line blocking inside a worker's
mailbox, and even a *cold* concurrent burst fans out across workers as they come
online. Benchmarks: the adaptive pool matches a hand-sized `cores`-worker pool
on both cold and warm bursts, with a fraction of its startup cost and no idle
isolates — see `packages/nitro/tool/bench_pool_compare.sh`.

```dart
void main() async {
  NitroConfig.instance.enable();
  await NitroRuntime.init(); // pre-warms the adaptive pool
  runApp(const MyApp());
}
```

> `NitroConfig.isolatePoolSize` and `NitroRuntime.init(isolatePoolSize: …)` are
> deprecated and ignored.

---

## Slow-call warnings

Both async paths emit a warning when a call exceeds the threshold:

```
⚠️  [Nitro/callSync(captureAudio)] slow call: 24893 µs exceeded threshold of 16000 µs
```

Adjust the threshold:

```dart
NitroConfig.instance
  ..slowCallThresholdUs = 50000  // 50 ms
  ..enable();
```

Set to `0` to disable slow-call detection.

---

## Timeline tracing

Enable `Timeline` spans for DevTools profiling:

```dart
NitroConfig.instance
  ..timelineTracingEnabled = true
  ..enable();
```

Every `callSync`, `callAsync`, and `openNativeAsync` call appears in the Flutter DevTools Timeline with the method name.

## `@mainThread` — run the impl on the platform main/UI thread

Many platform APIs (Android `SurfaceView`, UIKit, `CAMetalLayer`) must be
touched from the main thread, but Nitro calls implementations from whatever
thread invoked them. `@mainThread` moves the Kotlin/Swift impl call onto the
platform main thread:

```dart
@mainThread
@nitroNativeAsync
Future<void> attachToView(NativeHandle<Void> surface);
```

Per platform:

| Platform | Mechanism |
|---|---|
| Kotlin (sync) | `runBlocking(Dispatchers.Main.immediate) { impl.f() }` — inline when already on main |
| Kotlin (async) | body wrapped in `withContext(Dispatchers.Main.immediate)` (timeout composes around it) |
| Swift (sync) | whole dispatch body runs in one `DispatchQueue.main.sync` hop (inline when on main) |
| Swift (async) | the protocol requirement is `@MainActor` — the conforming impl infers main-actor isolation, so its body genuinely runs on the main thread |
| C++ (any platform) | no effect — validator warning `MAIN_THREAD_NO_EFFECT`; marshal inside your impl |

Notes:

- **Re-entrancy safe** — if the caller is already the main thread the impl
  runs inline; there is no self-deadlock.
- On a **sync** method the calling Dart thread blocks until the main thread
  runs the body. Prefer pairing with `@nitroAsync` (blocks a pool worker,
  not your caller) or `@nitroNativeAsync` (blocks nothing).
- Swift impls of `@mainThread` async methods are `@MainActor`-isolated —
  UIKit calls inside them need no extra dispatch.