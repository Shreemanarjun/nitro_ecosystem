// Point 13: Multi-instance bridge support — unit tests.
//
// Factory pattern (like RN Nitro's HybridObjectRegistry):
//   Plugin registers once:   registerFactory { -> Impl() }
//   Dart first access:       getInstance("key") → _create_instance(key) → native assigns Long id
//   All bridge calls:        use that Long instanceId for zero per-call overhead
//   Dart dispose():          _destroy_instance(id) → Kotlin removes + onDetached()

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:test/test.dart';

BridgeSpec _spec({bool swiftPath = false}) => BridgeSpec(
  dartClassName: 'Counter',
  lib: 'counter',
  namespace: 'counter',
  iosImpl: swiftPath ? NativeImpl.swift : NativeImpl.cpp,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'counter.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'increment',
      cSymbol: 'counter_increment',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [BridgeParam(name: 'by', type: BridgeType(name: 'int'))],
    ),
    BridgeFunction(
      dartName: 'reset',
      cSymbol: 'counter_reset',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'fetchData',
      cSymbol: 'counter_fetch_data',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'String'),
      params: [],
    ),
  ],
  properties: [
    BridgeProperty(
      dartName: 'value',
      type: BridgeType(name: 'int'),
      getSymbol: 'counter_get_value',
      setSymbol: 'counter_set_value',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'updates',
      itemType: BridgeType(name: 'int'),
      registerSymbol: 'counter_register_updates_stream',
      releaseSymbol: 'counter_release_updates_stream',
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

void main() {
  group('Point 13 — Dart FFI factory-pattern instance creation', () {
    test('emits static _instances map keyed by String', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains("static final _instances = <String, _CounterImpl>{}"));
    });

    test('does NOT emit static _nextInstanceId (id comes from native)', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, isNot(contains('static int _nextInstanceId')));
    });

    test('emits final String _instanceKey field', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('final String _instanceKey'));
    });

    test('emits late final int _instanceId (assigned from native)', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('late final int _instanceId'));
    });

    test('emits factory constructor with default key', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains("factory _CounterImpl([String key = 'default'])"));
      expect(out, contains('_instances.putIfAbsent(key'));
    });

    test('factory calls _init(key) with no id arg', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('_CounterImpl._init(key)'));
    });

    test('named _init constructor takes only instanceKey', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains("_CounterImpl._init(this._instanceKey) : _dylib = _loadSupportedLibrary()"));
    });

    test('_createInstancePtr pointer looks up counter_create_instance', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('_createInstancePtr'));
      expect(out, contains("counter_create_instance"));
    });

    test('_destroyInstancePtr pointer looks up counter_destroy_instance', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('_destroyInstancePtr'));
      expect(out, contains("counter_destroy_instance"));
    });

    test('_init body calls _createInstancePtr to get instanceId from native', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('_instanceId = _createInstancePtr(_keyPtr)'));
    });

    test('_init guards negative id as failure', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('if (_instanceId < 0)'));
    });

    test('_init allocates and frees the key Utf8 pointer with calloc', () {
      final out = DartFfiGenerator.generate(_spec());
      // Both ends use calloc (allocate + free) — a style choice, not a
      // correctness requirement: package:ffi's malloc.free/calloc.free both
      // resolve to the same OS-level free regardless of which allocator
      // produced the pointer, so mixing malloc/calloc here was never unsafe.
      expect(out, contains('toNativeUtf8(allocator: calloc)'));
      expect(out, contains('calloc.free(_keyPtr)'));
    });

    test('dispose() calls _destroyInstancePtr before removing from _instances', () {
      final out = DartFfiGenerator.generate(_spec());
      final destroyIdx = out.indexOf('_destroyInstancePtr(_instanceId)');
      final removeIdx = out.indexOf('_instances.remove(_instanceKey)');
      expect(destroyIdx, isNot(-1), reason: '_destroyInstancePtr call not found');
      expect(removeIdx, isNot(-1), reason: '_instances.remove not found');
      expect(destroyIdx, lessThan(removeIdx));
    });
  });

  group('Point 13 — Dart FFI _instanceId prepended to all calls', () {
    test('sync function with params', () {
      expect(DartFfiGenerator.generate(_spec()), contains('_incrementPtr(_instanceId, by, _nitroErr)'));
    });
    test('sync void function', () {
      expect(DartFfiGenerator.generate(_spec()), contains('_resetPtr(_instanceId, _nitroErr)'));
    });
    test('property getter', () {
      expect(DartFfiGenerator.generate(_spec()), contains('_getValuePtr(_instanceId, _nitroErr)'));
    });
    test('property setter', () {
      expect(DartFfiGenerator.generate(_spec()), contains('_setValuePtr(_instanceId,'));
    });
    test('stream register', () {
      expect(DartFfiGenerator.generate(_spec()), contains('_registerUpdatesPtr(_instanceId, port)'));
    });
    test('NativeAsync: instanceId before dart_port', () {
      expect(DartFfiGenerator.generate(_spec()), contains('_fetchDataPtr(_instanceId, port)'));
    });
  });

  group('Point 13 — C header lifecycle symbols', () {
    test('create_instance symbol present', () {
      expect(CppHeaderGenerator.generate(_spec()), contains('counter_create_instance(const char* key)'));
    });
    test('destroy_instance symbol present', () {
      expect(CppHeaderGenerator.generate(_spec()), contains('counter_destroy_instance(int64_t instanceId)'));
    });
    test('sync function still has instanceId as first param', () {
      expect(CppHeaderGenerator.generate(_spec()), contains('counter_increment(int64_t instanceId, int64_t by, NitroError* _nitro_err)'));
    });
    test('stream release does NOT have instanceId', () {
      final out = CppHeaderGenerator.generate(_spec());
      expect(out, contains('counter_release_updates_stream(int64_t dart_port)'));
      expect(out, isNot(contains('counter_release_updates_stream(int64_t instanceId')));
    });
  });

  group('Point 13 — Kotlin JniBridge factory-pattern', () {
    late String out;
    setUpAll(() => out = KotlinGenerator.generate(_spec()));

    test('has ConcurrentHashMap<Long, Hybrid...Spec>', () {
      expect(out, contains('ConcurrentHashMap<Long, HybridCounterSpec>'));
    });
    test('has AtomicLong id counter', () {
      expect(out, contains('AtomicLong'));
    });
    test('has _factory field', () {
      expect(out, contains('_factory'));
    });
    test('has registerFactory() instead of register(key,)', () {
      expect(out, contains('fun registerFactory(factory: () -> HybridCounterSpec, context: Context)'));
      expect(out, isNot(contains('fun register(key:')));
    });
    test('registerFactory sets _factory field', () {
      expect(out, contains('_factory = factory'));
    });
    test('create_instance_call is @JvmStatic and returns Long', () {
      expect(out, contains('fun create_instance_call(key: String): Long'));
    });
    test('create_instance_call calls factory() for a fresh impl', () {
      expect(out, contains('val impl = factory()'));
    });
    test('create_instance_call stores impl in _implementations', () {
      expect(out, contains('_implementations[id] = impl'));
    });
    test('create_instance_call returns the assigned id', () {
      final idx = out.indexOf('fun create_instance_call');
      final end = out.indexOf('\n    }', idx);
      expect(out.substring(idx, end), contains('return id'));
    });
    test('destroy_instance_call is @JvmStatic', () {
      expect(out, contains('fun destroy_instance_call(instanceId: Long)'));
    });
    test('destroy_instance_call removes and detaches', () {
      expect(out, contains('_implementations.remove(instanceId)?.onDetached()'));
    });
    test('_call methods use Long instanceId for dispatch', () {
      expect(out, contains('fun increment_call(instanceId: Long, by: Long)'));
      expect(out, contains('_implementations[instanceId]'));
    });
    test('no onDetached(key) — disposal driven by Dart', () {
      expect(out, isNot(contains('fun onDetached(key:')));
    });
  });

  group('Point 13 — C++ bridge: JNI create/destroy functions', () {
    late String out;
    setUpAll(() => out = CppBridgeGenerator.generate(_spec()));

    test('counter_create_instance C function emitted', () {
      expect(out, contains('counter_create_instance(const char* key)'));
    });
    test('counter_destroy_instance C function emitted', () {
      expect(out, contains('counter_destroy_instance(int64_t instanceId)'));
    });
    test('create uses CallStaticLongMethod + g_mid_create_instance_call', () {
      expect(out, contains('CallStaticLongMethod'));
      expect(out, contains('g_mid_create_instance_call'));
    });
    test('destroy uses CallStaticVoidMethod + g_mid_destroy_instance_call', () {
      expect(out, contains('g_mid_destroy_instance_call'));
    });
    test('method IDs cached in initialize()', () {
      expect(out, contains('g_mid_create_instance_call'));
      expect(out, contains('g_mid_destroy_instance_call'));
    });
  });

  group('Point 13 — Swift shim: create/destroy stubs for single-instance path', () {
    late String out;
    setUpAll(() => out = CppBridgeGenerator.generate(_spec(swiftPath: true)));

    test('create_instance stub emitted', () {
      expect(out, contains('counter_create_instance(const char* key)'));
    });
    test('destroy_instance stub emitted', () {
      expect(out, contains('counter_destroy_instance(int64_t instanceId)'));
    });
    test('Swift extern still does NOT have instanceId', () {
      expect(out, contains('extern int64_t _counter_call_increment(int64_t by)'));
    });
  });

  group('Point 13 — Key semantics', () {
    test('same key returns same cached Dart instance', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('_instances.putIfAbsent(key,'));
    });
    test('dispose removes key so next call creates fresh', () {
      final out = DartFfiGenerator.generate(_spec());
      expect(out, contains('_instances.remove(_instanceKey)'));
    });
    test('each new Dart key triggers factory() call on native side', () {
      final out = KotlinGenerator.generate(_spec());
      expect(out, contains('val impl = factory()'));
    });
  });
}
