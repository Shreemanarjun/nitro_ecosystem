// Tests for NitroAnyValue / NitroAnyMap — the dynamically-typed value used for
// AnyMap parameters and returns.
//
// It is a sealed union over 7 cases (null, bool, int64, float64, string, array,
// object) that crosses the bridge as a binary blob, so the properties that
// matter are: `from` accepts exactly what it claims, `toDart` is its inverse,
// nesting survives, and the typed accessors do not silently coerce.
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  group('NitroAnyValue.from', () {
    test('maps each supported Dart type to its case', () {
      expect(NitroAnyValue.from(null), isA<NitroAnyNull>());
      expect(NitroAnyValue.from(true), isA<NitroAnyBool>());
      expect(NitroAnyValue.from(42), isA<NitroAnyInt>());
      expect(NitroAnyValue.from(3.5), isA<NitroAnyDouble>());
      expect(NitroAnyValue.from('s'), isA<NitroAnyString>());
      expect(NitroAnyValue.from(<Object?>[]), isA<NitroAnyList>());
      expect(NitroAnyValue.from(<String, Object?>{}), isA<NitroAnyObject>());
    });

    test('throws on an unsupported type rather than coercing it', () {
      expect(() => NitroAnyValue.from(DateTime(2020)),
          throwsA(isA<ArgumentError>()));
      expect(() => NitroAnyValue.from(#symbol), throwsA(isA<ArgumentError>()));
    });

    test('int and double stay distinct — no numeric widening', () {
      expect(NitroAnyValue.from(1), isA<NitroAnyInt>());
      expect(NitroAnyValue.from(1.0), isA<NitroAnyDouble>(),
          reason: '1.0 must not collapse to int; the wire types differ');
    });

    test('converts nested lists and maps recursively', () {
      final v = NitroAnyValue.from({
        'list': [1, 'two', null],
        'nested': {'deep': true},
      });
      expect(v, isA<NitroAnyObject>());
      expect(v.toDart(), {
        'list': [1, 'two', null],
        'nested': {'deep': true},
      });
    });

    test('stringifies non-String map keys', () {
      final v = NitroAnyValue.from({1: 'a', true: 'b'});
      expect(v.toDart(), {'1': 'a', 'true': 'b'});
    });
  });

  group('toDart round-trip', () {
    test('is the inverse of from for representative values', () {
      const samples = <Object?>[
        null,
        true,
        false,
        0,
        -1,
        9223372036854775807, // int64 max
        1.5,
        -0.0,
        '',
        'unicode ⚡ 日本語',
      ];
      for (final s in samples) {
        expect(NitroAnyValue.from(s).toDart(), s, reason: 'round-trip of $s');
      }
    });

    test('preserves empty containers', () {
      expect(NitroAnyValue.from(<Object?>[]).toDart(), <Object?>[]);
      expect(NitroAnyValue.from(<String, Object?>{}).toDart(),
          <String, Object?>{});
    });

    test('preserves deeply nested structure', () {
      final deep = {
        'a': [
          {
            'b': [
              {'c': 1}
            ]
          }
        ]
      };
      expect(NitroAnyValue.from(deep).toDart(), deep);
    });

    test('round-trips special doubles', () {
      expect(NitroAnyValue.from(double.infinity).toDart(), double.infinity);
      expect(
          NitroAnyValue.from(double.negativeInfinity).toDart(),
          double.negativeInfinity);
      expect((NitroAnyValue.from(double.nan).toDart() as double).isNaN, isTrue);
    });
  });

  group('NitroAnyMap', () {
    test('typed setters and getters agree', () {
      final m = NitroAnyMap()
        ..setNull('n')
        ..setBool('b', true)
        ..setInt('i', 7)
        ..setDouble('d', 1.5)
        ..setString('s', 'x');

      expect(m.isNull('n'), isTrue);
      expect(m.getBool('b'), isTrue);
      expect(m.getInt('i'), 7);
      expect(m.getDouble('d'), 1.5);
      expect(m.getString('s'), 'x');
      expect(m.length, 5);
    });

    // A typed getter must not coerce across cases — an int read as a string
    // would silently corrupt data crossing the bridge.
    test('a typed getter returns null for a mismatched case', () {
      final m = NitroAnyMap()..setInt('i', 7);
      expect(m.getString('i'), isNull);
      expect(m.getBool('i'), isNull);
      expect(m.getDouble('i'), isNull);
      expect(m.getInt('i'), 7);
    });

    test('getters return null for a missing key', () {
      final m = NitroAnyMap();
      expect(m.getInt('nope'), isNull);
      expect(m.get('nope'), isNull);
      expect(m.contains('nope'), isFalse);
    });

    test('is-checks discriminate the cases', () {
      final m = NitroAnyMap()
        ..setNull('n')
        ..setInt('i', 1);
      expect(m.isNull('n'), isTrue);
      expect(m.isInt('n'), isFalse);
      expect(m.isInt('i'), isTrue);
      expect(m.isNull('i'), isFalse);
    });

    test('remove and clear', () {
      final m = NitroAnyMap()
        ..setInt('a', 1)
        ..setInt('b', 2);
      m.remove('a');
      expect(m.contains('a'), isFalse);
      expect(m.length, 1);
      m.clear();
      expect(m.length, 0);
      expect(m.keys, isEmpty);
    });

    test('setObject copies — later edits do not alias the stored value', () {
      final inner = NitroAnyMap()..setInt('v', 1);
      final outer = NitroAnyMap()..setObject('o', inner);

      inner.setInt('v', 999); // must not affect what was stored
      expect(outer.getObject('o')!.getInt('v'), 1,
          reason: 'setObject must snapshot, not alias');
    });

    test('fromDynamic and toDynamic round-trip', () {
      final src = <String, dynamic>{
        'i': 1,
        'd': 2.5,
        's': 'x',
        'b': false,
        'n': null,
        'list': [1, 2],
        'obj': {'k': 'v'},
      };
      expect(NitroAnyMap.fromDynamic(src).toDynamic(), src);
    });

    test('overwriting a key replaces its case', () {
      final m = NitroAnyMap()..setInt('k', 1);
      expect(m.getInt('k'), 1);
      m.setString('k', 'now a string');
      expect(m.getInt('k'), isNull);
      expect(m.getString('k'), 'now a string');
      expect(m.length, 1);
    });
  });
}
