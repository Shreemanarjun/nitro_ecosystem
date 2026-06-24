// Tests for Map<String, double> NaN/Infinity safe encoding in DartFfiGenerator.
// Issue #3: jsonEncode throws for NaN/Infinity — sentinel conversion needed.

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _doubleMapReturnSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getScores',
      cSymbol: 'foo_get_scores',
      isAsync: true,
      returnType: BridgeType(
        name: 'Map<String, double>',
        isRecord: true,
        isMap: true,
        isFuture: true,
      ),
      params: [],
    ),
  ],
);

BridgeSpec _doubleMapParamSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'setWeights',
      cSymbol: 'foo_set_weights',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'weights',
          type: BridgeType(
            name: 'Map<String, double>',
            isRecord: true,
            isMap: true,
          ),
        ),
      ],
    ),
  ],
);

BridgeSpec _nonDoubleMapSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getTags',
      cSymbol: 'foo_get_tags',
      isAsync: true,
      returnType: BridgeType(
        name: 'Map<String, String>',
        isRecord: true,
        isMap: true,
        isFuture: true,
      ),
      params: [],
    ),
  ],
);

void main() {
  group('DartFfiGenerator — Map<String, double> NaN/Infinity support (#3)', () {
    test('return type: uses _nitroDecodeDoubleMap for Map<String, double>', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('_nitroDecodeDoubleMap'));
    });

    test('return type: emits _nitroDecodeDoubleMap helper function', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('Map<String, double> _nitroDecodeDoubleMap'));
    });

    test('return type: emits _nitroEncodeDoubleMap helper function', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('String _nitroEncodeDoubleMap'));
    });

    test('return type: sentinel __NaN__ appears in decode helper', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains("'__NaN__'"));
    });

    test('return type: sentinel __Inf__ appears in decode helper', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains("'__Inf__'"));
    });

    test('return type: sentinel __NInf__ appears in decode helper', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains("'__NInf__'"));
    });

    test('return type: does NOT use plain .cast<String, double>()', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, isNot(contains('.cast<String, double>()')));
    });

    test('param type: uses _nitroEncodeDoubleMap for Map<String, double> param', () {
      final out = DartFfiGenerator.generate(_doubleMapParamSpec());
      expect(out, contains('_nitroEncodeDoubleMap(weights)'));
    });

    test('param type: uses toNativeUtf8 after _nitroEncodeDoubleMap', () {
      final out = DartFfiGenerator.generate(_doubleMapParamSpec());
      expect(out, contains('_nitroEncodeDoubleMap(weights).toNativeUtf8'));
    });

    test('param type: does NOT use plain jsonEncode for Map<String, double>', () {
      final out = DartFfiGenerator.generate(_doubleMapParamSpec());
      expect(out, isNot(contains('jsonEncode(weights)')));
    });

    test('non-double map: does not emit double map helpers for Map<String, String>', () {
      final out = DartFfiGenerator.generate(_nonDoubleMapSpec());
      expect(out, isNot(contains('_nitroEncodeDoubleMap')));
      expect(out, isNot(contains('_nitroDecodeDoubleMap')));
    });

    test('decode helper uses double.nan for __NaN__', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('double.nan'));
    });

    test('decode helper uses double.infinity for __Inf__', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('double.infinity'));
    });

    test('decode helper uses double.negativeInfinity for __NInf__', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('double.negativeInfinity'));
    });

    test('encode helper uses v.isNaN for NaN detection', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('v.isNaN'));
    });

    test('encode helper uses v.isInfinite for Infinity detection', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('v.isInfinite'));
    });
  });
}
