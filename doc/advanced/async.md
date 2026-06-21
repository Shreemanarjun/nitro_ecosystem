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
| **Overhead** | ~8 µs isolate dispatch | ~1–2 µs (post only) |
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
UI isolate → IsolatePool dispatch (~4 µs) → worker → native call → result → UI isolate
Total round-trip: ~8–15 µs (excluding native work time)
```

`IsolatePool` uses a **min-heap scheduler** — tasks go to the least-busy worker.

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

**No Dart isolate is spawned.** The entire dispatch overhead is a single C function call (~1 µs).

### When to use

- When the native side already manages its own thread/queue (audio callbacks, camera capture, network I/O).
- When Dart only needs the final result, not intermediate progress.
- When you need the absolute minimum latency (~146 µs end-to-end vs ~930 µs with `@nitroAsync` for a null-return).

### Error handling

`@NitroNativeAsync` does not use the `NitroError` slot. On error, native posts `Dart_CObject_kNull`. The `Future` resolves to `null` / throws `StateError` depending on the return type.

For rich errors, post an error via a second port or use `@nitroAsync` instead.

### Native implementation pattern

**Swift:**
```swift
func captureAudio(durationMs: Int64, dartPort: Int64) {
    Task.detached {
        let audio = await self.recordFor(ms: durationMs)
        let buf = audio.toNative()
        var obj = Dart_CObject()
        obj.type = Dart_CObject_kInt64
        obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: buf)))
        Dart_PostCObject_DL(dartPort, &obj)
    }
}
```

**Kotlin:**
```kotlin
override suspend fun captureAudio(durationMs: Long, dartPort: Long): Unit {
    _asyncExecutor.submit {
        val bytes = recordFor(durationMs)
        // post via JNI helper
        postBytesToPort(dartPort, bytes)
    }
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

By default, `IsolatePool` uses `Platform.numberOfProcessors` workers (capped at 8). Override:

```dart
void main() {
  NitroConfig.instance
    ..isolatePoolSize = 4   // custom worker count
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
  ..slowCallThresholdMicros = 50000  // 50 ms
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
</content>
</invoke>