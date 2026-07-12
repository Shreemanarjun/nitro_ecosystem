# Async Guide: `@nitroAsync` and `@NitroNativeAsync`

Nitro provides two async paths with different performance characteristics.
Choose based on whether Dart needs to process the result or native code can
post it directly.

---

## At a glance

| | `@nitroAsync` | `@NitroNativeAsync` |
|---|---|---|
| **Return type** | `Future<T>` | `Future<T>` (Dart side) |
| **Dart isolate** | Spawns a background isolate via `IsolatePool` | No isolate spawned |
| **Native post** | No — Dart isolate awaits result | Yes — `Dart_PostCObject_DL` |
| **Overhead** | ~28 µs (macOS), roughly at parity with a method channel round-trip | ~27 µs (macOS), no isolate hop |
| **Error path** | `NitroError` slot, checked in Dart | Native posts `kNull` on error |
| **Best for** | Work that returns complex types | I/O-bound, fire-and-forget |

---

## `@nitroAsync` — Dart-isolate async

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
2. The impl dispatches to an `IsolatePool` worker via `NitroRuntime.callAsync<T>`.
3. The worker calls the native `${lib}_read_file(path)` C function (synchronously inside the worker isolate).
4. The native function runs on the worker thread — **never blocks the UI thread**.
5. Return value is sent back to the calling isolate via the result port.
6. `NitroRuntime.checkError` is called; any `NitroError` becomes a Dart exception.

### Performance

```
UI isolate → IsolatePool dispatch → worker → native call → result → UI isolate
Measured total round-trip: ~28 µs on macOS (near-zero native work — see benchmark/
package's nitro_async_record case), roughly at parity with a Flutter method channel.
```

`IsolatePool` uses a **min-heap scheduler** — tasks go to the least-busy worker. A single, persistent reply port is shared across all workers for the pool's lifetime (no per-call `ReceivePort` allocation).

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

**No Dart isolate is spawned.** The entire dispatch overhead is a single C function call — measured at ~27 µs end-to-end on macOS (see `benchmark`'s `nitro_native_async_record` case), essentially the same as the underlying native work itself since there's no isolate hop to add latency.

### When to use

- When the native side already manages its own thread/queue (audio callbacks, camera capture, network I/O).
- When Dart only needs the final result, not intermediate progress.
- When you need to skip the isolate hop entirely — `@NitroNativeAsync` measures ~27 µs end-to-end on macOS vs ~28 µs for `@nitroAsync` on the same near-zero-work benchmark case; the real win is architectural (one fewer moving part, no worker-pool contention under concurrent load), not a large fixed-cost gap.

### Error handling

`@NitroNativeAsync` propagates a thrown exception back to Dart as a real `HybridException`, mirroring the `NitroError*` out-param mechanism the sync/`@nitroAsync` paths already use (see `nitro_generator`'s S8 mechanism) — with one difference: since native-async calls aren't serialized (several can be in flight concurrently on the same instance), Dart allocates a **fresh** `NitroErrorFfi` struct per call instead of reusing one instance-owned slot.

On **Kotlin** and **Swift**, this is fully automatic — if your `suspend fun`/`async throws func` implementation throws, the generated trampoline catches it and reports the exception's name and message; Dart's `Future` rejects with a `HybridException` instead of silently completing with `null`/a default value.

On the **C++ desktop-direct** path (`NativeImpl.cpp` on Windows/Linux, or macOS via `NativeImpl.cpp`), the framework doesn't own your async completion thread — the generated wrapper only catches a *synchronous* throw from your method (before it returns). If your implementation does real work on a background thread, you're responsible for populating the `NitroError*` parameter yourself before posting, exactly like `Dart_PostCObject_DL`/`dart_port` posting is already your responsibility (see the C++ example below).

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

## IsolatePool configuration

By default, `IsolatePool` uses a **single** persistent worker (`isolatePoolSize = 1`). A bigger pool only helps *concurrent* throughput — the least-busy-worker scheduler picks a worker in O(1) regardless of pool size, so a single sequential `@nitroAsync` call sees no latency benefit from more workers. Increase the pool size if your app makes multiple `@nitroAsync` calls concurrently and wants them to run in parallel rather than queue behind each other:

```dart
void main() {
  NitroConfig.instance
    ..isolatePoolSize = Platform.numberOfProcessors   // for concurrent async workloads
    ..enable();
  runApp(const MyApp());
}
```

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