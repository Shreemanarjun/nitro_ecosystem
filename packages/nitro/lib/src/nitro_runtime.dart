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
import 'nitro_error_ffi.dart';
import 'nitro_completion_batch.dart';
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

  // NitroLogLevel is declared in severity order, so .index is the rank —
  // an O(1) compare instead of two O(n) indexOf scans per log check.
  if (level.index > effective.index) return;

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
  /// On iOS/macOS [DynamicLibrary.process()] is used — it CANNOT be closed
  /// (`close()` throws `Bad state: ... can't be closed`), so we skip the close
  /// there and only drop the cache entry. The cache entry is still removed so
  /// the next [loadLib()] call resets the ref count cleanly.
  static void releaseLib(String libName) {
    final count = _libRefCount[libName];
    if (count == null || count <= 0) return;
    final next = count - 1;
    if (next == 0) {
      _libRefCount.remove(libName);
      final lib = _libCache.remove(libName);
      // DynamicLibrary.process()/.executable() (iOS/macOS static linking) throw
      // on close(); only close a genuinely-openable library.
      if (!Platform.isIOS && !Platform.isMacOS) lib?.close();
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
    } catch (e, st) {
      if (e is HybridException) rethrow;
      // A failure in the error-check path itself (invalid get/clear stubs, a
      // malformed error struct) must not mask the call's own result, so we
      // swallow and continue — but log at verbose so it is diagnosable rather
      // than silently lost (issue #27).
      _log(NitroLogLevel.verbose, 'checkError', 'error-check path threw (ignored): $e', e, st);
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
  static void throwIfOutParamError(
    Pointer<NitroErrorFfi> errPtr, {
    void Function(Pointer<NativeType>)? nativeFree,
    String methodName = '',
  }) {
    // Cache the struct view once — each `errPtr.ref` builds a fresh Struct
    // proxy. It is a view, so writes through `err` still hit native memory.
    final err = errPtr.ref;
    if (err.hasError == 0) return;
    // The string fields were strdup'd by the C bridge, so they must be freed
    // by a C-runtime free — the module's `<lib>_nitro_free` export, passed as
    // [nativeFree] by generated code. package:ffi's malloc.free is
    // CoTaskMemFree on Windows and corrupts the heap on these pointers; it
    // remains only as a fallback for pre-nitro_free callers on POSIX.
    final free = nativeFree ?? malloc.free;
    // Copy C-owned strings into Dart before freeing native memory.
    final name = err.name != nullptr ? err.name.toDartString() : 'NativeException';
    final message = err.message != nullptr ? err.message.toDartString() : 'An unknown native exception occurred.';
    final code = err.code != nullptr ? err.code.toDartString() : null;
    final stack = err.stackTrace != nullptr ? err.stackTrace.toDartString() : null;
    // Free native-heap strings (strdup'd by the C bridge) and reset the slot.
    if (err.name != nullptr) {
      free(err.name);
      err.name = nullptr;
    }
    if (err.message != nullptr) {
      free(err.message);
      err.message = nullptr;
    }
    if (err.code != nullptr) {
      free(err.code);
      err.code = nullptr;
    }
    if (err.stackTrace != nullptr) {
      free(err.stackTrace);
      err.stackTrace = nullptr;
    }
    err.hasError = 0;
    final ex = HybridException(
      name: name,
      message: message,
      code: code,
      stackTrace: stack,
    );
    // Generated sync calls pass [methodName]: this is the `threw:` log the
    // callSync wrapper used to emit from its catch block.
    if (methodName.isNotEmpty && NitroConfig.instance.effectiveLogLevel != NitroLogLevel.none) {
      _log(NitroLogLevel.error, 'callSync($methodName)', 'threw: $ex', ex, StackTrace.current);
    }
    throw ex;
  }

  /// Checks and frees a [NitroErrorFfi] slot allocated fresh for a single
  /// call — used by `@nitroNativeAsync`, where (unlike sync's one
  /// instance-owned, isolate-serialized slot) multiple calls can be in
  /// flight concurrently on the same instance, so each call gets its own
  /// `calloc`'d struct instead of sharing one.
  ///
  /// If [errPtr.ref.hasError] is non-zero, reads the C-owned string fields,
  /// frees them, frees [errPtr] itself, and throws a [HybridException]. If
  /// there is no error, frees [errPtr] and returns normally.
  static void throwIfOutParamErrorAndFree(
    Pointer<NitroErrorFfi> errPtr, {
    void Function(Pointer<NativeType>)? nativeFree,
  }) {
    // Same allocator rule as [throwIfOutParamError]: the string fields are
    // native strdup'd, so they need the module's `<lib>_nitro_free` (passed
    // by generated code); the struct itself is Dart calloc'd, so calloc.free
    // stays correct for it on every platform.
    final free = nativeFree ?? malloc.free;
    // Cache the struct view once; it is a view, so reads through `err` see the
    // same native slot.
    final err = errPtr.ref;
    if (err.hasError == 0) {
      calloc.free(errPtr);
      return;
    }
    final name = err.name != nullptr ? err.name.toDartString() : 'NativeException';
    final message = err.message != nullptr ? err.message.toDartString() : 'An unknown native exception occurred.';
    final code = err.code != nullptr ? err.code.toDartString() : null;
    final stack = err.stackTrace != nullptr ? err.stackTrace.toDartString() : null;
    if (err.name != nullptr) free(err.name);
    if (err.message != nullptr) free(err.message);
    if (err.code != nullptr) free(err.code);
    if (err.stackTrace != nullptr) free(err.stackTrace);
    calloc.free(errPtr);
    throw HybridException(
      name: name,
      message: message,
      code: code,
      stackTrace: stack,
    );
  }

  /// Emits the verbose "completed in N µs" line plus a slow-call warning when
  /// elapsed time exceeds [NitroConfig.slowCallThresholdUs]. Extracted from the
  /// three call paths (sync / async / native-async) that shared it verbatim.
  /// Only invoked on the instrumented path ([sw] non-null), so the
  /// allocation-free hot path never pays for it.
  static void _logCallTiming(Stopwatch? sw, String tag) {
    if (sw == null) return;
    sw.stop();
    _logElapsed(sw.elapsedMicroseconds, tag);
  }

  static void _logElapsed(int us, String tag) {
    _log(NitroLogLevel.verbose, tag, 'completed in $us µs');
    final threshold = NitroConfig.instance.slowCallThresholdUs;
    if (threshold > 0 && us > threshold) {
      _log(NitroLogLevel.warning, tag, 'slow call: $us µs exceeded threshold of $threshold µs');
    }
  }

  // ── Generated sync calls: instrumentation without a closure ──────────────
  // Generated methods used to wrap their body in `callSync(() => ...)`; the
  // closure captured the arguments, so AOT allocated a context on every call
  // (~160 ns on a 20 ns leaf call). They now run the body inline between
  // [syncStart] and [syncEnd], which keep callSync's semantics — verbose
  // "calling"/"completed in" logs, timeline spans, slow-call warnings — and
  // cost one static-stopwatch read each when only the slow-call threshold is
  // active (the default), nothing when instrumentation is off.
  static final Stopwatch _clock = Stopwatch()..start();

  /// Start tick for a generated sync call, or -1 when no per-call
  /// instrumentation is on and [syncEnd] has nothing to do.
  static int syncStart(String methodName) {
    final cfg = NitroConfig.instance;
    final level = cfg.effectiveLogLevel;
    final trace = cfg.timelineTracingEnabled;
    if (level != NitroLogLevel.verbose && !trace && cfg.slowCallThresholdUs == 0) return -1;
    if (level == NitroLogLevel.verbose) _log(NitroLogLevel.verbose, 'callSync($methodName)', 'calling');
    if (trace) developer.Timeline.startSync(_timelineLabel('callSync($methodName)'));
    return _clock.elapsedMicroseconds;
  }

  /// Pairs with [syncStart]; runs from the generated `finally`, so timeline
  /// spans stay balanced when the call throws.
  static void syncEnd(int start, String methodName) {
    if (start < 0) return;
    final cfg = NitroConfig.instance;
    final us = _clock.elapsedMicroseconds - start;
    if (cfg.effectiveLogLevel == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0) _logElapsed(us, 'callSync($methodName)');
    if (cfg.timelineTracingEnabled) developer.Timeline.finishSync();
  }

  /// Legacy async dispatch: spawn a fresh isolate per call (used when the
  /// pre-warmed pool is disabled or not yet ready). Extracted so [callAsync]'s
  /// fast and slow paths share one copy — `Isolate.run`'s spawn cost dominates,
  /// so the indirection is free.
  static Future<T> _runLegacyIsolate<T>(
    Function fn,
    List<Object?> args,
    Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>>? getError,
    Pointer<NativeFunction<Void Function()>>? clearError,
  ) {
    return Isolate.run(() {
      final res = Function.apply(fn, args) as T;
      if (getError != null && clearError != null) {
        checkError(getError.asFunction(), clearError.asFunction());
      }
      return res;
    });
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

    // Hot path: no PER-CALL instrumentation is requested. Per-call work (the
    // '$tag' string allocation, the Stopwatch, the _log('calling'), the
    // timeline span) is only needed at `verbose`, with timeline tracing, or
    // when a slow-call threshold is set. At the DEFAULT `error` level — and at
    // `warning`/`none` — callSync's only job is to propagate a thrown error,
    // so skip all of it and build the tag lazily only if the call actually
    // throws. This keeps the sub-µs sync path allocation-free out of the box
    // (previously the default `error` level allocated 'callSync(<method>)' on
    // every single call for a _log that immediately no-ops).
    if (effective != NitroLogLevel.verbose &&
        !traceTimeline &&
        cfg.slowCallThresholdUs == 0) {
      if (effective == NitroLogLevel.none) return call();
      try {
        return call();
      } catch (e, st) {
        _log(
          NitroLogLevel.error,
          methodName.isEmpty ? 'callSync' : 'callSync($methodName)',
          'threw: $e',
          e,
          st,
        );
        rethrow;
      }
    }

    final tag = methodName.isEmpty ? 'callSync' : 'callSync($methodName)';
    final sw = (effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0) ? (Stopwatch()..start()) : null;

    _log(NitroLogLevel.verbose, tag, 'calling');

    if (traceTimeline) developer.Timeline.startSync(_timelineLabel(tag));
    try {
      final result = call();
      _logCallTiming(sw, tag);
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

    // Hot path: skip the Stopwatch and tag-string allocation when no per-call
    // instrumentation is requested (mirrors callSync). Only the error-level log
    // survives, its tag built lazily on throw; `dispatch` keeps the pool/legacy
    // branch from being duplicated across the none/try paths.
    if (effective != NitroLogLevel.verbose && !traceTimeline && cfg.slowCallThresholdUs == 0) {
      Future<T> dispatch() => (poolSize <= 0 || !_poolReady)
          ? _runLegacyIsolate<T>(fn, args, getError, clearError)
          : _pool!.dispatch<T>(fn, args, getError: getError, clearError: clearError);
      if (effective == NitroLogLevel.none) return await dispatch();
      try {
        return await dispatch();
      } catch (e, st) {
        _log(NitroLogLevel.error, methodName.isEmpty ? 'callAsync' : 'callAsync($methodName)', 'threw: $e', e, st);
        rethrow;
      }
    }

    // Only pay for timing when there's somewhere to send the result.
    final sw = effective != NitroLogLevel.none && (effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0) ? (Stopwatch()..start()) : null;

    final tag = methodName.isEmpty ? 'callAsync' : 'callAsync($methodName)';

    if (traceTimeline) developer.Timeline.startSync(_timelineLabel(tag));
    try {
      final T result;
      if (poolSize <= 0 || !_poolReady) {
        // Legacy: spawn a fresh isolate per call.
        _log(NitroLogLevel.verbose, tag, 'dispatching via Isolate.run');
        result = await _runLegacyIsolate<T>(fn, args, getError, clearError);
      } else {
        _log(NitroLogLevel.verbose, tag, 'dispatching via pool (size=$poolSize)');
        result = await _pool!.dispatch<T>(
          fn,
          args,
          getError: getError,
          clearError: clearError,
        );
      }

      _logCallTiming(sw, tag);

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
    void Function()? cleanup,
    String methodName = '',
    NitroCompletionBatch? batch,
  }) {
    final cfg = NitroConfig.instance;
    final effective = cfg.effectiveLogLevel;
    final traceTimeline = cfg.timelineTracingEnabled;
    final timeoutMs = cfg.nativeAsyncTimeoutMs;
    final sw = effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0 ? (Stopwatch()..start()) : null;

    String tag() => methodName.isEmpty ? 'nativeAsync' : 'nativeAsync($methodName)';

    if (effective == NitroLogLevel.verbose) _log(NitroLogLevel.verbose, tag(), 'calling');

    if (traceTimeline) developer.Timeline.startSync(_timelineLabel(tag()));

    // Generated bridges pass a per-library [batch]: the call gets an id on the
    // shared batch port instead of a port of its own, and completions that
    // land while this isolate is busy arrive together as one message.
    if (batch != null) return _openBatched<T>(batch, call, unpack, cleanup, tag, sw, effective, traceTimeline, timeoutMs);

    final port = ReceivePort();

    // Guaranteed teardown — runs exactly once when the call settles (success,
    // native error, or timeout): closes the ReceivePort and frees the per-call
    // error slot via [cleanup], so a native side that never posts a result
    // can't leak the port or the slot.
    void terminate() {
      port.close();
      cleanup?.call();
      if (traceTimeline) developer.Timeline.finishSync();
    }

    try {
      call(port.sendPort.nativePort);
    } catch (e, st) {
      terminate();
      if (effective != NitroLogLevel.none) {
        _log(NitroLogLevel.error, tag(), 'threw: $e', e, st);
      }
      rethrow;
    }

    T handle(dynamic raw) {
      // Guard so `tag()` isn't allocated on the uninstrumented hot path.
      if (sw != null) _logCallTiming(sw, tag());
      try {
        return unpack(raw);
      } catch (e, st) {
        if (effective != NitroLogLevel.none) {
          _log(NitroLogLevel.error, tag(), 'threw during unpack: $e', e, st);
        }
        rethrow;
      }
    }

    if (timeoutMs <= 0) {
      // Default: wait indefinitely for the single posted message.
      return port.first.then(handle).whenComplete(terminate);
    }

    // Opt-in timeout (NitroConfig.nativeAsyncTimeoutMs): listen manually rather
    // than via port.first so closing the port on timeout can't surface an
    // unhandled "no element" error on an abandoned future. Complete exactly
    // once — whichever of the posted message or the timer fires first.
    final completer = Completer<dynamic>();
    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException('${tag()} did not post a result within ${timeoutMs}ms', Duration(milliseconds: timeoutMs)),
        );
      }
    });
    final sub = port.listen((msg) {
      if (!completer.isCompleted) completer.complete(msg);
    });
    return completer.future.then(handle).whenComplete(() {
      timer.cancel();
      sub.cancel();
      terminate();
    });
  }

  static Future<T> _openBatched<T>(
    NitroCompletionBatch batch,
    void Function(int id) call,
    T Function(dynamic raw) unpack,
    void Function()? cleanup,
    String Function() tag,
    Stopwatch? sw,
    NitroLogLevel effective,
    bool traceTimeline,
    int timeoutMs,
  ) {
    final completer = Completer<T>();
    void terminate() {
      cleanup?.call();
      if (traceTimeline) developer.Timeline.finishSync();
    }
    final id = batch.register((dynamic raw) {
      if (completer.isCompleted) return;
      if (sw != null) _logCallTiming(sw, tag());
      _completeUnpacked(completer, unpack, raw, tag, effective);
    });
    try {
      call(id);
    } catch (e, st) {
      batch.forget(id);
      terminate();
      if (effective != NitroLogLevel.none) _log(NitroLogLevel.error, tag(), 'threw: $e', e, st);
      rethrow;
    }
    return _finish(completer, terminate, timeoutMs, () {
      batch.forget(id);
      completer.completeError(TimeoutException('${tag()} did not post a result within ${timeoutMs}ms', Duration(milliseconds: timeoutMs)));
    });
  }

  static void _completeUnpacked<T>(Completer<T> completer, T Function(dynamic raw) unpack, dynamic raw, String Function() tag, NitroLogLevel effective) {
    try {
      completer.complete(unpack(raw));
    } catch (e, st) {
      if (effective != NitroLogLevel.none) _log(NitroLogLevel.error, tag(), 'threw during unpack: $e', e, st);
      completer.completeError(e, st);
    }
  }

  /// The call's future with [terminate] run at the end and, for a positive
  /// [timeoutMs], [onTimeout] fired if nothing completed it by then.
  static Future<T> _finish<T>(Completer<T> completer, void Function() terminate, int timeoutMs, void Function() onTimeout) {
    if (timeoutMs <= 0) return completer.future.whenComplete(terminate);
    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      if (!completer.isCompleted) onTimeout();
    });
    return completer.future.whenComplete(() {
      timer.cancel();
      terminate();
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

    /// Coalesced streams (`Backpressure.batch` on an all-C++ spec): called
    /// after every delivered message so the bridge flushes what accumulated
    /// meanwhile, or goes idle.
    void Function(int dartPort)? ack,

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
      if (!released) ack?.call(nativePort);
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
