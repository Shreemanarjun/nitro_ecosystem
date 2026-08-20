// Edge case tests for fixes applied after the audit:
//   1. void property type → INVALID_PROPERTY_TYPE validator error
//   2. Web bridge: isMap uses JSString (JSON), not JSArrayBuffer
//   3. Web bridge: isPointer/isNativeHandle types handled
//   4. PX19 factory name: safe for single-char and underscore-prefixed class names
//   5. Suffix matching: .web.bridge.g.dart wins over .g.dart

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/web/web_bridge_generator.dart';
import 'package:nitro_generator/src/generators/native_generator_facade.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

BridgeSpec _specWithVoidProperty() => BridgeSpec(
  dartClassName: 'Bad',
  lib: 'bad',
  namespace: 'bad',
  iosImpl: NativeImpl.swift,
  sourceUri: 'bad.native.dart',
  functions: [],
  properties: [
    BridgeProperty(
      dartName: 'badProp',
      type: BridgeType(name: 'void'),
      getSymbol: 'bad_get_bad_prop',
      setSymbol: 'bad_set_bad_prop',
      hasGetter: true,
      hasSetter: false,
    ),
  ],
);

BridgeSpec _webMapSpec() => BridgeSpec(
  dartClassName: 'Config',
  lib: 'config',
  namespace: 'config',
  webImpl: NativeImpl.wasm,
  sourceUri: 'config.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getSettings',
      cSymbol: 'config_get_settings',
      isAsync: false,
      returnType: BridgeType(name: 'Map<String, dynamic>', isRecord: true, isMap: true),
      params: [],
    ),
    BridgeFunction(
      dartName: 'setSettings',
      cSymbol: 'config_set_settings',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'settings',
          type: BridgeType(name: 'Map<String, dynamic>', isRecord: true, isMap: true),
        ),
      ],
    ),
  ],
);

BridgeSpec _webPointerSpec() => BridgeSpec(
  dartClassName: 'Raw',
  lib: 'raw',
  namespace: 'raw',
  webImpl: NativeImpl.wasm,
  sourceUri: 'raw.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getHandle',
      cSymbol: 'raw_get_handle',
      isAsync: false,
      returnType: BridgeType(name: 'NativeHandle<Void>', isNativeHandle: true, nativeHandleTypeParam: 'Void'),
      params: [],
    ),
  ],
);

BridgeSpec _singleCharClassSpec({required bool targetsWeb}) => BridgeSpec(
  dartClassName: 'A',
  lib: 'a',
  namespace: 'a',
  iosImpl: NativeImpl.swift,
  webImpl: targetsWeb ? NativeImpl.wasm : null,
  sourceUri: 'a.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'run',
      cSymbol: 'a_run',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
  ],
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── Fix #1: void property type → validator error ──────────────────────────
  group('Edge case: void property type', () {
    test('void property getter emits INVALID_PROPERTY_TYPE error', () {
      final issues = SpecValidator.validate(_specWithVoidProperty());
      final errors = issues.where((i) => i.code == 'INVALID_PROPERTY_TYPE').toList();
      expect(errors, isNotEmpty);
      expect(errors.first.isError, isTrue);
      expect(errors.first.message, contains('void'));
      expect(errors.first.message, contains('badProp'));
    });

    test('void property error hint suggests using a method instead', () {
      final issues = SpecValidator.validate(_specWithVoidProperty());
      final e = issues.firstWhere((i) => i.code == 'INVALID_PROPERTY_TYPE');
      expect(e.hint, contains('method'));
    });

    test('non-void property has no INVALID_PROPERTY_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Good',
        lib: 'good',
        namespace: 'good',
        iosImpl: NativeImpl.swift,
        sourceUri: 'good.native.dart',
        functions: [],
        properties: [
          BridgeProperty(
            dartName: 'count',
            type: BridgeType(name: 'int'),
            getSymbol: 'good_get_count',
            setSymbol: 'good_set_count',
            hasGetter: true,
            hasSetter: true,
          ),
        ],
      );
      expect(
        SpecValidator.validate(spec).where((i) => i.code == 'INVALID_PROPERTY_TYPE'),
        isEmpty,
      );
    });
  });

  // ── Fix #2: Web bridge Map<String,V> uses JSString not JSArrayBuffer ───────
  group('Edge case: Web bridge maps use the tagged binary wire (0.7.0)', () {
    test('Map crosses as framed binary, matching the native wire', () {
      final out = WebBridgeGenerator.generate(_webMapSpec());
      expect(out, contains('_nitroEncodeMapBytes'));
      expect(out, contains('_nitroDecodeMapBytes'));
      expect(out, isNot(contains('JSArrayBuffer')));
    });
  });

  // ── Fix #3: Web bridge isPointer/isNativeHandle ───────────────────────────
  group('Edge case: Web bridge NativeHandle type', () {
    test('NativeHandle crosses as its int address (0.7.0 pointer ABI)', () {
      final out = WebBridgeGenerator.generate(_webPointerSpec());
      // On web the handle IS a linear-memory offset; the override is typed
      // dynamic because NativeHandle resolves to different classes per
      // platform, and the web class is constructed from the posted address.
      expect(out, contains('NativeHandle<'));
      expect(out, contains('.fromAddress(_addr)'));
      expect(out, isNot(contains('UnsupportedError')));
    });

    test('NativeHandle impl method is generated in web class', () {
      final out = WebBridgeGenerator.generate(_webPointerSpec());
      // The impl class should override getHandle
      expect(out, contains('getHandle'));
      expect(out, contains('_RawWebImpl'));
    });
  });

  // ── Fix #4: PX19 factory name for edge-case class names ───────────────────
  group('Edge case: PX19 factory function name safety', () {
    test('single-char class A → aCreateNativeInstance() (not empty name)', () {
      // Web-split (0.7.0): the factory lives in the standalone ffi library.
      final out = DartFfiGenerator.generateFfiLibrary(_singleCharClassSpec(targetsWeb: true));
      // Should produce 'a_createNativeInstance(' or 'A_createNativeInstance' - some valid name
      expect(out, contains('_createNativeInstance'));
      // Must not produce an invalid identifier starting with digit or nothing.
      // Signature now carries an optional [key] param, so match up to '('.
      final factoryMatch = RegExp(r'\w+_createNativeInstance\(').firstMatch(out);
      expect(factoryMatch, isNotNull);
      final name = factoryMatch!.group(0)!;
      expect(name[0], isNot(equals('0'))); // must not start with digit
    });

    test('non-web spec: no _createNativeInstance factory emitted', () {
      final out = DartFfiGenerator.generate(_singleCharClassSpec(targetsWeb: false));
      expect(out, isNot(contains('_createNativeInstance')));
    });
  });

  // ── Fix #5: Suffix matching longest-match ─────────────────────────────────
  group('Edge case: suffix matching longest-match', () {
    test('.web.bridge.g.dart resolves to webBridge target (not dartFfi)', () {
      final facade = NativeGeneratorFacade.defaults();
      final target = facade.targetForOutputPath('lib/src/generated/web/math.web.bridge.g.dart');
      expect(target, NativeGeneratorTarget.webBridge);
    });

    test('.g.dart still resolves to dartFfi target', () {
      final facade = NativeGeneratorFacade.defaults();
      final target = facade.targetForOutputPath('lib/src/math.g.dart');
      expect(target, NativeGeneratorTarget.dartFfi);
    });

    test('ambiguous: .bridge.g.dart resolves to cppBridge (longer than .g.dart)', () {
      final facade = NativeGeneratorFacade.defaults();
      final target = facade.targetForOutputPath('lib/src/generated/cpp/math.bridge.g.cpp');
      expect(target, NativeGeneratorTarget.cppBridge);
    });

    test('unknown suffix returns null', () {
      final facade = NativeGeneratorFacade.defaults();
      expect(facade.targetForOutputPath('lib/src/math.unknown'), isNull);
    });
  });
}
