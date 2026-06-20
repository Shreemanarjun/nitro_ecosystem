import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:nitro_generator/src/generators/generator_metadata.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('NitroAr Regression Tests', () {
    test('Swift: generated bridge has nitro_generator version metadata', () {
      final out = SwiftGenerator.generate(simpleSpec());
      expect(out, contains('// nitro_generator: $nitroGeneratorVersion'));
      expect(out, isNot(contains('// Generator version: 0.3.5')));
    });

    test('Swift: async bool return uses correct Int8 casting', () {
      final spec = BridgeSpec(
        dartClassName: 'Test',
        lib: 'test',
        namespace: 'test',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'test.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'isReady',
            cSymbol: 'test_is_ready',
            isAsync: true,
            returnType: BridgeType(name: 'bool'),
            params: [],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // Verify correct casting to Int8 for async boolean results
      expect(out, contains('return Int8((result ?? false) ? 1 : 0)'));
    });

    test('Swift: Stream<Record> uses .toNative() in unpacker', () {
      final spec = BridgeSpec(
        dartClassName: 'Test',
        lib: 'test',
        namespace: 'test',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'test.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'PackageBoxes',
            fields: [
              BridgeRecordField(name: 'id', dartType: 'String', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
        streams: [
          BridgeStream(
            dartName: 'detectedPackages',
            registerSymbol: 'test_register_packages',
            releaseSymbol: 'test_release_packages',
            itemType: BridgeType(name: 'PackageBoxes', isRecord: true),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      // Verify that records in streams are converted to native pointers
      expect(out, contains('emitCb(dartPort, item.toNative())'));
    });

    test('Swift: structs referenced in record fields get fromReader/writeFields extensions', () {
      final spec = BridgeSpec(
        dartClassName: 'Test',
        lib: 'test',
        namespace: 'test',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'test.native.dart',
        structs: [
          BridgeStruct(
            name: 'PackageDimensions',
            packed: false,
            fields: [
              BridgeField(
                name: 'width',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
        recordTypes: [
          BridgeRecordType(
            name: 'Update',
            fields: [
              BridgeRecordField(
                name: 'dims',
                dartType: 'PackageDimensions',
                kind: RecordFieldKind.recordObject,
                itemTypeName: 'PackageDimensions',
              ),
            ],
          ),
        ],
      );
      final out = RecordGenerator.generateSwift(spec);
      expect(out, contains('extension PackageDimensions {'));
      expect(out, contains('public static func fromReader(_ r: NitroRecordReader) -> PackageDimensions'));
      expect(out, contains('public func writeFields(_ writer: NitroRecordWriter)'));
    });

    test('Record: Uint8List fields use readBlob/writeBlob', () {
      final spec = BridgeSpec(
        dartClassName: 'Test',
        lib: 'test',
        namespace: 'test',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'test.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'RawDepthMap',
            fields: [
              BridgeRecordField(name: 'depthData', dartType: 'Uint8List', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
      );

      // Test Swift generation
      final swiftOut = RecordGenerator.generateSwift(spec);
      expect(swiftOut, contains('writer.writeBlob(depthData)'));
      expect(swiftOut, contains('depthData: r.readBlob()'));

      // Test Dart extensions generation
      final dartOut = RecordGenerator.generateDartExtensions(spec);
      expect(dartOut, contains('writer.writeBlob(depthData)'));
      expect(dartOut, contains('depthData: r.readBlob()'));
    });
  });
}
