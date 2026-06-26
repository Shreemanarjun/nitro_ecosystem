// Tests for @NitroVariant sealed/union type code generation (P1).
//
// Covers:
//   - Dart fromReader / writeFields extensions (VariantGenerator)
//   - Kotlin sealed class + companion fromReader + writeFields
//   - Swift enum + static fromReader + writeFields
//   - SpecValidator E014 (empty variants, >10 cases)
//   - BridgeSpec.isVariantName O(1) lookup

import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/variant_generator.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Fixture specs ─────────────────────────────────────────────────────────────

/// FilterResult variant: two cases, one with a field, one unit.
BridgeVariant _filterVariant() => BridgeVariant(
  name: 'FilterResult',
  cases: [
    BridgeVariantCase(
      name: 'FilterAccepted',
      label: 'accepted',
      fields: [
        BridgeRecordField(
          name: 'id',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
    BridgeVariantCase(
      name: 'FilterRejected',
      label: 'rejected',
      fields: [],
    ),
  ],
);

/// Minimal BridgeSpec with a single @NitroVariant.
BridgeSpec _variantSpec() => BridgeSpec(
  dartClassName: 'Foo',
  lib: 'foo',
  namespace: 'foo',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'foo.native.dart',
  variants: [_filterVariant()],
);

/// Type-only spec — no @NitroModule, just the variant declaration.
BridgeSpec _typeOnlyVariantSpec() => BridgeSpec(
  dartClassName: '',
  lib: 'foo',
  namespace: '',
  sourceUri: 'foo.native.dart',
  variants: [_filterVariant()],
  isTypeOnly: true,
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('BridgeSpec — @NitroVariant', () {
    test('isVariantName returns true for declared variant', () {
      final spec = _variantSpec();
      expect(spec.isVariantName('FilterResult'), isTrue);
      expect(spec.isVariantName('Unknown'), isFalse);
    });

    test('variantByName returns correct variant', () {
      final spec = _variantSpec();
      final v = spec.variantByName('FilterResult');
      expect(v, isNotNull);
      expect(v!.cases.length, equals(2));
    });

    test('localVariants excludes imported variants', () {
      final spec = BridgeSpec(
        dartClassName: '',
        lib: 'foo',
        namespace: '',
        sourceUri: 'foo.native.dart',
        variants: [
          BridgeVariant(name: 'A', cases: [BridgeVariantCase(name: 'AX', label: 'x', fields: [])]),
          BridgeVariant(name: 'B', cases: [BridgeVariantCase(name: 'BY', label: 'y', fields: [])], isImported: true),
        ],
        isTypeOnly: true,
      );
      expect(spec.localVariants.map((v) => v.name), equals(['A']));
    });
  });

  group('VariantGenerator — Dart extensions', () {
    test('emits fromNative / fromReader / writeFields / toNative for variant', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, contains('extension FilterResultVariantExt on FilterResult'));
      expect(code, contains('static FilterResult fromNative'));
      expect(code, contains('static FilterResult fromReader'));
      expect(code, contains('void writeFields(RecordWriter writer)'));
      expect(code, contains('Pointer<Uint8> toNative(Allocator alloc)'));
    });

    test('fromReader uses tag switch for each case', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, contains('final tag = r.readInt8()'));
      expect(code, contains('return switch (tag)'));
      // case 0 → FilterAccepted, decodes the String field
      expect(code, contains('0 =>'));
      expect(code, contains('FilterAccepted'));
      // case 1 → FilterRejected (unit)
      expect(code, contains('1 =>'));
      expect(code, contains('FilterRejected'));
    });

    test('writeFields emits tag byte then case-specific fields', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      expect(code, contains('writer.writeInt8(0)'));
      expect(code, contains('writer.writeInt8(1)'));
      // FilterAccepted has a String id field
      expect(code, contains('writer.writeString'));
    });

    test('unit case writes only tag — no field write', () {
      final code = VariantGenerator.generateDartExtensions(_typeOnlyVariantSpec());
      // FilterRejected is unit → only the tag line inside its case
      expect(code, contains('case FilterRejected():'));
      expect(code, contains('writer.writeInt8(1)'));
    });

    test('returns empty string when no variants', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
      );
      expect(VariantGenerator.generateDartExtensions(spec), isEmpty);
    });
  });

  group('DartFfiGenerator — @NitroVariant', () {
    test('emits VariantExt in generated .g.dart output', () {
      final code = DartFfiGenerator.generate(_variantSpec());
      expect(code, contains('FilterResultVariantExt'));
    });
  });

  group('KotlinGenerator — @NitroVariant type-only', () {
    test('emits sealed class with sub-classes', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('sealed class FilterResult'));
      expect(code, contains('data class FilterAccepted'));
      expect(code, contains('data object FilterRejected'));
    });

    test('emits companion object with fromReader', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('companion object'));
      expect(code, contains('fun fromReader(r: RecordReader): FilterResult'));
    });

    test('fromReader uses when with correct tags', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('0 -> FilterAccepted'));
      expect(code, contains('1 -> FilterRejected'));
    });

    test('emits writeFields with when block', () {
      final code = KotlinGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('fun writeFields(w: RecordWriter)'));
      expect(code, contains('is FilterAccepted'));
      expect(code, contains('is FilterRejected'));
      expect(code, contains('w.writeInt8(0)'));
      expect(code, contains('w.writeInt8(1)'));
    });
  });

  group('SwiftGenerator — @NitroVariant type-only', () {
    test('emits enum with cases', () {
      final code = SwiftGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('enum FilterResult'));
      expect(code, contains('case accepted'));
      expect(code, contains('case rejected'));
    });

    test('emits static fromReader', () {
      final code = SwiftGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('static func fromReader'));
      expect(code, contains('case 0: return .accepted'));
      expect(code, contains('case 1: return .rejected'));
    });

    test('emits writeFields with switch on self', () {
      final code = SwiftGenerator.generate(_typeOnlyVariantSpec());
      expect(code, contains('func writeFields(to w: RecordWriter)'));
      expect(code, contains('case .accepted'));
      expect(code, contains('case .rejected'));
      expect(code, contains('w.writeInt8(0)'));
      expect(code, contains('w.writeInt8(1)'));
    });
  });

  group('SpecValidator — E014 (@NitroVariant case count)', () {
    test('E014 error for empty variant (zero cases)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
        variants: [BridgeVariant(name: 'Empty', cases: [])],
      );
      final result = SpecValidator.validate(spec);
      expect(result.any((i) => i.code == 'E014'), isTrue,
          reason: 'E014 expected for empty variant');
    });

    test('E014 error when variant has more than 10 cases', () {
      final manyCases = List.generate(
        11,
        (i) => BridgeVariantCase(name: 'Case$i', label: 'case$i', fields: []),
      );
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
        variants: [BridgeVariant(name: 'Big', cases: manyCases)],
      );
      final result = SpecValidator.validate(spec);
      final e014 = result.where((i) => i.code == 'E014').toList();
      expect(e014, isNotEmpty, reason: 'E014 expected for >10 cases');
      expect(e014.first.message, contains('11 cases'));
    });

    test('no E014 for valid variant (2 cases)', () {
      final spec = _variantSpec();
      final result = SpecValidator.validate(spec);
      expect(result.where((i) => i.code == 'E014'), isEmpty);
    });

    test('no E014 for variant with exactly 10 cases', () {
      final tenCases = List.generate(
        10,
        (i) => BridgeVariantCase(name: 'Case$i', label: 'case$i', fields: []),
      );
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        sourceUri: 'foo.native.dart',
        variants: [BridgeVariant(name: 'Max', cases: tenCases)],
      );
      final result = SpecValidator.validate(spec);
      expect(result.where((i) => i.code == 'E014'), isEmpty);
    });
  });

  // ── C++ variant codegen (S4-P1) ─────────────────────────────────────────────

  group('CppInterfaceGenerator — @NitroVariant', () {
    late BridgeSpec cppSpec;
    late String cppOutput;

    setUp(() {
      cppSpec = BridgeSpec(
        dartClassName: 'Filter',
        lib: 'mylib',
        namespace: 'mylib',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'filter.native.dart',
        variants: [_filterVariant()],
        functions: [
          BridgeFunction(
            dartName: 'process',
            cSymbol: 'mylib_process',
            isAsync: false,
            isNativeAsync: false,
            returnType: BridgeType(name: 'FilterResult', isRecord: false, isFunction: false),
            params: [
              BridgeParam(
                name: 'input',
                type: BridgeType(name: 'FilterResult', isRecord: false, isFunction: false),
              ),
            ],
          ),
        ],
      );
      cppOutput = CppInterfaceGenerator.generate(cppSpec);
    });

    test('includes <variant> header', () {
      expect(cppOutput, contains('#include <variant>'));
    });

    test('emits FilterAccepted struct with id field', () {
      expect(cppOutput, contains('struct FilterAccepted {'));
      expect(cppOutput, contains('std::string id;'));
    });

    test('emits FilterRejected as unit struct', () {
      expect(cppOutput, contains('struct FilterRejected {};'));
    });

    test('emits std::variant<> typedef', () {
      expect(cppOutput, contains('using FilterResult = std::variant<FilterAccepted, FilterRejected>;'));
    });

    test('emits nitro_decode_FilterResult function', () {
      expect(cppOutput, contains('inline FilterResult nitro_decode_FilterResult(NitroCppBuffer buf)'));
      expect(cppOutput, contains('case 0:')); // FilterAccepted tag
      expect(cppOutput, contains('case 1:')); // FilterRejected tag (actually no — only 2 cases so tag 0 and implicit)
    });

    test('emits nitro_encode_FilterResult function', () {
      expect(cppOutput, contains('inline std::pair<uint8_t*, size_t> nitro_encode_FilterResult'));
      expect(cppOutput, contains('std::visit'));
    });

    test('variant parameter in method uses NitroCppBuffer', () {
      expect(cppOutput, contains('virtual NitroCppBuffer process(NitroCppBuffer input) = 0;'));
    });

    test('variant type-only spec generates no abstract class', () {
      final typeOnly = BridgeSpec(
        dartClassName: '',
        lib: 'foo',
        namespace: '',
        sourceUri: 'foo.native.dart',
        variants: [_filterVariant()],
      );
      // type-only → not a hasCppImpl spec, returns placeholder
      final out = CppInterfaceGenerator.generate(typeOnly);
      expect(out, contains('Not applicable'));
    });
  });
}
