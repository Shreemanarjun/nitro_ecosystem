// Tests for SpecValidator expansion:
//   1. Cyclic @HybridStruct dependency detection
//   2. Enum-as-field support in @HybridStruct (validator + generators)
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:test/test.dart';

// ── Helpers ────────────────────────────────────────────────────────────────────

BridgeSpec _emptySpec({
  String lib = 'my_plugin',
  List<BridgeStruct> structs = const [],
  List<BridgeEnum> enums = const [],
}) {
  return BridgeSpec(
    dartClassName: 'MyPlugin',
    lib: lib,
    namespace: 'my_plugin',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'test://spec',
    structs: structs,
    enums: enums,
  );
}

BridgeStruct _struct(String name, List<BridgeField> fields, {bool packed = false}) => BridgeStruct(name: name, packed: packed, fields: fields);

BridgeField _field(String name, String typeName) => BridgeField(
  name: name,
  type: BridgeType(name: typeName),
);

BridgeEnum _enum(String name, [List<String> values = const ['a', 'b']]) => BridgeEnum(name: name, startValue: 0, values: values);

// ── 1. Cyclic dependency detection ────────────────────────────────────────────

void main() {
  group('SpecValidator — cyclic @HybridStruct detection', () {
    test('no error for unrelated structs', () {
      final spec = _emptySpec(
        structs: [
          _struct('Rect', [_field('x', 'double'), _field('y', 'double')]),
          _struct('Color', [_field('r', 'int'), _field('g', 'int')]),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'CYCLIC_STRUCT'), isFalse);
    });

    test('no error for linear struct chain (A has field of type B)', () {
      final spec = _emptySpec(
        structs: [
          _struct('Inner', [_field('x', 'double')]),
          _struct('Outer', [_field('inner', 'Inner'), _field('y', 'int')]),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'CYCLIC_STRUCT'), isFalse);
    });

    test('error for direct self-reference (A references A)', () {
      final spec = _emptySpec(
        structs: [
          _struct('Node', [_field('child', 'Node'), _field('value', 'int')]),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final cycleIssues = issues.where((i) => i.code == 'CYCLIC_STRUCT').toList();
      expect(cycleIssues, isNotEmpty);
      expect(cycleIssues.first.severity, equals(ValidationSeverity.error));
      expect(cycleIssues.first.message, contains('Node'));
    });

    test('error for two-struct mutual cycle (A → B → A)', () {
      final spec = _emptySpec(
        structs: [
          _struct('A', [_field('b', 'B')]),
          _struct('B', [_field('a', 'A')]),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'CYCLIC_STRUCT'), isTrue);
    });

    test('error for three-struct transitive cycle (A → B → C → A)', () {
      final spec = _emptySpec(
        structs: [
          _struct('A', [_field('b', 'B')]),
          _struct('B', [_field('c', 'C')]),
          _struct('C', [_field('a', 'A')]),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(issues.any((i) => i.code == 'CYCLIC_STRUCT'), isTrue);
    });

    test('cycle error hint mentions @HybridRecord as the fix', () {
      final spec = _emptySpec(
        structs: [
          _struct('A', [_field('b', 'B')]),
          _struct('B', [_field('a', 'A')]),
        ],
      );
      final issue = SpecValidator.validate(spec).firstWhere((i) => i.code == 'CYCLIC_STRUCT');
      expect(issue.hint, isNotNull);
      expect(issue.hint, contains('@HybridRecord'));
    });

    test('cycle error reports the cycle path in message', () {
      final spec = _emptySpec(
        structs: [
          _struct('Alpha', [_field('beta', 'Beta')]),
          _struct('Beta', [_field('alpha', 'Alpha')]),
        ],
      );
      final issue = SpecValidator.validate(spec).firstWhere((i) => i.code == 'CYCLIC_STRUCT');
      expect(issue.message, contains('Alpha'));
      expect(issue.message, contains('Beta'));
    });

    test('single cycle reported once even if reachable from multiple roots', () {
      final spec = _emptySpec(
        structs: [
          _struct('X', [_field('y', 'Y')]),
          _struct('Y', [_field('x', 'X')]),
          // Z is independent
          _struct('Z', [_field('v', 'double')]),
        ],
      );
      final cycleIssues = SpecValidator.validate(spec).where((i) => i.code == 'CYCLIC_STRUCT');
      expect(cycleIssues, hasLength(1));
    });

    test('no cycle for DAG with shared dependency', () {
      // A → C, B → C (diamond — not a cycle)
      final spec = _emptySpec(
        structs: [
          _struct('C', [_field('v', 'int')]),
          _struct('A', [_field('c', 'C')]),
          _struct('B', [_field('c', 'C')]),
        ],
      );
      expect(SpecValidator.validate(spec).any((i) => i.code == 'CYCLIC_STRUCT'), isFalse);
    });
  });

  // ── 2. Enum as struct field — validator ──────────────────────────────────────

  group('SpecValidator — enum-as-struct-field', () {
    test('no error when known @HybridEnum is used as a struct field', () {
      final spec = _emptySpec(
        enums: [_enum('Status')],
        structs: [
          _struct('Request', [
            _field('id', 'int'),
            _field('status', 'Status'),
          ]),
        ],
      );
      final issues = SpecValidator.validate(spec).where((i) => i.code == 'INVALID_STRUCT_FIELD_TYPE').toList();
      expect(issues, isEmpty);
    });

    test('error when unknown type (not enum, not struct) used as struct field', () {
      final spec = _emptySpec(
        structs: [
          _struct('Request', [_field('unknown', 'UnknownType')]),
        ],
      );
      expect(
        SpecValidator.validate(spec).any((i) => i.code == 'INVALID_STRUCT_FIELD_TYPE'),
        isTrue,
      );
    });

    test('hint for INVALID_STRUCT_FIELD_TYPE mentions @HybridEnum', () {
      final spec = _emptySpec(
        structs: [
          _struct('Foo', [_field('bar', 'Baz')]),
        ],
      );
      final issue = SpecValidator.validate(spec).firstWhere((i) => i.code == 'INVALID_STRUCT_FIELD_TYPE');
      expect(issue.hint, contains('@HybridEnum'));
    });

    test('multiple enum fields in same struct all pass validation', () {
      final spec = _emptySpec(
        enums: [_enum('Status'), _enum('Priority')],
        structs: [
          _struct('Task', [
            _field('status', 'Status'),
            _field('priority', 'Priority'),
            _field('id', 'int'),
          ]),
        ],
      );
      expect(
        SpecValidator.validate(spec).where((i) => i.code == 'INVALID_STRUCT_FIELD_TYPE'),
        isEmpty,
      );
    });
  });

  // ── 3. Enum as struct field — StructGenerator (C header) ──────────────────

  group('StructGenerator.generateCStructs — enum field', () {
    test('enum field emitted as int32_t in C struct', () {
      final spec = _emptySpec(
        enums: [_enum('Status')],
        structs: [
          _struct('Request', [_field('status', 'Status'), _field('id', 'int')]),
        ],
      );
      final c = StructGenerator.generateCStructs(spec);
      expect(c, contains('int32_t status;'));
      expect(c, contains('int64_t id;'));
    });
  });

  // ── 4. Enum as struct field — StructGenerator (Dart FFI) ──────────────────

  group('StructGenerator.generateDartExtensions — enum field', () {
    test('FFI struct field uses @Int32() annotation', () {
      final spec = _emptySpec(
        enums: [_enum('Status')],
        structs: [
          _struct('Request', [_field('status', 'Status')]),
        ],
      );
      final dart = StructGenerator.generateDartExtensions(spec);
      expect(dart, contains('@Int32()'));
      expect(dart, contains('external int status;'));
    });

    test('toDart() converts int field with .toStatus()', () {
      final spec = _emptySpec(
        enums: [_enum('Status')],
        structs: [
          _struct('Request', [_field('status', 'Status')]),
        ],
      );
      final dart = StructGenerator.generateDartExtensions(spec);
      expect(dart, contains('status: status.toStatus()'));
    });

    test('toNative() converts enum field with .nativeValue', () {
      final spec = _emptySpec(
        enums: [_enum('Status')],
        structs: [
          _struct('Request', [_field('status', 'Status')]),
        ],
      );
      final dart = StructGenerator.generateDartExtensions(spec);
      expect(dart, contains('ptr.ref.status = status.nativeValue;'));
    });

    test('non-enum int field still uses @Int64() annotation', () {
      final spec = _emptySpec(
        structs: [
          _struct('Data', [_field('count', 'int')]),
        ],
      );
      final dart = StructGenerator.generateDartExtensions(spec);
      expect(dart, contains('@Int64()'));
      expect(dart, isNot(contains('@Int32()')));
    });
  });

  // ── 5. Enum as struct field — StructGenerator (Kotlin) ────────────────────

  group('StructGenerator.generateKotlin — enum field', () {
    test('enum field stored as Long in Kotlin data class', () {
      final spec = _emptySpec(
        enums: [_enum('Status')],
        structs: [
          _struct('Request', [_field('status', 'Status'), _field('id', 'int')]),
        ],
      );
      final kt = StructGenerator.generateKotlin(spec);
      // Both enum field and regular int field should be Long
      expect(RegExp(r'val status: Long').hasMatch(kt), isTrue);
      expect(RegExp(r'val id: Long').hasMatch(kt), isTrue);
    });
  });

  // ── 6. Enum as struct field — StructGenerator (Swift) ────────────────────

  group('StructGenerator.generateSwift — enum field', () {
    test('enum field uses the enum type name in Swift struct', () {
      final spec = _emptySpec(
        enums: [_enum('Status')],
        structs: [
          _struct('Request', [_field('status', 'Status'), _field('id', 'int')]),
        ],
      );
      final swift = StructGenerator.generateSwift(spec);
      expect(swift, contains('public var status: Status'));
      expect(swift, contains('public var id: Int64'));
    });

    test('non-enum field is not mapped to enum type', () {
      final spec = _emptySpec(
        structs: [
          _struct('Data', [_field('x', 'double')]),
        ],
      );
      final swift = StructGenerator.generateSwift(spec);
      expect(swift, contains('public var x: Double'));
    });
  });

  // ── 7. Enum as struct field — CppBridgeGenerator (JNI pack/unpack) ────────

  group('CppBridgeGenerator — enum field in JNI struct helpers', () {
    BridgeSpec specWithEnumStructField() => _emptySpec(
      lib: 'test_lib',
      enums: [
        _enum('Status', ['ok', 'error']),
      ],
      structs: [
        _struct('Request', [
          _field('status', 'Status'),
          _field('id', 'int'),
        ]),
      ],
    );

    test('pack helper reads enum field as GetLongField', () {
      final cpp = CppBridgeGenerator.generate(specWithEnumStructField());
      expect(cpp, contains('GetLongField(obj, g_fid_Request_status)'));
    });

    test('pack helper casts enum field to C enum type via int32_t', () {
      final cpp = CppBridgeGenerator.generate(specWithEnumStructField());
      expect(cpp, contains('(Status)(int32_t)'));
    });

    test('unpack helper passes enum field as (jlong)(int32_t)', () {
      final cpp = CppBridgeGenerator.generate(specWithEnumStructField());
      expect(cpp, contains('(jlong)(int32_t)st->status'));
    });

    test('JNI constructor signature uses J for enum field', () {
      final cpp = CppBridgeGenerator.generate(specWithEnumStructField());
      // signature should be "(JJ)V" — enum (J) + int (J)
      expect(cpp, contains('"(JJ)V"'));
    });

    test('JNI field descriptor uses J for enum field', () {
      final cpp = CppBridgeGenerator.generate(specWithEnumStructField());
      expect(cpp, contains('"status", "J"'));
    });
  });
}
