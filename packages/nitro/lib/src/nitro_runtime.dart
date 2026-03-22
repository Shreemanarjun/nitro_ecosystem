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
  /// Uses a ReceivePort for direct native-to-dart bit posting.
  static Stream<T> openStream<T>({
    required void Function(int dartPort) register,
    required T Function(dynamic message) unpack,
    required void Function(int dartPort) release,
    required Backpressure backpressure,
  }) {
    final receivePort = ReceivePort();
    final controller = StreamController<T>(
      onListen: () {
        register(receivePort.sendPort.nativePort);
      },
      onCancel: () {
        release(receivePort.sendPort.nativePort);
        receivePort.close();
      },
    );

    receivePort.listen((dynamic message) {
      if (controller.isClosed) return;
      try {
        final item = unpack(message);
        controller.add(item);
      } catch (e) {
        controller.addError(e);
      }
    });

    return controller.stream;
  }

  static Future<void> init({int minIsolates = 1}) async {
    // Pre-warm isolate pool if needed
  }

  static Future<void> dispose() async {
    _libCache.clear();
  }
}
