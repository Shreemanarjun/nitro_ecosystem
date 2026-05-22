// Property type tests across SwiftGenerator, KotlinGenerator, and CppInterfaceGenerator.
//
// Verifies that every property type produces the correct getter/setter signature
// in all three native target languages.
//
//   Section 1: Scalar properties in Swift protocol (Bool/Int64/Double/String)
//   Section 2: Scalar properties in Kotlin interface (Boolean/Long/Double/String)
//   Section 3: Scalar properties in C++ interface (bool/int64_t/double/std::string)
//   Section 4: Enum properties in Swift, Kotlin, and C++
//   Section 5: Struct properties in Swift, Kotlin, and C++
//   Section 6: Read-only (val / {get}) vs read-write (var / {get set}) enforcement

import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/cpp_interface_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeProperty _prop(
  String dartType, {
  String name = 'value',
  bool readOnly = false,
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeProperty(
  dartName: name,
  type: BridgeType(name: dartType),
  getSymbol: 'mod_get_$name',
  setSymbol: 'mod_set_$name',
  hasGetter: true,
  hasSetter: !readOnly,
);

BridgeSpec _propSpec(
  String dartType, {
  String name = 'value',
  bool readOnly = false,
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
  bool forCpp = false,
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: forCpp ? NativeImpl.cpp : NativeImpl.swift,
  androidImpl: forCpp ? NativeImpl.cpp : NativeImpl.kotlin,
  macosImpl: forCpp ? NativeImpl.cpp : null,
  windowsImpl: forCpp ? NativeImpl.cpp : null,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  properties: [_prop(dartType, name: name, readOnly: readOnly)],
);

// ── Section 1: Swift property type mapping ────────────────────────────────────

void main() {
  group('SwiftGenerator — property types in protocol (read-write)', () {
    test('bool property → var value: Bool { get set }', () {
      final out = SwiftGenerator.generate(_propSpec('bool'));
      expect(out, contains('var value: Bool { get set }'));
    });

    test('int property → var value: Int64 { get set }', () {
      final out = SwiftGenerator.generate(_propSpec('int'));
      expect(out, contains('var value: Int64 { get set }'));
    });

    test('double property → var value: Double { get set }', () {
      final out = SwiftGenerator.generate(_propSpec('double'));
      expect(out, contains('var value: Double { get set }'));
    });

    test('String property → var value: String { get set }', () {
      final out = SwiftGenerator.generate(_propSpec('String'));
      expect(out, contains('var value: String { get set }'));
    });
  });

  group('SwiftGenerator — property types in protocol (read-only)', () {
    test('bool read-only → var value: Bool { get }', () {
      final out = SwiftGenerator.generate(_propSpec('bool', readOnly: true));
      expect(out, contains('var value: Bool { get }'));
      expect(out, isNot(contains('{ get set }')));
    });

    test('int read-only → var value: Int64 { get }', () {
      final out = SwiftGenerator.generate(_propSpec('int', readOnly: true));
      expect(out, contains('var value: Int64 { get }'));
    });

    test('double read-only → var value: Double { get }', () {
      final out = SwiftGenerator.generate(_propSpec('double', readOnly: true));
      expect(out, contains('var value: Double { get }'));
    });

    test('String read-only → var value: String { get }', () {
      final out = SwiftGenerator.generate(_propSpec('String', readOnly: true));
      expect(out, contains('var value: String { get }'));
    });
  });

  // ── Section 2: Kotlin property type mapping ──────────────────────────────

  group('KotlinGenerator — property types in interface (read-write → var)', () {
    test('bool property → var value: Boolean', () {
      final out = KotlinGenerator.generate(_propSpec('bool'));
      expect(out, contains('var value: Boolean'));
    });

    test('int property → var value: Long', () {
      final out = KotlinGenerator.generate(_propSpec('int'));
      expect(out, contains('var value: Long'));
    });

    test('double property → var value: Double', () {
      final out = KotlinGenerator.generate(_propSpec('double'));
      expect(out, contains('var value: Double'));
    });

    test('String property → var value: String', () {
      final out = KotlinGenerator.generate(_propSpec('String'));
      expect(out, contains('var value: String'));
    });
  });

  group('KotlinGenerator — property types in interface (read-only → val)', () {
    test('bool read-only → val value: Boolean', () {
      final out = KotlinGenerator.generate(_propSpec('bool', readOnly: true));
      expect(out, contains('val value: Boolean'));
      expect(out, isNot(contains('var value: Boolean')));
    });

    test('int read-only → val value: Long', () {
      final out = KotlinGenerator.generate(_propSpec('int', readOnly: true));
      expect(out, contains('val value: Long'));
    });

    test('double read-only → val value: Double', () {
      final out = KotlinGenerator.generate(_propSpec('double', readOnly: true));
      expect(out, contains('val value: Double'));
    });

    test('String read-only → val value: String', () {
      final out = KotlinGenerator.generate(_propSpec('String', readOnly: true));
      expect(out, contains('val value: String'));
    });
  });

  // ── Section 3: C++ interface property type mapping ───────────────────────

  group('CppInterfaceGenerator — scalar property getter types', () {
    test('bool property → virtual bool get_value() const = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('bool', forCpp: true));
      expect(out, contains('virtual bool get_value() const = 0'));
    });

    test('int property → virtual int64_t get_value() const = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('int', forCpp: true));
      expect(out, contains('virtual int64_t get_value() const = 0'));
    });

    test('double property → virtual double get_value() const = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('double', forCpp: true));
      expect(out, contains('virtual double get_value() const = 0'));
    });

    test('String property → virtual std::string get_value() const = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('String', forCpp: true));
      expect(out, contains('virtual std::string get_value() const = 0'));
    });
  });

  group('CppInterfaceGenerator — scalar property setter types', () {
    test('bool setter → virtual void set_value(bool value) = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('bool', forCpp: true));
      expect(out, contains('virtual void set_value(bool value) = 0'));
    });

    test('int setter → virtual void set_value(int64_t value) = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('int', forCpp: true));
      expect(out, contains('virtual void set_value(int64_t value) = 0'));
    });

    test('double setter → virtual void set_value(double value) = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('double', forCpp: true));
      expect(out, contains('virtual void set_value(double value) = 0'));
    });

    test('String setter → virtual void set_value(const std::string& value) = 0', () {
      final out = CppInterfaceGenerator.generate(_propSpec('String', forCpp: true));
      expect(out, contains('virtual void set_value(const std::string& value) = 0'));
    });
  });

  group('CppInterfaceGenerator — read-only property has getter but no setter', () {
    test('bool read-only has getter', () {
      final out = CppInterfaceGenerator.generate(_propSpec('bool', readOnly: true, forCpp: true));
      expect(out, contains('virtual bool get_value() const = 0'));
    });

    test('bool read-only has no setter', () {
      final out = CppInterfaceGenerator.generate(_propSpec('bool', readOnly: true, forCpp: true));
      expect(out, isNot(contains('set_value')));
    });

    test('int read-only has no setter', () {
      final out = CppInterfaceGenerator.generate(_propSpec('int', readOnly: true, forCpp: true));
      expect(out, isNot(contains('set_value')));
    });
  });

  // ── Section 4: Enum properties ───────────────────────────────────────────

  BridgeSpec _enumPropSpec({bool readOnly = false, bool forCpp = false}) => BridgeSpec(
    dartClassName: 'Mod',
    lib: 'mod',
    namespace: 'mod',
    iosImpl: forCpp ? NativeImpl.cpp : NativeImpl.swift,
    androidImpl: forCpp ? NativeImpl.cpp : NativeImpl.kotlin,
    macosImpl: forCpp ? NativeImpl.cpp : null,
    windowsImpl: forCpp ? NativeImpl.cpp : null,
    sourceUri: 'mod.native.dart',
    enums: [BridgeEnum(name: 'Mode', startValue: 0, values: ['off', 'on'])],
    properties: [
      BridgeProperty(
        dartName: 'mode',
        type: BridgeType(name: 'Mode'),
        getSymbol: 'mod_get_mode',
        setSymbol: 'mod_set_mode',
        hasGetter: true,
        hasSetter: !readOnly,
      ),
    ],
  );

  group('SwiftGenerator — enum property', () {
    test('enum read-write property → var mode: Mode { get set }', () {
      final out = SwiftGenerator.generate(_enumPropSpec());
      expect(out, contains('var mode: Mode { get set }'));
    });

    test('enum read-only property → var mode: Mode { get }', () {
      final out = SwiftGenerator.generate(_enumPropSpec(readOnly: true));
      expect(out, contains('var mode: Mode { get }'));
    });
  });

  group('KotlinGenerator — enum property', () {
    test('enum read-write property → var mode: Mode', () {
      final out = KotlinGenerator.generate(_enumPropSpec());
      expect(out, contains('var mode: Mode'));
    });

    test('enum read-only property → val mode: Mode', () {
      final out = KotlinGenerator.generate(_enumPropSpec(readOnly: true));
      expect(out, contains('val mode: Mode'));
    });
  });

  group('CppInterfaceGenerator — enum property', () {
    test('enum getter → virtual Mode get_mode() const = 0', () {
      final out = CppInterfaceGenerator.generate(_enumPropSpec(forCpp: true));
      expect(out, contains('virtual Mode get_mode() const = 0'));
    });

    test('enum setter → virtual void set_mode(Mode value) = 0', () {
      final out = CppInterfaceGenerator.generate(_enumPropSpec(forCpp: true));
      expect(out, contains('virtual void set_mode(Mode value) = 0'));
    });

    test('enum read-only has no setter', () {
      final out = CppInterfaceGenerator.generate(_enumPropSpec(readOnly: true, forCpp: true));
      expect(out, isNot(contains('set_mode')));
    });
  });

  // ── Section 5: Struct properties ─────────────────────────────────────────

  BridgeSpec _structPropSpec({bool readOnly = false, bool forCpp = false}) => BridgeSpec(
    dartClassName: 'Mod',
    lib: 'mod',
    namespace: 'mod',
    iosImpl: forCpp ? NativeImpl.cpp : NativeImpl.swift,
    androidImpl: forCpp ? NativeImpl.cpp : NativeImpl.kotlin,
    macosImpl: forCpp ? NativeImpl.cpp : null,
    windowsImpl: forCpp ? NativeImpl.cpp : null,
    sourceUri: 'mod.native.dart',
    structs: [
      BridgeStruct(name: 'Config', packed: false, fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
      ]),
    ],
    properties: [
      BridgeProperty(
        dartName: 'config',
        type: BridgeType(name: 'Config'),
        getSymbol: 'mod_get_config',
        setSymbol: 'mod_set_config',
        hasGetter: true,
        hasSetter: !readOnly,
      ),
    ],
  );

  group('SwiftGenerator — struct property', () {
    test('struct read-only property → var config: Config { get }', () {
      final out = SwiftGenerator.generate(_structPropSpec(readOnly: true));
      expect(out, contains('var config: Config { get }'));
    });

    test('struct read-write property → var config: Config { get set }', () {
      final out = SwiftGenerator.generate(_structPropSpec());
      expect(out, contains('var config: Config { get set }'));
    });
  });

  group('KotlinGenerator — struct property', () {
    test('struct read-only property → val config: Config', () {
      final out = KotlinGenerator.generate(_structPropSpec(readOnly: true));
      expect(out, contains('val config: Config'));
    });

    test('struct read-write property → var config: Config', () {
      final out = KotlinGenerator.generate(_structPropSpec());
      expect(out, contains('var config: Config'));
    });
  });

  group('CppInterfaceGenerator — struct property', () {
    test('struct getter → virtual Config get_config() const = 0', () {
      final out = CppInterfaceGenerator.generate(_structPropSpec(forCpp: true));
      expect(out, contains('virtual Config get_config() const = 0'));
    });

    test('struct setter → virtual void set_config(const Config& value) = 0', () {
      final out = CppInterfaceGenerator.generate(_structPropSpec(forCpp: true));
      expect(out, contains('virtual void set_config(const Config& value) = 0'));
    });
  });

  // ── Section 6: Multiple properties in same spec ───────────────────────────

  group('Multiple properties in same spec emit all declarations', () {
    BridgeSpec _multiPropSpec() => BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mod.native.dart',
      properties: [
        BridgeProperty(dartName: 'count', type: BridgeType(name: 'int'),
          getSymbol: 'mod_get_count', setSymbol: 'mod_set_count', hasGetter: true, hasSetter: true),
        BridgeProperty(dartName: 'name', type: BridgeType(name: 'String'),
          getSymbol: 'mod_get_name', setSymbol: 'mod_set_name', hasGetter: true, hasSetter: false),
        BridgeProperty(dartName: 'active', type: BridgeType(name: 'bool'),
          getSymbol: 'mod_get_active', setSymbol: 'mod_set_active', hasGetter: true, hasSetter: true),
      ],
    );

    test('Swift emits all three property declarations', () {
      final out = SwiftGenerator.generate(_multiPropSpec());
      expect(out, contains('var count: Int64 { get set }'));
      expect(out, contains('var name: String { get }'));
      expect(out, contains('var active: Bool { get set }'));
    });

    test('Kotlin emits all three property declarations', () {
      final out = KotlinGenerator.generate(_multiPropSpec());
      expect(out, contains('var count: Long'));
      expect(out, contains('val name: String'));
      expect(out, contains('var active: Boolean'));
    });
  });
}
