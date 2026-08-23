// A TypedData VIEW (Int32List.view, sublistView) shares a larger backing
// buffer. `.buffer.asUint8List()` returns the WHOLE buffer, ignoring
// offsetInBytes/lengthInBytes — so a record field holding a view serialised
// its neighbours' bytes too, at the wrong length. The struct codec already got
// this right; the record path did not.
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

BridgeSpec _recordSpec(String dartType, {bool nullable = false}) => BridgeSpec(
  dartClassName: 'M',
  lib: 'm',
  namespace: 'm',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'm.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'R',
      fields: [
        BridgeRecordField(name: 'data', dartType: nullable ? '$dartType?' : dartType, kind: RecordFieldKind.typedData, isNullable: nullable),
      ],
    ),
  ],
);

void main() {
  group('a non-Uint8List view is bounded to the view, not the whole buffer', () {
    for (final t in ['Int32List', 'Float64List', 'Int16List']) {
      test('$t writes offsetInBytes/lengthInBytes', () {
        final out = RecordGenerator.generateDartExtensions(_recordSpec(t));
        expect(out, contains('.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)'), reason: t);
        expect(
          out,
          isNot(contains('.buffer.asUint8List()')),
          reason: '$t: the unbounded form serialises the entire backing buffer',
        );
      });
    }

    test('the nullable form is bounded too', () {
      final out = RecordGenerator.generateDartExtensions(_recordSpec('Int32List', nullable: true));
      expect(out, contains('data!.buffer.asUint8List(data!.offsetInBytes, data!.lengthInBytes)'));
      expect(out, isNot(contains('.buffer.asUint8List()')));
    });
  });

  test('Uint8List is passed through — it is already offset-aware', () {
    // A Uint8List view has correct length and indexing, so writeBlob is right.
    final out = RecordGenerator.generateDartExtensions(_recordSpec('Uint8List'));
    expect(out, isNot(contains('.buffer.asUint8List')));
    expect(out, contains('writeBlob(data'));
  });
}
