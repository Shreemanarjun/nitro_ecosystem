// Tests for @NitroResult method annotation (S4-P6).
//
// Covers:
//   - BridgeFunction.isResult flag
//   - Dart FFI return type: NitroResultValue<T>
//   - Dart FFI method pointer uses Pointer<Uint8> (same as record wire type)
//   - Tag-based decode emitted for sync @NitroResult methods
//   - E015 validation: cannot combine with @nitroAsync / @NitroNativeAsync
//   - E015 validation: cannot wrap void return type

import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Fixture specs ─────────────────────────────────────────────────────────────

/// Spec with a @NitroResult<String> synchronous method.
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
        BridgeParam(name: 'user', type: BridgeType(name: 'String')),
        BridgeParam(name: 'pass', type: BridgeType(name: 'String')),
      ],
      isResult: true,
    ),
  ],
);

/// Spec with a @NitroResult<int> synchronous method (no arena params).
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
        BridgeParam(name: 'by', type: BridgeType(name: 'int')),
      ],
      isResult: true,
    ),
  ],
);

/// Spec with a @NitroResult<bool> synchronous method (no arena params).
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

/// @NitroResult combined with @nitroAsync — invalid (E015).
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
    test('E015 when @NitroResult combined with isAsync', () {
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
        isTrue,
        reason: 'E015 expected for @NitroResult + isAsync',
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
        functions: [_resultAsyncFunc()],
      );
      final issues = SpecValidator.validate(spec);
      final e015 = issues.firstWhere((i) => i.code == 'E015', orElse: () => throw Exception('No E015'));
      expect(e015.message, contains('asyncLogin'));
    });
  });
}
