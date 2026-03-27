import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'hybrid_exception.dart';
import 'nitro_runtime.dart';

// ── Messages sent over the pool's control channel ─────────────────────────────

class _CallRequest {
  final Function fn;
  final List<Object?> args;
  final SendPort replyPort;
  final Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>>? getError;
  final Pointer<NativeFunction<Void Function()>>? clearError;
  const _CallRequest(this.fn, this.args, this.replyPort, {this.getError, this.clearError});
}

class _CallResponse {
  final Object? result;
  final Object? error;
  final StackTrace? stack;
  const _CallResponse({this.result, this.error, this.stack});
}

// ── Worker isolate entry point ────────────────────────────────────────────────

void _workerMain(SendPort controlPort) {
  final inbox = ReceivePort();
  controlPort.send(inbox.sendPort); // handshake: send our inbox back

  inbox.listen((dynamic msg) {
    if (msg is _CallRequest) {
      try {
        final result = Function.apply(msg.fn, msg.args);
        if (msg.getError != null && msg.clearError != null) {
          NitroRuntime.checkError(
            msg.getError!.asFunction(),
            msg.clearError!.asFunction(),
          );
        }
        msg.replyPort.send(_CallResponse(result: result));
      } catch (e, st) {
        msg.replyPort.send(_CallResponse(error: e, stack: st));
      }
    }
  });
}

// ── Pool ──────────────────────────────────────────────────────────────────────

/// A fixed pool of long-lived worker isolates.
///
/// Each worker sits in a `ReceivePort.listen` loop.  Callers dispatch work
/// via [dispatch] and get back a [Future] that completes when the worker
/// replies.  Dispatch is round-robin across available workers.
class IsolatePool {
  IsolatePool._(this._workers);

  final List<SendPort> _workers;
  int _rrIndex = 0;

  /// Spawns [size] worker isolates and returns a ready pool.
  static Future<IsolatePool> create(int size) async {
    assert(size > 0, 'Pool size must be at least 1');
    final workers = <SendPort>[];
    for (var i = 0; i < size; i++) {
      final inbox = ReceivePort();
      await Isolate.spawn(_workerMain, inbox.sendPort);
      // First message back is the worker's own SendPort.
      final workerPort = await inbox.first as SendPort;
      workers.add(workerPort);
    }
    return IsolatePool._(workers);
  }

  /// Dispatches [fn]([args]) to the next worker in round-robin order.
  Future<T> dispatch<T>(
    Function fn,
    List<Object?> args, {
    Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>>? getError,
    Pointer<NativeFunction<Void Function()>>? clearError,
  }) {
    final reply = ReceivePort();
    final worker = _workers[_rrIndex % _workers.length];
    _rrIndex++;
    worker.send(_CallRequest(
      fn,
      args,
      reply.sendPort,
      getError: getError,
      clearError: clearError,
    ));
    return reply.first.then((dynamic msg) {
      reply.close();
      final response = msg as _CallResponse;
      if (response.error != null) {
        return Future<T>.error(response.error!, response.stack);
      }
      return response.result as T;
    });
  }

  /// Kills all worker isolates.  The pool must not be used after this.
  void dispose() {
    for (final w in _workers) {
      w.send(null); // workers quit on null (Isolate.exit)
    }
    _workers.clear();
  }
}
