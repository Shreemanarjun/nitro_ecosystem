// Async (Future<T>) return type tests across all three generators.
//
// Verifies that every Future<T> return type maps to the correct native signature in:
//   - Swift:  `async throws -> SwiftType` in protocol; semaphore-based C bridge stub
//   - Kotlin: `suspend fun name(): KotlinType` in interface
//   - Dart FFI: `Future<DartType> name()` wrapper (via DartFfiGenerator)
//
//   Return types covered: void, bool, int, double, String, @HybridEnum, @HybridStruct

import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeSpec _asyncSpec(
  String returnType, {
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  functions: [
    BridgeFunction(
      dartName: 'work',
      cSymbol: 'mod_work',
      isAsync: true,
      returnType: BridgeType(name: returnType),
      params: [],
    ),
  ],
);

BridgeSpec _asyncEnumSpec(String enumName) => _asyncSpec(
  enumName,
  enums: [
    BridgeEnum(name: enumName, startValue: 0, values: ['low', 'high']),
  ],
);

BridgeSpec _asyncStructSpec(String structName) => _asyncSpec(
  structName,
  structs: [
    BridgeStruct(
      name: structName,
      packed: false,
      fields: [
        BridgeField(
          name: 'val',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
  ],
);

// ── Swift: protocol async throws return type ──────────────────────────────────

void main() {
  group('SwiftGenerator — async protocol signature', () {
    test('Future<void> → async throws in protocol (no return arrow for void)', () {
      final out = SwiftGenerator.generate(_asyncSpec('void'));
      expect(out, contains('async throws'));
    });

    test('Future<bool> → async throws -> Bool', () {
      final out = SwiftGenerator.generate(_asyncSpec('bool'));
      expect(out, contains('async throws -> Bool'));
    });

    test('Future<int> → async throws -> Int64', () {
      final out = SwiftGenerator.generate(_asyncSpec('int'));
      expect(out, contains('async throws -> Int64'));
    });

    test('Future<double> → async throws -> Double', () {
      final out = SwiftGenerator.generate(_asyncSpec('double'));
      expect(out, contains('async throws -> Double'));
    });

    test('Future<String> → async throws -> String', () {
      final out = SwiftGenerator.generate(_asyncSpec('String'));
      expect(out, contains('async throws -> String'));
    });

    test('Future<@HybridEnum> → async throws -> EnumName', () {
      final out = SwiftGenerator.generate(_asyncEnumSpec('Priority'));
      expect(out, contains('async throws -> Priority'));
    });

    test('Future<@HybridStruct> → async throws -> StructName', () {
      final out = SwiftGenerator.generate(_asyncStructSpec('Reading'));
      expect(out, contains('async throws -> Reading'));
    });
  });

  // ── Swift: C bridge stub uses DispatchSemaphore ───────────────────────────

  group('SwiftGenerator — async C bridge stub uses DispatchSemaphore', () {
    test('Future<void> stub calls sema.wait()', () {
      final out = SwiftGenerator.generate(_asyncSpec('void'));
      expect(out, contains('sema.wait()'));
    });

    test('Future<bool> stub returns Int8 (bool bridge type)', () {
      final out = SwiftGenerator.generate(_asyncSpec('bool'));
      expect(out, contains('-> Int8'));
      expect(out, contains('sema.wait()'));
    });

    test('Future<int> stub returns result via sema', () {
      final out = SwiftGenerator.generate(_asyncSpec('int'));
      expect(out, contains('sema.wait()'));
      expect(out, contains('return result'));
    });

    test('Future<String> stub copies result via _nitroStringToCString (byte-exact, no BOM strip)', () {
      final out = SwiftGenerator.generate(_asyncSpec('String'));
      expect(out, contains('_nitroStringToCString(result)'));
    });

    test('Future<@HybridStruct> stub allocates C shadow pointer', () {
      final out = SwiftGenerator.generate(_asyncStructSpec('Sensor'));
      expect(out, contains('UnsafeMutablePointer<_SensorC>.allocate'));
    });
  });

  // ── Kotlin: interface suspend fun ─────────────────────────────────────────

  group('KotlinGenerator — async interface signature (suspend fun)', () {
    test('Future<void> → suspend fun work(): Unit', () {
      final out = KotlinGenerator.generate(_asyncSpec('void'));
      expect(out, contains('suspend fun work(): Unit'));
    });

    test('Future<bool> → suspend fun work(): Boolean', () {
      final out = KotlinGenerator.generate(_asyncSpec('bool'));
      expect(out, contains('suspend fun work(): Boolean'));
    });

    test('Future<int> → suspend fun work(): Long', () {
      final out = KotlinGenerator.generate(_asyncSpec('int'));
      expect(out, contains('suspend fun work(): Long'));
    });

    test('Future<double> → suspend fun work(): Double', () {
      final out = KotlinGenerator.generate(_asyncSpec('double'));
      expect(out, contains('suspend fun work(): Double'));
    });

    test('Future<String> → suspend fun work(): String', () {
      final out = KotlinGenerator.generate(_asyncSpec('String'));
      expect(out, contains('suspend fun work(): String'));
    });

    test('Future<@HybridEnum> → suspend fun work(): EnumName', () {
      final out = KotlinGenerator.generate(_asyncEnumSpec('Priority'));
      expect(out, contains('suspend fun work(): Priority'));
    });

    test('Future<@HybridStruct> → suspend fun work(): StructName', () {
      final out = KotlinGenerator.generate(_asyncStructSpec('Reading'));
      expect(out, contains('suspend fun work(): Reading'));
    });
  });

  // ── Kotlin: JniBridge _call uses runBlocking ──────────────────────────────

  group('KotlinGenerator — async JniBridge _call uses runBlocking', () {
    test('Future<void> _call uses runBlocking', () {
      final out = KotlinGenerator.generate(_asyncSpec('void'));
      expect(out, contains('runBlocking { impl.work() }'));
    });

    test('Future<int> _call returns via runBlocking', () {
      final out = KotlinGenerator.generate(_asyncSpec('int'));
      expect(out, contains('runBlocking { impl.work() }'));
    });
  });

  // ── Dart FFI: Future<T> wrapper signature ─────────────────────────────────

  group('DartFfiGenerator — async function emits Future<T> wrapper', () {
    test('Future<void> emits Future<void>', () {
      final out = DartFfiGenerator.generate(_asyncSpec('void'));
      expect(out, contains('Future<void>'));
    });

    test('Future<bool> emits Future<bool>', () {
      final out = DartFfiGenerator.generate(_asyncSpec('bool'));
      expect(out, contains('Future<bool>'));
    });

    test('Future<int> emits Future<int>', () {
      final out = DartFfiGenerator.generate(_asyncSpec('int'));
      expect(out, contains('Future<int>'));
    });

    test('Future<double> emits Future<double>', () {
      final out = DartFfiGenerator.generate(_asyncSpec('double'));
      expect(out, contains('Future<double>'));
    });

    test('Future<String> emits Future<String>', () {
      final out = DartFfiGenerator.generate(_asyncSpec('String'));
      expect(out, contains('Future<String>'));
    });

    test('Future<@HybridEnum> emits Future<EnumName>', () {
      final out = DartFfiGenerator.generate(_asyncEnumSpec('Priority'));
      expect(out, contains('Future<Priority>'));
    });

    test('Future<@HybridStruct> emits Future<StructName>', () {
      final out = DartFfiGenerator.generate(_asyncStructSpec('Reading'));
      expect(out, contains('Future<Reading>'));
    });
  });
}
