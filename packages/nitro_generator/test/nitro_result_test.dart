// Tests for @NitroResult method annotation (S4-P6).
//
// Covers:
//   - BridgeFunction.isResult flag
//   - Dart FFI return type: NitroResultValue<T>
//   - Dart FFI method pointer uses Pointer<Uint8> (same as record wire type)
//   - Tag-based decode emitted for sync @NitroResult methods
//   - E015 validation: cannot combine with @NitroNativeAsync (but @nitroAsync is now allowed)
//   - E015 validation: cannot wrap void return type

import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Fixture specs ─────────────────────────────────────────────────────────────

/// Spec with a `@NitroResult<String>` synchronous method.
BridgeSpec _resultStringSpec() => BridgeSpec(
  dartClassName: 'Auth',
  lib: 'auth',
  namespace: 'auth',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'auth.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'login',
      cSymbol: 'auth_login',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'user',
          type: BridgeType(name: 'String'),
        ),
        BridgeParam(
          name: 'pass',
          type: BridgeType(name: 'String'),
        ),
      ],
      isResult: true,
    ),
  ],
);

/// Spec with a `@NitroResult<int>` synchronous method (no arena params).
BridgeSpec _resultIntSpec() => BridgeSpec(
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
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'by',
          type: BridgeType(name: 'int'),
        ),
      ],
      isResult: true,
    ),
  ],
);

/// Spec with a `@NitroResult<bool>` synchronous method (no arena params).
BridgeSpec _resultBoolSpec() => BridgeSpec(
  dartClassName: 'Gate',
  lib: 'gate',
  namespace: 'gate',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'gate.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'check',
      cSymbol: 'gate_check',
      isAsync: false,
      returnType: BridgeType(name: 'bool'),
      params: [],
      isResult: true,
    ),
  ],
);

/// @NitroResult combined with @nitroAsync — now valid (no E015 since the session fix).
BridgeFunction _resultAsyncFunc() => BridgeFunction(
  dartName: 'asyncLogin',
  cSymbol: 'auth_async_login',
  isAsync: true,
  returnType: BridgeType(name: 'String', isFuture: true),
  params: [],
  isResult: true,
);

/// @NitroResult on void return — invalid (E015).
BridgeFunction _resultVoidFunc() => BridgeFunction(
  dartName: 'doSomething',
  cSymbol: 'auth_do_something',
  isAsync: false,
  returnType: BridgeType(name: 'void'),
  params: [],
  isResult: true,
);

/// Spec with a `@NitroResult<double>` synchronous method (no params, no arena).
BridgeSpec _resultDoubleSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'readTemperature',
      cSymbol: 'sensor_read_temperature',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [],
      isResult: true,
    ),
  ],
);

/// Spec with a `@NitroResult<Severity>` enum return — needs enum in spec.
BridgeSpec _resultEnumSpec() => BridgeSpec(
  dartClassName: 'Logger',
  lib: 'logger',
  namespace: 'logger',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'logger.native.dart',
  enums: [
    BridgeEnum(name: 'Severity', startValue: 0, values: ['info', 'warn', 'error']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'classify',
      cSymbol: 'logger_classify',
      isAsync: false,
      returnType: BridgeType(name: 'Severity'),
      params: [
        BridgeParam(
          name: 'code',
          type: BridgeType(name: 'int'),
        ),
      ],
      isResult: true,
    ),
  ],
);

/// Spec with a `@NitroResult<Vec3>` struct return — needs struct in spec.
BridgeSpec _resultStructSpec() => BridgeSpec(
  dartClassName: 'Physics',
  lib: 'physics',
  namespace: 'physics',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'physics.native.dart',
  structs: [
    BridgeStruct(
      name: 'Vec3',
      packed: false,
      fields: [
        BridgeField(
          name: 'x',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'y',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'z',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'normalize',
      cSymbol: 'physics_normalize',
      isAsync: false,
      returnType: BridgeType(name: 'Vec3'),
      params: [
        BridgeParam(
          name: 'v',
          type: BridgeType(name: 'Vec3'),
        ),
      ],
      isResult: true,
    ),
  ],
);

/// Spec with a `@NitroResult<Profile>` record return — needs record in spec.
BridgeSpec _resultRecordSpec() => BridgeSpec(
  dartClassName: 'Database',
  lib: 'database',
  namespace: 'database',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'database.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Profile',
      fields: [
        BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'name', dartType: 'String', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fetchProfile',
      cSymbol: 'database_fetch_profile',
      isAsync: false,
      returnType: BridgeType(name: 'Profile', isRecord: true),
      params: [
        BridgeParam(
          name: 'userId',
          type: BridgeType(name: 'int'),
        ),
      ],
      isResult: true,
    ),
  ],
);

/// Spec with two @NitroResult methods — verifies both appear, no cross-contamination.
BridgeSpec _resultMultiMethodSpec() => BridgeSpec(
  dartClassName: 'MultiApi',
  lib: 'multi_api',
  namespace: 'multi_api',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'multi_api.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getCount',
      cSymbol: 'multi_api_get_count',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [],
      isResult: true,
    ),
    BridgeFunction(
      dartName: 'getLabel',
      cSymbol: 'multi_api_get_label',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [],
      isResult: true,
    ),
  ],
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('BridgeFunction — isResult flag', () {
    test('isResult defaults to false', () {
      final f = BridgeFunction(
        dartName: 'foo',
        cSymbol: 'foo',
        isAsync: false,
        returnType: BridgeType(name: 'int'),
        params: [],
      );
      expect(f.isResult, isFalse);
    });

    test('isResult can be set to true', () {
      final f = BridgeFunction(
        dartName: 'foo',
        cSymbol: 'foo',
        isAsync: false,
        returnType: BridgeType(name: 'String'),
        params: [],
        isResult: true,
      );
      expect(f.isResult, isTrue);
    });
  });

  // ── Dart FFI codegen ─────────────────────────────────────────────────────────

  group('DartFfiGenerator — @NitroResult<String>', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultStringSpec()));

    test('Dart return type is NitroResultValue<String>', () {
      expect(code, contains('NitroResultValue<String> login('));
    });

    test('method pointer uses Pointer<Uint8> return (tagged buffer wire)', () {
      // The FFI function pointer must use Pointer<Uint8> as return type,
      // same wire format as @HybridRecord.
      expect(code, contains('Pointer<Uint8> Function('));
    });

    test('emits tag check: if (_tag != 0)', () {
      expect(code, contains('_tag != 0'));
    });

    test('emits NitroErr on error path', () {
      expect(code, contains('return NitroErr('));
    });

    test('emits NitroOk on success path', () {
      expect(code, contains('return NitroOk('));
    });

    test('reads error string via RecordReader', () {
      expect(code, contains('_errR.readString()'));
    });

    test('decodes String value via RecordReader.readString', () {
      expect(code, contains('_r.readString()'));
    });

    test('does NOT emit _assertCheckError (errors go through result)', () {
      expect(code, isNot(contains('_assertCheckError')));
    });

    test('does not use async keyword in method', () {
      // @NitroResult is always sync on Dart side
      expect(code, isNot(contains('async {')));
    });
  });

  group('DartFfiGenerator — @NitroResult<int>', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultIntSpec()));

    test('Dart return type is NitroResultValue<int>', () {
      expect(code, contains('NitroResultValue<int> increment('));
    });

    test('success path uses _r.readInt()', () {
      expect(code, contains('_r.readInt()'));
    });

    test('error path uses _errR.readString()', () {
      expect(code, contains('_errR.readString()'));
    });
  });

  group('DartFfiGenerator — @NitroResult<bool>', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultBoolSpec()));

    test('Dart return type is NitroResultValue<bool>', () {
      expect(code, contains('NitroResultValue<bool> check('));
    });

    test('success path uses _r.readBool()', () {
      expect(code, contains('_r.readBool()'));
    });
  });

  // ── SpecValidator E015 ────────────────────────────────────────────────────────

  group('SpecValidator — E015 (@NitroResult constraints)', () {
    test('no E015 when @NitroResult combined with @nitroAsync', () {
      final spec = BridgeSpec(
        dartClassName: 'Auth',
        lib: 'auth',
        namespace: 'auth',
        sourceUri: 'auth.native.dart',
        functions: [_resultAsyncFunc()],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'E015'),
        isFalse,
        reason: '@nitroAsync + @NitroResult is now allowed — no E015',
      );
    });

    test('E015 when @NitroResult combined with isNativeAsync', () {
      final spec = BridgeSpec(
        dartClassName: 'Auth',
        lib: 'auth',
        namespace: 'auth',
        sourceUri: 'auth.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'go',
            cSymbol: 'auth_go',
            isAsync: false,
            isNativeAsync: true,
            returnType: BridgeType(name: 'String'),
            params: [],
            isResult: true,
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'E015'),
        isTrue,
        reason: 'E015 expected for @NitroResult + isNativeAsync',
      );
    });

    test('E015 when @NitroResult wraps void return type', () {
      final spec = BridgeSpec(
        dartClassName: 'Auth',
        lib: 'auth',
        namespace: 'auth',
        sourceUri: 'auth.native.dart',
        functions: [_resultVoidFunc()],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'E015'),
        isTrue,
        reason: 'E015 expected for @NitroResult on void return',
      );
    });

    test('no E015 for valid @NitroResult<String> sync method', () {
      final spec = _resultStringSpec();
      final issues = SpecValidator.validate(spec);
      expect(
        issues.where((i) => i.code == 'E015'),
        isEmpty,
        reason: 'No E015 expected for valid @NitroResult<String>',
      );
    });

    test('no E015 for valid @NitroResult<int> sync method', () {
      final spec = _resultIntSpec();
      final issues = SpecValidator.validate(spec);
      expect(
        issues.where((i) => i.code == 'E015'),
        isEmpty,
        reason: 'No E015 expected for valid @NitroResult<int>',
      );
    });

    test('E015 hint mentions the method name', () {
      final spec = BridgeSpec(
        dartClassName: 'Auth',
        lib: 'auth',
        namespace: 'auth',
        sourceUri: 'auth.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'asyncLogin',
            cSymbol: 'auth_async_login',
            isAsync: false,
            isNativeAsync: true,
            returnType: BridgeType(name: 'String'),
            params: [],
            isResult: true,
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final e015 = issues.firstWhere((i) => i.code == 'E015', orElse: () => throw Exception('No E015'));
      expect(e015.message, contains('asyncLogin'));
    });
  });

  // ── Additional return types ───────────────────────────────────────────────────

  group('DartFfiGenerator — @NitroResult<double>', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultDoubleSpec()));

    test('Dart return type is NitroResultValue<double>', () {
      expect(code, contains('NitroResultValue<double> readTemperature('));
    });

    test('success path uses _r.readDouble()', () {
      expect(code, contains('_r.readDouble()'));
    });

    test('error path uses _errR.readString()', () {
      expect(code, contains('_errR.readString()'));
    });

    test('tag check is emitted', () {
      expect(code, contains('_tag != 0'));
    });

    test('no arena (no params) uses direct callSync block', () {
      // No arena needed — no String/Record params.
      // The call must NOT wrap in withArena.
      expect(code, isNot(contains('withArena')));
    });

    test('does NOT emit _assertCheckError', () {
      expect(code, isNot(contains('_assertCheckError')));
    });
  });

  group('CppBridgeGenerator — @NitroResult Swift shim', () {
    test('uses tagged uint8_t* ABI for Swift _cdecl wrapper', () {
      final code = CppBridgeGenerator.generate(_resultDoubleSpec());
      expect(code, contains('extern uint8_t* _sensor_call_readTemperature(void);'));
      expect(code, contains('uint8_t* sensor_read_temperature(int64_t instanceId, NitroError* _nitro_err)'));
    });
  });

  group('DartFfiGenerator — @NitroResult<int> scalar param passed correctly', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultIntSpec()));

    test('scalar param `by` is forwarded to FFI pointer call', () {
      // Regression: no-arena path previously emitted _incrementPtr(_nitroErr)
      // dropping all params. Fixed: must emit _incrementPtr(_instanceId, by, _nitroErr).
      expect(code, contains('_incrementPtr(_instanceId, by, _nitroErr)'));
    });
  });

  group('DartFfiGenerator — @NitroResult<Severity> enum return', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultEnumSpec()));

    test('Dart return type is NitroResultValue<Severity>', () {
      expect(code, contains('NitroResultValue<Severity> classify('));
    });

    test('success path decodes enum via SeverityEnumExt.fromNativeValue', () {
      expect(code, contains('SeverityEnumExt.fromNativeValue(_r.readInt())'));
    });

    test('error path uses _errR.readString()', () {
      expect(code, contains('_errR.readString()'));
    });

    test('emits NitroOk wrapping the enum value', () {
      expect(code, contains('return NitroOk(SeverityEnumExt.fromNativeValue'));
    });

    test('does NOT emit _assertCheckError', () {
      expect(code, isNot(contains('_assertCheckError')));
    });
  });

  group('DartFfiGenerator — @NitroResult<Vec3> struct return', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultStructSpec()));

    test('Dart return type is NitroResultValue<Vec3>', () {
      expect(code, contains('NitroResultValue<Vec3> normalize('));
    });

    test('success path decodes struct via Vec3StructExt.fromReader', () {
      expect(code, contains('Vec3StructExt.fromReader(_r)'));
    });

    test('emits NitroOk wrapping the struct value', () {
      expect(code, contains('return NitroOk(Vec3StructExt.fromReader'));
    });

    test('error path uses _errR.readString()', () {
      expect(code, contains('_errR.readString()'));
    });

    test('does NOT emit _assertCheckError', () {
      expect(code, isNot(contains('_assertCheckError')));
    });
  });

  group('DartFfiGenerator — @NitroResult<Profile> record return', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultRecordSpec()));

    test('Dart return type is NitroResultValue<Profile>', () {
      expect(code, contains('NitroResultValue<Profile> fetchProfile('));
    });

    test('success path decodes record (does NOT use RecordReader for record types)', () {
      // @HybridRecord uses _decodeRecordExpr which calls ProfileRecordExt.fromReader,
      // not the primitive RecordReader path.
      expect(code, isNot(contains('final _r = RecordReader.fromNative')));
    });

    test('emits NitroOk wrapping the record decode expression', () {
      expect(code, contains('return NitroOk('));
    });

    test('error path uses _errR.readString()', () {
      expect(code, contains('_errR.readString()'));
    });

    test('no arena for scalar param (int userId) — no withArena', () {
      expect(code, isNot(contains('withArena')));
    });

    test('does NOT emit _assertCheckError', () {
      expect(code, isNot(contains('_assertCheckError')));
    });
  });

  group('DartFfiGenerator — @NitroResult multiple methods in one spec', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultMultiMethodSpec()));

    test('both methods appear in generated code', () {
      expect(code, contains('NitroResultValue<int> getCount('));
      expect(code, contains('NitroResultValue<String> getLabel('));
    });

    test('both methods emit tag checks', () {
      // Two separate tag checks — count occurrences
      final tagChecks = RegExp(r'_tag != 0').allMatches(code).length;
      expect(tagChecks, greaterThanOrEqualTo(2));
    });

    test('both methods decode independently (readInt and readString both present)', () {
      expect(code, contains('_r.readInt()'));
      expect(code, contains('_r.readString()'));
    });

    test('neither method emits _assertCheckError', () {
      expect(code, isNot(contains('_assertCheckError')));
    });
  });

  group('DartFfiGenerator — @NitroResult FFI pointer type', () {
    late String code;
    setUp(() => code = DartFfiGenerator.generate(_resultStringSpec()));

    test('function pointer return type is Pointer<Uint8>', () {
      expect(code, contains('Pointer<Uint8> Function('));
    });

    test('function pointer includes NitroError* out-param', () {
      expect(code, contains('Pointer<NitroErrorFfi>'));
    });
  });
}
