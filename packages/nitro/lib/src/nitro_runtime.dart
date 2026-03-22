import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
  /// (Mostly used as a marker for generated code, as ffi calls are direct).
  static T callSync<T>(Function fn, List<Object?> args) {
    return Function.apply(fn, args) as T;
  }

  /// Calls a native function on a background isolate.
  static Future<T> callAsync<T>(Function fn, List<Object?> args) async {
    // We use compute or Isolate.run to execute on a background thread.
    // Note: FFI pointers can't be sent across isolates easily if they refer to 
    // memory allocated in the source isolate. But function pointers are usually fine 
    // if the library is loaded in both or via DynamicLibrary.process().
    // However, since we are using FFI, we usually just call it.
    
    return compute((params) {
      final func = params[0] as Function;
      final argList = params[1] as List<Object?>;
      return Function.apply(func, argList) as T;
    }, [fn, args]);
  }

  static Stream<T> openStream<T>({
    required void Function(int dartPort) register,
    required T Function(int rawPtr) unpack,
    required void Function(int rawPtr) release,
    required Backpressure backpressure,
  }) {
    // Basic implementation using ReceivePort
    final controller = StreamController<T>();
    // TODO: Implement native callback registration via SendPort
    return controller.stream;
  }

  static Future<void> init({int minIsolates = 1}) async {
    // Pre-warm isolate pool if needed
  }

  static Future<void> dispose() async {
    _libCache.clear();
  }
}
