// Tests for Map<String, @HybridRecord> bridging via JSON in DartFfiGenerator.
//
// A Map<String, V> function return / parameter uses `isMap = true` regardless
// of whether V is a @HybridRecord class. The entire map bridges as a JSON
// string (Pointer<Utf8> / jsonDecode / jsonEncode) — NOT via binary RecordExt.
//
// The specs here set `isMap: true` without adding the value type to recordTypes.
// That is the realistic scenario emitted by the spec extractor: it sets isMap on
// the BridgeType but does NOT synthesize a BridgeRecordType for Map's value.

import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeSpec _mapRecordReturnSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  // No recordTypes — the map value type (Device) is only named in BridgeType.name.
  // The isMap flag controls routing; no RecordExt is generated for the value type.
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
    test('uses Pointer<Utf8> for the getDevices FFI function pointer', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      // Map types bridge as JSON strings via Pointer<Utf8>
      expect(
        out,
        contains(
          'Pointer<Utf8> Function() _getDevicesPtr',
        ),
      );
    });

    test('decodes via jsonDecode', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('jsonDecode'));
    });

    test('does NOT use binary RecordExt path (fromNative / fromReader)', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      // isMap takes precedence over isRecord — binary codec is skipped
      expect(out, isNot(contains('RecordExt')));
      expect(out, isNot(contains('fromNative')));
    });

    test('casts jsonDecode result as Map<String, dynamic>', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('as Map<String, dynamic>'));
    });

    test('getDevices function appears in generated output', () {
      final out = DartFfiGenerator.generate(_mapRecordReturnSpec());
      expect(out, contains('getDevices'));
    });
  });

  group('DartFfiGenerator — Map<String, @HybridRecord> parameter', () {
    test('uses jsonEncode to serialize the map param', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('jsonEncode(settings)'));
    });

    test('uses toNativeUtf8 to pass map as Pointer<Utf8>', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('toNativeUtf8'));
    });

    test('does NOT use binary RecordExt for the map param', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, isNot(contains('RecordExt')));
    });

    test('param FFI signature uses Pointer<Utf8> for map type', () {
      final out = DartFfiGenerator.generate(_mapRecordParamSpec());
      expect(out, contains('Pointer<Utf8>'));
    });
  });
}
