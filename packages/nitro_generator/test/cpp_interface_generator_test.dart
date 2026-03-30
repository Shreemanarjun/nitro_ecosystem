import 'package:nitro_generator/src/generators/cpp_interface_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('CppInterfaceGenerator', () {
    test('generates abstract class with pure-virtual methods', () {
      final out = CppInterfaceGenerator.generate(cppSpec());
      expect(out, contains('class HybridMath'));
      expect(out, contains('virtual double add(double a, double b) = 0;'));
    });

    test('generates property getters/setters', () {
      final out = CppInterfaceGenerator.generate(cppSpec());
      expect(out, contains('virtual int64_t get_precision() const = 0;'));
      expect(out, contains('virtual void set_precision(int64_t value) = 0;'));
    });

    test('generates registration API', () {
      final out = CppInterfaceGenerator.generate(cppSpec());
      expect(out, contains('void math_register_impl(HybridMath* impl);'));
      expect(out, contains('HybridMath* math_get_impl(void);'));
    });

    test('enum param/return uses C type name', () {
      final out = CppInterfaceGenerator.generate(cppEnumSpec());
      expect(out, contains('virtual SensorMode getMode() = 0;'));
    });

    test('includes NitroCppBuffer struct', () {
      final out = CppInterfaceGenerator.generate(cppSpec());
      expect(out, contains('struct NitroCppBuffer'));
    });
  });

  group('CppInterfaceGenerator — edge cases', () {
    test('TypedData param expands to pointer + size_t length', () {
      final spec = BridgeSpec(
        dartClassName: 'Buffers',
        lib: 'buffers',
        namespace: 'buf',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'buffers.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'process',
            cSymbol: 'buffers_process',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'data',
                type: BridgeType(name: 'Uint8List'),
              ),
            ],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('const uint8_t* data'));
      expect(out, contains('size_t data_length'));
    });

    test('struct param uses const T& reference', () {
      final spec = BridgeSpec(
        dartClassName: 'Sensor',
        lib: 'sensor',
        namespace: 'sensor',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'sensor.native.dart',
        structs: [BridgeStruct(name: 'SensorData', packed: true, fields: [])],
        functions: [
          BridgeFunction(
            dartName: 'update',
            cSymbol: 'sensor_update',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'data',
                type: BridgeType(name: 'SensorData'),
              ),
            ],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('const SensorData& data'));
    });

    test('record param and return use NitroCppBuffer', () {
      final spec = BridgeSpec(
        dartClassName: 'Records',
        lib: 'records',
        namespace: 'records',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'records.native.dart',
        recordTypes: [BridgeRecordType(name: 'Config', fields: [])],
        functions: [
          BridgeFunction(
            dartName: 'configure',
            cSymbol: 'records_configure',
            isAsync: false,
            returnType: BridgeType(name: 'Config'),
            params: [
              BridgeParam(
                name: 'cfg',
                type: BridgeType(name: 'Config'),
              ),
            ],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('virtual NitroCppBuffer configure(NitroCppBuffer cfg) = 0;'));
    });

    test('header guard is derived from lib name in uppercase', () {
      final out = CppInterfaceGenerator.generate(cppSpec());
      expect(out, contains('#ifndef MATH_NATIVE_G_H'));
    });

    test('registration API wrapped in extern C guard', () {
      final out = CppInterfaceGenerator.generate(cppSpec());
      expect(out, contains('#ifdef __cplusplus\nextern "C" {'));
    });

    test('List<T> with isRecord=true maps to NitroCppBuffer', () {
      final spec = BridgeSpec(
        dartClassName: 'Registry',
        lib: 'registry',
        namespace: 'registry',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'registry.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'listDevices',
            cSymbol: 'registry_list_devices',
            isAsync: false,
            returnType: BridgeType(name: 'List<Device>', isRecord: true),
            params: [],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('virtual NitroCppBuffer listDevices() = 0;'));
    });

    test('recordNames fallback still works', () {
      final spec = BridgeSpec(
        dartClassName: 'Service',
        lib: 'service',
        namespace: 'service',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'service.native.dart',
        recordTypes: [BridgeRecordType(name: 'Payload', fields: [])],
        functions: [
          BridgeFunction(
            dartName: 'process',
            cSymbol: 'service_process',
            isAsync: false,
            returnType: BridgeType(name: 'Payload'),
            params: [],
          ),
        ],
      );
      final out = CppInterfaceGenerator.generate(spec);
      expect(out, contains('virtual NitroCppBuffer process() = 0;'));
    });
  });
}
