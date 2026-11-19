// The Swift record writer builds the record in the block Dart receives.
// tool/verify_record_wire.dart compiles and runs it; this pins the shape.
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  final swift = RecordGenerator.generateSwift(
    BridgeSpec(
      dartClassName: 'M',
      lib: 'm',
      namespace: 'm',
      iosImpl: NativeImpl.swift,
      sourceUri: 'm.native.dart',
      recordTypes: [
        BridgeRecordType(name: 'Item', fields: [BridgeRecordField(name: 'id', dartType: 'int', kind: RecordFieldKind.primitive)]),
      ],
    ),
  );

  test('toNative hands the writer\'s own block over instead of copying into a new one', () {
    expect(swift, contains('private var block: UnsafeMutablePointer<UInt8>?'));
    expect(swift, contains('block = realloc(block, 4 + capacity)!.assumingMemoryBound(to: UInt8.self)'));
    expect(swift, contains('let out = block'));
    expect(swift, isNot(contains('UnsafeMutablePointer<UInt8>.allocate(capacity: total)')));
    // nitrogen link finds the boilerplate by this exact line.
    expect(swift, contains('\npublic class NitroRecordWriter {'));
  });

  test('an indexed list is written by one writer with a back-filled offset table', () {
    expect(swift, contains('_ = w.room(8 * items.count)'));
    expect(swift, isNot(contains('var blobs: [[UInt8]] = []')));
  });

  test('the payload is still readable as bytes', () {
    expect(swift, contains('public var bytes: [UInt8] {'));
  });
}
