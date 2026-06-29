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
  group('DartFfiGenerator — Map<String, double> NaN/Infinity support (#7 binary encoding)', () {
    // With binary map encoding (#7), NaN/Infinity are encoded as IEEE 754 float64
    // natively — no sentinel strings needed. The old JSON+sentinel approach is gone.

    test('return type: uses binary decode helper for Map<String, double>', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('_nitroDecodeMapBinaryDouble'));
    });

    test('return type: emits binary map helper function (not old sentinel helper)', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('_nitroDecodeMapBinaryDouble'));
      // Old sentinel helpers are gone — binary handles NaN/Inf natively.
      expect(out, isNot(contains('_nitroDecodeDoubleMap')));
      expect(out, isNot(contains("'__NaN__'")));
    });

    test('return type: function pointer uses Pointer<Uint8> not Pointer<Utf8> (binary)', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      // The map-specific function pointer uses Pointer<Uint8> (binary), not Pointer<Utf8> (JSON).
      expect(out, contains('Pointer<Uint8> Function(int) _getScoresPtr'));
      expect(out, isNot(contains('Pointer<Utf8> Function() _getScoresPtr')));
    });

    test('return type: does NOT use plain .cast<String, double>()', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, isNot(contains('.cast<String, double>()')));
    });

    test('return type: does NOT use jsonDecode', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, isNot(contains('jsonDecode')));
    });

    test('param type: uses binary encode helper for Map<String, double>', () {
      final out = DartFfiGenerator.generate(_doubleMapParamSpec());
      expect(out, contains('_nitroEncodeMapBinaryDouble'));
    });

    test('param type: does NOT use toNativeUtf8 (binary uses alloc + Uint8)', () {
      final out = DartFfiGenerator.generate(_doubleMapParamSpec());
      // toNativeUtf8 appears in the _init constructor for the instance key; check only the setWeights body.
      final setIdx = out.indexOf('_setWeightsPtr(');
      expect(setIdx, isNot(-1), reason: 'setWeights method call not found');
      final methodBody = out.substring(setIdx, setIdx + 300);
      expect(methodBody, isNot(contains('toNativeUtf8')));
    });

    test('param type: does NOT use plain jsonEncode for Map<String, double>', () {
      final out = DartFfiGenerator.generate(_doubleMapParamSpec());
      expect(out, isNot(contains('jsonEncode(weights)')));
    });

    test('non-double map: emits binary helpers for Map<String, String> (not double)', () {
      final out = DartFfiGenerator.generate(_nonDoubleMapSpec());
      expect(out, contains('_nitroEncodeMapBinaryString'));
      // Not the double-specific ones
      expect(out, isNot(contains('_nitroEncodeMapBinaryDouble')));
      expect(out, isNot(contains('_nitroEncodeDoubleMap')));
    });

    test('binary decode helper uses getFloat64 for NaN/Inf-safe float decoding', () {
      final out = DartFfiGenerator.generate(_doubleMapReturnSpec());
      expect(out, contains('getFloat64'));
    });

    test('binary encode helper uses setFloat64 for NaN/Inf-safe float encoding', () {
      final out = DartFfiGenerator.generate(_doubleMapParamSpec());
      expect(out, contains('setFloat64'));
    });
  });
}
