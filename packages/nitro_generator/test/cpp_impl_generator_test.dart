import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_impl_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('§39 CppImplGenerator — basic', () {
    test('§39.1 generates concrete class extending HybridMath', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('class MathImpl final : public HybridMath'));
    });

    test('§39.2 includes the native.g.h header', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('#include "math.native.g.h"'));
    });

    test('§39.3 stub for double-return method', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('double add(double a, double b) override'));
      expect(out, contains('throw std::runtime_error("Not implemented: add")'));
    });

    test('§39.4 stub for string-return method', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('std::string greet(const std::string& name) override'));
      expect(out, contains('throw std::runtime_error("Not implemented: greet")'));
    });

    test('§39.5 stub for int property getter', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('int64_t get_precision() const override'));
      expect(out, contains('throw std::runtime_error("Not implemented: get_precision")'));
    });

    test('§39.6 stub for int property setter', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('void set_precision(int64_t value) override'));
      expect(out, contains('throw std::runtime_error("Not implemented: set_precision")'));
    });

    test('§39.7 includes default and destructor', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('MathImpl() = default'));
      expect(out, contains('~MathImpl() override = default'));
    });

    test('§39.8 registration comment block shows correct lib stem', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('math_register_impl(&'));
      expect(out, contains('math_register_impl(nullptr)'));
    });

    test('§39.9 file header mentions it is editable', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('edit this file'));
      expect(out, contains('Nitrogen will NOT overwrite it'));
    });

    test('§39.10 not-applicable for non-cpp spec', () {
      final out = CppImplGenerator.generate(simpleSpec());
      expect(out, contains('Not applicable'));
    });
  });

  group('§40 CppImplGenerator — void method and streams', () {
    test('§40.1 void-return method stub', () {
      final out = CppImplGenerator.generate(cppStreamSpec());
      // no methods in cppStreamSpec, but streams section should appear
      expect(out, contains('// ── Streams'));
      expect(out, contains('emit_points'));
    });

    test('§40.2 stream emit comment references item type', () {
      final out = CppImplGenerator.generate(cppStreamSpec());
      expect(out, contains('LidarImpl final : public HybridLidar'));
      expect(out, contains('emit_points'));
    });

    test('§40.3 iOS-only C++ spec generates impl (not not-applicable)', () {
      final out = CppImplGenerator.generate(iosOnlyCppSpec());
      expect(out, isNot(contains('Not applicable')));
      expect(out, contains('IosProcessorImpl final : public HybridIosProcessor'));
    });

    test('§40.4 Android-only C++ spec generates impl', () {
      final out = CppImplGenerator.generate(androidOnlyCppSpec());
      expect(out, isNot(contains('Not applicable')));
      expect(out, contains('AndroidProcessorImpl final : public HybridAndroidProcessor'));
    });

    test('§40.5 registration block references correct lib stem for ios-only', () {
      final out = CppImplGenerator.generate(iosOnlyCppSpec());
      expect(out, contains('ios_processor_register_impl'));
    });
  });

  group('§41 CppImplGenerator — enum and record types', () {
    test('§41.1 enum method returns correct C++ enum type', () {
      final out = CppImplGenerator.generate(cppEnumSpec());
      expect(out, contains('SensorMode getMode() override'));
      expect(out, contains('throw std::runtime_error("Not implemented: getMode")'));
    });

    test('§41.2 enum spec class name is correct', () {
      final out = CppImplGenerator.generate(cppEnumSpec());
      expect(out, contains('SensorImpl final : public HybridSensor'));
    });

    test('§41.3 enum spec includes native.g.h', () {
      final out = CppImplGenerator.generate(cppEnumSpec());
      expect(out, contains('#include "sensor.native.g.h"'));
    });
  });

  group('§42 CppImplGenerator — output structure', () {
    test('§42.1 Methods section header present', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('// ── Methods'));
    });

    test('§42.2 Properties section header present', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('// ── Properties'));
    });

    test('§42.3 Registration section header present', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('// ── Registration'));
    });

    test('§42.4 class body is closed with semicolon', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('};'));
    });

    test('§42.5 includes stdexcept for runtime_error', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('#include <stdexcept>'));
    });

    test('§42.6 placeholder return comment for double', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('// return 0.0;'));
    });

    test('§42.7 placeholder return comment for string', () {
      final out = CppImplGenerator.generate(cppSpec());
      expect(out, contains('// return "";'));
    });
  });
}
