// PX18 + PX19 tests for the web bridge generator and dart:ffi PX19 guard.
//
// PX18: WebBridgeGenerator emits `@JS()` external declarations and a web
//       implementation class for specs targeting NativeImpl.wasm.
// PX19: dart_ffi_generator emits a kIsWeb assert-guard and a platform
//       conditional factory function when web is targeted.

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
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'greet',
      cSymbol: 'math_greet',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'name',
          type: BridgeType(name: 'String'),
        ),
      ],
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
      params: [
        BridgeParam(
          name: 'x',
          type: BridgeType(name: 'int'),
        ),
      ],
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

    test('emits a standalone library importing the web-bridge barrel', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      // 0.7.0 pointer ABI: symbols are called through NitroWasmModule (no
      // top-level @JS externals), resolved via the always-web barrel.
      expect(out, contains('library;'));
      expect(out, contains("import 'package:nitro/web_bridge.dart';"));
    });

    test('imports the spec library two levels up (not the .g.dart part file)', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      // The web bridge is emitted to lib/<dir>/generated/web/, so the spec is
      // always ../../<spec>.native.dart. Importing the .g.dart part is invalid
      // (part files cannot be imported) and was the old broken behaviour.
      expect(out, contains("import '../../"));
      expect(out, contains('.native.dart\';'));
      expect(out, isNot(contains("import 'math.g.dart';")));
    });

    test('does not emit dart:ffi codegen into the web file', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, isNot(contains('@Packed')));
      expect(out, isNot(contains('extends Struct')));
      expect(out, isNot(contains('dart:ffi')));
      expect(out, isNot(contains('lookupFunction')));
    });

    test('imports dart:js_interop', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains("import 'dart:js_interop';"));
    });

    test('calls each sync function through the module by C symbol', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains("_m.call('math_add'"));
      expect(out, contains("_m.call('math_greet'"));
      expect(out, contains("_m.call('math_reset'"));
      // instanceId leads every call; the sync error slot follows the params.
      expect(out, contains('jsI64(_instanceId)'));
      expect(out, contains('_err.ptr.toJS'));
    });

    test('@nitroAsync runs inline with the legacy error check', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains("_m.call('math_compute'"));
      expect(out, contains('NitroRuntime.callAsync<double>'));
      expect(out, contains('_checkLegacyError();'));
    });

    test('properties call the get/set symbols with the error slot', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains("_m.call('math_get_precision', [jsI64(_instanceId), _err.ptr.toJS])"));
      expect(out, contains("_m.call('math_set_precision'"));
      expect(out, contains('NitroRuntime.throwIfOutParamError(_err);'));
    });

    test('emits web implementation class extending the spec class', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('final class _MathWebImpl extends Math'));
    });

    test('web impl overrides sync double method via the module call', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('double add(double a, double b)'));
      expect(out, contains('.toDartDouble'));
      expect(out, contains('NitroRuntime.callSync'));
    });

    test('web impl overrides void method', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('void reset()'));
    });

    test('web impl wraps String return via JS interop', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('.toDart'));
    });

    test('web impl opens streams through the port registry', () {
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
      // Full parity in 0.7.0: streams register a web port with the module.
      expect(out, contains('NitroRuntime.openStream'));
      expect(out, contains("_m.call('camera_register_on_frame_stream'"));
      expect(out, contains("_m.call('camera_release_on_frame_stream'"));
      expect(out, contains('Backpressure.dropLatest'));
      expect(out, isNot(contains('UnsupportedError')));
    });

    test('emits the canonical shim-exported factories', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains("Math createMathInstance([String key = 'default'])"));
      expect(out, contains('Future<void> ensureMathReady({String? jsUrl})'));
      expect(out, contains('_MathWebImpl(key)'));
    });

    test('module bootstrap loads by lib name with the baked asset package', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains("const String _libName = 'math';"));
      expect(out, contains('NitroRuntime.loadWebModule(_libName'));
      expect(out, contains('NitroRuntime.webModule(_libName)'));
    });

    test('double params use .toJS conversion in extern calls', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('a.toJS'));
      expect(out, contains('b.toJS'));
    });

    test('String params copy through the arena as C strings', () {
      final out = WebBridgeGenerator.generate(_webSpec());
      expect(out, contains('arena.cString(name).toJS'));
      expect(out, contains('withWasmArena(_m, (arena)'));
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
        enums: [
          BridgeEnum(name: 'Color', startValue: 0, values: ['red', 'green']),
        ],
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
      // Web-split (0.7.0): the impl lives in the standalone ffi library.
      final out = DartFfiGenerator.generateFfiLibrary(_webSpec());
      expect(out, contains("dart.library.js_interop"));
      expect(out, contains('assert('));
    });

    test('assert message names the web bridge alternative', () {
      final out = DartFfiGenerator.generateFfiLibrary(_webSpec());
      expect(out, contains('web.bridge.g.dart'));
    });

    test('web-targeting spec emits the factories in the ffi library', () {
      final out = DartFfiGenerator.generateFfiLibrary(_webSpec());
      // Legacy multi-instance factory is kept for compatibility...
      expect(out, contains("_createNativeInstance([String key = 'default'])"));
      expect(out, contains('_MathImpl(key)'));
      // ...and the canonical shim-exported pair is new in 0.7.0.
      expect(out, contains("Math createMathInstance([String key = 'default'])"));
      expect(out, contains('Future<void> ensureMathReady({String? jsUrl}) async {}'));
    });

    test('web-targeting spec: part keeps only platform-neutral codecs', () {
      final out = DartFfiGenerator.generate(_webSpec());
      expect(out, isNot(contains('Pointer')));
      expect(out, isNot(contains('_MathImpl')));
      expect(out, contains('Web-split layout'));
    });

    test('platform shim conditionally exports the two factories', () {
      final out = DartFfiGenerator.generatePlatformShim(_webSpec());
      expect(out, contains("export 'generated/native/"));
      expect(out, contains("if (dart.library.js_interop) 'generated/web/"));
      expect(out, contains('show createMathInstance, ensureMathReady;'));
    });

    test('non-web spec gets placeholder ffi library and shim', () {
      expect(DartFfiGenerator.generateFfiLibrary(_noWebSpec()), contains('Web not targeted'));
      expect(DartFfiGenerator.generatePlatformShim(_noWebSpec()), contains('Web not targeted'));
    });

    test('factory function comment explains conditional import pattern', () {
      final out = DartFfiGenerator.generateFfiLibrary(_webSpec());
      // Comment or doc for the factory mentions web or conditional import
      final mentionsWeb = out.contains('web bridge') || out.contains('web.bridge') || out.contains('conditional');
      expect(mentionsWeb, isTrue);
    });

    test('_loadSupportedLibrary still passes web: true to loadLibForTargets', () {
      final out = DartFfiGenerator.generateFfiLibrary(_webSpec());
      // web: true when webImpl is set
      expect(out, contains('web: true'));
    });

    test('non-web spec: _loadSupportedLibrary passes web: false', () {
      final out = DartFfiGenerator.generate(_noWebSpec());
      expect(out, contains('web: false'));
    });
  });

  group('web return decode — Map<String,V> and List<record>', () {
    // 0.7.0 pointer ABI: maps and record lists cross as framed binary blobs
    // decoded with the shared RecordReader — same wire as native.
    BridgeSpec spec() => BridgeSpec(
      dartClassName: 'Coll',
      lib: 'coll',
      namespace: 'coll',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      webImpl: NativeImpl.wasm,
      sourceUri: 'coll.native.dart',
      recordTypes: [
        BridgeRecordType(
          name: 'Stat',
          fields: [
            BridgeRecordField(name: 'count', dartType: 'int', kind: RecordFieldKind.primitive),
            BridgeRecordField(name: 'mean', dartType: 'double', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
      functions: [
        BridgeFunction(
          dartName: 'echoMap',
          cSymbol: 'coll_echo_map',
          isAsync: false,
          returnType: BridgeType(name: 'Map<String, int>', isMap: true),
          params: [BridgeParam(name: 'm', type: BridgeType(name: 'Map<String, int>', isMap: true))],
        ),
        BridgeFunction(
          dartName: 'echoStats',
          cSymbol: 'coll_echo_stats',
          isAsync: false,
          returnType: BridgeType(name: 'List<Stat>', isRecord: true, recordListItemType: 'Stat'),
          params: [BridgeParam(name: 's', type: BridgeType(name: 'List<Stat>', isRecord: true, recordListItemType: 'Stat'))],
        ),
      ],
    );

    test('Map<String,int> crosses as tagged binary, not JSON', () {
      final out = WebBridgeGenerator.generate(spec());
      // Encode helper writes the string-key tagged wire the native side reads.
      expect(out, contains('Uint8List _nitroEncodeMapBytesStringInt(Map<String, int> m)'));
      expect(out, contains('w.writeInt8(1);'));
      expect(out, contains('Map<String, int> _nitroDecodeMapBytesStringInt(Uint8List framed)'));
      // Sync map returns are borrowed framed blobs.
      expect(out, contains('_m.readFramed(_ptr)'));
      expect(out, isNot(contains('jsonEncode(m)')));
    });

    test('List<record> encodes AND decodes indexed — both directions match', () {
      final out = WebBridgeGenerator.generate(spec());
      expect(out, contains('RecordReader.decodeIndexedListBytes(_framed, (r) => StatRecordExt.fromReader(r))'));
      // The offset table is not optional: encoding plain here makes the
      // receiver read item bytes as offsets — it throws on dart2js and
      // silently decodes garbage on dart2wasm.
      expect(out, contains('RecordWriter.encodeIndexedListBytes(s, (w, e) => e.writeFields(w))'));
      expect(out, isNot(contains('RecordWriter.encodeListBytes(s, (w, e) => e.writeFields(w))')));
    });
  });

  group('web list wire shapes match the native/Kotlin/Swift contract', () {
    // One spec per item category. The contract these pin down:
    //
    //   category    param        return
    //   record      INDEXED      INDEXED
    //   primitive   INDEXED      PLAIN     <- deliberately asymmetric
    //   enum        PLAIN        PLAIN
    //   variant     PLAIN        PLAIN
    //   enum?/var?  PRESENCE     PRESENCE
    //
    // Getting either half wrong is silent data corruption, not a crash, so
    // assert both halves explicitly rather than trusting a round-trip.
    BridgeSpec listSpec(BridgeType t, String fn) => BridgeSpec(
      dartClassName: 'Coll',
      lib: 'coll',
      namespace: 'coll',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      webImpl: NativeImpl.wasm,
      sourceUri: 'coll.native.dart',
      enums: [
        BridgeEnum(name: 'Level', startValue: 0, values: ['low', 'high']),
      ],
      functions: [
        BridgeFunction(
          dartName: fn,
          cSymbol: 'coll_$fn',
          isAsync: false,
          returnType: t,
          params: [BridgeParam(name: 'v', type: t)],
        ),
      ],
    );

    test('List<int> param is INDEXED while its return stays PLAIN', () {
      final out = WebBridgeGenerator.generate(
        listSpec(
          BridgeType(
            name: 'List<int>',
            isRecord: true,
            recordListItemType: 'int',
            recordListItemIsPrimitive: true,
          ),
          'echoInts',
        ),
      );
      // Kotlin/Swift skip an 8-byte-per-item offset table on primitive params.
      expect(out, contains('RecordWriter.encodeIndexedListBytes(v, (w, e) => w.writeInt(e))'));
      // ...but primitive returns really are plain on every backend.
      expect(out, contains('RecordReader.decodeListBytes(_framed, (r) => r.readInt())'));
    });

    test('List<Level> stays PLAIN in both directions', () {
      final out = WebBridgeGenerator.generate(
        listSpec(
          BridgeType(
            name: 'List<Level>',
            isRecord: true,
            recordListItemType: 'Level',
            isEnumList: true,
          ),
          'echoLevels',
        ),
      );
      expect(out, contains('RecordWriter.encodeListBytes(v, (w, e) => w.writeInt(e.nativeValue))'));
      expect(out, contains('RecordReader.decodeListBytes(_framed, (r) => r.readInt().toLevel())'));
      expect(out, isNot(contains('encodeIndexedListBytes(v')));
    });

    test('List<Level?> carries a per-item presence flag in both directions', () {
      final out = WebBridgeGenerator.generate(
        listSpec(
          BridgeType(
            name: 'List<Level?>',
            isRecord: true,
            recordListItemType: 'Level',
            isEnumList: true,
            recordListItemIsNullable: true,
          ),
          'echoMaybeLevels',
        ),
      );
      // Plain encoding drops the 1B flag and shifts every later item.
      expect(out, contains('RecordWriter.encodeNullableListBytes(v, (w, e) => w.writeInt(e.nativeValue))'));
      expect(out, contains('RecordReader.decodeNullableListBytes(_framed, (r) => r.readInt().toLevel())'));
    });
  });
}
