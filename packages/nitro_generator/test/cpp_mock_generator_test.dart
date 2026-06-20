import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_mock_generator.dart';
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

    test('iOS-only C++ spec generates mock (not not-applicable)', () {
      final out = CppMockGenerator.generateMockHeader(iosOnlyCppSpec());
      expect(out, isNot(contains('Not applicable')));
      expect(out, contains('class MockIosProcessor'));
    });

    test('Android-only C++ spec generates mock (not not-applicable)', () {
      final out = CppMockGenerator.generateMockHeader(androidOnlyCppSpec());
      expect(out, isNot(contains('Not applicable')));
      expect(out, contains('class MockAndroidProcessor'));
    });

    test('iOS-only C++ test starter registers impl and runs tests', () {
      final out = CppMockGenerator.generateTestStarter(iosOnlyCppSpec());
      expect(out, contains('ios_processor_register_impl'));
      expect(out, contains('RUN_ALL_TESTS()'));
    });

    test('Android-only C++ test starter registers impl', () {
      final out = CppMockGenerator.generateTestStarter(androidOnlyCppSpec());
      expect(out, contains('android_processor_register_impl'));
    });

    test('swift/kotlin spec returns not-applicable for mock', () {
      final out = CppMockGenerator.generateMockHeader(simpleSpec());
      expect(out, contains('Not applicable'));
    });

    test('swift/kotlin spec returns not-applicable for test starter', () {
      final out = CppMockGenerator.generateTestStarter(simpleSpec());
      expect(out, contains('Not applicable'));
    });

    test('cppEnumSpec generates MOCK_METHOD with enum return', () {
      final out = CppMockGenerator.generateMockHeader(cppEnumSpec());
      expect(out, contains('MOCK_METHOD(SensorMode, getMode'));
    });

    test('zero-copy TypedData return mocks as NitroCppBuffer', () {
      final out = CppMockGenerator.generateMockHeader(
        BridgeSpec(
          dartClassName: 'Buffers',
          lib: 'buffers',
          namespace: 'buf',
          iosImpl: NativeImpl.cpp,
          androidImpl: NativeImpl.cpp,
          sourceUri: 'buffers.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'snapshot',
              cSymbol: 'buffers_snapshot',
              isAsync: false,
              returnType: BridgeType(name: 'Uint8List'),
              zeroCopyReturn: true,
              params: [],
            ),
          ],
        ),
      );

      expect(out, contains('MOCK_METHOD(NitroCppBuffer, snapshot, (), (override));'));
    });

    test('cppStreamSpec generates mock extending HybridLidar', () {
      final out = CppMockGenerator.generateMockHeader(cppStreamSpec());
      // Stream emit methods are inherited from HybridLidar, not mocked
      expect(out, contains('class MockLidar : public HybridLidar'));
    });
  });
}
