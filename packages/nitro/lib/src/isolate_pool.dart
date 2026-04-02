import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'hybrid_exception.dart';
import 'nitro_runtime.dart';

// ── Wire messages ─────────────────────────────────────────────────────────────

class _CallRequest {
  final int callId;
  final Function fn;
  final List<Object?> args;
  final Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>>? getError;
  final Pointer<NativeFunction<Void Function()>>? clearError;
  const _CallRequest(this.callId, this.fn, this.args, {this.getError, this.clearError});
}

class _CallResponse {
  final int callId;
  final Object? result;
  final Object? error;
  final StackTrace? stack;
  const _CallResponse({required this.callId, this.result, this.error, this.stack});
}

// ── Worker init bundle ────────────────────────────────────────────────────────

/// Passed as the single spawn argument so the worker gets both ports in one
/// message, avoiding a second round-trip during the handshake.
class _WorkerInit {
  final SendPort handshake; // used once to return the worker's inbox SendPort
  final SendPort poolReply; // the pool-level persistent reply port
  const _WorkerInit(this.handshake, this.poolReply);
}

// ── Worker isolate entry point ────────────────────────────────────────────────

void _workerMain(_WorkerInit init) {
  final inbox = ReceivePort();
  init.handshake.send(inbox.sendPort); // handshake complete

  inbox.listen((dynamic msg) {
    if (msg == null) {
      // Graceful shutdown signal sent by IsolatePool.dispose().
      inbox.close();
      return;
    }
    if (msg is _CallRequest) {
      try {
        final result = Function.apply(msg.fn, msg.args);
        if (msg.getError != null && msg.clearError != null) {
          NitroRuntime.checkError(
            msg.getError!.asFunction(),
            msg.clearError!.asFunction(),
          );
        }
        init.poolReply.send(_CallResponse(callId: msg.callId, result: result));
      } catch (e, st) {
        init.poolReply.send(_CallResponse(callId: msg.callId, error: e, stack: st));
      }
    }
  });
}

// ── Pending call tracker ──────────────────────────────────────────────────────

class _PendingCall {
  final Completer<_CallResponse> completer;
  final int workerIdx;
  const _PendingCall(this.completer, this.workerIdx);
}

// ── Pool ──────────────────────────────────────────────────────────────────────

/// A fixed pool of long-lived worker isolates with a **persistent reply port**.
///
/// ### Why this is faster than the naive ReceivePort-per-call approach
///
/// The old implementation allocated and closed a `ReceivePort` on every
/// [dispatch] call.  Each allocation involves an OS-level port registration,
/// and each close involves a deregistration — costs that dominate latency for
/// short FFI tasks.  With a pool size of 4 and 50,000 calls/second that is
/// 100,000 OS operations per second just for port bookkeeping.
///
/// This implementation opens exactly **one** `ReceivePort` per pool at
/// creation time.  Every response is tagged with a monotonically-increasing
/// [_callIdCounter]; a `Map<int, _PendingCall>` routes each response to the
/// correct `Completer` without any per-call OS interaction.
///
/// ### Least-busy scheduling
///
/// Workers are chosen by the **least-busy** algorithm: [_inflight] tracks the
/// number of in-flight calls per worker and the dispatcher always picks the
/// worker with the smallest count.  This prevents a slow JNI or Swift call on
/// one worker from blocking the next task that would have landed there via
/// round-robin.
class IsolatePool {
  IsolatePool._(this._workers, ReceivePort replyPort)
      : _inflight = List.filled(_workers.length, 0) {
    _replyPort = replyPort;
    replyPort.listen(_onReply);
  }

  final List<SendPort> _workers;

  /// In-flight call count per worker, index-parallel with [_workers].
  final List<int> _inflight;

  late final ReceivePort _replyPort;

  int _callIdCounter = 0;
  final Map<int, _PendingCall> _pending = {};
  bool _disposed = false;

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Spawns [size] worker isolates, wires a single persistent reply port, and
  /// returns a ready pool.
  static Future<IsolatePool> create(int size) async {
    assert(size > 0, 'Pool size must be at least 1');

    // One reply port shared by all workers for the lifetime of the pool.
    final replyPort = ReceivePort();
    final workers = <SendPort>[];

    for (var i = 0; i < size; i++) {
      final handshake = ReceivePort();
      await Isolate.spawn(
        _workerMain,
        _WorkerInit(handshake.sendPort, replyPort.sendPort),
      );
      final workerPort = await handshake.first as SendPort;
      handshake.close(); // handshake port used once — close immediately
      workers.add(workerPort);
    }

    return IsolatePool._(workers, replyPort);
  }

  // ── Reply demux ───────────────────────────────────────────────────────────

  void _onReply(dynamic msg) {
    if (msg is! _CallResponse) return;
    final pending = _pending.remove(msg.callId);
    if (pending == null) return; // already disposed or duplicate (shouldn't happen)
    _inflight[pending.workerIdx]--;
    // Completer.sync() means this fires the registered .then() handler
    // directly in this microtask rather than scheduling a new one.
    pending.completer.complete(msg);
  }

  // ── Scheduling ────────────────────────────────────────────────────────────

  int _leastBusyIndex() {
    var best = 0;
    for (var i = 1; i < _inflight.length; i++) {
      if (_inflight[i] < _inflight[best]) best = i;
    }
    return best;
  }

  // ── Dispatch ──────────────────────────────────────────────────────────────

  /// Dispatches [fn]([args]) to the least-busy worker.
  ///
  /// Returns a [Future] that completes when the worker replies.  No
  /// [ReceivePort] is allocated — the pool-level reply port is reused across
  /// all calls.
  Future<T> dispatch<T>(
    Function fn,
    List<Object?> args, {
    Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>>? getError,
    Pointer<NativeFunction<Void Function()>>? clearError,
  }) {
    assert(!_disposed, 'dispatch called on a disposed IsolatePool');

    final callId = _callIdCounter++;
    // Completer.sync() avoids an extra microtask hop between _onReply and
    // the caller's await — the value is delivered in the same microtask that
    // processes the port message.
    final completer = Completer<_CallResponse>.sync();

    final workerIdx = _leastBusyIndex();
    _inflight[workerIdx]++;
    _pending[callId] = _PendingCall(completer, workerIdx);

    _workers[workerIdx].send(
      _CallRequest(callId, fn, args, getError: getError, clearError: clearError),
    );

    return completer.future.then((response) {
      if (response.error != null) {
        return Future<T>.error(response.error!, response.stack);
      }
      return response.result as T;
    });
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  /// Kills all worker isolates and closes the reply port.
  ///
  /// Any in-flight calls are completed with a [StateError].  Calling [dispose]
  /// more than once is a no-op.  The pool must not be used after [dispose].
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    for (final w in _workers) {
      w.send(null); // null signals graceful shutdown to the worker
    }
    _workers.clear();

    // Complete all pending calls with a cancellation error so awaiting code
    // doesn't hang indefinitely.
    if (_pending.isNotEmpty) {
      final error = StateError('IsolatePool disposed while call was in flight');
      for (final p in _pending.values) {
        if (!p.completer.isCompleted) {
          p.completer.complete(_CallResponse(callId: -1, error: error));
        }
      }
      _pending.clear();
    }

    _replyPort.close();
  }
}
