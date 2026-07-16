# NativeHandle<T> — Raw Pointer Escape Hatch

`NativeHandle<T>` lets you pass opaque native pointers through the Nitro bridge with **zero codec overhead**. The type parameter `T` is Dart-side documentation only; the wire format is always `void*` / `Long` / `UnsafeMutableRawPointer?`.

## When to use

Use `NativeHandle<T>` when native code owns a heap-allocated resource (a GPU buffer, camera frame, audio buffer, C++ object) and Dart needs to refer to it without copying or serializing it.

**Do not** use it for small data that fits in a struct or record — those have better ergonomics and type safety.

## Spec syntax

```dart
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Camera extends HybridObject {
  // Borrow — native retains ownership. The handle is valid only
  // for the duration of the call. Do NOT store it.
  NativeHandle<Void> peekLatestFrame();

  // Own — native heap-allocates; Dart NativeFinalizer calls _release on GC.
  @NitroOwned
  NativeHandle<Void> acquireFrame();

  // Pass handle back to native — no codec, pure pointer pass-through.
  void processFrame(NativeHandle<Void> handle);
}
```

## Generated cross-platform output

| Platform | Return | Param | Notes |
|---|---|---|---|
| **Dart FFI** | `NativeHandle<Void>` wrapping `Pointer<Void>` | `Pointer<Void>` | `@NitroOwned` attaches `NativeFinalizer` |
| **Kotlin** | `Long` (pointer address) | `Long` | JNI bridge; address is the native `void*` |
| **Swift** | `UnsafeMutableRawPointer?` | `UnsafeMutableRawPointer?` | @_cdecl stub |
| **C++ interface** | `void*` | `void*` | pure virtual method |
| **C++ bridge** | `void*` | `void*` | pass-through |
| **C header** | `void* fn(void)` | `void fn(void* handle)` | NITRO_EXPORT |

## `@NitroOwned` — automatic memory management

Mark the return of a `NativeHandle`-returning method with `@NitroOwned` to tell the generator that **Dart takes ownership** of the allocation:

```dart
@NitroOwned
NativeHandle<Void> acquireFrame();
```

The generator emits:

**C header:**
```c
// Implement this to free the allocation.
NITRO_EXPORT void camera_acquire_frame_release(void* handle);
```

**Dart FFI** (generated):
```dart
late final _acquireFrameReleaseFn = _dylib.lookupFunction<...>('camera_acquire_frame_release');
late final _acquireFrameFinalizer = NativeFinalizer(_dylib.lookup<...>('camera_acquire_frame_release').cast());

NativeHandle<Void> acquireFrame() {
  return NitroRuntime.callSync(() {
    final res = _acquireFramePtr();
    final handle = NativeHandle<Void>.fromAddress(res.address);
    _acquireFrameFinalizer.attach(handle, res.cast(), detach: handle);
    handle._releaseCallback = (addr) { ... };
    return handle;
  }, methodName: 'acquireFrame');
}
```

**You implement** (in your `.cpp`):
```cpp
void camera_acquire_frame_release(void* handle) {
    delete static_cast<CameraFrame*>(handle);
}
```

## Library-owned handles: `@NitroOwned(release: ...)`

Handles created by a native library (wgpu, sqlite, …) must be released through
the library's own function — calling `free()` on them corrupts the allocator.
Pass the release symbol in the annotation:

```dart
@NitroOwned(release: 'wgpuBufferRelease')
NativeHandle<Void> createBuffer(int size);
```

The generated `<symbol>_release` thunk then calls `wgpuBufferRelease(handle)`
instead of `free(handle)` — both the `NativeFinalizer` (GC) path and manual
`handle.release()` go through it, so ownership stays with the library's API on
every platform. Requirements:

- The symbol must be an `extern "C"` function taking the handle pointer as its
  single argument.
- It must be linked into the plugin's native library on **every** platform the
  module builds for (the bridge forward-declares it; the linker resolves it).
- Several methods may share one release symbol — it is declared once.

## Async owned factories: `Future<NativeHandle<T>>`

`@nitroNativeAsync` composes with `@NitroOwned` — the whole acquire-async,
own-on-arrival flow is one annotation pair (no hand-rolled address plumbing):

```dart
@nitroNativeAsync
@NitroOwned(release: 'wgpuAdapterRelease')
Future<NativeHandle<Void>> requestAdapter(NativeHandle<Void> instance);
```

Wire contract: the native side posts the raw pointer address as
`Dart_CObject_kInt64`. Dart attaches the `NativeFinalizer` and release
callback the moment the handle arrives, so ownership transfer is atomic —
there is no window where the pointer exists un-owned on the Dart side.

- **Kotlin** — the interface method is `suspend fun requestAdapter(...): Long`;
  return the address (0 = null for a nullable handle).
- **Swift** — `func requestAdapter(...) async throws -> UnsafeMutableRawPointer?`;
  nil posts address 0.
- **C++** — post `(int64_t)(uintptr_t)handle` via `Dart_PostCObject_DL`.

A nullable `Future<NativeHandle<T>?>` decodes both `kNull` and address 0 to
Dart `null`; a non-nullable one turns a posted null into a descriptive
`StateError`.

## Manual early release

```dart
final frame = cam.acquireFrame();
// ... use frame ...
frame.release();   // calls _release now, detaches finalizer
// OR let the GC collect it — finalizer handles cleanup automatically
```

## Casting to a concrete type

`NativeHandle<T>` carries the type parameter as documentation. To access fields of the underlying native struct, cast the pointer:

```dart
final frame = cam.peekLatestFrame();              // NativeHandle<Void>
final ptr = frame.pointer.cast<CameraFrameNative>(); // Pointer<CameraFrameNative>
final native = ptr.ref;                            // CameraFrameNative (NativeStruct)
// Read fields without any copy
```

## Lifecycle rules

| Variant | Who owns | When valid | How freed |
|---|---|---|---|
| Borrow (no `@NitroOwned`) | Native | During the call only | Native frees |
| Owned (`@NitroOwned`) | Dart | Until `release()` or GC | `NativeFinalizer` → `_release` → `free()` |
| Owned (`@NitroOwned(release: 'sym')`) | Dart | Until `release()` or GC | `NativeFinalizer` → `_release` → `sym(handle)` |

**Never store a borrowed handle** beyond the synchronous call that returned it.

## Validator rules

| Situation | Result |
|---|---|
| `@NitroOwned` on `NativeHandle<T>` return | ✅ Valid |
| `@NitroOwned` on non-`NativeHandle` return | ❌ `INVALID_OWNED` error |
| `@NitroOwned` on a parameter | ❌ `INVALID_OWNED` error |
| `NativeHandle<T>` as param (no `@NitroOwned`) | ✅ Valid (borrow) |
