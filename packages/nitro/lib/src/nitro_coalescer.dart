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
  bool _disposed = false;

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
  /// Throws a [StateError] if called after [dispose] — the port is closed, so
  /// the result could never arrive and the future would hang forever.
  Future<int> submit(void Function(int callId, int nativePort) call) {
    if (_disposed) {
      throw StateError('NitroCoalescer.submit() called after dispose()');
    }
    final id = _nextId++;
    final completer = Completer<int>();
    _pending[id] = completer;
    try {
      call(id, nativePort);
    } catch (_) {
      // The native call never reached the other side, so no batch will ever
      // carry this id — drop the slot instead of leaving a future that can
      // only resolve at dispose().
      _pending.remove(id);
      rethrow;
    }
    return completer.future;
  }

  void _onBatch(dynamic msg) {
    // Batch wire: [callId0, value0, callId1, value1, ...] (int64 pairs).
    // A trailing unpaired element is ignored rather than throwing: the loop
    // bound already stops before it, so a malformed batch cannot desync the
    // pairing of the entries that are well-formed.
    final list = msg as List;
    for (var i = 0; i + 1 < list.length; i += 2) {
      _pending.remove(list[i] as int)?.complete(list[i + 1] as int);
    }
  }

  /// Closes the shared port and settles every pending call.
  ///
  /// A native post only *enqueues* on the port; delivery needs an event-loop
  /// turn. Since `dispose()` is normally called synchronously from a client's
  /// own `dispose()`, results that native already produced are typically still
  /// queued at this point. So this first yields — up to [drainTurns] turns,
  /// stopping as soon as nothing is pending — letting those arrive and complete
  /// normally. Stopping the native side first is still worth doing, but it is
  /// not sufficient on its own: the delay is on the Dart delivery side.
  ///
  /// Whatever remains after draining is genuinely unrecoverable and is
  /// completed with a [StateError]. A pending future is never simply dropped —
  /// that turns a lost result into a future that hangs forever.
  /// Idempotent — a second call is a no-op.
  Future<void> dispose({int drainTurns = 8}) async {
    if (_disposed) return;
    _disposed = true;
    for (var i = 0; i < drainTurns && _pending.isNotEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await _sub.cancel();
    _port.close();
    final abandoned = _pending.values.toList();
    _pending.clear();
    for (final completer in abandoned) {
      if (!completer.isCompleted) {
        completer.completeError(
          StateError('NitroCoalescer was disposed before this call completed'),
        );
      }
    }
  }
}
