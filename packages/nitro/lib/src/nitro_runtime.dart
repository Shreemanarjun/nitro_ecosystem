import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'annotations.dart';
import 'hybrid_exception.dart';
import 'isolate_pool.dart';
import 'nitro_config.dart';

export 'nitro_config.dart';

// ── Internal logger helper ────────────────────────────────────────────────────

void _log(
  NitroLogLevel level,
  String tag,
  String message, [
  Object? error,
  StackTrace? stack,
]) {
  final cfg = NitroConfig.instance;
  final effective = cfg.effectiveLogLevel;
  if (effective == NitroLogLevel.none) return;

  final levelRank = NitroLogLevel.values.indexOf(level);
  final effectiveRank = NitroLogLevel.values.indexOf(effective);
  if (levelRank > effectiveRank) return;

  cfg.logHandler(level, tag, message, error, stack);
}

// ── NitroRuntime ──────────────────────────────────────────────────────────────

/// The runtime is called only by generated code.
/// Plugin authors and app developers interact with [NitroConfig] instead.
class NitroRuntime {
  static final Map<String, DynamicLibrary> _libCache = {};
  static IsolatePool? _pool;
  static bool _poolReady = false;

  // ── Library loading ──────────────────────────────────────────────────────

  static DynamicLibrary loadLib(String libName) {
    if (_libCache.containsKey(libName)) return _libCache[libName]!;

    _log(NitroLogLevel.verbose, 'loadLib', 'Loading native lib: $libName');
    late DynamicLibrary lib;
    if (Platform.isIOS || Platform.isMacOS) {
      lib = DynamicLibrary.process();
    } else if (Platform.isAndroid) {
      lib = DynamicLibrary.open('lib$libName.so');
    } else if (Platform.isWindows) {
      lib = DynamicLibrary.open('$libName.dll');
    } else {
      lib = DynamicLibrary.open('lib$libName.so');
    }

    _libCache[libName] = lib;
    _log(NitroLogLevel.verbose, 'loadLib', 'Loaded: $libName');
    return lib;
  }

  // ── Error handling ────────────────────────────────────────────────────────

  /// Checks if the last native call in [dylib] resulted in an error.
  /// If so, throws a [HybridException] and clears the error state.
  /// Checks if the last native call resulted in an error.
  /// If so, throws a [HybridException] and clears the error state.
  static void checkError(
    Pointer<NitroErrorFfi> Function() get,
    void Function() clear,
  ) {
    try {
      final errPtr = get();
      if (errPtr != nullptr && errPtr.ref.hasError != 0) {
        final name = errPtr.ref.name.toDartString();
        final message = errPtr.ref.message.toDartString();
        final code = errPtr.ref.code != nullptr ? errPtr.ref.code.toDartString() : null;
        final stack = errPtr.ref.stackTrace != nullptr ? errPtr.ref.stackTrace.toDartString() : null;

        // Clear for next call
        clear();

        throw HybridException(
          name: name,
          message: message,
          code: code,
          stackTrace: stack,
        );
      }
    } catch (e) {
      if (e is HybridException) rethrow;
      // If error handlers fail or are invalid stubs, ignore and continue.
      return;
    }
  }

  // ── Synchronous call ─────────────────────────────────────────────────────

  /// Calls a native function synchronously.
  static T callSync<T>(Function fn, List<Object?> args) {
    if (NitroConfig.instance.effectiveLogLevel == NitroLogLevel.verbose) {
      final sw = Stopwatch()..start();
      final result = Function.apply(fn, args) as T;
      sw.stop();
      _log(
        NitroLogLevel.verbose,
        'callSync',
        'call completed in ${sw.elapsedMicroseconds} µs',
      );
      return result;
    }
    return Function.apply(fn, args) as T;
  }

  // ── Async call via isolate pool ──────────────────────────────────────────

  /// Calls a native function on a background isolate.
  ///
  /// When [NitroConfig.instance.isolatePoolSize] is `0`, falls back to
  /// spawning a fresh [Isolate] per call (legacy behaviour).
  /// Otherwise dispatches to the pre-warmed [IsolatePool].
  static Future<T> callAsync<T>(
    Function fn,
    List<Object?> args, {
    Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>>? getError,
    Pointer<NativeFunction<Void Function()>>? clearError,
  }) async {
    final cfg = NitroConfig.instance;
    final poolSize = cfg.isolatePoolSize;
    final effective = cfg.effectiveLogLevel;
    // Only pay for timing when there's somewhere to send the result.
    final sw = effective != NitroLogLevel.none && (effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0) ? (Stopwatch()..start()) : null;

    final T result;
    if (poolSize <= 0 || !_poolReady) {
      // Legacy: spawn a fresh isolate per call.
      _log(NitroLogLevel.verbose, 'callAsync', 'dispatching via Isolate.run');
      result = await Isolate.run(() {
        final res = Function.apply(fn, args) as T;
        if (getError != null && clearError != null) {
          checkError(getError.asFunction(), clearError.asFunction());
        }
        return res;
      });
    } else {
      _log(
        NitroLogLevel.verbose,
        'callAsync',
        'dispatching via pool (size=$poolSize)',
      );
      result = await _pool!.dispatch<T>(
        fn,
        args,
        getError: getError,
        clearError: clearError,
      );
    }

    if (sw != null) {
      sw.stop();
      final us = sw.elapsedMicroseconds;
      _log(NitroLogLevel.verbose, 'callAsync', 'completed in $us µs');
      if (cfg.slowCallThresholdUs > 0 && us > cfg.slowCallThresholdUs) {
        _log(
          NitroLogLevel.warning,
          'callAsync',
          'slow call detected: $us µs > threshold ${cfg.slowCallThresholdUs} µs',
        );
      }
    }

    return result;
  }

  // ── Stream ───────────────────────────────────────────────────────────────

  /// Opens a high-performance stream from a native event source.
  /// Uses a [ReceivePort] for direct native-to-Dart posting (Dart_PostCObject).
  ///
  /// ## Lifecycle safety
  ///
  /// The stream handles three teardown scenarios without dangling references:
  ///
  /// **1. Explicit cancel** — `subscription.cancel()` triggers `onCancel`,
  /// which calls `release(port)` immediately. The native emitter stops.
  ///
  /// **2. GC without cancel** — if a widget is disposed without cancelling its
  /// subscription, a [Finalizer] attached to the [StreamController] fires when
  /// it is GC'd and calls `release(port)` automatically, stopping the native
  /// thread from posting to a dead port indefinitely.
  ///
  /// **3. Hot restart** — Flutter tears down the Dart isolate; [ReceivePort]s
  /// are invalidated so `Dart_PostCObject` returns false and the C++ bridge
  /// stops emitting. The Dart [Finalizer] may not fire during a full isolate
  /// shutdown. For guaranteed cleanup across hot restarts, plugin authors should
  /// expose a C release symbol and use [NativeFinalizer] on their objects —
  /// see `docs/lifecycle.md` for the full pattern.
  static Stream<T> openStream<T>({
    required void Function(int dartPort) register,
    required T Function(dynamic message) unpack,
    required void Function(int dartPort) release,
    required Backpressure backpressure,

    /// Optional tag used in log messages to identify this stream.
    /// Defaults to `'Stream<$T>'`.
    String? debugLabel,
  }) {
    final label = debugLabel ?? 'Stream<$T>';
    final receivePort = ReceivePort();
    final nativePort = receivePort.sendPort.nativePort;
    var released = false;
    var eventCount = 0;

    _log(NitroLogLevel.verbose, label, 'opening (port=$nativePort)');

    // Idempotent release — safe to call from either onCancel or the finalizer.
    void doRelease() {
      if (released) return;
      released = true;
      _log(
        NitroLogLevel.verbose,
        label,
        'releasing (port=$nativePort, events=$eventCount)',
      );
      release(nativePort);
      receivePort.close();
    }

    final controller = StreamController<T>(
      onListen: () {
        _log(NitroLogLevel.verbose, label, 'listener attached — registering');
        register(nativePort);
      },
      onCancel: doRelease,
    );

    // Safety net: if the StreamController is GC'd without cancel() being
    // called (abandoned subscription, hot-restart mid-listen), doRelease still
    // fires so the native emitter stops and the ReceivePort is freed.
    _streamFinalizer.attach(controller, doRelease, detach: controller);

    receivePort.listen((dynamic message) {
      if (controller.isClosed) return;
      try {
        final item = unpack(message);
        eventCount++;
        _log(
          NitroLogLevel.verbose,
          label,
          'event #$eventCount unpacked',
        );
        controller.add(item);
      } catch (e, st) {
        // Log at error level regardless of debugMode so unpack failures
        // are never silently swallowed.
        _log(
          NitroLogLevel.error,
          label,
          'unpack failed on event #${eventCount + 1} — forwarding error to stream',
          e,
          st,
        );
        controller.addError(e, st);
      }
    });

    return controller.stream;
  }

  // Finalizer for StreamControllers abandoned without cancel().
  // Token is a void Function() closure — no strong ref back to the controller.
  static final _streamFinalizer = Finalizer<void Function()>(
    (doRelease) => doRelease(),
  );

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /// Initialises the runtime.  Call once in `main()` before using any plugin.
  ///
  /// ```dart
  /// await NitroRuntime.init();
  /// // or with pool pre-warming:
  /// NitroConfig.instance.isolatePoolSize = 4;
  /// await NitroRuntime.init();
  /// ```
  static Future<void> init({int? isolatePoolSize}) async {
    final cfg = NitroConfig.instance;
    if (isolatePoolSize != null) cfg.isolatePoolSize = isolatePoolSize;

    final poolSize = cfg.isolatePoolSize;
    if (poolSize > 0) {
      _log(
        NitroLogLevel.verbose,
        'init',
        'spawning isolate pool (size=$poolSize)…',
      );
      _pool = await IsolatePool.create(poolSize);
      _poolReady = true;
      _log(NitroLogLevel.verbose, 'init', 'pool ready');
    } else {
      _log(
        NitroLogLevel.verbose,
        'init',
        'pool disabled (isolatePoolSize=0) — using Isolate.run per call',
      );
    }
  }

  /// Tears down the runtime.  Disposes the isolate pool and clears the lib
  /// cache.  After calling this, [init] must be called again before using
  /// any plugin.
  static Future<void> dispose() async {
    if (_poolReady) {
      _log(NitroLogLevel.verbose, 'dispose', 'shutting down isolate pool');
      _pool?.dispose();
      _pool = null;
      _poolReady = false;
    }
    _libCache.clear();
    _log(NitroLogLevel.verbose, 'dispose', 'done');
  }
}
