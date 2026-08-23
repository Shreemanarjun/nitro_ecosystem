// Tests for NitroCoalescer — the shared-port demultiplexer for coalesced
// @nitroNativeAsync completions (issue #39). A native batch is simulated by
// posting a [callId0, value0, …] list to the coalescer's SendPort.
import 'package:leak_tracker/leak_tracker.dart';
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  group('NitroCoalescer', () {
    test('assigns sequential callIds and resolves each by id', () async {
      final c = NitroCoalescer();
      final ids = <int>[];
      final f0 = c.submit((id, _) => ids.add(id));
      final f1 = c.submit((id, _) => ids.add(id));
      final f2 = c.submit((id, _) => ids.add(id));
      expect(ids, [0, 1, 2]);
      expect(c.pendingCount, 3);

      // One coalesced batch carrying all three, out of order.
      c.sendPort.send([2, 222, 0, 200, 1, 211]);

      expect(await f0, 200);
      expect(await f1, 211);
      expect(await f2, 222);
      expect(c.pendingCount, 0);
      await c.dispose();
    });

    test('resolves across multiple partial batches', () async {
      final c = NitroCoalescer();
      final f0 = c.submit((_, _) {});
      final f1 = c.submit((_, _) {});
      c.sendPort.send([0, 10]); // first batch: only call 0
      expect(await f0, 10);
      expect(c.pendingCount, 1);
      c.sendPort.send([1, 11]); // later batch: call 1
      expect(await f1, 11);
      await c.dispose();
    });

    test('nativePort is stable and matches the send port', () async {
      final c = NitroCoalescer();
      expect(c.nativePort, c.sendPort.nativePort);
      expect(c.nativePort, isNot(0));
      await c.dispose();
    });

    test('ignores unknown callIds without throwing', () async {
      final c = NitroCoalescer();
      final f0 = c.submit((_, _) {});
      c.sendPort.send([999, 42, 0, 7]); // 999 unknown, 0 pending
      expect(await f0, 7);
      await c.dispose();
    });

    // #47: dispose() dropped pending completers, so a call whose result was
    // already posted (but not yet delivered — a post only enqueues) never
    // completed. The future hung forever instead of failing.
    test('dispose delivers a result that was already posted', () async {
      final c = NitroCoalescer();
      final pending = c.submit((id, _) => c.sendPort.send(<int>[id, 42]));
      await c.dispose();
      expect(await pending.timeout(const Duration(seconds: 2)), 42);
    });

    test('dispose fails a genuinely lost call instead of hanging', () async {
      final c = NitroCoalescer();
      final pending = c.submit((_, _) {}); // native never posts
      final fails = expectLater(pending, throwsA(isA<StateError>()));
      await c.dispose();
      await fails;
    });

    test('dispose stops draining as soon as nothing is pending', () async {
      final c = NitroCoalescer();
      final pending = c.submit((id, _) => c.sendPort.send(<int>[id, 7]));
      final sw = Stopwatch()..start();
      await c.dispose(drainTurns: 1000);
      sw.stop();
      expect(await pending, 7);
      // Must exit on the delivering turn, not burn all 1000.
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('partial batch: delivered ids complete, undelivered ones fail', () async {
      final c = NitroCoalescer();
      late int idA;
      final a = c.submit((id, _) => idA = id);
      final b = c.submit((_, _) {}); // never posted
      // Attach the error expectation BEFORE dispose: the failure fires during
      // dispose, and an error future with no handler yet is a zone crash.
      final bFails = expectLater(b, throwsA(isA<StateError>()));
      c.sendPort.send(<int>[idA, 11]); // only A is answered
      await c.dispose();
      expect(await a, 11);
      await bFails;
    });

    test('large burst: 64 in-flight results all survive dispose', () async {
      final c = NitroCoalescer();
      final futures = <Future<int>>[];
      final batch = <int>[];
      for (var i = 0; i < 64; i++) {
        futures.add(c.submit((id, _) => batch.addAll(<int>[id, id * 3])));
      }
      c.sendPort.send(batch); // one coalesced post carrying all 64
      await c.dispose();
      final results = await Future.wait(futures);
      expect(results, [for (var i = 0; i < 64; i++) i * 3]);
      expect(c.pendingCount, 0);
    });

    test('result arriving mid-drain still completes', () async {
      final c = NitroCoalescer();
      late int id;
      final f = c.submit((i, _) => id = i);
      // Post a few turns into the drain window, not before it.
      Future<void>.delayed(Duration.zero).then((_) {
        Future<void>.delayed(Duration.zero).then((_) => c.sendPort.send(<int>[id, 99]));
      });
      await c.dispose();
      expect(await f, 99);
    });

    test('drainTurns: 0 fails immediately without yielding', () async {
      final c = NitroCoalescer();
      final f = c.submit((id, _) => c.sendPort.send(<int>[id, 5]));
      final fails = expectLater(f, throwsA(isA<StateError>()));
      await c.dispose(drainTurns: 0); // no turn to deliver the queued post
      await fails;
    });

    test('dispose is idempotent', () async {
      final c = NitroCoalescer();
      await c.dispose();
      await c.dispose(); // must not throw on a closed port / cancelled sub
      await c.dispose();
    });

    test('submit after dispose throws instead of hanging', () async {
      final c = NitroCoalescer();
      await c.dispose();
      expect(() => c.submit((_, _) {}), throwsA(isA<StateError>()));
    });

    test('malformed batch: odd trailing element is ignored', () async {
      final c = NitroCoalescer();
      late int idA;
      final a = c.submit((id, _) => idA = id);
      c.sendPort.send(<int>[idA, 21, 999]); // dangling id with no value
      expect(await a, 21);
      await c.dispose();
    });

    test('duplicate callId in one batch completes once, does not throw', () async {
      final c = NitroCoalescer();
      late int idA;
      final a = c.submit((id, _) => idA = id);
      // Second pair for the same id must be a no-op, not a double-complete.
      c.sendPort.send(<int>[idA, 1, idA, 2]);
      expect(await a, 1);
      await c.dispose();
    });

    test('ids stay unique across many submits', () async {
      final c = NitroCoalescer();
      final ids = <int>{};
      final batch = <int>[];
      for (var i = 0; i < 200; i++) {
        c.submit((id, _) {
          ids.add(id);
          batch.addAll(<int>[id, id]);
        }).ignore();
      }
      expect(ids.length, 200);
      c.sendPort.send(batch);
      await c.dispose();
      expect(c.pendingCount, 0);
    });

    test('disposed coalescers are GC-collectable (no port/subscription leak)', () async {
      Future<WeakReference<Object>> makeAndDispose() async {
        final c = NitroCoalescer();
        // Register a pending completer, then drop it. dispose() now fails it,
        // so acknowledge the error — an unawaited error future is a zone crash.
        c.submit((_, _) {}).ignore();
        final w = WeakReference<Object>(c);
        await c.dispose();
        return w; // `c` goes out of scope here → collectable if not retained
      }

      final weaks = <WeakReference<Object>>[];
      for (var i = 0; i < 30; i++) {
        weaks.add(await makeAndDispose());
      }
      await forceGC(fullGcCycles: 3, timeout: const Duration(seconds: 10));
      final live = weaks.where((w) => w.target != null).length;
      expect(live, lessThan(8),
          reason: '$live/30 disposed coalescers still live — retained port/subscription');
    });
    // If the native call throws synchronously (a disposed handle, a bad
    // pointer, an out-of-memory arena) nothing on the other side ever sees the
    // id, so no batch can carry it. The slot used to stay in _pending and its
    // future only completed at dispose() — an await that hung indefinitely.
    group('a synchronous throw in the call must not leak the pending slot', () {
      test('the slot is released and the error propagates', () {
        final c = NitroCoalescer();
        addTearDown(c.dispose);
        expect(c.pendingCount, 0);

        expect(
          () => c.submit((id, port) => throw StateError('native call failed')),
          throwsA(isA<StateError>()),
        );
        expect(c.pendingCount, 0, reason: 'the pending slot outlived a call that never reached native');
      });

      test('later submits still get working ids after a failed one', () async {
        final c = NitroCoalescer();
        addTearDown(c.dispose);

        expect(() => c.submit((_, _) => throw StateError('boom')), throwsA(isA<StateError>()));

        final ids = <int>[];
        final f = c.submit((id, _) => ids.add(id));
        expect(c.pendingCount, 1);
        c.sendPort.send([ids.single, 99]);
        expect(await f, 99);
        expect(c.pendingCount, 0);
      });

      test('a failed submit does not disturb an in-flight one', () async {
        final c = NitroCoalescer();
        addTearDown(c.dispose);

        int? liveId;
        final live = c.submit((id, _) => liveId = id);
        expect(() => c.submit((_, _) => throw StateError('boom')), throwsA(isA<StateError>()));
        expect(c.pendingCount, 1, reason: 'only the live call should remain');

        c.sendPort.send([liveId!, 7]);
        expect(await live, 7);
      });
    });

  });
}
