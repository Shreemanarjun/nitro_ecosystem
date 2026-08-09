import 'dart:async';
import 'dart:ffi'; // SendPort.nativePort
import 'dart:isolate';

/// Demultiplexer for **coalesced** `@nitroNativeAsync` completions.
///
/// Opt-in batching for the case where many native-async calls are in-flight and
/// finish together: the native side posts one `kArray` of
/// `[callId0, value0, …]` over a single shared port instead of one post per
/// call, so the whole burst shares one isolate wake. This class owns that port
/// and resolves each pending call by its id. Scalar (`int`) results only.
///
/// The per-call [ReceivePort] path (`openNativeAsync`) stays the default — it is
/// right for a single call. See issue #39.
class NitroCoalescer {
  NitroCoalescer() {
    _sub = _port.listen(_onBatch);
  }

  final ReceivePort _port = ReceivePort();
  final Map<int, Completer<int>> _pending = {};
  late final StreamSubscription<dynamic> _sub;
  int _nextId = 0;

  /// The native port id to hand to the native submit call so its coalescer can
  /// address this demuxer.
  int get nativePort => _port.sendPort.nativePort;

  /// The [SendPort] the native coalescer posts batches to. Most callers only
  /// need [nativePort]; exposed for advanced use and testing (inject a batch
  /// `[callId0, value0, …]` directly).
  SendPort get sendPort => _port.sendPort;

  /// Number of calls still awaiting a result.
  int get pendingCount => _pending.length;

  /// Registers a pending call, invokes [call] with the freshly-assigned id and
  /// [nativePort] (which the native submit forwards to its coalescer), and
  /// returns the future that completes when the batch carrying this id arrives.
  Future<int> submit(void Function(int callId, int nativePort) call) {
    final id = _nextId++;
    final completer = Completer<int>();
    _pending[id] = completer;
    call(id, nativePort);
    return completer.future;
  }

  void _onBatch(dynamic msg) {
    // Batch wire: [callId0, value0, callId1, value1, ...] (int64 pairs).
    final list = msg as List;
    for (var i = 0; i + 1 < list.length; i += 2) {
      _pending.remove(list[i] as int)?.complete(list[i + 1] as int);
    }
  }

  /// Closes the shared port and drops any still-pending calls. The native side
  /// must be stopped first — a post to the closed port is dropped, so any call
  /// whose result is still in flight will never complete.
  Future<void> dispose() async {
    await _sub.cancel();
    _port.close();
    _pending.clear();
  }
}
