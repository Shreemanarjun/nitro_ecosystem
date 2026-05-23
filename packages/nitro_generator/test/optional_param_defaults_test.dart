// Optional/named parameter handling tests for DartFfiGenerator.
//
// Covers the current generator behavior for named and optional parameters
// and documents Bug 5.1 — the known limitation around non-nullable named params.
//
// Bug 5.1: BridgeParam has no `defaultLiteral` field. When a non-nullable
// named param is emitted, the generator produces `{int timeout}` which is
// invalid Dart (non-nullable named params must be `required` or have a
// default value). The current workaround is to use nullable types (`int?`).
//
// Tests are organised as:
//   Section 1: Positional params — always valid
//   Section 2: Nullable named params — valid, no default needed
//   Section 3: Non-nullable named params — documents Bug 5.1 behavior
//   Section 4: Multiple mixed params — valid combinations

import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeParam _pos(String type, String name) =>
    BridgeParam(name: name, type: BridgeType(name: type), isNamed: false);

BridgeParam _named(String type, String name) =>
    BridgeParam(name: name, type: BridgeType(name: type), isNamed: true);

BridgeSpec _fnSpec(String returnType, List<BridgeParam> params) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: false,
      returnType: BridgeType(name: returnType),
      params: params,
    ),
  ],
);

// ── Section 1: Positional params ──────────────────────────────────────────────

void main() {
  group('DartFfiGenerator — positional params always valid', () {
    test('int positional param → int name', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_pos('int', 'count')]));
      expect(out, contains('fn(int count)'));
    });

    test('bool positional param → bool name', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_pos('bool', 'flag')]));
      expect(out, contains('fn(bool flag)'));
    });

    test('double positional param → double name', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_pos('double', 'val')]));
      expect(out, contains('fn(double val)'));
    });

    test('String positional param → String name', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_pos('String', 'text')]));
      expect(out, contains('fn(String text)'));
    });

    test('nullable int positional param → int? name', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_pos('int?', 'count')]));
      expect(out, contains('fn(int? count)'));
    });

    test('multiple positional params → comma-separated', () {
      final out = DartFfiGenerator.generate(_fnSpec(
        'bool',
        [_pos('int', 'a'), _pos('double', 'b'), _pos('String', 'c')],
      ));
      expect(out, contains('fn(int a, double b, String c)'));
    });
  });

  // ── Section 2: Nullable named params (valid — no default required) ────────

  group('DartFfiGenerator — nullable named params emit valid {T? name} syntax', () {
    test('int? named → {int? timeout}', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_named('int?', 'timeout')]));
      expect(out, contains('{int? timeout}'));
    });

    test('bool? named → {bool? verbose}', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_named('bool?', 'verbose')]));
      expect(out, contains('{bool? verbose}'));
    });

    test('double? named → {double? scale}', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_named('double?', 'scale')]));
      expect(out, contains('{double? scale}'));
    });

    test('String? named → {String? label}', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_named('String?', 'label')]));
      expect(out, contains('{String? label}'));
    });

    test('multiple nullable named params → {T? a, U? b}', () {
      final out = DartFfiGenerator.generate(_fnSpec(
        'void',
        [_named('int?', 'timeout'), _named('bool?', 'retryOnFail')],
      ));
      expect(out, contains('{int? timeout, bool? retryOnFail}'));
    });

    test('mixed positional + nullable named → positional, {named}', () {
      final out = DartFfiGenerator.generate(_fnSpec(
        'void',
        [_pos('String', 'url'), _named('int?', 'timeout')],
      ));
      expect(out, contains('fn(String url, {int? timeout})'));
    });
  });

  // ── Section 3: Non-nullable named params — Bug 5.1 ───────────────────────
  //
  // The generator emits `{int name}` for non-nullable named params.
  // This is invalid Dart — non-nullable named params must be either
  // `required` or have a default value. BridgeParam has no `defaultLiteral`
  // field, so no default can be emitted.
  //
  // These tests document the current (buggy) output, NOT valid Dart.
  // Fix: add `defaultLiteral: String?` to BridgeParam and update _paramList()
  // to emit `{int name = <defaultLiteral>}` when a literal is present.

  group('DartFfiGenerator — Bug 5.1: non-nullable named params emit {T name} (invalid Dart)', () {
    test('non-nullable int named → {int timeout} (invalid: no default)', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_named('int', 'timeout')]));
      // Documents current output — not valid Dart
      expect(out, contains('{int timeout}'));
    });

    test('non-nullable bool named → {bool verbose} (invalid: no default)', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_named('bool', 'verbose')]));
      expect(out, contains('{bool verbose}'));
    });

    test('non-nullable String named → {String label} (invalid: no default)', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [_named('String', 'label')]));
      expect(out, contains('{String label}'));
    });
  });

    // ── Section 3b: defaultLiteral fix — Bug 5.1 resolved ───────────────────
  //
  // When BridgeParam.defaultLiteral is set, the generator emits the default
  // and the resulting `{Type name = literal}` is valid Dart.

  group('DartFfiGenerator — Bug 5.1 fix: defaultLiteral emits valid {T name = value}', () {
    BridgeParam namedWithDefault(String type, String name, String literal) =>
        BridgeParam(name: name, type: BridgeType(name: type), isNamed: true, isOptional: true, defaultLiteral: literal);

    test('int named with default 5 → {int timeout = 5}', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [namedWithDefault('int', 'timeout', '5')]));
      expect(out, contains('{int timeout = 5}'));
    });

    test('bool named with default true → {bool verbose = true}', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [namedWithDefault('bool', 'verbose', 'true')]));
      expect(out, contains('{bool verbose = true}'));
    });

    test('double named with default 1.0 → {double scale = 1.0}', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [namedWithDefault('double', 'scale', '1.0')]));
      expect(out, contains('{double scale = 1.0}'));
    });

    test('String named with default empty → {String label = \'\'}', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [namedWithDefault('String', 'label', "''")]));
      expect(out, contains("{String label = ''}"));
    });

    test('positional + named with default → valid mixed signature', () {
      final out = DartFfiGenerator.generate(_fnSpec('bool', [
        _pos('String', 'id'),
        namedWithDefault('int', 'timeout', '30'),
      ]));
      expect(out, contains('fn(String id, {int timeout = 30})'));
    });

    test('multiple named params — one with default, one nullable', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', [
        namedWithDefault('int', 'retries', '3'),
        _named('bool?', 'verbose'),
      ]));
      expect(out, contains('{int retries = 3, bool? verbose}'));
    });
  });

  // ── Section 4: Mixed valid combinations ───────────────────────────────────

  group('DartFfiGenerator — mixed param lists with nullable named params', () {
    test('positional int + nullable named int? → valid signature', () {
      final out = DartFfiGenerator.generate(_fnSpec(
        'bool',
        [_pos('String', 'id'), _named('int?', 'timeoutSeconds')],
      ));
      expect(out, contains('fn(String id, {int? timeoutSeconds})'));
    });

    test('positional + multiple nullable named → valid signature', () {
      final out = DartFfiGenerator.generate(_fnSpec(
        'void',
        [_pos('String', 'host'), _named('int?', 'port'), _named('bool?', 'secure')],
      ));
      expect(out, contains('fn(String host, {int? port, bool? secure})'));
    });

    test('no params → empty param list', () {
      final out = DartFfiGenerator.generate(_fnSpec('void', []));
      expect(out, contains('fn()'));
    });
  });
}
