import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('DartFfiGenerator (@HybridRecord)', () {
    test('async single record return decodes via fromNative', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      expect(out, contains('CameraDeviceRecordExt.fromNative'));
    });

    test('async List<record> return uses LazyRecordList.decode + fromReader', () {
      final out = DartFfiGenerator.generate(recordListSpec());
      expect(out, contains('LazyRecordList.decode'));
      expect(out, contains('CameraDeviceRecordExt.fromReader'));
    });

    test('record param uses .toNative(arena)', () {
      final out = DartFfiGenerator.generate(singleRecordSpec());
      expect(out, contains('.toNative(arena)'));
    });
  });
}
