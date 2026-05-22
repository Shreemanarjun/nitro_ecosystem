// Comprehensive type-mapping tests for CppInterfaceGenerator.
//
// Covers every Dart type → C++ type translation in virtual function signatures:
//
//   Section 1: Scalar primitive params and returns (bool/int/double/String/void)
//   Section 2: All 10 TypedData variants as params (const T* + size_t length)
//   Section 3: Nullable scalars (? stripped in C++)
//   Section 4: @HybridEnum param and return types
//   Section 5: @HybridStruct param and return types
//   Section 6: C++ interface header boilerplate (virtual, = 0, pure virtual)

import 'package:nitro_generator/src/generators/cpp_interface_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeSpec _fnSpec(
  String returnType,
  List<BridgeParam> params, {
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  macosImpl: NativeImpl.cpp,
  windowsImpl: NativeImpl.cpp,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
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

BridgeParam _p(String type, String name) =>
    BridgeParam(name: name, type: BridgeType(name: type));

BridgeSpec _typedDataSpec(String typeName) =>
    _fnSpec('void', [_p(typeName, 'data')]);

// ── Section 1: Scalar primitive params ───────────────────────────────────────

void main() {
  group('CppInterfaceGenerator — scalar primitive params', () {
    test('bool param → bool flag', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', [_p('bool', 'flag')]));
      expect(out, contains('bool flag'));
    });

    test('int param → int64_t count', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', [_p('int', 'count')]));
      expect(out, contains('int64_t count'));
    });

    test('double param → double value', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', [_p('double', 'value')]));
      expect(out, contains('double value'));
    });

    test('String param → const std::string& text', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', [_p('String', 'text')]));
      expect(out, contains('const std::string& text'));
    });
  });

  group('CppInterfaceGenerator — scalar primitive returns', () {
    test('bool return → virtual bool fn()', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('bool', []));
      expect(out, contains('virtual bool fn()'));
    });

    test('int return → virtual int64_t fn()', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('int', []));
      expect(out, contains('virtual int64_t fn()'));
    });

    test('double return → virtual double fn()', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('double', []));
      expect(out, contains('virtual double fn()'));
    });

    test('String return → virtual std::string fn()', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('String', []));
      expect(out, contains('virtual std::string fn()'));
    });

    test('void return → virtual void fn()', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', []));
      expect(out, contains('virtual void fn()'));
    });
  });

  // ── Section 2: TypedData params → pointer + length ───────────────────────

  group('CppInterfaceGenerator — TypedData params emit pointer + size_t length', () {
    test('Uint8List → const uint8_t* data, size_t data_length', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Uint8List'));
      expect(out, contains('const uint8_t* data'));
      expect(out, contains('size_t data_length'));
    });

    test('Int8List → const int8_t* data, size_t data_length', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Int8List'));
      expect(out, contains('const int8_t* data'));
      expect(out, contains('size_t data_length'));
    });

    test('Int16List → const int16_t* data', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Int16List'));
      expect(out, contains('const int16_t* data'));
    });

    test('Uint16List → const uint16_t* data', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Uint16List'));
      expect(out, contains('const uint16_t* data'));
    });

    test('Int32List → const int32_t* data', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Int32List'));
      expect(out, contains('const int32_t* data'));
    });

    test('Uint32List → const uint32_t* data', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Uint32List'));
      expect(out, contains('const uint32_t* data'));
    });

    test('Float32List → const float* data', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Float32List'));
      expect(out, contains('const float* data'));
    });

    test('Float64List → const double* data', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Float64List'));
      expect(out, contains('const double* data'));
    });

    test('Int64List → const int64_t* data', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Int64List'));
      expect(out, contains('const int64_t* data'));
    });

    test('Uint64List → const uint64_t* data', () {
      final out = CppInterfaceGenerator.generate(_typedDataSpec('Uint64List'));
      expect(out, contains('const uint64_t* data'));
    });

    test('TypedData param always adds size_t length parameter', () {
      for (final td in ['Uint8List', 'Int16List', 'Float32List', 'Int64List']) {
        final out = CppInterfaceGenerator.generate(_typedDataSpec(td));
        expect(out, contains('size_t data_length'), reason: '$td should add _length');
      }
    });
  });

  // ── Section 3: Nullable types — ? stripped in C++ ────────────────────────

  group('CppInterfaceGenerator — nullable types strip ? in C++', () {
    test('int? param → int64_t count (? stripped)', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', [_p('int?', 'count')]));
      expect(out, contains('int64_t count'));
      expect(out, isNot(contains('int64_t?')));
    });

    test('bool? param → bool flag (? stripped)', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', [_p('bool?', 'flag')]));
      expect(out, contains('bool flag'));
    });

    test('double? param → double value (? stripped)', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', [_p('double?', 'value')]));
      expect(out, contains('double value'));
    });

    test('String? param → const std::string& text (? stripped)', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', [_p('String?', 'text')]));
      expect(out, contains('const std::string& text'));
    });

    test('int? return → virtual int64_t fn() (? stripped)', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('int?', []));
      expect(out, contains('virtual int64_t fn()'));
    });
  });

  // ── Section 4: Enum types ─────────────────────────────────────────────────

  group('CppInterfaceGenerator — @HybridEnum types', () {
    BridgeSpec _enumSpec(String enumName) => _fnSpec(
      enumName,
      [_p(enumName, 'mode')],
      enums: [BridgeEnum(name: enumName, startValue: 0, values: ['a', 'b'])],
    );

    test('enum param → EnumName mode (no const&)', () {
      final out = CppInterfaceGenerator.generate(_enumSpec('Status'));
      expect(out, contains('Status mode'));
      expect(out, isNot(contains('const Status&')));
    });

    test('enum return → virtual EnumName fn()', () {
      final out = CppInterfaceGenerator.generate(_enumSpec('Status'));
      expect(out, contains('virtual Status fn(Status mode)'));
    });

    test('nullable enum? param strips ? → EnumName mode', () {
      final spec = _fnSpec(
        'void',
        [_p('Status?', 'mode')],
        enums: [BridgeEnum(name: 'Status', startValue: 0, values: ['a', 'b'])],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('Status mode'));
    });
  });

  // ── Section 5: Struct types ───────────────────────────────────────────────

  group('CppInterfaceGenerator — @HybridStruct types', () {
    BridgeSpec _structSpec(String structName) => _fnSpec(
      structName,
      [_p(structName, 'src')],
      structs: [
        BridgeStruct(name: structName, packed: false, fields: [
          BridgeField(name: 'x', type: BridgeType(name: 'double')),
        ]),
      ],
    );

    test('struct param → const StructName& src', () {
      final out = CppInterfaceGenerator.generate(_structSpec('Point'));
      expect(out, contains('const Point& src'));
    });

    test('struct return → virtual StructName fn()', () {
      final out = CppInterfaceGenerator.generate(_structSpec('Point'));
      expect(out, contains('virtual Point fn(const Point& src)'));
    });

    test('nullable struct? param strips ? → const StructName& src', () {
      final spec = _fnSpec(
        'void',
        [_p('Point?', 'src')],
        structs: [
          BridgeStruct(name: 'Point', packed: false, fields: [
            BridgeField(name: 'x', type: BridgeType(name: 'double')),
          ]),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('const Point& src'));
    });
  });

  // ── Section 6: C++ interface boilerplate ─────────────────────────────────

  group('CppInterfaceGenerator — class boilerplate', () {
    test('emits pure virtual class Hybrid<Name>', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', []));
      expect(out, contains('class HybridMod'));
    });

    test('all functions are pure virtual (= 0)', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('int', [_p('String', 'x')]));
      expect(out, contains('= 0'));
    });

    test('virtual destructor is included', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('void', []));
      expect(out, contains('virtual ~Hybrid'));
    });

    test('multiple params in correct order', () {
      final out = CppInterfaceGenerator.generate(_fnSpec('bool', [
        _p('String', 'host'),
        _p('int', 'port'),
        _p('bool', 'secure'),
      ]));
      expect(out, contains('const std::string& host, int64_t port, bool secure'));
    });
  });
}
