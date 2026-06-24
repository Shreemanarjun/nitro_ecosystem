// Tests for the NitroNullable JNI bridge-param type encoding.
//
// NitroNullable: int?/double?/bool? params now use binary ByteArray encoding
// ([B JVM descriptor) instead of sentinel primitive values.
// Wire format: [1B hasValue][nB value] — zero sentinel collisions.
//
// This replaces the old sentinel approach:
//   OLD: int? → Long (J), sentinel Int64.min for null
//   NEW: int? → ByteArray ([B), NitroNullableInt binary
//
// Scenarios covered:
//   §1  nullable int?   param in sync  _call  → ByteArray (not Long)
//   §2  nullable bool?  param in sync  _call  → ByteArray (not Int/Boolean)
//   §3  nullable double? param in sync _call  → ByteArray (not Double)
//   §4  nullable params in async @nitroAsync _call
//   §5  nullable params in @NitroNativeAsync _call
//   §6  interface keeps Long? / Boolean? / Double? (correct for impl)
//   §7  non-nullable params are unchanged in _call
//   §8  nullable String? stays String? in _call (reference type – can be null)
//   §9  nullable struct stays T? in _call (reference type – can be null)
//   §10 isOptional flag (no type? suffix) also produces ByteArray in _call
//   §11 mixed params: some nullable, some not
//   §12 C++ JNI sig emits [B for int?/bool?/double? params

import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Spec builders ────────────────────────────────────────────────────────────

BridgeSpec _syncSpec({
  required List<BridgeParam> params,
  String returnType = 'bool',
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  sourceUri: 'mod.native.dart',
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

BridgeSpec _asyncSpec({required List<BridgeParam> params, String returnType = 'bool'}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: true,
      returnType: BridgeType(name: returnType),
      params: params,
    ),
  ],
);

BridgeSpec _nativeAsyncSpec({required List<BridgeParam> params}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fn',
      cSymbol: 'mod_fn',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'bool'),
      params: params,
    ),
  ],
);

// Common nullable params
final _nullableIntParam = BridgeParam(
  name: 'timeout',
  type: BridgeType(name: 'int?'),
  isNamed: true,
  isOptional: true,
);
final _nullableBoolParam = BridgeParam(
  name: 'flag',
  type: BridgeType(name: 'bool?'),
  isNamed: true,
  isOptional: true,
);
final _nullableDoubleParam = BridgeParam(
  name: 'scale',
  type: BridgeType(name: 'double?'),
  isNamed: true,
  isOptional: true,
);
final _nullableStringParam = BridgeParam(
  name: 'label',
  type: BridgeType(name: 'String?'),
  isNamed: true,
  isOptional: true,
);
final _nonNullIntParam = BridgeParam(
  name: 'count',
  type: BridgeType(name: 'int'),
);
final _nonNullBoolParam = BridgeParam(
  name: 'enabled',
  type: BridgeType(name: 'bool'),
);
final _nonNullStringParam = BridgeParam(
  name: 'id',
  type: BridgeType(name: 'String'),
);
final _isOptionalIntParam = BridgeParam(
  name: 'limit',
  type: BridgeType(name: 'int'),
  isNamed: true,
  isOptional: true,
);

// ── §1 nullable int? in sync _call ───────────────────────────────────────────

void main() {
  group('§1 nullable int? param — sync _call uses ByteArray (NitroNullable)', () {
    late String out;
    setUpAll(() => out = KotlinGenerator.generate(_syncSpec(params: [_nullableIntParam])));

    test('_call signature uses ByteArray (NitroNullable binary)', () {
      expect(out, contains('fun fn_call(timeout: ByteArray): Boolean'));
    });

    test('interface uses Long? (nullable for Kotlin impl)', () {
      expect(out, contains('fun fn(timeout: Long?): Boolean'));
    });

    test('_call body decodes NitroNullableInt before calling impl', () {
      expect(out, contains('val timeoutArg: Long? = NitroNullableInt.decode(timeout).nullable'));
      expect(out, contains('impl.fn(timeoutArg)'));
    });

    test('_call does NOT declare Long or Long? for timeout', () {
      // The _call line must have ByteArray — not Long/Long?
      final callLine = out.split('\n').where((l) => l.contains('fn_call')).first;
      expect(callLine, contains('ByteArray'));
      expect(callLine, isNot(contains('Long')));
    });
  });

  // ── §2 nullable bool? in sync _call ─────────────────────────────────────────

  group('§2 nullable bool? param — sync _call uses ByteArray (NitroNullable)', () {
    late String out;
    setUpAll(() => out = KotlinGenerator.generate(_syncSpec(params: [_nullableBoolParam])));

    test('_call signature uses ByteArray (NitroNullableBool binary)', () {
      expect(out, contains('fun fn_call(flag: ByteArray): Boolean'));
    });

    test('interface uses Boolean? (nullable for Kotlin impl)', () {
      expect(out, contains('fun fn(flag: Boolean?): Boolean'));
    });

    test('_call body decodes NitroNullableBool', () {
      expect(out, contains('NitroNullableBool.decode(flag).nullable'));
    });

    test('_call does NOT declare Boolean param for flag', () {
      final callLine = out.split('\n').where((l) => l.contains('fn_call')).first;
      expect(callLine, contains('ByteArray'));
      // Should not have Boolean as param type (only ByteArray for flag param)
      // Note: return type 'Boolean' is OK — we check the param only
      expect(callLine, isNot(contains('flag: Boolean')));
      expect(callLine, isNot(contains('flag: Boolean?')));
    });
  });

  // ── §3 nullable double? in sync _call ───────────────────────────────────────

  group('§3 nullable double? param — sync _call uses ByteArray (NitroNullable)', () {
    late String out;
    setUpAll(() => out = KotlinGenerator.generate(_syncSpec(params: [_nullableDoubleParam])));

    test('_call signature uses ByteArray (NitroNullableDouble binary)', () {
      expect(out, contains('fun fn_call(scale: ByteArray): Boolean'));
    });

    test('interface uses Double? (nullable for Kotlin impl)', () {
      expect(out, contains('fun fn(scale: Double?): Boolean'));
    });

    test('_call body decodes NitroNullableDouble', () {
      expect(out, contains('NitroNullableDouble.decode(scale).nullable'));
    });

    test('_call does NOT declare Double or Double? for scale', () {
      final callLine = out.split('\n').where((l) => l.contains('fn_call')).first;
      expect(callLine, contains('ByteArray'));
      expect(callLine, isNot(contains('Double')));
    });
  });

  // ── §4 nullable params in async @nitroAsync _call ───────────────────────────

  group('§4 nullable int? param — async _call uses ByteArray (NitroNullable)', () {
    late String out;
    setUpAll(() => out = KotlinGenerator.generate(_asyncSpec(params: [_nullableIntParam])));

    test('async _call signature uses ByteArray (NitroNullable)', () {
      expect(out, contains('fun fn_call(timeout: ByteArray): Boolean'));
    });

    test('async interface uses Long? (suspend fun)', () {
      expect(out, contains('suspend fun fn(timeout: Long?): Boolean'));
    });

    test('async _call uses runBlocking with NitroNullable decode', () {
      expect(out, contains('val timeoutArg: Long? = NitroNullableInt.decode(timeout).nullable'));
      expect(out, contains('runBlocking { impl.fn(timeoutArg) }'));
      expect(out, contains('_asyncExecutor.submit'));
    });
  });

  // ── §5 nullable params in @NitroNativeAsync _call ───────────────────────────

  group('§5 nullable int? param — @NitroNativeAsync _call uses Long (primitive)', () {
    late String out;
    setUpAll(
      () => out = KotlinGenerator.generate(
        _nativeAsyncSpec(
          params: [
            BridgeParam(
              name: 'printerId',
              type: BridgeType(name: 'String'),
            ),
            _nullableIntParam,
          ],
        ),
      ),
    );

    test('@NitroNativeAsync _call appends dartPort and uses ByteArray for int?', () {
      expect(out, contains('fun fn_call(printerId: String, timeout: ByteArray, dartPort: Long)'));
    });

    test('@NitroNativeAsync interface uses Long? for int? param', () {
      expect(out, contains('suspend fun fn(printerId: String, timeout: Long?): Boolean'));
    });

    test('@NitroNativeAsync _call body decodes NitroNullableInt before calling impl', () {
      expect(out, contains('val timeoutArg: Long? = NitroNullableInt.decode(timeout).nullable'));
      expect(out, contains('impl.fn(printerId, timeoutArg)'));
    });
  });

  // ── §6 interface integrity ───────────────────────────────────────────────────

  group('§6 interface always preserves nullable types for Kotlin impl', () {
    test('int? interface param is Long?', () {
      final out = KotlinGenerator.generate(_syncSpec(params: [_nullableIntParam]));
      expect(out, contains('fun fn(timeout: Long?): Boolean'));
    });

    test('bool? interface param is Boolean?', () {
      final out = KotlinGenerator.generate(_syncSpec(params: [_nullableBoolParam]));
      expect(out, contains('fun fn(flag: Boolean?): Boolean'));
    });

    test('double? interface param is Double?', () {
      final out = KotlinGenerator.generate(_syncSpec(params: [_nullableDoubleParam]));
      expect(out, contains('fun fn(scale: Double?): Boolean'));
    });
  });

  // ── §7 non-nullable params are unchanged ─────────────────────────────────────

  group('§7 non-nullable params are identical in interface and _call', () {
    late String out;
    setUpAll(
      () => out = KotlinGenerator.generate(
        _syncSpec(
          params: [
            _nonNullIntParam,
            _nonNullBoolParam,
            _nonNullStringParam,
          ],
        ),
      ),
    );

    test('non-null int param stays Long in _call', () {
      expect(out, contains('fun fn_call(count: Long, enabled: Boolean, id: String): Boolean'));
    });

    test('non-null int param stays Long in interface', () {
      expect(out, contains('fun fn(count: Long, enabled: Boolean, id: String): Boolean'));
    });
  });

  // ── §8 nullable String? stays String? in _call ──────────────────────────────

  group('§8 nullable String? param stays String? in _call (reference type)', () {
    late String out;
    setUpAll(() => out = KotlinGenerator.generate(_syncSpec(params: [_nullableStringParam])));

    test('_call keeps String? for nullable String (JNI can pass null objects)', () {
      expect(out, contains('fun fn_call(label: String?): Boolean'));
    });

    test('interface also uses String?', () {
      expect(out, contains('fun fn(label: String?): Boolean'));
    });
  });

  // ── §9 nullable struct stays T? in _call ────────────────────────────────────

  group('§9 nullable struct stays T? in _call (reference type)', () {
    final structSpec = _syncSpec(
      params: [
        BridgeParam(
          name: 'settings',
          type: BridgeType(name: 'Config?'),
          isNamed: true,
          isOptional: true,
        ),
      ],
      structs: [BridgeStruct(name: 'Config', packed: false, fields: [])],
    );

    test('_call keeps Config? for nullable struct param', () {
      final out = KotlinGenerator.generate(structSpec);
      expect(out, contains('fun fn_call(settings: Config?): Boolean'));
    });

    test('interface also uses Config?', () {
      final out = KotlinGenerator.generate(structSpec);
      expect(out, contains('fun fn(settings: Config?): Boolean'));
    });
  });

  // ── §10 isOptional flag (no ? suffix) also fixes the JVM descriptor ──────────

  group('§10 isOptional=true without ? suffix also produces primitive in _call', () {
    late String out;
    setUpAll(() => out = KotlinGenerator.generate(_syncSpec(params: [_isOptionalIntParam])));

    test('_call uses ByteArray (NitroNullable) when isOptional=true on int param', () {
      expect(out, contains('fun fn_call(limit: ByteArray): Boolean'));
    });

    test('interface uses Long? when isOptional=true on int param', () {
      expect(out, contains('fun fn(limit: Long?): Boolean'));
    });
  });

  // ── §11 mixed: some nullable, some not ──────────────────────────────────────

  group('§11 mixed nullable and non-nullable params', () {
    late String out;
    setUpAll(
      () => out = KotlinGenerator.generate(
        _syncSpec(
          params: [
            _nonNullStringParam, // positional non-null
            _nullableIntParam, // named optional int?
            _nullableStringParam, // named optional String?
          ],
        ),
      ),
    );

    test('_call uses correct types for each param', () {
      // id: String (non-null), timeout: ByteArray (NitroNullable for int?), label: String? (ref type)
      expect(out, contains('fun fn_call(id: String, timeout: ByteArray, label: String?): Boolean'));
    });

    test('interface uses correct nullable for each param', () {
      expect(out, contains('fun fn(id: String, timeout: Long?, label: String?): Boolean'));
    });
  });

  // ── §12 C++ JNI sig is still primitive (no regression) ──────────────────────

  group('§12 C++ JNI descriptor uses [B for int?/bool?/double? params (NitroNullable)', () {
    test('int? param → [B in GetStaticMethodID signature (NitroNullable ByteArray)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        androidImpl: NativeImpl.kotlin,
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'testConn',
            cSymbol: 'mod_test_conn',
            isAsync: true,
            returnType: BridgeType(name: 'bool'),
            params: [
              BridgeParam(
                name: 'printerId',
                type: BridgeType(name: 'String'),
              ),
              BridgeParam(
                name: 'timeout',
                type: BridgeType(name: 'int?'),
                isNamed: true,
                isOptional: true,
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      // Must contain [B (ByteArray) descriptor for int? param (NitroNullable)
      expect(out, contains('(Ljava/lang/String;[B)Z'));
      expect(out, isNot(contains('Ljava/lang/Long;')));
    });

    test('bool? param → [B in GetStaticMethodID signature (NitroNullable)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        androidImpl: NativeImpl.kotlin,
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'flag',
                type: BridgeType(name: 'bool?'),
                isNamed: true,
                isOptional: true,
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      // bool? uses [B (ByteArray) for NitroNullableBool
      expect(out, contains('([B)V'));
      expect(out, isNot(contains('Ljava/lang/Boolean;')));
    });

    test('double? param → [B in GetStaticMethodID signature (NitroNullable)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        androidImpl: NativeImpl.kotlin,
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'scale',
                type: BridgeType(name: 'double?'),
                isNamed: true,
                isOptional: true,
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      // double? uses [B (ByteArray) for NitroNullableDouble
      expect(out, contains('([B)V'));
      expect(out, isNot(contains('Ljava/lang/Double;')));
    });

    test('String? param stays Ljava/lang/String; (reference type, nullable OK)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        androidImpl: NativeImpl.kotlin,
        iosImpl: NativeImpl.swift,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'label',
                type: BridgeType(name: 'String?'),
                isNamed: true,
                isOptional: true,
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('(Ljava/lang/String;)V'));
    });
  });

  // ── §13 no regressions on iOS/macOS/Linux/Windows (Swift / C++ interface) ───

  group('§13 no regressions: iOS/macOS/Linux/Windows targets unaffected', () {
    test('iOS-only spec with int? param produces valid Swift output (no crash)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        // no androidImpl → Kotlin bridge skipped
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: true,
            returnType: BridgeType(name: 'bool'),
            params: [
              BridgeParam(
                name: 'timeout',
                type: BridgeType(name: 'int?'),
                isNamed: true,
                isOptional: true,
              ),
            ],
          ),
        ],
      );
      // Kotlin generator outputs a no-op comment when androidImpl is null
      final kotlinOut = KotlinGenerator.generate(spec);
      expect(kotlinOut, contains('Android not targeted'));
      // C++ bridge generator still runs for all platforms
      final cppOut = CppBridgeGenerator.generate(spec);
      expect(cppOut, isNotEmpty);
    });

    test('int? param: C++ bridge uses void* for NitroNullable buffer', () {
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
            isAsync: true,
            returnType: BridgeType(name: 'bool'),
            params: [
              BridgeParam(
                name: 'timeout',
                type: BridgeType(name: 'int?'),
                isNamed: true,
                isOptional: true,
              ),
            ],
          ),
        ],
      );
      final cppOut = CppBridgeGenerator.generate(spec);
      // C++ function signature uses void* (NitroNullable buffer pointer) for optional int?
      expect(cppOut, contains('void* timeout'));
      // C++ JNI descriptor uses [B (ByteArray) for NitroNullable
      expect(cppOut, contains('[B)'));
    });

    test('multiple nullable primitives in same spec generates correct bridge', () {
      final spec = _syncSpec(
        params: [
          _nullableIntParam,
          _nullableBoolParam,
          _nullableDoubleParam,
          _nullableStringParam,
        ],
      );
      final out = KotlinGenerator.generate(spec);
      // _call: all nullable primitives use ByteArray (NitroNullable), String? stays nullable
      expect(out, contains('fun fn_call(timeout: ByteArray, flag: ByteArray, scale: ByteArray, label: String?): Boolean'));
      // interface: all nullable
      expect(out, contains('fun fn(timeout: Long?, flag: Boolean?, scale: Double?, label: String?): Boolean'));
    });
  });
}
