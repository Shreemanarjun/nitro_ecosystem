import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'annotations.dart';

/// The runtime is called only by generated code.
/// Plugin authors and app developers never call it directly.
class NitroRuntime {
  static final Map<String, DynamicLibrary> _libCache = {};

  static DynamicLibrary loadLib(String libName) {
    if (_libCache.containsKey(libName)) return _libCache[libName]!;

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
    return lib;
  }

  /// Calls a native function synchronously.
  static T callSync<T>(Function fn, List<Object?> args) {
    return Function.apply(fn, args) as T;
  }

  /// Calls a native function on a background isolate.
  static Future<T> callAsync<T>(Function fn, List<Object?> args) async {
    // Isolate.run is available in Dart 2.19+ and is very efficient.
    // Native function pointers (from lookupFunction) are sendable.
    return Isolate.run(() {
      return Function.apply(fn, args) as T;
    });
  }

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
  }) {
    final receivePort = ReceivePort();
    final nativePort = receivePort.sendPort.nativePort;
    var released = false;

    // Idempotent release — safe to call from either onCancel or the finalizer.
    void doRelease() {
      if (released) return;
      released = true;
      release(nativePort);
      receivePort.close();
    }

    final controller = StreamController<T>(
      onListen: () => register(nativePort),
      onCancel: doRelease,
    );

    // Safety net: if the StreamController is GC'd without cancel() being called
    // (abandoned subscription, hot-restart mid-listen), doRelease still fires
    // so the native emitter stops and the ReceivePort is freed.
    _streamFinalizer.attach(controller, doRelease, detach: controller);

    receivePort.listen((dynamic message) {
      if (controller.isClosed) return;
      try {
        controller.add(unpack(message));
      } catch (e) {
        controller.addError(e);
      }
    });

    return controller.stream;
  }

  // Finalizer for StreamControllers abandoned without cancel().
  // Token is a void Function() closure — no strong ref back to the controller.
  static final _streamFinalizer = Finalizer<void Function()>(
    (doRelease) => doRelease(),
  );

  static Future<void> init({int minIsolates = 1}) async {
    // Pre-warm isolate pool if needed
  }

  static Future<void> dispose() async {
    _libCache.clear();
  }
}
