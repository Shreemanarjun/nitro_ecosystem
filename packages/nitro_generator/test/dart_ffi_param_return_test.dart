// Missing DartFfiGenerator param/return type tests from §8.1 of the plan.
//
// Covers:
//   Section 1: Nullable named params — {bool? flag}, {double? d}
//   Section 2: Non-nullable named params with defaults — Bug 5.1 + Bug 5.2 (enum default)
//   Section 3: Future<Uint8List> async return
//   Section 4: Future<@HybridStruct> async return
//   Section 5: Nullable struct param Foo?
//   Section 6: @HybridEnum positional param in Dart signature
//   Section 7: TypedData param variants — Int8List, Float32List coverage

import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  // ── Section 1: Nullable named params ────────────────────────────────────────

  group('DartFfiGenerator — nullable named params', () {
    test('{bool? flag} named optional param emits curly-brace syntax', () {
      final out = DartFfiGenerator.generate(optionalBoolParamSpec());
      expect(out, contains('{bool? flag'));
    });

    test('{double? d} named optional param emits curly-brace syntax', () {
      final out = DartFfiGenerator.generate(optionalDoubleParamSpec());
      expect(out, contains('{double? d'));
    });

    test('bool? optional param does not require a default value', () {
      final out = DartFfiGenerator.generate(optionalBoolParamSpec());
      // nullable params are valid without a default literal
      expect(out, isNot(contains('{bool? flag = ')));
    });
  });

  // ── Section 2: Named params with defaults (Bug 5.1 / Bug 5.2) ───────────────

  group('DartFfiGenerator — named params with defaultLiteral (Bug 5.1 fix)', () {
    test('{int x = 5} emits non-nullable param with default literal', () {
      final out = DartFfiGenerator.generate(defaultIntParamSpec());
      expect(out, contains('{int x = 5}'));
    });

    test('{int x = 5} does not emit {required int x}', () {
      final out = DartFfiGenerator.generate(defaultIntParamSpec());
      expect(out, isNot(contains('required int x')));
    });
  });

  group('DartFfiGenerator — enum named param with default (Bug 5.2)', () {
    test('{Quality quality = Quality.normal} emits enum default', () {
      final out = DartFfiGenerator.generate(defaultEnumParamSpec());
      expect(out, contains('{Quality quality = Quality.normal}'));
    });

    test('enum param with default does NOT emit required keyword', () {
      final out = DartFfiGenerator.generate(defaultEnumParamSpec());
      expect(out, isNot(contains('required Quality quality')));
    });

    test('enum param with default is in the override method signature', () {
      final out = DartFfiGenerator.generate(defaultEnumParamSpec());
      // The override in _ModImpl should have the full signature
      expect(out, contains('@override'));
      expect(out, contains('Quality quality = Quality.normal'));
    });
  });

  // ── Section 2b: Struct-typed default param (Bug 5.3) ────────────────────────

  group('DartFfiGenerator — struct named param with default (Bug 5.3)', () {
    final spec = BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mod.native.dart',
      structs: [
        BridgeStruct(name: 'PrintSettings', packed: false, fields: [
          BridgeField(name: 'copies', type: BridgeType(name: 'int')),
        ]),
      ],
      functions: [
        BridgeFunction(
          dartName: 'printDoc',
          cSymbol: 'mod_print_doc',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'settings',
              type: BridgeType(name: 'PrintSettings', isRecord: false),
              isNamed: true,
              isOptional: true,
              defaultLiteral: 'PrintSettings(copies: 1)',
            ),
          ],
        ),
      ],
    );

    test('{PrintSettings settings = PrintSettings(copies: 1)} emits struct default', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('{PrintSettings settings = PrintSettings(copies: 1)}'));
    });

    test('struct param with default does NOT emit required keyword', () {
      final out = DartFfiGenerator.generate(spec);
      expect(out, isNot(contains('required PrintSettings settings')));
    });
  });

  // ── Section 3: Future<Uint8List> async return ────────────────────────────────

  group('DartFfiGenerator — Future<Uint8List> async return', () {
    test('getData returns Future<Uint8List>', () {
      final out = DartFfiGenerator.generate(asyncUint8ListReturnSpec());
      expect(out, contains('Future<Uint8List>'));
    });

    test('async Uint8List uses NitroRuntime.callAsync', () {
      final out = DartFfiGenerator.generate(asyncUint8ListReturnSpec());
      expect(out, contains('callAsync'));
    });

    test('async Uint8List does not return void', () {
      final out = DartFfiGenerator.generate(asyncUint8ListReturnSpec());
      expect(out, isNot(contains('Future<void> getData')));
    });
  });

  // ── Section 4: Future<@HybridStruct> async return ───────────────────────────

  group('DartFfiGenerator — Future<@HybridStruct> async return', () {
    test('fetch returns Future<Reading>', () {
      final out = DartFfiGenerator.generate(asyncStructReturnSpec());
      expect(out, contains('Future<Reading>'));
    });

    test('async struct return uses NitroRuntime.callAsync', () {
      final out = DartFfiGenerator.generate(asyncStructReturnSpec());
      expect(out, contains('callAsync'));
    });

    test('async struct return decodes via struct unpack, not jsonDecode', () {
      final out = DartFfiGenerator.generate(asyncStructReturnSpec());
      expect(out, isNot(contains('jsonDecode')));
    });
  });

  // ── Section 5: Nullable struct param Foo? ───────────────────────────────────

  group('DartFfiGenerator — nullable struct param Foo?', () {
    test('Foo? param appears in Dart @override method signature', () {
      final out = DartFfiGenerator.generate(nullableStructParamSpec());
      expect(out, contains('Foo? x'));
    });

    test('Foo? param uses void* in FFI (struct passed as pointer)', () {
      final out = DartFfiGenerator.generate(nullableStructParamSpec());
      // Structs (nullable or not) pass as Pointer<Void> in FFI
      expect(out, contains('Pointer<Void>'));
    });
  });

  // ── Section 6: @HybridEnum positional param ──────────────────────────────────

  group('DartFfiGenerator — @HybridEnum positional param/return', () {
    test('enum return type appears in Dart @override signature', () {
      final out = DartFfiGenerator.generate(enumSpec());
      // enumSpec has DeviceStatus enum return type
      expect(out, contains('DeviceStatus'));
    });

    test('enum return converts from nativeValue (int64_t) in FFI call', () {
      final out = DartFfiGenerator.generate(enumSpec());
      expect(out, contains('nativeValue'));
    });
  });

  // ── Section 7: TypedData param variants ─────────────────────────────────────

  group('DartFfiGenerator — TypedData param variants in Dart signature', () {
    for (final typeName in [
      'Uint8List',
      'Int8List',
      'Int16List',
      'Int32List',
      'Uint16List',
      'Uint32List',
      'Float32List',
      'Float64List',
      'Int64List',
      'Uint64List',
    ]) {
      test('$typeName param appears as $typeName in Dart signature', () {
        final out = DartFfiGenerator.generate(typedDataParamSpec(typeName));
        expect(out, contains('$typeName x'));
      });
    }
  });
}
