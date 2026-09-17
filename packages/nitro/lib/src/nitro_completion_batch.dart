import 'dart:ffi';
import 'dart:isolate';

/// Shared-port demux for one library's `@nitroNativeAsync` completions.
///
/// Every message a Dart isolate receives costs one embedder task (~10 µs in a
/// Flutter build), whichever port it targets. The C++ side
/// (nitro_completion_batch.h) therefore delivers completions to this one port
/// as `[id, value, id, value, ...]` and holds any that arrive before [ack] so
/// they travel as one message. A lone completion still goes out at once.
class NitroCompletionBatch {
  NitroCompletionBatch({required this.bind, required this.ack}) {
    _port = RawReceivePort(_onBatch)..keepIsolateAlive = false;
  }

  /// `<lib>_nitro_bind(batchPort) → id`, reserved per call.
  final int Function(int batchPort) bind;

  /// `<lib>_nitro_ack(batchPort)`, sent after every handled batch.
  final void Function(int batchPort) ack;

  late final RawReceivePort _port;
  final Map<int, void Function(dynamic raw)> _pending = {};

  int get nativePort => _port.sendPort.nativePort;

  /// The batch port as a [SendPort] (tests feed it without native code).
  SendPort get sendPort => _port.sendPort;

  /// Reserves an id for one call; the native side posts its result to it.
  /// [onComplete] must not throw.
  int register(void Function(dynamic raw) onComplete) {
    final id = bind(nativePort);
    _pending[id] = onComplete;
    return id;
  }

  /// Drops a call (timeout); a late completion is ignored on arrival.
  void forget(int id) => _pending.remove(id);

  int get pendingCount => _pending.length;

  void _onBatch(dynamic msg) {
    final batch = msg as List<dynamic>;
    for (var i = 0; i + 1 < batch.length; i += 2) {
      _pending.remove(batch[i] as int)?.call(batch[i + 1]);
    }
    ack(nativePort);
  }
}
