import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'nitro_error_ffi.dart';
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

  // getError/clearError are the same two per-instance pointers on every
  // dispatch for a given module — .asFunction() rebinds a fresh Dart closure
  // around an unchanged Pointer each time it's called, which is redundant
  // per-call work. Cache the bound closures by pointer address instead of
  // rebinding on every message.
  final errorFnCache = <int, Pointer<NitroErrorFfi> Function()>{};
  final clearFnCache = <int, void Function()>{};

  inbox.listen((dynamic msg) {
    if (msg == null) {
      // Graceful shutdown signal sent by IsolatePool.dispose().
      inbox.close();
      return;
    }
    if (msg is _CallRequest) {
      // Every path must post exactly one reply. An un-sendable payload — an
      // error or result holding an FFI pointer or a closure — used to throw
      // out of this listener, killing the isolate and leaving every call
      // dispatched to it pending forever, with no timeout to recover.
      void reply(_CallResponse r, {required int callId}) {
        try {
          init.poolReply.send(r);
        } catch (e) {
          init.poolReply.send(
            _CallResponse(
              callId: callId,
              error: StateError('nitro: worker reply was not sendable ($e). Original: ${r.error ?? r.result}'),
            ),
          );
        }
      }

      try {
        final result = Function.apply(msg.fn, msg.args);
        if (msg.getError != null && msg.clearError != null) {
          final getErrorFn = errorFnCache.putIfAbsent(msg.getError!.address, () => msg.getError!.asFunction());
          final clearErrorFn = clearFnCache.putIfAbsent(msg.clearError!.address, () => msg.clearError!.asFunction());
          NitroRuntime.checkError(getErrorFn, clearErrorFn);
        }
        reply(_CallResponse(callId: msg.callId, result: result), callId: msg.callId);
      } catch (e, st) {
        reply(_CallResponse(callId: msg.callId, error: e, stack: st), callId: msg.callId);
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

/// A call waiting in the central backlog for a free worker. Carries everything
/// needed to send it the moment a worker frees up (or a new one spawns).
class _QueuedCall {
  final _CallRequest request;
  final Completer<_CallResponse> completer;
  const _QueuedCall(this.request, this.completer);
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
/// ### Work-queue scheduling
///
/// At most **one call is in flight per worker**. Extra calls wait in a central
/// [_queue] instead of a worker's mailbox, and the moment any worker frees up
/// (or a new one spawns) it pulls the head of the queue. That gives perfect
/// load balancing with no head-of-line blocking — a slow JNI/Swift call can't
/// trap the calls behind it — and lets a cold concurrent burst fan out across
/// workers as the pool grows, rather than stranding them on the first worker.
///
/// ### Elastic sizing
///
/// The pool grows from [_minWorkers] toward [_maxWorkers] under load (spawning
/// the whole demand deficit at once) and, after [_reapInterval] of no activity,
/// retires the extra workers back down to [_minWorkers]. Retired slots are
/// tombstoned (`null`) and reused by later growth, so the backing arrays stay
/// bounded by [_maxWorkers]. A fixed pool (`_minWorkers == _maxWorkers`) does
/// neither.
class IsolatePool {
  IsolatePool._(this._workers, ReceivePort replyPort, List<ReceivePort?> deathPorts, this._maxWorkers, this._minWorkers, this._reapInterval)
    : _free = List<int>.generate(_workers.length, (i) => i, growable: true),
      _live = _workers.length,
      _deathPorts = deathPorts {
    _replyPort = replyPort;
    replyPort.listen(_onReply);
    for (var i = 0; i < deathPorts.length; i++) {
      final idx = i;
      deathPorts[i]!.listen((dynamic m) => _onWorkerDeath(idx, m));
    }
  }

  /// Upper bound on worker count — the pool grows toward this under load.
  final int _maxWorkers;

  /// Lower bound — the pool never shrinks below this (the initial size, so a
  /// fixed pool where `_minWorkers == _maxWorkers` neither grows nor shrinks).
  final int _minWorkers;

  /// How long the pool must sit idle before a reap tick retires excess workers.
  /// `Duration.zero` disables shrinking.
  final Duration _reapInterval;

  /// Live (non-dead, non-retired) worker count — the real pool width. Tracked
  /// separately from `_workers.length`, which carries `null` tombstones for
  /// retired/dead slots that growth later reuses.
  int _live;

  /// Reusable slot indices freed by a death or a reap; growth fills these before
  /// appending, so `_workers.length` stays bounded by [_maxWorkers].
  final List<int> _emptySlots = [];

  /// Periodic idle-reaper; null when not running (pool at floor, or shrink
  /// disabled). Started on first growth, cancelled at the floor and on dispose.
  Timer? _reapTimer;

  /// Set on every dispatch, cleared each reap tick — distinguishes a genuinely
  /// quiet interval (safe to shrink) from a momentarily-idle-but-active one.
  bool _usedSinceReap = false;

  /// Spawns currently in flight. Growth is demand-proportional: when in-flight
  /// calls outnumber workers the pool spawns the whole deficit (up to the cap)
  /// at once, so it reaches full width in a single spawn window instead of one
  /// worker per contention event. Counted so overlapping triggers never
  /// over-spawn past [_maxWorkers].
  int _spawning = 0;

  /// Number of worker isolates currently live — rises toward [_maxWorkers]
  /// under load and falls back toward [_minWorkers] after an idle period.
  /// Useful to observe how far an adaptive pool has scaled.
  int get workerCount => _live;

  final List<ReceivePort?> _deathPorts;

  /// Fails every call still dispatched to a worker that has died, so the
  /// caller sees an error instead of a future that never settles.
  void _onWorkerDeath(int workerIdx, Object? message) {
    // Ignore a stale notification for a slot already emptied.
    if (_workers[workerIdx] == null) return;
    // Empty the slot and close its death port NOW — after the isolate has
    // exited (that's what triggered this). Closing the onExit port before the
    // exit lands prevents the VM from reclaiming the isolate, so port teardown
    // must happen here, not eagerly in _retire.
    final wasRetiring = _retiring.remove(workerIdx);
    _free.remove(workerIdx);
    _workers[workerIdx] = null;
    _deathPorts[workerIdx]?.close();
    _deathPorts[workerIdx] = null;
    _emptySlots.add(workerIdx);
    if (wasRetiring) return; // graceful shrink: _live already dropped, no call to fail
    _live--;
    // Crash: fail the one call it was running (≤1 in flight per worker).
    for (final e in _pending.entries) {
      if (e.value.workerIdx != workerIdx) continue;
      _pending.remove(e.key);
      e.value.completer.complete(
        _CallResponse(
          callId: e.key,
          error: StateError('nitro: worker isolate $workerIdx died before replying ($message)'),
        ),
      );
      break;
    }
    // Surviving / still-spawning workers take over the backlog; whatever can't
    // be served by anyone (no worker left, none spawning) is failed, not hung.
    _drain();
    _failQueueIfStranded();
  }

  /// Slots sent a graceful shutdown by [_retire] and awaiting their onExit.
  /// [_live] was already decremented for them, so [_onWorkerDeath] must not
  /// decrement again or fail a (non-existent) in-flight call.
  final Set<int> _retiring = {};

  final List<SendPort?> _workers;

  /// Indices of idle workers (a free-list). A worker sits here iff it has no
  /// call in flight; assignment pops one, a reply or a newly-spawned worker
  /// pushes it back. Replaces the old least-busy heap: with one call in flight
  /// per worker, "least busy" is just "any free worker".
  final List<int> _free;

  /// Central backlog of calls with no free worker yet. Holding it here — rather
  /// than queuing extra calls in a worker's mailbox — means whichever worker
  /// frees up next (or spawns next) pulls the head, so a cold burst parallelises
  /// as the pool grows and there is no head-of-line blocking.
  final Queue<_QueuedCall> _queue = Queue<_QueuedCall>();

  late final ReceivePort _replyPort;

  int _callIdCounter = 0;
  final Map<int, _PendingCall> _pending = {};
  bool _disposed = false;

  // ── Factory ───────────────────────────────────────────────────────────────

  /// Spawns [size] worker isolates, wires a single persistent reply port, and
  /// returns a ready pool.
  ///
  /// When [maxWorkers] exceeds [size] the pool is **adaptive**: it starts with
  /// [size] workers, spawns more (up to [maxWorkers]) on demand when every
  /// worker is busy, and after [idleReap] of no activity retires the extras back
  /// down to [size] (never below). Defaults to [size] (a fixed pool: no growth,
  /// no shrink). Pass `idleReap: Duration.zero` to disable shrinking.
  static Future<IsolatePool> create(int size, {int? maxWorkers, Duration idleReap = const Duration(seconds: 30)}) async {
    assert(size > 0, 'Pool size must be at least 1');
    final cap = maxWorkers ?? size;
    assert(cap >= size, 'maxWorkers ($cap) must be >= initial size ($size)');

    // One reply port shared by all workers for the lifetime of the pool.
    final replyPort = ReceivePort();
    final workers = <SendPort?>[];

    // A worker that dies (un-sendable payload, OOM, a native crash) must fail
    // its in-flight calls. Without this every future dispatched to it stays
    // pending forever and one bad call permanently poisons 1/N of the pool.
    final deathPorts = <ReceivePort?>[];
    for (var i = 0; i < size; i++) {
      final handshake = ReceivePort();
      final death = ReceivePort();
      deathPorts.add(death);
      await Isolate.spawn(
        _workerMain,
        _WorkerInit(handshake.sendPort, replyPort.sendPort),
        onExit: death.sendPort,
        onError: death.sendPort,
      );
      final workerPort = await handshake.first as SendPort;
      handshake.close(); // handshake port used once — close immediately
      workers.add(workerPort);
    }

    return IsolatePool._(workers, replyPort, deathPorts, cap, size, idleReap);
  }

  /// Brings workers online to match demand: with `D` calls in flight and `W`
  /// workers (`W < cap`), spawns `min(D, cap) − W − inFlightSpawns` more, all at
  /// once. Fire-and-forget — the triggering call is NOT delayed by the spawns;
  /// it dispatches to the least-busy worker now, and the new workers serve the
  /// backlog and subsequent calls. Spawning the whole deficit (rather than one
  /// per contention event) lets the pool reach full width in a single spawn
  /// window, so a sustained workload matches a pre-sized pool.
  void _maybeGrow() {
    if (_disposed) return;
    // Demand = calls in flight + calls waiting in the backlog.
    final demand = _pending.length + _queue.length;
    final target = demand < _maxWorkers ? demand : _maxWorkers;
    var want = target - _live - _spawning;
    while (want-- > 0) {
      _spawning++;
      unawaited(_growOne());
    }
  }

  Future<void> _growOne() async {
    final handshake = ReceivePort();
    final death = ReceivePort();
    try {
      await Isolate.spawn(
        _workerMain,
        _WorkerInit(handshake.sendPort, _replyPort.sendPort),
        onExit: death.sendPort,
        onError: death.sendPort,
      );
      final workerPort = await handshake.first as SendPort;
      handshake.close(); // used once
      // dispose() may have run during the two awaits above. Don't leak the new
      // isolate: shut it down and drop its death port instead of registering.
      if (_disposed) {
        workerPort.send(null); // graceful shutdown signal
        death.close();
        return;
      }
      // Reuse a tombstone slot if one is free, else append — keeps _workers
      // bounded by _maxWorkers across grow/shrink cycles.
      final int idx;
      if (_emptySlots.isNotEmpty) {
        idx = _emptySlots.removeLast();
        _workers[idx] = workerPort;
        _deathPorts[idx] = death;
      } else {
        idx = _workers.length;
        _workers.add(workerPort);
        _deathPorts.add(death);
      }
      death.listen((dynamic m) => _onWorkerDeath(idx, m));
      _live++;
      _ensureReapTimer(); // the pool grew — start watching for an idle period
      _free.add(idx); // idle and ready…
      _drain(); // …so it immediately pulls queued backlog (cold-burst fan-out).
    } catch (_) {
      // Spawn failed (platform isolate limit, OOM): keep serving with the
      // workers we have; a later contended dispatch retries growth.
      handshake.close();
      death.close();
    } finally {
      _spawning--;
    }
    // If that was the last spawn and it failed (or dispose raced it), the
    // backlog may now be unservable — fail it rather than hang.
    _failQueueIfStranded();
  }

  // ── Reply demux ───────────────────────────────────────────────────────────

  void _onReply(dynamic msg) {
    if (msg is! _CallResponse) return;
    final pending = _pending.remove(msg.callId);
    if (pending == null) return; // already disposed or duplicate (shouldn't happen)
    // The worker is free again — hand it the next queued call before completing,
    // so it never idles while backlog waits.
    _free.add(pending.workerIdx);
    _drain();
    // Completer.sync() means this fires the registered .then() handler
    // directly in this microtask rather than scheduling a new one.
    pending.completer.complete(msg);
  }

  // ── Scheduling ────────────────────────────────────────────────────────────

  /// Pair queued calls with free workers, one each, until one side runs out.
  /// Called whenever the backlog or the free-list may have grown: on dispatch,
  /// on a reply, when a worker is spawned, and on a death.
  void _drain() {
    while (_queue.isNotEmpty && _free.isNotEmpty) {
      final idx = _free.removeLast();
      final q = _queue.removeFirst();
      _pending[q.request.callId] = _PendingCall(q.completer, idx);
      _workers[idx]!.send(q.request); // _free only holds live slots
    }
  }

  /// Fails queued calls that nothing can ever serve. After a worker death (or a
  /// failed spawn) the backlog can be stranded: no idle worker to take it, no
  /// busy worker that will free, and no spawn in flight. Without this they would
  /// hang forever — the central-queue analogue of a mailbox dying with its
  /// worker. (Not reached while the pool can still grow or has a live worker.)
  void _failQueueIfStranded() {
    if (_disposed || _queue.isEmpty) return;
    if (_free.isNotEmpty || _pending.isNotEmpty || _spawning > 0) return;
    final error = StateError('nitro: no live worker isolate to serve queued @nitroAsync calls (all workers died)');
    while (_queue.isNotEmpty) {
      final q = _queue.removeFirst();
      if (!q.completer.isCompleted) {
        q.completer.complete(_CallResponse(callId: q.request.callId, error: error));
      }
    }
  }

  // ── Idle shrink ─────────────────────────────────────────────────────────────

  /// Starts the periodic idle-reaper if it isn't already running and shrinking
  /// is enabled. Called when the pool grows above its floor.
  void _ensureReapTimer() {
    if (_reapTimer != null || _disposed || _reapInterval <= Duration.zero) return;
    if (_live <= _minWorkers) return;
    _reapTimer = Timer.periodic(_reapInterval, (_) => _reap());
  }

  /// One reap tick. Retires excess workers only after a FULL quiet interval
  /// (no dispatch since the last tick) AND while the pool is completely idle —
  /// no in-flight call, no backlog, no spawn — so no call is ever disturbed.
  /// Shrinks back toward [_minWorkers]; growth re-spawns if load returns.
  void _reap() {
    if (_disposed) return;
    if (_usedSinceReap) {
      _usedSinceReap = false; // activity last interval — give it another one
      return;
    }
    if (_pending.isEmpty && _queue.isEmpty && _spawning == 0) {
      var excess = _live - _minWorkers;
      while (excess-- > 0 && _free.isNotEmpty) {
        _retire(_free.removeLast());
      }
    }
    if (_live <= _minWorkers) {
      // At the floor — nothing to watch until the next growth restarts us.
      _reapTimer?.cancel();
      _reapTimer = null;
    }
  }

  /// Gracefully shuts down one idle worker (already removed from the free-list).
  /// Sends the shutdown signal and drops [_live] immediately so the reaper's
  /// accounting is correct, but leaves the slot and its death port in place: the
  /// ensuing onExit runs [_onWorkerDeath], which tombstones the slot and closes
  /// the port *after* the isolate has exited (closing it earlier would strand
  /// the isolate in the VM and leak its heap — see isolate_pool_shrink_bench).
  void _retire(int idx) {
    _retiring.add(idx);
    _live--;
    _workers[idx]?.send(null); // graceful shutdown → onExit → _onWorkerDeath
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
    // Release builds (asserts off) must fail fast, not queue a call that nothing
    // will ever drain — a disposed pool has no workers to serve it.
    if (_disposed) {
      return Future<T>.error(StateError('nitro: dispatch called on a disposed IsolatePool'));
    }

    final callId = _callIdCounter++;
    // Completer.sync() avoids an extra microtask hop between _onReply and
    // the caller's await — the value is delivered in the same microtask that
    // processes the port message.
    final completer = Completer<_CallResponse>.sync();

    _usedSinceReap = true; // mark activity so the idle-reaper won't shrink us

    final req = _CallRequest(callId, fn, args, getError: getError, clearError: clearError);
    if (_free.isNotEmpty) {
      // A worker is idle — assign directly. Fast path for the common
      // sequential case: no _QueuedCall allocation, no growth check.
      final idx = _free.removeLast();
      _pending[callId] = _PendingCall(completer, idx);
      _workers[idx]!.send(req); // _free only holds live slots
    } else {
      // Every worker is busy — hold the call centrally and, if below the cap,
      // grow to meet demand. Whichever worker frees or spawns next pulls it, so
      // it never waits behind another call in one worker's mailbox, and a cold
      // burst fans out across new workers as they come online. This call is not
      // delayed by any spawn — it's already queued.
      _queue.add(_QueuedCall(req, completer));
      if (_live < _maxWorkers) _maybeGrow();
    }

    return completer.future.then((response) {
      if (response.error != null) {
        // Return a Future.error, don't throw: `completer` is sync (above), so
        // this callback runs synchronously when dispose() completes a pending
        // call, and a raw throw would escape into dispose()'s caller.
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

    _reapTimer?.cancel();
    _reapTimer = null;

    for (final w in _workers) {
      w?.send(null); // null signals graceful shutdown (skip tombstoned slots)
    }
    // Close the onExit/onError ports too — a graceful shutdown fires onExit,
    // and a live listener would otherwise keep the pool's isolate alive.
    for (final d in _deathPorts) {
      d?.close();
    }
    _deathPorts.clear();
    _workers.clear();
    _free.clear();
    _emptySlots.clear();
    _retiring.clear();
    _live = 0;

    // Fail every call that will never get a reply — both those in flight on a
    // worker and those still waiting in the backlog — so awaiting code doesn't
    // hang indefinitely.
    final error = StateError('IsolatePool disposed while call was in flight');
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) {
        p.completer.complete(_CallResponse(callId: -1, error: error));
      }
    }
    _pending.clear();
    for (final q in _queue) {
      if (!q.completer.isCompleted) {
        q.completer.complete(_CallResponse(callId: -1, error: error));
      }
    }
    _queue.clear();

    _replyPort.close();
  }
}
