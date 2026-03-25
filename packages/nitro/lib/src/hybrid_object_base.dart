// Every spec abstract class extends this.
// The generator checks for this supertype to confirm the class is a valid spec.
abstract class HybridObject {
  bool _disposed = false;

  /// Whether [dispose] has been called on this object.
  bool get isDisposed => _disposed;

  /// Releases all native resources held by this object.
  ///
  /// After calling [dispose]:
  /// - [isDisposed] returns `true`
  /// - Any call to a method, property getter/setter, or stream getter throws
  ///   a [StateError] with a descriptive message
  ///
  /// Safe to call multiple times — subsequent calls are no-ops.
  ///
  /// Override to release native handles, stop background timers, etc.
  /// Always call `super.dispose()`.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onDestroy();
  }

  /// Called once when [dispose] is first invoked.
  /// Override to perform cleanup (close file handles, cancel work, etc.).
  void onDestroy() {}

  /// Android low-memory signal. Override to release caches or non-critical data.
  void onMemoryTrim() {}

  /// Throws [StateError] if [dispose] has already been called.
  /// Called automatically at the start of every generated method and getter.
  @pragma('vm:prefer-inline')
  void checkDisposed() {
    if (_disposed) {
      throw StateError(
        '$runtimeType has been disposed — do not use after dispose().',
      );
    }
  }
}
