// Tests that the builder's validation gate runs before any file is written.
//
// The NitroGeneratorBuilder.build() method (lib/builder.dart) follows this
// order:
//   1. Extract BridgeSpec from the library
//   2. Call SpecValidator.validate(spec)
//   3. If any issue.isError → log + return early (NO files written)
//   4. Only if all-clear → loop over outputs and write files
//
// These tests confirm that gate condition produces the correct result for
// error specs, warning specs, and valid specs — without needing a real
// BuildStep (which would require a full build_runner integration harness).
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/swift_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';

// ── Spec factories ────────────────────────────────────────────────────────────

BridgeSpec _e002Spec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'check',
      cSymbol: 'mod_check',
      isAsync: true,       // @nitroAsync on a non-Future return → E002
      returnType: BridgeType(name: 'bool'),
      params: [],
    ),
  ],
);

BridgeSpec _e001Spec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'setMeta',
      cSymbol: 'mod_set_meta',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'meta',
          // Map<K,V> where K != String → E001 (isMap:false = extractor did not recognise Map<String,V>)
          type: BridgeType(name: 'Map<int, String>', isRecord: true, isMap: false),
        ),
      ],
    ),
  ],
);

BridgeSpec _w001Spec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'connect',
      cSymbol: 'mod_connect',
      isAsync: false,
      returnType: BridgeType(name: 'bool'),
      params: [
        // Non-nullable named param with no defaultLiteral → W001
        BridgeParam(
          name: 'timeout',
          type: BridgeType(name: 'int'),
          isNamed: true,
          isOptional: true,
        ),
      ],
    ),
  ],
);

BridgeSpec _validSpec() => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'mod_add',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'a', type: BridgeType(name: 'double')),
        BridgeParam(name: 'b', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // ── Error specs: builder returns early, no files written ─────────────────

  group('Builder gate — error specs trigger early return', () {
    test('E002 spec has isError issue (gate blocks generation)', () {
      final issues = SpecValidator.validate(_e002Spec());
      expect(
        issues.any((i) => i.isError),
        isTrue,
        reason: 'builder.dart: if (issues.any((i) => i.isError)) return;',
      );
    });

    test('E002 issue code is E002', () {
      final issues = SpecValidator.validate(_e002Spec());
      expect(issues.any((i) => i.code == 'E002'), isTrue);
    });

    test('E001 spec has isError issue (gate blocks generation)', () {
      final issues = SpecValidator.validate(_e001Spec());
      expect(issues.any((i) => i.isError), isTrue);
    });

    test('E001 issue code is E001', () {
      final issues = SpecValidator.validate(_e001Spec());
      expect(issues.any((i) => i.code == 'E001'), isTrue);
    });
  });

  // ── Generators always produce output (they do not self-validate) ──────────
  // This confirms that the builder is the ONLY gatekeeper. If the builder
  // were to skip the validation check, generators would happily emit broken code.

  group('Builder gate — generators do not self-validate', () {
    test('DartFfiGenerator produces output for E002 spec (builder is gatekeeper)', () {
      final code = DartFfiGenerator.generate(_e002Spec());
      expect(code, isNotEmpty);
    });

    test('SwiftGenerator produces output for E002 spec', () {
      final code = SwiftGenerator.generate(_e002Spec());
      expect(code, isNotEmpty);
    });

    test('KotlinGenerator produces output for E002 spec', () {
      final code = KotlinGenerator.generate(_e002Spec());
      expect(code, isNotEmpty);
    });
  });

  // ── Warning specs: builder continues and writes files ─────────────────────

  group('Builder gate — warning specs do NOT trigger early return', () {
    test('W001 spec has no error issues (gate allows generation)', () {
      final issues = SpecValidator.validate(_w001Spec());
      expect(
        issues.any((i) => i.isError),
        isFalse,
        reason: 'builder continues: warnings are logged but do not block writing',
      );
    });

    test('W001 spec has at least one warning', () {
      final issues = SpecValidator.validate(_w001Spec());
      expect(issues.any((i) => !i.isError), isTrue);
      expect(issues.any((i) => i.code == 'W001'), isTrue);
    });

    test('DartFfiGenerator is reachable for W001 spec', () {
      expect(DartFfiGenerator.generate(_w001Spec()), isNotEmpty);
    });
  });

  // ── Valid specs: no issues, builder writes all outputs ────────────────────

  group('Builder gate — valid specs produce no issues', () {
    test('valid spec returns empty issue list', () {
      expect(SpecValidator.validate(_validSpec()), isEmpty);
    });

    test('valid spec gate condition is false (no early return)', () {
      final issues = SpecValidator.validate(_validSpec());
      expect(issues.any((i) => i.isError), isFalse);
    });
  });

  // ── Multiple errors: all collected before returning ───────────────────────

  group('Builder gate — all errors collected before returning', () {
    test('spec with two independent errors returns both issues', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'checkA',
            cSymbol: 'mod_check_a',
            isAsync: true,
            returnType: BridgeType(name: 'bool'),
            params: [],
          ),
          BridgeFunction(
            dartName: 'checkB',
            cSymbol: 'mod_check_b',
            isAsync: true,
            returnType: BridgeType(name: 'int'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final errors = issues.where((i) => i.isError).toList();
      // Builder logs all errors, then returns — user sees all problems at once.
      expect(errors.length, greaterThanOrEqualTo(2));
    });
  });
}
