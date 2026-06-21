/// Tests for generated callback parameter types across all four generators.
///
/// For each Dart callback param type (int, double, bool, String, enum) verifies:
/// - C++ JNI `_invoke_` function: correct `jXxx` param + C typedef type
/// - Kotlin external `_invoke_` fun: correct Kotlin JVM type
/// - Swift `@_cdecl` stub: correct `@convention(c)` type + wrapper conversion
/// - Dart FFI NativeCallable: correct FFI type + Dart conversion in listener
library callback_param_types_test;

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

final _stateEnum = BridgeEnum(
  name: 'DeviceState',
  startValue: 0,
  values: ['active', 'idle', 'error'],
);

BridgeSpec _spec({
  required List<BridgeType> cbParams,
  List<BridgeEnum> enums = const [],
}) {
  return BridgeSpec(
    dartClassName: 'Device',
    lib: 'device',
    namespace: 'device',
    androidImpl: NativeImpl.kotlin,
    iosImpl: NativeImpl.swift,
    sourceUri: 'device.native.dart',
    enums: enums,
    functions: [
      BridgeFunction(
        dartName: 'subscribe',
        cSymbol: 'device_subscribe',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'callback',
            type: BridgeType(
              name: 'Function',
              isFunction: true,
              functionReturnType: 'void',
              functionParams: cbParams,
            ),
          ),
        ],
      ),
    ],
  );
}

// ── Main ──────────────────────────────────────────────────────────────────────

void main() {
  // ── C++ JNI `_invoke_callback` ─────────────────────────────────────────────
  group('C++ JNI _invoke_ parameter types', () {
    test('int → jlong + int64_t', () {
      final out = CppBridgeGenerator.generate(_spec(cbParams: [BridgeType(name: 'int')]));
      expect(out, contains('jlong callbackPtr, jlong arg0'));
      expect(out, contains('typedef void (*CB)(int64_t);'));
      expect(out, contains('((CB)callbackPtr)((int64_t)arg0);'));
    });

    test('double → jdouble + double', () {
      final out = CppBridgeGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('jlong callbackPtr, jdouble arg0'));
      expect(out, contains('typedef void (*CB)(double);'));
      expect(out, contains('((CB)callbackPtr)((double)arg0);'));
      expect(out, isNot(contains('jlong arg0')));
    });

    test('bool → jboolean + bool', () {
      final out = CppBridgeGenerator.generate(_spec(cbParams: [BridgeType(name: 'bool')]));
      expect(out, contains('jlong callbackPtr, jboolean arg0'));
      expect(out, contains('typedef void (*CB)(bool);'));
      expect(out, contains('((CB)callbackPtr)((bool)arg0);'));
    });

    test('String → jstring + const char* with GetStringUTFChars', () {
      final out = CppBridgeGenerator.generate(_spec(cbParams: [BridgeType(name: 'String')]));
      expect(out, contains('jlong callbackPtr, jstring arg0'));
      expect(out, contains('typedef void (*CB)(const char*);'));
      expect(out, contains('GetStringUTFChars(arg0, nullptr)'));
      expect(out, contains('ReleaseStringUTFChars(arg0, s_arg0)'));
      expect(out, contains('((CB)callbackPtr)(s_arg0);'));
    });

    test('enum → jlong + int64_t (same as int)', () {
      final out = CppBridgeGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'DeviceState')], enums: [_stateEnum]),
      );
      expect(out, contains('jlong callbackPtr, jlong arg0'));
      expect(out, contains('typedef void (*CB)(int64_t);'));
    });

    test('mixed params → correct type per position', () {
      final out = CppBridgeGenerator.generate(
        _spec(
          cbParams: [
            BridgeType(name: 'DeviceState'),
            BridgeType(name: 'double'),
            BridgeType(name: 'bool'),
            BridgeType(name: 'String'),
            BridgeType(name: 'int'),
          ],
          enums: [_stateEnum],
        ),
      );
      expect(out, contains('jlong callbackPtr, jlong arg0, jdouble arg1, jboolean arg2, jstring arg3, jlong arg4'));
      expect(out, contains('typedef void (*CB)(int64_t, double, bool, const char*, int64_t);'));
      expect(out, contains('const char* s_arg3 = arg3 ? env->GetStringUTFChars(arg3, nullptr) : nullptr;'));
      expect(out, contains('ReleaseStringUTFChars(arg3, s_arg3)'));
      expect(out, contains('((CB)callbackPtr)((int64_t)arg0, (double)arg1, (bool)arg2, s_arg3, (int64_t)arg4);'));
    });

    test('no String params → no s_arg string conversion variables in _invoke_', () {
      final out = CppBridgeGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'int'), BridgeType(name: 'double')]),
      );
      // GetStringUTFChars/ReleaseStringUTFChars appear in the always-present JNI
      // exception reporter, but s_argN conversion variables are _invoke_-specific.
      expect(out, isNot(contains('const char* s_arg')));
    });

    test('empty params → void typedef', () {
      final out = CppBridgeGenerator.generate(_spec(cbParams: []));
      expect(out, contains('typedef void (*CB)(void);'));
      expect(out, contains('((CB)callbackPtr)();'));
    });
  });

  // ── Kotlin `_invoke_` external fun ─────────────────────────────────────────
  group('Kotlin _invoke_ external fun parameter types', () {
    test('int → Long', () {
      final out = KotlinGenerator.generate(_spec(cbParams: [BridgeType(name: 'int')]));
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long, arg0: Long)'));
    });

    test('double → Double', () {
      final out = KotlinGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long, arg0: Double)'));
      expect(out, isNot(contains('arg0: Long')));
    });

    test('bool → Boolean', () {
      final out = KotlinGenerator.generate(_spec(cbParams: [BridgeType(name: 'bool')]));
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long, arg0: Boolean)'));
    });

    test('String → String?', () {
      final out = KotlinGenerator.generate(_spec(cbParams: [BridgeType(name: 'String')]));
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long, arg0: String?)'));
    });

    test('enum → Long', () {
      final out = KotlinGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'DeviceState')], enums: [_stateEnum]),
      );
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long, arg0: Long)'));
    });

    test('mixed → correct Kotlin type per position', () {
      final out = KotlinGenerator.generate(
        _spec(
          cbParams: [
            BridgeType(name: 'DeviceState'),
            BridgeType(name: 'double'),
            BridgeType(name: 'bool'),
            BridgeType(name: 'String'),
            BridgeType(name: 'int'),
          ],
          enums: [_stateEnum],
        ),
      );
      expect(
        out,
        contains('external fun _invoke_callback(callbackPtr: Long, arg0: Long, arg1: Double, arg2: Boolean, arg3: String?, arg4: Long)'),
      );
    });

    test('enum lambda arg → p0.nativeValue (converts to Long)', () {
      final out = KotlinGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'DeviceState')], enums: [_stateEnum]),
      );
      expect(out, contains('p0.nativeValue'));
    });

    test('double lambda arg → p0 directly (no conversion needed)', () {
      final out = KotlinGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('_invoke_callback(callback, p0)'));
      expect(out, isNot(contains('p0.nativeValue')));
    });

    test('empty callback → no extra args in _invoke_', () {
      final out = KotlinGenerator.generate(_spec(cbParams: []));
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long)'));
    });
  });

  // ── Swift @_cdecl + callback wrapper ───────────────────────────────────────
  group('Swift @_cdecl callback parameter types', () {
    test('int → Int64 in @convention(c), pass-through in wrapper', () {
      final out = SwiftGenerator.generate(_spec(cbParams: [BridgeType(name: 'int')]));
      expect(out, contains('@convention(c) (Int64) -> Void'));
      expect(out, contains('{ arg0 in callback(arg0) }'));
    });

    test('double → Double in @convention(c), pass-through in wrapper', () {
      final out = SwiftGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('@convention(c) (Double) -> Void'));
      expect(out, contains('{ arg0 in callback(arg0) }'));
      expect(out, isNot(contains('@convention(c) (Int64) -> Void')));
    });

    test('bool → Bool in @convention(c), pass-through in wrapper', () {
      final out = SwiftGenerator.generate(_spec(cbParams: [BridgeType(name: 'bool')]));
      expect(out, contains('@convention(c) (Bool) -> Void'));
      expect(out, contains('{ arg0 in callback(arg0) }'));
    });

    test('String → UnsafePointer<CChar>? in @convention(c), NSString.utf8String in wrapper', () {
      final out = SwiftGenerator.generate(_spec(cbParams: [BridgeType(name: 'String')]));
      expect(out, contains('@convention(c) (UnsafePointer<CChar>?) -> Void'));
      expect(out, contains('(arg0 as NSString).utf8String'));
      expect(out, isNot(contains('@convention(c) (Int64) -> Void')));
    });

    test('enum → Int64 in @convention(c), .rawValue in wrapper', () {
      final out = SwiftGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'DeviceState')], enums: [_stateEnum]),
      );
      expect(out, contains('@convention(c) (Int64) -> Void'));
      expect(out, contains('{ arg0 in callback(arg0.rawValue) }'));
      expect(out, isNot(contains('DeviceState(rawValue: arg0)')));
    });

    test('enum protocol param is idiomatic Swift type (not Int64)', () {
      final out = SwiftGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'DeviceState')], enums: [_stateEnum]),
      );
      expect(out, contains('callback: @escaping (DeviceState) -> Void'));
    });

    test('mixed → correct @convention(c) type per position', () {
      final out = SwiftGenerator.generate(
        _spec(
          cbParams: [
            BridgeType(name: 'DeviceState'),
            BridgeType(name: 'double'),
            BridgeType(name: 'bool'),
            BridgeType(name: 'String'),
            BridgeType(name: 'int'),
          ],
          enums: [_stateEnum],
        ),
      );
      expect(out, contains('@convention(c) (Int64, Double, Bool, UnsafePointer<CChar>?, Int64) -> Void'));
    });

    test('mixed protocol signature uses idiomatic Swift types', () {
      final out = SwiftGenerator.generate(
        _spec(
          cbParams: [
            BridgeType(name: 'DeviceState'),
            BridgeType(name: 'double'),
            BridgeType(name: 'bool'),
            BridgeType(name: 'String'),
            BridgeType(name: 'int'),
          ],
          enums: [_stateEnum],
        ),
      );
      expect(out, contains('callback: @escaping (DeviceState, Double, Bool, String, Int64) -> Void'));
    });

    test('mixed wrapper closure converts each arg correctly', () {
      final out = SwiftGenerator.generate(
        _spec(
          cbParams: [
            BridgeType(name: 'DeviceState'),
            BridgeType(name: 'double'),
            BridgeType(name: 'bool'),
            BridgeType(name: 'String'),
            BridgeType(name: 'int'),
          ],
          enums: [_stateEnum],
        ),
      );
      expect(out, contains(
        '{ arg0, arg1, arg2, arg3, arg4 in callback(arg0.rawValue, arg1, arg2, (arg3 as NSString).utf8String, arg4) }',
      ));
    });

    test('empty callback → empty @convention(c) and wrapper calls directly', () {
      final out = SwiftGenerator.generate(_spec(cbParams: []));
      expect(out, contains('@convention(c) () -> Void'));
      expect(out, contains('{ callback() }'));
    });
  });

  // ── Dart FFI NativeCallable ─────────────────────────────────────────────────
  group('Dart FFI NativeCallable signature per callback param type', () {
    test('int → Void Function(Int64), no conversion', () {
      final out = DartFfiGenerator.generate(_spec(cbParams: [BridgeType(name: 'int')]));
      expect(out, contains('NativeCallable<Void Function(Int64)>'));
      expect(out, contains('callback(arg0);'));
    });

    test('double → Void Function(Double), no conversion', () {
      final out = DartFfiGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('NativeCallable<Void Function(Double)>'));
      expect(out, contains('callback(arg0);'));
    });

    test('bool → Void Function(Int8), converts != 0', () {
      final out = DartFfiGenerator.generate(_spec(cbParams: [BridgeType(name: 'bool')]));
      expect(out, contains('NativeCallable<Void Function(Int8)>'));
      expect(out, contains('callback(arg0 != 0);'));
    });

    test('String → Void Function(Pointer<Utf8>), converts toDartString()', () {
      final out = DartFfiGenerator.generate(_spec(cbParams: [BridgeType(name: 'String')]));
      expect(out, contains('NativeCallable<Void Function(Pointer<Utf8>)>'));
      expect(out, contains('callback(arg0.toDartString());'));
    });

    test('enum → Void Function(Int64), converts to enum via toEnumType()', () {
      final out = DartFfiGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'DeviceState')], enums: [_stateEnum]),
      );
      expect(out, contains('NativeCallable<Void Function(Int64)>'));
      expect(out, contains('callback(arg0.toDeviceState());'));
    });

    test('mixed → correct FFI types for all positions', () {
      final out = DartFfiGenerator.generate(
        _spec(
          cbParams: [
            BridgeType(name: 'DeviceState'),
            BridgeType(name: 'double'),
            BridgeType(name: 'bool'),
            BridgeType(name: 'String'),
            BridgeType(name: 'int'),
          ],
          enums: [_stateEnum],
        ),
      );
      expect(out, contains('Void Function(Int64, Double, Int8, Pointer<Utf8>, Int64)'));
    });

    test('empty callback → Void Function()', () {
      final out = DartFfiGenerator.generate(_spec(cbParams: []));
      expect(out, contains('NativeCallable<Void Function()>'));
    });
  });
}
