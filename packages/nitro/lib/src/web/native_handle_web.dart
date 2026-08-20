/// Web twin of the native `NativeHandle<T>`.
///
/// On web a native handle IS its integer address — a wasm32 linear-memory
/// offset (or an opaque id the C++ impl chose). The type parameter [T] is
/// documentation only, exactly as on native; the marker types from the ffi
/// stub (`Void`, etc.) satisfy existing `NativeHandle<Void>` spec signatures.
///
/// There is deliberately no `pointer` getter: dereferencing a handle is a
/// native-only operation, so code that does `handle.pointer` fails to compile
/// for web instead of failing at runtime.
class NativeHandle<T> {
  /// The raw address / opaque id.
  final int address;

  NativeHandle.fromAddress(this.address);

  // Internal: set by generated code when @NitroOwned is present.
  void Function(int)? _releaseCallback;

  /// Registers the generated release callback for an owned handle.
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
