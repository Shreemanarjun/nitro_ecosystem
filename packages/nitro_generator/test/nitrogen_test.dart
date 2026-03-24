// Tests for Nitrogen generators — no source_gen / dart:mirrors dependencies.
// Each generator is a pure BridgeSpec → String function and can be tested directly.

import 'package:nitro/nitro.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/spec_validator.dart';
import 'package:nitro_generator/src/generators/cmake_generator.dart';
import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/cpp_header_generator.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/enum_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:nitro_generator/src/generators/struct_generator.dart';
import 'package:nitro_generator/src/generators/swift_generator.dart';
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
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'double'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'getGreeting',
      cSymbol: 'my_camera_get_greeting',
      isAsync: true,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'name',
          type: BridgeType(name: 'String'),
        ),
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
    BridgeEnum(
      name: 'DeviceStatus',
      startValue: 0,
      values: ['idle', 'running', 'error'],
    ),
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
        BridgeField(
          name: 'data',
          type: BridgeType(name: 'Uint8List'),
          zeroCopy: true,
        ),
        BridgeField(
          name: 'width',
          type: BridgeType(name: 'int'),
        ),
        BridgeField(
          name: 'height',
          type: BridgeType(name: 'int'),
        ),
        BridgeField(
          name: 'stride',
          type: BridgeType(name: 'int'),
        ),
        BridgeField(
          name: 'timestampNs',
          type: BridgeType(name: 'int'),
        ),
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

// Spec with bools, strings, int, async enum, struct param, property setter
BridgeSpec _richSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  enums: [
    BridgeEnum(
      name: 'SensorMode',
      startValue: 0,
      values: ['off', 'low', 'high'],
    ),
  ],
  structs: [
    BridgeStruct(
      name: 'Reading',
      packed: false,
      fields: [
        BridgeField(
          name: 'value',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'valid',
          type: BridgeType(name: 'bool'),
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'isReady',
      cSymbol: 'sensor_is_ready',
      isAsync: false,
      returnType: BridgeType(name: 'bool'),
      params: [
        BridgeParam(
          name: 'strict',
          type: BridgeType(name: 'bool'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'count',
      cSymbol: 'sensor_count',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'label',
      cSymbol: 'sensor_label',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'id',
          type: BridgeType(name: 'String'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'getMode',
      cSymbol: 'sensor_get_mode',
      isAsync: false,
      returnType: BridgeType(name: 'SensorMode'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'fetchReading',
      cSymbol: 'sensor_fetch_reading',
      isAsync: true,
      returnType: BridgeType(name: 'Reading'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'push',
      cSymbol: 'sensor_push',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'r',
          type: BridgeType(name: 'Reading'),
        ),
      ],
    ),
  ],
  properties: [
    BridgeProperty(
      dartName: 'enabled',
      type: BridgeType(name: 'bool'),
      getSymbol: 'sensor_get_enabled',
      setSymbol: 'sensor_set_enabled',
      hasGetter: true,
      hasSetter: true,
    ),
    BridgeProperty(
      dartName: 'mode',
      type: BridgeType(name: 'SensorMode'),
      getSymbol: 'sensor_get_mode_prop',
      setSymbol: 'sensor_set_mode_prop',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'ticks',
      registerSymbol: 'sensor_register_ticks_stream',
      releaseSymbol: 'sensor_release_ticks_stream',
      itemType: BridgeType(name: 'double'),
      backpressure: Backpressure.dropLatest,
    ),
    BridgeStream(
      dartName: 'counts',
      registerSymbol: 'sensor_register_counts_stream',
      releaseSymbol: 'sensor_release_counts_stream',
      itemType: BridgeType(name: 'int'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// Async enum return (no arena needed)
BridgeSpec _asyncEnumSpec() => BridgeSpec(
  dartClassName: 'Device',
  lib: 'device',
  namespace: 'device',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'device.native.dart',
  enums: [
    BridgeEnum(name: 'State', startValue: 0, values: ['idle', 'running']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fetchState',
      cSymbol: 'device_fetch_state',
      isAsync: true,
      returnType: BridgeType(name: 'State'),
      params: [],
    ),
  ],
);

// ── @HybridRecord helpers ─────────────────────────────────────────────────────

/// Spec with a single @HybridRecord type (flat primitives/strings only).
/// Contains an async return and a sync record param.
BridgeSpec _singleRecordSpec() => BridgeSpec(
  dartClassName: 'CameraModule',
  lib: 'camera_module',
  namespace: 'camera_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'camera_module.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'CameraDevice',
      fields: [
        BridgeRecordField(
          name: 'id',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'name',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'isFrontFacing',
          dartType: 'bool',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getDevice',
      cSymbol: 'camera_module_get_device',
      isAsync: true,
      returnType: BridgeType(name: 'CameraDevice', isRecord: true),
      params: [],
    ),
    BridgeFunction(
      dartName: 'setDevice',
      cSymbol: 'camera_module_set_device',
      isAsync: false,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'device',
          type: BridgeType(name: 'CameraDevice', isRecord: true),
        ),
      ],
    ),
  ],
);

/// Spec with nested @HybridRecord types and a List<@HybridRecord> return.
BridgeSpec _recordListSpec() => BridgeSpec(
  dartClassName: 'CameraModule',
  lib: 'camera_module',
  namespace: 'camera_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'camera_module.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'Resolution',
      fields: [
        BridgeRecordField(
          name: 'width',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'height',
          dartType: 'int',
          kind: RecordFieldKind.primitive,
        ),
      ],
    ),
    BridgeRecordType(
      name: 'CameraDevice',
      fields: [
        BridgeRecordField(
          name: 'id',
          dartType: 'String',
          kind: RecordFieldKind.primitive,
        ),
        BridgeRecordField(
          name: 'resolutions',
          dartType: 'List<Resolution>',
          kind: RecordFieldKind.listRecordObject,
          itemTypeName: 'Resolution',
        ),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getAvailableDevices',
      cSymbol: 'camera_module_get_available_devices',
      isAsync: true,
      returnType: BridgeType(
        name: 'List<CameraDevice>',
        isRecord: true,
        recordListItemType: 'CameraDevice',
      ),
      params: [],
    ),
  ],
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
      expect(
        out,
        contains(
          "lookupFunction<Double Function(Double, Double), double Function(double, double)>('my_camera_add')",
        ),
      );
    });

    test('async String function returns NitroRuntime.callAsync', () {
      final out = DartFfiGenerator.generate(_simpleSpec());
      expect(out, contains('NitroRuntime.callAsync'));
    });

    test('enum return type uses Int64 FFI type', () {
      final out = DartFfiGenerator.generate(_enumSpec());
      expect(out, contains('Int64 Function()'));
      expect(
        out,
        contains(
          "lookupFunction<Int64 Function(), int Function()>('complex_module_get_status')",
        ),
      );
    });

    test('enum return calls toDeviceStatus()', () {
      final out = DartFfiGenerator.generate(_enumSpec());
      expect(out, contains('.toDeviceStatus()'));
    });

    test('stream register/release pointers emitted', () {
      final out = DartFfiGenerator.generate(_structStreamSpec());
      expect(
        out,
        contains(
          "lookupFunction<Void Function(Int64), void Function(int)>('my_camera_register_frames_stream')",
        ),
      );
      expect(
        out,
        contains(
          "lookupFunction<Void Function(Int64), void Function(int)>('my_camera_release_frames_stream')",
        ),
      );
    });

    test(
      'struct stream uses NitroRuntime.openStream with fromAddress unpack',
      () {
        final out = DartFfiGenerator.generate(_structStreamSpec());
        expect(out, contains('NitroRuntime.openStream<CameraFrame>'));
        expect(
          out,
          contains('Pointer<CameraFrameFfi>.fromAddress(rawPtr).ref.toDart()'),
        );
      },
    );
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
      expect(
        out,
        contains('fun my_camera_register_frames_stream_call(dartPort: Long)'),
      );
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

    test('stream with underscored dartName gets all underscores mangled', () {
      // dartName='sensor_data' → emit method → 'emit_sensor_data'
      // JNI mangle: 'emit_1sensor_1data' (NOT 'emit_1sensor_data')
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
      // All underscores in every component must be mangled
      expect(
        out,
        contains('Java_nitro_my_1hub_1module_HubJniBridge_emit_1sensor_1data'),
      );
      expect(out, isNot(contains('emit_1sensor_data(')));
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
      expect(
        out,
        contains(
          'if (methodId == nullptr) { LOGE("Method not found"); return; }',
        ),
      );
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
      expect(
        out,
        contains('void complex_module_set_config(const char* value)'),
      );
    });

    test('struct stream emit uses malloc', () {
      final out = CppBridgeGenerator.generate(_structStreamSpec());
      expect(
        out,
        contains(
          'CameraFrame* st_ptr = (CameraFrame*)malloc(sizeof(CameraFrame))',
        ),
      );
      expect(out, contains('pack_CameraFrame_from_jni'));
    });

    test('struct stream emit JNI function name uses correct mangling', () {
      final out = CppBridgeGenerator.generate(_structStreamSpec());
      expect(
        out,
        contains(
          'Java_nitro_my_1camera_1module_MyCameraJniBridge_emit_1frames',
        ),
      );
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

  // ── SpecValidator ─────────────────────────────────────────────────────────

  group('SpecValidator', () {
    test('valid simple spec produces no issues', () {
      expect(SpecValidator.validate(_simpleSpec()), isEmpty);
    });

    test('valid enum spec produces no issues', () {
      expect(SpecValidator.validate(_enumSpec()), isEmpty);
    });

    test('valid struct stream spec produces no issues', () {
      expect(SpecValidator.validate(_structStreamSpec()), isEmpty);
    });

    test('unknown return type emits UNKNOWN_RETURN_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'bar',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'MyUnknownType'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'UNKNOWN_RETURN_TYPE' && i.isError),
        isTrue,
      );
    });

    test('unknown parameter type emits UNKNOWN_PARAM_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'bar',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'x',
                type: BridgeType(name: 'UnknownStruct'),
              ),
            ],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'UNKNOWN_PARAM_TYPE' && i.isError),
        isTrue,
      );
    });

    test('known @HybridEnum in return produces no error', () {
      expect(
        SpecValidator.validate(_enumSpec()).where((i) => i.isError),
        isEmpty,
      );
    });

    test('known @HybridStruct in stream produces no error', () {
      expect(
        SpecValidator.validate(_structStreamSpec()).where((i) => i.isError),
        isEmpty,
      );
    });

    test('duplicate C symbols emit DUPLICATE_SYMBOL error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'a',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
          BridgeFunction(
            dartName: 'b',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'DUPLICATE_SYMBOL' && i.isError),
        isTrue,
      );
    });

    test('sync struct return emits SYNC_STRUCT_RETURN warning (not error)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Result',
            packed: false,
            fields: [
              BridgeField(
                name: 'value',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'get',
            cSymbol: 'foo_get',
            isAsync: false,
            returnType: BridgeType(name: 'Result'),
            params: [],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      final w = issues.where((i) => i.code == 'SYNC_STRUCT_RETURN').toList();
      expect(w, hasLength(1));
      expect(w.first.isError, isFalse);
    });

    test('zero_copy on non-Uint8List field emits INVALID_ZERO_COPY error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Bad',
            packed: false,
            fields: [
              BridgeField(
                name: 'count',
                type: BridgeType(name: 'int'),
                zeroCopy: true,
              ),
            ],
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'INVALID_ZERO_COPY' && i.isError),
        isTrue,
      );
    });

    test('unknown stream item type emits UNKNOWN_STREAM_ITEM_TYPE error', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        streams: [
          BridgeStream(
            dartName: 'events',
            registerSymbol: 'foo_register_events_stream',
            releaseSymbol: 'foo_release_events_stream',
            itemType: BridgeType(name: 'SomeComplexClass'),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final issues = SpecValidator.validate(spec);
      expect(
        issues.any((i) => i.code == 'UNKNOWN_STREAM_ITEM_TYPE' && i.isError),
        isTrue,
      );
    });

    test(
      'invalid struct field type (List<int>) emits INVALID_STRUCT_FIELD_TYPE error',
      () {
        final spec = BridgeSpec(
          dartClassName: 'Foo',
          lib: 'foo',
          namespace: 'foo',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'foo.native.dart',
          structs: [
            BridgeStruct(
              name: 'Wrapper',
              packed: false,
              fields: [
                BridgeField(
                  name: 'items',
                  type: BridgeType(name: 'List<int>'),
                ),
              ],
            ),
          ],
        );
        final issues = SpecValidator.validate(spec);
        expect(
          issues.any((i) => i.code == 'INVALID_STRUCT_FIELD_TYPE' && i.isError),
          isTrue,
        );
      },
    );

    test('error issues carry actionable hints', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'bar',
            cSymbol: 'foo_bar',
            isAsync: false,
            returnType: BridgeType(name: 'MissingType'),
            params: [],
          ),
        ],
      );
      final errors = SpecValidator.validate(
        spec,
      ).where((i) => i.isError).toList();
      expect(errors, isNotEmpty);
      expect(errors.first.hint, isNotNull);
      expect(errors.first.hint, isNotEmpty);
    });
  });

  // ── DartFfiGenerator — additional edge cases ──────────────────────────────

  group('DartFfiGenerator (edge cases)', () {
    test('bool return converts via != 0', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('return _isReadyPtr(strict ? 1 : 0) != 0;'));
    });

    test('bool param passes value ? 1 : 0', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('strict ? 1 : 0'));
    });

    test('int return is passed through directly', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('return _countPtr();'));
    });

    test('String return calls toDartStringWithFree', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('toDartStringWithFree()'));
    });

    test('String param uses toNativeUtf8 inside withArena', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('toNativeUtf8(allocator: arena)'));
      expect(out, contains('withArena'));
    });

    test('async struct return uses Pointer<ReadingFfi>.fromAddress', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('Pointer<ReadingFfi>.fromAddress'));
    });

    test('struct param uses toNative(arena).cast<Void>()', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('.toNative(arena).cast<Void>()'));
    });

    test('async enum return calls toState()', () {
      final out = DartFfiGenerator.generate(_asyncEnumSpec());
      expect(out, contains('.toState()'));
    });

    test('property with setter emits set accessor', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('set enabled('));
    });

    test('property bool getter converts != 0', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(
        out,
        contains(
          'bool get enabled { checkDisposed(); return _getEnabledPtr() != 0; }',
        ),
      );
    });

    test('property enum getter calls toSensorMode()', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('.toSensorMode()'));
    });

    test('property bool setter converts value ? 1 : 0', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(
        out,
        contains(
          'set enabled(bool value) { checkDisposed(); _setEnabledPtr(value ? 1 : 0); }',
        ),
      );
    });

    test('property enum setter passes nativeValue', () {
      final out = DartFfiGenerator.generate(_richSpec());
      // pointer name = _set{Cap(dartName)}Ptr; dartName='mode' → _setModePtr
      expect(out, contains('_setModePtr(value.nativeValue)'));
    });

    test('dispose() override is emitted in generated impl', () {
      final out = DartFfiGenerator.generate(_simpleSpec());
      expect(
        out,
        contains(
          '@override\n  // ignore: unnecessary_overrides\n  void dispose() {',
        ),
      );
      expect(out, contains('super.dispose();'));
    });

    test('methods have checkDisposed() guard', () {
      final out = DartFfiGenerator.generate(_simpleSpec());
      // add(double, double) should guard
      expect(out, contains('checkDisposed();'));
    });

    test('stream getter has checkDisposed() guard', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('Stream<double> get ticks {\n    checkDisposed();'));
    });

    test('property getter has checkDisposed() in block body', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('{ checkDisposed();'));
    });

    test('primitive double stream uses direct rawPtr cast', () {
      final out = DartFfiGenerator.generate(_richSpec());
      // double stream item: unpack is cast to double
      expect(out, contains('(rawPtr) => rawPtr as double'));
    });

    test('primitive int stream uses direct rawPtr cast', () {
      final out = DartFfiGenerator.generate(_richSpec());
      expect(out, contains('(rawPtr) => rawPtr as int'));
    });
  });

  // ── KotlinGenerator — additional edge cases ───────────────────────────────

  group('KotlinGenerator (edge cases)', () {
    test('async function emits suspend fun in interface', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(out, contains('suspend fun fetchReading(): Reading'));
    });

    test('async function JniBridge uses runBlocking', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(out, contains('runBlocking'));
    });

    test('bool type maps to Boolean', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(out, contains('fun isReady(strict: Boolean): Boolean'));
    });

    test('int type maps to Long', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(out, contains('fun count(): Long'));
    });

    test('struct data class emitted', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(out, contains('data class Reading('));
    });

    test('struct data class emits @Keep', () {
      final out = KotlinGenerator.generate(_richSpec());
      // @Keep must appear before data class
      final keepIdx = out.indexOf('@Keep\ndata class Reading');
      expect(keepIdx, greaterThanOrEqualTo(0));
    });

    test('property setter with bool type var in interface', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(out, contains('var enabled: Boolean'));
    });

    test('property setter with enum uses fromNative in JniBridge', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(out, contains('SensorMode.fromNative(value)'));
    });

    test('stream external emit fun emitted', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(
        out,
        contains('external fun emit_ticks(dartPort: Long, item: Double)'),
      );
    });

    test('stream jobs map declared', () {
      final out = KotlinGenerator.generate(_richSpec());
      expect(out, contains('_streamJobs'));
    });
  });

  // ── CppBridgeGenerator — additional edge cases ────────────────────────────

  group('CppBridgeGenerator (edge cases)', () {
    test('String return uses strdup and DeleteLocalRef', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('strdup(nativeStr)'));
      expect(out, contains('DeleteLocalRef(jstr)'));
    });

    test('String param uses NewStringUTF and DeleteLocalRef', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('NewStringUTF(id)'));
      expect(out, contains('DeleteLocalRef(j_id)'));
    });

    test('bool return calls CallStaticBooleanMethod', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('CallStaticBooleanMethod'));
    });

    test('int return calls CallStaticLongMethod', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('CallStaticLongMethod(g_bridgeClass, methodId)'));
    });

    test('struct param calls unpack_Reading_to_jni', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('unpack_Reading_to_jni'));
    });

    test('primitive double stream uses Dart_CObject_kDouble', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('Dart_CObject_kDouble'));
      expect(out, contains('as_double = item'));
    });

    test('primitive int stream uses Dart_CObject_kInt64', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('Dart_CObject_kInt64'));
      expect(out, contains('as_int64 = item'));
    });

    test('iOS section emits property getter extern', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      // bool maps to int8_t in C
      expect(out, contains('extern int8_t _call_get_enabled(void)'));
    });

    test('iOS section emits property setter extern', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('extern void _call_set_enabled(int8_t value)'));
    });

    test('pack_Reading_from_jni helper emitted for Android', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('static Reading pack_Reading_from_jni'));
    });

    test('unpack_Reading_to_jni helper emitted for Android', () {
      final out = CppBridgeGenerator.generate(_richSpec());
      expect(out, contains('static jobject unpack_Reading_to_jni'));
    });
  });

  // ── CppHeaderGenerator ────────────────────────────────────────────────────

  group('CppHeaderGenerator', () {
    test('emits #pragma once', () {
      final out = CppHeaderGenerator.generate(_simpleSpec());
      expect(out, startsWith('#pragma once'));
    });

    test('emits extern C block', () {
      final out = CppHeaderGenerator.generate(_simpleSpec());
      expect(out, contains('extern "C"'));
    });

    test('double function declaration in methods section', () {
      final out = CppHeaderGenerator.generate(_simpleSpec());
      expect(out, contains('double my_camera_add(double a, double b);'));
    });

    test('enum return type is int64_t not void*', () {
      final out = CppHeaderGenerator.generate(_enumSpec());
      expect(out, contains('int64_t complex_module_get_status(void);'));
      expect(out, isNot(contains('void* complex_module_get_status')));
    });

    test('void function declared correctly', () {
      final out = CppHeaderGenerator.generate(_richSpec());
      expect(out, contains('void sensor_push(void* r);'));
    });

    test('struct param declared as void*', () {
      final out = CppHeaderGenerator.generate(_richSpec());
      // struct params passed as void* in C header
      expect(out, contains('void* r'));
    });

    test(
      'non-enum property getter keeps its native type (double stays double)',
      () {
        final out = CppHeaderGenerator.generate(_enumSpec());
        expect(out, contains('double complex_module_get_battery_level(void);'));
        expect(
          out,
          isNot(contains('int64_t complex_module_get_battery_level')),
        );
      },
    );

    test('stream register and release declared', () {
      final out = CppHeaderGenerator.generate(_structStreamSpec());
      expect(
        out,
        contains('void my_camera_register_frames_stream(int64_t dart_port);'),
      );
      expect(
        out,
        contains('void my_camera_release_frames_stream(int64_t dart_port);'),
      );
    });

    test('C enum typedef emitted', () {
      final out = CppHeaderGenerator.generate(_enumSpec());
      expect(out, contains('typedef enum {'));
      expect(out, contains('} DeviceStatus;'));
    });

    test('C struct typedef emitted', () {
      final out = CppHeaderGenerator.generate(_structStreamSpec());
      expect(out, contains('typedef struct {'));
      expect(out, contains('} CameraFrame;'));
    });

    test('packed struct uses pragma pack', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Tight',
            packed: true,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = CppHeaderGenerator.generate(spec);
      expect(out, contains('#pragma pack(push, 1)'));
      expect(out, contains('#pragma pack(pop)'));
    });

    test('spec with no functions emits no Methods section', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
      );
      final out = CppHeaderGenerator.generate(spec);
      expect(out, isNot(contains('// Methods')));
    });
  });

  // ── CMakeGenerator ────────────────────────────────────────────────────────

  group('CMakeGenerator', () {
    test('emits cmake_minimum_required', () {
      final out = CMakeGenerator.generate(_simpleSpec());
      expect(out, contains('cmake_minimum_required'));
    });

    test('sets NITRO_MODULE_NAME to lib name', () {
      final out = CMakeGenerator.generate(_simpleSpec());
      expect(out, contains('set(NITRO_MODULE_NAME my_camera)'));
    });

    test('emits add_library with module name variable', () {
      final out = CMakeGenerator.generate(_simpleSpec());
      expect(out, contains('add_library('));
    });

    test('links android and log', () {
      final out = CMakeGenerator.generate(_simpleSpec());
      expect(out, contains('android'));
      expect(out, contains('log'));
    });

    test('lib name in NITRO_MODULE_NAME matches spec.lib', () {
      final out = CMakeGenerator.generate(_enumSpec());
      expect(out, contains('set(NITRO_MODULE_NAME complex)'));
    });
  });

  // ── SwiftGenerator ────────────────────────────────────────────────────────

  group('SwiftGenerator', () {
    test('emits import Foundation and Combine', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      expect(out, contains('import Foundation'));
      expect(out, contains('import Combine'));
    });

    test('emits protocol with correct name', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      expect(out, contains('public protocol HybridMyCameraProtocol'));
    });

    test('sync function in protocol', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      expect(out, contains('func add(a: Double, b: Double) -> Double'));
    });

    test('async function uses async throws in protocol', () {
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('async throws'));
    });

    test('stream uses AnyPublisher in protocol', () {
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('AnyPublisher<Double, Never>'));
    });

    test('property with getter+setter uses get set syntax', () {
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('{ get set }'));
    });

    test('property read-only uses get syntax', () {
      final out = SwiftGenerator.generate(_enumSpec());
      expect(out, contains('{ get }'));
    });

    test('registry class emitted', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      expect(out, contains('class MyCameraRegistry'));
    });

    test('_call_ stub uses @_cdecl attribute', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      expect(out, contains('@_cdecl("_call_add")'));
    });

    test('_call_ stub is a top-level func (not static)', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      expect(out, contains('public func _call_add('));
      expect(out, isNot(contains('static func _call_add')));
    });

    test('registry class has no @objc or NSObject', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      expect(out, isNot(contains('@objc')));
      expect(out, isNot(contains('NSObject')));
    });

    test('bool return type uses Int8 in @_cdecl stub', () {
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('@_cdecl("_call_isReady")'));
      expect(out, contains('public func _call_isReady('));
      expect(out, contains('-> Int8'));
      expect(out, contains('? 1 : 0'));
    });

    test('sync struct return type uses UnsafeMutableRawPointer?', () {
      // _richSpec() has sync struct return: push() returns void but has struct param
      // Use a spec with sync struct return explicitly
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Result',
            packed: false,
            fields: [
              BridgeField(
                name: 'value',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getResult',
            cSymbol: 'foo_get_result',
            isAsync: false,
            returnType: BridgeType(name: 'Result'),
            params: [],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('@_cdecl("_call_getResult")'));
      expect(out, contains('-> UnsafeMutableRawPointer?'));
      expect(
        out,
        contains('UnsafeMutablePointer<Result>.allocate(capacity: 1)'),
      );
      expect(out, contains('ptr.initialize(to: result)'));
      expect(out, contains('return UnsafeMutableRawPointer(ptr)'));
    });

    test('async struct return uses DispatchSemaphore + Task.detached', () {
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('@_cdecl("_call_fetchReading")'));
      expect(out, contains('DispatchSemaphore(value: 0)'));
      expect(out, contains('Task.detached'));
      expect(out, contains('sema.signal()'));
      expect(out, contains('sema.wait()'));
      expect(out, contains('-> UnsafeMutableRawPointer?'));
    });

    test('async void return uses DispatchSemaphore pattern', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'doAsync',
            cSymbol: 'foo_do_async',
            isAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final out = SwiftGenerator.generate(spec);
      expect(out, contains('@_cdecl("_call_doAsync")'));
      expect(out, contains('DispatchSemaphore(value: 0)'));
      expect(out, contains('Task.detached'));
      expect(out, contains('sema.wait()'));
    });

    test('async String return uses strdup + empty string fallback', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      // getGreeting is async String
      expect(out, contains('@_cdecl("_call_getGreeting")'));
      expect(out, contains('DispatchSemaphore(value: 0)'));
      // New correct pattern: var result = "" (not String? = nil)
      expect(out, contains('var result = ""'));
      expect(out, contains('return strdup(result)'));
      // Guard when impl is nil must return strdup(""), not nil
      expect(out, contains('return strdup("")'));
    });

    // ── String C-ABI type correctness ─────────────────────────────────────────

    test('String param in @_cdecl uses UnsafePointer<CChar>? not String', () {
      // _simpleSpec().getGreeting has param name: String
      final out = SwiftGenerator.generate(_simpleSpec());
      expect(out, contains('_ name: UnsafePointer<CChar>?'));
      // Bare "String" must NOT appear as a @_cdecl param type
      expect(out, isNot(contains('_ name: String')));
    });

    test(
      'async String return type is UnsafeMutablePointer<CChar>? not String',
      () {
        final out = SwiftGenerator.generate(_simpleSpec());
        // getGreeting async -> String: return type must be C pointer
        expect(out, contains('-> UnsafeMutablePointer<CChar>?'));
        // Swift's fat String must NOT appear as @_cdecl return type
        final cdeclLine = out
            .split('\n')
            .where((l) => l.contains('public func _call_getGreeting('))
            .join();
        expect(cdeclLine, isNot(contains('-> String')));
      },
    );

    test('String param conversion emitted before call', () {
      final out = SwiftGenerator.generate(_simpleSpec());
      // Conversion: UnsafePointer<CChar>? -> Swift String
      expect(
        out,
        contains('let nameStr = name.map { String(cString: \$0) } ?? ""'),
      );
      // callArgs must use converted local var, not the raw pointer
      expect(out, contains('name: nameStr'));
    });

    test('sync String return uses strdup', () {
      // _richSpec().label() is sync String param + String return
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('@_cdecl("_call_label")'));
      expect(out, contains('return strdup('));
    });

    test('sync String return does not directly return Swift String', () {
      final out = SwiftGenerator.generate(_richSpec());
      // Ensure the sync label stub doesn't "return impl?.label(...)" bare
      final labelLines = out
          .split('\n')
          .skipWhile((l) => !l.contains('@_cdecl("_call_label")'))
          .take(10)
          .join('\n');
      expect(labelLines, contains('strdup('));
      expect(labelLines, isNot(contains('return SensorRegistry.impl?.label')));
    });

    test('String property getter returns UnsafeMutablePointer<CChar>?', () {
      // _enumSpec().config is a String read-write property
      final out = SwiftGenerator.generate(_enumSpec());
      expect(out, contains('@_cdecl("_call_get_config")'));
      expect(
        out,
        contains(
          'public func _call_get_config() -> UnsafeMutablePointer<CChar>?',
        ),
      );
    });

    test('String property getter uses strdup', () {
      final out = SwiftGenerator.generate(_enumSpec());
      // Must use strdup to malloc-allocate the returned C string
      final getLines = out
          .split('\n')
          .skipWhile((l) => !l.contains('@_cdecl("_call_get_config")'))
          .take(5)
          .join('\n');
      expect(getLines, contains('strdup('));
    });

    test('String property setter param is UnsafePointer<CChar>?', () {
      final out = SwiftGenerator.generate(_enumSpec());
      expect(out, contains('@_cdecl("_call_set_config")'));
      expect(
        out,
        contains(
          'public func _call_set_config(_ value: UnsafePointer<CChar>?)',
        ),
      );
    });

    test('String property setter converts with String(cString:)', () {
      final out = SwiftGenerator.generate(_enumSpec());
      expect(out, contains('value.map { String(cString: \$0) } ?? ""'));
    });

    test('no @_cdecl function uses bare Swift String as param or return', () {
      // Regression: ensure the generator never emits String as a @_cdecl type
      final out = SwiftGenerator.generate(_simpleSpec());
      final cdeclFuncLines = <String>[];
      var inCdecl = false;
      for (final line in out.split('\n')) {
        if (line.contains('@_cdecl(')) inCdecl = true;
        if (inCdecl) {
          cdeclFuncLines.add(line);
          if (line.contains(')') && line.contains('->')) inCdecl = false;
        }
      }
      final sig = cdeclFuncLines.join(' ');
      // @_cdecl param signature must not contain bare ": String" or "-> String"
      expect(sig, isNot(matches(r':\s+String[,\)]')));
      expect(sig, isNot(contains('-> String')));
    });

    test('registry stores stream cancellables', () {
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('_ticksCancellables'));
      expect(out, contains('[Int64: AnyCancellable]()'));
    });

    test('@_cdecl stream register/release emitted', () {
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('@_cdecl("_register_ticks_stream")'));
      expect(out, contains('@_cdecl("_release_ticks_stream")'));
    });

    test('Swift enum emitted as Int64', () {
      final out = SwiftGenerator.generate(_enumSpec());
      expect(out, contains('public enum DeviceStatus: Int64'));
    });

    test('Swift struct emitted as public struct', () {
      final out = SwiftGenerator.generate(_structStreamSpec());
      expect(out, contains('public struct CameraFrame'));
    });

    test('stream cancellable registration emitted', () {
      final out = SwiftGenerator.generate(_richSpec());
      expect(out, contains('_register_ticks_stream'));
      expect(out, contains('AnyCancellable'));
    });
  });

  // ── EnumGenerator ─────────────────────────────────────────────────────────

  group('EnumGenerator', () {
    test('Dart extension emits nativeValue getter', () {
      final out = EnumGenerator.generateDartExtensions(_enumSpec());
      expect(out, contains('int get nativeValue => index + 0;'));
    });

    test('Dart extension emits toDeviceStatus() on int', () {
      final out = EnumGenerator.generateDartExtensions(_enumSpec());
      expect(out, contains('DeviceStatus toDeviceStatus()'));
    });

    test('startValue offset applied in Dart nativeValue', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'x.native.dart',
        enums: [
          BridgeEnum(name: 'Priority', startValue: 10, values: ['low', 'high']),
        ],
      );
      final out = EnumGenerator.generateDartExtensions(spec);
      expect(out, contains('index + 10'));
      expect(out, contains('this - 10'));
    });

    test('C enum typedef with SCREAMING_SNAKE values', () {
      final out = EnumGenerator.generateCEnums(_enumSpec());
      expect(out, contains('DEVICESTATUS_IDLE = 0,'));
      expect(out, contains('typedef enum {'));
      expect(out, contains('} DeviceStatus;'));
    });

    test('C enum camelCase value converted to SCREAMING_SNAKE', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'x.native.dart',
        enums: [
          BridgeEnum(
            name: 'AudioState',
            startValue: 0,
            values: ['isPlaying', 'isStopped'],
          ),
        ],
      );
      final out = EnumGenerator.generateCEnums(spec);
      expect(out, contains('AUDIOSTATE_IS_PLAYING = 0,'));
      expect(out, contains('AUDIOSTATE_IS_STOPPED = 1,'));
    });

    test('Kotlin enum class has nativeValue Long field', () {
      final out = EnumGenerator.generateKotlin(_enumSpec());
      expect(out, contains('enum class DeviceStatus(val nativeValue: Long)'));
    });

    test('Kotlin enum has fromNative companion', () {
      final out = EnumGenerator.generateKotlin(_enumSpec());
      expect(out, contains('fun fromNative(v: Long): DeviceStatus'));
    });

    test('Kotlin enum values are uppercase', () {
      final out = EnumGenerator.generateKotlin(_enumSpec());
      expect(out, contains('IDLE(0)'));
      expect(out, contains('RUNNING(1)'));
    });

    test('Swift enum uses Int64 raw type', () {
      final out = EnumGenerator.generateSwift(_enumSpec());
      expect(out, contains('public enum DeviceStatus: Int64'));
    });

    test('Swift enum case values are correct', () {
      final out = EnumGenerator.generateSwift(_enumSpec());
      // _enumSpec() has values ['idle', 'running', 'error']
      expect(out, contains('case idle = 0'));
      expect(out, contains('case running = 1'));
    });

    test('spec with no enums returns empty string', () {
      expect(EnumGenerator.generateDartExtensions(_simpleSpec()), isEmpty);
      expect(EnumGenerator.generateCEnums(_simpleSpec()), isEmpty);
      expect(EnumGenerator.generateKotlin(_simpleSpec()), isEmpty);
      expect(EnumGenerator.generateSwift(_simpleSpec()), isEmpty);
    });
  });

  // ── StructGenerator ───────────────────────────────────────────────────────

  group('StructGenerator', () {
    test('Dart FFI class emitted with @Packed for packed struct', () {
      final out = StructGenerator.generateDartExtensions(_richSpec());
      // Reading is not packed — but let's confirm non-packed has no @Packed
      expect(out, isNot(contains('@Packed(1)')));
    });

    test('packed struct emits @Packed(1)', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'x.native.dart',
        structs: [
          BridgeStruct(
            name: 'Tight',
            packed: true,
            fields: [
              BridgeField(
                name: 'val',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = StructGenerator.generateDartExtensions(spec);
      expect(out, contains('@Packed(1)'));
    });

    test('Dart FFI Struct has @Int64 annotation on int field', () {
      final out = StructGenerator.generateDartExtensions(_richSpec());
      expect(out, contains('@Double()')); // double field
    });

    test('Dart FFI Struct has @Int8 annotation on bool field', () {
      final out = StructGenerator.generateDartExtensions(_richSpec());
      expect(out, contains('@Int8()'));
    });

    test('toDart() converts bool field via != 0', () {
      final out = StructGenerator.generateDartExtensions(_richSpec());
      expect(out, contains('valid != 0'));
    });

    test('toDart() zero-copy field uses asTypedList with length field', () {
      final out = StructGenerator.generateDartExtensions(_structStreamSpec());
      expect(out, contains('asTypedList'));
    });

    test('toNative() zero-copy Uint8List uses toPointer', () {
      final out = StructGenerator.generateDartExtensions(_structStreamSpec());
      expect(out, contains('toPointer(arena)'));
    });

    test('toNative() bool field uses ? 1 : 0', () {
      final out = StructGenerator.generateDartExtensions(_richSpec());
      expect(out, contains('valid ? 1 : 0'));
    });

    test('C struct typedef emitted', () {
      final out = StructGenerator.generateCStructs(_richSpec());
      expect(out, contains('typedef struct {'));
      expect(out, contains('} Reading;'));
    });

    test('C struct double field is double', () {
      final out = StructGenerator.generateCStructs(_richSpec());
      expect(out, contains('double value;'));
    });

    test('C struct bool field is int8_t', () {
      final out = StructGenerator.generateCStructs(_richSpec());
      expect(out, contains('int8_t valid;'));
    });

    test('C struct zero-copy Uint8List is uint8_t*', () {
      final out = StructGenerator.generateCStructs(_structStreamSpec());
      expect(out, contains('uint8_t* data;'));
    });

    test('C struct zero-copy field annotated with comment', () {
      final out = StructGenerator.generateCStructs(_structStreamSpec());
      expect(out, contains('/* zero-copy */'));
    });

    test('packed C struct has pragma pack', () {
      final spec = BridgeSpec(
        dartClassName: 'X',
        lib: 'x',
        namespace: 'x',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'x.native.dart',
        structs: [
          BridgeStruct(
            name: 'Dense',
            packed: true,
            fields: [
              BridgeField(
                name: 'n',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = StructGenerator.generateCStructs(spec);
      expect(out, contains('#pragma pack(push, 1)'));
      expect(out, contains('#pragma pack(pop)'));
    });

    test('Kotlin data class emitted', () {
      final out = StructGenerator.generateKotlin(_richSpec());
      expect(out, contains('data class Reading('));
    });

    test('Kotlin zero-copy Uint8List field uses ByteBuffer', () {
      final out = StructGenerator.generateKotlin(_structStreamSpec());
      expect(out, contains('ByteBuffer'));
    });

    test('Kotlin bool field uses Boolean', () {
      final out = StructGenerator.generateKotlin(_richSpec());
      expect(out, contains('val valid: Boolean'));
    });

    test('Swift struct public fields emitted', () {
      final out = StructGenerator.generateSwift(_richSpec());
      expect(out, contains('public struct Reading'));
      expect(out, contains('public var value: Double'));
      expect(out, contains('public var valid: Bool'));
    });

    test('spec with no structs returns empty string', () {
      expect(StructGenerator.generateDartExtensions(_simpleSpec()), isEmpty);
      expect(StructGenerator.generateCStructs(_simpleSpec()), isEmpty);
      expect(StructGenerator.generateKotlin(_simpleSpec()), isEmpty);
      expect(StructGenerator.generateSwift(_simpleSpec()), isEmpty);
    });
  });

  // ── SpecValidator — additional edge cases ─────────────────────────────────

  group('SpecValidator (edge cases)', () {
    test('empty spec (no functions/streams/properties) is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Noop',
        lib: 'noop',
        namespace: 'noop',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'noop.native.dart',
      );
      expect(SpecValidator.validate(spec), isEmpty);
    });

    test('nullable String? return type is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'get',
            cSymbol: 'foo_get',
            isAsync: false,
            returnType: BridgeType(name: 'String?'),
            params: [],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('nullable int? parameter is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'set',
            cSymbol: 'foo_set',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'x',
                type: BridgeType(name: 'int?'),
              ),
            ],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('Uint8List parameter is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'write',
            cSymbol: 'foo_write',
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
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('primitive stream item types are valid', () {
      for (final t in ['double', 'int', 'bool', 'String']) {
        final spec = BridgeSpec(
          dartClassName: 'Foo',
          lib: 'foo',
          namespace: 'foo',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'foo.native.dart',
          streams: [
            BridgeStream(
              dartName: 'values',
              registerSymbol: 'foo_register_values_stream',
              releaseSymbol: 'foo_release_values_stream',
              itemType: BridgeType(name: t),
              backpressure: Backpressure.dropLatest,
            ),
          ],
        );
        expect(
          SpecValidator.validate(spec).where((i) => i.isError),
          isEmpty,
          reason: 'Stream<$t> should be valid',
        );
      }
    });

    test('struct-typed stream item is valid when struct is in spec', () {
      expect(
        SpecValidator.validate(_structStreamSpec()).where((i) => i.isError),
        isEmpty,
      );
    });

    test('enum-typed return is valid when enum is in spec', () {
      expect(
        SpecValidator.validate(_enumSpec()).where((i) => i.isError),
        isEmpty,
      );
    });

    test('struct field referencing another struct in spec is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        structs: [
          BridgeStruct(
            name: 'Inner',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
          BridgeStruct(
            name: 'Outer',
            packed: false,
            fields: [
              BridgeField(
                name: 'inner',
                type: BridgeType(name: 'Inner'),
              ),
            ],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('async void return is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fire',
            cSymbol: 'foo_fire',
            isAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test(
      'multiple valid specs validated independently produce no cross-contamination',
      () {
        final issues1 = SpecValidator.validate(_simpleSpec());
        final issues2 = SpecValidator.validate(_enumSpec());
        final issues3 = SpecValidator.validate(_structStreamSpec());
        expect(issues1.where((i) => i.isError), isEmpty);
        expect(issues2.where((i) => i.isError), isEmpty);
        expect(issues3.where((i) => i.isError), isEmpty);
      },
    );

    test('@HybridRecord return type produces no errors', () {
      expect(
        SpecValidator.validate(_singleRecordSpec()).where((i) => i.isError),
        isEmpty,
      );
    });

    test('List<@HybridRecord> return type produces no errors', () {
      expect(
        SpecValidator.validate(_recordListSpec()).where((i) => i.isError),
        isEmpty,
      );
    });

    test(
      'sync @HybridRecord return emits SYNC_RECORD_RETURN warning (not error)',
      () {
        final spec = BridgeSpec(
          dartClassName: 'Foo',
          lib: 'foo',
          namespace: 'foo',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'foo.native.dart',
          recordTypes: [
            BridgeRecordType(
              name: 'Config',
              fields: [
                BridgeRecordField(
                  name: 'key',
                  dartType: 'String',
                  kind: RecordFieldKind.primitive,
                ),
              ],
            ),
          ],
          functions: [
            BridgeFunction(
              dartName: 'getConfig',
              cSymbol: 'foo_get_config',
              isAsync: false,
              returnType: BridgeType(name: 'Config', isRecord: true),
              params: [],
            ),
          ],
        );
        final issues = SpecValidator.validate(spec);
        final w = issues.where((i) => i.code == 'SYNC_RECORD_RETURN').toList();
        expect(w, hasLength(1));
        expect(w.first.isError, isFalse);
      },
    );

    test('@HybridRecord as stream item type produces no errors', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Event',
            fields: [
              BridgeRecordField(
                name: 'type',
                dartType: 'String',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
        streams: [
          BridgeStream(
            dartName: 'events',
            registerSymbol: 'foo_register_events_stream',
            releaseSymbol: 'foo_release_events_stream',
            itemType: BridgeType(name: 'Event', isRecord: true),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('@HybridRecord as property type produces no errors', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Config',
            fields: [
              BridgeRecordField(
                name: 'k',
                dartType: 'String',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
        properties: [
          BridgeProperty(
            dartName: 'config',
            type: BridgeType(name: 'Config', isRecord: true),
            getSymbol: 'foo_get_config',
            setSymbol: 'foo_set_config',
            hasGetter: true,
            hasSetter: true,
          ),
        ],
      );
      expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
    });

    test('unannotated complex return type still emits UNKNOWN_RETURN_TYPE', () {
      // isRecord: false — should be flagged even if name looks complex
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'get',
            cSymbol: 'foo_get',
            isAsync: true,
            returnType: BridgeType(name: 'List<SomeClass>'),
            params: [],
          ),
        ],
      );
      expect(
        SpecValidator.validate(spec).any(
          (i) => i.code == 'UNKNOWN_RETURN_TYPE' && i.isError,
        ),
        isTrue,
      );
    });

    test('UNKNOWN_RETURN_TYPE hint now mentions @HybridRecord', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'get',
            cSymbol: 'foo_get',
            isAsync: true,
            returnType: BridgeType(name: 'SomeClass'),
            params: [],
          ),
        ],
      );
      final errors = SpecValidator.validate(spec)
          .where((i) => i.isError && i.code == 'UNKNOWN_RETURN_TYPE')
          .toList();
      expect(errors, hasLength(1));
      expect(errors.first.hint, contains('@HybridRecord'));
    });

    test('spec with property-only (no functions) is valid', () {
      final spec = BridgeSpec(
        dartClassName: 'Cfg',
        lib: 'cfg',
        namespace: 'cfg',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'cfg.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'timeout',
            type: BridgeType(name: 'int'),
            getSymbol: 'cfg_get_timeout',
            setSymbol: 'cfg_set_timeout',
            hasGetter: true,
            hasSetter: true,
          ),
        ],
      );
      expect(SpecValidator.validate(spec), isEmpty);
    });
  });

  // ── RecordGenerator ───────────────────────────────────────────────────────

  group('RecordGenerator', () {
    test('emits extension for each @HybridRecord type', () {
      final out = RecordGenerator.generateDartExtensions(_singleRecordSpec());
      expect(out, contains('extension CameraDeviceRecordExt on CameraDevice'));
    });

    test('emits static fromNative factory', () {
      final out = RecordGenerator.generateDartExtensions(_singleRecordSpec());
      expect(out, contains('static CameraDevice fromNative(Pointer<Uint8> ptr)'));
    });

    test('emits static fromReader inner decoder', () {
      final out = RecordGenerator.generateDartExtensions(_singleRecordSpec());
      expect(out, contains('static CameraDevice fromReader(RecordReader r)'));
    });

    test('emits writeFields method', () {
      final out = RecordGenerator.generateDartExtensions(_singleRecordSpec());
      expect(out, contains('void writeFields(RecordWriter w)'));
    });

    test('emits toNative method', () {
      final out = RecordGenerator.generateDartExtensions(_singleRecordSpec());
      expect(out, contains('Pointer<Uint8> toNative(Allocator alloc)'));
    });

    test('primitive String field reads via r.readString() in fromReader', () {
      final out = RecordGenerator.generateDartExtensions(_singleRecordSpec());
      expect(out, contains('r.readString()'));
    });

    test('primitive bool field reads via r.readBool() in fromReader', () {
      final out = RecordGenerator.generateDartExtensions(_singleRecordSpec());
      expect(out, contains('r.readBool()'));
    });

    test('primitive String field writes via w.writeString in writeFields', () {
      final out = RecordGenerator.generateDartExtensions(_singleRecordSpec());
      expect(out, contains('w.writeString(id)'));
    });

    test('primitive double reads via r.readDouble() in fromReader', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Measurement',
            fields: [
              BridgeRecordField(
                name: 'value',
                dartType: 'double',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
      );
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('r.readDouble()'));
      expect(out, contains('w.writeDouble(value)'));
    });

    test('nullable double writes null tag and reads conditionally', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Measurement',
            fields: [
              BridgeRecordField(
                name: 'value',
                dartType: 'double?',
                kind: RecordFieldKind.primitive,
                isNullable: true,
              ),
            ],
          ),
        ],
      );
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('r.readNullTag()'));
      expect(out, contains('r.readDouble()'));
      expect(out, contains('w.writeNullTag(value == null)'));
    });

    test('nested @HybridRecord field calls TypeRecordExt.fromReader', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Inner',
            fields: [
              BridgeRecordField(
                name: 'x',
                dartType: 'int',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
          BridgeRecordType(
            name: 'Outer',
            fields: [
              BridgeRecordField(
                name: 'inner',
                dartType: 'Inner',
                kind: RecordFieldKind.recordObject,
              ),
            ],
          ),
        ],
      );
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('InnerRecordExt.fromReader(r)'));
      expect(out, contains('inner.writeFields(w)'));
    });

    test('nullable nested record uses readNullTag guard in fromReader', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Inner',
            fields: [
              BridgeRecordField(
                name: 'x',
                dartType: 'int',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
          BridgeRecordType(
            name: 'Outer',
            fields: [
              BridgeRecordField(
                name: 'inner',
                dartType: 'Inner?',
                kind: RecordFieldKind.recordObject,
                isNullable: true,
              ),
            ],
          ),
        ],
      );
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(out, contains('r.readNullTag()'));
      expect(out, contains('InnerRecordExt.fromReader(r)'));
      expect(out, contains('w.writeNullTag(inner == null)'));
    });

    test('List<@HybridRecord> field uses List.generate + fromReader', () {
      final out = RecordGenerator.generateDartExtensions(_recordListSpec());
      expect(
        out,
        contains(
          'List.generate(r.readInt32(), (_) => ResolutionRecordExt.fromReader(r))',
        ),
      );
    });

    test('List<@HybridRecord> field uses for loop + writeFields in writeFields', () {
      final out = RecordGenerator.generateDartExtensions(_recordListSpec());
      expect(out, contains('for (final e in resolutions) e.writeFields(w)'));
    });

    test('List<primitive String> field uses List.generate + readString', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Config',
            fields: [
              BridgeRecordField(
                name: 'modes',
                dartType: 'List<String>',
                kind: RecordFieldKind.listPrimitive,
                itemTypeName: 'String',
              ),
            ],
          ),
        ],
      );
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(
        out,
        contains('List.generate(r.readInt32(), (_) => r.readString())'),
      );
      expect(out, contains('for (final e in modes) w.writeString(e)'));
    });

    test('List<double> field uses List.generate + readDouble', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Curve',
            fields: [
              BridgeRecordField(
                name: 'points',
                dartType: 'List<double>',
                kind: RecordFieldKind.listPrimitive,
                itemTypeName: 'double',
              ),
            ],
          ),
        ],
      );
      final out = RecordGenerator.generateDartExtensions(spec);
      expect(
        out,
        contains('List.generate(r.readInt32(), (_) => r.readDouble())'),
      );
      expect(out, contains('for (final e in points) w.writeDouble(e)'));
    });

    test('multiple @HybridRecord types each get their own extension', () {
      final out = RecordGenerator.generateDartExtensions(_recordListSpec());
      expect(out, contains('extension ResolutionRecordExt on Resolution'));
      expect(out, contains('extension CameraDeviceRecordExt on CameraDevice'));
    });

    test('empty spec (no recordTypes) returns empty string', () {
      expect(
        RecordGenerator.generateDartExtensions(_simpleSpec()),
        isEmpty,
      );
    });
  });

  // ── DartFfiGenerator (@HybridRecord) ──────────────────────────────────────

  group('DartFfiGenerator (@HybridRecord)', () {
    test('async single record return uses Pointer<Uint8> FFI lookup type', () {
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      expect(
        out,
        contains(
          "lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>"
          "('camera_module_get_device')",
        ),
      );
    });

    test('record param uses Pointer<Uint8> in FFI lookup', () {
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      expect(
        out,
        contains(
          "lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>"
          "('camera_module_set_device')",
        ),
      );
    });

    test('async single record return decodes via fromNative', () {
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      expect(out, contains('CameraDeviceRecordExt.fromNative'));
      // binary path — must NOT use JSON decode
      expect(out, isNot(contains('jsonDecode')));
      expect(out, isNot(contains('toDartStringWithFree')));
    });

    test('async single record return does not produce Map<String, dynamic>', () {
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      expect(out, isNot(contains('as Map<String, dynamic>')));
    });

    test('async List<record> return uses RecordReader.decodeList + fromReader', () {
      final out = DartFfiGenerator.generate(_recordListSpec());
      expect(out, contains('RecordReader.decodeList'));
      expect(out, contains('CameraDeviceRecordExt.fromReader'));
    });

    test('record param uses .toNative(arena)', () {
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      expect(out, contains('device.toNative(arena)'));
      // Must NOT use JSON path
      expect(out, isNot(contains('jsonEncode(device')));
    });

    test('record param forces withArena even when no other arena params', () {
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      // setDevice has only a record param — must still enter withArena
      final lines = out.split('\n');
      final idx = lines.indexWhere((l) => l.contains('void setDevice('));
      final body = lines.skip(idx).take(12).join('\n');
      expect(body, contains('withArena'));
    });

    test('binary extensions are included in .g.dart output', () {
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      expect(out, contains('@HybridRecord binary extensions'));
      expect(out, contains('extension CameraDeviceRecordExt'));
    });

    test('record property getter decodes via fromNative', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Config',
            fields: [
              BridgeRecordField(
                name: 'key',
                dartType: 'String',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
        properties: [
          BridgeProperty(
            dartName: 'config',
            type: BridgeType(name: 'Config', isRecord: true),
            getSymbol: 'foo_get_config',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('ConfigRecordExt.fromNative'));
      expect(out, isNot(contains('toDartStringWithFree')));
    });

    test('record property setter encodes via .toNative(arena)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Config',
            fields: [
              BridgeRecordField(
                name: 'key',
                dartType: 'String',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
        properties: [
          BridgeProperty(
            dartName: 'config',
            type: BridgeType(name: 'Config', isRecord: true),
            setSymbol: 'foo_set_config',
            hasGetter: false,
            hasSetter: true,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('value.toNative(arena)'));
      expect(out, isNot(contains('jsonEncode(value')));
    });

    test('record stream item unpack decodes via fromNative', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Event',
            fields: [
              BridgeRecordField(
                name: 'type',
                dartType: 'String',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
        streams: [
          BridgeStream(
            dartName: 'events',
            registerSymbol: 'foo_register_events_stream',
            releaseSymbol: 'foo_release_events_stream',
            itemType: BridgeType(name: 'Event', isRecord: true),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('EventRecordExt.fromNative'));
      expect(out, isNot(contains('toDartStringWithFree')));
      expect(out, isNot(contains('jsonDecode')));
    });

    test('List<record> stream item unpack uses RecordReader.decodeList', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Item',
            fields: [
              BridgeRecordField(
                name: 'id',
                dartType: 'int',
                kind: RecordFieldKind.primitive,
              ),
            ],
          ),
        ],
        streams: [
          BridgeStream(
            dartName: 'batch',
            registerSymbol: 'foo_register_batch_stream',
            releaseSymbol: 'foo_release_batch_stream',
            itemType: BridgeType(
              name: 'List<Item>',
              isRecord: true,
              recordListItemType: 'Item',
            ),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodeList'));
      expect(out, contains('ItemRecordExt.fromReader'));
    });

    // ── List<primitive> bridge ────────────────────────────────────────────────

    test('List<String> return decodes via RecordReader.decodePrimitiveList + readString', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getTags',
            cSymbol: 'foo_get_tags',
            isAsync: true,
            returnType: BridgeType(
              name: 'List<String>',
              isRecord: true,
              recordListItemType: 'String',
              recordListItemIsPrimitive: true,
            ),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodePrimitiveList'));
      expect(out, contains('readString'));
      expect(out, isNot(contains('StringRecordExt')));
    });

    test('List<int> return decodes via RecordReader.decodePrimitiveList + readInt', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getCounts',
            cSymbol: 'foo_get_counts',
            isAsync: true,
            returnType: BridgeType(
              name: 'List<int>',
              isRecord: true,
              recordListItemType: 'int',
              recordListItemIsPrimitive: true,
            ),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodePrimitiveList'));
      expect(out, contains('readInt'));
    });

    test('List<double> return uses RecordReader.decodePrimitiveList + readDouble', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getScores',
            cSymbol: 'foo_get_scores',
            isAsync: true,
            returnType: BridgeType(
              name: 'List<double>',
              isRecord: true,
              recordListItemType: 'double',
              recordListItemIsPrimitive: true,
            ),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodePrimitiveList'));
      expect(out, contains('readDouble'));
    });

    test('List<String> param uses RecordWriter.encodePrimitiveList (no jsonEncode)', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'setTags',
            cSymbol: 'foo_set_tags',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'tags',
                type: BridgeType(
                  name: 'List<String>',
                  isRecord: true,
                  recordListItemType: 'String',
                  recordListItemIsPrimitive: true,
                ),
              ),
            ],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordWriter.encodePrimitiveList(tags'));
      expect(out, contains('writeString'));
      expect(out, isNot(contains('jsonEncode(tags)')));
    });

    test('List<String> property setter uses RecordWriter.encodePrimitiveList', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'tags',
            type: BridgeType(
              name: 'List<String>',
              isRecord: true,
              recordListItemType: 'String',
              recordListItemIsPrimitive: true,
            ),
            setSymbol: 'foo_set_tags',
            hasGetter: false,
            hasSetter: true,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordWriter.encodePrimitiveList(value'));
      expect(out, contains('writeString'));
      expect(out, isNot(contains('jsonEncode(value)')));
    });

    test('List<int> stream item decodes via RecordReader.decodePrimitiveList + readInt', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        streams: [
          BridgeStream(
            dartName: 'counts',
            registerSymbol: 'foo_register_counts_stream',
            releaseSymbol: 'foo_release_counts_stream',
            itemType: BridgeType(
              name: 'List<int>',
              isRecord: true,
              recordListItemType: 'int',
              recordListItemIsPrimitive: true,
            ),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('RecordReader.decodePrimitiveList'));
      expect(out, contains('readInt'));
      expect(out, isNot(contains('RecordExt')));
    });

    // ── Map<String, T> bridge (still JSON — dynamic value type) ──────────────

    test('Map<String, dynamic> return decodes via jsonDecode as Map<String, dynamic>', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getMetadata',
            cSymbol: 'foo_get_metadata',
            isAsync: true,
            returnType: BridgeType(
              name: 'Map<String, dynamic>',
              isRecord: true,
              isMap: true,
            ),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonDecode'));
      expect(out, contains('as Map<String, dynamic>'));
      expect(out, contains('Pointer<Utf8>'));
      // Must NOT call RecordExt
      expect(out, isNot(contains('RecordExt')));
    });

    test('Map<String, dynamic> param encodes via jsonEncode(param) with toNativeUtf8', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'setMetadata',
            cSymbol: 'foo_set_metadata',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'meta',
                type: BridgeType(
                  name: 'Map<String, dynamic>',
                  isRecord: true,
                  isMap: true,
                ),
              ),
            ],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonEncode(meta)'));
      expect(out, contains('toNativeUtf8'));
      expect(out, isNot(contains('meta.toJson()')));
    });

    test('Map<String, dynamic> property setter uses jsonEncode(value) directly', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'metadata',
            type: BridgeType(
              name: 'Map<String, dynamic>',
              isRecord: true,
              isMap: true,
            ),
            setSymbol: 'foo_set_metadata',
            hasGetter: false,
            hasSetter: true,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonEncode(value)'));
      expect(out, contains('toNativeUtf8'));
      expect(out, isNot(contains('value.toJson()')));
    });

    test('Map<String, dynamic> stream item decodes as Map<String, dynamic>', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        streams: [
          BridgeStream(
            dartName: 'updates',
            registerSymbol: 'foo_register_updates_stream',
            releaseSymbol: 'foo_release_updates_stream',
            itemType: BridgeType(
              name: 'Map<String, dynamic>',
              isRecord: true,
              isMap: true,
            ),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonDecode'));
      expect(out, contains('as Map<String, dynamic>'));
      expect(out, isNot(contains('RecordExt')));
    });

    test('Map<String, dynamic> property getter decodes as Map<String, dynamic>', () {
      final spec = BridgeSpec(
        dartClassName: 'Foo',
        lib: 'foo',
        namespace: 'foo',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'foo.native.dart',
        properties: [
          BridgeProperty(
            dartName: 'metadata',
            type: BridgeType(
              name: 'Map<String, dynamic>',
              isRecord: true,
              isMap: true,
            ),
            getSymbol: 'foo_get_metadata',
            hasGetter: true,
            hasSetter: false,
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('jsonDecode'));
      expect(out, contains('as Map<String, dynamic>'));
      expect(out, isNot(contains('RecordExt')));
    });

    test(
      '@HybridRecord and @HybridStruct coexist in same spec without collision',
      () {
        final spec = BridgeSpec(
          dartClassName: 'Hybrid',
          lib: 'hybrid',
          namespace: 'hybrid',
          iosImpl: NativeImpl.swift,
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'hybrid.native.dart',
          structs: [
            BridgeStruct(
              name: 'Frame',
              packed: false,
              fields: [
                BridgeField(
                  name: 'width',
                  type: BridgeType(name: 'int'),
                ),
              ],
            ),
          ],
          recordTypes: [
            BridgeRecordType(
              name: 'Config',
              fields: [
                BridgeRecordField(
                  name: 'key',
                  dartType: 'String',
                  kind: RecordFieldKind.primitive,
                ),
              ],
            ),
          ],
          functions: [
            BridgeFunction(
              dartName: 'getConfig',
              cSymbol: 'hybrid_get_config',
              isAsync: true,
              returnType: BridgeType(name: 'Config', isRecord: true),
              params: [],
            ),
            BridgeFunction(
              dartName: 'processFrame',
              cSymbol: 'hybrid_process_frame',
              isAsync: true,
              returnType: BridgeType(name: 'Frame'),
              params: [],
            ),
          ],
        );
        final out = DartFfiGenerator.generate(spec);
        // Both record and struct extensions present
        expect(out, contains('extension ConfigRecordExt'));
        expect(out, contains('final class FrameFfi'));
        // Record method uses binary decode
        expect(out, contains('ConfigRecordExt.fromNative'));
        // Struct method uses fromAddress
        expect(out, contains('Pointer<FrameFfi>.fromAddress'));
        // No errors from spec validator either
        expect(SpecValidator.validate(spec).where((i) => i.isError), isEmpty);
      },
    );
  });
}
