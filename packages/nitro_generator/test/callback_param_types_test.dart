// Tests for generated callback parameter types across all four generators.
//
// For each Dart callback param type (int, double, bool, String, enum) verifies:
// - C++ JNI `_invoke_` function: correct `jXxx` param + C typedef type
// - Kotlin external `_invoke_` fun: correct Kotlin JVM type
// - Swift `@_cdecl` stub: correct `@convention(c)` type + wrapper conversion
// - Dart FFI NativeCallable: correct FFI type + Dart conversion in listener

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

// ── Record fixture ─────────────────────────────────────────────────────────────

BridgeSpec _recordSpec({required List<BridgeType> cbParams, List<BridgeRecordType> records = const []}) {
  return BridgeSpec(
    dartClassName: 'Analytics',
    lib: 'analytics',
    namespace: 'analytics',
    androidImpl: NativeImpl.kotlin,
    iosImpl: NativeImpl.swift,
    sourceUri: 'analytics.native.dart',
    recordTypes: records,
    functions: [
      BridgeFunction(
        dartName: 'onEvent',
        cSymbol: 'analytics_on_event',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'handler',
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

// ── Helpers ───────────────────────────────────────────────────────────────────

final _stateEnum = BridgeEnum(
  name: 'DeviceState',
  startValue: 0,
  values: ['active', 'idle', 'error'],
);

final _readingStruct = BridgeStruct(
  name: 'SensorReading',
  packed: false,
  fields: [
    BridgeField(name: 'value', type: BridgeType(name: 'double')),
    BridgeField(name: 'ts', type: BridgeType(name: 'int')),
  ],
);

BridgeSpec _spec({
  required List<BridgeType> cbParams,
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) {
  return BridgeSpec(
    dartClassName: 'Device',
    lib: 'device',
    namespace: 'device',
    androidImpl: NativeImpl.kotlin,
    iosImpl: NativeImpl.swift,
    sourceUri: 'device.native.dart',
    enums: enums,
    structs: structs,
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

    test('double → jlong (IEEE 754 bits) passed as int64_t (exact NativeCallable<Int64> ABI)', () {
      final out = CppBridgeGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      // double encoded as jlong; typedef uses int64_t to exactly match NativeCallable<Void Function(Int64)>.
      expect(out, contains('jlong callbackPtr, jlong arg0'));
      expect(out, contains('typedef void (*CB)(int64_t);'));
      expect(out, contains('(int64_t)arg0'));
    });

    test('bool → jlong (0/1) passed as int64_t (exact NativeCallable<Int64> ABI)', () {
      final out = CppBridgeGenerator.generate(_spec(cbParams: [BridgeType(name: 'bool')]));
      // bool encoded as 1L/0L jlong; typedef uses int64_t to exactly match NativeCallable<Void Function(Int64)>.
      expect(out, contains('jlong callbackPtr, jlong arg0'));
      expect(out, contains('typedef void (*CB)(int64_t);'));
      expect(out, contains('(int64_t)arg0'));
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
      // bool and double both use jlong/int64_t for NativeCallable<Int64> ABI match.
      expect(out, contains('jlong callbackPtr, jlong arg0, jlong arg1, jlong arg2, jstring arg3, jlong arg4'));
      expect(out, contains('typedef void (*CB)(int64_t, int64_t, int64_t, const char*, int64_t);'));
      expect(out, contains('const char* s_arg3 = arg3 ? env->GetStringUTFChars(arg3, nullptr) : nullptr;'));
      expect(out, contains('ReleaseStringUTFChars(arg3, s_arg3)'));
      // All args passed as int64_t.
      expect(out, contains('((CB)callbackPtr)((int64_t)arg0, (int64_t)arg1, (int64_t)arg2, s_arg3, (int64_t)arg4);'));
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

    test('double → Long (raw IEEE 754 bits for synchronous NativeCallable)', () {
      final out = KotlinGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long, arg0: Long)'));
    });

    test('bool → Long (1L/0L encoding for synchronous NativeCallable)', () {
      final out = KotlinGenerator.generate(_spec(cbParams: [BridgeType(name: 'bool')]));
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long, arg0: Long)'));
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
      // bool and double both use Long for synchronous NativeCallable firing.
      expect(
        out,
        contains('external fun _invoke_callback(callbackPtr: Long, arg0: Long, arg1: Long, arg2: Long, arg3: String?, arg4: Long)'),
      );
    });

    test('enum lambda arg → p0.nativeValue (converts to Long)', () {
      final out = KotlinGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'DeviceState')], enums: [_stateEnum]),
      );
      expect(out, contains('p0.nativeValue'));
    });

    test('double lambda arg → java.lang.Double.doubleToRawLongBits(p0)', () {
      final out = KotlinGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('java.lang.Double.doubleToRawLongBits(p0)'));
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

    test('double → Int64 in @convention(c), Int64.bitPattern in wrapper', () {
      // double uses Int64 (raw IEEE 754 bits) so Dart NativeCallable reads from
      // GP registers (x0, x1, ...), not FP registers (d0, d1, ...).
      final out = SwiftGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('@convention(c) (Int64) -> Void'));
      expect(out, contains('{ arg0 in callback(Int64(bitPattern: arg0.bitPattern)) }'));
      expect(out, isNot(contains('@convention(c) (Double) -> Void')));
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
      // double uses Int64 (raw IEEE 754 bits) — same GP register as int, enum.
      expect(out, contains('@convention(c) (Int64, Int64, Bool, UnsafePointer<CChar>?, Int64) -> Void'));
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
      // double arg1 is converted to Int64.bitPattern so it stays in GP registers.
      expect(out, contains(
        '{ arg0, arg1, arg2, arg3, arg4 in callback(arg0.rawValue, Int64(bitPattern: arg1.bitPattern), arg2, (arg3 as NSString).utf8String, arg4) }',
      ));
    });

    test('empty callback → empty @convention(c) and wrapper calls directly', () {
      final out = SwiftGenerator.generate(_spec(cbParams: []));
      expect(out, contains('@convention(c) () -> Void'));
      expect(out, contains('{ callback() }'));
    });
  });

  // ── @HybridStruct callback param ───────────────────────────────────────────
  group('@HybridStruct callback parameter types', () {
    test('spec validator accepts struct callback params', () {
      // Previously rejected; structs are now a supported callback param type.
      final spec = _spec(
        cbParams: [BridgeType(name: 'SensorReading')],
        structs: [_readingStruct],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('C++ JNI → jobject param + pack_*_from_jni + const StructName* in typedef', () {
      final out = CppBridgeGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'SensorReading')], structs: [_readingStruct]),
      );
      expect(out, contains('jlong callbackPtr, jobject arg0'));
      expect(out, contains('typedef void (*CB)(const SensorReading*);'));
      expect(out, contains('SensorReading c_arg0 = pack_SensorReading_from_jni(env, arg0);'));
      expect(out, contains('((CB)callbackPtr)(&c_arg0);'));
    });

    test('Kotlin _invoke_ → struct data class param type', () {
      final out = KotlinGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'SensorReading')], structs: [_readingStruct]),
      );
      expect(out, contains('external fun _invoke_callback(callbackPtr: Long, arg0: SensorReading)'));
      expect(out, isNot(contains('arg0: Long')));
    });

    test('Kotlin lambda → passes data class directly (no nativeValue)', () {
      final out = KotlinGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'SensorReading')], structs: [_readingStruct]),
      );
      expect(out, contains('_invoke_callback(callback, p0)'));
      expect(out, isNot(contains('p0.nativeValue')));
    });

    test('Swift @convention(c) → UnsafeRawPointer? for struct param', () {
      final out = SwiftGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'SensorReading')], structs: [_readingStruct]),
      );
      expect(out, contains('@convention(c) (UnsafeRawPointer?) -> Void'));
      expect(out, isNot(contains('@convention(c) (Int64) -> Void')));
    });

    test('Swift protocol → idiomatic Swift struct type in callback', () {
      final out = SwiftGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'SensorReading')], structs: [_readingStruct]),
      );
      expect(out, contains('callback: @escaping (SensorReading) -> Void'));
    });

    test('Swift wrapper → shadow struct + UnsafeRawPointer(&_s0)', () {
      final out = SwiftGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'SensorReading')], structs: [_readingStruct]),
      );
      expect(out, contains('var _s0 = _SensorReadingC.fromSwift(arg0)'));
      expect(out, contains('UnsafeRawPointer(&_s0)'));
    });

    test('Dart FFI → Void Function(Pointer<Void>), casts to StructFfi', () {
      final out = DartFfiGenerator.generate(
        _spec(cbParams: [BridgeType(name: 'SensorReading')], structs: [_readingStruct]),
      );
      expect(out, contains('NativeCallable<Void Function(Pointer<Void>)>'));
      expect(out, contains('arg0.cast<SensorReadingFfi>().ref.toDart()'));
    });

    test('mixed struct + primitive → correct types for all positions', () {
      final out = CppBridgeGenerator.generate(
        _spec(
          cbParams: [
            BridgeType(name: 'SensorReading'),
            BridgeType(name: 'int'),
            BridgeType(name: 'bool'),
          ],
          structs: [_readingStruct],
        ),
      );
      // bool uses jlong/int64_t for NativeCallable<Int64> ABI match.
      expect(out, contains('jlong callbackPtr, jobject arg0, jlong arg1, jlong arg2'));
      expect(out, contains('typedef void (*CB)(const SensorReading*, int64_t, int64_t);'));
      expect(out, contains('SensorReading c_arg0 = pack_SensorReading_from_jni(env, arg0);'));
      expect(out, contains('(int64_t)arg2'));
    });
  });

  // ── @HybridRecord callback param ───────────────────────────────────────────
  group('@HybridRecord callback parameter types', () {
    final eventRecord = BridgeRecordType(
      name: 'AnalyticsEvent',
      fields: [
        BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive),
      ],
    );

    test('spec validator accepts record callback params', () {
      final spec = _recordSpec(
        cbParams: [BridgeType(name: 'AnalyticsEvent', isRecord: true)],
        records: [eventRecord],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('C++ JNI → jbyteArray param + malloc copy + const uint8_t* in typedef', () {
      final out = CppBridgeGenerator.generate(
        _recordSpec(
          cbParams: [BridgeType(name: 'AnalyticsEvent', isRecord: true)],
          records: [eventRecord],
        ),
      );
      expect(out, contains('jlong callbackPtr, jbyteArray arg0'));
      expect(out, contains('typedef void (*CB)(const uint8_t*);'));
      expect(out, contains('jsize r_len0 = env->GetArrayLength(arg0);'));
      expect(out, contains('uint8_t* r_buf0 = (uint8_t*)malloc((size_t)r_len0);'));
      expect(out, contains('env->GetByteArrayRegion(arg0, 0, r_len0, (jbyte*)r_buf0);'));
      expect(out, contains('((CB)callbackPtr)(r_buf0);'));
    });

    test('Kotlin _invoke_ → ByteArray param type', () {
      final out = KotlinGenerator.generate(
        _recordSpec(
          cbParams: [BridgeType(name: 'AnalyticsEvent', isRecord: true)],
          records: [eventRecord],
        ),
      );
      expect(out, contains('external fun _invoke_handler(callbackPtr: Long, arg0: ByteArray)'));
    });

    test('Kotlin lambda → .encode() to serialize record', () {
      final out = KotlinGenerator.generate(
        _recordSpec(
          cbParams: [BridgeType(name: 'AnalyticsEvent', isRecord: true)],
          records: [eventRecord],
        ),
      );
      expect(out, contains('_invoke_handler(handler, p0.encode())'));
    });

    test('Swift @convention(c) → UnsafeMutablePointer<UInt8>? for record', () {
      final out = SwiftGenerator.generate(
        _recordSpec(
          cbParams: [BridgeType(name: 'AnalyticsEvent', isRecord: true)],
          records: [eventRecord],
        ),
      );
      expect(out, contains('@convention(c) (UnsafeMutablePointer<UInt8>?) -> Void'));
    });

    test('Swift protocol → idiomatic record type in callback', () {
      final out = SwiftGenerator.generate(
        _recordSpec(
          cbParams: [BridgeType(name: 'AnalyticsEvent', isRecord: true)],
          records: [eventRecord],
        ),
      );
      expect(out, contains('handler: @escaping (AnalyticsEvent) -> Void'));
    });

    test('Swift wrapper → toNative() to serialize record to malloc buffer', () {
      final out = SwiftGenerator.generate(
        _recordSpec(
          cbParams: [BridgeType(name: 'AnalyticsEvent', isRecord: true)],
          records: [eventRecord],
        ),
      );
      expect(out, contains('arg0.toNative()'));
    });

    test('Dart FFI → Void Function(Pointer<Uint8>), fromNative + malloc.free', () {
      final out = DartFfiGenerator.generate(
        _recordSpec(
          cbParams: [BridgeType(name: 'AnalyticsEvent', isRecord: true)],
          records: [eventRecord],
        ),
      );
      expect(out, contains('NativeCallable<Void Function(Pointer<Uint8>)>'));
      expect(out, contains('AnalyticsEvent.fromNative(arg0)'));
      expect(out, contains('malloc.free(arg0)'));
    });
  });

  // ── Dart FFI NativeCallable ─────────────────────────────────────────────────
  group('Dart FFI NativeCallable signature per callback param type', () {
    test('int → Void Function(Int64), no conversion', () {
      final out = DartFfiGenerator.generate(_spec(cbParams: [BridgeType(name: 'int')]));
      expect(out, contains('NativeCallable<Void Function(Int64)>'));
      expect(out, contains('callback(arg0);'));
    });

    test('double → Void Function(Int64), decodes via Int64List bits', () {
      // double is encoded as raw IEEE 754 bits in Int64 for synchronous NativeCallable.
      final out = DartFfiGenerator.generate(_spec(cbParams: [BridgeType(name: 'double')]));
      expect(out, contains('NativeCallable<Void Function(Int64)>'));
      expect(out, contains('Int64List.fromList([arg0]).buffer.asFloat64List()[0]'));
    });

    test('bool → Void Function(Int64), converts != 0 from Int64', () {
      // bool is encoded as 1L/0L in Int64 for synchronous NativeCallable.
      final out = DartFfiGenerator.generate(_spec(cbParams: [BridgeType(name: 'bool')]));
      expect(out, contains('NativeCallable<Void Function(Int64)>'));
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
      // bool and double both use Int64 for synchronous NativeCallable firing.
      expect(out, contains('Void Function(Int64, Int64, Int64, Pointer<Utf8>, Int64)'));
    });

    test('empty callback → Void Function()', () {
      final out = DartFfiGenerator.generate(_spec(cbParams: []));
      expect(out, contains('NativeCallable<Void Function()>'));
    });
  });
}
