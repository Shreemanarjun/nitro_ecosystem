import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';

export 'package:nitro_generator/src/bridge_spec.dart';
export 'package:nitro_generator/src/spec_validator.dart';
export 'package:nitro_annotations/nitro_annotations.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

BridgeSpec simpleSpec() => BridgeSpec(
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

BridgeSpec enumSpec() => BridgeSpec(
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

BridgeSpec structStreamSpec() => BridgeSpec(
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

BridgeSpec underscoreLibSpec() => BridgeSpec(
  dartClassName: 'SensorHub',
  lib: 'sensor_hub',
  namespace: 'sensor_hub_module',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor_hub.native.dart',
);

// Spec with bools, strings, int, async enum, struct param, property setter
BridgeSpec richSpec() => BridgeSpec(
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
BridgeSpec asyncEnumSpec() => BridgeSpec(
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
BridgeSpec singleRecordSpec() => BridgeSpec(
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
BridgeSpec recordListSpec() => BridgeSpec(
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

// ── NativeImpl.cpp spec helpers ───────────────────────────────────────────────

BridgeSpec cppSpec() => BridgeSpec(
  dartClassName: 'Math',
  lib: 'math',
  namespace: 'math_module',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'math.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'math_add',
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
      dartName: 'greet',
      cSymbol: 'math_greet',
      isAsync: false,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'name',
          type: BridgeType(name: 'String'),
        ),
      ],
    ),
  ],
  properties: [
    BridgeProperty(
      dartName: 'precision',
      type: BridgeType(name: 'int'),
      getSymbol: 'math_get_precision',
      setSymbol: 'math_set_precision',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
);

BridgeSpec cppEnumSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor_module',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'sensor.native.dart',
  enums: [
    BridgeEnum(name: 'SensorMode', startValue: 1, values: ['idle', 'active', 'error']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getMode',
      cSymbol: 'sensor_get_mode',
      isAsync: false,
      returnType: BridgeType(name: 'SensorMode'),
      params: [],
    ),
  ],
);

BridgeSpec cppStreamSpec() => BridgeSpec(
  dartClassName: 'Lidar',
  lib: 'lidar',
  namespace: 'lidar_module',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'lidar.native.dart',
  streams: [
    BridgeStream(
      dartName: 'points',
      registerSymbol: 'lidar_register_points_stream',
      releaseSymbol: 'lidar_release_points_stream',
      itemType: BridgeType(name: 'double'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

// ── Single-platform spec helpers ─────────────────────────────────────────────

/// iOS-only with Swift (no Android).
BridgeSpec iosOnlySpec() => BridgeSpec(
  dartClassName: 'IosCamera',
  lib: 'ios_camera',
  namespace: 'ios_camera',
  iosImpl: NativeImpl.swift,
  sourceUri: 'ios_camera.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'capture',
      cSymbol: 'ios_camera_capture',
      isAsync: false,
      returnType: BridgeType(name: 'bool'),
      params: [],
    ),
  ],
);

/// Android-only with Kotlin (no iOS).
BridgeSpec androidOnlySpec() => BridgeSpec(
  dartClassName: 'AndroidSensor',
  lib: 'android_sensor',
  namespace: 'android_sensor',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'android_sensor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'read',
      cSymbol: 'android_sensor_read',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [],
    ),
  ],
);

/// iOS-only with C++ (no Android).
BridgeSpec iosOnlyCppSpec() => BridgeSpec(
  dartClassName: 'IosProcessor',
  lib: 'ios_processor',
  namespace: 'ios_processor',
  iosImpl: NativeImpl.cpp,
  sourceUri: 'ios_processor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'ios_processor_process',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'value', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);

/// Android-only with C++ (no iOS).
BridgeSpec androidOnlyCppSpec() => BridgeSpec(
  dartClassName: 'AndroidProcessor',
  lib: 'android_processor',
  namespace: 'android_processor',
  androidImpl: NativeImpl.cpp,
  sourceUri: 'android_processor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'android_processor_process',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'value', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);

/// macOS-only with C++ (no iOS, no Android).
BridgeSpec macosOnlyCppSpec() => BridgeSpec(
  dartClassName: 'MacProcessor',
  lib: 'mac_processor',
  namespace: 'mac_processor',
  macosImpl: NativeImpl.cpp,
  sourceUri: 'mac_processor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'mac_processor_process',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'value', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);

/// iOS + macOS shared C++ (no Android).
BridgeSpec appleOnlyCppSpec() => BridgeSpec(
  dartClassName: 'AppleProcessor',
  lib: 'apple_processor',
  namespace: 'apple_processor',
  iosImpl: NativeImpl.cpp,
  macosImpl: NativeImpl.cpp,
  sourceUri: 'apple_processor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'apple_processor_process',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'value', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);

/// iOS + macOS + Android — full shared C++ across all three platforms.
BridgeSpec triPlatformCppSpec() => BridgeSpec(
  dartClassName: 'SharedProcessor',
  lib: 'shared_processor',
  namespace: 'shared_processor',
  iosImpl: NativeImpl.cpp,
  macosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'shared_processor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'shared_processor_process',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'value', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);

/// iOS-only with Swift, includes a property (getter + setter).
BridgeSpec iosOnlyWithPropertySpec() => BridgeSpec(
  dartClassName: 'IosBrightness',
  lib: 'ios_brightness',
  namespace: 'ios_brightness',
  iosImpl: NativeImpl.swift,
  sourceUri: 'ios_brightness.native.dart',
  properties: [
    BridgeProperty(
      dartName: 'level',
      type: BridgeType(name: 'double'),
      getSymbol: 'ios_brightness_get_level',
      setSymbol: 'ios_brightness_set_level',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
);

/// Android-only with Kotlin, includes a property (getter + setter).
BridgeSpec androidOnlyWithPropertySpec() => BridgeSpec(
  dartClassName: 'AndroidVolume',
  lib: 'android_volume',
  namespace: 'android_volume',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'android_volume.native.dart',
  properties: [
    BridgeProperty(
      dartName: 'level',
      type: BridgeType(name: 'int'),
      getSymbol: 'android_volume_get_level',
      setSymbol: 'android_volume_set_level',
      hasGetter: true,
      hasSetter: true,
    ),
  ],
);

/// iOS-only with Swift, includes a stream.
BridgeSpec iosOnlyWithStreamSpec() => BridgeSpec(
  dartClassName: 'IosHeartRate',
  lib: 'ios_heart_rate',
  namespace: 'ios_heart_rate',
  iosImpl: NativeImpl.swift,
  sourceUri: 'ios_heart_rate.native.dart',
  streams: [
    BridgeStream(
      dartName: 'bpm',
      registerSymbol: 'ios_heart_rate_register_bpm_stream',
      releaseSymbol: 'ios_heart_rate_release_bpm_stream',
      itemType: BridgeType(name: 'double'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// Android-only with Kotlin, includes a stream.
BridgeSpec androidOnlyWithStreamSpec() => BridgeSpec(
  dartClassName: 'AndroidStepCounter',
  lib: 'android_step_counter',
  namespace: 'android_step_counter',
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'android_step_counter.native.dart',
  streams: [
    BridgeStream(
      dartName: 'steps',
      registerSymbol: 'android_step_counter_register_steps_stream',
      releaseSymbol: 'android_step_counter_release_steps_stream',
      itemType: BridgeType(name: 'int'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);

/// Same as [cppStreamSpec] but the stream item type is a struct (not a
/// primitive), so the generated unpack must malloc then free the pointer.
BridgeSpec cppStreamStructSpec() => BridgeSpec(
  dartClassName: 'Lidar',
  lib: 'lidar',
  namespace: 'lidar_module',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'lidar.native.dart',
  structs: [
    BridgeStruct(
      name: 'LidarPoint',
      packed: true,
      fields: [
        BridgeField(
          name: 'x',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'y',
          type: BridgeType(name: 'double'),
        ),
        BridgeField(
          name: 'z',
          type: BridgeType(name: 'double'),
        ),
      ],
    ),
  ],
  streams: [
    BridgeStream(
      dartName: 'points',
      registerSymbol: 'lidar_register_points_stream',
      releaseSymbol: 'lidar_release_points_stream',
      itemType: BridgeType(name: 'LidarPoint'),
      backpressure: Backpressure.dropLatest,
    ),
  ],
);
