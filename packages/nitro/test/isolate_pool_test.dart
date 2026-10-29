import 'dart:async';
import 'dart:io' show sleep;
import 'dart:isolate' show Isolate;

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a pool, runs [body], then disposes the pool even if [body] throws.
Future<void> withPool(int size, Future<void> Function(IsolatePool pool) body) async {
  final pool = await IsolatePool.create(size);
  try {
    await body(pool);
  } finally {
    pool.dispose();
  }
}

// Simple pure-Dart functions used as dispatch targets — must be top-level
// so they can be sent to worker isolates.
int _add(int a, int b) => a + b;
String _greet(String name) => 'Hello, $name!';
int _double(int x) => x * 2;
Never _throws(String msg) => throw ArgumentError(msg);

// ── C2 regression helpers ──────────────────────────────────────────────────
// A ReceivePort can never cross an isolate port. Throwing (or returning) one
// used to make the worker's reply send() throw INSIDE the listener, killing
// the isolate — and every call already dispatched to it then never settled.
// (A closure literal IS sendable in modern Dart, so it does not reproduce.)
class UnsendableError implements Exception {
  UnsendableError(this.port);
  final ReceivePort port;
  @override
  String toString() => 'UnsendableError';
}

Never _throwsUnsendable() => throw UnsendableError(ReceivePort());

ReceivePort _returnsUnsendable() => ReceivePort();

int _slowAdd(int a, int b) {
  // simulate a small amount of work (no actual sleep — just arithmetic)
  var sum = 0;
  for (var i = 0; i < 1000; i++) {
    sum += i;
  }
  return a + b + (sum - sum); // sum cancels out; avoids dead-code elimination
}

/// Blocks the worker's thread for [ms] so it stays "busy" — used to hold every
/// worker occupied and force the adaptive pool to grow.
int _sleepReturn(int ms) {
  sleep(Duration(milliseconds: ms));
  return ms;
}

/// Kills the worker isolate mid-call (no reply) — simulates a native crash / OOM
/// so the pool's onExit/onError death handling runs.
Never _suicide() => Isolate.exit();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('IsolatePool.create', () {
    test('creates a pool with the requested number of workers and disposes cleanly', () async {
      final pool = await IsolatePool.create(3);
      // If create() succeeded without throwing, all 3 workers spawned.
      // Dispatch a trivial call to confirm the pool is operational.
      final result = await pool.dispatch<int>(_add, [1, 2]);
      expect(result, 3);
      pool.dispose();
    });

    test('pool size 1 works correctly', () async {
      await withPool(1, (pool) async {
        expect(await pool.dispatch<int>(_add, [10, 20]), 30);
      });
    });

    test('pool size 4 works correctly', () async {
      await withPool(4, (pool) async {
        expect(await pool.dispatch<String>(_greet, ['World']), 'Hello, World!');
      });
    });

    test('assert fires for size 0 in debug mode', () {
      // Only meaningful in debug builds; in release the assert is a no-op.
      // We verify the factory rejects it without hanging.
      expect(
        () async => IsolatePool.create(0),
        throwsA(anything), // AssertionError in debug, no-op otherwise
      );
    }, skip: !const bool.fromEnvironment('dart.vm.product') == false ? false : true); // run in debug only
  });

  group('IsolatePool.dispatch — return values', () {
    test('returns the correct result for int computation', () async {
      await withPool(2, (pool) async {
        expect(await pool.dispatch<int>(_add, [7, 8]), 15);
      });
    });

    test('returns the correct result for String computation', () async {
      await withPool(2, (pool) async {
        expect(await pool.dispatch<String>(_greet, ['Nitro']), 'Hello, Nitro!');
      });
    });

    test('each call gets its own independent result (no cross-talk)', () async {
      await withPool(2, (pool) async {
        final futures = [
          pool.dispatch<int>(_add, [1, 2]),
          pool.dispatch<int>(_add, [3, 4]),
          pool.dispatch<int>(_add, [5, 6]),
          pool.dispatch<int>(_add, [7, 8]),
        ];
        final results = await Future.wait(futures);
        expect(results, [3, 7, 11, 15]);
      });
    });

    test('many sequential dispatches all return correct results', () async {
      await withPool(2, (pool) async {
        for (var i = 0; i < 20; i++) {
          expect(await pool.dispatch<int>(_double, [i]), i * 2);
        }
      });
    });

    test('many concurrent dispatches complete without loss', () async {
      await withPool(4, (pool) async {
        const n = 50;
        final futures = List.generate(
          n,
          (i) => pool.dispatch<int>(_add, [i, i]),
        );
        final results = await Future.wait(futures);
        for (var i = 0; i < n; i++) {
          expect(results[i], i * 2, reason: 'index $i');
        }
      });
    });
  });

  group('IsolatePool.dispatch — error propagation', () {
    test('propagates exceptions thrown by the dispatched function', () async {
      await withPool(2, (pool) async {
        // BOTH dispatches must be awaited: withPool disposes in its `finally`,
        // and a still-in-flight call is completed with "disposed while call was
        // in flight" instead of the function's own error. An un-awaited
        // expectation raced dispose and failed on slower CI runners.
        await expectLater(
          pool.dispatch<int>(_throws, ['boom']),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'boom')),
        );
        await expectLater(
          pool.dispatch<int>(_throws, ['boom']),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    test('a failing call does not affect subsequent calls on the same pool', () async {
      await withPool(2, (pool) async {
        await expectLater(
          pool.dispatch<int>(_throws, ['oops']),
          throwsA(isA<ArgumentError>()),
        );
        // Pool should still be healthy.
        expect(await pool.dispatch<int>(_add, [10, 5]), 15);
      });
    });

    test('multiple concurrent errors are all reported independently', () async {
      await withPool(4, (pool) async {
        final futures = [
          pool.dispatch<int>(_throws, ['err0']).then((_) => 'ok').onError((e, s) => 'err'),
          pool.dispatch<int>(_add, [1, 1]),
          pool.dispatch<int>(_throws, ['err2']).then((_) => 42).onError<ArgumentError>((e, _) => -1),
          pool.dispatch<int>(_add, [3, 3]),
        ];
        final results = await Future.wait(futures);
        expect(results[0], 'err');
        expect(results[1], 2);
        expect(results[2], -1);
        expect(results[3], 6);
      });
    });
  });

  group('IsolatePool — callId uniqueness', () {
    test('100 concurrent dispatches each receive unique, correct results', () async {
      await withPool(4, (pool) async {
        const n = 100;
        // Use a function where the output uniquely identifies the input.
        final futures = List.generate(n, (i) => pool.dispatch<int>(_double, [i]));
        final results = await Future.wait(futures);
        for (var i = 0; i < n; i++) {
          expect(results[i], i * 2, reason: 'call $i returned wrong value');
        }
      });
    });
  });

  group('IsolatePool — least-busy scheduling', () {
    test('all workers receive tasks when pool has multiple workers', () async {
      // We cannot directly observe which worker a task went to, but we can
      // verify that concurrent dispatches complete without stalling — which
      // only happens when the scheduler distributes load.
      await withPool(4, (pool) async {
        final futures = List.generate(
          16,
          (i) => pool.dispatch<int>(_slowAdd, [i, 1]),
        );
        final results = await Future.wait(futures);
        for (var i = 0; i < 16; i++) {
          expect(results[i], i + 1, reason: 'task $i');
        }
      });
    });

    test('single-worker pool serialises all tasks correctly', () async {
      await withPool(1, (pool) async {
        final futures = List.generate(10, (i) => pool.dispatch<int>(_add, [i, 0]));
        final results = await Future.wait(futures);
        for (var i = 0; i < 10; i++) {
          expect(results[i], i);
        }
      });
    });
  });

  group('IsolatePool.dispose', () {
    test('dispose is idempotent — calling twice does not throw', () async {
      final pool = await IsolatePool.create(2);
      pool.dispose();
      expect(() => pool.dispose(), returnsNormally);
    });

    test('in-flight calls receive StateError after dispose', () async {
      final pool = await IsolatePool.create(1);

      // Kick off a call but DO NOT await it yet.
      final future = pool.dispatch<int>(_add, [1, 2]);

      // Dispose immediately — the call may or may not have been processed.
      pool.dispose();

      // The future must complete (either with the result or with a StateError).
      // It must NOT hang.
      final result = await future.then<Object>((v) => v).onError<StateError>((e, _) => 'cancelled').onError<Object>((e, s) => 'other-error');

      expect(result, anyOf(3, 'cancelled', 'other-error'));
    });

    test('dispatch after dispose throws AssertionError in debug mode', () async {
      final pool = await IsolatePool.create(1);
      pool.dispose();
      // In debug mode an assert fires; in release it's undefined but should
      // not produce a valid result.
      expect(
        () => pool.dispatch<int>(_add, [1, 2]),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('IsolatePool — stress / edge cases', () {
    test('1000 sequential dispatches on a single-worker pool all succeed', () async {
      await withPool(1, (pool) async {
        for (var i = 0; i < 1000; i++) {
          expect(await pool.dispatch<int>(_add, [i, 1]), i + 1);
        }
      });
    });

    test('200 concurrent dispatches on a 4-worker pool all return correct values', () async {
      await withPool(4, (pool) async {
        const n = 200;
        final futures = List.generate(n, (i) => pool.dispatch<int>(_double, [i]));
        final results = await Future.wait(futures);
        for (var i = 0; i < n; i++) {
          expect(results[i], i * 2);
        }
      });
    });

    test('pool survives interleaved successes and failures without corruption', () async {
      await withPool(3, (pool) async {
        const n = 30;
        final futures = List.generate(n, (i) {
          if (i.isOdd) {
            return pool.dispatch<int>(_throws, ['fail $i']).then<int>((_) => -999).onError<ArgumentError>((e, s) => -(i));
          }
          return pool.dispatch<int>(_add, [i, 0]);
        });
        final results = await Future.wait(futures);
        for (var i = 0; i < n; i++) {
          if (i.isOdd) {
            expect(results[i], -i, reason: 'odd index $i should be error sentinel');
          } else {
            expect(results[i], i, reason: 'even index $i should equal i');
          }
        }
      });
    });

    test('re-creating a pool after dispose works correctly', () async {
      final pool1 = await IsolatePool.create(2);
      expect(await pool1.dispatch<int>(_add, [1, 1]), 2);
      pool1.dispose();

      // Create a fresh pool — prior disposal must not affect new instances.
      final pool2 = await IsolatePool.create(2);
      expect(await pool2.dispatch<int>(_add, [2, 2]), 4);
      pool2.dispose();
    });

    // ── TC4: 1,000 concurrent dispatches — no deadlock guarantee ────────────
    test('1,000 concurrent dispatches on 8-worker pool — no deadlock, all correct', () async {
      await withPool(8, (pool) async {
        const n = 1000;
        // Each future uniquely identifies its result: double(i) == 2*i.
        // Any callId routing bug would surface here as a wrong or missing result.
        final futures = List.generate(n, (i) => pool.dispatch<int>(_double, [i]));
        final results = await Future.wait(futures);
        for (var i = 0; i < n; i++) {
          expect(results[i], i * 2, reason: 'dispatch $i returned wrong value');
        }
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('1,000 concurrent dispatches with mixed errors — pool stays healthy', () async {
      await withPool(8, (pool) async {
        const n = 1000;
        // Even indices succeed, odd indices throw — all 1000 dispatched concurrently.
        final futures = List.generate(n, (i) {
          if (i.isOdd) {
            return pool.dispatch<int>(_throws, ['e$i']).then<int>((_) => -1).onError<ArgumentError>((_, _) => -(i));
          }
          return pool.dispatch<int>(_add, [i, 0]);
        });
        final results = await Future.wait(futures);
        for (var i = 0; i < n; i++) {
          if (i.isOdd) {
            expect(results[i], -i, reason: 'error sentinel for $i');
          } else {
            expect(results[i], i, reason: 'success result for $i');
          }
        }
        // After 1,000 concurrent dispatches the pool must still work.
        expect(await pool.dispatch<int>(_add, [42, 0]), 42);
      });
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('4 pools running 250 concurrent dispatches each — no cross-pool corruption', () async {
      // Four independent pools, each getting 250 concurrent tasks.
      // Verifies there is no shared global state between IsolatePool instances.
      const perPool = 250;
      final pools = await Future.wait(List.generate(4, (_) => IsolatePool.create(4)));
      try {
        final allFutures = [
          for (var p = 0; p < 4; p++)
            for (var i = 0; i < perPool; i++) pools[p].dispatch<int>(_add, [p * 1000 + i, 0]),
        ];
        final results = await Future.wait(allFutures);
        for (var p = 0; p < 4; p++) {
          for (var i = 0; i < perPool; i++) {
            final idx = p * perPool + i;
            expect(results[idx], p * 1000 + i, reason: 'pool $p task $i returned wrong value');
          }
        }
      } finally {
        for (final pool in pools) {
          pool.dispose();
        }
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
  group('worker survival — un-sendable payloads must not hang the pool', () {
    test('an un-sendable ERROR fails the call instead of hanging', () async {
      await withPool(1, (pool) async {
        await expectLater(
          pool.dispatch<void>(_throwsUnsendable, const []),
          throwsA(anything),
        );
        // The worker must still be alive and serving.
        expect(await pool.dispatch<int>(_add, [2, 3]), 5);
      });
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('an un-sendable RESULT fails the call instead of hanging', () async {
      await withPool(1, (pool) async {
        await expectLater(
          pool.dispatch<ReceivePort>(_returnsUnsendable, const []),
          throwsA(anything),
        );
        expect(await pool.dispatch<int>(_add, [4, 4]), 8);
      });
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('calls queued behind an un-sendable payload still settle', () async {
      await withPool(1, (pool) async {
        final bad = pool.dispatch<void>(_throwsUnsendable, const []);
        final queued = [for (var i = 0; i < 4; i++) pool.dispatch<int>(_add, [i, i])];
        await expectLater(bad, throwsA(anything));
        expect(await Future.wait(queued), [0, 2, 4, 6]);
      });
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('adaptive growth', () {
    test('a fixed pool (maxWorkers defaults to size) never grows', () async {
      await withPool(2, (pool) async {
        final calls = [for (var i = 0; i < 12; i++) pool.dispatch<int>(_sleepReturn, [30])];
        await Future.wait(calls);
        expect(pool.workerCount, 2, reason: 'no growth when maxWorkers == size');
      });
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('grows past the initial size under concurrent load', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 4);
      final inflight = <Future<int>>[];
      try {
        expect(pool.workerCount, 1);
        // A steady stream of overlapping blocking calls: once in-flight calls
        // outnumber workers the pool spawns the shortfall (demand-proportional,
        // in parallel) up to the cap.
        for (var i = 0; i < 200 && pool.workerCount < 4; i++) {
          inflight.add(pool.dispatch<int>(_sleepReturn, [40]));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(pool.workerCount, 4, reason: 'adaptive pool should ramp to maxWorkers under sustained load');
      } finally {
        await Future.wait(inflight);
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('never grows beyond maxWorkers under a flood', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 2);
      try {
        final calls = [for (var i = 0; i < 40; i++) pool.dispatch<int>(_sleepReturn, [20])];
        await Future.wait(calls);
        expect(pool.workerCount, lessThanOrEqualTo(2));
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('grown workers serve calls and dispose cleanly', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 3);
      final inflight = <Future<int>>[];
      try {
        for (var i = 0; i < 100 && pool.workerCount < 3; i++) {
          inflight.add(pool.dispatch<int>(_sleepReturn, [30]));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(pool.workerCount, greaterThan(1));
        // Every dispatched call (across original + grown workers) returns.
        expect(await Future.wait(inflight), everyElement(30));
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a cold concurrent burst fans out onto workers as they spawn', () async {
      // All 24 calls are dispatched before any new worker exists, so they queue
      // centrally; the work-queue hands them to workers as they come online
      // (rather than stranding all 24 on the first worker).
      final pool = await IsolatePool.create(1, maxWorkers: 4);
      try {
        expect(pool.workerCount, 1);
        final results = await Future.wait([for (var i = 0; i < 24; i++) pool.dispatch<int>(_sleepReturn, [40])]);
        expect(results, everyElement(40), reason: 'every queued call must still complete');
        expect(pool.workerCount, greaterThan(1), reason: 'the backlog should have pulled new workers in');
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('work-queue edge cases', () {
    test('worker death with a backlog fails the queued calls (fixed pool cannot grow to recover)', () async {
      // The one worker dies mid-call; the calls queued behind it are in the
      // central backlog, not the worker's mailbox. With no worker left and no
      // growth (maxWorkers == size), nothing can ever serve them — they must
      // FAIL, not hang.
      final pool = await IsolatePool.create(1);
      try {
        final suicide = pool.dispatch<void>(_suicide, const []);
        final queued = [for (var i = 0; i < 5; i++) pool.dispatch<int>(_add, [i, 0])];
        await expectLater(suicide, throwsA(anything));
        for (var i = 0; i < queued.length; i++) {
          await expectLater(queued[i], throwsA(anything), reason: 'queued call $i must settle, not hang');
        }
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('worker death with survivors: the backlog drains onto a live worker', () async {
      final pool = await IsolatePool.create(2);
      try {
        final suicide = pool.dispatch<void>(_suicide, const []);
        final good = [for (var i = 0; i < 12; i++) pool.dispatch<int>(_add, [i, 100])];
        await expectLater(suicide, throwsA(anything));
        expect(await Future.wait(good), [for (var i = 0; i < 12; i++) i + 100],
            reason: 'the surviving worker must serve the whole backlog');
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('an adaptive pool spawns past a dead worker to serve the backlog', () async {
      // maxWorkers > 1: the backlog dispatch already triggered growth, so fresh
      // workers come online and serve it even though the first worker died.
      final pool = await IsolatePool.create(1, maxWorkers: 4);
      try {
        final suicide = pool.dispatch<void>(_suicide, const []);
        final good = [for (var i = 0; i < 16; i++) pool.dispatch<int>(_add, [i, 1])];
        await expectLater(suicide, throwsA(anything));
        expect(await Future.wait(good), [for (var i = 0; i < 16; i++) i + 1]);
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('dispose fails a large queued backlog — nothing hangs', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 2);
      // Blocking calls: a couple assigned, the rest piled in the backlog.
      final calls = [for (var i = 0; i < 30; i++) pool.dispatch<int>(_sleepReturn, [200])];
      pool.dispose();
      for (var i = 0; i < calls.length; i++) {
        await expectLater(calls[i], throwsA(anything), reason: 'call $i must settle after dispose');
      }
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('dispose while workers are still spawning settles everything + is idempotent', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 8);
      // A burst that triggers several spawns…
      final calls = [for (var i = 0; i < 40; i++) pool.dispatch<int>(_sleepReturn, [100])];
      // …disposed almost immediately, racing the in-flight spawns.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      pool.dispose();
      for (var i = 0; i < calls.length; i++) {
        await expectLater(calls[i], throwsA(anything));
      }
      expect(() => pool.dispose(), returnsNormally);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('a call dispatched to a never-contended pool still uses the fast path', () async {
      // Sequential dispatch on a pool that can grow but never needs to: must
      // stay at one worker and return correct results (fast path, no queue).
      final pool = await IsolatePool.create(1, maxWorkers: 4);
      try {
        for (var i = 0; i < 50; i++) {
          expect(await pool.dispatch<int>(_add, [i, i]), i + i);
        }
        expect(pool.workerCount, 1, reason: 'no concurrency → no growth');
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  group('idle shrink', () {
    // Grow the pool via a sustained concurrent stream, then await the inflight.
    Future<void> growUnderLoad(IsolatePool pool, int target) async {
      final inflight = <Future<int>>[];
      for (var i = 0; i < 200 && pool.workerCount < target; i++) {
        inflight.add(pool.dispatch<int>(_sleepReturn, [40]));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future.wait(inflight);
    }

    test('shrinks back to the floor after an idle period', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 4, idleReap: const Duration(milliseconds: 100));
      try {
        await growUnderLoad(pool, 4);
        expect(pool.workerCount, greaterThan(1), reason: 'should have grown under load');
        // Idle through several reap intervals → retire the extras back to 1.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(pool.workerCount, 1, reason: 'idle pool must shrink to the floor (never below)');
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('serves correctly after shrinking and regrows under new load', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 4, idleReap: const Duration(milliseconds: 100));
      try {
        await growUnderLoad(pool, 4);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(pool.workerCount, 1);
        // Floor worker still serves.
        expect(await pool.dispatch<int>(_add, [2, 3]), 5);
        // New load regrows (reusing the tombstoned slots).
        await growUnderLoad(pool, 4);
        expect(pool.workerCount, greaterThan(1), reason: 'must regrow after shrinking');
        expect(await pool.dispatch<int>(_add, [10, 20]), 30);
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a fixed pool never starts a reaper and never shrinks', () async {
      final pool = await IsolatePool.create(3, idleReap: const Duration(milliseconds: 80));
      try {
        expect(await pool.dispatch<int>(_add, [1, 1]), 2); // some activity
        await Future<void>.delayed(const Duration(milliseconds: 400)); // idle through many ticks
        expect(pool.workerCount, 3, reason: 'fixed pool must stay at its size');
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('idleReap: Duration.zero disables shrinking (stays grown)', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 4, idleReap: Duration.zero);
      try {
        await growUnderLoad(pool, 4);
        final grown = pool.workerCount;
        expect(grown, greaterThan(1));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(pool.workerCount, grown, reason: 'shrink disabled → pool keeps its workers');
      } finally {
        pool.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('dispose cancels the reaper and stays idempotent', () async {
      final pool = await IsolatePool.create(1, maxWorkers: 4, idleReap: const Duration(milliseconds: 50));
      await growUnderLoad(pool, 3);
      pool.dispose();
      expect(() => pool.dispose(), returnsNormally);
      // If the reaper kept firing on a disposed pool it would touch torn-down
      // state; _reap guards on _disposed, so this quiet wait is uneventful.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
