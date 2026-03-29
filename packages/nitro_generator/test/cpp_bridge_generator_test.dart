import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('CppBridgeGenerator', () {
    test('emits InitDartApiDL', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('intptr_t my_camera_init_dart_api_dl(void* data)'));
      expect(out, contains('Dart_InitializeApiDL(data)'));
    });

    test('emits JNI_OnLoad with correct lib name', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('JNI_OnLoad called for my_camera'));
    });

    test('JNI package prefix does NOT have nitro_1 prefix', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('nitro_my_1camera_1module'));
      expect(out, isNot(contains('nitro_1my_1camera_1module')));
    });

    test('lib with single underscored name produces correct JNI prefix', () {
      final out = CppBridgeGenerator.generate(enumSpec());
      expect(out, contains('nitro_complex_1module'));
    });

    test('lib with multi-underscore name produces correct JNI prefix', () {
      final out = CppBridgeGenerator.generate(underscoreLibSpec());
      expect(out, contains('nitro_sensor_1hub_1module'));
    });

    test('stream with underscored dartName gets all underscores mangled', () {
      final spec = BridgeSpec(
        dartClassName: 'Hub',
        lib: 'my_hub',
        namespace: 'my_hub_module',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'my_hub.native.dart',
        structs: [
          BridgeStruct(
            name: 'Payload',
            packed: false,
            fields: [
              BridgeField(
                name: 'size',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
        streams: [
          BridgeStream(
            dartName: 'sensor_data',
            registerSymbol: 'my_hub_register_sensor_data_stream',
            releaseSymbol: 'my_hub_release_sensor_data_stream',
            itemType: BridgeType(name: 'Payload'),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(
        out,
        contains('Java_nitro_my_1hub_1module_HubJniBridge_emit_1sensor_1data'),
      );
    });

    test('double function calls CallStaticDoubleMethod', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('CallStaticDoubleMethod'));
    });

    test('void function does not return nullptr', () {
      final spec = BridgeSpec(
        dartClassName: 'MyCamera',
        lib: 'my_camera',
        namespace: 'my_camera_module',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'my_camera.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'doSomething',
            cSymbol: 'my_camera_do_something',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('void my_camera_do_something(void)'));
      expect(out, contains('if (env == nullptr) return;\n'));
      expect(out, contains('if (methodId == nullptr) { LOGE("Method not found"); return; }'));
    });

    test('enum return uses int64_t and CallStaticLongMethod', () {
      final out = CppBridgeGenerator.generate(enumSpec());
      expect(out, contains('int64_t complex_module_get_status(void)'));
      expect(out, contains('CallStaticLongMethod'));
    });

    test('property getter emitted', () {
      final out = CppBridgeGenerator.generate(enumSpec());
      expect(out, contains('double complex_module_get_battery_level(void)'));
    });

    test('property setter emitted', () {
      final out = CppBridgeGenerator.generate(enumSpec());
      expect(out, contains('void complex_module_set_config(const char* value)'));
    });

    test('struct stream emit uses malloc', () {
      final out = CppBridgeGenerator.generate(structStreamSpec());
      expect(out, contains('CameraFrame* st_ptr = (CameraFrame*)malloc(sizeof(CameraFrame))'));
    });

    test('iOS section emits extern _call functions', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('#elif __APPLE__'));
      expect(out, contains('extern double _call_add(double a, double b)'));
    });
  });

  group('CppBridgeGenerator (edge cases)', () {
    test('iOS functions wrap @try in #ifdef __OBJC__', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      final applePart = out.split('#elif __APPLE__')[1];
      expect(applePart, contains('#ifdef __OBJC__'));
      expect(applePart, contains('@try {'));
    });

    test('String return uses strdup and DeleteLocalRef', () {
      final out = CppBridgeGenerator.generate(richSpec());
      expect(out, contains('strdup(nativeStr)'));
      expect(out, contains('DeleteLocalRef(jstr)'));
    });

    test('iOS section emits property getter extern', () {
      final out = CppBridgeGenerator.generate(richSpec());
      expect(out, contains('extern int8_t _call_get_enabled(void)'));
    });
  });

  group('CppBridgeGenerator (cpp direct path)', () {
    test('does not contain JNI_OnLoad for cpp module', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, isNot(contains('JNI_OnLoad')));
    });

    test('includes native.g.h header', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, contains('"math.native.g.h"'));
    });

    test('generates register_impl and get_impl', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, contains('math_register_impl'));
      expect(out, contains('math_get_impl'));
    });

    test('method calls g_impl virtual method', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, contains('g_impl->add('));
    });

    test('NotInitialized guard present', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, contains('NotInitialized'));
    });
  });

  group('CppBridgeGenerator (cpp direct path) — edge cases', () {
    test('bool return type has correct default (false)', () {
      final spec = BridgeSpec(
        dartClassName: 'Flags',
        lib: 'flags',
        namespace: 'flags',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'flags.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'isReady',
            cSymbol: 'flags_is_ready',
            isAsync: false,
            returnType: BridgeType(name: 'bool'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('return false'));
    });

    test('int return type has correct default (0)', () {
      final spec = BridgeSpec(
        dartClassName: 'Counter',
        lib: 'counter',
        namespace: 'counter',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'counter.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'value',
            cSymbol: 'counter_value',
            isAsync: false,
            returnType: BridgeType(name: 'int'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('return 0'));
    });
  });
}
