class NitroModule {
  final NativeImpl ios;           // which language implements on iOS
  final NativeImpl android;       // which language implements on Android
  final String?    cSymbolPrefix; // override C prefix (default: snake_case classname)
  final String?    lib;           // override .so/.dylib name (default: lib{classname})

  const NitroModule({
    required this.ios,
    required this.android,
    this.cSymbolPrefix,
    this.lib,
  });
}

enum NativeImpl {
  swift,    // iOS: Swift + @_cdecl C bridge
  kotlin,   // Android: Kotlin + JNI bridge
  cpp,      // Both: shared C++ (advanced)
}

class HybridStruct {
  // Fields named here are Uint8List delivered as zero-copy raw pointer.
  // A Finalizer calls the native unlock symbol when the Dart object is GC'd.
  final List<String> zeroCopy;
  final bool packed;  // no C struct padding, default false

  const HybridStruct({this.zeroCopy = const [], this.packed = false});
}

class HybridEnum {
  final int startValue;  // first case value, default 0
  const HybridEnum({this.startValue = 0});
}

// Makes a method async. Return type must be Future<T>.
// Dispatched on NitroRuntime's background isolate pool.
const nitroAsync = NitroAsync();
class NitroAsync { const NitroAsync(); }

// Makes a getter a native stream via SendPort dispatch.
// Only valid on abstract getters returning Stream<T>.
class NitroStream {
  final Backpressure backpressure;
  const NitroStream({this.backpressure = Backpressure.dropLatest});
}

// Marks a Uint8List param as zero-copy (passed as raw ptr, callee must not retain).
const zeroCopy = ZeroCopy();
class ZeroCopy { const ZeroCopy(); }

enum Backpressure {
  dropLatest,   // best for sensors/camera: stale frames are useless
  block,        // block native thread until Dart consumes
  bufferDrop,   // ring buffer; oldest item dropped when full
}
