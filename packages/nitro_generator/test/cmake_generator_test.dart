import 'package:nitro_generator/src/generators/cmake_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('CMakeGenerator', () {
    test('emits cmake_minimum_required', () {
      final out = CMakeGenerator.generate(simpleSpec());
      expect(out, contains('cmake_minimum_required'));
    });

    test('sets NITRO_MODULE_NAME to lib name', () {
      final out = CMakeGenerator.generate(simpleSpec());
      expect(out, contains('set(NITRO_MODULE_NAME my_camera)'));
    });

    test('emits add_library with module name variable', () {
      final out = CMakeGenerator.generate(simpleSpec());
      expect(out, contains('add_library('));
    });

    test('links android and log', () {
      final out = CMakeGenerator.generate(simpleSpec());
      expect(out, contains('android'));
      expect(out, contains('log'));
    });

    test('lib name in NITRO_MODULE_NAME matches spec.lib', () {
      final out = CMakeGenerator.generate(enumSpec());
      expect(out, contains('set(NITRO_MODULE_NAME complex)'));
    });
  });
}
