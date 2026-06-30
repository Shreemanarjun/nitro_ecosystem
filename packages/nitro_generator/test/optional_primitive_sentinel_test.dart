// Comprehensive tests ensuring ALL parameter type combinations generate
// correct code in both the Dart FFI generator and Kotlin generator.
//
// The optional-primitive NitroOptional<T> pattern (zero-cost packed transport):
//   Dart callArgs  → arena.packOptionalInt/Double/Bool(v) — Pointer<Uint8> packed
//   Dart decode    → NitroOptional.decodeInt/Double/Bool(res).nullable
//   Kotlin _call   → NitroOptInt64/Float64/Bool.decode(bytes).nullable (inline class)
//   C bridge       → const NitroOptXxx* typed pointer (no length prefix)
//   Swift bridge   → UnsafeMutablePointer<NitroOptXxx>? with .pointee access
//
// Wire format: [1B hasValue][N bytes value] — NO RecordWriter 4-byte prefix.
// Sizes: NitroOptional<int>=9B, NitroOptional<double>=9B, NitroOptional<bool>=2B
//
// §1-§3  Dart: NitroOptional<T> packed encoding (table-driven per type)
// §4     Dart: non-optional primitives — no NitroOpt*
// §5     Dart: String / String? — pointers, not NitroOpt*
// §6     Dart: struct / struct? — pointer / null-guarded
// §7     Dart: enum — nativeValue
// §8     Dart: mixed params
// §9     Dart: @NitroNativeAsync — NitroOpt* still applied
// §10    Kotlin: _call param types (JVM descriptors)
// §11    Kotlin: NitroOpt* decode in _call body
// §12    Kotlin: interface keeps nullable types
// §13    Kotlin: @NitroNativeAsync NitroOpt* decode
// §14    Kotlin: mixed params — only optional-primitives unwrapped
// §15    NitroOpt* round-trip logic (pure Dart unit tests)
// §16    isOptional flag treated same as nullable type suffix

import 'package:test/test.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
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
    dartSentinel: 'arena.packInt(timeout)',
    kotlinCallType: 'ByteArray',
    kotlinConversion: 'val timeoutArg: Long? = NitroOptInt64.decode(timeout).nullable',
    kotlinInterfaceType: 'Long?',
  ),
  (
    type: 'double?',
    param: 'scale',
    dartSentinel: 'arena.packDouble(scale)',
    kotlinCallType: 'ByteArray',
    kotlinConversion: 'val scaleArg: Double? = NitroOptFloat64.decode(scale).nullable',
    kotlinInterfaceType: 'Double?',
  ),
  (
    type: 'bool?',
    param: 'enabled',
    dartSentinel: 'arena.packBool(enabled)',
    kotlinCallType: 'ByteArray',
    kotlinConversion: 'val enabledArg: Boolean? = NitroOptBool.decode(enabled).nullable',
    kotlinInterfaceType: 'Boolean?',
  ),
];

// ─── §15 NitroOptional<T> round-trip helpers ──────────────────────────────────
// Wire format: [1B hasValue][N bytes value] — no length prefix.
// NitroOptional<T> encodes via NitroOptionalAllocator; decoded via static methods.

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // §1-§3  Dart FFI: optional-primitive sentinels
  // ══════════════════════════════════════════════════════════════════════════
  group('§1-§3 Dart FFI — optional-primitive sentinels', () {
    for (final c in _optPrimCases) {
      test('async ${c.type} → uses NitroOptional<T> packed encoding (${c.dartSentinel})', () {
        _checkDartFfi(
          _asyncSpec(funcName: 'fn', params: [_p(c.param, c.type)]),
          has: [c.dartSentinel],
        );
      });
      test('sync ${c.type} → uses NitroOptional<T> packed encoding (${c.dartSentinel})', () {
        _checkDartFfi(
          _syncSpec(funcName: 'fn', params: [_p(c.param, c.type)]),
          has: [c.dartSentinel],
        );
      });
    }

    // Extra int? edge cases
    test('named int? uses arena.packInt(limit)', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'fn', params: [_p('limit', 'int?', isNamed: true)]),
        has: ['arena.packInt(limit)'],
      );
    });
    test('multiple int? params each get NitroOptional<int> encoding', () {
      _checkDartFfi(
        _asyncSpec(funcName: 'fn', params: [_p('a', 'int?'), _p('b', 'int?')]),
        has: [
          'arena.packInt(a)',
          'arena.packInt(b)',
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
          'arena.packInt(timeout)',
          'arena.packDouble(scale)',
          'arena.packBool(verbose)',
          'enabled ? 1 : 0',
          'count',
        ],
        hasNot: ['count ?? ', 'enabled ?? '],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §9  Dart FFI: @NitroNativeAsync — NitroOptional<T> encoding applied in callArgs
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
  // The NitroOptional<T> packed encoding only applies to the FFI call bridge (not NativeAsync result posting).

  // ══════════════════════════════════════════════════════════════════════════
  // §10  Kotlin: _call bridge param types (JVM descriptors)
  // ══════════════════════════════════════════════════════════════════════════
  group('§10 Kotlin — _call JVM descriptor param types', () {
    // Optional primitives → primitive (non-nullable) JVM type in _call
    for (final c in _optPrimCases) {
      test('${c.type} → ${c.kotlinCallType} in _call', () {
        _checkKotlin(
          _asyncSpec(funcName: 'fn', params: [_p(c.param, c.type)]),
          has: ['fn_call(instanceId: Long, ${c.param}: ${c.kotlinCallType})'],
        );
      });
    }

    // Reference type: nullable in _call
    test('String? stays String? in _call', () {
      _checkKotlin(
        _asyncSpec(funcName: 'send', params: [_p('msg', 'String?')]),
        has: ['send_call(instanceId: Long, msg: String?)'],
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
          has: ['fn_call(instanceId: Long, $param: $jvmType)'],
        );
      });
    }
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §11  Kotlin: sentinel-to-null conversions in _call body
  // ══════════════════════════════════════════════════════════════════════════
  group('§11 Kotlin — _call body NitroOpt* decode', () {
    // Optional primitives → Arg local via NitroOpt* decode, forwarded to impl
    for (final c in _optPrimCases) {
      test('${c.type} emits NitroOpt* decode Arg local + impl call', () {
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

    // Sync variant applies same NitroOptional pattern
    test('sync int? emits NitroOptInt64 decode', () {
      _checkKotlin(
        _syncSpec(funcName: 'fn', params: [_p('timeout', 'int?')]),
        has: ['val timeoutArg: Long? = NitroOptInt64.decode(timeout).nullable'],
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
  group('§13 Kotlin — @NitroNativeAsync NitroOptInt64 decode', () {
    test('NativeAsync int? emits NitroOptInt64 decode before _asyncExecutor.execute', () {
      final out = _kotlin(
        _nativeAsyncSpec(
          funcName: 'fetchAsync',
          params: [_p('timeout', 'int?')],
          returnType: 'int',
        ),
      );
      final decodeIdx = out.indexOf('val timeoutArg: Long? = NitroOptInt64.decode(timeout).nullable');
      final executeIdx = out.indexOf('_asyncExecutor.execute');
      expect(decodeIdx, greaterThan(-1), reason: 'NitroOptInt64 decode must be emitted');
      expect(decodeIdx, lessThan(executeIdx), reason: 'decode must be computed before the execute block');
      expect(out, contains('impl.fetchAsync(timeoutArg)'));
    });

    test('NativeAsync double? emits NitroOptFloat64 decode', () {
      _checkKotlin(
        _nativeAsyncSpec(
          funcName: 'computeAsync',
          params: [_p('factor', 'double?')],
          returnType: 'double',
        ),
        has: [
          'val factorArg: Double? = NitroOptFloat64.decode(factor).nullable',
          'impl.computeAsync(factorArg)',
        ],
      );
    });

    test('NativeAsync bool? emits NitroOptBool decode', () {
      _checkKotlin(
        _nativeAsyncSpec(
          funcName: 'toggleAsync',
          params: [_p('flag', 'bool?')],
          returnType: 'bool',
        ),
        has: [
          'val flagArg: Boolean? = NitroOptBool.decode(flag).nullable',
          'impl.toggleAsync(flagArg)',
        ],
      );
    });

    test('NativeAsync without optional primitives: no NitroOptXxx emitted', () {
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
          'val timeoutArg: Long? = NitroOptInt64.decode(timeout).nullable',
          'val scaleArg: Double? = NitroOptFloat64.decode(scale).nullable',
          'val verboseArg: Boolean? = NitroOptBool.decode(verbose).nullable',
          'impl.doAll(id, timeoutArg, scaleArg, verboseArg, flag, count)',
        ],
        hasNot: ['flagArg', 'countArg', 'idArg'],
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §15  NitroOptional<T> generator output — FFI type assertions
  // ══════════════════════════════════════════════════════════════════════════
  group('§15 NitroOptional<T> generator output — FFI type assertions', () {
    test('int? param → Pointer<NitroOptInt64> (typed struct pointer) in generated Dart', () {
      final out = DartFfiGenerator.generate(
        _asyncSpec(funcName: 'fn', params: [_p('v', 'int?')]),
      );
      expect(out, contains('Pointer<NitroOptInt64>'));
      expect(out, contains('packInt('));
    });
    test('double? param → Pointer<NitroOptFloat64> (typed struct pointer) in generated Dart', () {
      final out = DartFfiGenerator.generate(
        _asyncSpec(funcName: 'fn', params: [_p('v', 'double?')]),
      );
      expect(out, contains('Pointer<NitroOptFloat64>'));
      expect(out, contains('packDouble('));
    });
    test('bool? param → Pointer<NitroOptBool> (typed struct pointer) in generated Dart', () {
      final out = DartFfiGenerator.generate(
        _asyncSpec(funcName: 'fn', params: [_p('v', 'bool?')]),
      );
      expect(out, contains('Pointer<NitroOptBool>'));
      expect(out, contains('packBool('));
    });
    test('int? return (@nitroAsync) → Pointer<NitroOptInt64> + .decoded in generated Dart', () {
      final out = DartFfiGenerator.generate(
        _asyncSpec(funcName: 'fn', params: [], returnType: 'int?'),
      );
      expect(out, contains('Pointer<NitroOptInt64>'));
      expect(out, contains('.decoded'));
    });
    test('double? return (@nitroAsync) → Pointer<NitroOptFloat64> + .decoded in generated Dart', () {
      final out = DartFfiGenerator.generate(
        _asyncSpec(funcName: 'fn', params: [], returnType: 'double?'),
      );
      expect(out, contains('Pointer<NitroOptFloat64>'));
      expect(out, contains('.decoded'));
    });
    test('bool? return (@nitroAsync) → Pointer<NitroOptBool> + .decoded in generated Dart', () {
      final out = DartFfiGenerator.generate(
        _asyncSpec(funcName: 'fn', params: [], returnType: 'bool?'),
      );
      expect(out, contains('Pointer<NitroOptBool>'));
      expect(out, contains('.decoded'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §16  isOptional flag — same treatment as nullable type suffix
  // ══════════════════════════════════════════════════════════════════════════
  group('§16 isOptional flag — treated same as nullable suffix', () {
    test('Dart: isOptional int? → arena.packOptionalInt encoding', () {
      _checkDartFfi(
        _asyncSpec(
          funcName: 'retry',
          params: [
            _p('retries', 'int?', isNamed: true, isOptional: true, defaultLiteral: '3'),
          ],
        ),
        has: ['arena.packInt(retries)'],
      );
    });

    test('Kotlin: isOptional int? → NitroOptInt64 decode', () {
      _checkKotlin(
        _asyncSpec(
          funcName: 'retry',
          params: [
            _p('retries', 'int?', isNamed: true, isOptional: true, defaultLiteral: '3'),
          ],
        ),
        has: ['val retriesArg: Long? = NitroOptInt64.decode(retries).nullable'],
      );
    });

    test('Dart: isOptional double? → arena.packOptionalDouble encoding', () {
      _checkDartFfi(
        _asyncSpec(
          funcName: 'check',
          params: [
            _p('threshold', 'double?', isNamed: true, isOptional: true),
          ],
        ),
        has: ['arena.packDouble(threshold)'],
      );
    });

    test('Kotlin: isOptional double? → NitroOptFloat64 decode', () {
      _checkKotlin(
        _asyncSpec(
          funcName: 'check',
          params: [
            _p('threshold', 'double?', isNamed: true, isOptional: true),
          ],
        ),
        has: ['val thresholdArg: Double? = NitroOptFloat64.decode(threshold).nullable'],
      );
    });
  });
}
