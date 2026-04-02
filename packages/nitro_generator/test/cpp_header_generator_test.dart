import 'package:nitro_generator/src/generators/cpp_header_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('CppHeaderGenerator', () {
    test('emits #pragma once', () {
      final out = CppHeaderGenerator.generate(simpleSpec());
      expect(out, contains('#pragma once'));
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
