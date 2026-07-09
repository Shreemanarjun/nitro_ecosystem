import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
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
  static const int expectedAbiVersion = 1;

  static final Map<String, DynamicLibrary> _libCache = {};
  // Reference count per library name — incremented on first load, decremented
  // in releaseLib(). When it reaches 0 the library is closed and removed from
  // the cache so the next loadLib() call reloads it from disk.
  static final Map<String, int> _libRefCount = {};
  static IsolatePool? _pool;
  static bool _poolReady = false;

  static String _timelineLabel(String tag) => 'Nitro.$tag';

  /// True on iOS and macOS — used by generated code to select `@Native<F>` direct
  /// dispatch vs function-pointer dispatch. Generated part files cannot import
  /// dart:io directly, so this bridges the Platform check.
  static final bool useNativeBindings = Platform.isIOS || Platform.isMacOS;

  // ── Library loading ──────────────────────────────────────────────────────

  static DynamicLibrary loadLib(String libName) {
    _libRefCount[libName] = (_libRefCount[libName] ?? 0) + 1;
    return _libCache.putIfAbsent(libName, () {
      _log(NitroLogLevel.verbose, 'loadLib', 'Loading native lib: $libName');
      final sw = Stopwatch()..start();
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

      sw.stop();
      _log(NitroLogLevel.verbose, 'loadLib', 'Loaded: $libName in ${sw.elapsedMicroseconds} µs');
      return lib;
    });
  }

  /// Decrements the reference count for [libName]. When it reaches zero the
  /// library is closed (unmapped from process memory on Android/Linux/Windows)
  /// and removed from the cache. Safe to call from [dispose()].
  ///
  /// On iOS/macOS [DynamicLibrary.process()] is used — close() is a no-op but
  /// harmless. The cache entry is still removed so the next [loadLib()] call
  /// resets the ref count cleanly.
  static void releaseLib(String libName) {
    final count = _libRefCount[libName];
    if (count == null || count <= 0) return;
    final next = count - 1;
    if (next == 0) {
      _libRefCount.remove(libName);
      final lib = _libCache.remove(libName);
      lib?.close();
      _log(NitroLogLevel.verbose, 'releaseLib', 'Released native lib: $libName');
    } else {
      _libRefCount[libName] = next;
    }
  }

  static DynamicLibrary loadLibForTargets(
    String libName, {
    required bool ios,
    required bool android,
    required bool macos,
    required bool windows,
    required bool linux,
    required bool web,
  }) {
    checkSupportedPlatform(
      libName,
      ios: ios,
      android: android,
      macos: macos,
      windows: windows,
      linux: linux,
      web: web,
    );
    return loadLib(libName);
  }

  static void checkSupportedPlatform(
    String libName, {
    required bool ios,
    required bool android,
    required bool macos,
    required bool windows,
    required bool linux,
    required bool web,
  }) {
    final isSupported = (ios && Platform.isIOS) || (android && Platform.isAndroid) || (macos && Platform.isMacOS) || (windows && Platform.isWindows) || (linux && Platform.isLinux);
    if (isSupported) return;

    final targets = <String>[
      if (ios) 'iOS',
      if (android) 'Android',
      if (macos) 'macOS',
      if (windows) 'Windows',
      if (linux) 'Linux',
      if (web) 'Web',
    ].join(', ');
    throw UnsupportedError(
      '$libName: this generated Nitro module does not target '
      '${_currentPlatformName()}. Targeted platforms: '
      '${targets.isEmpty ? 'none' : targets}. Update @NitroModule platform '
      'targets, regenerate with `nitrogen generate`, run `nitrogen link`, '
      'and rebuild the app.',
    );
  }

  static String _currentPlatformName() {
    if (Platform.isIOS) return 'iOS';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    if (Platform.isFuchsia) return 'Fuchsia';
    return Platform.operatingSystem;
  }

  static void checkAbiVersion(String libName, int Function() readVersion) {
    late final int actual;
    try {
      actual = readVersion();
    } catch (error) {
      throw StateError(
        '$libName: Nitro ABI version check failed. Run `nitrogen generate` '
        'and `nitrogen link` so the generated Dart and native bridge code '
        'come from the same Nitro toolchain. Details: $error',
      );
    }

    if (actual != expectedAbiVersion) {
      throw StateError(
        '$libName: Nitro ABI version mismatch. Dart runtime expects '
        '$expectedAbiVersion but the native bridge reports $actual. Run '
        '`nitrogen generate` and `nitrogen link`, then rebuild the app.',
      );
    }
  }

  static void checkLinkChecksum(
    String libName,
    String expectedChecksum,
    String Function() readChecksum,
  ) {
    late final String actual;
    try {
      actual = readChecksum();
    } catch (error) {
      throw StateError(
        '$libName: Nitro bridge checksum check failed. Run `nitrogen generate` '
        'and `nitrogen link` so the generated Dart and native bridge code are '
        'compiled into the same native library. Details: $error',
      );
    }

    if (actual != expectedChecksum) {
      throw StateError(
        '$libName: Nitro bridge checksum mismatch. Dart expects '
        '$expectedChecksum but the native bridge reports $actual. Run '
        '`nitrogen generate` and `nitrogen link`, then rebuild the app.',
      );
    }
  }

  // ── Lifecycle logging ────────────────────────────────────────────────────

  /// Logs a lifecycle event (init, dispose) for a module.
  /// Called by generated code so it has access to the module name.
  static void logLifecycle(String tag, String message) {
    _log(NitroLogLevel.verbose, tag, message);
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

  // ── S8: Out-param error checking ─────────────────────────────────────────
  //
  // S8 eliminates the two-call `get_error()` + `clear_error()` round-trip from
  // every synchronous bridge call. Instead, each generated C function receives
  // a `NitroError*` out-parameter and writes error information directly into it.
  // Dart allocates ONE `NitroErrorFfi` struct per module instance (in the
  // constructor) and passes it to every sync call. Since each `_NitroXxxImpl`
  // lives in a single Dart isolate, the slot is never accessed concurrently.
  //
  // Benefits vs the old TLS-slot approach:
  //   • Debug mode:   3 FFI calls → 1 FFI call  (-2 per sync method)
  //   • Release mode: errors are NOW ALWAYS checked (assert-gate removed)
  //   • No heap allocation per call — struct is pre-allocated in constructor

  /// Checks an S8-style out-parameter error slot.
  ///
  /// If [errPtr.ref.hasError] is non-zero the method reads the C-owned string
  /// fields (copying them into Dart [String]s), frees the native memory, resets
  /// the slot for the next call, and throws a [HybridException].
  ///
  /// This is a no-op when there is no error — optimised to a single byte read.
  static void throwIfOutParamError(Pointer<NitroErrorFfi> errPtr) {
    if (errPtr.ref.hasError == 0) return;
    // Copy C-owned strings into Dart before freeing native memory.
    final name = errPtr.ref.name != nullptr
        ? errPtr.ref.name.toDartString()
        : 'NativeException';
    final message = errPtr.ref.message != nullptr
        ? errPtr.ref.message.toDartString()
        : 'An unknown native exception occurred.';
    final code = errPtr.ref.code != nullptr
        ? errPtr.ref.code.toDartString()
        : null;
    final stack = errPtr.ref.stackTrace != nullptr
        ? errPtr.ref.stackTrace.toDartString()
        : null;
    // Free native-heap strings (strdup'd by the C bridge) and reset the slot.
    if (errPtr.ref.name != nullptr) {
      malloc.free(errPtr.ref.name);
      errPtr.ref.name = nullptr;
    }
    if (errPtr.ref.message != nullptr) {
      malloc.free(errPtr.ref.message);
      errPtr.ref.message = nullptr;
    }
    if (errPtr.ref.code != nullptr) {
      malloc.free(errPtr.ref.code);
      errPtr.ref.code = nullptr;
    }
    if (errPtr.ref.stackTrace != nullptr) {
      malloc.free(errPtr.ref.stackTrace);
      errPtr.ref.stackTrace = nullptr;
    }
    errPtr.ref.hasError = 0;
    throw HybridException(
      name: name,
      message: message,
      code: code,
      stackTrace: stack,
    );
  }

  // ── Synchronous call ─────────────────────────────────────────────────────

  /// Calls a native function synchronously, with logging and slow-call
  /// detection that mirror [callAsync].
  ///
  /// Pass [methodName] so log lines identify which method was called:
  ///
  /// ```dart
  /// final res = NitroRuntime.callSync(
  ///   () {
  ///     final r = _addPtr(a, b);
  ///     NitroRuntime.checkError(_getErrorPtr, _clearErrorPtr);
  ///     return r;
  ///   },
  ///   methodName: 'add',
  /// );
  /// ```
  ///
  /// At [NitroLogLevel.verbose] every call emits a "calling" + "completed in
  /// N µs" pair.  When [NitroConfig.slowCallThresholdUs] > 0 a
  /// [NitroLogLevel.warning] is emitted for calls that exceed the threshold —
  /// useful for catching synchronous FFI calls that block the UI thread.
  ///
  /// Any exception thrown by [call] (typically a [HybridException] from
  /// [checkError]) is logged at [NitroLogLevel.error] and re-thrown.
  static T callSync<T>(T Function() call, {String methodName = ''}) {
    final cfg = NitroConfig.instance;
    final effective = cfg.effectiveLogLevel;
    final traceTimeline = cfg.timelineTracingEnabled;

    // Fast path: logging is fully disabled.
    if (effective == NitroLogLevel.none && !traceTimeline) return call();

    final tag = methodName.isEmpty ? 'callSync' : 'callSync($methodName)';
    final sw = (effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0) ? (Stopwatch()..start()) : null;

    _log(NitroLogLevel.verbose, tag, 'calling');

    if (traceTimeline) developer.Timeline.startSync(_timelineLabel(tag));
    try {
      final result = call();
      if (sw != null) {
        sw.stop();
        final us = sw.elapsedMicroseconds;
        _log(NitroLogLevel.verbose, tag, 'completed in $us µs');
        if (cfg.slowCallThresholdUs > 0 && us > cfg.slowCallThresholdUs) {
          _log(
            NitroLogLevel.warning,
            tag,
            'slow call: $us µs exceeded threshold of ${cfg.slowCallThresholdUs} µs',
          );
        }
      }
      return result;
    } catch (e, st) {
      _log(NitroLogLevel.error, tag, 'threw: $e', e, st);
      rethrow;
    } finally {
      if (traceTimeline) developer.Timeline.finishSync();
    }
  }

  // ── Callback lifecycle ────────────────────────────────────────────────────

  /// Closes a replaced callback [NativeCallable] on the next microtask turn.
  ///
  /// Generated callback-setter helpers call this whenever a callback-typed
  /// parameter slot already holds a previously-registered [NativeCallable] at
  /// the moment a new one is created (i.e. the setter was invoked again with
  /// a fresh closure — the common idiomatic-Flutter pattern). [old] must not
  /// be closed until native has switched over to the *new* function pointer,
  /// which happens synchronously inside the FFI call that immediately follows
  /// the helper on the same call stack — scheduling the close on a microtask
  /// guarantees it runs only after that call has returned. No-op if [old] is
  /// `null` (first registration).
  static void deferredClose(NativeCallable<dynamic>? old) {
    if (old == null) return;
    scheduleMicrotask(old.close);
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

    /// The Dart method name passed by generated code (e.g. `'fetchData'`).
    /// Included in every log message so slow-call warnings are immediately
    /// actionable without attaching a debugger.
    String methodName = '',
  }) async {
    final cfg = NitroConfig.instance;
    final poolSize = cfg.isolatePoolSize;
    final effective = cfg.effectiveLogLevel;
    final traceTimeline = cfg.timelineTracingEnabled;
    // Only pay for timing when there's somewhere to send the result.
    final sw = effective != NitroLogLevel.none && (effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0) ? (Stopwatch()..start()) : null;

    final tag = methodName.isEmpty ? 'callAsync' : 'callAsync($methodName)';

    if (traceTimeline) developer.Timeline.startSync(_timelineLabel(tag));
    try {
      final T result;
      if (poolSize <= 0 || !_poolReady) {
        // Legacy: spawn a fresh isolate per call.
        _log(NitroLogLevel.verbose, tag, 'dispatching via Isolate.run');
        result = await Isolate.run(() {
          final res = Function.apply(fn, args) as T;
          if (getError != null && clearError != null) {
            checkError(getError.asFunction(), clearError.asFunction());
          }
          return res;
        });
      } else {
        _log(NitroLogLevel.verbose, tag, 'dispatching via pool (size=$poolSize)');
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
        _log(NitroLogLevel.verbose, tag, 'completed in $us µs');
        if (cfg.slowCallThresholdUs > 0 && us > cfg.slowCallThresholdUs) {
          _log(
            NitroLogLevel.warning,
            tag,
            'slow call: $us µs exceeded threshold of ${cfg.slowCallThresholdUs} µs',
          );
        }
      }

      return result;
    } finally {
      if (traceTimeline) developer.Timeline.finishSync();
    }
  }

  // ── Native-async (zero-hop) ──────────────────────────────────────────────

  /// Opens a single-use [ReceivePort], hands its native port ID to [call] so
  /// the native implementation can post the result via `Dart_PostCObject_DL`,
  /// then waits for exactly one message and converts it with [unpack].
  ///
  /// This eliminates the isolate-message double-hop that [callAsync] incurs:
  /// no Dart isolate is ever spawned, cutting per-call overhead
  /// when the native side is already asynchronous (Kotlin coroutine,
  /// Swift `async`, C++ thread pool).
  ///
  /// The native side **must** post exactly one message to the port.
  static Future<T> openNativeAsync<T>({
    required void Function(int dartPort) call,
    required T Function(dynamic raw) unpack,
    String methodName = '',
  }) {
    final cfg = NitroConfig.instance;
    final effective = cfg.effectiveLogLevel;
    final tag = methodName.isEmpty ? 'nativeAsync' : 'nativeAsync($methodName)';
    final traceTimeline = cfg.timelineTracingEnabled;

    final sw = effective != NitroLogLevel.none && (effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0) ? (Stopwatch()..start()) : null;

    _log(NitroLogLevel.verbose, tag, 'calling');

    final port = ReceivePort();
    if (traceTimeline) developer.Timeline.startSync(_timelineLabel(tag));
    try {
      call(port.sendPort.nativePort);
    } catch (_) {
      port.close();
      if (traceTimeline) developer.Timeline.finishSync();
      rethrow;
    }
    return port.first
        .then((raw) {
          port.close();
          if (sw != null) {
            sw.stop();
            final us = sw.elapsedMicroseconds;
            _log(NitroLogLevel.verbose, tag, 'completed in $us µs');
            if (cfg.slowCallThresholdUs > 0 && us > cfg.slowCallThresholdUs) {
              _log(
                NitroLogLevel.warning,
                tag,
                'slow call: $us µs exceeded threshold of ${cfg.slowCallThresholdUs} µs',
              );
            }
          }
          try {
            return unpack(raw);
          } catch (e, st) {
            _log(NitroLogLevel.error, tag, 'threw during unpack: $e', e, st);
            rethrow;
          }
        })
        .whenComplete(() {
          if (traceTimeline) developer.Timeline.finishSync();
        });
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

    /// Inject a pre-created [ReceivePort] instead of creating one internally.
    /// Only for unit tests — production callers should leave this null.
    @visibleForTesting ReceivePort? testPort,
  }) {
    final label = debugLabel ?? 'Stream<$T>';
    final receivePort = testPort ?? ReceivePort();
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
