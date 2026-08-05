// NitroPromise behavior — added alongside the #36/PR-#38 change (lazily
// allocated listener lists; the proposed Completer.sync() was REJECTED because
// it made un-awaited rejections surface as unhandled errors — the
// "reject without awaiting" case here is what proved that). No promise tests
// existed before; these lock the semantics: first-wins settling, listener
// firing, chaining, factories, and that a continuation which re-enters
// resolve()/reject() is a safe no-op (the first-wins guard runs before any
// listener).
import 'dart:async';
import 'package:nitro/src/nitro_promise.dart';
import 'package:test/test.dart';

void main() {
  group('resolve / reject basics', () {
    test('resolve completes the future with the value', () async {
      final p = NitroPromise<int>();
      p.resolve(42);
      expect(p.isResolved, isTrue);
      expect(await p.future, 42);
    });

    test('reject completes the future with the error', () async {
      final p = NitroPromise<int>();
      p.reject(StateError('boom'));
      expect(p.isRejected, isTrue);
      await expectLater(p.future, throwsA(isA<StateError>()));
    });

    test('first-wins: a second resolve/reject is a no-op', () async {
      final p = NitroPromise<int>();
      p.resolve(1);
      p.resolve(2); // ignored
      p.reject(StateError('late')); // ignored
      expect(await p.future, 1);
    });

    test('pending state before settling', () {
      final p = NitroPromise<int>();
      expect(p.isPending, isTrue);
      expect(p.isResolved, isFalse);
      expect(p.isRejected, isFalse);
      expect(p.state, NitroPromiseState.pending);
    });

    test('a resolved promise with no listeners still delivers (lazy null list)',
        () async {
      // Exercises the `_resolvedListeners == null` path — the common case
      // where the promise is only awaited via .future.
      final p = NitroPromise<String>();
      p.resolve('ok');
      expect(await p.future, 'ok');
    });
  });

  group('sync completer — reentrancy safety', () {
    test('a continuation that re-enters resolve() is a safe no-op', () async {
      final p = NitroPromise<int>();
      var reentered = 0;
      // With Completer.sync, this .then may run synchronously at complete()
      // time. Re-entering resolve() must hit the first-wins guard, not recurse.
      p.future.then((v) {
        reentered++;
        p.resolve(999); // must be ignored — already resolved
        p.reject(StateError('x')); // must be ignored
      });
      p.resolve(7);
      expect(await p.future, 7);
      expect(reentered, 1);
    });

    test('await resumes with the resolved value (no lost completion)', () async {
      final p = NitroPromise<int>();
      Timer.run(() => p.resolve(5));
      expect(await p.future, 5);
    });

    test('reject without awaiting does not surface as unhandled', () async {
      // The no-op suppressor in reject() must swallow the "unhandled" error.
      final p = NitroPromise<int>();
      p.reject(StateError('nobody awaits me'));
      // Give the microtask queue a chance to flag an unhandled error.
      await Future<void>.delayed(Duration.zero);
      // Now attach a handler — the error is still observable on demand.
      await expectLater(p.future, throwsA(isA<StateError>()));
    });
  });

  group('listeners', () {
    test('addOnResolvedListener fires on later resolve', () async {
      final p = NitroPromise<int>();
      final got = <int>[];
      p.addOnResolvedListener(got.add);
      p.addOnResolvedListener((v) => got.add(v * 10));
      p.resolve(3);
      expect(got, [3, 30]);
    });

    test('addOnRejectedListener fires on later reject', () async {
      final p = NitroPromise<int>();
      Object? seen;
      p.addOnRejectedListener((e, _) => seen = e);
      final err = StateError('nope');
      p.reject(err);
      expect(seen, same(err));
    });

    test('resolved promise: rejection listeners never fire', () async {
      final p = NitroPromise<int>();
      p.resolve(1);
      var called = false;
      p.addOnRejectedListener((_, _) => called = true);
      await Future<void>.delayed(Duration.zero);
      expect(called, isFalse);
    });

    test('adding a resolved listener after resolution fires it (async)',
        () async {
      final p = NitroPromise<int>();
      p.resolve(8);
      final c = Completer<int>();
      p.addOnResolvedListener(c.complete);
      expect(await c.future, 8);
    });
  });

  group('chaining', () {
    test('then transforms the value', () async {
      final p = NitroPromise<int>();
      final mapped = p.then((v) => v + 1);
      p.resolve(41);
      expect(await mapped.future, 42);
    });

    test('then propagates rejection', () async {
      final p = NitroPromise<int>();
      final mapped = p.then((v) => v + 1);
      p.reject(StateError('e'));
      await expectLater(mapped.future, throwsA(isA<StateError>()));
    });

    test('andThen chains an async transform', () async {
      final p = NitroPromise<int>();
      final chained = p.andThen((v) async => 'v=$v');
      p.resolve(9);
      expect(await chained.future, 'v=9');
    });

    test('catchError recovers from a rejection', () async {
      final p = NitroPromise<int>();
      final recovered = p.catchError((_) => -1);
      p.reject(StateError('fail'));
      expect(await recovered.future, -1);
    });
  });

  group('static factories', () {
    test('resolved()', () async {
      expect(await NitroPromise.resolved<int>(11).future, 11);
    });

    test('rejected()', () async {
      await expectLater(
          NitroPromise.rejected<int>(StateError('x')).future, throwsA(isA<StateError>()));
    });

    test('async_ completes from a Future', () async {
      final p = NitroPromise.async_<int>(() async => 21);
      expect(await p.future, 21);
    });

    test('all() waits for every promise', () async {
      final a = NitroPromise<int>()..resolve(1);
      final b = NitroPromise<int>();
      Timer.run(() => b.resolve(2));
      final combined = NitroPromise.all<int>([a, b]);
      expect(await combined.future, [1, 2]);
    });

    test('all() rejects if any rejects', () async {
      final a = NitroPromise<int>()..resolve(1);
      final b = NitroPromise<int>()..reject(StateError('one failed'));
      final combined = NitroPromise.all<int>([a, b]);
      await expectLater(combined.future, throwsA(isA<StateError>()));
    });
  });
}
