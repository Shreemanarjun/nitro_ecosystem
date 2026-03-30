// Tests for nullable type handling across generators.
// Covers: CppInterfaceGenerator strips '?' from type names,
// DartFfiGenerator preserves '?' in Dart signatures,
// RecordGenerator generates nullable fields correctly in Dart and Kotlin.
import 'package:nitro_generator/src/generators/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _nullableReturnSpec(String returnTypeName) => BridgeSpec(
  dartClassName: 'NullMod',
  lib: 'null_mod',
  namespace: 'null_mod',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'null_mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getValue',
      cSymbol: 'null_mod_get_value',
      isAsync: false,
      returnType: BridgeType(name: returnTypeName),
      params: [],
    ),
  ],
);

BridgeSpec _nullableParamSpec(String paramTypeName) => BridgeSpec(
  dartClassName: 'NullMod',
  lib: 'null_mod',
  namespace: 'null_mod',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'null_mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'setValue',
      cSymbol: 'null_mod_set_value',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'val',
          type: BridgeType(name: paramTypeName),
        ),
      ],
    ),
  ],
);

BridgeSpec _dartNullableReturnSpec(String returnTypeName) => BridgeSpec(
  dartClassName: 'NullMod',
  lib: 'null_mod',
  namespace: 'null_mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'null_mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'getValue',
      cSymbol: 'null_mod_get_value',
      isAsync: false,
      returnType: BridgeType(name: returnTypeName),
      params: [],
    ),
  ],
);

BridgeSpec _recordSpec(List<BridgeRecordField> fields) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  recordTypes: [BridgeRecordType(name: 'Stats', fields: fields)],
  functions: [
    BridgeFunction(
      dartName: 'getStats',
      cSymbol: 'mod_get_stats',
      isAsync: false,
      returnType: BridgeType(name: 'Stats', isRecord: true),
      params: [],
    ),
  ],
);

void main() {
  group('CppInterfaceGenerator — nullable type names strip ?', () {
    test('String? return strips ? → std::string', () {
      final out = CppInterfaceGenerator.generate(_nullableReturnSpec('String?'));
      expect(out, contains('virtual std::string getValue() = 0;'));
    });

    test('int? return strips ? → int64_t', () {
      final out = CppInterfaceGenerator.generate(_nullableReturnSpec('int?'));
      expect(out, contains('virtual int64_t getValue() = 0;'));
    });

    test('double? return strips ? → double', () {
      final out = CppInterfaceGenerator.generate(_nullableReturnSpec('double?'));
      expect(out, contains('virtual double getValue() = 0;'));
    });

    test('bool? return strips ? → bool', () {
      final out = CppInterfaceGenerator.generate(_nullableReturnSpec('bool?'));
      expect(out, contains('virtual bool getValue() = 0;'));
    });

    test('String? param strips ? → const std::string&', () {
      final out = CppInterfaceGenerator.generate(_nullableParamSpec('String?'));
      expect(out, contains('virtual void setValue(const std::string& val) = 0;'));
    });

    test('int? param strips ? → int64_t', () {
      final out = CppInterfaceGenerator.generate(_nullableParamSpec('int?'));
      expect(out, contains('virtual void setValue(int64_t val) = 0;'));
    });

    test('double? param strips ? → double', () {
      final out = CppInterfaceGenerator.generate(_nullableParamSpec('double?'));
      expect(out, contains('virtual void setValue(double val) = 0;'));
    });

    test('nullable struct param strips ? → const StructName&', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'Frame',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'push',
            cSymbol: 'mod_push',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'f',
                type: BridgeType(name: 'Frame?'),
              ),
            ],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('virtual void push(const Frame& f) = 0;'));
    });

    test('nullable enum param strips ? → enum type', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'mod.native.dart',
        enums: [
          BridgeEnum(name: 'Mode', startValue: 0, values: ['off', 'on']),
        ],
        functions: [
          BridgeFunction(
            dartName: 'setMode',
            cSymbol: 'mod_set_mode',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'm',
                type: BridgeType(name: 'Mode?'),
              ),
            ],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('virtual void setMode(Mode m) = 0;'));
    });
  });

  group('DartFfiGenerator — nullable type names preserved in Dart output', () {
    test('String? return type appears as String? in generated Dart method', () {
      final out = DartFfiGenerator.generate(_dartNullableReturnSpec('String?'));
      expect(out, contains('String? getValue()'));
    });

    test('int? return type appears as int? in generated Dart method', () {
      final out = DartFfiGenerator.generate(_dartNullableReturnSpec('int?'));
      expect(out, contains('int? getValue()'));
    });

    test('double? return type appears as double? in generated Dart method', () {
      final out = DartFfiGenerator.generate(_dartNullableReturnSpec('double?'));
      expect(out, contains('double? getValue()'));
    });
  });

  group('RecordGenerator — nullable record fields in Kotlin output', () {
    test('nullable record field → Kotlin uses ? suffix', () {
      final spec = _recordSpec([
        BridgeRecordField(
          name: 'count',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'label',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
          isNullable: true,
        ),
      ]);
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('String?'));
    });

    test('non-nullable fields → Kotlin output has Long for int, String for String', () {
      final spec = _recordSpec([
        BridgeRecordField(
          name: 'count',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'name',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ]);
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('String'));
      expect(out, contains('Long'));
    });

    test('nullable primitive field → Kotlin uses null-safe decode pattern', () {
      final spec = _recordSpec([
        BridgeRecordField(
          name: 'v',
          dartType: 'double',
          kind: RecordFieldKind.primitive,
          isNullable: true,
        ),
      ]);
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('buf.get().toInt() == 0'));
    });

    test('nullable recordObject field → Kotlin uses null-safe decode with decodeFrom', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Inner',
            fields: [
              BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
            ],
          ),
          BridgeRecordType(
            name: 'Outer',
            fields: [
              BridgeRecordField(
                name: 'inner',
                dartType: 'Inner?',
                kind: RecordFieldKind.recordObject,
                isNullable: true,
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getOuter',
            cSymbol: 'mod_get_outer',
            isAsync: false,
            returnType: BridgeType(name: 'Outer', isRecord: true),
            params: [],
          ),
        ],
      );
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('buf.get().toInt() == 0'));
    });
  });

  group('RecordGenerator — nullable record fields in Dart extension output', () {
    test('Dart extension contains record class name', () {
      final spec = _recordSpec([
        BridgeRecordField(
          name: 'count',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'label',
          dartType: 'String?',
          kind: RecordFieldKind.primitive,
          isNullable: true,
        ),
      ]);
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('Stats'));
    });

    test('nullable record object field → Dart uses readNullTag() pattern', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Inner',
            fields: [
              BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
            ],
          ),
          BridgeRecordType(
            name: 'Outer',
            fields: [
              BridgeRecordField(
                name: 'inner',
                dartType: 'Inner?',
                kind: RecordFieldKind.recordObject,
                isNullable: true,
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getOuter',
            cSymbol: 'mod_get_outer',
            isAsync: false,
            returnType: BridgeType(name: 'Outer', isRecord: true),
            params: [],
          ),
        ],
      );
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('readNullTag()'));
    });
  });

  group('BridgeType isNullable flag', () {
    test('BridgeType isNullable defaults to false', () {
      final bt = BridgeType(name: 'int');
      expect(bt.isNullable, isFalse);
    });

    test('BridgeType isNullable can be set to true', () {
      final bt = BridgeType(name: 'int', isNullable: true);
      expect(bt.isNullable, isTrue);
    });

    test('BridgeType name with ? is stripped by CppInterfaceGenerator', () {
      final out = CppInterfaceGenerator.generate(_nullableReturnSpec('int?'));
      expect(out, contains('virtual int64_t getValue() = 0;'));
      expect(out, isNot(contains('int?')));
    });
  });
}
