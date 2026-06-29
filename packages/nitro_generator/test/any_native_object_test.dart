// Tests for AnyNativeObject (L14) across all five generators.
//
// AnyNativeObject is an opaque int64_t instance ID — the equivalent of
// RN Nitro's AnyHybridObject. Wire format: int64_t (non-null), int64_t with
// -1 as null sentinel (nullable).

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart' as jni;
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';

// ── Stream fixture ─────────────────────────────────────────────────────────────

BridgeSpec _streamSpec() => BridgeSpec(
  dartClassName: 'Registry',
  lib: 'registry',
  namespace: 'registry',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'registry.native.dart',
  streams: [
    BridgeStream(
      dartName: 'objects',
      registerSymbol: 'registry_register_objects_stream',
      releaseSymbol: 'registry_release_objects_stream',
      itemType: BridgeType(name: 'AnyNativeObject', isAnyNativeObject: true),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'maybeObjects',
      registerSymbol: 'registry_register_maybe_objects_stream',
      releaseSymbol: 'registry_release_maybe_objects_stream',
      itemType: BridgeType(name: 'AnyNativeObject?', isAnyNativeObject: true, isNullable: true),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ── Callback fixture ───────────────────────────────────────────────────────────

BridgeSpec _callbackSpec() => BridgeSpec(
  dartClassName: 'Registry',
  lib: 'registry',
  namespace: 'registry',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'registry.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'onObject',
      cSymbol: 'registry_on_object',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'callback',
          type: BridgeType(
            name: 'void Function(AnyNativeObject)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [
              BridgeType(name: 'AnyNativeObject', isAnyNativeObject: true),
            ],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'onMaybeObject',
      cSymbol: 'registry_on_maybe_object',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'callback',
          type: BridgeType(
            name: 'void Function(AnyNativeObject?)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [
              BridgeType(name: 'AnyNativeObject?', isAnyNativeObject: true, isNullable: true),
            ],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'requestObject',
      cSymbol: 'registry_request_object',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'supplier',
          type: BridgeType(
            name: 'AnyNativeObject Function()',
            isFunction: true,
            functionReturnType: 'AnyNativeObject',
            functionParams: [],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'requestMaybeObject',
      cSymbol: 'registry_request_maybe_object',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'supplier',
          type: BridgeType(
            name: 'AnyNativeObject? Function()',
            isFunction: true,
            functionReturnType: 'AnyNativeObject?',
            functionParams: [],
          ),
        ),
      ],
    ),
  ],
);

// ── Fixtures ──────────────────────────────────────────────────────────────────

BridgeSpec _returnSpec() => BridgeSpec(
  dartClassName: 'Registry',
  lib: 'registry',
  namespace: 'registry',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'registry.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getObject',
      cSymbol: 'registry_get_object',
      isAsync: false,
      returnType: BridgeType(name: 'AnyNativeObject', isAnyNativeObject: true),
      params: [],
    ),
    BridgeFunction(
      dartName: 'findObject',
      cSymbol: 'registry_find_object',
      isAsync: false,
      returnType: BridgeType(name: 'AnyNativeObject?', isAnyNativeObject: true, isNullable: true),
      params: [],
    ),
  ],
);

BridgeSpec _paramSpec() => BridgeSpec(
  dartClassName: 'Registry',
  lib: 'registry',
  namespace: 'registry',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'registry.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'processObject',
      cSymbol: 'registry_process_object',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'obj',
          type: BridgeType(name: 'AnyNativeObject', isAnyNativeObject: true),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'tryProcessObject',
      cSymbol: 'registry_try_process_object',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'obj',
          type: BridgeType(name: 'AnyNativeObject?', isAnyNativeObject: true, isNullable: true),
        ),
      ],
    ),
  ],
);

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
  group('AnyNativeObject — C header', () {
    test('non-null return: int64_t return type', () {
      final out = CppHeaderGenerator.generate(_returnSpec());
      expect(out, contains('int64_t registry_get_object(int64_t instanceId, NitroError* _nitro_err);'));
    });

    test('nullable return: int64_t return type (sentinel -1)', () {
      final out = CppHeaderGenerator.generate(_returnSpec());
      expect(out, contains('int64_t registry_find_object(int64_t instanceId, NitroError* _nitro_err);'));
    });

    test('non-null param: int64_t in C declaration', () {
      final out = CppHeaderGenerator.generate(_paramSpec());
      expect(out, contains('void registry_process_object(int64_t instanceId, int64_t obj, NitroError* _nitro_err);'));
    });

    test('nullable param: int64_t in C declaration (sentinel -1)', () {
      final out = CppHeaderGenerator.generate(_paramSpec());
      expect(out, contains('void registry_try_process_object(int64_t instanceId, int64_t obj, NitroError* _nitro_err);'));
    });
  });

  group('AnyNativeObject — Dart FFI', () {
    test('return: encodes as Int64 / int in native/dart type strings', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('Int64 Function(Int64, Pointer<NitroErrorFfi>)'));
      expect(out, contains('int Function(int, Pointer<NitroErrorFfi>)'));
    });

    test('non-null return: decoded as AnyNativeObject(res)', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('return AnyNativeObject(res)'));
    });

    test('nullable return: decoded with -1 null sentinel', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('return res == -1 ? null : AnyNativeObject(res)'));
    });

    test('non-null param: encoded as .instanceId', () {
      final out = DartFfiGenerator.generate(_paramSpec());
      expect(out, contains('obj.instanceId'));
    });

    test('nullable param: encoded with ?? -1 sentinel', () {
      final out = DartFfiGenerator.generate(_paramSpec());
      expect(out, contains('obj?.instanceId ?? -1'));
    });

    test('impl class emits asAnyNativeObject getter', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('AnyNativeObject get asAnyNativeObject => AnyNativeObject(_instanceId)'));
    });
  });

  group('AnyNativeObject — Kotlin', () {
    test('return type: Long', () {
      final out = KotlinGenerator.generate(_returnSpec());
      expect(out, contains('fun getObject(): Long'));
    });

    test('nullable return type: Long?', () {
      final out = KotlinGenerator.generate(_returnSpec());
      expect(out, contains('fun findObject(): Long?'));
    });

    test('param type: Long', () {
      final out = KotlinGenerator.generate(_paramSpec());
      expect(out, contains('fun processObject(obj: Long)'));
    });

    test('nullable param type: Long? in interface', () {
      final out = KotlinGenerator.generate(_paramSpec());
      expect(out, contains('fun tryProcessObject(obj: Long?)'));
    });

    test('JNI C bridge: CallStaticLongMethod for AnyNativeObject return', () {
      final out = jni.CppBridgeGenerator.generate(_returnSpec());
      expect(out, contains('CallStaticLongMethod'));
    });
  });

  group('AnyNativeObject — Swift', () {
    test('return type: Int64 in @_cdecl function', () {
      final out = SwiftGenerator.generate(_returnSpec());
      expect(out, contains('-> Int64'));
    });

    test('non-null return: direct instanceId passthrough', () {
      final out = SwiftGenerator.generate(_returnSpec());
      expect(out, contains('getObject'));
    });

    test('nullable return: -1 for null', () {
      final out = SwiftGenerator.generate(_returnSpec());
      expect(out, contains('-1'));
    });

    test('param type: Int64 in @_cdecl function', () {
      final out = SwiftGenerator.generate(_paramSpec());
      expect(out, contains('obj: Int64'));
    });
  });

  // ── Improvement 1: NativeRef extension ──────────────────────────────────────

  group('AnyNativeObject — NativeRef extension on abstract class', () {
    test('emits RegistryNativeRef extension on abstract class', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('extension RegistryNativeRef on Registry'));
    });

    test('extension getter casts to _Impl and delegates', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('(this as _RegistryImpl).asAnyNativeObject'));
    });

    test('extension is separate from the impl class asAnyNativeObject', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      // Both the impl getter AND the extension are present.
      expect(out, contains('AnyNativeObject get asAnyNativeObject => AnyNativeObject(_instanceId)'));
      expect(out, contains('extension RegistryNativeRef on Registry'));
    });
  });

  // ── Improvement 2: NitroInstanceRegistry ────────────────────────────────────

  group('AnyNativeObject — NitroInstanceRegistry wiring in generated impl', () {
    test('constructor registers instance', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('NitroInstanceRegistry.register(_instanceId, this)'));
    });

    test('dispose unregisters instance', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      expect(out, contains('NitroInstanceRegistry.unregister(_instanceId, this)'));
    });

    test('register call comes after instanceId assignment', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      final registerIdx = out.indexOf('NitroInstanceRegistry.register(_instanceId, this)');
      final instanceIdIdx = out.indexOf('_instanceId = _createInstancePtr');
      expect(registerIdx, greaterThan(instanceIdIdx));
    });

    test('unregister call comes before super.dispose()', () {
      final out = DartFfiGenerator.generate(_returnSpec());
      final unregisterIdx = out.indexOf('NitroInstanceRegistry.unregister(_instanceId, this)');
      final superIdx = out.indexOf('super.dispose()');
      expect(unregisterIdx, lessThan(superIdx));
    });
  });

  // ── Improvement 3: Stream<AnyNativeObject> ──────────────────────────────────

  group('AnyNativeObject — Stream<AnyNativeObject> Dart decoder', () {
    test('non-null stream: decodes kInt64 message as AnyNativeObject(message as int)', () {
      final out = DartFfiGenerator.generate(_streamSpec());
      expect(out, contains('AnyNativeObject(message as int)'));
    });

    test('nullable stream: null message decodes to null', () {
      final out = DartFfiGenerator.generate(_streamSpec());
      expect(out, contains('message == null ? null : AnyNativeObject(message as int)'));
    });

    test('non-null stream type: Stream<AnyNativeObject>', () {
      final out = DartFfiGenerator.generate(_streamSpec());
      expect(out, contains('Stream<AnyNativeObject> get objects'));
    });

    test('nullable stream type: Stream<AnyNativeObject?>', () {
      final out = DartFfiGenerator.generate(_streamSpec());
      expect(out, contains('Stream<AnyNativeObject?> get maybeObjects'));
    });

    test('Kotlin non-null stream: emits Long item type', () {
      final out = KotlinGenerator.generate(_streamSpec());
      expect(out, contains('emit_objects(dartPort, item'));
    });

    test('Kotlin nullable stream: emits Long? item type', () {
      final out = KotlinGenerator.generate(_streamSpec());
      expect(out, contains('Long?'));
    });

    test('Swift non-null stream: cType is Int64', () {
      final out = SwiftGenerator.generate(_streamSpec());
      expect(out, contains('emitCb: @convention(c) (Int64, Int64) -> Bool'));
    });

    test('Swift nullable stream: cType is UnsafePointer<Int64>?', () {
      final out = SwiftGenerator.generate(_streamSpec());
      expect(out, contains('emitCb: @convention(c) (Int64, UnsafePointer<Int64>?) -> Bool'));
    });
  });

  // ── Improvement 5: Callback AnyNativeObject params/returns ──────────────────

  group('AnyNativeObject — callback parameter support', () {
    test('non-null param: NativeCallable wrapper param is Int64', () {
      final out = DartFfiGenerator.generate(_callbackSpec());
      expect(out, contains('Int64 Function('));
    });

    test('non-null param: decoded as AnyNativeObject(arg0)', () {
      final out = DartFfiGenerator.generate(_callbackSpec());
      expect(out, contains('AnyNativeObject(arg0)'));
    });

    test('nullable param: decoded with -1 null sentinel', () {
      final out = DartFfiGenerator.generate(_callbackSpec());
      expect(out, contains('arg0 == -1 ? null : AnyNativeObject(arg0)'));
    });

    test('non-null return: encodes as .instanceId', () {
      final out = DartFfiGenerator.generate(_callbackSpec());
      expect(out, contains('.instanceId'));
    });

    test('nullable return: encodes null as -1', () {
      final out = DartFfiGenerator.generate(_callbackSpec());
      expect(out, contains('_v == null ? -1 : _v.instanceId'));
    });

    test('exceptional return for non-null AnyNativeObject is 0', () {
      final out = DartFfiGenerator.generate(_callbackSpec());
      expect(out, contains('exceptionalReturn: 0'));
    });

    test('exceptional return for nullable AnyNativeObject? is -1', () {
      final out = DartFfiGenerator.generate(_callbackSpec());
      expect(out, contains('exceptionalReturn: -1'));
    });
  });
}
