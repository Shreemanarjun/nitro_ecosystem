import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';

/// Tests for Gap #3 — `Map<int, V>` and `Map<Enum, V>` map key types.
void main() {
  group('BridgeType.extractMapKeyType', () {
    test('extracts String from Map<String, V>', () {
      expect(BridgeType.extractMapKeyType('Map<String, int>'), 'String');
    });

    test('extracts int from Map<int, V>', () {
      expect(BridgeType.extractMapKeyType('Map<int, String>'), 'int');
    });

    test('extracts int32 from Map<int32, V>', () {
      expect(BridgeType.extractMapKeyType('Map<int32, double>'), 'int32');
    });

    test('extracts uint64 from Map<uint64, V>', () {
      expect(BridgeType.extractMapKeyType('Map<uint64, bool>'), 'uint64');
    });

    test('extracts enum name from Map<Status, V>', () {
      expect(BridgeType.extractMapKeyType('Map<Status, String>'), 'Status');
    });

    test('returns null for non-map type names', () {
      expect(BridgeType.extractMapKeyType('List<int>'), isNull);
      expect(BridgeType.extractMapKeyType('String'), isNull);
      expect(BridgeType.extractMapKeyType('int'), isNull);
    });
  });

  group('SpecValidator E001 — int-key map (Gap #3)', () {
    BridgeSpec mapSpec(BridgeType mapType) => BridgeSpec(
          dartClassName: 'Cache',
          lib: 'cache',
          namespace: 'cache',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'cache.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'getAll',
              cSymbol: 'cache_get_all',
              isAsync: false,
              returnType: mapType,
              params: [],
            ),
          ],
        );

    test('E001 is NOT emitted for Map<int, String>', () {
      final issues = SpecValidator.validate(
        mapSpec(BridgeType(name: 'Map<int, String>')),
      );
      final e001 = issues.where((i) => i.code == 'E001').toList();
      expect(e001, isEmpty);
    });

    test('E001 is NOT emitted for Map<int32, double>', () {
      final issues = SpecValidator.validate(
        mapSpec(BridgeType(name: 'Map<int32, double>')),
      );
      final e001 = issues.where((i) => i.code == 'E001').toList();
      expect(e001, isEmpty);
    });

    test('E001 is NOT emitted for Map<uint32, bool>', () {
      final issues = SpecValidator.validate(
        mapSpec(BridgeType(name: 'Map<uint32, bool>')),
      );
      final e001 = issues.where((i) => i.code == 'E001').toList();
      expect(e001, isEmpty);
    });

    test('E001 is NOT emitted for Map<int64, String>', () {
      final issues = SpecValidator.validate(
        mapSpec(BridgeType(name: 'Map<int64, String>')),
      );
      final e001 = issues.where((i) => i.code == 'E001').toList();
      expect(e001, isEmpty);
    });

    test('E001 is NOT emitted for Map<@HybridEnum, V>', () {
      final spec = BridgeSpec(
        dartClassName: 'Cache',
        lib: 'cache',
        namespace: 'cache',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'cache.native.dart',
        enums: [
          BridgeEnum(name: 'CacheKey', startValue: 0, values: ['fast', 'slow']),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getAll',
            cSymbol: 'cache_get_all',
            isAsync: false,
            returnType: BridgeType(name: 'Map<CacheKey, String>'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final e001 = issues.where((i) => i.code == 'E001').toList();
      expect(e001, isEmpty);
    });

    test('E001 IS still emitted for Map<bool, V> (unsupported key)', () {
      final issues = SpecValidator.validate(
        mapSpec(BridgeType(name: 'Map<bool, String>')),
      );
      final e001 = issues.where((i) => i.code == 'E001').toList();
      expect(e001, isNotEmpty);
    });

    test('E001 is NOT emitted for Map<int, V> param', () {
      final spec = BridgeSpec(
        dartClassName: 'Cache',
        lib: 'cache',
        namespace: 'cache',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'cache.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'setAll',
            cSymbol: 'cache_set_all',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'data',
                type: BridgeType(name: 'Map<int, String>'),
              ),
            ],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final e001 = issues.where((i) => i.code == 'E001').toList();
      expect(e001, isEmpty);
    });
  });

  group('DartFfiGenerator.generateIntKeyMapHelpers', () {
    final emptySpec = BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mod.native.dart',
    );

    test('Map<int, String> encode uses setInt64 for 8-byte key', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int', 'String', emptySpec);
      expect(out, contains('setInt64'));
      expect(out, contains('getInt64'));
    });

    test('Map<int, String> encode emits utf8.encode for string value', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int', 'String', emptySpec);
      expect(out, contains('utf8.encode(e.value)'));
      expect(out, contains('utf8.decode('));
    });

    test('Map<int32, double> encode uses setInt32 for 4-byte key', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int32', 'double', emptySpec);
      expect(out, contains('setInt32'));
      expect(out, contains('getInt32'));
    });

    test('Map<int32, double> encode uses setFloat64 for double value', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int32', 'double', emptySpec);
      expect(out, contains('setFloat64'));
      expect(out, contains('getFloat64'));
    });

    test('Map<uint64, bool> encode uses setUint64 for 8-byte unsigned key', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('uint64', 'bool', emptySpec);
      expect(out, contains('setUint64'));
      expect(out, contains('getUint64'));
    });

    test('Map<int, int> encode uses two setInt64 calls (key + value)', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int', 'int', emptySpec);
      // Should contain setInt64 at least twice: once for key, once for value
      final count = RegExp('setInt64').allMatches(out).length;
      expect(count, greaterThanOrEqualTo(2));
    });

    test('Map<int, bool> encode uses addByte for bool value', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int', 'bool', emptySpec);
      expect(out, contains('bb.addByte(e.value ? 1 : 0)'));
      expect(out, contains('bd.getUint8(pos) != 0'));
    });

    test('encode function name contains key and value type suffixes', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int', 'String', emptySpec);
      expect(out, contains('_nitroEncodeIntKeyMapBinaryIntString'));
      expect(out, contains('_nitroDecodeIntKeyMapBinaryIntString'));
    });

    test('Map<int32, double> function name uses Int32Double suffix', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int32', 'double', emptySpec);
      expect(out, contains('_nitroEncodeIntKeyMapBinaryInt32Double'));
      expect(out, contains('_nitroDecodeIntKeyMapBinaryInt32Double'));
    });

    test('int16 key uses setInt16 / getInt16 (2-byte key)', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int16', 'int', emptySpec);
      expect(out, contains('setInt16'));
      expect(out, contains('getInt16'));
    });

    test('generated encode returns Pointer<Uint8>', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int', 'String', emptySpec);
      expect(out, contains('Pointer<Uint8> _nitroEncodeIntKeyMapBinaryIntString('));
    });

    test('generated decode returns Map<int, String>', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int', 'String', emptySpec);
      expect(out, contains('Map<int, String> _nitroDecodeIntKeyMapBinaryIntString('));
    });

    test('wire format: payload length prefix is present (4-byte count)', () {
      final out = DartFfiGenerator.generateIntKeyMapHelpers('int', 'bool', emptySpec);
      // Decode: reads 4-byte count
      expect(out, contains('bd.getInt32(pos, Endian.little)'));
    });
  });
}
