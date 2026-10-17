import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'nitro_config.dart';

/// Shared-port demux for one library's `@nitroNativeAsync` completions.
///
/// Every message a Dart isolate receives costs one embedder task (~10 µs in a
/// Flutter build), whichever port it targets. The C++ side
/// (nitro_completion_batch.h) therefore delivers completions to this one port
/// as `[id, value, id, value, ...]` and holds any that arrive before [ack] so
/// they travel as one message. A lone completion still goes out at once.
class NitroCompletionBatch implements Finalizable {
  NitroCompletionBatch({required this.bind, required this.ack, required this.arm, required this.poll}) {
    _port = RawReceivePort(_onBatch)..keepIsolateAlive = false;
  }

  // The spin read-buffer is calloc'd (not GC-managed), so release it when the
  // batch is collected. The port closes itself on GC (RawReceivePort), but the
  // buffer would otherwise be a permanent native leak — one per batch that ever
  // spun. [Finalizable] keeps `this` reachable while a spin is in flight.
  static final _spinOutFinalizer = NativeFinalizer(malloc.nativeFree);

  /// `<lib>_nitro_bind(batchPort) → id`, reserved per call.
  final int Function(int batchPort) bind;

  /// `<lib>_nitro_ack(batchPort)`, sent after every handled batch.
  final void Function(int batchPort) ack;

  /// `<lib>_nitro_arm(id)` — arm the single-in-flight spin slot for [spinPoll].
  final void Function(int id) arm;

  /// `<lib>_nitro_poll(id, out, giveUp) → state` — one spin iteration.
  final int Function(int id, Pointer<Uint8> out, int giveUp) poll;

  late final RawReceivePort _port;
  final Map<int, void Function(dynamic raw)> _pending = {};

  // 24-byte read buffer for the spin slot: int32 tag @0, int64 @8, double @16.
  // One buffer suffices because spinning is single-in-flight by contract.
  Pointer<Uint8>? _spinOut;

  // Uncensored miss-latency instrument: a lone spin that parks doesn't know its
  // completion latency yet, so stamp the arm time and measure it when the port
  // delivers (in [_onBatch]). Single-in-flight → exactly one pending sample.
  final Stopwatch _spinClock = Stopwatch()..start();
  int _armMicros = 0;
  bool _awaitingParkLatency = false;

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

  // Circuit-breaker state, per library — completion speeds differ per native
  // impl, so each batch decides independently whether spinning is paying.
  int _recentMisses = 0; // consecutive misses → trips the breaker
  bool _backedOff = false; // breaker open: park fast, probe occasionally
  int _sinceProbe = 0; // calls since the last probe while backed off

  // After this many consecutive misses the spin isn't catching anything (the
  // native side is slower than the cap) — stop burning a core and park
  // straight away, probing once every [_probeEvery] calls to notice if
  // completions get fast enough to catch again.
  static const int _missesToBackOff = 8;
  static const int _probeEvery = 32;

  // Foot-gun guard: a fat-fingered `nativeAsyncSpinUs` must not burn a core for
  // its whole value on each miss before the breaker trips. Far above any sane cap.
  static const int _maxSpinUs = 10000;

  // Event-loop occupancy cap: the spin is a synchronous busy-wait, so bound it
  // to [_dutyBudgetUs] per [_dutyWindowUs] of wall-clock (reusing _spinClock).
  // A lone call spins ~µs (far under budget) so production is untouched; only a
  // sustained loop — e.g. under a profiler / flutter_driver — is throttled,
  // which keeps the busy-wait from starving the loop, with no flag or detection.
  static const int _dutyWindowUs = 20000; // 20 ms (> one 60fps frame)
  static const int _dutyBudgetUs = 5000; // ≤25% of wall-clock spinning
  int _dutySpentUs = 0;
  int _dutyWindowStartUs = 0;

  // A miss, or an edge hit that barely caught: trip the breaker after a run.
  void _countMiss() {
    if (++_recentMisses >= _missesToBackOff) _backedOff = true;
  }

  /// Arms the native spin slot for [id]. Call right before the native call,
  /// only when single-in-flight (see [spinPoll]).
  void armSpin(int id) {
    _armMicros = _spinClock.elapsedMicroseconds;
    arm(id);
  }

  /// Busy-polls the armed slot (issue #57), capped at [capUs] µs. Returns a
  /// one-element `[raw]` when the completion lands off-port — no port message,
  /// no OS wake — or null when it parks, leaving the normal port callback to
  /// deliver it. Single-in-flight only.
  ///
  /// The loop breaks the instant the completion lands, so [capUs] is an upper
  /// bound, not a fixed spend: a hit only ever spins until its result arrives,
  /// however large the cap. The cap therefore bounds just the *miss* path, and
  /// a circuit breaker caps even that — after a run of misses (the native side
  /// is reliably slower than [capUs], so spinning can't win) the window drops
  /// to zero and calls park immediately, probing at the full cap every
  /// [_probeEvery] calls. [NitroSpinStats] reports the hit-rate so you can see
  /// whether the cap is set usefully.
  List<dynamic>? spinPoll(int id, int capUs) {
    final window = _effectiveWindow(capUs);
    final out = _spinOut ??= () {
      final buf = calloc<Uint8>(24);
      _spinOutFinalizer.attach(this, buf.cast(), detach: this, externalSize: 24);
      return buf;
    }();
    var state = 0; // 0 pending, 1 done, 2 parked
    final sw = Stopwatch()..start();
    if (window > 0) {
      // Poll in bursts between clock reads (a clock read ~150 ns dwarfs a leaf
      // poll ~few ns), so the loop stays poll-bound and catches a completion
      // within ns of it landing rather than within a clock-read.
      outer:
      while (sw.elapsedMicroseconds < window) {
        for (var k = 0; k < 64; k++) {
          state = poll(id, out, 0);
          if (state != 0) break outer;
        }
      }
    }
    if (state == 0) state = poll(id, out, 1); // deadline: claim-or-park
    _dutySpentUs += sw.elapsedMicroseconds; // charge actual busy-wait to the budget

    if (state != 1) {
      // Parked → the port path takes over.
      _countMiss();
      NitroSpinStats.instance.recordMiss();
      // Measure this miss's true latency when its port message lands — but only
      // if we actually spun (a breaker-forced window==0 park never armed a fresh
      // clock and isn't a real "the cap was too tight" miss).
      if (window > 0) _awaitingParkLatency = true;
      return null;
    }

    // Hit: delivered off-port; the port callback must not fire.
    final hitUs = sw.elapsedMicroseconds;
    // An edge hit (spun almost the whole window before landing) paid nearly the
    // full miss cost; the miss-only breaker can't see it, so a worker that lands
    // at the boundary every call would spin near-full-window forever. Count it
    // toward backoff; only a comfortably-early hit (the common ~µs case) resumes.
    if (window > 0 && hitUs > window - (window >> 3)) {
      _countMiss();
    } else {
      _recentMisses = 0;
      _backedOff = false;
    }
    NitroSpinStats.instance.recordHit(hitUs);
    _pending.remove(id);
    return [_decodeSlot(out)];
  }

  // The window for this call: the cap (clamped to [_maxSpinUs]), 0 while the
  // breaker is open (bar an occasional probe), and 0 once this sliding window's
  // duty budget is spent — so the event loop (and any driver channel) is served.
  int _effectiveWindow(int capUs) {
    int window = capUs < _maxSpinUs ? capUs : _maxSpinUs;
    if (_backedOff) {
      if (_sinceProbe >= _probeEvery) {
        _sinceProbe = 0; // probe: has the native side got fast enough again?
      } else {
        _sinceProbe++;
        window = 0;
      }
    }
    final nowUs = _spinClock.elapsedMicroseconds;
    if (nowUs - _dutyWindowStartUs >= _dutyWindowUs) {
      _dutyWindowStartUs = nowUs;
      _dutySpentUs = 0;
    }
    if (_dutySpentUs >= _dutyBudgetUs) window = 0;
    return window;
  }

  // Decode the native slot payload: int32 tag @0, then int64 @8 / double @16.
  static Object? _decodeSlot(Pointer<Uint8> out) => switch (out.cast<Int32>().value) {
        0 => null, // kTagNull
        2 => (out + 16).cast<Double>().value, // kTagDouble
        3 => (out + 8).cast<Int64>().value != 0, // kTagBool
        _ => (out + 8).cast<Int64>().value, // kTagInt / int64 heap address
      };

  void _onBatch(dynamic msg) {
    // The one deferred parked-spin latency (single-in-flight → one sample).
    if (_awaitingParkLatency) {
      _awaitingParkLatency = false;
      NitroSpinStats.instance.recordMissLatency(_spinClock.elapsedMicroseconds - _armMicros);
    }
    final batch = msg as List<dynamic>;
    for (var i = 0; i + 1 < batch.length; i += 2) {
      _pending.remove(batch[i] as int)?.call(batch[i + 1]);
    }
    ack(nativePort);
  }
}
