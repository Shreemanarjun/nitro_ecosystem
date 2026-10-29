import 'dart:async';

/// Web twin of `IsolatePool`.
///
/// Isolates do not exist on the web (every `dart:isolate` member throws under
/// dart2wasm and dart2js), so the pool degrades to inline execution: `@nitroAsync`
/// work runs on the main thread with a single event-loop hop. Kept
/// API-compatible so runtime code and user configuration compile unchanged.
class IsolatePool {
  IsolatePool._();

  /// Web: no isolates to spawn — returns an inline-executing pool. [size] and
  /// [maxWorkers] are accepted for API parity with the VM pool but ignored
  /// (there is nothing to grow on a single-threaded runtime).
  static Future<IsolatePool> create(int size, {int? maxWorkers}) async => IsolatePool._();

  /// API parity with the VM pool: web runs inline, so there is one conceptual
  /// executor and it never grows.
  int get workerCount => 1;

  /// Runs [fn] inline after one event-loop hop. [getError]/[clearError] are
  /// the native error-slot function pointers on the VM; on web the generated
  /// bridge checks its own error slot, so they are ignored.
  Future<T> dispatch<T>(
    Function fn,
    List<Object?> args, {
    Object? getError,
    Object? clearError,
  }) => Future<T>(() => Function.apply(fn, args) as T);

  void dispose() {}
}
