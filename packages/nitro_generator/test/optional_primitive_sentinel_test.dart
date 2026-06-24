// Comprehensive tests ensuring ALL parameter type combinations generate
// correct code in both the Dart FFI generator and Kotlin generator.
//
// The optional-primitive sentinel pattern:
//   Dart callArgs  → sentinel value when null (int?→-1, double?→nan, bool?→-1)
//   Kotlin _call   → sentinel-to-null conversion before forwarding to interface
//
// Sentinels:
//   int?    → `?? Int64.min`              (Kotlin: == Long.MIN_VALUE → null)
//   double? → `?? double.nan`                (Kotlin: isNaN → null)
//   bool?   → `== null ? -1 : (v! ? 1 : 0)` (Kotlin: .toInt() < 0 → null)
//
// All other types (String, String?, struct, struct?, enum, bool, int, double)
// are handled correctly without sentinels.
//
// §1-§3  Dart: optional-primitive sentinels (table-driven per type)
// §4     Dart: non-optional primitives — no sentinel
// §5     Dart: String / String? — pointers, not sentinel
// §6     Dart: struct / struct? — pointer / null-guarded
// §7     Dart: enum — nativeValue
// §8     Dart: mixed params
// §9     Dart: @NitroNativeAsync — sentinels still applied
// §10    Kotlin: _call param types (JVM descriptors)
// §11    Kotlin: sentinel-to-null conversions in _call body
// §12    Kotlin: interface keeps nullable types
// §13    Kotlin: @NitroNativeAsync sentinel-to-null
// §14    Kotlin: mixed params — only optional-primitives unwrapped
// §15    Sentinel round-trip logic (pure Dart unit tests)
// §16    isOptional flag treated same as nullable type suffix

import 'package:test/test.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro/src/nitro_nullable.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/bridge_spec.dart';

// ─── Spec builders ────────────────────────────────────────────────────────────

BridgeSpec _syncSpec({
  required String funcName,
  required List<BridgeParam> params,
  String returnType = 'void',
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  functions: [
    BridgeFunction(
      dartName: funcName,
      cSymbol: 'mod_$funcName',
      isAsync: false,
      returnType: BridgeType(name: returnType),
      params: params,
    ),
  ],
);

BridgeSpec _asyncSpec({
  required String funcName,
  required List<BridgeParam> params,
  String returnType = 'void',
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  functions: [
    BridgeFunction(
      dartName: funcName,
      cSymbol: 'mod_$funcName',
      isAsync: true,
      returnType: BridgeType(name: returnType),
      params: params,
    ),
  ],
);

BridgeSpec _nativeAsyncSpec({
  required String funcName,
  required List<BridgeParam> params,
  String returnType = 'void',
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  androidImpl: NativeImpl.kotlin,
  iosImpl: NativeImpl.swift,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: funcName,
      cSymbol: 'mod_$funcName',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: returnType),
      params: params,
    ),
  ],
);

BridgeParam _p(
  String name,
  String type, {
  bool isNamed = false,
  bool isOptional = false,
  String? defaultLiteral,
}) => BridgeParam(
  name: name,
  type: BridgeType(name: type),
  isNamed: isNamed,
  isOptional: isOptional,
  defaultLiteral: defaultLiteral,
);

// ─── Bridge check helpers ─────────────────────────────────────────────────────

/// Returns the Dart FFI generator output for [spec].
String _dartFfi(BridgeSpec spec) => DartFfiGenerator.generate(spec);

/// Returns the Kotlin generator output for [spec].
String _kotlin(BridgeSpec spec) => KotlinGenerator.generate(spec);

/// Asserts that the Dart FFI output for [spec] contains every string in [has]
/// and none of the strings in [hasNot].
void _checkDartFfi(
  BridgeSpec spec, {
  List<String> has = const [],
  List<String> hasNot = const [],
}) {
  final out = _dartFfi(spec);
  for (final s in has) {
    expect(out, contains(s));
  }
  for (final s in hasNot) {
    expect(out, isNot(contains(s)));
  }
}

/// Asserts that the Kotlin output for [spec] contains every string in [has]
/// and none of the strings in [hasNot].
void _checkKotlin(
  BridgeSpec spec, {
  List<String> has = const [],
  List<String> hasNot = const [],
}) {
  final out = _kotlin(spec);
  for (final s in has) {
    expect(out, contains(s));
  }
  for (final s in hasNot) {
    expect(out, isNot(contains(s)));
  }
}

// ─── Optional-primitive test data ────────────────────────────────────────────
//
// One record per nullable-primitive type. Each entry drives §1-§3 (Dart
// sentinels), §9 (NativeAsync Dart), and §10-§12 (Kotlin _call / interface).

const _optPrimCases = [
  (
    type: 'int?',
    param: 'timeout',
    dartSentinel: 'NitroNullableInt.fromNullable(timeout).toNative(arena)',
    kotlinCallType: 'ByteArray',
    kotlinConversion: 'val timeoutArg: Long? = NitroNullableInt.decode(timeout).nullable',
    kotlinInterfaceType: 'Long?',
  ),
  (
    type: 'double?',
    param: 'scale',
    dartSentinel: 'NitroNullableDouble.fromNullable(scale).toNative(arena)',
    kotlinCallType: 'ByteArray',
    kotlinConversion: 'val scaleArg: Double? = NitroNullableDouble.decode(scale).nullable',
    kotlinInterfaceType: 'Double?',
  ),
  (
    type: 'bool?',
    param: 'enabled',
    dartSentinel: 'NitroNullableBool.fromNullable(enabled).toNative(arena)',
    kotlinCallType: 'ByteArray',
    kotlinConversion: 'val enabledArg: Boolean? = NitroNullableBool.decode(enabled).nullable',
    kotlinInterfaceType: 'Boolean?',
  ),
];

// ─── §15 NitroNullable round-trip helpers ──────────────────────────────────────
// These test the NitroNullable encoding/decoding round-trip.
// NitroNullable uses binary format: [1B hasValue][nB value]

// Test that fromNullable preserves all values including sentinels
NitroNullableInt _encodeNullableInt(int? v) => NitroNullableInt.fromNullable(v);
NitroNullableDouble _encodeNullableDouble(double? v) => NitroNullableDouble.fromNullable(v);
NitroNullableBool _encodeNullableBool(bool? v) => NitroNullableBool.fromNullable(v);

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // §1-§3  Dart FFI: optional-primitive sentinels
  // ══════════════════════════════════════════════════════════════════════════
  group('§1-§3 Dart FFI — optional-primitive sentinels', () {
    for (final c in _optPrimCases) {
      test('async ${c.type} → uses NitroNullable (${c.dartSentinel})', () {
        _checkDartFfi(
          _asyncSpec(funcName: 'fn', params: [_p(c.param, c.type)]),
          has: [c.dartSentinel],
        );
      });
      test('sync ${c.type} → uses NitroNullable (${c.dartSentinel})', () {
        _checkDartFfi(
          _syncSpec(funcName: 'fn', params: [_p(c.param, c.type)]),
          has: [c.dartSentinel],
        );
      });
    }

    // Extra int? edge cases
    test('named int? uses NitroNullableInt.fromNullable(limit).toNative(arena)', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'fn', params: [_p('limit', 'int?', isNamed: true)]),
        has: ['NitroNullableInt.fromNullable(limit).toNative(arena)'],
      );
    });
    test('multiple int? params each get NitroNullable encoding', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'fn', params: [_p('a', 'int?'), _p('b', 'int?')]),
        has: [
          'NitroNullableInt.fromNullable(a).toNative(arena)',
          'NitroNullableInt.fromNullable(b).toNative(arena)',
        ],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §4  Dart FFI: non-optional primitives — NO sentinel
  // ══════════════════════════════════════════════════════════════════════════
  group('§4 Dart FFI — non-optional primitives: no sentinel', () {
    test('int passes as-is', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'fn', params: [_p('count', 'int')]),
        has: ['count'],
        hasNot: ['count ?? '],
      );
    });

    test('double passes as-is', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'fn', params: [_p('scale', 'double')]),
        hasNot: ['scale ?? '],
      );
    });

    test('bool uses ? 1 : 0, not sentinel', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'fn', params: [_p('flag', 'bool')]),
        has: ['flag ? 1 : 0'],
        hasNot: ['flag == null'],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §5  Dart FFI: String / String?
  // ══════════════════════════════════════════════════════════════════════════
  group('§5 Dart FFI — String / String?', () {
    test('String uses toNativeUtf8', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'send', params: [_p('msg', 'String')]),
        has: ['msg.toNativeUtf8'],
        hasNot: ['msg ?? '],
      );
    });

    test('String? uses null-guarded toNativeUtf8', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'send', params: [_p('msg', 'String?')]),
        has: ['msg != null', 'toNativeUtf8', 'nullptr'],
        hasNot: ['msg ?? -9223372036854775808'],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §6  Dart FFI: struct / struct? — pointer encoding
  // ══════════════════════════════════════════════════════════════════════════
  group('§6 Dart FFI — struct / struct?', () {
    final structSpec = BridgeStruct(name: 'Config', packed: false, fields: []);

    test('struct uses .toNative(arena).cast<Void>()', () {
      _checkDartFfi(
        _asyncSpec(
          funcName: 'configure',
          params: [_p('cfg', 'Config')],
          structs: [structSpec],
        ),
        has: ['cfg.toNative(arena).cast<Void>()'],
      );
    });

    test('struct? uses null-guarded .toNative() with nullptr fallback', () {
      _checkDartFfi(
        _asyncSpec(
          funcName: 'configure',
          params: [_p('cfg', 'Config?')],
          structs: [structSpec],
        ),
        has: ['cfg != null', 'toNative', 'nullptr'],
        hasNot: ['cfg ?? -9223372036854775808'],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §7  Dart FFI: enum — nativeValue
  // ══════════════════════════════════════════════════════════════════════════
  group('§7 Dart FFI — enum param', () {
    final enumSpec = BridgeEnum(
      name: 'Color',
      startValue: 0,
      values: ['red', 'green', 'blue'],
    );

    test('enum uses .nativeValue, not sentinel', () {
      _checkDartFfi(
        _asyncSpec(
          funcName: 'paint',
          params: [_p('color', 'Color')],
          enums: [enumSpec],
        ),
        has: ['color.nativeValue'],
        hasNot: ['color ?? '],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §8  Dart FFI: mixed params in one function
  // ══════════════════════════════════════════════════════════════════════════
  group('§8 Dart FFI — mixed params', () {
    test('all types encoded correctly together', () {
      _checkDartFfi(
        _asyncSpec(
          funcName: 'doAll',
          params: [
            _p('id', 'String'),
            _p('timeout', 'int?'),
            _p('scale', 'double?'),
            _p('verbose', 'bool?'),
            _p('enabled', 'bool'),
            _p('count', 'int'),
          ],
        ),
        has: [
          'id.toNativeUtf8',
          'NitroNullableInt.fromNullable(timeout).toNative(arena)',
          'NitroNullableDouble.fromNullable(scale).toNative(arena)',
          'NitroNullableBool.fromNullable(verbose).toNative(arena)',
          'enabled ? 1 : 0',
          'count',
        ],
        hasNot: ['count ?? ', 'enabled ?? '],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §9  Dart FFI: @NitroNativeAsync — sentinels applied in callArgs
  // ══════════════════════════════════════════════════════════════════════════
  group('§9 Dart FFI — @NitroNativeAsync optional primitives', () {
    for (final c in _optPrimCases) {
      test('NativeAsync ${c.type} → ${c.dartSentinel}', () {
        _checkDartFfi(
          _nativeAsyncSpec(funcName: 'asyncFn', params: [_p(c.param, c.type)]),
          has: [c.dartSentinel],
        );
      });
    }
  });
  // NOTE: NativeAsync uses Dart_PostCObject_DL on native side which posts primitives directly.
  // The NitroNullable encoding only applies to the FFI call bridge (not NativeAsync result posting).

  // ══════════════════════════════════════════════════════════════════════════
  // §10  Kotlin: _call bridge param types (JVM descriptors)
  // ══════════════════════════════════════════════════════════════════════════
  group('§10 Kotlin — _call JVM descriptor param types', () {
    // Optional primitives → primitive (non-nullable) JVM type in _call
    for (final c in _optPrimCases) {
      test('${c.type} → ${c.kotlinCallType} in _call', () {
        _checkKotlin(
          _asyncSpec(funcName: 'fn', params: [_p(c.param, c.type)]),
          has: ['fn_call(${c.param}: ${c.kotlinCallType})'],
        );
      });
    }

    // Reference type: nullable in _call
    test('String? stays String? in _call', () {
      _checkKotlin(
        _asyncSpec(funcName: 'send', params: [_p('msg', 'String?')]),
        has: ['send_call(msg: String?)'],
      );
    });

    // Non-optional primitives: non-nullable in _call
    for (final (type, param, jvmType) in [
      ('int', 'count', 'Long'),
      ('bool', 'flag', 'Boolean'),
      ('double', 'ratio', 'Double'),
    ]) {
      test('non-optional $type stays $jvmType in _call', () {
        _checkKotlin(
          _asyncSpec(funcName: 'fn', params: [_p(param, type)]),
          has: ['fn_call($param: $jvmType)'],
        );
      });
    }
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §11  Kotlin: sentinel-to-null conversions in _call body
  // ══════════════════════════════════════════════════════════════════════════
  group('§11 Kotlin — _call body sentinel-to-null conversions', () {
    // Optional primitives → Arg local with sentinel check, forwarded to impl
    for (final c in _optPrimCases) {
      test('${c.type} emits NitroNullable decode Arg local + impl call', () {
        _checkKotlin(
          _asyncSpec(funcName: 'fn', params: [_p(c.param, c.type)]),
          has: [c.kotlinConversion, 'impl.fn(${c.param}Arg)'],
        );
      });
    }

    // Non-optional/reference types: no Arg locals emitted
    for (final (type, param) in [('int', 'count'), ('bool', 'flag'), ('String?', 'msg')]) {
      test('$type ($param): no ${param}Arg local', () {
        _checkKotlin(
          _asyncSpec(funcName: 'fn', params: [_p(param, type)]),
          hasNot: ['${param}Arg'],
        );
      });
    }

    // Sync variant applies same sentinel pattern
    test('sync int? emits NitroNullableInt decode', () {
      _checkKotlin(
        _syncSpec(funcName: 'fn', params: [_p('timeout', 'int?')]),
        has: ['val timeoutArg: Long? = NitroNullableInt.decode(timeout).nullable'],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §12  Kotlin interface: keeps nullable types
  // ══════════════════════════════════════════════════════════════════════════
  group('§12 Kotlin — interface keeps nullable types', () {
    for (final c in _optPrimCases) {
      test('${c.type} in interface is ${c.kotlinInterfaceType}', () {
        _checkKotlin(
          _asyncSpec(funcName: 'fn', params: [_p(c.param, c.type)]),
          has: ['fun fn(${c.param}: ${c.kotlinInterfaceType})'],
        );
      });
    }
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §13  Kotlin @NitroNativeAsync — sentinel-to-null before execute block
  // ══════════════════════════════════════════════════════════════════════════
  group('§13 Kotlin — @NitroNativeAsync sentinel-to-null', () {
    test('NativeAsync int? emits NitroNullableInt decode before _asyncExecutor.execute', () {
      final out = _kotlin(
        _nativeAsyncSpec(
          funcName: 'fetchAsync',
          params: [_p('timeout', 'int?')],
          returnType: 'int',
        ),
      );
      final decodeIdx = out.indexOf('val timeoutArg: Long? = NitroNullableInt.decode(timeout).nullable');
      final executeIdx = out.indexOf('_asyncExecutor.execute');
      expect(decodeIdx, greaterThan(-1), reason: 'NitroNullable decode must be emitted');
      expect(decodeIdx, lessThan(executeIdx), reason: 'decode must be computed before the execute block');
      expect(out, contains('impl.fetchAsync(timeoutArg)'));
    });

    test('NativeAsync double? emits NitroNullableDouble decode', () {
      _checkKotlin(
        _nativeAsyncSpec(
          funcName: 'computeAsync',
          params: [_p('factor', 'double?')],
          returnType: 'double',
        ),
        has: [
          'val factorArg: Double? = NitroNullableDouble.decode(factor).nullable',
          'impl.computeAsync(factorArg)',
        ],
      );
    });

    test('NativeAsync bool? emits NitroNullableBool decode', () {
      _checkKotlin(
        _nativeAsyncSpec(
          funcName: 'toggleAsync',
          params: [_p('flag', 'bool?')],
          returnType: 'bool',
        ),
        has: [
          'val flagArg: Boolean? = NitroNullableBool.decode(flag).nullable',
          'impl.toggleAsync(flagArg)',
        ],
      );
    });

    test('NativeAsync without optional primitives: no sentinel emitted', () {
      _checkKotlin(
        _nativeAsyncSpec(
          funcName: 'pureAsync',
          params: [_p('name', 'String'), _p('count', 'int')],
        ),
        hasNot: ['Arg: Long?', 'Arg: Double?', 'Arg: Boolean?'],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §14  Kotlin mixed params — only optional-primitives get unwrapped
  // ══════════════════════════════════════════════════════════════════════════
  group('§14 Kotlin — mixed params: selective unwrapping', () {
    test('only int?, bool?, double? get Arg locals; others pass raw', () {
      _checkKotlin(
        _asyncSpec(
          funcName: 'doAll',
          params: [
            _p('id', 'String'),
            _p('timeout', 'int?'),
            _p('scale', 'double?'),
            _p('verbose', 'bool?'),
            _p('flag', 'bool'),
            _p('count', 'int'),
          ],
        ),
        has: [
          'val timeoutArg: Long? = NitroNullableInt.decode(timeout).nullable',
          'val scaleArg: Double? = NitroNullableDouble.decode(scale).nullable',
          'val verboseArg: Boolean? = NitroNullableBool.decode(verbose).nullable',
          'impl.doAll(id, timeoutArg, scaleArg, verboseArg, flag, count)',
        ],
        hasNot: ['flagArg', 'countArg', 'idArg'],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §15  Sentinel round-trip logic (pure Dart unit tests)
  // ══════════════════════════════════════════════════════════════════════════
  group('§15 NitroNullable round-trip — Dart class tests', () {
    // NitroNullable encoding preserves all values including Int64.min
    test('int? null → NitroNullableInt with hasValue=false', () => expect(_encodeNullableInt(null).hasValue, isFalse));
    test('int? 30 → NitroNullableInt with value=30', () => expect(_encodeNullableInt(30).nullable, equals(30)));
    test('int? 0 → NitroNullableInt with value=0 (zero is valid)', () => expect(_encodeNullableInt(0).nullable, equals(0)));
    test('int? Int64.min → representable (no collision!)', () => expect(_encodeNullableInt(-9223372036854775808).nullable, equals(-9223372036854775808)));
    test('int? -1 → representable (no collision!)', () => expect(_encodeNullableInt(-1).nullable, equals(-1)));

    test('double? null → NitroNullableDouble with hasValue=false', () => expect(_encodeNullableDouble(null).hasValue, isFalse));
    test('double? 3.14 → NitroNullableDouble with value=3.14', () => expect(_encodeNullableDouble(3.14).nullable, equals(3.14)));
    test('double? 0.0 → NitroNullableDouble with value=0.0', () => expect(_encodeNullableDouble(0.0).nullable, equals(0.0)));
    test('double? NaN → representable (no collision!)', () => expect(_encodeNullableDouble(double.nan).nullable!.isNaN, isTrue));

    test('bool? null → NitroNullableBool with hasValue=false', () => expect(_encodeNullableBool(null).hasValue, isFalse));
    test('bool? true → NitroNullableBool with value=true', () => expect(_encodeNullableBool(true).nullable, isTrue));
    test('bool? false → NitroNullableBool with value=false', () => expect(_encodeNullableBool(false).nullable, isFalse));
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §16  isOptional flag — same treatment as nullable type suffix
  // ══════════════════════════════════════════════════════════════════════════
  group('§16 isOptional flag — treated same as nullable suffix', () {
    test('Dart: isOptional int? → NitroNullableInt encoding', () {
      _checkDartFfi(
        _asyncSpec(
          funcName: 'retry',
          params: [
            _p('retries', 'int?', isNamed: true, isOptional: true, defaultLiteral: '3'),
          ],
        ),
        has: ['NitroNullableInt.fromNullable(retries).toNative(arena)'],
      );
    });

    test('Kotlin: isOptional int? → NitroNullableInt decode', () {
      _checkKotlin(
        _asyncSpec(
          funcName: 'retry',
          params: [
            _p('retries', 'int?', isNamed: true, isOptional: true, defaultLiteral: '3'),
          ],
        ),
        has: ['val retriesArg: Long? = NitroNullableInt.decode(retries).nullable'],
      );
    });

    test('Dart: isOptional double? → NitroNullableDouble encoding', () {
      _checkDartFfi(
        _asyncSpec(
          funcName: 'check',
          params: [
            _p('threshold', 'double?', isNamed: true, isOptional: true),
          ],
        ),
        has: ['NitroNullableDouble.fromNullable(threshold).toNative(arena)'],
      );
    });

    test('Kotlin: isOptional double? → NitroNullableDouble decode', () {
      _checkKotlin(
        _asyncSpec(
          funcName: 'check',
          params: [
            _p('threshold', 'double?', isNamed: true, isOptional: true),
          ],
        ),
        has: ['val thresholdArg: Double? = NitroNullableDouble.decode(threshold).nullable'],
      );
    });
  });
}
