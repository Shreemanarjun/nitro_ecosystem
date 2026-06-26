// Tests for Map<String, @HybridRecord> bridging via BINARY encoding (#7).
//
// With #7: Maps use binary Pointer<Uint8> (same as @HybridRecord), replacing JSON.
// A Map<String, V> bridges as a binary buffer — faster, handles NaN/Inf, type-safe.

import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _mapRecordReturnSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getDevices',
      cSymbol: 'foo_get_devices',
      isAsync: true,
      returnType: BridgeType(
        name: 'Map<String, Device>',
        isRecord: true,
        isMap: true,
        isFuture: true,
      ),
      params: [],
    ),
  ],
);

BridgeSpec _mapRecordParamSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'configure',
      cSymbol: 'foo_configure',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'settings',
          type: BridgeType(
            name: 'Map<String, Settings>',
            isRecord: true,
            isMap: true,
          ),
        ),
      ],
    ),
  ],
);

void main() {
  group('DartFfiGenerator — Map<String, @HybridRecord> return type', () {
    test('uses Pointer<Uint8> for the getDevices FFI function pointer (binary)', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('Pointer<Uint8> Function() _getDevicesPtr'));
    });

    test('decodes via binary helper', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('_nitroDecodeMapBinaryDevice'));
      // Top-level decode uses binary — jsonDecode may appear internally for dynamic fallback
      expect(out, isNot(contains('_nitroDecodeMapBinaryDevice(res.toDartString')));
    });

    test('does NOT use binary RecordExt path (fromNative / fromReader)', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      // isMap takes precedence over isRecord — RecordExt is skipped for map values
      expect(out, isNot(contains('RecordExt')));
    });

    test('getDevices function appears in generated output', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('getDevices'));
    });
  });

  group('DartFfiGenerator — Map<String, @HybridRecord> parameter', () {
    test('uses binary encode helper for map param', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('_nitroEncodeMapBinarySettings'));
    });

    test('does NOT use toNativeUtf8 (binary uses alloc)', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, isNot(contains('toNativeUtf8')));
    });

    test('does NOT use binary RecordExt for the map param', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, isNot(contains('RecordExt')));
    });

    test('param FFI signature uses Pointer<Uint8> for map type (binary)', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      // Map param uses Pointer<Uint8> in the function pointer declaration.
      expect(out, contains('Pointer<Uint8>'));
      // The configure function pointer does NOT use Pointer<Utf8> for the map arg.
      expect(out, isNot(contains('Pointer<Utf8> Function(Pointer<Uint8>')));
    });
  });
}
