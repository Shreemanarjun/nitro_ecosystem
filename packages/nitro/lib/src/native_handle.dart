import 'dart:ffi';

/// A lightweight wrapper around a raw native pointer that crosses the Nitro
/// bridge without any codec overhead.
///
/// The type parameter [T] extends [NativeType] and serves as documentation only
/// — at the Dart FFI level all handles are `Pointer<Void>`. No runtime casting
/// or checking is performed.
///
/// ### Lifetime
///
/// - **Borrow** (no `@NitroOwned`): native code retains ownership. The handle
///   is valid only during the call that returned it. Do not store it.
/// - **Owned** (`@NitroOwned`): Dart owns the allocation. A `NativeFinalizer`
///   is automatically attached; the native `_release` function runs when the
///   `NativeHandle` is garbage-collected.  Call [release] for early cleanup.
///
/// ### Usage
///
/// ```dart
/// // Native returns an opaque camera frame handle
/// final handle = cam.acquireFrame();       // NativeHandle<Void>
/// final ptr = handle.pointer.cast<CameraFrameNative>();
/// final frame = ptr.ref;                   // read fields
/// handle.release();                        // early free (optional)
/// ```
class NativeHandle<T extends NativeType> implements Finalizable {
  /// The underlying raw pointer. Do not store this beyond the handle's lifetime.
  final Pointer<T> pointer;

  /// Convenience getter for the numeric address.
  int get address => pointer.address;

  NativeHandle(this.pointer);

  /// Constructs a [NativeHandle] from a raw integer address.
  NativeHandle.fromAddress(int addr) : pointer = Pointer<T>.fromAddress(addr);

  // Internal: set by generated code when @NitroOwned is present.
  // Calling release() triggers this and detaches the finalizer.
  void Function(int)? _releaseCallback;

  /// Registers the generated release callback for an owned handle.
  ///
  /// This is used by generated bridge code for `@NitroOwned` returns. Calling
  /// [release] invokes the callback once, then clears it.
  void attachReleaseCallback(void Function(int address) callback) {
    _releaseCallback = callback;
  }

  /// Manually release the native resource.
  ///
  /// Only meaningful when the handle was returned with `@NitroOwned`.
  /// Safe to call multiple times — subsequent calls are no-ops.
  void release() {
    final cb = _releaseCallback;
    if (cb != null) {
      _releaseCallback = null;
      cb(address);
    }
  }

  @override
  String toString() => 'NativeHandle<$T>(0x${address.toRadixString(16)})';
}
