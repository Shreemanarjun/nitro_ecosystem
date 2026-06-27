# Memory Management in Nitro

Nitro manages native memory using three mechanisms depending on type:
**NativeFinalizer** (automatic), **ZeroCopyBuffer** (explicit or auto), and **NativeHandle<T>** (explicit with optional finalizer). Understanding the ownership rules prevents use-after-free and double-free bugs.

---

## 1. Structs (`@HybridStruct`)

Struct returns are heap-allocated by native code and owned by Dart.

### Lifetime

```
C++ / Kotlin / Swift → malloc(sizeof(Foo)) → Dart Foo (proxy)
                                             ↓
                                    NativeFinalizer
                                             ↓ (on GC)
                          ${lib}_release_Foo(ptr)  →  free(ptr)
```

The generated `FooProxy` class attaches a `NativeFinalizer` at construction. When the proxy is garbage-collected, the finalizer calls the native `_release_Foo` symbol.

### Ownership rules

- **Dart owns**: struct returns from bridge methods.
- **Do not free manually**: the finalizer handles it.
- **Safe to copy fields**: all non-ZeroCopy fields are eagerly decoded and owned by Dart.
- **ZeroCopy fields**: see §2 below.

### Example

```dart
final reading = sensor.getReading();    // Foo: heap-allocated by native
print(reading.temperature);             // safe — Dart has a copy
// reading goes out of scope → NativeFinalizer fires → free()
```

---

## 2. ZeroCopy buffers (`@ZeroCopy`)

Zero-copy buffers let Dart access native memory **without copying**. The native side retains the allocation; Dart holds a view.

### Concrete types

| Class | Element | Dart accessor |
|---|---|---|
| `ZeroCopyBuffer` | `uint8_t*` | `.bytes: Uint8List` |
| `ZeroCopyInt8Buffer` | `int8_t*` | `.values: Int8List` |
| `ZeroCopyInt16Buffer` | `int16_t*` | `.values: Int16List` |
| `ZeroCopyUint16Buffer` | `uint16_t*` | `.values: Uint16List` |
| `ZeroCopyInt32Buffer` | `int32_t*` | `.values: Int32List` |
| `ZeroCopyUint32Buffer` | `uint32_t*` | `.values: Uint32List` |
| `ZeroCopyFloat32Buffer` | `float*` | `.floats: Float32List` |
| `ZeroCopyFloat64Buffer` | `double*` | `.doubles: Float64List` |
| `ZeroCopyInt64Buffer` | `int64_t*` | `.values: Int64List` |

### Lifetime

```
C++ / Kotlin / Swift → malloc / non-owning ptr → ZeroCopyBuffer (Dart)
                                                          ↓ release() or GC
                                                   nativeRelease()  →  free / unlock
```

A shared `Finalizer<void Function()>` is attached. When the buffer is GC'd **or** `release()` is called, the `nativeRelease` callback runs.

### Ownership rules

- **Native must not free** the buffer while Dart holds the `ZeroCopyBuffer`.
- **Call `release()` explicitly** when done early to return the buffer sooner.
- **Double release is safe** — second call is a no-op.
- **After release, accessing `.bytes` / `.values` / `.floats` / `.doubles` throws `StateError`**.

### Example

```dart
// Struct with a @ZeroCopy pcm field:
final chunk = audio.getPcmChunk();
// chunk.pcm is backed by native memory — zero copy
processAudio(chunk.pcm.bytes);
chunk.pcm.release();  // hand memory back to native immediately
```

### Spec

```dart
@HybridStruct(zeroCopy: ['pcm'])
class AudioChunk {
  final Uint8List pcm;   // zero-copy — backed by native uint8_t*
  final int sampleRate;  // copied — owned by Dart
}
```

---

## 3. NativeHandle<T>

Raw opaque pointer escape hatch for objects that Dart should not decode.

### Borrowed handles (no `@NitroOwned`)

```dart
NativeHandle<Void> peekLatestFrame();
```

- Native retains ownership.
- Handle is **only valid during the synchronous call** that returned it.
- **Never store a borrowed handle**.

### Owned handles (`@NitroOwned`)

```dart
@NitroOwned
NativeHandle<Void> acquireFrame();
```

- Dart takes ownership.
- Generator emits a `NativeFinalizer` → `${cSymbol}_release(handle)`.
- Call `handle.release()` for early free; finalizer covers the rest.

See [native_handle.md](native_handle.md) for the full API.

---

## 4. Records (`@HybridRecord`)

Records are binary-encoded on the way in, eagerly decoded on the way out.

- **Method return**: C mallocs a length-prefixed buffer → Dart decodes eagerly → `malloc.free(buf)` → Dart owns the decoded object.
- **Callback param**: same flow in reverse — native mallocs, Dart decodes + frees in the `NativeCallable.listener`.
- **No lingering native memory**: by the time the Dart record object is visible, all native buffers are already freed.

---

## 5. Strings

- **Method return**: C calls `strdup()` → Dart calls `.toDartStringWithFree()` → `free()`.
- **Method param**: Dart arena-allocates a `Pointer<Utf8>` → native reads during the call → arena freed after `await`.

---

## 6. Typed data (non-zero-copy)

`Uint8List`, `Float32List`, etc. without `@ZeroCopy`:

- **Param**: Dart copies into a JVM array (`SetByteArrayRegion`) or native buffer.
- **Return**: native mallocs a `[int64 byte-length][payload]` envelope → Dart copies into a new list → `free()`.

---

## Quick reference

| Type | Owner | Release mechanism | After release |
|---|---|---|---|
| `@HybridStruct` (fields) | Dart | `NativeFinalizer` → `_release_Foo` | GC safe |
| `@ZeroCopy` field | Native | `release()` / GC → `nativeRelease` | `StateError` on access |
| `NativeHandle` (borrow) | Native | N/A — valid for call duration only | Undefined |
| `NativeHandle` (`@NitroOwned`) | Dart | `release()` / GC → `_release` | `release()` is no-op |
| `@HybridRecord` | Dart | automatic (buffer freed during decode) | N/A |
| `String` return | Dart | `toDartStringWithFree()` → `free` | N/A |
| `Uint8List` return | Dart | automatic | N/A |

---

## Common mistakes

**Storing a zero-copy view beyond native lifetime:**
```dart
// WRONG
Uint8List? _cached;
void onChunk(ZeroCopyBuffer buf) {
  _cached = buf.bytes;  // ← buf released, _cached is a dangling view
}

// CORRECT — copy the data if you need it after release
void onChunk(ZeroCopyBuffer buf) {
  _cached = Uint8List.fromList(buf.bytes);  // eager copy
  buf.release();
}
```

**Double-freeing a struct pointer:**
The `NativeFinalizer` handles this. Never call `malloc.free` on a struct pointer you received from Nitro.

**Using a borrowed `NativeHandle` after the call returns:**
```dart
// WRONG
NativeHandle<Void>? _saved;
void setup() {
  _saved = cam.peekFrame();  // borrow — only valid during this call
}
void later() {
  cam.processFrame(_saved!);  // UAF — native already freed the frame
}
```
