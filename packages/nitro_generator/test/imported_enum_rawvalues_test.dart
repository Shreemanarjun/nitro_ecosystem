// An imported @HybridEnum must keep its explicit rawValues. Dropping them made
// every downstream lookup table fall back to contiguous index values, so a
// non-contiguous enum imported from another module mapped cases to the WRONG
// wire value — silently, with no diagnostic.
import 'dart:io';

import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _specWith(BridgeEnum e) => BridgeSpec(
  dartClassName: 'M',
  lib: 'm',
  namespace: 'm',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'm.native.dart',
  enums: [e],
  variants: [
    BridgeVariant(
      name: 'V',
      cases: [
        BridgeVariantCase(
          name: 'VLevelled',
          label: 'levelled',
          fields: [BridgeRecordField(name: 'lvl', dartType: 'Level', kind: RecordFieldKind.enumValue)],
        ),
      ],
    ),
  ],
);

void main() {
  test('a non-contiguous enum keeps its rawValues in the C++ lookup table', () {
    final out = CppInterfaceGenerator.generate(
      _specWith(BridgeEnum(name: 'Level', startValue: 0, values: ['low', 'mid', 'high'], rawValues: [0, 50, 100])),
    );
    expect(out, contains('{ 0, 50, 100 }'), reason: 'rawValues lost — indices would be used instead');
    expect(out, isNot(contains('{ 0, 1, 2 }')));
  });

  test('an enum WITHOUT rawValues still falls back to contiguous', () {
    final out = CppInterfaceGenerator.generate(
      _specWith(BridgeEnum(name: 'Level', startValue: 0, values: ['low', 'mid', 'high'])),
    );
    expect(out, contains('{ 0, 1, 2 }'));
  });

  test('the imported-enum copy carries every field the primary one does', () {
    // spec_extractor rebuilds imported enums field-by-field; a field left out
    // of that copy is lost silently. Compare the two constructions in source
    // so a newly added BridgeEnum field cannot be forgotten again.
    final src = File('lib/src/spec_extractor.dart').readAsStringSync();
    final copy = RegExp(r'\(e\) => BridgeEnum\((.*?)\),\n', dotAll: true).firstMatch(src)?.group(1);
    expect(copy, isNotNull, reason: 'imported-enum copy site not found — did it move?');
    for (final field in ['name:', 'startValue:', 'values:', 'rawValues:']) {
      expect(copy, contains(field), reason: 'imported enums drop \$field');
    }
  });

}
