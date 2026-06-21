/// PX18 + PX19 tests for the web bridge generator and dart:ffi PX19 guard.
///
/// PX18: WebBridgeGenerator emits `@JS()` external declarations and a web
///       implementation class for specs targeting NativeImpl.wasm.
/// PX19: dart_ffi_generator emits a kIsWeb assert-guard and a platform
///       conditional factory function when web is targeted.

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:test/test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

BridgeSpec _webSpec() => BridgeSpec(
  dartClassName: 'Math',
  lib: 'math',
  namespace: 'math',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  webImpl: NativeImpl.wasm,
  sourceUri: 'math.native.dart',
  enums: [
    BridgeEnum(name: 'MathMode', startValue: 0, values: ['fast', 'precise']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'math_add',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'a', type: BridgeType(name: 'double')),
        BridgeParam(name: 'b', type: BridgeType(name: 'double')),
      ],
    ),
    BridgeFunction(
      dartName: 'greet',
      cSymbol: 'math_greet',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [BridgeParam(name: 'name', type: BridgeType(name: 'String'))],
    ),
    BridgeFunction(
      dartName: 'reset',
      cSymbol: 'math_reset',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'compute',
      cSymbol: 'math_compute',
      isAsync: true,
      returnType: BridgeType(name: 'double'),
      params: [BridgeParam(name: 'x', type: BridgeType(name: 'int'))],
    ),
  ],
  properties: [
    BridgeProperty(
      dartName: 'precision',
      type: BridgeType(name: 'int'),
      getSymbol: 'math_get_precision',
      setSymbol: 'math_set_precision',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
);

BridgeSpec _noWebSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'read',
      cSymbol: 'sensor_read',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [],
    ),
  ],
);

// ── PX18 tests ────────────────────────────────────────────────────────────────

void main() {
  group('PX18 — WebBridgeGenerator', () {
    test('emits stub comment when web not targeted', () {
      final out = WebBridgeGenerator.generate(_noWebSpec());
      expect(out, contains('// Web not targeted'));
      // The stub output must NOT emit any @JS() declarations
      expect(out, isNot(contains("@JS('nitro_")));
    });

    test('emits @JS() library annotation when web is targeted', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('@JS()'));
      expect(out, contains('library nitro_math_web;'));
    });

    test('imports dart:js_interop', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains("import 'dart:js_interop';"));
    });

    test('emits @JS() external using C symbol name (snake_case) for each sync function', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      // cSymbol = 'math_add', 'math_greet', 'math_reset' — NOT 'nitro_math_add'
      expect(out, contains("@JS('math_add')"));
      expect(out, contains('external JSNumber _math_add_js'));
      expect(out, contains("@JS('math_greet')"));
      expect(out, contains('external JSString _math_greet_js'));
      expect(out, contains("@JS('math_reset')"));
      expect(out, contains('external void _math_reset_js'));
    });

    test('emits @JS() externals for async functions using C symbol name', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      // cSymbol for 'compute' is 'math_compute'
      expect(out, contains("@JS('math_compute')"));
      expect(out, contains('_math_compute_js'));
    });

    test('emits @JS() externals for property getter and setter', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains("@JS('nitro_math_get_precision')"));
      expect(out, contains('_math_get_precision_js'));
      expect(out, contains("@JS('nitro_math_set_precision')"));
      expect(out, contains('_math_set_precision_js'));
    });

    test('emits web implementation class extending the spec class', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('final class _MathWebImpl extends Math'));
    });

    test('web impl overrides sync double method via JS interop', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('double add(double a, double b)'));
      expect(out, contains('_math_add_js'));
      expect(out, contains('.toDartDouble'));
    });

    test('web impl overrides void method', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('void reset()'));
      expect(out, contains('_math_reset_js()'));
    });

    test('web impl wraps String return via JS interop', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('.toDart'));
    });

    test('web impl throws UnsupportedError for streams', () {
      final webSpecWithStream = BridgeSpec(
        dartClassName: 'Camera',
        lib: 'camera',
        namespace: 'camera',
        webImpl: NativeImpl.wasm,
        sourceUri: 'camera.native.dart',
        functions: [],
        streams: [
          BridgeStream(
            dartName: 'onFrame',
            registerSymbol: 'camera_register_on_frame_stream',
            releaseSymbol: 'camera_release_on_frame_stream',
            itemType: BridgeType(name: 'int'),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = WebBridgeGenerator.generate(webSpecWithStream);
      expect(out, contains('UnsupportedError'));
      expect(out, contains('onFrame'));
    });

    test('emits factory function for conditional import pattern', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('createMathWebInstance()'));
      expect(out, contains('_MathWebImpl()'));
    });

    test('factory function docs describe conditional import usage', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('web.bridge.g.dart'));
    });

    test('double params use .toJS conversion in extern calls', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('a.toJS'));
      expect(out, contains('b.toJS'));
    });

    test('String params use .toJS conversion', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('name.toJS'));
    });

    test('type-only spec emits only type declarations (no impl class)', () {
      final typeOnlySpec = BridgeSpec(
        dartClassName: 'Types',
        lib: 'types',
        namespace: 'types',
        webImpl: NativeImpl.wasm,
        sourceUri: 'types.native.dart',
        isTypeOnly: true,
        functions: [],
        enums: [BridgeEnum(name: 'Color', startValue: 0, values: ['red', 'green'])],
      );
      final out = WebBridgeGenerator.generate(typeOnlySpec);
      expect(out, isNot(contains('final class')));
      expect(out, isNot(contains('createTypesWebInstance')));
    });
  });

  // ── PX19 tests ──────────────────────────────────────────────────────────────

  group('PX19 — dart_ffi_generator kIsWeb guard + conditional factory', () {
    test('non-web spec: no kIsWeb assert guard emitted', () {
      final out = DartFfiGenerator.generate(_noWebSpec());
      expect(out, isNot(contains("dart.library.js_interop")));
      expect(out, isNot(contains('_createNativeInstance')));
    });

    test('web-targeting spec: kIsWeb assert guard in _loadSupportedLibrary', () {
      final out = DartFfiGenerator.generate(_webSpec());
      expect(out, contains("dart.library.js_interop"));
      expect(out, contains('assert('));
    });

    test('assert message names the web bridge alternative', () {
      final out = DartFfiGenerator.generate(_webSpec());
      expect(out, contains('web.bridge.g.dart'));
      expect(out, contains('createMathWebInstance'));
    });

    test('web-targeting spec emits _createNativeInstance() factory', () {
      final out = DartFfiGenerator.generate(_webSpec());
      expect(out, contains('_createNativeInstance()'));
      expect(out, contains('_MathImpl()'));
    });

    test('factory function comment explains conditional import pattern', () {
      final out = DartFfiGenerator.generate(_webSpec());
      // Comment or doc for the factory mentions web or conditional import
      final mentionsWeb = out.contains('web bridge') || out.contains('web.bridge') || out.contains('conditional');
      expect(mentionsWeb, isTrue);
    });

    test('_loadSupportedLibrary still passes web: true to loadLibForTargets', () {
      final out = DartFfiGenerator.generate(_webSpec());
      // web: true when webImpl is set
      expect(out, contains('web: true'));
    });

    test('non-web spec: _loadSupportedLibrary passes web: false', () {
      final out = DartFfiGenerator.generate(_noWebSpec());
      expect(out, contains('web: false'));
    });
  });
}
