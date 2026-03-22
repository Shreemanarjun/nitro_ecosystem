// Tests for Nitrogen generators — no source_gen / dart:mirrors dependencies.
// Each generator is a pure BridgeSpec → String function and can be tested directly.

import 'package:nitro/nitro.dart';
import 'package:nitrogen/src/bridge_spec.dart';
import 'package:nitrogen/src/generators/cpp_bridge_generator.dart';
import 'package:nitrogen/src/generators/dart_ffi_generator.dart';
import 'package:nitrogen/src/generators/kotlin_generator.dart';
import 'package:test/test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

BridgeSpec _simpleSpec() => BridgeSpec(
      dartClassName: 'MyCamera',
      lib: 'my_camera',
      namespace: 'my_camera_module',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'my_camera.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'add',
          cSymbol: 'my_camera_add',
          isAsync: false,
          returnType: BridgeType(name: 'double'),
          params: [
            BridgeParam(name: 'a', type: BridgeType(name: 'double')),
            BridgeParam(name: 'b', type: BridgeType(name: 'double')),
          ],
        ),
        BridgeFunction(
          dartName: 'getGreeting',
          cSymbol: 'my_camera_get_greeting',
          isAsync: true,
          returnType: BridgeType(name: 'String'),
          params: [
            BridgeParam(name: 'name', type: BridgeType(name: 'String')),
          ],
        ),
      ],
    );

BridgeSpec _enumSpec() => BridgeSpec(
      dartClassName: 'ComplexModule',
      lib: 'complex',
      namespace: 'complex_module',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'complex.native.dart',
      enums: [
        BridgeEnum(name: 'DeviceStatus', startValue: 0, values: ['idle', 'running', 'error']),
      ],
      functions: [
        BridgeFunction(
          dartName: 'getStatus',
          cSymbol: 'complex_module_get_status',
          isAsync: false,
          returnType: BridgeType(name: 'DeviceStatus'),
          params: [],
        ),
      ],
      properties: [
        BridgeProperty(
          dartName: 'batteryLevel',
          type: BridgeType(name: 'double'),
          getSymbol: 'complex_module_get_battery_level',
          hasGetter: true,
          hasSetter: false,
        ),
        BridgeProperty(
          dartName: 'config',
          type: BridgeType(name: 'String'),
          getSymbol: 'complex_module_get_config',
          setSymbol: 'complex_module_set_config',
          hasGetter: true,
          hasSetter: true,
        ),
      ],
    );

BridgeSpec _structStreamSpec() => BridgeSpec(
      dartClassName: 'MyCamera',
      lib: 'my_camera',
      namespace: 'my_camera_module',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'my_camera.native.dart',
      structs: [
        BridgeStruct(
          name: 'CameraFrame',
          packed: false,
          fields: [
            BridgeField(name: 'data', type: BridgeType(name: 'Uint8List'), zeroCopy: true),
            BridgeField(name: 'width', type: BridgeType(name: 'int')),
            BridgeField(name: 'height', type: BridgeType(name: 'int')),
            BridgeField(name: 'stride', type: BridgeType(name: 'int')),
            BridgeField(name: 'timestampNs', type: BridgeType(name: 'int')),
          ],
        ),
      ],
      streams: [
        BridgeStream(
          dartName: 'frames',
          registerSymbol: 'my_camera_register_frames_stream',
          releaseSymbol: 'my_camera_release_frames_stream',
          itemType: BridgeType(name: 'CameraFrame'),
          backpressure: Backpressure.dropLatest,
        ),
      ],
    );

BridgeSpec _underscoreLibSpec() => BridgeSpec(
      dartClassName: 'SensorHub',
      lib: 'sensor_hub',
      namespace: 'sensor_hub_module',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'sensor_hub.native.dart',
    );

// ── DartFfiGenerator ─────────────────────────────────────────────────────────

void main() {
  group('DartFfiGenerator', () {
    test('emits part directive', () {
      final out = DartFfiGenerator.generate(_simpleSpec());
      expect(out, contains("part of 'my_camera.native.dart';"));
    });

    test('emits impl class name', () {
      final out = DartFfiGenerator.generate(_simpleSpec());
      expect(out, contains('class _MyCameraImpl extends MyCamera'));
    });

    test('emits loadLib call with correct lib name', () {
      final out = DartFfiGenerator.generate(_simpleSpec());
      expect(out, contains("NitroRuntime.loadLib('my_camera')"));
    });

    test('sync double function uses lookupFunction', () {
      final out = DartFfiGenerator.generate(_simpleSpec());
      expect(out, contains("lookupFunction<Double Function(Double, Double), double Function(double, double)>('my_camera_add')"));
    });

    test('async String function returns NitroRuntime.callAsync', () {
      final out = DartFfiGenerator.generate(_simpleSpec());
      expect(out, contains('NitroRuntime.callAsync'));
    });

    test('enum return type uses Int64 FFI type', () {
      final out = DartFfiGenerator.generate(_enumSpec());
      expect(out, contains('Int64 Function()'));
      expect(out, contains("lookupFunction<Int64 Function(), int Function()>('complex_module_get_status')"));
    });

    test('enum return calls toDeviceStatus()', () {
      final out = DartFfiGenerator.generate(_enumSpec());
      expect(out, contains('.toDeviceStatus()'));
    });

    test('stream register/release pointers emitted', () {
      final out = DartFfiGenerator.generate(_structStreamSpec());
      expect(out, contains("lookupFunction<Void Function(Int64), void Function(int)>('my_camera_register_frames_stream')"));
      expect(out, contains("lookupFunction<Void Function(Int64), void Function(int)>('my_camera_release_frames_stream')"));
    });

    test('struct stream uses NitroRuntime.openStream with fromAddress unpack', () {
      final out = DartFfiGenerator.generate(_structStreamSpec());
      expect(out, contains('NitroRuntime.openStream<CameraFrame>'));
      expect(out, contains('Pointer<CameraFrameFfi>.fromAddress(rawPtr).ref.toDart()'));
    });
  });

  // ── KotlinGenerator ─────────────────────────────────────────────────────────

  group('KotlinGenerator', () {
    test('emits correct package', () {
      final out = KotlinGenerator.generate(_simpleSpec());
      expect(out, contains('package nitro.my_camera_module'));
    });

    test('emits interface with correct name', () {
      final out = KotlinGenerator.generate(_simpleSpec());
      expect(out, contains('interface HybridMyCameraSpec'));
    });

    test('emits JniBridge object', () {
      final out = KotlinGenerator.generate(_simpleSpec());
      expect(out, contains('object MyCameraJniBridge'));
    });

    test('sync double function in interface', () {
      final out = KotlinGenerator.generate(_simpleSpec());
      expect(out, contains('fun add(a: Double, b: Double): Double'));
    });

    test('enum class emitted with nativeValue', () {
      final out = KotlinGenerator.generate(_enumSpec());
      expect(out, contains('enum class DeviceStatus'));
      expect(out, contains('nativeValue'));
    });

    test('enum function in interface uses enum type (not Long)', () {
      final out = KotlinGenerator.generate(_enumSpec());
      expect(out, contains('fun getStatus(): DeviceStatus'));
    });

    test('JniBridge _call for enum returns Long', () {
      final out = KotlinGenerator.generate(_enumSpec());
      expect(out, contains('fun getStatus_call(): Long'));
      expect(out, contains('.nativeValue'));
    });

    test('stream emits Flow<CameraFrame>', () {
      final out = KotlinGenerator.generate(_structStreamSpec());
      expect(out, contains('val frames: Flow<CameraFrame>'));
    });

    test('stream register_call emitted', () {
      final out = KotlinGenerator.generate(_structStreamSpec());
      expect(out, contains('fun my_camera_register_frames_stream_call(dartPort: Long)'));
    });

    test('property val for read-only', () {
      final out = KotlinGenerator.generate(_enumSpec());
      expect(out, contains('val batteryLevel: Double'));
    });

    test('property var for read-write', () {
      final out = KotlinGenerator.generate(_enumSpec());
      expect(out, contains('var config: String'));
    });
  });

  // ── CppBridgeGenerator ───────────────────────────────────────────────────────

  group('CppBridgeGenerator', () {
    test('emits InitDartApiDL', () {
      final out = CppBridgeGenerator.generate(_simpleSpec());
      expect(out, contains('intptr_t InitDartApiDL(void* data)'));
      expect(out, contains('Dart_InitializeApiDL(data)'));
    });

    test('emits JNI_OnLoad with correct lib name', () {
      final out = CppBridgeGenerator.generate(_simpleSpec());
      expect(out, contains('JNI_OnLoad called for my_camera'));
    });

    test('JNI package prefix does NOT have nitro_1 prefix', () {
      final out = CppBridgeGenerator.generate(_simpleSpec());
      // Correct: nitro_my_1camera_1module (underscore in identifier → _1)
      expect(out, contains('nitro_my_1camera_1module'));
      // Wrong form must NOT appear
      expect(out, isNot(contains('nitro_1my_1camera_1module')));
    });

    test('lib with single underscored name produces correct JNI prefix', () {
      // lib='complex' → 'complex_module' → 'complex_1module'
      final out = CppBridgeGenerator.generate(_enumSpec());
      expect(out, contains('nitro_complex_1module'));
      expect(out, isNot(contains('nitro_1complex')));
    });

    test('lib with multi-underscore name produces correct JNI prefix', () {
      // lib='sensor_hub' → 'sensor_hub_module' → 'sensor_1hub_1module'
      final out = CppBridgeGenerator.generate(_underscoreLibSpec());
      expect(out, contains('nitro_sensor_1hub_1module'));
    });

    test('double function calls CallStaticDoubleMethod', () {
      final out = CppBridgeGenerator.generate(_simpleSpec());
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
      // The void function body must use bare `return;`, not `return nullptr;`
      // (note: `return nullptr;` may appear in boilerplate like GetEnv())
      expect(out, contains('if (env == nullptr) return;\n'));
      expect(out, contains('if (methodId == nullptr) { LOGE("Method not found"); return; }'));
    });

    test('enum return uses int64_t and CallStaticLongMethod', () {
      final out = CppBridgeGenerator.generate(_enumSpec());
      expect(out, contains('int64_t complex_module_get_status(void)'));
      expect(out, contains('CallStaticLongMethod'));
    });

    test('property getter emitted', () {
      final out = CppBridgeGenerator.generate(_enumSpec());
      expect(out, contains('double complex_module_get_battery_level(void)'));
      expect(out, contains('CallStaticDoubleMethod'));
    });

    test('property setter emitted', () {
      final out = CppBridgeGenerator.generate(_enumSpec());
      expect(out, contains('void complex_module_set_config(const char* value)'));
    });

    test('struct stream emit uses malloc', () {
      final out = CppBridgeGenerator.generate(_structStreamSpec());
      expect(out, contains('CameraFrame* st_ptr = (CameraFrame*)malloc(sizeof(CameraFrame))'));
      expect(out, contains('pack_CameraFrame_from_jni'));
    });

    test('struct stream emit JNI function name uses correct mangling', () {
      final out = CppBridgeGenerator.generate(_structStreamSpec());
      expect(out, contains('Java_nitro_my_1camera_1module_MyCameraJniBridge_emit_1frames'));
    });

    test('iOS section emits extern _call functions', () {
      final out = CppBridgeGenerator.generate(_simpleSpec());
      expect(out, contains('#elif __APPLE__'));
      expect(out, contains('extern double _call_add(double a, double b)'));
    });

    test('iOS section emits stream register/release', () {
      final out = CppBridgeGenerator.generate(_structStreamSpec());
      expect(out, contains('_register_frames_stream(dart_port'));
      expect(out, contains('_release_frames_stream(dart_port)'));
    });
  });
}
