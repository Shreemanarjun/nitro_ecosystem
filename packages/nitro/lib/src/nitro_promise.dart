import 'dart:async';

// ── NitroPromise<T> — composable async primitive ──────────────────────────────
//
// Mirrors RN Nitro's `Promise<T>` C++ class, adapted for Dart/FFI.
//
// RN Nitro's Promise<T> is a composable async type with:
//   - .resolve(T) / .reject(Error)     — native side resolves
//   - .addOnResolvedListener(fn)        — chain work after completion
//   - .addOnRejectedListener(fn)        — chain error handling
//   - .then<R>(fn) → Promise<R>         — transform value
//   - .andThen<R>(fn) → Promise<R>      — async transform
//   - Static factories: resolved(), rejected(), async_()
//
// Flutter adaptation:
//   - Built on Dart's Completer<T> / Future<T> (no custom scheduler needed)
//   - Native code calls .resolve() / .reject() to complete the future
//   - .then<R>() / .catchError() / .whenComplete() chain using Future combos
//   - .future property exposes the underlying Dart Future<T>
//   - Thread-safe: Dart's Isolate model ensures single-threaded resolve/reject
//
// The main value over raw Completer<T>:
//   - Explicit pending/resolved/rejected state observable via [state]
//   - .addOnResolvedListener() / .addOnRejectedListener() for multi-subscriber
//   - .andThen<R>() for async chaining that returns a NitroPromise<R>
//   - Static factories mirror RN Nitro API exactly

/// Observable state of a [NitroPromise].
enum NitroPromiseState {
  /// The promise has been created but not yet resolved or rejected.
  pending,

  /// The promise was successfully completed with a value.
  resolved,

  /// The promise failed with an error.
  rejected,
}

/// A composable async primitive that mirrors RN Nitro's `Promise<T>`.
///
/// ## Creating and resolving
/// ```dart
/// final promise = NitroPromise<int>();
/// // Native code (called from C bridge):
/// promise.resolve(42);
///
/// // Dart consumers:
/// final value = await promise.future;           // standard Future<T>
/// promise.addOnResolvedListener((v) => print(v));
/// ```
///
/// ## Static factories (mirror RN Nitro API)
/// ```dart
/// final p1 = NitroPromise.resolved(42);         // already completed
/// final p2 = NitroPromise.rejected<int>(error); // already failed
/// final p3 = NitroPromise.async_(() async { ... return value; });
/// ```
///
/// ## Chaining
/// ```dart
/// final doubled = promise.then((v) => v * 2);          // NitroPromise<int>
/// final str     = promise.andThen((v) async => '$v');  // NitroPromise<String>
/// ```
class NitroPromise<T> {
  final Completer<T> _completer = Completer<T>();
  NitroPromiseState _state = NitroPromiseState.pending;

  final List<void Function(T)> _resolvedListeners = [];
  final List<void Function(Object, StackTrace?)> _rejectedListeners = [];

  NitroPromise();

  // ── State ─────────────────────────────────────────────────────────────────

  /// Current observable state of this promise.
  NitroPromiseState get state => _state;

  bool get isPending => _state == NitroPromiseState.pending;
  bool get isResolved => _state == NitroPromiseState.resolved;
  bool get isRejected => _state == NitroPromiseState.rejected;

  // ── Future interop ────────────────────────────────────────────────────────

  /// The underlying Dart [Future]. Await this for standard async/await usage.
  Future<T> get future => _completer.future;

  // ── Resolve / Reject ──────────────────────────────────────────────────────

  /// Complete this promise with [value]. Mirrors `Promise<T>::resolve(T)`.
  /// No-op if already settled (first-wins semantics, matching RN Nitro Promise).
  void resolve(T value) {
    if (!isPending) return;
    _state = NitroPromiseState.resolved;
    _completer.complete(value);
    for (final l in _resolvedListeners) {
      l(value);
    }
    _resolvedListeners.clear();
    _rejectedListeners.clear();
  }

  /// Complete this promise with an error. Mirrors `Promise<T>::reject(Error)`.
  /// No-op if already settled (first-wins semantics, matching RN Nitro Promise).
  void reject(Object error, [StackTrace? stackTrace]) {
    if (!isPending) return;
    _state = NitroPromiseState.rejected;
    _completer.completeError(error, stackTrace);
    // Suppress unhandled-rejection warning: register a no-op error handler so
    // Dart doesn't report the error as unhandled if the caller hasn't awaited
    // .future yet. Callers who do await .future still receive the error.
    // ignore: unawaited_futures
    _completer.future.then<void>((_) {}, onError: (Object e, StackTrace t) {});
    for (final l in _rejectedListeners) {
      l(error, stackTrace);
    }
    _rejectedListeners.clear();
    _resolvedListeners.clear();
  }

  // ── Listeners (multi-subscriber, mirrors RN Nitro addOnXxxListener) ───────

  /// Add a callback invoked when this promise resolves successfully.
  /// If already resolved, invokes immediately on the next microtask.
  void addOnResolvedListener(void Function(T value) listener) {
    if (isResolved) {
      // Already resolved — invoke asynchronously to avoid synchronous surprises.
      _completer.future.then(listener);
    } else if (isPending) {
      _resolvedListeners.add(listener);
    }
    // Rejected: resolved listeners are never called.
  }

  /// Add a callback invoked when this promise is rejected.
  /// If already rejected, invokes on the next microtask.
  void addOnRejectedListener(void Function(Object error, StackTrace? trace) listener) {
    if (isRejected) {
      // Error is already handled (no-op handler registered in reject()); consume
      // it here as a side-effect only — do NOT re-throw, which would create a
      // second unhandled future error.
      // ignore: unawaited_futures
      _completer.future.then<void>(
        (_) {},
        onError: (Object e, StackTrace t) {
          listener(e, t);
        },
      );
    } else if (isPending) {
      _rejectedListeners.add(listener);
    }
    // Resolved: rejection listeners are never called.
  }

  // ── Chaining ──────────────────────────────────────────────────────────────

  /// Synchronously transform the resolved value. Returns a new [NitroPromise<R>].
  /// Mirrors `Promise<T>::then<R>(fn)` in RN Nitro.
  NitroPromise<R> then<R>(R Function(T) transform) {
    final next = NitroPromise<R>();
    _completer.future.then(
      (v) => next.resolve(transform(v)),
      onError: (e, s) => next.reject(e, s),
    );
    return next;
  }

  /// Asynchronously chain another async operation. Returns a [NitroPromise<R>].
  /// Mirrors `Promise<T>::andThen<R>(fn)` in RN Nitro.
  NitroPromise<R> andThen<R>(Future<R> Function(T) transform) {
    final next = NitroPromise<R>();
    _completer.future.then(
      (v) => transform(v).then(next.resolve, onError: next.reject),
      onError: (e, s) => next.reject(e, s),
    );
    return next;
  }

  /// Recover from a rejection by providing a fallback value.
  NitroPromise<T> catchError(T Function(Object error) recover) {
    final next = NitroPromise<T>();
    _completer.future.then(
      next.resolve,
      onError: (e, _) {
        try {
          next.resolve(recover(e));
        } catch (e2, s2) {
          next.reject(e2, s2);
        }
      },
    );
    return next;
  }

  // ── Static factories (mirror RN Nitro Promise:: statics) ─────────────────

  /// A promise that is already resolved with [value].
  static NitroPromise<T> resolved<T>(T value) {
    final p = NitroPromise<T>();
    p.resolve(value);
    return p;
  }

  /// A promise that is already rejected with [error].
  static NitroPromise<T> rejected<T>(Object error, [StackTrace? trace]) {
    final p = NitroPromise<T>();
    p.reject(error, trace);
    return p;
  }

  /// Run [work] asynchronously and complete the returned promise with its result.
  /// Mirrors `Promise<T>::async_(fn)` in RN Nitro.
  static NitroPromise<T> async_<T>(Future<T> Function() work) {
    final p = NitroPromise<T>();
    work().then(p.resolve, onError: p.reject);
    return p;
  }

  /// Create a promise that resolves when ALL of [promises] resolve.
  /// If any rejects, the returned promise rejects immediately.
  static NitroPromise<List<T>> all<T>(List<NitroPromise<T>> promises) {
    final p = NitroPromise<List<T>>();
    Future.wait(promises.map((pp) => pp.future)).then(p.resolve, onError: p.reject);
    return p;
  }

  /// Create a promise that resolves/rejects with the first promise to settle.
  static NitroPromise<T> race<T>(List<NitroPromise<T>> promises) {
    final p = NitroPromise<T>();
    for (final pp in promises) {
      pp.addOnResolvedListener((v) {
        if (p.isPending) p.resolve(v);
      });
      pp.addOnRejectedListener((e, s) {
        if (p.isPending) p.reject(e, s);
      });
    }
    return p;
  }

  @override
  String toString() => 'NitroPromise<$T>($_state)';
}
