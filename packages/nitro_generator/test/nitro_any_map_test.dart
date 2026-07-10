// Tests for NitroAnyMap — heterogeneous typed map (Gap 1 from RN Nitro AnyMap).
//
// Covers:
//   §1  Dart runtime: NitroAnyValue sealed class correctness
//   §2  Dart runtime: NitroAnyMap API (setters/getters/containment/merge)
//   §3  Dart runtime: binary round-trip (toNative → fromNative)
//   §4  Generator: NitroAnyMap recognized as anyMap BridgeTypeKind
//   §5  Generator: Dart FFI param uses Pointer<Uint8> (same as @HybridRecord)
//   §6  Generator: Dart FFI return decodes via NitroAnyMap.fromNative()
//   §7  Generator: Dart param encode uses .toNative(arena)
//   §8  Generator: Kotlin bridge uses NitroAnyMapCodec
//   §9  Generator: Kotlin bridge emits NitroAnyMapCodec helper object

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:nitro/src/nitro_any_value.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

BridgeSpec _anyMapReturnSpec() => BridgeSpec(
  dartClassName: 'AnyMapMod',
  lib: 'any_map_mod',
  namespace: 'any_map_mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'any_map_mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getMetadata',
      cSymbol: 'any_map_mod_get_metadata',
      isAsync: true,
      returnType: BridgeType(name: 'NitroAnyMap', isAnyMap: true, isFuture: true),
      params: [],
    ),
  ],
);

BridgeSpec _anyMapParamSpec() => BridgeSpec(
  dartClassName: 'AnyMapMod',
  lib: 'any_map_mod',
  namespace: 'any_map_mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'any_map_mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'configure',
      cSymbol: 'any_map_mod_configure',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'options',
          type: BridgeType(name: 'NitroAnyMap', isAnyMap: true),
        ),
      ],
    ),
  ],
);

// ── §1  NitroAnyValue sealed class ───────────────────────────────────────────

void main() {
  group('§1 NitroAnyValue — sealed class correctness', () {
    test('NitroAnyNull toDart returns null', () {
      expect(const NitroAnyNull().toDart(), isNull);
    });

    test('NitroAnyBool toDart returns bool', () {
      expect(NitroAnyBool(true).toDart(), isTrue);
      expect(NitroAnyBool(false).toDart(), isFalse);
    });

    test('NitroAnyInt toDart returns int', () {
      expect(NitroAnyInt(42).toDart(), 42);
      expect(NitroAnyInt(-1).toDart(), -1);
    });

    test('NitroAnyDouble toDart returns double', () {
      expect(NitroAnyDouble(3.14).toDart(), 3.14);
    });

    test('NitroAnyDouble preserves NaN (impossible in JSON)', () {
      final v = NitroAnyDouble(double.nan);
      expect((v.toDart() as double).isNaN, isTrue);
    });

    test('NitroAnyDouble preserves Infinity (impossible in JSON)', () {
      expect(NitroAnyDouble(double.infinity).toDart(), double.infinity);
    });

    test('NitroAnyString toDart returns String', () {
      expect(NitroAnyString('hello').toDart(), 'hello');
    });

    test('NitroAnyList toDart returns List', () {
      final v = NitroAnyList([NitroAnyInt(1), NitroAnyBool(false)]);
      final d = v.toDart() as List;
      expect(d, [1, false]);
    });

    test('NitroAnyObject toDart returns Map', () {
      final v = NitroAnyObject({'x': NitroAnyInt(7), 'y': NitroAnyString('hi')});
      final d = v.toDart() as Map;
      expect(d['x'], 7);
      expect(d['y'], 'hi');
    });

    test('NitroAnyValue.from(null) returns NitroAnyNull', () {
      expect(NitroAnyValue.from(null), isA<NitroAnyNull>());
    });

    test('NitroAnyValue.from(bool) returns NitroAnyBool', () {
      expect(NitroAnyValue.from(true), isA<NitroAnyBool>());
    });

    test('NitroAnyValue.from(int) returns NitroAnyInt', () {
      expect(NitroAnyValue.from(42), isA<NitroAnyInt>());
    });

    test('NitroAnyValue.from(double) returns NitroAnyDouble', () {
      expect(NitroAnyValue.from(3.14), isA<NitroAnyDouble>());
    });

    test('NitroAnyValue.from(String) returns NitroAnyString', () {
      expect(NitroAnyValue.from('hi'), isA<NitroAnyString>());
    });

    test('NitroAnyValue.from(List) returns NitroAnyList', () {
      expect(NitroAnyValue.from([1, 2, 3]), isA<NitroAnyList>());
    });

    test('NitroAnyValue.from(Map) returns NitroAnyObject', () {
      expect(NitroAnyValue.from({'a': 1}), isA<NitroAnyObject>());
    });

    test('NitroAnyValue.from(unsupported) throws', () {
      expect(() => NitroAnyValue.from(DateTime.now()), throwsArgumentError);
    });
  });

  // ── §2  NitroAnyMap API ──────────────────────────────────────────────────

  group('§2 NitroAnyMap — typed setters/getters/containment', () {
    late NitroAnyMap map;
    setUp(() => map = NitroAnyMap());

    test('setNull / isNull', () {
      map.setNull('k');
      expect(map.isNull('k'), isTrue);
      expect(map.isBool('k'), isFalse);
    });

    test('setBool / getBool', () {
      map.setBool('flag', true);
      expect(map.getBool('flag'), isTrue);
    });

    test('setInt / getInt', () {
      map.setInt('count', 99);
      expect(map.getInt('count'), 99);
    });

    test('setDouble / getDouble', () {
      map.setDouble('score', 7.5);
      expect(map.getDouble('score'), 7.5);
    });

    test('setString / getString', () {
      map.setString('name', 'nitro');
      expect(map.getString('name'), 'nitro');
    });

    test('setList / getList', () {
      map.setList('vals', [NitroAnyInt(1), NitroAnyInt(2)]);
      expect(map.getList('vals')?.length, 2);
    });

    test('setObject / getObject', () {
      final inner = NitroAnyMap();
      inner.setInt('x', 1);
      map.setObject('pos', inner);
      expect(map.getObject('pos')?.getInt('x'), 1);
    });

    test('contains / remove', () {
      map.setInt('n', 5);
      expect(map.contains('n'), isTrue);
      map.remove('n');
      expect(map.contains('n'), isFalse);
    });

    test('keys returns all keys', () {
      map.setInt('a', 1);
      map.setInt('b', 2);
      expect(map.keys.toSet(), {'a', 'b'});
    });

    test('clear removes all entries', () {
      map.setInt('a', 1);
      map.clear();
      expect(map.length, 0);
    });

    test('merge overlays keys from other map', () {
      map.setInt('a', 1);
      final other = NitroAnyMap();
      other.setInt('b', 2);
      other.setInt('a', 99); // overwrites
      map.merge(other);
      expect(map.getInt('a'), 99);
      expect(map.getInt('b'), 2);
    });

    test('fromDynamic converts plain Dart map', () {
      final m = NitroAnyMap.fromDynamic({'x': 1, 'y': true, 'z': 'hi'});
      expect(m.getInt('x'), 1);
      expect(m.getBool('y'), true);
      expect(m.getString('z'), 'hi');
    });

    test('toDynamic round-trips plain Dart map', () {
      map.setInt('n', 7);
      map.setString('s', 'abc');
      final d = map.toDynamic();
      expect(d['n'], 7);
      expect(d['s'], 'abc');
    });
  });

  // ── §3  Binary round-trip ────────────────────────────────────────────────

  group('§3 NitroAnyMap — binary round-trip via toNative/fromNative', () {
    NitroAnyMap roundTrip(NitroAnyMap original) {
      using((arena) {
        final ptr = original.toNative(arena);
        // copy to malloc so it survives arena scope
        final len = ptr.cast<Int32>().value + 4;
        final copy = malloc<Uint8>(len);
        for (var i = 0; i < len; i++) {
          copy[i] = ptr[i];
        }
        return NitroAnyMap.fromNative(copy);
      });
      // For simplicity, just encode and decode in one arena
      late NitroAnyMap result;
      using((arena) {
        final ptr = original.toNative(arena);
        // must copy before arena frees
        final len = ptr.cast<Int32>().value + 4;
        final copy = malloc<Uint8>(len);
        for (var i = 0; i < len; i++) {
          copy[i] = ptr[i];
        }
        result = NitroAnyMap.fromNative(copy);
        malloc.free(copy);
      });
      return result;
    }

    test('null value survives round-trip', () {
      final m = NitroAnyMap();
      m.setNull('k');
      expect(roundTrip(m).isNull('k'), isTrue);
    });

    test('bool value survives round-trip', () {
      final m = NitroAnyMap();
      m.setBool('flag', true);
      expect(roundTrip(m).getBool('flag'), isTrue);
    });

    test('int64 value survives round-trip', () {
      final m = NitroAnyMap();
      m.setInt('n', -9223372036854775807); // near Int64.min
      expect(roundTrip(m).getInt('n'), -9223372036854775807);
    });

    test('double NaN survives round-trip (impossible in JSON)', () {
      final m = NitroAnyMap();
      m.setDouble('nan', double.nan);
      expect(roundTrip(m).getDouble('nan')!.isNaN, isTrue);
    });

    test('double Infinity survives round-trip (impossible in JSON)', () {
      final m = NitroAnyMap();
      m.setDouble('inf', double.infinity);
      expect(roundTrip(m).getDouble('inf'), double.infinity);
    });

    test('string value survives round-trip', () {
      final m = NitroAnyMap();
      m.setString('s', 'hello 世界');
      expect(roundTrip(m).getString('s'), 'hello 世界');
    });

    test('nested list survives round-trip', () {
      final m = NitroAnyMap();
      m.setList('arr', [NitroAnyInt(1), NitroAnyInt(2), NitroAnyInt(3)]);
      final result = roundTrip(m).getList('arr')!;
      expect((result[0] as NitroAnyInt).value, 1);
      expect((result[2] as NitroAnyInt).value, 3);
    });

    test('nested object survives round-trip', () {
      final m = NitroAnyMap();
      final inner = NitroAnyMap();
      inner.setDouble('lat', 37.7749);
      inner.setDouble('lng', -122.4194);
      m.setObject('coords', inner);
      final result = roundTrip(m).getObject('coords')!;
      expect(result.getDouble('lat'), 37.7749);
      expect(result.getDouble('lng'), -122.4194);
    });

    test('multi-key heterogeneous map round-trips correctly', () {
      final m = NitroAnyMap();
      m.setNull('nothing');
      m.setBool('flag', false);
      m.setInt('count', 42);
      m.setDouble('score', 9.81);
      m.setString('name', 'nitro');
      final rt = roundTrip(m);
      expect(rt.isNull('nothing'), isTrue);
      expect(rt.getBool('flag'), false);
      expect(rt.getInt('count'), 42);
      expect(rt.getDouble('score'), 9.81);
      expect(rt.getString('name'), 'nitro');
    });

    test('empty map round-trips as empty map', () {
      final m = NitroAnyMap();
      expect(roundTrip(m).length, 0);
    });
  });

  // ── §4  BridgeTypeKind ───────────────────────────────────────────────────

  group('§4 Generator — NitroAnyMap BridgeTypeKind', () {
    test('isAnyMap flag sets kind to anyMap', () {
      final t = BridgeType(name: 'NitroAnyMap', isAnyMap: true);
      expect(t.kind, BridgeTypeKind.anyMap);
    });

    test('anyMap kind takes priority over map kind', () {
      final t = BridgeType(name: 'NitroAnyMap', isAnyMap: true, isMap: true);
      expect(t.kind, BridgeTypeKind.anyMap);
    });
  });

  // ── §5  Dart FFI param type ──────────────────────────────────────────────

  group('§5 Generator — Dart FFI uses Pointer<Uint8> for NitroAnyMap param', () {
    test('configure(_: NitroAnyMap) → Pointer<Uint8> in FFI signature', () {
      final out = DartFfiGenerator.generate(_anyMapParamSpec());
      expect(out, contains('Pointer<Uint8>'));
    });

    test('configure call site uses arena and .toNative(arena)', () {
      final out = DartFfiGenerator.generate(_anyMapParamSpec());
      expect(out, contains('toNative(arena)'));
    });
  });

  // ── §6  Dart FFI return decode ───────────────────────────────────────────

  group('§6 Generator — Dart FFI return decodes via NitroAnyMap.fromNative()', () {
    test('getMetadata returns NitroAnyMap in generated code', () {
      final out = DartFfiGenerator.generate(_anyMapReturnSpec());
      expect(out, contains('NitroAnyMap'));
    });

    test('getMetadata decode uses NitroAnyMap.fromNative', () {
      final out = DartFfiGenerator.generate(_anyMapReturnSpec());
      expect(out, contains('NitroAnyMap.fromNative('));
    });
  });

  // ── §7  Dart param encoding ──────────────────────────────────────────────

  group('§7 Generator — NitroAnyMap param encoded via .toNative(arena)', () {
    test('encode uses toNative not jsonEncode', () {
      final out = DartFfiGenerator.generate(_anyMapParamSpec());
      expect(out, contains('toNative'));
      expect(out, isNot(contains('jsonEncode')));
    });
  });

  // ── §8  Kotlin bridge uses NitroAnyMapCodec ──────────────────────────────

  group('§8 Generator — Kotlin bridge uses NitroAnyMapCodec', () {
    test('NitroAnyMap param decoded via NitroAnyMapCodec.decode()', () {
      final out = KotlinGenerator.generate(_anyMapParamSpec());
      expect(out, contains('NitroAnyMapCodec'));
    });

    test('NitroAnyMap return encoded via NitroAnyMapCodec.encode()', () {
      final out = KotlinGenerator.generate(_anyMapReturnSpec());
      expect(out, contains('NitroAnyMapCodec'));
    });
  });

  // ── §9  Kotlin codec helper is emitted ──────────────────────────────────

  group('§9 Generator — Kotlin bridge emits NitroAnyMapCodec helper', () {
    test('NitroAnyMapCodec object is emitted when anyMap type is used', () {
      final out = KotlinGenerator.generate(_anyMapReturnSpec());
      expect(out, contains('private object NitroAnyMapCodec'));
    });

    test('codec handles recursive AnyValue tags: null, bool, int, double, string, list, object', () {
      final out = KotlinGenerator.generate(_anyMapReturnSpec());
      expect(out, contains('ANY_NULL'));
      expect(out, contains('ANY_BOOL'));
      expect(out, contains('ANY_INT'));
      expect(out, contains('ANY_DOUBLE'));
      expect(out, contains('ANY_STRING'));
      expect(out, contains('ANY_LIST'));
      expect(out, contains('ANY_OBJECT'));
    });

    test('codec is NOT emitted when no anyMap types are used', () {
      // Spec with only plain int param — no NitroAnyMap
      final plainSpec = BridgeSpec(
        dartClassName: 'PlainMod',
        lib: 'plain_mod',
        namespace: 'plain_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'plain_mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'add',
            cSymbol: 'plain_mod_add',
            isAsync: false,
            returnType: BridgeType(name: 'int'),
            params: [
              BridgeParam(
                name: 'a',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = KotlinGenerator.generate(plainSpec);
      expect(out, isNot(contains('NitroAnyMapCodec')));
    });
  });

  // ── §10  Kotlin interface param/return type symmetry ─────────────────────

  group('§10 Generator — Kotlin interface param type matches return type', () {
    test('NitroAnyMap param uses Map<String, Any?> in the interface, not the generic Any? fallback', () {
      // Regression: retType() special-cased isAnyMap -> 'Map<String, Any?>'
      // but type() (which paramType() delegates to) didn't, so a NitroAnyMap
      // *parameter* fell through to the generic 'Any?' default — asymmetric
      // with the return type. Found via nitro_type_coverage's real plugin.
      final out = KotlinGenerator.generate(_anyMapParamSpec());
      expect(out, contains('fun configure(options: Map<String, Any?>)'));
      expect(out, isNot(contains('fun configure(options: Any?)')));
    });
  });
}
