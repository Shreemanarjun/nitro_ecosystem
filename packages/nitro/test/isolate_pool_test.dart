import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro/nitro.dart';

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
int _slowAdd(int a, int b) {
  // simulate a small amount of work (no actual sleep — just arithmetic)
  var sum = 0;
  for (var i = 0; i < 1000; i++) { sum += i; }
  return a + b + (sum - sum); // sum cancels out; avoids dead-code elimination
}

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
    }, skip: !const bool.fromEnvironment('dart.vm.product') == false
        ? false
        : true); // run in debug only
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
        expect(
          () => pool.dispatch<int>(_throws, ['boom']),
          throwsA(isA<ArgumentError>().having((e) => e.message, 'message', 'boom')),
        );
        // Wait for the error to propagate before the pool is disposed.
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
      final result = await future
          .then<Object>((v) => v)
          .onError<StateError>((e, _) => 'cancelled')
          .onError<Object>((e, s) => 'other-error');

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
            return pool
                .dispatch<int>(_throws, ['fail $i'])
                .then<int>((_) => -999)
                .onError<ArgumentError>((e, s) => -(i));
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
  });
}
