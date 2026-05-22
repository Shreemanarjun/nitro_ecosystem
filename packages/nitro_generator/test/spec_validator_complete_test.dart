// Comprehensive validation tests for E002, W002, and W003.
//
//   E002: @nitroAsync on a non-Future return type (non-void).
//   W002: Non-nullable @HybridEnum named optional param with no default.
//   W003: Non-nullable @HybridStruct named optional param with no default.

import 'package:test/test.dart';
import 'test_utils.dart';

// ── Shared helpers ─────────────────────────────────────────────────────────────

BridgeSpec _asyncSpec(String returnTypeName, {bool isFuture = false}) => BridgeSpec(
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
      isAsync: true,
      returnType: BridgeType(name: returnTypeName, isFuture: isFuture),
      params: [],
    ),
  ],
);

BridgeSpec _namedEnumParamSpec({String? defaultLiteral, bool nullable = false}) {
  final typeName = nullable ? 'Status?' : 'Status';
  return BridgeSpec(
    dartClassName: 'Mod',
    lib: 'mod',
    namespace: 'mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'mod.native.dart',
    enums: [BridgeEnum(name: 'Status', startValue: 0, values: ['off', 'on'])],
    functions: [
      BridgeFunction(
        dartName: 'fn',
        cSymbol: 'mod_fn',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'mode',
            type: BridgeType(name: typeName),
            isNamed: true,
            isOptional: true,
            defaultLiteral: defaultLiteral,
          ),
        ],
      ),
    ],
  );
}

BridgeSpec _namedStructParamSpec({String? defaultLiteral, bool nullable = false}) {
  final typeName = nullable ? 'Config?' : 'Config';
  return BridgeSpec(
    dartClassName: 'Mod',
    lib: 'mod',
    namespace: 'mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'mod.native.dart',
    structs: [
      BridgeStruct(name: 'Config', packed: false, fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
      ]),
    ],
    functions: [
      BridgeFunction(
        dartName: 'fn',
        cSymbol: 'mod_fn',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: [
          BridgeParam(
            name: 'cfg',
            type: BridgeType(name: typeName),
            isNamed: true,
            isOptional: true,
            defaultLiteral: defaultLiteral,
          ),
        ],
      ),
    ],
  );
}

// ── E002: @nitroAsync on non-Future return type ───────────────────────────────

void main() {
  group('SpecValidator — E002: @nitroAsync on non-Future return type', () {
    test('isAsync + String return (isFuture false) emits E002 error', () {
      final issues = SpecValidator.validate(_asyncSpec('String'));
      expect(issues.any((i) => i.code == 'E002' && i.isError), isTrue);
    });

    test('isAsync + int return (isFuture false) emits E002 error', () {
      final issues = SpecValidator.validate(_asyncSpec('int'));
      expect(issues.any((i) => i.code == 'E002' && i.isError), isTrue);
    });

    test('isAsync + bool return (isFuture false) emits E002 error', () {
      final issues = SpecValidator.validate(_asyncSpec('bool'));
      expect(issues.any((i) => i.code == 'E002' && i.isError), isTrue);
    });

    test('isAsync + double return (isFuture false) emits E002 error', () {
      final issues = SpecValidator.validate(_asyncSpec('double'));
      expect(issues.any((i) => i.code == 'E002' && i.isError), isTrue);
    });

    test('E002 message includes function name and bad return type', () {
      final issues = SpecValidator.validate(_asyncSpec('String'));
      final e = issues.firstWhere((i) => i.code == 'E002');
      expect(e.message, contains('fn'));
      expect(e.message, contains('String'));
    });

    test('E002 hint mentions Future<T>', () {
      final issues = SpecValidator.validate(_asyncSpec('String'));
      final e = issues.firstWhere((i) => i.code == 'E002');
      expect(e.hint, isNotNull);
      expect(e.hint, contains('Future'));
    });

    test('isAsync + void return does NOT emit E002 (fire-and-forget is valid)', () {
      final issues = SpecValidator.validate(_asyncSpec('void'));
      expect(issues.any((i) => i.code == 'E002'), isFalse);
    });

    test('isAsync + String with isFuture:true does NOT emit E002', () {
      final issues = SpecValidator.validate(_asyncSpec('String', isFuture: true));
      expect(issues.any((i) => i.code == 'E002'), isFalse);
    });

    test('sync String return does NOT emit E002', () {
      final spec = BridgeSpec(
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
            returnType: BridgeType(name: 'String'),
            params: [],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).any((i) => i.code == 'E002'), isFalse);
    });
  });

  // ── W002: non-nullable @HybridEnum named optional param with no default ──────

  group('SpecValidator — W002: non-nullable enum named param with no default', () {
    test('enum named param with no default emits W002 warning', () {
      final issues = SpecValidator.validate(_namedEnumParamSpec());
      expect(issues.any((i) => i.code == 'W002'), isTrue);
    });

    test('W002 is a warning, not an error', () {
      final issues = SpecValidator.validate(_namedEnumParamSpec());
      final w = issues.firstWhere((i) => i.code == 'W002');
      expect(w.isError, isFalse);
    });

    test('W002 message includes param name and type', () {
      final issues = SpecValidator.validate(_namedEnumParamSpec());
      final w = issues.firstWhere((i) => i.code == 'W002');
      expect(w.message, contains('mode'));
      expect(w.message, contains('Status'));
    });

    test('W002 hint mentions adding a default value', () {
      final issues = SpecValidator.validate(_namedEnumParamSpec());
      final w = issues.firstWhere((i) => i.code == 'W002');
      expect(w.hint, isNotNull);
      expect(w.hint, contains('default'));
    });

    test('enum named param with defaultLiteral does NOT emit W002', () {
      final issues = SpecValidator.validate(
        _namedEnumParamSpec(defaultLiteral: 'Status.off'),
      );
      expect(issues.any((i) => i.code == 'W002'), isFalse);
    });

    test('nullable enum? named param does NOT emit W002', () {
      final issues = SpecValidator.validate(_namedEnumParamSpec(nullable: true));
      expect(issues.any((i) => i.code == 'W002'), isFalse);
    });

    test('enum named param does NOT emit W001 (W002 is the specific code)', () {
      final issues = SpecValidator.validate(_namedEnumParamSpec());
      expect(issues.any((i) => i.code == 'W001'), isFalse);
    });
  });

  // ── W003: non-nullable @HybridStruct named optional param with no default ────

  group('SpecValidator — W003: non-nullable struct named param with no default', () {
    test('struct named param with no default emits W003 warning', () {
      final issues = SpecValidator.validate(_namedStructParamSpec());
      expect(issues.any((i) => i.code == 'W003'), isTrue);
    });

    test('W003 is a warning, not an error', () {
      final issues = SpecValidator.validate(_namedStructParamSpec());
      final w = issues.firstWhere((i) => i.code == 'W003');
      expect(w.isError, isFalse);
    });

    test('W003 message includes param name and type', () {
      final issues = SpecValidator.validate(_namedStructParamSpec());
      final w = issues.firstWhere((i) => i.code == 'W003');
      expect(w.message, contains('cfg'));
      expect(w.message, contains('Config'));
    });

    test('W003 hint mentions adding a default value', () {
      final issues = SpecValidator.validate(_namedStructParamSpec());
      final w = issues.firstWhere((i) => i.code == 'W003');
      expect(w.hint, isNotNull);
      expect(w.hint, contains('default'));
    });

    test('struct named param with defaultLiteral does NOT emit W003', () {
      final issues = SpecValidator.validate(
        _namedStructParamSpec(defaultLiteral: 'Config()'),
      );
      expect(issues.any((i) => i.code == 'W003'), isFalse);
    });

    test('nullable struct? named param does NOT emit W003', () {
      final issues = SpecValidator.validate(_namedStructParamSpec(nullable: true));
      expect(issues.any((i) => i.code == 'W003'), isFalse);
    });

    test('struct named param does NOT emit W001 (W003 is the specific code)', () {
      final issues = SpecValidator.validate(_namedStructParamSpec());
      expect(issues.any((i) => i.code == 'W001'), isFalse);
    });
  });

  // ── Interaction: multiple warning codes in one spec ───────────────────────────

  group('SpecValidator — mixed W001/W002/W003 in same spec', () {
    test('spec with int + enum + struct named params emits W001 + W002 + W003', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [BridgeEnum(name: 'Status', startValue: 0, values: ['off', 'on'])],
        structs: [
          BridgeStruct(name: 'Config', packed: false, fields: [
            BridgeField(name: 'x', type: BridgeType(name: 'double')),
          ]),
        ],
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'timeout',
                type: BridgeType(name: 'int'),
                isNamed: true,
                isOptional: true,
              ),
              BridgeParam(
                name: 'mode',
                type: BridgeType(name: 'Status'),
                isNamed: true,
                isOptional: true,
              ),
              BridgeParam(
                name: 'cfg',
                type: BridgeType(name: 'Config'),
                isNamed: true,
                isOptional: true,
              ),
            ],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'W001'), isTrue);
      expect(issues.any((i) => i.code == 'W002'), isTrue);
      expect(issues.any((i) => i.code == 'W003'), isTrue);
    });

    test('providing all defaults suppresses all W001/W002/W003', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        enums: [BridgeEnum(name: 'Status', startValue: 0, values: ['off', 'on'])],
        structs: [
          BridgeStruct(name: 'Config', packed: false, fields: [
            BridgeField(name: 'x', type: BridgeType(name: 'double')),
          ]),
        ],
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'timeout',
                type: BridgeType(name: 'int'),
                isNamed: true,
                isOptional: true,
                defaultLiteral: '30',
              ),
              BridgeParam(
                name: 'mode',
                type: BridgeType(name: 'Status'),
                isNamed: true,
                isOptional: true,
                defaultLiteral: 'Status.off',
              ),
              BridgeParam(
                name: 'cfg',
                type: BridgeType(name: 'Config'),
                isNamed: true,
                isOptional: true,
                defaultLiteral: 'Config()',
              ),
            ],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'W001' || i.code == 'W002' || i.code == 'W003'), isFalse);
    });
  });
}
