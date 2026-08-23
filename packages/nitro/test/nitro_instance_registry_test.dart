// Tests for NitroInstanceRegistry — the Dart-side map from native instance IDs
// to live impl objects, used to resolve an AnyNativeObject back to its concrete
// type without a native round-trip.
//
// The registry holds WeakReferences and attaches a Finalizer, so the behaviour
// worth pinning down is lifetime: entries must disappear on unregister AND on
// garbage collection, and a stale ID must never resolve to a live object.
import 'package:leak_tracker/leak_tracker.dart';
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

class _Impl {
  _Impl(this.tag);
  final String tag;
}

class _OtherImpl {}

void main() {
  group('NitroInstanceRegistry', () {
    test('resolves a registered instance with its concrete type', () {
      final impl = _Impl('a');
      NitroInstanceRegistry.register(1, impl);
      addTearDown(() => NitroInstanceRegistry.unregister(1, impl));

      final resolved = NitroInstanceRegistry.resolve<_Impl>(
        const AnyNativeObject(1),
      );
      expect(identical(resolved, impl), isTrue);
      expect(resolved!.tag, 'a');
    });

    test('resolve returns null for an id that was never registered', () {
      expect(
        NitroInstanceRegistry.resolve<_Impl>(const AnyNativeObject(9999)),
        isNull,
      );
    });

    test('unregister removes the entry', () {
      final impl = _Impl('b');
      NitroInstanceRegistry.register(2, impl);
      expect(NitroInstanceRegistry.resolve<_Impl>(const AnyNativeObject(2)),
          isNotNull);

      NitroInstanceRegistry.unregister(2, impl);
      expect(
        NitroInstanceRegistry.resolve<_Impl>(const AnyNativeObject(2)),
        isNull,
      );
    });

    test('unregister is safe to call twice', () {
      final impl = _Impl('c');
      NitroInstanceRegistry.register(3, impl);
      NitroInstanceRegistry.unregister(3, impl);
      expect(() => NitroInstanceRegistry.unregister(3, impl), returnsNormally);
    });

    test('re-registering an id replaces the previous instance', () {
      final first = _Impl('first');
      final second = _Impl('second');
      NitroInstanceRegistry.register(4, first);
      NitroInstanceRegistry.register(4, second);
      addTearDown(() => NitroInstanceRegistry.unregister(4, second));

      final resolved = NitroInstanceRegistry.resolve<_Impl>(
        const AnyNativeObject(4),
      );
      expect(identical(resolved, second), isTrue,
          reason: 'the newer registration must win');
    });

    test('distinct ids resolve independently', () {
      final a = _Impl('a');
      final b = _Impl('b');
      NitroInstanceRegistry.register(5, a);
      NitroInstanceRegistry.register(6, b);
      addTearDown(() {
        NitroInstanceRegistry.unregister(5, a);
        NitroInstanceRegistry.unregister(6, b);
      });

      expect(NitroInstanceRegistry.resolve<_Impl>(const AnyNativeObject(5))!.tag,
          'a');
      expect(NitroInstanceRegistry.resolve<_Impl>(const AnyNativeObject(6))!.tag,
          'b');
    });

    // The registry exists so a dropped impl does not pin native memory. If the
    // finalizer stopped firing, entries would accumulate for the process
    // lifetime — the leak this class was introduced to fix.
    test('an instance dropped without unregister is collected and evicted',
        () async {
      const count = 30;
      final refs = <WeakReference<Object>>[];
      for (var i = 0; i < count; i++) {
        final impl = _Impl('gc$i');
        NitroInstanceRegistry.register(1000 + i, impl);
        refs.add(WeakReference<Object>(impl));
      }

      await forceGC();

      final live = refs.where((r) => r.target != null).length;
      expect(live, lessThan(8),
          reason: 'registry must hold only weak references; $live/$count '
              'instances still live after GC');

      // Every collected instance must also be gone from the registry, not just
      // from the heap — a resolve on a stale id would otherwise hand back an
      // object the caller believes is alive.
      var resolvable = 0;
      for (var i = 0; i < count; i++) {
        if (NitroInstanceRegistry.resolve<_Impl>(AnyNativeObject(1000 + i)) !=
            null) {
          resolvable++;
        }
      }
      expect(resolvable, lessThan(8),
          reason: '$resolvable/$count stale ids still resolve after GC');
    });

    // Documents the current contract for a type mismatch. resolve<T> performs
    // `as T?`, so asking for the wrong type throws rather than returning null.
    // Pinned deliberately: whichever behaviour is chosen, it should be chosen.
    test('resolving with a mismatched type throws (does not return null)', () {
      final impl = _Impl('typed');
      NitroInstanceRegistry.register(7, impl);
      addTearDown(() => NitroInstanceRegistry.unregister(7, impl));

      expect(
        () => NitroInstanceRegistry.resolve<_OtherImpl>(
          const AnyNativeObject(7),
        ),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('AnyNativeObject', () {
    test('equality and hashCode are by instanceId', () {
      expect(const AnyNativeObject(3), const AnyNativeObject(3));
      expect(const AnyNativeObject(3).hashCode, const AnyNativeObject(3).hashCode);
      expect(const AnyNativeObject(3), isNot(const AnyNativeObject(4)));
    });

    test('rejects a negative instanceId', () {
      expect(() => AnyNativeObject(-1), throwsA(isA<AssertionError>()));
    });

    test('id 0 is valid — it is the legacy single-impl slot', () {
      expect(() => AnyNativeObject(0), returnsNormally);
    });
  });
    // Native hands the same instance id to a NEW object once the old one is
    // destroyed. The GC finalizer removed the entry by id unconditionally, so
    // when the dead object's finalizer eventually ran it evicted the LIVE
    // entry and resolve() returned null for an object that was alive.
    group('id reuse', () {
      test('re-registering an id resolves to the NEW instance', () {
        final first = _Impl('first');
        NitroInstanceRegistry.register(90, first);
        final second = _Impl('second');
        NitroInstanceRegistry.register(90, second);
        addTearDown(() => NitroInstanceRegistry.unregister(90, second));

        final resolved = NitroInstanceRegistry.resolve<_Impl>(const AnyNativeObject(90));
        expect(identical(resolved, second), isTrue);
        expect(resolved!.tag, 'second');
      });

      test('a collected instance does not evict the live entry that reused its id', () async {
        NitroInstanceRegistry.register(91, _Impl('dead'));
        // Drop the only strong reference and force collection so the dead
        // object's finalizer is queued.
        await forceGC();

        final live = _Impl('live');
        NitroInstanceRegistry.register(91, live);
        addTearDown(() => NitroInstanceRegistry.unregister(91, live));

        // Give any pending finalizer callback a chance to run.
        await forceGC();
        await Future<void>.delayed(Duration.zero);

        final resolved = NitroInstanceRegistry.resolve<_Impl>(const AnyNativeObject(91));
        expect(resolved, isNotNull, reason: 'the dead instance\'s finalizer evicted the live entry');
        expect(identical(resolved, live), isTrue);
      });
    });

}
