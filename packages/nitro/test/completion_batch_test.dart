// NitroCompletionBatch: the Dart half of shared-port completion batching.
// The "native" side is simulated by sending [id, value, ...] arrays to the
// batch port and recording bind/ack calls.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro/nitro.dart';

// No-op spin hooks for the tests that don't exercise the spin (spin is off by
// default, so arm/poll are never invoked on those paths).
void _noArm(int id) {}
int _noPoll(int id, Pointer<Uint8> out, int giveUp) => 2; // always "parked"

void main() {
  test('ids come from bind, batches demux by id, and every batch is acked once', () async {
    var nextId = 100;
    final binds = <int>[];
    final acks = <int>[];
    final batch = NitroCompletionBatch(bind: (port) { binds.add(port); return nextId++; }, ack: acks.add, arm: _noArm, poll: _noPoll);
    final got = <int, dynamic>{};
    final a = batch.register((raw) => got[100] = raw);
    final b = batch.register((raw) => got[101] = raw);
    final c = batch.register((raw) => got[102] = raw);
    expect([a, b, c], [100, 101, 102]);
    expect(binds, [batch.nativePort, batch.nativePort, batch.nativePort]);
    final send = batch.sendPort;
    // One lone completion, then a two-call batch, as the C++ side would send.
    send.send([102, 'c']);
    send.send([100, 1, 101, 2.5]);
    await Future<void>.delayed(Duration.zero);
    expect(got, {102: 'c', 100: 1, 101: 2.5});
    expect(acks, [batch.nativePort, batch.nativePort], reason: 'one ack per message, not per completion');
    expect(batch.pendingCount, 0);
  });

  test('a forgotten (timed-out) id is ignored but still acked; unknown ids never throw', () async {
    final acks = <int>[];
    final batch = NitroCompletionBatch(bind: (_) => 7, ack: acks.add, arm: _noArm, poll: _noPoll);
    var called = false;
    batch.register((_) => called = true);
    batch.forget(7);
    batch.sendPort.send([7, 'late', 999, 'unknown']);
    await Future<void>.delayed(Duration.zero);
    expect(called, isFalse);
    expect(acks, hasLength(1));
  });

  test('openNativeAsync with a batch resolves through it, keeps unpack errors as future errors, and honours the timeout', () async {
    var seq = 0;
    final acks = <int>[];
    final batch = NitroCompletionBatch(bind: (_) => ++seq, ack: acks.add, arm: _noArm, poll: _noPoll);
    final send = batch.sendPort;
    final ok = NitroRuntime.openNativeAsync<int>(call: (id) => send.send([id, 41]), unpack: (raw) => (raw as int) + 1, batch: batch);
    expect(await ok, 42);
    final bad = NitroRuntime.openNativeAsync<int>(call: (id) => send.send([id, 'x']), unpack: (raw) => throw StateError('bad $raw'), batch: batch);
    await expectLater(bad, throwsA(isA<StateError>()));
    NitroConfig.instance.nativeAsyncTimeoutMs = 20;
    try {
      final slow = NitroRuntime.openNativeAsync<int>(call: (_) {}, unpack: (raw) => raw as int, batch: batch);
      await expectLater(slow, throwsA(isA<TimeoutException>()));
      expect(batch.pendingCount, 0, reason: 'timed-out id forgotten');
    } finally {
      NitroConfig.instance.reset();
    }
  });

  group('single-in-flight completion spin (issue #57)', () {
    // A Dart stand-in for the native slot handshake in nitro_completion_batch.h.
    // The "worker" completes a call via [completeViaSlot]; poll() mirrors the
    // C++ CAS: whoever reaches the flag first (worker=done, Dart giveUp=parked)
    // decides the delivery channel.
    late int armedId;
    late int flag; // 0 pending, 1 done, 2 parked
    late int tag, ival;
    late double dval;
    late int pollCount;
    void arm(int id) {
      armedId = id;
      flag = 0;
    }

    int poll(int id, Pointer<Uint8> out, int giveUp) {
      pollCount++;
      if (armedId != id) return 2;
      if (giveUp != 0 && flag == 0) flag = 2;
      if (flag == 0) return 0;
      armedId = 0;
      if (flag == 1) {
        out.cast<Int32>().value = tag;
        (out + 8).cast<Int64>().value = ival;
        (out + 16).cast<Double>().value = dval;
        return 1;
      }
      return 2;
    }

    void completeViaSlot(int t, {int i = 0, double d = 0}) {
      if (flag != 0) return; // Dart already parked → caller must use the port
      tag = t;
      ival = i;
      dval = d;
      flag = 1;
    }

    NitroCompletionBatch make(List<int> acks) =>
        NitroCompletionBatch(bind: (_) => 1, ack: acks.add, arm: arm, poll: poll);

    setUp(() {
      armedId = 0;
      flag = 2;
      pollCount = 0;
      NitroSpinStats.instance.reset();
      NitroConfig.instance.nativeAsyncSpinUs = 5000;
    });
    tearDown(() {
      NitroConfig.instance.reset();
      NitroSpinStats.instance.reset();
    });

    test('a completion inside the window resolves off-port — no ack, no message', () async {
      final acks = <int>[];
      final batch = make(acks);
      final f = NitroRuntime.openNativeAsync<int>(
        call: (id) => completeViaSlot(1, i: 41), // worker completes during the call
        unpack: (raw) => (raw as int) + 1,
        batch: batch,
      );
      expect(await f, 42);
      expect(acks, isEmpty, reason: 'nothing travelled through the port');
      expect(batch.pendingCount, 0, reason: 'id dropped on slot delivery');
      expect(NitroSpinStats.instance.hits, 1);
      expect(NitroSpinStats.instance.misses, 0);
      expect(NitroSpinStats.instance.hitRate, 1.0);
    });

    test('tag decode: null, double and bool round-trip through the slot', () async {
      final batch = make(<int>[]);
      final n = NitroRuntime.openNativeAsync<int?>(call: (_) => completeViaSlot(0), unpack: (raw) => raw as int?, batch: batch);
      expect(await n, isNull);
      final d = NitroRuntime.openNativeAsync<double>(call: (_) => completeViaSlot(2, d: 3.5), unpack: (raw) => raw as double, batch: batch);
      expect(await d, 3.5);
      final b = NitroRuntime.openNativeAsync<bool>(call: (_) => completeViaSlot(3, i: 1), unpack: (raw) => raw as bool, batch: batch);
      expect(await b, isTrue);
    });

    test('a completion that misses the window parks and falls back to the port', () async {
      final acks = <int>[];
      final batch = make(acks);
      NitroConfig.instance.nativeAsyncSpinUs = 50; // tiny window → always misses
      late int capturedId;
      final f = NitroRuntime.openNativeAsync<int>(
        call: (id) => capturedId = id, // no slot completion during the call
        unpack: (raw) => raw as int,
        batch: batch,
      );
      // Spin already gave up (parked) by the time openNativeAsync returned.
      expect(flag, 2);
      batch.sendPort.send([capturedId, 7]); // the worker delivers via the port
      expect(await f, 7);
      expect(acks, isNotEmpty, reason: 'the port path acked the batch');
      expect(NitroSpinStats.instance.misses, 1);
      expect(NitroSpinStats.instance.hits, 0);
    });

    test('circuit breaker opens after a run of misses, then parks with no spin', () {
      final batch = make(<int>[]);
      // The fake slot never completes → every spinPoll is a miss.
      final polls = <int>[];
      for (var call = 0; call < 10; call++) {
        final id = 2000 + call;
        pollCount = 0;
        batch.armSpin(id);
        expect(batch.spinPoll(id, 200), isNull);
        polls.add(pollCount);
      }
      expect(polls.first, greaterThan(10), reason: 'early calls actually spin');
      expect(polls.last, 1, reason: 'breaker open → one park poll, no spin loop');
      expect(NitroSpinStats.instance.misses, 10);
      expect(NitroSpinStats.instance.hits, 0);
    });

    test('spin is skipped when another native-async call is already in flight', () async {
      var seq = 0;
      var polls = 0;
      NitroConfig.instance.nativeAsyncSpinUs = 50; // keep the first call's spin short
      final batch = NitroCompletionBatch(
        bind: (_) => ++seq,
        ack: (_) {},
        arm: arm,
        poll: (id, out, giveUp) { polls++; return poll(id, out, giveUp); },
      );
      // First call: single-in-flight → spins, misses, parks. Stays pending.
      final first = NitroRuntime.openNativeAsync<int>(call: (_) {}, unpack: (raw) => raw as int, batch: batch);
      final pollsAfterFirst = polls;
      // Second call now sees pendingCount == 1 → must not arm/poll at all.
      final second = NitroRuntime.openNativeAsync<int>(call: (id) => batch.sendPort.send([id, 2]), unpack: (raw) => raw as int, batch: batch);
      expect(polls, pollsAfterFirst, reason: 'no spin while another call is outstanding');
      expect(await second, 2);
      batch.sendPort.send([1, 1]); // deliver the first via the port
      expect(await first, 1);
    });

    test('breaker recovers after a hit — full-window spinning resumes', () {
      final batch = make(<int>[]);
      // Trip the breaker with 8 misses (the fake never completes).
      for (var i = 0; i < 8; i++) {
        batch.armSpin(3000 + i);
        batch.spinPoll(3000 + i, 200);
      }
      // Backed off: a miss now parks with a single poll, no spin.
      pollCount = 0;
      batch.armSpin(3100);
      expect(batch.spinPoll(3100, 200), isNull);
      expect(pollCount, 1, reason: 'breaker open → no spin loop');
      // A completion lands → hit → clears the breaker.
      batch.armSpin(3101);
      completeViaSlot(1, i: 7);
      expect(batch.spinPoll(3101, 200), [7]);
      // Next miss spins the full window again — spinning resumed.
      pollCount = 0;
      batch.armSpin(3102);
      expect(batch.spinPoll(3102, 200), isNull);
      expect(pollCount, greaterThan(10), reason: 'window back to the cap after recovery');
    });

    test('a slot hit whose unpack throws surfaces as a future error, still counted a hit', () async {
      final batch = make(<int>[]);
      final f = NitroRuntime.openNativeAsync<int>(
        call: (_) => completeViaSlot(1, i: 5),
        unpack: (raw) => throw StateError('boom $raw'),
        batch: batch,
      );
      await expectLater(f, throwsA(isA<StateError>()));
      expect(NitroSpinStats.instance.hits, 1);
    });

    test('a spun call that never completes still honours nativeAsyncTimeoutMs', () async {
      NitroConfig.instance.nativeAsyncSpinUs = 50;
      NitroConfig.instance.nativeAsyncTimeoutMs = 20;
      final batch = make(<int>[]);
      final f = NitroRuntime.openNativeAsync<int>(call: (_) {}, unpack: (raw) => raw as int, batch: batch);
      await expectLater(f, throwsA(isA<TimeoutException>()));
    });

    test('a large int64 heap address round-trips through the slot', () async {
      final batch = make(<int>[]);
      const addr = 0x7fffabcd1234; // a realistic 64-bit pointer value
      final f = NitroRuntime.openNativeAsync<int>(
        call: (_) => completeViaSlot(1, i: addr),
        unpack: (raw) => raw as int,
        batch: batch,
      );
      expect(await f, addr);
    });

    test('NitroSpinStats aggregates hit-rate / avg and resets', () async {
      final batch = make(<int>[]);
      for (final v in [10, 20, 30]) {
        batch.armSpin(5000);
        completeViaSlot(1, i: v);
        batch.spinPoll(5000, 200);
      }
      batch.armSpin(5001);
      batch.spinPoll(5001, 50); // a miss (never completed via the slot)
      // Its uncensored latency only lands when the port delivers → _onBatch.
      batch.sendPort.send([5001, 0]);
      await Future<void>.delayed(Duration.zero);
      final s = NitroSpinStats.instance;
      expect(s.hits, 3);
      expect(s.misses, 1);
      expect(s.spins, 4);
      expect(s.hitRate, closeTo(0.75, 1e-9));
      expect(s.avgHitUs, greaterThanOrEqualTo(0));
      expect(s.avgMissUs, greaterThanOrEqualTo(0), reason: 'park-path latency recorded on port delivery');
      s.reset();
      expect([s.spins, s.hits, s.misses], [0, 0, 0]);
      expect([s.hitRate, s.avgHitUs, s.avgMissUs], [0, 0, 0]);
    });

    test('nativeAsyncSpinUs = 0 disables the spin entirely (no arm, no poll)', () async {
      NitroConfig.instance.nativeAsyncSpinUs = 0;
      var armed = 0, polled = 0;
      final batch = NitroCompletionBatch(
        bind: (_) => 1,
        ack: (_) {},
        arm: (_) => armed++,
        poll: (i, o, g) {
          polled++;
          return 2;
        },
      );
      final f = NitroRuntime.openNativeAsync<int>(call: (id) => batch.sendPort.send([id, 9]), unpack: (raw) => raw as int, batch: batch);
      expect(await f, 9);
      expect([armed, polled], [0, 0]);
      expect(NitroSpinStats.instance.spins, 0);
    });

    test('a pathological cap is clamped so the spin cannot hang', () {
      final batch = make(<int>[]);
      batch.armSpin(6000); // never completes → spins the whole (clamped) window
      final sw = Stopwatch()..start();
      expect(batch.spinPoll(6000, 5000000), isNull); // 5-second cap requested
      expect(sw.elapsedMilliseconds, lessThan(200), reason: 'clamped to ~10ms, not 5s');
    });

    test('edge hits (landing at the window boundary) trip the breaker, bounding the busy-wait', () {
      // A worker that lands right at the deadline every call: never hits during
      // the burst, "completes" only on the giveUp poll → hitUs ≈ window. The
      // consecutive-miss breaker can't see this (it's a hit), so without the
      // edge-hit accounting it would spin near-full-window forever.
      int edgePoll(int id, Pointer<Uint8> out, int giveUp) {
        pollCount++;
        if (giveUp != 0) {
          out.cast<Int32>().value = 1; // tag int
          (out + 8).cast<Int64>().value = 1;
          return 1; // lands exactly at the deadline
        }
        return 0; // pending through the whole burst
      }

      final batch = NitroCompletionBatch(bind: (_) => 1, ack: (_) {}, arm: arm, poll: edgePoll);
      for (var i = 0; i < 8; i++) {
        batch.armSpin(7000 + i);
        batch.spinPoll(7000 + i, 30); // each spins ~30µs then edge-hits
      }
      // If the breaker opened, the 9th call takes the window==0 path: a single
      // giveUp poll, no burst. (Without the fix every edge-hit resets the miss
      // counter, so the breaker never opens and this call spins → many polls.)
      pollCount = 0;
      batch.armSpin(7100);
      batch.spinPoll(7100, 30);
      expect(pollCount, 1, reason: 'edge hits opened the breaker; the spin stops burning the loop');
    });
  });
}
