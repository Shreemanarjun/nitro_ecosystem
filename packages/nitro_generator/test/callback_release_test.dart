// Tests for Point 10: Per-callback close/release mechanism.
//
// Verifies that the generator emits:
//   • Kotlin: `_release_${paramName}(callbackPtr: Long)` external per unique callback param
//   • C bridge: global std::unordered_map + NITRO_EXPORT registerCallbackRelease + JNI _release_* impl
//   • Dart: _callbackPtrToKey reverse map, _callbackReleasePort, _registerCallbackReleasePtr field,
//           registration inside callback helper, and port close in dispose()
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// A spec with two functions that share a callback param name.
// "onEvent" appears in both — _release_onEvent should be deduplicated.
BridgeSpec _callbackReleaseSpec() => BridgeSpec(
  dartClassName: 'EventBus',
  lib: 'event-bus',
  namespace: 'event_bus',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'event_bus.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'subscribe',
      cSymbol: 'event_bus_subscribe',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'onEvent',
          type: BridgeType(
            name: 'Function',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'int')],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'subscribeOnce',
      cSymbol: 'event_bus_subscribe_once',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        // Same name as above — _release_onEvent should be emitted only once
        BridgeParam(
          name: 'onEvent',
          type: BridgeType(
            name: 'Function',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'int')],
          ),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'addFilter',
      cSymbol: 'event_bus_add_filter',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        // Different param name — _release_filter should also be emitted
        BridgeParam(
          name: 'filter',
          type: BridgeType(
            name: 'Function',
            isFunction: true,
            functionReturnType: 'bool',
            functionParams: [BridgeType(name: 'String')],
          ),
        ),
      ],
    ),
  ],
);

// A spec with no callback params — should NOT emit release infrastructure.
BridgeSpec _noCallbackSpec() => BridgeSpec(
  dartClassName: 'Counter',
  lib: 'counter',
  namespace: 'counter',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'counter.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'increment',
      cSymbol: 'counter_increment',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
  ],
);

void main() {
  group('Point 10 — Kotlin: _release_* externals', () {
    test('Kotlin emits _release_onEvent alongside _invoke_onEvent', () {
      final out = KotlinGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('@JvmStatic external fun _release_onEvent(callbackPtr: Long)'));
      expect(out, contains('@JvmStatic external fun _invoke_onEvent(callbackPtr: Long, arg0: Long)'));
    });

    test('Kotlin emits _release_filter for second unique callback param', () {
      final out = KotlinGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('@JvmStatic external fun _release_filter(callbackPtr: Long)'));
    });

    test('Kotlin deduplicates _release_onEvent across two functions', () {
      final out = KotlinGenerator.generate(_callbackReleaseSpec());
      final count = '_release_onEvent'.allMatches(out).length;
      // Should appear exactly once (deduplicated)
      expect(count, equals(1));
    });

    test('Kotlin does NOT emit _release_* when no callback params exist', () {
      final out = KotlinGenerator.generate(_noCallbackSpec());
      expect(out, isNot(contains('_release_')));
    });
  });

  group('Point 10 — C bridge: global map + NITRO_EXPORT + JNI _release_*', () {
    test('C bridge emits <mutex> and <unordered_map> includes when callbacks present', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('#include <mutex>'));
      expect(out, contains('#include <unordered_map>'));
    });

    test('C bridge does NOT emit <mutex> or <unordered_map> when no callbacks', () {
      final out = CppBridgeGenerator.generate(_noCallbackSpec());
      expect(out, isNot(contains('#include <mutex>')));
      expect(out, isNot(contains('#include <unordered_map>')));
    });

    test('C bridge emits global g_cb_release_mtx and g_cb_release_ports', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('static std::mutex g_cb_release_mtx;'));
      expect(out, contains('static std::unordered_map<int64_t, Dart_Port> g_cb_release_ports;'));
    });

    test('C bridge emits NITRO_EXPORT event_bus_registerCallbackRelease', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('NITRO_EXPORT void event_bus_registerCallbackRelease'));
      expect(out, contains('g_cb_release_ports[callbackPtr] = (Dart_Port)releasePort'));
    });

    test('NITRO_EXPORT registerCallbackRelease takes (int64_t, int64_t) params', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('event_bus_registerCallbackRelease(int64_t callbackPtr, int64_t releasePort)'));
    });

    test('C bridge emits JNI _release_onEvent inside Android section', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      // JNI mangling: _release_onEvent → _1release_1onEvent
      expect(out, contains('_1release_1onEvent'));
      expect(out, contains('g_cb_release_ports.find(callbackPtr)'));
      expect(out, contains('Dart_PostCObject_DL(it->second, &msg)'));
      expect(out, contains('g_cb_release_ports.erase(it)'));
    });

    test('C bridge emits JNI _release_filter for second param name', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      // JNI mangling: _release_filter → _1release_1filter
      expect(out, contains('_1release_1filter'));
    });

    test('_release_* posts int64 callbackPtr value to Dart port', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('msg.type = Dart_CObject_kInt64; msg.value.as_int64 = callbackPtr'));
    });

    test('C bridge does NOT emit release infrastructure when no callbacks', () {
      final out = CppBridgeGenerator.generate(_noCallbackSpec());
      expect(out, isNot(contains('g_cb_release_mtx')));
      expect(out, isNot(contains('registerCallbackRelease')));
    });

    test('global map appears BEFORE the #ifdef __ANDROID__ section', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      final mapIdx = out.indexOf('g_cb_release_mtx');
      final androidIdx = out.indexOf('#ifdef __ANDROID__');
      expect(mapIdx, isNot(-1));
      expect(androidIdx, isNot(-1));
      // Global map must come before the Android-only JNI section.
      expect(mapIdx, lessThan(androidIdx));
    });
  });

  group('Point 10 — Dart: reverse map, release port, registration', () {
    test('Dart emits _callbackPtrToKey reverse map field', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('final Map<int, Object> _callbackPtrToKey = {};'));
    });

    test('Dart emits _callbackReleasePort as late final ReceivePort', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('late final ReceivePort _callbackReleasePort = ReceivePort()'));
    });

    test('Dart release port listener uses _callbackPtrToKey to close NativeCallable', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('final key = _callbackPtrToKey.remove(msg)'));
      expect(out, contains('if (key != null) _nativeCallbackCache.remove(key)?.close()'));
    });

    test('Dart emits _registerCallbackReleasePtr lookup field', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains("'event_bus_registerCallbackRelease'"));
      expect(out, contains('void Function(int, int) _registerCallbackReleasePtr'));
    });

    test('Dart callback helper registers ptr in _callbackPtrToKey', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('_callbackPtrToKey[ptr] = key;'));
      expect(out, contains('final ptr = nc.nativeFunction.address;'));
    });

    test('Dart callback helper calls _registerCallbackReleasePtr with ptr and release port', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('_registerCallbackReleasePtr(ptr, _callbackReleasePort.sendPort.nativePort)'));
    });

    test('Dart dispose() clears _callbackPtrToKey and closes _callbackReleasePort', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('_callbackPtrToKey.clear();'));
      expect(out, contains('_callbackReleasePort.close();'));
    });

    test('Dart does NOT emit release fields when no callback params', () {
      final out = DartFfiGenerator.generate(_noCallbackSpec());
      expect(out, isNot(contains('_callbackPtrToKey')));
      expect(out, isNot(contains('_callbackReleasePort')));
      expect(out, isNot(contains('_registerCallbackReleasePtr')));
    });

    test('Dart callback helper early-exits from cache on second call (no double-registration)', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('if (_nativeCallbackCache.containsKey(key)) {'));
      expect(out, contains('return _nativeCallbackCache[key]! as NativeCallable'));
    });
  });
}
