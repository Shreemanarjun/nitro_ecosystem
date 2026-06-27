// Missing CppInterfaceGenerator type coverage from §8.4 of the plan.
//
// Covers:
//   Section 1: Scalar return types — bool, int, String
//   Section 2: String param
//   Section 3: @HybridStruct param and return
//   Section 4: @HybridEnum param and return
//   Section 5: Pointer<Int32> param
//   Section 6: Properties — getter-only and getter+setter

import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Inline spec helpers ───────────────────────────────────────────────────────

BridgeSpec _retSpec(String typeName, {List<BridgeEnum> enums = const [], List<BridgeStruct> structs = const []}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.cpp,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: false,
      returnType: BridgeType(name: typeName),
      params: [],
    ),
  ],
);

BridgeSpec _paramSpec(String typeName, {List<BridgeEnum> enums = const [], List<BridgeStruct> structs = const []}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.cpp,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'x',
          type: BridgeType(name: typeName),
        ),
      ],
    ),
  ],
);

BridgeSpec _propSpec(String typeName, {bool hasSetter = false, List<BridgeEnum> enums = const [], List<BridgeStruct> structs = const []}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.cpp,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  properties: [
    BridgeProperty(
      dartName: 'x',
      type: BridgeType(name: typeName),
      getSymbol: 'mod_get_x',
      setSymbol: hasSetter ? 'mod_set_x' : null,
      hasGetter: true,
      hasSetter: hasSetter,
    ),
  ],
);

final _kColorStruct = [
  BridgeStruct(
    name: 'Color',
    packed: false,
    fields: [
      BridgeField(
        name: 'r',
        type: BridgeType(name: 'double'),
      ),
    ],
  ),
];
final _kStatusEnum = [
  BridgeEnum(name: 'Status', startValue: 0, values: ['off', 'on']),
];

void main() {
  // ── Section 1: Scalar return types ──────────────────────────────────────────

  group('CppInterfaceGenerator — scalar return types', () {
    test('bool return emits virtual bool fn() = 0', () {
      final out = CppInterfaceGenerator.generate(_retSpec('bool'));
      expect(out, contains('virtual bool fn() = 0'));
    });

    test('int return emits virtual int64_t fn() = 0', () {
      final out = CppInterfaceGenerator.generate(_retSpec('int'));
      expect(out, contains('virtual int64_t fn() = 0'));
    });

    test('String return emits virtual std::string fn() = 0', () {
      final out = CppInterfaceGenerator.generate(_retSpec('String'));
      expect(out, contains('virtual std::string fn() = 0'));
    });

    test('double return emits virtual double fn() = 0', () {
      final out = CppInterfaceGenerator.generate(_retSpec('double'));
      expect(out, contains('virtual double fn() = 0'));
    });

    test('void return emits virtual void fn() = 0', () {
      final out = CppInterfaceGenerator.generate(_retSpec('void'));
      expect(out, contains('virtual void fn() = 0'));
    });
  });

  // ── Section 2: String param ──────────────────────────────────────────────────

  group('CppInterfaceGenerator — String param', () {
    test('String param uses const std::string& in C++ interface', () {
      final out = CppInterfaceGenerator.generate(_paramSpec('String'));
      expect(out, contains('const std::string& x'));
    });

    test('String param method is pure virtual', () {
      final out = CppInterfaceGenerator.generate(_paramSpec('String'));
      expect(out, contains('virtual void fn(const std::string& x) = 0'));
    });
  });

  // ── Section 3: @HybridStruct param and return ────────────────────────────────

  group('CppInterfaceGenerator — @HybridStruct param and return', () {
    test('struct param uses const Color& in C++ interface', () {
      final out = CppInterfaceGenerator.generate(
        _paramSpec('Color', structs: _kColorStruct),
      );
      expect(out, contains('const Color& x'));
    });

    test('struct return emits the struct type directly', () {
      final out = CppInterfaceGenerator.generate(
        _retSpec('Color', structs: _kColorStruct),
      );
      expect(out, contains('virtual Color fn() = 0'));
    });

    test('struct param method is pure virtual', () {
      final out = CppInterfaceGenerator.generate(
        _paramSpec('Color', structs: _kColorStruct),
      );
      expect(out, contains('= 0'));
    });
  });

  // ── Section 4: @HybridEnum param and return ──────────────────────────────────

  group('CppInterfaceGenerator — @HybridEnum param and return', () {
    test('enum param uses enum type (not int64_t) in C++ interface', () {
      final out = CppInterfaceGenerator.generate(
        _paramSpec('Status', enums: _kStatusEnum),
      );
      expect(out, contains('Status x'));
    });

    test('enum return emits the enum type directly', () {
      final out = CppInterfaceGenerator.generate(
        _retSpec('Status', enums: _kStatusEnum),
      );
      expect(out, contains('virtual Status fn() = 0'));
    });
  });

  // ── Section 5: Pointer<Int32> param ─────────────────────────────────────────

  group('CppInterfaceGenerator — Pointer<Int32> param', () {
    test('Pointer<Int32> param emits int32_t* in C++ interface', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'buf',
                type: BridgeType(
                  name: 'Pointer<Int32>',
                  isPointer: true,
                  pointerInnerType: 'Int32',
                ),
              ),
            ],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('int32_t*'));
    });
  });

  // ── Section 6: Properties ────────────────────────────────────────────────────

  group('CppInterfaceGenerator — getter-only property', () {
    test('read-only int property emits virtual int64_t getX() const = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('int'));
      expect(out, contains('virtual int64_t get_x() const = 0'));
    });

    test('read-only bool property emits virtual bool getX() const = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('bool'));
      expect(out, contains('virtual bool get_x() const = 0'));
    });

    test('read-only String property emits virtual std::string getX() const = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('String'));
      expect(out, contains('virtual std::string get_x() const = 0'));
    });

    test('getter-only property does NOT emit a setter', () {
      final out = CppInterfaceGenerator.generate(_propSpec('int'));
      expect(out, isNot(contains('set_x')));
    });
  });

  group('CppInterfaceGenerator — getter+setter property', () {
    test('read-write int property emits setter virtual void setX(int64_t)', () {
      final out = CppInterfaceGenerator.generate(_propSpec('int', hasSetter: true));
      expect(out, contains('virtual void set_x(int64_t value) = 0'));
    });

    test('read-write bool property emits setter virtual void setX(bool)', () {
      final out = CppInterfaceGenerator.generate(_propSpec('bool', hasSetter: true));
      expect(out, contains('virtual void set_x(bool value) = 0'));
    });

    test('read-write property emits both getter and setter', () {
      final out = CppInterfaceGenerator.generate(_propSpec('int', hasSetter: true));
      expect(out, contains('get_x'));
      expect(out, contains('set_x'));
    });

    test('read-write enum property setter uses enum type', () {
      final out = CppInterfaceGenerator.generate(
        _propSpec('Status', hasSetter: true, enums: _kStatusEnum),
      );
      expect(out, contains('virtual void set_x(Status value) = 0'));
    });
  });
}
