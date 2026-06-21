// Tests for optional named parameter support in DartFfiGenerator.
//
// Covers the pattern:
//   @nitroAsync
//   Future<void> startCapture(int sampleRate, {String? outputFile});
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _optionalStringParamSpec() => BridgeSpec(
  dartClassName: 'Recorder',
  lib: 'recorder',
  namespace: 'recorder',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'recorder.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'startCapture',
      cSymbol: 'recorder_start_capture',
      isAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'sampleRate',
          type: BridgeType(name: 'int'),
        ),
        BridgeParam(
          name: 'outputFile',
          type: BridgeType(name: 'String?'),
          isNamed: true,
          isOptional: true,
        ),
      ],
    ),
  ],
);

BridgeSpec _allNamedOptionalSpec() => BridgeSpec(
  dartClassName: 'Filter',
  lib: 'filter',
  namespace: 'filter',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'filter.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'apply',
      cSymbol: 'filter_apply',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'intensity',
          type: BridgeType(name: 'double'),
          isNamed: true,
          isOptional: true,
        ),
      ],
    ),
  ],
);

void main() {
  group('DartFfiGenerator — optional named params', () {
    test('method signature wraps named params in curly braces', () {
      final out = DartFfiGenerator.generate(_optionalStringParamSpec());
      expect(out, contains('startCapture(int sampleRate, {String? outputFile})'));
    });

    test('all-named-param method signature has only curly braces (no leading comma)', () {
      final out = DartFfiGenerator.generate(_allNamedOptionalSpec());
      expect(out, contains('apply({double intensity})'));
      expect(out, isNot(contains('apply(, {')));
    });

    test('nullable String? arg uses null-check with nullptr fallback', () {
      final out = DartFfiGenerator.generate(_optionalStringParamSpec());
      expect(out, contains('outputFile != null ? outputFile.toNativeUtf8(allocator: arena) : nullptr'));
    });

    test('nullable String? param triggers arena allocation', () {
      final out = DartFfiGenerator.generate(_optionalStringParamSpec());
      expect(out, contains('final arena = Arena()'));
      expect(out, contains('arena.releaseAll()'));
    });

    test('FFI type for nullable String? is still Pointer<Utf8>', () {
      final out = DartFfiGenerator.generate(_optionalStringParamSpec());
      // String? → Pointer<Utf8> in the native type signature
      expect(out, contains('Pointer<Utf8>'));
    });

    test('non-nullable positional int param is not wrapped in braces', () {
      final out = DartFfiGenerator.generate(_optionalStringParamSpec());
      // sampleRate is positional — must not be inside {}
      expect(out, isNot(contains('{int sampleRate')));
    });
  });
}
