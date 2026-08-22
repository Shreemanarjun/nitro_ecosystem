/// Web implementation of NitroRuntime.
///
/// Mirrors the native `nitro_runtime.dart` API over an Emscripten-compiled
/// WASM module: `DynamicLibrary` becomes an async-loaded [NitroWasmModule],
/// `SendPort.nativePort` becomes a [NitroWebPorts] id delivered through a
/// function-table callback, and `@nitroAsync` runs inline (the web has no
/// isolates). Works under both dart2js and dart2wasm.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../annotations.dart';
import '../nitro_config.dart';
import '../shared/nitro_bytes.dart';
import 'nitro_error_web.dart';
import 'nitro_wasm_module.dart';
import 'port_registry.dart';

export '../nitro_config.dart';

// ── Internal logger helper (mirrors the native runtime) ───────────────────────

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
  if (level.index > effective.index) return;
  cfg.logHandler(level, tag, message, error, stack);
}

/// Computes the Emscripten `EXPORT_NAME` factory for a nitro lib name:
/// `benchmark_cpp` → `createBenchmarkCppModule`. The CMake emitter uses the
/// same convention — keep the two in sync.
String nitroWebExportName(String libName) {
  final pascal = libName.split(RegExp(r'[_\-]+')).where((p) => p.isNotEmpty).map((p) => p[0].toUpperCase() + p.substring(1)).join();
  return 'create${pascal}Module';
}

// ── NitroRuntime (web) ─────────────────────────────────────────────────────────

/// The runtime is called only by generated code.
/// Plugin authors and app developers interact with [NitroConfig] instead.
class NitroRuntime {
  static const int expectedAbiVersion = 1;

  /// Web never uses `@Native<F>` direct dispatch.
  static const bool useNativeBindings = false;

  static final Map<String, NitroWasmModule> _moduleCache = {};
  static final Map<String, Future<NitroWasmModule>> _loading = {};
  static final Map<String, int> _libRefCount = {};

  static String _timelineLabel(String tag) => 'Nitro.$tag';

  // ── Module loading ─────────────────────────────────────────────────────────

  /// Loads the Emscripten glue script for [libName] and instantiates its
  /// module. Idempotent: concurrent and repeated calls share one load.
  ///
  /// [jsUrl] is the URL of the MODULARIZE glue `.js` (the `.wasm` is fetched
  /// relative to it). Defaults to the Flutter asset path
  /// `assets/packages/<package>/assets/web/<libName>.js` when [assetPackage]
  /// is given, else `assets/web/<libName>.js` relative to the page.
  static Future<NitroWasmModule> loadWebModule(
    String libName, {
    String? jsUrl,
    String? assetPackage,
  }) {
    final cached = _moduleCache[libName];
    if (cached != null) {
      _libRefCount[libName] = (_libRefCount[libName] ?? 0) + 1;
      return Future.value(cached);
    }
    return _loading.putIfAbsent(libName, () async {
      final url = jsUrl ?? (assetPackage != null ? 'assets/packages/$assetPackage/assets/web/$libName.js' : 'assets/web/$libName.js');
      _log(NitroLogLevel.verbose, 'loadWebModule', 'Loading WASM module: $libName from $url');
      final sw = Stopwatch()..start();

      await _injectScript(url, libName);

      final factoryName = nitroWebExportName(libName);
      final factory = globalContext.getProperty(factoryName.toJS);
      if (factory == null || !factory.typeofEquals('function')) {
        throw StateError(
          '$libName: $url loaded but did not define $factoryName(). Build the '
          'module with -sMODULARIZE=1 -sEXPORT_NAME=$factoryName '
          '(web/build_web.sh does this).',
        );
      }
      final promise = (factory as JSFunction).callAsFunction(null, JSObject())! as JSPromise;
      final raw = await promise.toDart;
      final module = NitroWasmModule(libName, EmscriptenModule(raw! as JSObject));

      _registerPostFn(module);

      sw.stop();
      _log(NitroLogLevel.verbose, 'loadWebModule', 'Loaded: $libName in ${sw.elapsedMicroseconds} µs');
      _moduleCache[libName] = module;
      _libRefCount[libName] = (_libRefCount[libName] ?? 0) + 1;
      _loading.remove(libName);
      return module;
    });
  }

  /// Returns the loaded module for [libName], or throws with the fix.
  static NitroWasmModule webModule(String libName) {
    final module = _moduleCache[libName];
    if (module == null) {
      throw StateError(
        '$libName: WASM module not loaded yet. On web, await the generated '
        "ensure<Class>Ready() (or NitroRuntime.loadWebModule('$libName', ...)) "
        'before constructing the bridge — module instantiation is asynchronous '
        'in the browser.',
      );
    }
    return module;
  }

  /// Takes a reference to an already-loaded [libName], balancing the
  /// [releaseLib] a generated bridge performs in `dispose()`.
  ///
  /// Native takes one lib reference per hybrid instance (`loadLib` in the FFI
  /// impl's constructor). On web the module is loaded once by
  /// `ensure<Class>Ready()`, so without this every instance disposed would
  /// decrement a count nobody incremented — the first `dispose()` dropped the
  /// count to zero and evicted the module, and every later call in the program
  /// failed with "WASM module not loaded yet".
  ///
  /// A no-op when the module is not loaded: the bridge constructor throws on
  /// its own with a better message.
  static void retainLib(String libName) {
    if (!_moduleCache.containsKey(libName)) return;
    _libRefCount[libName] = (_libRefCount[libName] ?? 0) + 1;
  }

  /// Decrements the reference count for [libName]; drops the cached module at
  /// zero. The browser has no dlclose — dropping references lets the JS GC
  /// collect the instance once generated bridges release theirs.
  static void releaseLib(String libName) {
    final count = _libRefCount[libName];
    if (count == null || count <= 0) return;
    final next = count - 1;
    if (next == 0) {
      _libRefCount.remove(libName);
      _moduleCache.remove(libName);
      _log(NitroLogLevel.verbose, 'releaseLib', 'Released WASM module: $libName');
    } else {
      _libRefCount[libName] = next;
    }
  }

  /// Native-only entry point. On web, module loading is asynchronous — see
  /// [loadWebModule] / the generated `ensure<Class>Ready()`.
  static Never loadLib(String libName) {
    throw UnsupportedError(
      '$libName: NitroRuntime.loadLib is native-only. On web, await the '
      "generated ensure<Class>Ready() (or NitroRuntime.loadWebModule) first — "
      'the FFI implementation class does not exist in a web build.',
    );
  }

  static Never loadLibForTargets(
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
    loadLib(libName);
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
    if (web) return;
    final targets = <String>[
      if (ios) 'iOS',
      if (android) 'Android',
      if (macos) 'macOS',
      if (windows) 'Windows',
      if (linux) 'Linux',
    ].join(', ');
    throw UnsupportedError(
      '$libName: this generated Nitro module does not target Web. Targeted '
      'platforms: ${targets.isEmpty ? 'none' : targets}. Add '
      '`web: NativeImpl.wasm` to @NitroModule, regenerate with '
      '`nitrogen generate`, run `nitrogen link`, and rebuild the app.',
    );
  }

  static void checkAbiVersion(String libName, int Function() readVersion) {
    late final int actual;
    try {
      actual = readVersion();
    } catch (error) {
      throw StateError(
        '$libName: Nitro ABI version check failed. Run `nitrogen generate` '
        'and `nitrogen link`, then rebuild the WASM module '
        '(web/build_web.sh). Details: $error',
      );
    }
    if (actual != expectedAbiVersion) {
      throw StateError(
        '$libName: Nitro ABI version mismatch. Dart runtime expects '
        '$expectedAbiVersion but the WASM bridge reports $actual. Run '
        '`nitrogen generate`, rebuild the WASM module, and rebuild the app.',
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
        'and rebuild the WASM module (web/build_web.sh) so the generated Dart '
        'and WASM bridge come from the same generation. Details: $error',
      );
    }
    if (actual != expectedChecksum) {
      throw StateError(
        '$libName: Nitro bridge checksum mismatch. Dart expects '
        '$expectedChecksum but the WASM bridge reports $actual. Run '
        '`nitrogen generate`, rebuild the WASM module (web/build_web.sh), and '
        'hot-restart the app.',
      );
    }
  }

  // ── Script injection + post-callback wiring ───────────────────────────────

  static Future<void> _injectScript(String url, String libName) {
    final document = globalContext.getProperty('document'.toJS);
    if (document == null) {
      throw StateError(
        '$libName: no `document` in this JS environment — Nitro web modules '
        'load via a <script> tag and require a browser context.',
      );
    }
    final doc = document as JSObject;
    final script = doc.callMethod('createElement'.toJS, 'script'.toJS)! as JSObject;
    script.setProperty('src'.toJS, url.toJS);
    final completer = Completer<void>();
    script.callMethod(
      'addEventListener'.toJS,
      'load'.toJS,
      ((JSAny? _) => completer.complete()).toJS,
    );
    script.callMethod(
      'addEventListener'.toJS,
      'error'.toJS,
      ((JSAny? _) => completer.completeError(
            StateError('$libName: failed to load $url — is the .js/.wasm asset bundled? (flutter: assets: [assets/web/])'),
          )).toJS,
    );
    final head = doc.getProperty('head'.toJS)! as JSObject;
    head.callMethod('appendChild'.toJS, script);
    return completer.future;
  }

  /// Registers the module's post callback — the web replacement for
  /// `Dart_PostCObject_DL`. Tags mirror the Dart_CObject subset the bridges
  /// post: 0=null, 1=int64, 2=double, 3=borrowed C string, 4=borrowed int64
  /// array. Borrowed payloads (3, 4) are decoded synchronously — the C caller
  /// may free them when the post returns — and delivery is deferred one
  /// microtask so completions never run while the wasm call is on the stack.
  static void _registerPostFn(NitroWasmModule module) {
    final setter = '${module.libName}_nitro_set_post_fn';
    if (!module.providesSymbol(setter)) {
      _log(
        NitroLogLevel.warning,
        'loadWebModule',
        '${module.libName}: WASM module lacks $setter — async/stream posts '
            'will not be delivered. Rebuild the module from bridges generated '
            'with nitro_generator >= 0.7.0.',
      );
      return;
    }
    void onPost(JSAny? port, JSAny? tag, JSAny? a, JSAny? b, JSAny? d) {
      final portId = dartI64(port);
      final t = (tag! as JSNumber).toDartInt;
      final dynamic raw;
      switch (t) {
        case 0:
          raw = null;
        case 1:
          raw = dartI64(a);
        case 2:
          raw = (d! as JSNumber).toDartDouble;
        case 3:
          raw = module.readCString(dartI64(a));
        case 4:
          final base = dartI64(a);
          final count = dartI64(b);
          final bytes = module.readBytes(base, count * 8);
          final bd = ByteData.sublistView(bytes);
          raw = List<int>.generate(count, (i) => getInt64LE(bd, i * 8), growable: false);
        case 5:
          // String array (string-batch streams): a = char** (wasm32 u32
          // slots), b = count. Borrowed — decode every element now.
          final base = dartI64(a);
          final count = dartI64(b);
          final slots = module.readBytes(base, count * 4);
          final sbd = ByteData.sublistView(slots);
          raw = List<String>.generate(
            count,
            (i) => module.readCString(sbd.getUint32(i * 4, Endian.little)),
            growable: false,
          );
        case 6:
          // Byte buffer (record/variant batch streams): a = data, b = bytes.
          raw = module.readBytes(dartI64(a), dartI64(b));
        default:
          _log(NitroLogLevel.error, 'nitroPost', '${module.libName}: unknown post tag $t (port $portId) — dropped');
          return;
      }
      scheduleMicrotask(() => NitroWebPorts.deliver(portId, raw));
    }

    final fnPtr = module.addFunction(onPost.toJS, 'vjijjd');
    module.call(setter, [fnPtr.toJS]);
  }

  // ── Lifecycle logging ──────────────────────────────────────────────────────

  /// Logs a lifecycle event (init, dispose) for a module.
  static void logLifecycle(String tag, String message) {
    _log(NitroLogLevel.verbose, tag, message);
  }

  // ── Error handling ─────────────────────────────────────────────────────────

  /// Checks the legacy two-call error protocol. On web the generated bridge
  /// passes Dart closures over the module exports.
  static void checkError(
    dynamic Function() get,
    void Function() clear,
  ) {
    try {
      final err = get();
      if (err is Exception) {
        clear();
        throw err;
      }
    } catch (e, st) {
      if (e is Exception) rethrow;
      _log(NitroLogLevel.verbose, 'checkError', 'error-check path threw (ignored): $e', e, st);
    }
  }

  /// Checks an S8-style out-parameter error slot after a sync bridge call —
  /// the web counterpart of the native `throwIfOutParamError(Pointer<...>)`.
  /// Reads the slot from module memory; if an error is present, frees the
  /// strdup'd fields with the module's `nitro_free`, resets the slot, and
  /// throws a `HybridException`.
  static void throwIfOutParamError(WebNitroErrorSlot slot) => slot.throwIfError();

  /// Checks and frees a per-call error slot (`@nitroNativeAsync`) — the web
  /// counterpart of the native `throwIfOutParamErrorAndFree`.
  static void throwIfOutParamErrorAndFree(WebNitroErrorSlot slot) => slot.throwIfErrorAndFree();

  /// Emits the verbose "completed in N µs" line plus a slow-call warning when
  /// elapsed time exceeds [NitroConfig.slowCallThresholdUs].
  static void _logCallTiming(Stopwatch? sw, String tag) {
    if (sw == null) return;
    sw.stop();
    final us = sw.elapsedMicroseconds;
    _log(NitroLogLevel.verbose, tag, 'completed in $us µs');
    final threshold = NitroConfig.instance.slowCallThresholdUs;
    if (threshold > 0 && us > threshold) {
      _log(NitroLogLevel.warning, tag, 'slow call: $us µs exceeded threshold of $threshold µs');
    }
  }

  // ── Synchronous call ───────────────────────────────────────────────────────

  /// Calls a bridge function synchronously, with the same logging and
  /// slow-call detection as the native runtime.
  static T callSync<T>(T Function() call, {String methodName = ''}) {
    final cfg = NitroConfig.instance;
    final effective = cfg.effectiveLogLevel;
    final traceTimeline = cfg.timelineTracingEnabled;

    if (effective != NitroLogLevel.verbose && !traceTimeline && cfg.slowCallThresholdUs == 0) {
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

  // ── Callback lifecycle ─────────────────────────────────────────────────────

  /// Web analog of the native deferred `NativeCallable.close`: releases a
  /// replaced callback's function-table slot on the next microtask, after the
  /// bridge call that switched native over to the new slot has returned.
  static void deferredCloseWebFunction(NitroWasmModule module, int? oldFnPtr) {
    if (oldFnPtr == null || oldFnPtr == 0) return;
    scheduleMicrotask(() => module.removeFunction(oldFnPtr));
  }

  /// API-parity shim for the native `deferredClose(NativeCallable?)` — the
  /// web bridge uses [deferredCloseWebFunction] instead.
  static void deferredClose(Object? old) {}

  // ── Async call (inline on web) ─────────────────────────────────────────────

  /// `@nitroAsync` on web: there are no isolates, so [fn] runs on the main
  /// thread after a single event-loop hop. Long-running native work will jank
  /// the UI — prefer `@nitroNativeAsync` for genuinely asynchronous impls.
  static Future<T> callAsync<T>(
    Function fn,
    List<Object?> args, {
    Object? getError,
    Object? clearError,
    String methodName = '',
  }) async {
    final cfg = NitroConfig.instance;
    final effective = cfg.effectiveLogLevel;
    final traceTimeline = cfg.timelineTracingEnabled;

    Future<T> dispatch() => Future<T>(() => Function.apply(fn, args) as T);

    if (effective != NitroLogLevel.verbose && !traceTimeline && cfg.slowCallThresholdUs == 0) {
      if (effective == NitroLogLevel.none) return await dispatch();
      try {
        return await dispatch();
      } catch (e, st) {
        _log(NitroLogLevel.error, methodName.isEmpty ? 'callAsync' : 'callAsync($methodName)', 'threw: $e', e, st);
        rethrow;
      }
    }

    final sw = effective != NitroLogLevel.none && (effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0) ? (Stopwatch()..start()) : null;
    final tag = methodName.isEmpty ? 'callAsync' : 'callAsync($methodName)';

    if (traceTimeline) developer.Timeline.startSync(_timelineLabel(tag));
    try {
      _log(NitroLogLevel.verbose, tag, 'dispatching inline (web has no isolates)');
      final result = await dispatch();
      _logCallTiming(sw, tag);
      return result;
    } finally {
      if (traceTimeline) developer.Timeline.finishSync();
    }
  }

  // ── Native-async (zero-hop) ────────────────────────────────────────────────

  /// Opens a single-use [WebReceivePort], hands its port id to [call] so the
  /// WASM implementation can post the result through the module post
  /// callback, then waits for exactly one message and converts it with
  /// [unpack]. Mirrors the native contract, including
  /// [NitroConfig.nativeAsyncTimeoutMs].
  static Future<T> openNativeAsync<T>({
    required void Function(int dartPort) call,
    required T Function(dynamic raw) unpack,
    void Function()? cleanup,
    String methodName = '',
  }) {
    final cfg = NitroConfig.instance;
    final effective = cfg.effectiveLogLevel;
    final traceTimeline = cfg.timelineTracingEnabled;
    final timeoutMs = cfg.nativeAsyncTimeoutMs;
    final sw = effective == NitroLogLevel.verbose || cfg.slowCallThresholdUs > 0 ? (Stopwatch()..start()) : null;

    String tag() => methodName.isEmpty ? 'nativeAsync' : 'nativeAsync($methodName)';

    if (effective == NitroLogLevel.verbose) _log(NitroLogLevel.verbose, tag(), 'calling');

    final port = WebReceivePort();
    if (traceTimeline) developer.Timeline.startSync(_timelineLabel(tag()));

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
      return port.first.then(handle).whenComplete(terminate);
    }

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

  // ── Stream ─────────────────────────────────────────────────────────────────

  /// Opens a stream from a WASM event source over a [WebReceivePort],
  /// mirroring the native lifecycle (explicit cancel, GC finalizer safety
  /// net; hot restart tears down the JS context wholesale).
  static Stream<T> openStream<T>({
    required void Function(int dartPort) register,
    required T Function(dynamic message) unpack,
    required void Function(int dartPort) release,
    required Backpressure backpressure,
    String? debugLabel,
    @visibleForTesting WebReceivePort? testPort,
  }) {
    final label = debugLabel ?? 'Stream<$T>';
    final receivePort = testPort ?? WebReceivePort();
    final nativePort = receivePort.sendPort.nativePort;
    var released = false;
    var eventCount = 0;

    _log(NitroLogLevel.verbose, label, 'opening (port=$nativePort)');

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
  static final _streamFinalizer = Finalizer<void Function()>(
    (doRelease) => doRelease(),
  );

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Initialises the runtime. On web there is no isolate pool to warm — this
  /// exists for API parity so `main()` code runs unchanged.
  static Future<void> init({int? isolatePoolSize}) async {
    final cfg = NitroConfig.instance;
    if (isolatePoolSize != null) cfg.isolatePoolSize = isolatePoolSize;
    _log(NitroLogLevel.verbose, 'init', 'web runtime ready (no isolate pool on web)');
  }

  /// Tears down the runtime: clears the module cache. After calling this,
  /// modules must be loaded again before use.
  static Future<void> dispose() async {
    _moduleCache.clear();
    _libRefCount.clear();
    _log(NitroLogLevel.verbose, 'dispose', 'done');
  }

}
