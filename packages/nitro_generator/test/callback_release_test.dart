// Tests for the callback NativeCallable leak fix.
//
// Every callback-typed parameter setter now uses replace-on-reassign: the
// cache is keyed by "methodName.paramName" only (no closure identity), and
// re-registering closes the previous NativeCallable via
// NitroRuntime.deferredClose instead of accumulating one per call.
//
// The old per-callback native-initiated release mechanism (Kotlin
// `_release_*` externals, the C bridge's `g_cb_release_*` global map +
// `registerCallbackRelease`, and the Dart `_callbackPtrToKey`/
// `_callbackReleasePort`/`_registerCallbackReleasePtr` trio) was dead code —
// nothing generated ever called it — and has been removed entirely rather
// than completed on Swift/C++.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// A spec with two functions that share a callback param name.
// "onEvent" appears in both — _invoke_onEvent should be deduplicated.
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
        // Same name as above — _invoke_onEvent should be emitted only once,
        // but the two setters use independent cache slots ("subscribe.onEvent"
        // vs "subscribeOnce.onEvent") since they belong to different methods.
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
        // Different param name — its own independent cache slot.
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

// A spec with no callback params — should NOT emit any callback machinery.
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
  group('Kotlin — dead _release_* mechanism removed', () {
    test('Kotlin still emits _invoke_onEvent and _invoke_filter', () {
      final out = KotlinGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('@JvmStatic external fun _invoke_onEvent(callbackPtr: Long, arg0: Long)'));
      expect(out, contains('@JvmStatic external fun _invoke_filter'));
    });

    test('Kotlin deduplicates the _invoke_onEvent external declaration across two functions', () {
      final out = KotlinGenerator.generate(_callbackReleaseSpec());
      final count = '@JvmStatic external fun _invoke_onEvent'.allMatches(out).length;
      expect(count, equals(1));
    });

    test('Kotlin does NOT emit any _release_* external', () {
      final out = KotlinGenerator.generate(_callbackReleaseSpec());
      expect(out, isNot(contains('_release_')));
    });
  });

  group('C bridge — dead release infrastructure removed', () {
    test('C bridge does NOT emit <mutex> or <unordered_map> for callbacks alone', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      expect(out, isNot(contains('#include <mutex>')));
      expect(out, isNot(contains('#include <unordered_map>')));
    });

    test('C bridge does NOT emit g_cb_release_* globals or registerCallbackRelease', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      expect(out, isNot(contains('g_cb_release_mtx')));
      expect(out, isNot(contains('g_cb_release_ports')));
      expect(out, isNot(contains('registerCallbackRelease')));
    });

    test('C bridge does NOT emit JNI _release_* implementations', () {
      final out = CppBridgeGenerator.generate(_callbackReleaseSpec());
      // JNI mangling: _release_onEvent → _1release_1onEvent
      expect(out, isNot(contains('_1release_1onEvent')));
      expect(out, isNot(contains('_1release_1filter')));
    });

    test('C bridge does NOT emit release infrastructure when no callbacks', () {
      final out = CppBridgeGenerator.generate(_noCallbackSpec());
      expect(out, isNot(contains('g_cb_release_mtx')));
      expect(out, isNot(contains('registerCallbackRelease')));
    });
  });

  group('Dart — replace-on-reassign, no leak-prone identity cache', () {
    test('Dart emits a plain String-keyed cache (no closure in the key)', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('final Map<String, NativeCallable<dynamic>> _nativeCallbackCache = {};'));
    });

    test('Dart callback helper uses independent keys per method.param slot', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains("const key = 'subscribe.onEvent';"));
      expect(out, contains("const key = 'subscribeOnce.onEvent';"));
      expect(out, contains("const key = 'addFilter.filter';"));
    });

    test('Dart callback helper replaces the slot and defers closing the old callable', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('final old = _nativeCallbackCache[key];'));
      expect(out, contains('_nativeCallbackCache[key] = nc;'));
      expect(out, contains('NitroRuntime.deferredClose(old);'));
    });

    test('Dart callback helper does NOT cache-hit-and-return on a fresh closure', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      // The old leak-prone shape checked containsKey(key) and returned early —
      // that branch (and the closure-in-key tuple) must be gone.
      expect(out, isNot(contains('containsKey(key)')));
      expect(out, isNot(contains(', callback);'))); // tuple key `(name, callback)`
    });

    test('Dart does NOT emit any of the removed release-mechanism symbols', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, isNot(contains('_callbackPtrToKey')));
      expect(out, isNot(contains('_callbackReleasePort')));
      expect(out, isNot(contains('_registerCallbackReleasePtr')));
    });

    test('Dart dispose() still closes every cached callable and clears the map', () {
      final out = DartFfiGenerator.generate(_callbackReleaseSpec());
      expect(out, contains('for (final callback in _nativeCallbackCache.values) {'));
      expect(out, contains('callback.close();'));
      expect(out, contains('_nativeCallbackCache.clear();'));
    });

    test('Dart does NOT emit any callback cache/fields when no callback params', () {
      final out = DartFfiGenerator.generate(_noCallbackSpec());
      expect(out, isNot(contains('_nativeCallbackCache')));
      expect(out, isNot(contains('_callbackPtrToKey')));
      expect(out, isNot(contains('_callbackReleasePort')));
      expect(out, isNot(contains('_registerCallbackReleasePtr')));
    });
  });
}
