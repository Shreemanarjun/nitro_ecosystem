// Comprehensive tests ensuring ALL parameter type combinations generate
// correct code in both the Dart FFI generator and Kotlin generator.
//
// The optional-primitive sentinel pattern:
//   Dart callArgs  → sentinel value when null (int?→-1, double?→nan, bool?→-1)
//   Kotlin _call   → sentinel-to-null conversion before forwarding to interface
//
// Sentinels:
//   int?    → `?? -1`                        (Kotlin: < 0L  → null)
//   double? → `?? double.nan`                (Kotlin: isNaN → null)
//   bool?   → `== null ? -1 : (v! ? 1 : 0)` (Kotlin: .toInt() < 0 → null)
//
// All other types (String, String?, struct, struct?, enum, bool, int, double)
// are handled correctly without sentinels.
//
// §1   Dart: int?   → ?? -1 sentinel
// §2   Dart: double? → ?? double.nan sentinel
// §3   Dart: bool?  → ternary -1 sentinel
// §4   Dart: non-optional primitives — no sentinel
// §5   Dart: String / String? — pointers, not sentinel
// §6   Dart: struct / struct? — pointer / null-guarded
// §7   Dart: enum — nativeValue
// §8   Dart: mixed params
// §9   Dart: @NitroNativeAsync — sentinels still applied
// §10  Kotlin: _call param types (JVM descriptors)
// §11  Kotlin: sentinel-to-null conversions in _call body
// §12  Kotlin: interface keeps nullable types
// §13  Kotlin: @NitroNativeAsync sentinel-to-null
// §14  Kotlin: mixed params — only optional-primitives unwrapped
// §15  Sentinel round-trip logic (pure Dart unit tests)
// §16  isOptional flag treated same as nullable type suffix

import 'package:test/test.dart';
import 'package:nitro_annotations/nitro_annotations.dart';
import '../lib/src/generators/dart_ffi_generator.dart';
import '../lib/src/generators/kotlin_generator.dart';
import '../lib/src/bridge_spec.dart';



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

BridgeParam _p(String name, String type, {bool isNamed = false, bool isOptional = false, String? defaultLiteral}) =>
    BridgeParam(
      name: name,
      type: BridgeType(name: type),
      isNamed: isNamed,
      isOptional: isOptional,
      defaultLiteral: defaultLiteral,
    );

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ══════════════════════════════════════════════════════════════════════════
  // §1  Dart FFI: int? → ?? -1
  // ══════════════════════════════════════════════════════════════════════════
  group('§1 Dart FFI — int? sentinel', () {
    test('async: int? uses ?? -1', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'doWork', params: [_p('timeout', 'int?')]));
      expect(out, contains('timeout ?? -1'));
    });

    test('sync: int? uses ?? -1', () {
      final out = DartFfiGenerator.generate(
          _syncSpec(funcName: 'doWork', params: [_p('timeout', 'int?')]));
      expect(out, contains('timeout ?? -1'));
    });

    test('named int? uses ?? -1', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'doWork', params: [_p('limit', 'int?', isNamed: true)]));
      expect(out, contains('limit ?? -1'));
    });

    test('multiple int? params each get ?? -1', () {
      final out = DartFfiGenerator.generate(_asyncSpec(funcName: 'fn', params: [
        _p('a', 'int?'),
        _p('b', 'int?'),
      ]));
      expect(out, contains('a ?? -1'));
      expect(out, contains('b ?? -1'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §2  Dart FFI: double? → ?? double.nan
  // ══════════════════════════════════════════════════════════════════════════
  group('§2 Dart FFI — double? sentinel', () {
    test('async: double? uses ?? double.nan', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'measure', params: [_p('scale', 'double?')]));
      expect(out, contains('scale ?? double.nan'));
    });

    test('sync: double? uses ?? double.nan', () {
      final out = DartFfiGenerator.generate(
          _syncSpec(funcName: 'measure', params: [_p('ratio', 'double?')]));
      expect(out, contains('ratio ?? double.nan'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §3  Dart FFI: bool? → ternary with -1 sentinel
  // ══════════════════════════════════════════════════════════════════════════
  group('§3 Dart FFI — bool? sentinel', () {
    test('async: bool? uses ternary sentinel', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'toggle', params: [_p('enabled', 'bool?')]));
      expect(out, contains('enabled == null ? -1 : (enabled! ? 1 : 0)'));
    });

    test('sync: bool? uses ternary sentinel', () {
      final out = DartFfiGenerator.generate(
          _syncSpec(funcName: 'toggle', params: [_p('verbose', 'bool?')]));
      expect(out, contains('verbose == null ? -1 : (verbose! ? 1 : 0)'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §4  Dart FFI: non-optional primitives — NO sentinel
  // ══════════════════════════════════════════════════════════════════════════
  group('§4 Dart FFI — non-optional primitives: no sentinel', () {
    test('int passes as-is', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('count', 'int')]));
      expect(out, isNot(contains('count ?? ')));
      expect(out, contains('count'));
    });

    test('double passes as-is', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('scale', 'double')]));
      expect(out, isNot(contains('scale ?? ')));
    });

    test('bool uses ? 1 : 0, not sentinel', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('flag', 'bool')]));
      expect(out, contains('flag ? 1 : 0'));
      expect(out, isNot(contains('flag == null')));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §5  Dart FFI: String / String?
  // ══════════════════════════════════════════════════════════════════════════
  group('§5 Dart FFI — String / String?', () {
    test('String uses toNativeUtf8', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'send', params: [_p('msg', 'String')]));
      expect(out, contains('msg.toNativeUtf8'));
      expect(out, isNot(contains('msg ?? ')));
    });

    test('String? uses null-guarded toNativeUtf8', () {
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'send', params: [_p('msg', 'String?')]));
      expect(out, contains('msg != null'));
      expect(out, contains('toNativeUtf8'));
      expect(out, contains('nullptr'));
      expect(out, isNot(contains('msg ?? -1')));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §6  Dart FFI: struct / struct? — pointer encoding
  // ══════════════════════════════════════════════════════════════════════════
  group('§6 Dart FFI — struct / struct?', () {
    final structSpec = BridgeStruct(
      name: 'Config',
      packed: false,
      fields: [],
    );

    test('struct uses .toNative(arena).cast<Void>()', () {
      final out = DartFfiGenerator.generate(_asyncSpec(
        funcName: 'configure',
        params: [_p('cfg', 'Config')],
        structs: [structSpec],
      ));
      expect(out, contains('cfg.toNative(arena).cast<Void>()'));
    });

    test('struct? uses null-guarded .toNative() with nullptr fallback', () {
      final out = DartFfiGenerator.generate(_asyncSpec(
        funcName: 'configure',
        params: [_p('cfg', 'Config?')],
        structs: [structSpec],
      ));
      expect(out, contains('cfg != null'));
      expect(out, contains('toNative'));
      expect(out, contains('nullptr'));
      expect(out, isNot(contains('cfg ?? -1')));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §7  Dart FFI: enum — nativeValue
  // ══════════════════════════════════════════════════════════════════════════
  group('§7 Dart FFI — enum param', () {
    final enumSpec = BridgeEnum(name: 'Color', startValue: 0, values: ['red', 'green', 'blue']);

    test('enum uses .nativeValue, not sentinel', () {
      final out = DartFfiGenerator.generate(_asyncSpec(
        funcName: 'paint',
        params: [_p('color', 'Color')],
        enums: [enumSpec],
      ));
      expect(out, contains('color.nativeValue'));
      expect(out, isNot(contains('color ?? ')));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §8  Dart FFI: mixed params in one function
  // ══════════════════════════════════════════════════════════════════════════
  group('§8 Dart FFI — mixed params', () {
    test('all types encoded correctly together', () {
      final out = DartFfiGenerator.generate(_asyncSpec(
        funcName: 'doAll',
        params: [
          _p('id', 'String'),
          _p('timeout', 'int?'),
          _p('scale', 'double?'),
          _p('verbose', 'bool?'),
          _p('enabled', 'bool'),
          _p('count', 'int'),
        ],
      ));
      expect(out, contains('id.toNativeUtf8'));
      expect(out, contains('timeout ?? -1'));
      expect(out, contains('scale ?? double.nan'));
      expect(out, contains('verbose == null ? -1 : (verbose! ? 1 : 0)'));
      expect(out, contains('enabled ? 1 : 0'));
      expect(out, contains('count'));
      expect(out, isNot(contains('count ?? ')));
      expect(out, isNot(contains('enabled ?? ')));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §9  Dart FFI: @NitroNativeAsync — sentinels applied in callArgs
  // ══════════════════════════════════════════════════════════════════════════
  group('§9 Dart FFI — @NitroNativeAsync optional primitives', () {
    test('NativeAsync int? uses ?? -1', () {
      final out = DartFfiGenerator.generate(
          _nativeAsyncSpec(funcName: 'fetchAsync', params: [_p('delay', 'int?')]));
      expect(out, contains('delay ?? -1'));
    });

    test('NativeAsync double? uses ?? double.nan', () {
      final out = DartFfiGenerator.generate(
          _nativeAsyncSpec(funcName: 'computeAsync', params: [_p('factor', 'double?')]));
      expect(out, contains('factor ?? double.nan'));
    });

    test('NativeAsync bool? uses ternary sentinel', () {
      final out = DartFfiGenerator.generate(
          _nativeAsyncSpec(funcName: 'toggleAsync', params: [_p('flag', 'bool?')]));
      expect(out, contains('flag == null ? -1 : (flag! ? 1 : 0)'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §10  Kotlin: _call bridge param types (JVM descriptors)
  // ══════════════════════════════════════════════════════════════════════════
  group('§10 Kotlin — _call JVM descriptor param types', () {
    test('int? → Long (primitive J) not Long?', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'doWork', params: [_p('timeout', 'int?')]));
      expect(out, contains('doWork_call(timeout: Long)'));
      expect(out, isNot(contains('doWork_call(timeout: Long?)')));
    });

    test('bool? → Boolean (primitive Z) not Boolean?', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'toggle', params: [_p('enabled', 'bool?')]));
      expect(out, contains('toggle_call(enabled: Boolean)'));
      expect(out, isNot(contains('toggle_call(enabled: Boolean?)')));
    });

    test('double? → Double (primitive D) not Double?', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'measure', params: [_p('scale', 'double?')]));
      expect(out, contains('measure_call(scale: Double)'));
      expect(out, isNot(contains('measure_call(scale: Double?)')));
    });

    test('String? stays String? (reference type)', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'send', params: [_p('msg', 'String?')]));
      expect(out, contains('send_call(msg: String?)'));
    });

    test('non-optional int stays Long', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('count', 'int')]));
      expect(out, contains('fn_call(count: Long)'));
    });

    test('non-optional bool stays Boolean', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('flag', 'bool')]));
      expect(out, contains('fn_call(flag: Boolean)'));
    });

    test('non-optional double stays Double', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('ratio', 'double')]));
      expect(out, contains('fn_call(ratio: Double)'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §11  Kotlin: sentinel-to-null conversions in _call body
  // ══════════════════════════════════════════════════════════════════════════
  group('§11 Kotlin — _call body sentinel-to-null conversions', () {
    test('int? emits Long? unwrap from sentinel', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'doWork', params: [_p('timeout', 'int?')]));
      expect(out, contains('val timeoutArg: Long? = if (timeout < 0L) null else timeout'));
      expect(out, contains('impl.doWork(timeoutArg)'));
    });

    test('double? emits Double? unwrap via isNaN()', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'measure', params: [_p('scale', 'double?')]));
      expect(out, contains('val scaleArg: Double? = if (scale.isNaN()) null else scale'));
      expect(out, contains('impl.measure(scaleArg)'));
    });

    test('bool? emits Boolean? unwrap via toInt() < 0', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'toggle', params: [_p('enabled', 'bool?')]));
      expect(out, contains('val enabledArg: Boolean? = if (enabled.toInt() < 0) null else enabled'));
      expect(out, contains('impl.toggle(enabledArg)'));
    });

    test('non-optional int: no unwrap emitted', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('count', 'int')]));
      expect(out, isNot(contains('countArg')));
    });

    test('non-optional bool: no unwrap emitted', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('flag', 'bool')]));
      expect(out, isNot(contains('flagArg')));
    });

    test('String?: no unwrap (reference type)', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'fn', params: [_p('msg', 'String?')]));
      expect(out, isNot(contains('msgArg')));
    });

    test('sync int? emits Long? unwrap', () {
      final out = KotlinGenerator.generate(
          _syncSpec(funcName: 'fn', params: [_p('timeout', 'int?')]));
      expect(out, contains('val timeoutArg: Long? = if (timeout < 0L) null else timeout'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §12  Kotlin interface: keeps nullable types
  // ══════════════════════════════════════════════════════════════════════════
  group('§12 Kotlin — interface keeps nullable types', () {
    test('int? in interface is Long?', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'doWork', params: [_p('timeout', 'int?')]));
      // Interface fun declaration must have Long?
      expect(out, contains('fun doWork(timeout: Long?)'));
    });

    test('double? in interface is Double?', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'measure', params: [_p('scale', 'double?')]));
      expect(out, contains('fun measure(scale: Double?)'));
    });

    test('bool? in interface is Boolean?', () {
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'toggle', params: [_p('enabled', 'bool?')]));
      expect(out, contains('fun toggle(enabled: Boolean?)'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §13  Kotlin @NitroNativeAsync — sentinel-to-null before execute block
  // ══════════════════════════════════════════════════════════════════════════
  group('§13 Kotlin — @NitroNativeAsync sentinel-to-null', () {
    test('NativeAsync int? emits Long? sentinel before _asyncExecutor.execute', () {
      final out = KotlinGenerator.generate(
          _nativeAsyncSpec(funcName: 'fetchAsync', params: [_p('timeout', 'int?')],
              returnType: 'int'));
      final sentinelIdx = out.indexOf('val timeoutArg: Long? = if (timeout < 0L) null else timeout');
      final executeIdx = out.indexOf('_asyncExecutor.execute');
      expect(sentinelIdx, greaterThan(-1), reason: 'sentinel conversion must be emitted');
      expect(sentinelIdx, lessThan(executeIdx),
          reason: 'sentinel must be computed before the execute block');
      expect(out, contains('impl.fetchAsync(timeoutArg)'));
    });

    test('NativeAsync double? emits Double? isNaN check', () {
      final out = KotlinGenerator.generate(
          _nativeAsyncSpec(funcName: 'computeAsync', params: [_p('factor', 'double?')],
              returnType: 'double'));
      expect(out, contains('val factorArg: Double? = if (factor.isNaN()) null else factor'));
      expect(out, contains('impl.computeAsync(factorArg)'));
    });

    test('NativeAsync bool? emits Boolean? toInt() check', () {
      final out = KotlinGenerator.generate(
          _nativeAsyncSpec(funcName: 'toggleAsync', params: [_p('flag', 'bool?')],
              returnType: 'bool'));
      expect(out, contains('val flagArg: Boolean? = if (flag.toInt() < 0) null else flag'));
      expect(out, contains('impl.toggleAsync(flagArg)'));
    });

    test('NativeAsync without optional primitives: no sentinel emitted', () {
      final out = KotlinGenerator.generate(_nativeAsyncSpec(
        funcName: 'pureAsync',
        params: [_p('name', 'String'), _p('count', 'int')],
      ));
      expect(out, isNot(contains('Arg: Long?')));
      expect(out, isNot(contains('Arg: Double?')));
      expect(out, isNot(contains('Arg: Boolean?')));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §14  Kotlin mixed params — only optional-primitives get unwrapped
  // ══════════════════════════════════════════════════════════════════════════
  group('§14 Kotlin — mixed params: selective unwrapping', () {
    test('only int?, bool?, double? get Arg locals; others pass raw', () {
      final out = KotlinGenerator.generate(_asyncSpec(funcName: 'doAll', params: [
        _p('id', 'String'),
        _p('timeout', 'int?'),
        _p('scale', 'double?'),
        _p('verbose', 'bool?'),
        _p('flag', 'bool'),
        _p('count', 'int'),
      ]));
      // Must have sentinel-to-null for optional primitives
      expect(out, contains('val timeoutArg: Long? = if (timeout < 0L) null else timeout'));
      expect(out, contains('val scaleArg: Double? = if (scale.isNaN()) null else scale'));
      expect(out, contains('val verboseArg: Boolean? = if (verbose.toInt() < 0) null else verbose'));
      // Must NOT unwrap non-optional params
      expect(out, isNot(contains('flagArg')));
      expect(out, isNot(contains('countArg')));
      expect(out, isNot(contains('idArg')));
      // Interface call uses resolved (unwrapped) args
      expect(out, contains('impl.doAll(id, timeoutArg, scaleArg, verboseArg, flag, count)'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §15  Sentinel round-trip logic (pure Dart unit tests)
  // ══════════════════════════════════════════════════════════════════════════
  group('§15 Sentinel round-trip — Dart expressions', () {
    test('int? null → -1 sentinel', () {
      const int? v = null;
      expect(v ?? -1, equals(-1));
    });

    test('int? 30 → 30 (no truncation)', () {
      const int? v = 30;
      expect(v ?? -1, equals(30));
    });

    test('int? 0 → 0 (zero is valid)', () {
      const int? v = 0;
      expect(v ?? -1, equals(0));
    });

    test('double? null → double.nan sentinel', () {
      const double? v = null;
      expect((v ?? double.nan).isNaN, isTrue);
    });

    test('double? 3.14 → 3.14', () {
      const double? v = 3.14;
      expect(v ?? double.nan, equals(3.14));
    });

    test('double? 0.0 → 0.0 (zero is valid)', () {
      const double? v = 0.0;
      expect(v ?? double.nan, equals(0.0));
    });

    test('bool? null → -1 sentinel', () {
      const bool? v = null;
      final r = v == null ? -1 : (v ? 1 : 0);
      expect(r, equals(-1));
    });

    test('bool? true → 1', () {
      const bool? v = true;
      final r = v == null ? -1 : (v ? 1 : 0);
      expect(r, equals(1));
    });

    test('bool? false → 0', () {
      const bool? v = false;
      final r = v == null ? -1 : (v ? 1 : 0);
      expect(r, equals(0));
    });

    // Kotlin-side sentinel detection (simulated in Dart):
    test('Kotlin int? unwrap: -1 → null', () {
      final long = -1;
      final result = long < 0 ? null : long;
      expect(result, isNull);
    });

    test('Kotlin int? unwrap: 30 → 30', () {
      final long = 30;
      final result = long < 0 ? null : long;
      expect(result, equals(30));
    });

    test('Kotlin double? unwrap: NaN → null', () {
      final d = double.nan;
      final result = d.isNaN ? null : d;
      expect(result, isNull);
    });

    test('Kotlin double? unwrap: 3.14 → 3.14', () {
      final d = 3.14;
      final result = d.isNaN ? null : d;
      expect(result, equals(3.14));
    });

    test('Kotlin bool? unwrap: -1 (sentinel) → null', () {
      const sentinel = -1;
      final result = sentinel < 0 ? null : (sentinel != 0);
      expect(result, isNull);
    });

    test('Kotlin bool? unwrap: 1 → true', () {
      const v = 1;
      final result = v < 0 ? null : (v != 0);
      expect(result, isTrue);
    });

    test('Kotlin bool? unwrap: 0 → false', () {
      const v = 0;
      final result = v < 0 ? null : (v != 0);
      expect(result, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // §16  isOptional flag — same treatment as nullable type suffix
  // ══════════════════════════════════════════════════════════════════════════
  group('§16 isOptional flag — treated same as nullable suffix', () {
    test('Dart: isOptional int? → ?? -1', () {
      final param = BridgeParam(
        name: 'retries',
        type: BridgeType(name: 'int?'),
        isNamed: true,
        isOptional: true,
        defaultLiteral: '3',
      );
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'retry', params: [param]));
      expect(out, contains('retries ?? -1'));
    });

    test('Kotlin: isOptional int? → Long? sentinel conversion', () {
      final param = BridgeParam(
        name: 'retries',
        type: BridgeType(name: 'int?'),
        isNamed: true,
        isOptional: true,
        defaultLiteral: '3',
      );
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'retry', params: [param]));
      expect(out, contains('val retriesArg: Long? = if (retries < 0L) null else retries'));
    });

    test('Dart: isOptional double? → ?? double.nan', () {
      final param = BridgeParam(
        name: 'threshold',
        type: BridgeType(name: 'double?'),
        isNamed: true,
        isOptional: true,
      );
      final out = DartFfiGenerator.generate(
          _asyncSpec(funcName: 'check', params: [param]));
      expect(out, contains('threshold ?? double.nan'));
    });

    test('Kotlin: isOptional double? → Double? isNaN conversion', () {
      final param = BridgeParam(
        name: 'threshold',
        type: BridgeType(name: 'double?'),
        isNamed: true,
        isOptional: true,
      );
      final out = KotlinGenerator.generate(
          _asyncSpec(funcName: 'check', params: [param]));
      expect(out, contains('val thresholdArg: Double? = if (threshold.isNaN()) null else threshold'));
    });
  });
}
