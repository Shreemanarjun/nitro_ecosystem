import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('RecordGenerator', () {
    test('emits extension for each @HybridRecord type', () {
      final out = RecordGenerator.generateDartExtensions(singleRecordSpec());
      expect(out, contains('extension CameraDeviceRecordExt on CameraDevice'));
    });

    test('emits static fromNative factory', () {
      final out = RecordGenerator.generateDartExtensions(singleRecordSpec());
      expect(out, contains('static CameraDevice fromNative(Pointer<Uint8> ptr)'));
    });

    test('emits writeFields method', () {
      final out = RecordGenerator.generateDartExtensions(singleRecordSpec());
      expect(out, contains('void writeFields(RecordWriter w)'));
    });

    test('primitive String field reads via r.readString()', () {
      final out = RecordGenerator.generateDartExtensions(singleRecordSpec());
      expect(out, contains('r.readString()'));
    });

    test('List<@HybridRecord> field uses List.generate + fromReader', () {
      final out = RecordGenerator.generateDartExtensions(recordListSpec());
      expect(out, contains('List.generate(r.readInt32(), (_) => ResolutionRecordExt.fromReader(r))'));
    });
  });
}
