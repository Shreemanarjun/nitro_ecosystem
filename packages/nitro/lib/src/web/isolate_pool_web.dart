import 'dart:async';

/// Web twin of `IsolatePool`.
///
/// Isolates do not exist on the web (every `dart:isolate` member throws under
/// dart2wasm and dart2js), so the pool degrades to inline execution: `@nitroAsync`
/// work runs on the main thread with a single event-loop hop. Kept
/// API-compatible so runtime code and user configuration compile unchanged.
class IsolatePool {
  IsolatePool._();

  /// Web: no isolates to spawn — returns an inline-executing pool.
  static Future<IsolatePool> create(int size) async => IsolatePool._();

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
