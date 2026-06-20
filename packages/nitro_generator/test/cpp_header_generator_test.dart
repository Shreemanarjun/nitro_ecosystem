import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_header_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('CppHeaderGenerator', () {
    test('emits #pragma once', () {
      final out = CppHeaderGenerator.generate(simpleSpec());
      expect(out, contains('#pragma once'));
    });

    test('emits ABI version declaration', () {
      final out = CppHeaderGenerator.generate(simpleSpec());
      expect(
        out,
        contains('NITRO_EXPORT uint32_t my_camera_nitro_abi_version(void);'),
      );
    });

    test('emits bridge checksum declaration', () {
      final out = CppHeaderGenerator.generate(simpleSpec());
      expect(
        out,
        contains('NITRO_EXPORT const char* my_camera_nitro_bridge_checksum(void);'),
      );
    });

    test('declares zero-copy typed-data return release symbol', () {
      final out = CppHeaderGenerator.generate(
        BridgeSpec(
          dartClassName: 'Dsp',
          lib: 'dsp',
          namespace: 'dsp',
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'dsp.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'snapshot',
              cSymbol: 'dsp_snapshot',
              isAsync: false,
              returnType: BridgeType(name: 'Uint8List'),
              zeroCopyReturn: true,
              params: [],
            ),
          ],
        ),
      );

      expect(out, contains('NITRO_EXPORT void dsp_release_typed_data_return(void* ptr);'));
    });

    test('TypedData return declarations use uint8_t envelope pointer', () {
      final out = CppHeaderGenerator.generate(
        BridgeSpec(
          dartClassName: 'Dsp',
          lib: 'dsp',
          namespace: 'dsp',
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'dsp.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'samples',
              cSymbol: 'dsp_samples',
              isAsync: false,
              returnType: BridgeType(name: 'Float32List'),
              zeroCopyReturn: true,
              params: [],
            ),
          ],
        ),
      );

      expect(out, contains('NITRO_EXPORT uint8_t* dsp_samples(void);'));
      expect(out, isNot(contains('NITRO_EXPORT float* dsp_samples(void);')));
    });

    test('CppHeaderGenerator emits balanced #ifdef __cplusplus', () {
      final out = CppHeaderGenerator.generate(simpleSpec());
      // Should have two #ifdef __cplusplus and matching ends/closers
      expect(RegExp('#ifdef __cplusplus').allMatches(out).length, 2);
    });

    test('emits struct release functions', () {
      final out = CppHeaderGenerator.generate(structStreamSpec());
      expect(out, contains('NITRO_EXPORT void my_camera_release_CameraFrame(void* ptr);'));
    });
  });
}
