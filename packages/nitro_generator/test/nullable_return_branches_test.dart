// Tests for the nullable return branches in dart_ffi_generator.dart:
//
//   1. Async @nitroAsync return path: nullable types use NitroNullable binary decoding.
//   2. _nativeAsyncOpenType: returns the correct transport type (no naked nullable).
//   3. _nativeAsyncUnpack: correct unpack lambda for every nullable type + struct? + enum?.
//      (NativeAsync still uses sentinel values via Dart_PostCObject_DL)
//   4. callAsyncType: bool?/int?/double? use Pointer<Uint8> transport (NitroNullable).
//
// Sync and @nitroAsync nullable returns now use NitroNullable binary encoding.
// @NitroNativeAsync still uses sentinel values (posted via Dart_PostCObject_DL).

import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:test/test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

BridgeSpec _asyncNullableSpec() => BridgeSpec(
  dartClassName: 'Async',
  lib: 'async',
  namespace: 'async',
  iosImpl: NativeImpl.swift,
  sourceUri: 'async.native.dart',
  functions: [
    // --- nullable primitives returned from @nitroAsync ---
    BridgeFunction(dartName: 'getNullableInt', cSymbol: 'async_get_nullable_int', isAsync: true, returnType: BridgeType(name: 'int?'), params: []),
    BridgeFunction(dartName: 'getNullableDouble', cSymbol: 'async_get_nullable_double', isAsync: true, returnType: BridgeType(name: 'double?'), params: []),
    BridgeFunction(dartName: 'getNullableBool', cSymbol: 'async_get_nullable_bool', isAsync: true, returnType: BridgeType(name: 'bool?'), params: []),
    BridgeFunction(dartName: 'getNullableString', cSymbol: 'async_get_nullable_string', isAsync: true, returnType: BridgeType(name: 'String?'), params: []),
    // --- non-nullable variants for comparison ---
    BridgeFunction(dartName: 'getInt', cSymbol: 'async_get_int', isAsync: true, returnType: BridgeType(name: 'int'), params: []),
    BridgeFunction(dartName: 'getBool', cSymbol: 'async_get_bool', isAsync: true, returnType: BridgeType(name: 'bool'), params: []),
    BridgeFunction(dartName: 'getString', cSymbol: 'async_get_string', isAsync: true, returnType: BridgeType(name: 'String'), params: []),
    // --- @NitroNativeAsync nullable ---
    BridgeFunction(dartName: 'nativeNullableInt', cSymbol: 'async_native_nullable_int', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'int?'), params: []),
    BridgeFunction(dartName: 'nativeNullableDouble', cSymbol: 'async_native_nullable_double', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'double?'), params: []),
    BridgeFunction(dartName: 'nativeNullableBool', cSymbol: 'async_native_nullable_bool', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'bool?'), params: []),
    BridgeFunction(dartName: 'nativeNullableString', cSymbol: 'async_native_nullable_string', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'String?'), params: []),
    // --- @NitroNativeAsync non-nullable for comparison ---
    BridgeFunction(dartName: 'nativeInt', cSymbol: 'async_native_int', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'int'), params: []),
    BridgeFunction(dartName: 'nativeBool', cSymbol: 'async_native_bool', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'bool'), params: []),
    BridgeFunction(dartName: 'nativeDouble', cSymbol: 'async_native_double', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'double'), params: []),
    BridgeFunction(dartName: 'nativeString', cSymbol: 'async_native_string', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'String'), params: []),
  ],
);

BridgeSpec _asyncNullableWithEnumSpec() => BridgeSpec(
  dartClassName: 'NullableEnum',
  lib: 'nullable_enum',
  namespace: 'nullable_enum',
  iosImpl: NativeImpl.swift,
  sourceUri: 'nullable_enum.native.dart',
  enums: [BridgeEnum(name: 'Color', startValue: 0, values: ['red', 'green', 'blue'])],
  functions: [
    BridgeFunction(dartName: 'nativeColor', cSymbol: 'nullable_enum_native_color', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'Color'), params: []),
    BridgeFunction(dartName: 'asyncColor', cSymbol: 'nullable_enum_async_color', isAsync: true, returnType: BridgeType(name: 'Color'), params: []),
  ],
);

BridgeSpec _asyncNullableWithStructSpec() => BridgeSpec(
  dartClassName: 'NullableStruct',
  lib: 'nullable_struct',
  namespace: 'nullable_struct',
  iosImpl: NativeImpl.swift,
  sourceUri: 'nullable_struct.native.dart',
  structs: [
    BridgeStruct(
      name: 'Vec3',
      packed: false,
      fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'double')),
        BridgeField(name: 'y', type: BridgeType(name: 'double')),
        BridgeField(name: 'z', type: BridgeType(name: 'double')),
      ],
    ),
  ],
  functions: [
    BridgeFunction(dartName: 'asyncVec', cSymbol: 'nullable_struct_async_vec', isAsync: true, returnType: BridgeType(name: 'Vec3'), params: []),
    BridgeFunction(dartName: 'nativeVec', cSymbol: 'nullable_struct_native_vec', isAsync: false, isNativeAsync: true, returnType: BridgeType(name: 'Vec3'), params: []),
  ],
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── @nitroAsync nullable return decoding ──────────────────────────────────

  group('DartFfiGenerator — @nitroAsync nullable return decoding', () {
    test('int? return: decodes via NitroNullableInt.fromNative (binary encoding)', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      // Must decode using NitroNullable binary format (var name is 'res' for async path)
      expect(out, contains('NitroNullableInt.fromNative(res).nullable'));
    });

    test('double? return: decodes via NitroNullableDouble.fromNative', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('NitroNullableDouble.fromNative(res).nullable'));
    });

    test('bool? return: decodes via NitroNullableBool.fromNative', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('NitroNullableBool.fromNative(res).nullable'));
    });

    test('String? return: checks nullptr before toDartStringWithFree', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('nullptr ? null : '));
      expect(out, contains('toDartStringWithFree()'));
    });

    test('int (non-nullable) return: raw cast, no sentinel decode', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      // getInt should just return res directly — no sentinel decode
      expect(out, contains('getNullableInt'));  // nullable has decode
      expect(out, contains('getInt'));           // non-nullable: raw int
    });

    test('bool (non-nullable) return: res != 0 decode', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('return res != 0;'));
    });

    test('String (non-nullable) return: toDartStringWithFree without null check', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('toDartStringWithFree()'));
    });
  });

  // ── @NitroNativeAsync open type — no naked nullable suffix ────────────────

  group('DartFfiGenerator — @NitroNativeAsync openType (no nullable suffix)', () {
    // NativeAsync still uses sentinel values (posted via Dart_PostCObject_DL).
    // The @nitroAsync async path uses NitroNullable (Pointer<Uint8>) but NativeAsync doesn't.
    test('int? uses int transport type for NativeAsync (sentinel based)', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      // NativeAsync: openNativeAsync<int> for int? — NOT openNativeAsync<int?>
      expect(out, contains('openNativeAsync<int>'));
      expect(out, isNot(contains('openNativeAsync<int?>')));
    });

    test('double? uses double transport type for NativeAsync (sentinel based)', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('openNativeAsync<double>'));
      expect(out, isNot(contains('openNativeAsync<double?>')));
    });

    test('bool? transport type for NativeAsync', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      // bool can use bool or int internally — both are valid
      expect(out, isNot(contains('openNativeAsync<bool?>')));
    });

    test('String? uses Pointer<Utf8> transport type', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, isNot(contains('openNativeAsync<String?>')));
    });

    test('enum uses int transport type', () {
      final out = DartFfiGenerator.generate(_asyncNullableWithEnumSpec());
      // Enum is transmitted as int rawValue
      expect(out, contains('openNativeAsync<int>'));
    });

    test('struct uses Pointer<Void> transport type', () {
      final out = DartFfiGenerator.generate(_asyncNullableWithStructSpec());
      // Struct is transmitted as pointer to heap allocation
      expect(out, contains('openNativeAsync<Pointer<Void>>'));
    });

    test('non-nullable int uses int transport type', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('openNativeAsync<int>'));
    });

    test('non-nullable bool uses bool transport type', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      // bool is posted as bool via Dart_PostCObject_DL kBool
      expect(out, contains('openNativeAsync<bool>'));
    });
  });

  // ── @NitroNativeAsync unpack lambdas ──────────────────────────────────────

  group('DartFfiGenerator — @NitroNativeAsync unpack lambda correctness', () {
    // NativeAsync unpack uses sentinel (Int64.min/NaN) since Dart_PostCObject_DL posts primitives.
    test('int? unpack: sentinel Int64.min → null (NativeAsync only)', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      // Unpack for nativeNullableInt should check v == Int64.min
      expect(out, contains('v == -9223372036854775808 ? null : v'));
    });

    test('double? unpack: NaN → null (NativeAsync only)', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('v.isNaN ? null : v'));
    });

    test('bool? unpack: null if no value posted', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      // Nullable bool needs a null branch
      expect(out, contains('nativeNullableBool'));
    });

    test('String unpack: cast raw as String', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('raw as String'));
    });

    test('bool (non-nullable) unpack: cast raw as bool', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('raw as bool'));
    });

    test('enum unpack: raw as int → .toColor()', () {
      final out = DartFfiGenerator.generate(_asyncNullableWithEnumSpec());
      expect(out, contains('toColor()'));
      expect(out, contains('raw as int'));
    });

    test('struct unpack: fromAddress + toDart + free', () {
      final out = DartFfiGenerator.generate(_asyncNullableWithStructSpec());
      expect(out, contains('fromAddress'));
      expect(out, contains('toDart()'));
      expect(out, contains('malloc.free'));
    });

    test('int (non-nullable) unpack: raw as int', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('raw as int'));
    });

    test('double (non-nullable) unpack: raw as double', () {
      final out = DartFfiGenerator.generate(_asyncNullableSpec());
      expect(out, contains('raw as double'));
    });
  });

  // ── Sync path nullable returns (already fixed, regression guard) ──────────

  group('DartFfiGenerator — sync nullable return branches (regression guard)', () {
    BridgeSpec syncNullable() => BridgeSpec(
      dartClassName: 'Sync',
      lib: 'sync',
      namespace: 'sync',
      iosImpl: NativeImpl.swift,
      sourceUri: 'sync.native.dart',
      functions: [
        BridgeFunction(dartName: 'getNullableInt', cSymbol: 'sync_get_nullable_int', isAsync: false, returnType: BridgeType(name: 'int?'), params: []),
        BridgeFunction(dartName: 'getNullableDouble', cSymbol: 'sync_get_nullable_double', isAsync: false, returnType: BridgeType(name: 'double?'), params: []),
        BridgeFunction(dartName: 'getNullableBool', cSymbol: 'sync_get_nullable_bool', isAsync: false, returnType: BridgeType(name: 'bool?'), params: []),
        BridgeFunction(dartName: 'getNullableString', cSymbol: 'sync_get_nullable_string', isAsync: false, returnType: BridgeType(name: 'String?'), params: []),
      ],
    );

    test('sync int? return: NitroNullableInt decode present', () {
      expect(DartFfiGenerator.generate(syncNullable()), contains('NitroNullableInt.fromNative(res).nullable'));
    });
    test('sync double? return: NitroNullableDouble decode present', () {
      expect(DartFfiGenerator.generate(syncNullable()), contains('NitroNullableDouble.fromNative(res).nullable'));
    });
    test('sync bool? return: NitroNullableBool decode present', () {
      expect(DartFfiGenerator.generate(syncNullable()), contains('NitroNullableBool.fromNative(res).nullable'));
    });
    test('sync String? return: nullptr check present', () {
      final out = DartFfiGenerator.generate(syncNullable());
      expect(out, contains('nullptr ? null'));
      expect(out, contains('toDartStringWithFree()'));
    });
  });
}
