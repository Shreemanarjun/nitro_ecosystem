// Missing Kotlin JniBridge _call return-type tests from §8.3 of the plan.
//
// Covers:
//   Section 1: Sync _call return types — bool → Boolean (not Long), String, double
//   Section 2: Async _call return types — bool, double, String, enum nativeValue
//   Section 3: Async _call enum → Long via nativeValue
//   Section 4: _call void → Unit (no return statement)

import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

BridgeSpec _syncReturnSpec(String returnType, {List<BridgeEnum> enums = const []}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  enums: enums,
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: false,
      returnType: BridgeType(name: returnType),
      params: [],
    ),
  ],
);

BridgeSpec _asyncReturnSpec(String returnType, {List<BridgeEnum> enums = const []}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  enums: enums,
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: true,
      returnType: BridgeType(name: returnType),
      params: [],
    ),
  ],
);

final _kPriorityEnum = [
  BridgeEnum(name: 'Priority', startValue: 0, values: ['low', 'high']),
];

void main() {
  // ── Section 1: Sync _call return types ──────────────────────────────────────

  group('KotlinGenerator — sync JniBridge _call return type: bool', () {
    test('bool sync return → fun fn_call(): Boolean (not Long)', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('bool'));
      expect(out, contains('fun fn_call(): Boolean'));
    });

    test('bool sync _call returns impl.fn() directly (no nativeValue)', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('bool'));
      // Boolean return goes through the plain `return impl.fn()` path
      expect(out, contains('return impl.fn()'));
      expect(out, isNot(contains('.nativeValue')));
    });

    test('bool sync _call does NOT return Long', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('bool'));
      expect(out, isNot(contains('fun fn_call(): Long')));
    });
  });

  group('KotlinGenerator — sync JniBridge _call return type: String', () {
    test('String sync return → fun fn_call(): String', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('String'));
      expect(out, contains('fun fn_call(): String'));
    });

    test('String sync _call returns impl.fn() directly', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('String'));
      expect(out, contains('return impl.fn()'));
    });
  });

  group('KotlinGenerator — sync JniBridge _call return type: double', () {
    test('double sync return → fun fn_call(): Double', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('double'));
      expect(out, contains('fun fn_call(): Double'));
    });

    test('double sync _call returns impl.fn() directly', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('double'));
      expect(out, contains('return impl.fn()'));
    });
  });

  group('KotlinGenerator — sync JniBridge _call return type: int', () {
    test('int sync return → fun fn_call(): Long', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('int'));
      expect(out, contains('fun fn_call(): Long'));
    });
  });

  group('KotlinGenerator — sync JniBridge _call return type: void', () {
    test('void sync _call → fun fn_call(): Unit', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('void'));
      expect(out, contains('fun fn_call(): Unit'));
    });

    test('void sync _call body calls impl.fn() without return', () {
      final out = KotlinGenerator.generate(_syncReturnSpec('void'));
      expect(out, contains('impl.fn()'));
    });
  });

  // ── Section 2: Async _call return types ──────────────────────────────────────

  group('KotlinGenerator — async JniBridge _call return type: bool', () {
    test('async bool → fun fn_call(): Boolean', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('bool'));
      expect(out, contains('fun fn_call(): Boolean'));
    });

    test('async bool _call uses runBlocking', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('bool'));
      expect(out, contains('runBlocking { impl.fn() }'));
    });

    test('async bool _call uses _asyncExecutor.submit', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('bool'));
      expect(out, contains('_asyncExecutor.submit'));
    });

    test('async bool _call does NOT use postBoolToPort (not @NitroNativeAsync)', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('bool'));
      // postBoolToPort is only for @NitroNativeAsync, not regular Future<T>
      expect(out, isNot(contains('postBoolToPort')));
    });
  });

  group('KotlinGenerator — async JniBridge _call return type: double', () {
    test('async double → fun fn_call(): Double', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('double'));
      expect(out, contains('fun fn_call(): Double'));
    });

    test('async double _call uses runBlocking', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('double'));
      expect(out, contains('runBlocking { impl.fn() }'));
    });
  });

  group('KotlinGenerator — async JniBridge _call return type: String', () {
    test('async String → fun fn_call(): String', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('String'));
      expect(out, contains('fun fn_call(): String'));
    });

    test('async String _call uses runBlocking', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('String'));
      expect(out, contains('runBlocking { impl.fn() }'));
    });

    test('async String _call uses _asyncExecutor.submit', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('String'));
      expect(out, contains('_asyncExecutor.submit'));
    });
  });

  // ── Section 3: Async _call enum → Long via nativeValue ──────────────────────

  group('KotlinGenerator — async JniBridge _call return type: enum', () {
    test('async enum → fun fn_call(): Long (bridged via nativeValue)', () {
      final out = KotlinGenerator.generate(
        _asyncReturnSpec('Priority', enums: _kPriorityEnum),
      );
      expect(out, contains('fun fn_call(): Long'));
    });

    test('async enum _call returns .nativeValue from runBlocking result', () {
      final out = KotlinGenerator.generate(
        _asyncReturnSpec('Priority', enums: _kPriorityEnum),
      );
      expect(out, contains('.nativeValue'));
    });

    test('async enum _call uses runBlocking', () {
      final out = KotlinGenerator.generate(
        _asyncReturnSpec('Priority', enums: _kPriorityEnum),
      );
      expect(out, contains('runBlocking { impl.fn() }'));
    });

    test('async enum interface uses suspend fun fn(): Priority (strong type)', () {
      final out = KotlinGenerator.generate(
        _asyncReturnSpec('Priority', enums: _kPriorityEnum),
      );
      // Interface uses the actual enum type, not Long
      expect(out, contains('suspend fun fn(): Priority'));
    });
  });

  // ── Section 4: _call void async ──────────────────────────────────────────────

  group('KotlinGenerator — async JniBridge _call return type: void', () {
    test('async void → fun fn_call(): Unit', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('void'));
      expect(out, contains('fun fn_call(): Unit'));
    });

    test('async void _call uses runBlocking without return statement', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('void'));
      expect(out, contains('runBlocking { impl.fn() }'));
    });

    test('async void _call uses _asyncExecutor.submit', () {
      final out = KotlinGenerator.generate(_asyncReturnSpec('void'));
      expect(out, contains('_asyncExecutor.submit'));
    });
  });
}
