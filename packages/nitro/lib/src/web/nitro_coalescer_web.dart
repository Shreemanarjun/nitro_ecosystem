import 'dart:async';

import 'port_registry.dart';

/// Web twin of `NitroCoalescer` — demultiplexer for **coalesced**
/// `@nitroNativeAsync` completions, backed by a [WebReceivePort] instead of a
/// `ReceivePort`.
///
/// The batch wire format is identical: the WASM side posts one int64 array of
/// `[callId0, value0, …]` (post tag 4) over a single shared port. Scalar
/// (`int`) results only.
class NitroCoalescer {
  NitroCoalescer() {
    _sub = _port.listen(_onBatch);
  }

  final WebReceivePort _port = WebReceivePort();
  final Map<int, Completer<int>> _pending = {};
  late final StreamSubscription<dynamic> _sub;
  int _nextId = 0;
  bool _disposed = false;

  /// The port id to hand to the WASM submit call so its coalescer can address
  /// this demuxer.
  int get nativePort => _port.sendPort.nativePort;

  /// The [WebSendPort] batches are posted to. Most callers only need
  /// [nativePort]; exposed for advanced use and testing (inject a batch
  /// `[callId0, value0, …]` directly).
  WebSendPort get sendPort => _port.sendPort;

  /// Number of calls still awaiting a result.
  int get pendingCount => _pending.length;

  /// Registers a pending call, invokes [call] with the freshly-assigned id and
  /// [nativePort], and returns the future that completes when the batch
  /// carrying this id arrives. Throws a [StateError] if called after
  /// [dispose] — the port is closed, so the result could never arrive.
  Future<int> submit(void Function(int callId, int nativePort) call) {
    if (_disposed) {
      throw StateError('NitroCoalescer.submit() called after dispose()');
    }
    final id = _nextId++;
    final completer = Completer<int>();
    _pending[id] = completer;
    call(id, nativePort);
    return completer.future;
  }

  void _onBatch(dynamic msg) {
    // Batch wire: [callId0, value0, callId1, value1, ...] (int64 pairs).
    // A trailing unpaired element is ignored rather than throwing.
    final list = msg as List;
    for (var i = 0; i + 1 < list.length; i += 2) {
      _pending.remove((list[i] as num).toInt())?.complete((list[i + 1] as num).toInt());
    }
  }

  /// Closes the shared port and settles every pending call. Drains up to
  /// [drainTurns] event-loop turns first so already-posted results complete
  /// normally; whatever remains is completed with a [StateError]. Idempotent.
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
