// Tests for NitroPromise<T> — composable async type (Gap 3 from RN Nitro Promise<T>).
//
// Covers:
//   §1  State lifecycle (pending → resolved / pending → rejected)
//   §2  Multi-subscriber listeners
//   §3  .then<R>() chaining (sync transform)
//   §4  .andThen<R>() chaining (async transform)
//   §5  .catchError() recovery
//   §6  Static factories: resolved, rejected, async_
//   §7  NitroPromise.all — all-or-nothing aggregate
//   §8  NitroPromise.race — first-wins

import 'package:nitro/src/nitro_promise.dart';
import 'package:test/test.dart';

void main() {
  // ── §1  State lifecycle ────────────────────────────────────────────────────

  group('§1 State lifecycle', () {
    test('starts in pending state', () {
      final p = NitroPromise<int>();
      expect(p.state, NitroPromiseState.pending);
    });

    test('resolve transitions to resolved state', () {
      final p = NitroPromise<int>();
      p.resolve(42);
      expect(p.state, NitroPromiseState.resolved);
    });

    test('reject transitions to rejected state', () {
      final p = NitroPromise<int>()..reject(Exception('fail'));
      expect(p.state, NitroPromiseState.rejected);
    });

    test('resolve exposes value via future', () async {
      final p = NitroPromise<int>();
      p.resolve(7);
      expect(await p.future, 7);
    });

    test('reject exposes error via future', () async {
      final p = NitroPromise<int>()..reject(Exception('boom'));
      await expectLater(p.future, throwsA(isA<Exception>()));
    });

    test('double resolve is a no-op (first value wins)', () async {
      final p = NitroPromise<int>()..resolve(1)..resolve(2);
      expect(await p.future, 1);
      expect(p.state, NitroPromiseState.resolved);
    });

    test('double reject is a no-op (first error wins)', () async {
      final err1 = Exception('first');
      final err2 = Exception('second');
      final p = NitroPromise<int>()..reject(err1)..reject(err2);
      await expectLater(p.future, throwsA(same(err1)));
    });

    test('resolve after reject is a no-op', () {
      final p = NitroPromise<int>()..reject(Exception('fail'))..resolve(99);
      expect(p.state, NitroPromiseState.rejected);
    });

    test('reject after resolve is a no-op', () {
      final p = NitroPromise<int>()..resolve(5)..reject(Exception('too late'));
      expect(p.state, NitroPromiseState.resolved);
    });
  });

  // ── §2  Multi-subscriber listeners ────────────────────────────────────────

  group('§2 Multi-subscriber listeners', () {
    test('multiple addOnResolvedListener all receive the value', () async {
      final p = NitroPromise<int>();
      final received = <int>[];
      p.addOnResolvedListener((v) => received.add(v));
      p.addOnResolvedListener((v) => received.add(v * 2));
      p.resolve(10);
      await p.future;
      expect(received, containsAll([10, 20]));
    });

    test('addOnResolvedListener added after resolve fires immediately', () async {
      final p = NitroPromise<int>()..resolve(3);
      var called = false;
      p.addOnResolvedListener((_) => called = true);
      await Future.microtask(() => null);
      expect(called, isTrue);
    });

    test('addOnRejectedListener fires on reject', () async {
      final p = NitroPromise<int>();
      Object? caught;
      p.addOnRejectedListener((e, _) => caught = e);
      final err = Exception('oops');
      p.reject(err);
      await Future.microtask(() => null).catchError((_) {});
      await Future.microtask(() => null);
      expect(caught, same(err));
    });

    test('multiple addOnRejectedListener all fire', () async {
      final p = NitroPromise<int>();
      final caught = <Object>[];
      p.addOnRejectedListener((e, _) => caught.add(e));
      p.addOnRejectedListener((e, _) => caught.add(e));
      p.reject(Exception('fail'));
      // wait for listeners to fire
      await Future.delayed(const Duration(milliseconds: 10));
      expect(caught.length, 2);
    });
  });

  // ── §3  .then<R>() chaining ────────────────────────────────────────────────

  group('§3 .then<R>() sync chaining', () {
    test('transforms resolved value', () async {
      final p = NitroPromise<int>();
      final doubled = p.then((v) => v * 2);
      p.resolve(5);
      expect(await doubled.future, 10);
    });

    test('propagates rejection through chain', () async {
      final p = NitroPromise<int>();
      final chained = p.then((v) => v + 1);
      p.reject(Exception('upstream'));
      await expectLater(chained.future, throwsA(isA<Exception>()));
    });

    test('chains can be nested', () async {
      final p = NitroPromise<int>();
      final chain = p.then((v) => v + 1).then((v) => v * 3);
      p.resolve(4); // (4+1)*3 = 15
      expect(await chain.future, 15);
    });
  });

  // ── §4  .andThen<R>() async chaining ──────────────────────────────────────

  group('§4 .andThen<R>() async chaining', () {
    test('chains an async transform', () async {
      final p = NitroPromise<int>();
      final async_ = p.andThen((v) async => v * 10);
      p.resolve(3);
      expect(await async_.future, 30);
    });

    test('propagates async rejection', () async {
      final p = NitroPromise<int>();
      final chained = p.andThen((v) async => throw Exception('async fail'));
      p.resolve(1);
      await expectLater(chained.future, throwsA(isA<Exception>()));
    });

    test('upstream rejection propagates through andThen', () async {
      final p = NitroPromise<int>();
      final chained = p.andThen((v) async => v + 1);
      p.reject(Exception('upstream'));
      await expectLater(chained.future, throwsA(isA<Exception>()));
    });
  });

  // ── §5  .catchError() recovery ────────────────────────────────────────────

  group('§5 .catchError() recovery', () {
    test('converts rejection into resolved value', () async {
      final p = NitroPromise<int>();
      final recovered = p.catchError((_) => 0);
      p.reject(Exception('fail'));
      expect(await recovered.future, 0);
    });

    test('does not affect already-resolved promise', () async {
      final p = NitroPromise<int>();
      final guarded = p.catchError((_) => -1);
      p.resolve(42);
      expect(await guarded.future, 42);
    });
  });

  // ── §6  Static factories ──────────────────────────────────────────────────

  group('§6 Static factories', () {
    test('NitroPromise.resolved returns immediately resolved promise', () async {
      final p = NitroPromise.resolved(99);
      expect(p.state, NitroPromiseState.resolved);
      expect(await p.future, 99);
    });

    test('NitroPromise.rejected returns immediately rejected promise', () async {
      final p = NitroPromise.rejected<int>(Exception('pre-failed'));
      expect(p.state, NitroPromiseState.rejected);
      await expectLater(p.future, throwsA(isA<Exception>()));
    });

    test('NitroPromise.async_ wraps a Future computation', () async {
      final p = NitroPromise.async_(() async {
        await Future.delayed(Duration.zero);
        return 7;
      });
      expect(await p.future, 7);
    });

    test('NitroPromise.async_ captures thrown errors', () async {
      final p = NitroPromise.async_<int>(() async => throw Exception('async err'));
      await expectLater(p.future, throwsA(isA<Exception>()));
    });
  });

  // ── §7  NitroPromise.all ──────────────────────────────────────────────────

  group('§7 NitroPromise.all', () {
    test('resolves when all promises resolve', () async {
      final a = NitroPromise<int>()..resolve(1);
      final b = NitroPromise<int>()..resolve(2);
      final c = NitroPromise<int>()..resolve(3);
      final all = NitroPromise.all([a, b, c]);
      expect(await all.future, [1, 2, 3]);
    });

    test('preserves order of results', () async {
      final a = NitroPromise<int>();
      final b = NitroPromise<int>();
      final all = NitroPromise.all([a, b]);
      b.resolve(20); // b resolves first
      a.resolve(10);
      expect(await all.future, [10, 20]);
    });

    test('rejects when any promise rejects', () async {
      final a = NitroPromise<int>()..resolve(1);
      final b = NitroPromise<int>()..reject(Exception('one failed'));
      final all = NitroPromise.all([a, b]);
      await expectLater(all.future, throwsA(isA<Exception>()));
    });

    test('empty list resolves immediately to empty list', () async {
      final all = NitroPromise.all<int>([]);
      expect(await all.future, isEmpty);
    });
  });

  // ── §8  NitroPromise.race ─────────────────────────────────────────────────

  group('§8 NitroPromise.race', () {
    test('resolves with the first resolved value', () async {
      final a = NitroPromise<String>();
      final b = NitroPromise<String>();
      final race = NitroPromise.race([a, b]);
      b.resolve('b wins');
      a.resolve('a wins');
      expect(await race.future, 'b wins');
    });

    test('rejects if the first to settle rejects', () async {
      final a = NitroPromise<String>();
      final b = NitroPromise<String>();
      final race = NitroPromise.race([a, b]);
      a.reject(Exception('a failed first'));
      await expectLater(race.future, throwsA(isA<Exception>()));
    });

    test('winner resolve beats later reject', () async {
      final a = NitroPromise<int>()..resolve(1);
      final b = NitroPromise<int>()..reject(Exception('late fail'));
      final race = NitroPromise.race([a, b]);
      expect(await race.future, 1);
    });
  });
}
