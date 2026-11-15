import 'package:nitro_generator/src/generators/enum_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('EnumGenerator', () {
    test('Dart extension emits nativeValue getter', () {
      final out = EnumGenerator.generateDartExtensions(enumSpec());
      expect(out, contains('int get nativeValue => index + 0;'));
    });

    test('Dart extension emits toDeviceStatus() on int', () {
      final out = EnumGenerator.generateDartExtensions(enumSpec());
      expect(out, contains('DeviceStatus toDeviceStatus()'));
    });

    test('C enum typedef with SCREAMING_SNAKE values', () {
      final out = EnumGenerator.generateCEnums(enumSpec());
      expect(out, contains('DEVICESTATUS_IDLE = 0,'));
      expect(out, contains('typedef enum {'));
      expect(out, contains('} DeviceStatus;'));
    });

    // One translation unit can reach the bridge header by two paths (a
    // CocoaPods build does), so each enum has to tolerate being seen twice.
    test('C enum is inside its own include guard', () {
      final out = EnumGenerator.generateCEnums(enumSpec());
      final guard = out.indexOf('#ifndef NITRO_ENUM_DEVICESTATUS_DEFINED\n#define NITRO_ENUM_DEVICESTATUS_DEFINED\n');
      expect(guard, isNonNegative);
      expect(out.indexOf('typedef enum {'), greaterThan(guard));
      expect(out.indexOf('#endif // NITRO_ENUM_DEVICESTATUS_DEFINED'), greaterThan(out.indexOf('} DeviceStatus;')));
    });

    test('Kotlin enum class has nativeValue Long field', () {
      final out = EnumGenerator.generateKotlin(enumSpec());
      expect(out, contains('enum class DeviceStatus(val nativeValue: Long)'));
    });

    test('Swift enum uses Int64 raw type', () {
      final out = EnumGenerator.generateSwift(enumSpec());
      expect(out, contains('public enum DeviceStatus: Int64'));
    });
  });
}
