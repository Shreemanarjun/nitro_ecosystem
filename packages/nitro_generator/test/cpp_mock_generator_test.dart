import 'package:nitro_generator/src/generators/cpp_mock_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('CppMockGenerator', () {
    test('generates Mock class extending HybridMath', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec());
      expect(out, contains('class MockMath : public HybridMath'));
    });

    test('MOCK_METHOD for each function', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec());
      expect(out, contains('MOCK_METHOD(double, add, (double a, double b), (override))'));
      expect(out, contains('MOCK_METHOD(std::string, greet, (const std::string& name), (override))'));
    });

    test('MOCK_METHOD for property getter uses const override', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec());
      expect(out, contains('MOCK_METHOD(int64_t, get_precision, (), (const, override))'));
    });

    test('MOCK_METHOD for property setter', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec());
      expect(out, contains('MOCK_METHOD(void, set_precision, (int64_t), (override))'));
    });

    test('includes native.g.h', () {
      final out = CppMockGenerator.generateMockHeader(cppSpec());
      expect(out, contains('"math.native.g.h"'));
    });

    test('returns not-applicable for non-cpp spec', () {
      final out = CppMockGenerator.generateMockHeader(simpleSpec());
      expect(out, contains('Not applicable'));
    });

    test('test starter has smoke test', () {
      final out = CppMockGenerator.generateTestStarter(cppSpec());
      expect(out, contains('TEST(MathTest, SmokeTest)'));
      expect(out, contains('math_register_impl(&mock)'));
    });

    test('test starter has main()', () {
      final out = CppMockGenerator.generateTestStarter(cppSpec());
      expect(out, contains('RUN_ALL_TESTS()'));
    });

    test('test starter includes mock header', () {
      final out = CppMockGenerator.generateTestStarter(cppSpec());
      expect(out, contains('"math.mock.g.h"'));
    });
  });
}
