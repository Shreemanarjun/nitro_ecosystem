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
| Owned (`@NitroOwned`) | Dart | Until `release()` or GC | `NativeFinalizer` → `_release` |

**Never store a borrowed handle** beyond the synchronous call that returned it.

## Validator rules

| Situation | Result |
|---|---|
| `@NitroOwned` on `NativeHandle<T>` return | ✅ Valid |
| `@NitroOwned` on non-`NativeHandle` return | ❌ `INVALID_OWNED` error |
| `@NitroOwned` on a parameter | ❌ `INVALID_OWNED` error |
| `NativeHandle<T>` as param (no `@NitroOwned`) | ✅ Valid (borrow) |
