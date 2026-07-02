import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/variant_generator.dart';
import 'package:test/test.dart';

/// Tests for Gap #5 — `null` as a `@NitroVariant` case.
///
/// When a [BridgeVariantCase] has `name == 'null'` (case-insensitive),
/// [VariantGenerator] treats it as a nullable-marker:
///   • `fromNative` / `fromReader` return `VariantName?`
///   • The null-tag decodes to Dart `null`
///   • An `encodeNullable` static is added to handle null encoding
void main() {
  group('Null variant case (Gap #5)', () {
    BridgeSpec nullableVariantSpec({String nullCaseName = 'null'}) => BridgeSpec(
          dartClassName: 'Filter',
          lib: 'filter',
          namespace: 'filter',
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'filter.native.dart',
          variants: [
            BridgeVariant(
              name: 'FilterEvent',
              cases: [
                BridgeVariantCase(
                  name: 'FilterAccepted',
                  label: 'accepted',
                  fields: [],
                ),
                BridgeVariantCase(
                  name: nullCaseName,
                  label: nullCaseName,
                  fields: [],
                ),
              ],
            ),
          ],
        );

    test('generates extension code for a variant with a null case', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      expect(out, isNotEmpty);
    });

    test('fromNative return type is nullable (VariantName?)', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      expect(out, contains('static FilterEvent? fromNative('));
    });

    test('fromReader return type is nullable (VariantName?)', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      expect(out, contains('static FilterEvent? fromReader('));
    });

    test('null tag decodes to Dart null in fromReader switch', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      // The null case is at index 1 (second case), so tag 1 → null.
      expect(out, contains('1 => null,'));
    });

    test('non-null case still decodes normally', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      expect(out, contains('0 => FilterAccepted(),'));
    });

    test('encodeNullable static is emitted', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      expect(out, contains('static Pointer<Uint8> encodeNullable(FilterEvent? value, Allocator alloc)'));
    });

    test('encodeNullable writes null tag when value is null', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      // null case is at tag index 1
      expect(out, contains('writer.writeInt8(1);'));
    });

    test('encodeNullable delegates to writeFields for non-null', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      expect(out, contains('value.writeFields(writer);'));
    });

    test('null case with first tag (index 0) correctly writes tag 0', () {
      // Spec where the null case is first (tag 0), real case is second (tag 1).
      final spec = BridgeSpec(
        dartClassName: 'Evt',
        lib: 'evt',
        namespace: 'evt',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'evt.native.dart',
        variants: [
          BridgeVariant(
            name: 'Evt',
            cases: [
              BridgeVariantCase(name: 'null', label: 'null', fields: []),
              BridgeVariantCase(name: 'EvtHappened', label: 'happened', fields: []),
            ],
          ),
        ],
      );
      final out = VariantGenerator.generateDartExtensions(spec);
      expect(out, contains('0 => null,'));
      expect(out, contains('1 => EvtHappened(),'));
      expect(out, contains('writer.writeInt8(0)'));
    });

    test('null case name is case-insensitive (NULL, Null)', () {
      for (final name in ['NULL', 'Null']) {
        final out = VariantGenerator.generateDartExtensions(nullableVariantSpec(nullCaseName: name));
        expect(out, contains('FilterEvent?'), reason: 'Failed for null case name: $name');
        expect(out, contains('=> null,'), reason: 'Failed for null case name: $name');
      }
    });

    test('variant without null case still has non-nullable return type', () {
      final spec = BridgeSpec(
        dartClassName: 'Event',
        lib: 'event',
        namespace: 'event',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'event.native.dart',
        variants: [
          BridgeVariant(
            name: 'MyEvent',
            cases: [
              BridgeVariantCase(name: 'EventA', label: 'a', fields: []),
              BridgeVariantCase(name: 'EventB', label: 'b', fields: []),
            ],
          ),
        ],
      );
      final out = VariantGenerator.generateDartExtensions(spec);
      expect(out, contains('static MyEvent fromNative('));
      expect(out, isNot(contains('MyEvent?')));
      expect(out, isNot(contains('encodeNullable')));
    });

    test('toNative is still emitted for non-null encoding', () {
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      expect(out, contains('Pointer<Uint8> toNative(Allocator alloc)'));
    });

    test('writeFields does not include a switch case for the null marker', () {
      // The null case has no Dart class, so writeFields has no switch arm for it.
      final out = VariantGenerator.generateDartExtensions(nullableVariantSpec());
      // Only FilterAccepted should appear in writeFields
      expect(out, contains('case FilterAccepted():'));
      // There should NOT be a 'case null():' line (invalid Dart)
      expect(out, isNot(contains('case null():')));
    });

    test('variant with null case and a field case generates correctly', () {
      final spec = BridgeSpec(
        dartClassName: 'Result',
        lib: 'result',
        namespace: 'result',
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'result.native.dart',
        variants: [
          BridgeVariant(
            name: 'Result',
            cases: [
              BridgeVariantCase(
                name: 'ResultOk',
                label: 'ok',
                fields: [
                  BridgeRecordField(
                    name: 'value',
                    dartType: 'String',
                    kind: RecordFieldKind.primitive,
                  ),
                ],
              ),
              BridgeVariantCase(name: 'null', label: 'null', fields: []),
            ],
          ),
        ],
      );
      final out = VariantGenerator.generateDartExtensions(spec);
      expect(out, contains('static Result? fromNative('));
      expect(out, contains('1 => null,'));
      // The field case should still decode correctly
      expect(out, contains('value: r.readString()'));
    });
  });
}
