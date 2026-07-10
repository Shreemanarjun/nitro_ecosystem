// Tests for @NitroNativeAsync — the zero-hop native async path.
//
// Covers all four generators (Dart FFI, C++ bridge, C++ interface, Kotlin,
// Swift) to ensure the correct code patterns are emitted for each return type.
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/languages/cpp_native/cpp_interface_generator.dart';
import 'package:nitro_generator/src/generators/languages/dart/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

// ── Test specs ────────────────────────────────────────────────────────────────

BridgeSpec _nativeAsyncIntSpec() => BridgeSpec(
  dartClassName: 'Compute',
  lib: 'compute',
  namespace: 'compute',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'compute.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'compute',
      cSymbol: 'compute_compute',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'x',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncStringSpec() => BridgeSpec(
  dartClassName: 'Fetcher',
  lib: 'fetcher',
  namespace: 'fetcher',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'fetcher.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fetchData',
      cSymbol: 'fetcher_fetch_data',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'String'),
      params: [
        BridgeParam(
          name: 'query',
          type: BridgeType(name: 'String'),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncNullableStringSpec() => BridgeSpec(
  dartClassName: 'MaybeFetcher',
  lib: 'maybe_fetcher',
  namespace: 'maybe_fetcher',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'maybe_fetcher.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'fetchMaybe',
      cSymbol: 'maybe_fetcher_fetch_maybe',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'String?', isNullable: true),
      params: [
        BridgeParam(
          name: 'query',
          type: BridgeType(name: 'String?', isNullable: true),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncVoidSpec() => BridgeSpec(
  dartClassName: 'Worker',
  lib: 'worker',
  namespace: 'worker',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'worker.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'doWork',
      cSymbol: 'worker_do_work',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [],
    ),
  ],
);

BridgeSpec _nativeAsyncBoolSpec() => BridgeSpec(
  dartClassName: 'Checker',
  lib: 'checker',
  namespace: 'checker',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'checker.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'check',
      cSymbol: 'checker_check',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'bool'),
      params: [
        BridgeParam(
          name: 'flag',
          type: BridgeType(name: 'bool'),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncDoubleSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'readTemp',
      cSymbol: 'sensor_read_temp',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'double'),
      params: [],
    ),
  ],
);

BridgeSpec _mixedSpec() => BridgeSpec(
  dartClassName: 'Mixed',
  lib: 'mixed',
  namespace: 'mixed',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mixed.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'syncAdd',
      cSymbol: 'mixed_sync_add',
      isAsync: false,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'a',
          type: BridgeType(name: 'int'),
        ),
        BridgeParam(
          name: 'b',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
    BridgeFunction(
      dartName: 'asyncFetch',
      cSymbol: 'mixed_async_fetch',
      isAsync: true,
      returnType: BridgeType(name: 'String'),
      params: [],
    ),
    BridgeFunction(
      dartName: 'nativeCompute',
      cSymbol: 'mixed_native_compute',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'n',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

BridgeSpec _nativeAsyncEnumReturnSpec() => BridgeSpec(
  dartClassName: 'Status',
  lib: 'status',
  namespace: 'status',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'status.native.dart',
  enums: [
    BridgeEnum(name: 'Mode', startValue: 0, values: ['idle', 'running', 'error']),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getMode',
      cSymbol: 'status_get_mode',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'Mode'),
      params: [],
    ),
  ],
);

/// Regression spec for the record-return NativeAsync codegen gap: the Kotlin
/// and Swift trampolines used to discard the impl's result and always post
/// null instead of encoding the record — see stopVideoRecording-style bug.
BridgeSpec _nativeAsyncRecordSpec() => BridgeSpec(
  dartClassName: 'Recorder',
  lib: 'recorder',
  namespace: 'recorder',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'recorder.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'RecordingResult',
      fields: [
        BridgeRecordField(name: 'path', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'durationMs', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'stopVideoRecording',
      cSymbol: 'recorder_stop_video_recording',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'RecordingResult', isRecord: true),
      params: [
        BridgeParam(
          name: 'textureId',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

/// Same as [_nativeAsyncRecordSpec] but with a nullable record return —
/// exercises the "post address 0, not Dart_CObject_kNull" convention.
BridgeSpec _nativeAsyncNullableRecordSpec() => BridgeSpec(
  dartClassName: 'Recorder',
  lib: 'recorder',
  namespace: 'recorder',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'recorder.native.dart',
  recordTypes: [
    BridgeRecordType(
      name: 'RecordingResult',
      fields: [
        BridgeRecordField(name: 'path', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'durationMs', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'stopVideoRecording',
      cSymbol: 'recorder_stop_video_recording',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'RecordingResult?', isRecord: true, isNullable: true),
      params: [
        BridgeParam(
          name: 'textureId',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

/// Regression spec for the native-async parameter-decoding gap: on both
/// Kotlin and Swift, `@NitroNativeAsync`'s trampoline only decoded
/// nullable-primitive params — every other category (enum, record, variant,
/// list-of-those, callback) was forwarded as its raw undecoded bridge value,
/// which fails to compile against the impl's typed parameter. One function
/// per param category, all void-returning so the return path (already
/// covered elsewhere) isn't a variable here.
BridgeSpec _nativeAsyncParamsSpec() => BridgeSpec(
  dartClassName: 'ParamRecorder',
  lib: 'param_recorder',
  namespace: 'param_recorder',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'param_recorder.native.dart',
  enums: [
    BridgeEnum(name: 'Mode', startValue: 0, values: ['idle', 'running', 'error']),
  ],
  recordTypes: [
    BridgeRecordType(
      name: 'RecordingResult',
      fields: [
        BridgeRecordField(name: 'path', dartType: 'String', kind: RecordFieldKind.primitive),
        BridgeRecordField(name: 'durationMs', dartType: 'int', kind: RecordFieldKind.primitive),
      ],
    ),
  ],
  variants: [
    BridgeVariant(
      name: 'GestureEvent',
      cases: [
        BridgeVariantCase(
          name: 'GestureTap',
          label: 'tap',
          fields: [
            BridgeRecordField(name: 'x', dartType: 'double', kind: RecordFieldKind.primitive),
          ],
        ),
      ],
    ),
  ],
  functions: [
    // enum param — non-nullable.
    BridgeFunction(
      dartName: 'setMode',
      cSymbol: 'param_recorder_set_mode',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'mode', type: BridgeType(name: 'Mode'))],
    ),
    // enum param — nullable (-1 sentinel decode).
    BridgeFunction(
      dartName: 'setModeMaybe',
      cSymbol: 'param_recorder_set_mode_maybe',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'mode', type: BridgeType(name: 'Mode?', isNullable: true))],
    ),
    // single @HybridRecord param — non-nullable. (@NitroTuple params share
    // this exact isRecord-flag codegen path, with no additional
    // special-casing anywhere in either emitter, so this test doubles as
    // tuple-param coverage.)
    BridgeFunction(
      dartName: 'saveRecording',
      cSymbol: 'param_recorder_save_recording',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'result', type: BridgeType(name: 'RecordingResult', isRecord: true))],
    ),
    // single @HybridRecord param — nullable.
    BridgeFunction(
      dartName: 'saveRecordingMaybe',
      cSymbol: 'param_recorder_save_recording_maybe',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'result',
          type: BridgeType(name: 'RecordingResult?', isRecord: true, isNullable: true),
        ),
      ],
    ),
    // @NitroVariant param.
    BridgeFunction(
      dartName: 'handleGesture',
      cSymbol: 'param_recorder_handle_gesture',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'event', type: BridgeType(name: 'GestureEvent'))],
    ),
    // List<@HybridRecord> param.
    BridgeFunction(
      dartName: 'saveRecordings',
      cSymbol: 'param_recorder_save_recordings',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'results',
          type: BridgeType(name: 'List<RecordingResult>', isRecord: true, recordListItemType: 'RecordingResult'),
        ),
      ],
    ),
    // List<@HybridEnum> param.
    BridgeFunction(
      dartName: 'setModes',
      cSymbol: 'param_recorder_set_modes',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'modes',
          type: BridgeType(name: 'List<Mode>', isRecord: true, isEnumList: true, recordListItemType: 'Mode'),
        ),
      ],
    ),
    // List<@NitroVariant> param.
    BridgeFunction(
      dartName: 'handleGestures',
      cSymbol: 'param_recorder_handle_gestures',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'events',
          type: BridgeType(name: 'List<GestureEvent>', isRecord: true, isVariantList: true, recordListItemType: 'GestureEvent'),
        ),
      ],
    ),
    // List<primitive> param.
    BridgeFunction(
      dartName: 'setValues',
      cSymbol: 'param_recorder_set_values',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'values',
          type: BridgeType(name: 'List<int>', isRecord: true, recordListItemType: 'int', recordListItemIsPrimitive: true),
        ),
      ],
    ),
    // TypedData param — the decoded ${p.name}Arr local was already built
    // (Swift) before this fix but never referenced at the call site (dead
    // code); the raw pointer was forwarded instead.
    BridgeFunction(
      dartName: 'uploadFrame',
      cSymbol: 'param_recorder_upload_frame',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'frame', type: BridgeType(name: 'Uint8List'))],
    ),
    // Callback/function param.
    BridgeFunction(
      dartName: 'onProgress',
      cSymbol: 'param_recorder_on_progress',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'callback',
          type: BridgeType(
            name: 'void Function(int)',
            isFunction: true,
            functionReturnType: 'void',
            functionParams: [BridgeType(name: 'int')],
          ),
        ),
      ],
    ),
    // Map<String,int> param — previously deferred/unhandled for native-async.
    BridgeFunction(
      dartName: 'setCounts',
      cSymbol: 'param_recorder_set_counts',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'counts',
          type: BridgeType(name: 'Map<String, int>', isMap: true, isRecord: true),
        ),
      ],
    ),
    // NitroAnyMap param — Kotlin only (Swift has no NitroAnyMap codec at all
    // yet, a separate, larger gap — see the NitroAnyMap-on-Swift work item).
    BridgeFunction(
      dartName: 'setAnyMap',
      cSymbol: 'param_recorder_set_any_map',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(name: 'data', type: BridgeType(name: 'NitroAnyMap', isAnyMap: true)),
      ],
    ),
  ],
);

/// Regression spec for the native-async return-type dispatch gap: an audit
/// following the record-return fix found the same "no dedicated branch, falls
/// to a generic primitive-shaped fallback" pattern affecting several more
/// return categories on both platforms — plus a fresh regression the record
/// fix itself introduced for List<@HybridEnum>/List<@NitroVariant> returns.
/// NitroAnyMap now works on both platforms — Swift previously had no
/// NitroAnyMap encode/decode path anywhere in the emitter at all (sync or
/// @nitroAsync either); a new recursive AnyValue codec fixed that.
BridgeSpec _nativeAsyncReturnsSpec() => BridgeSpec(
  dartClassName: 'ReturnsRecorder',
  lib: 'returns_recorder',
  namespace: 'returns_recorder',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'returns_recorder.native.dart',
  enums: [
    BridgeEnum(name: 'Mode', startValue: 0, values: ['idle', 'running', 'error']),
  ],
  variants: [
    BridgeVariant(
      name: 'GestureEvent',
      cases: [
        BridgeVariantCase(
          name: 'GestureTap',
          label: 'tap',
          fields: [BridgeRecordField(name: 'x', dartType: 'double', kind: RecordFieldKind.primitive)],
        ),
      ],
    ),
  ],
  customTypes: [
    BridgeCustomType(name: 'Color', codecClass: 'ColorCodec', encodedSize: 5),
  ],
  structs: [
    BridgeStruct(
      name: 'Point',
      packed: false,
      fields: [
        BridgeField(name: 'x', type: BridgeType(name: 'int')),
        BridgeField(name: 'y', type: BridgeType(name: 'int')),
      ],
    ),
  ],
  functions: [
    // Bare @NitroVariant return.
    BridgeFunction(
      dartName: 'getGesture',
      cSymbol: 'returns_recorder_get_gesture',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'GestureEvent'),
      params: [],
    ),
    // Map<String,V> return.
    BridgeFunction(
      dartName: 'getCounts',
      cSymbol: 'returns_recorder_get_counts',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'Map<String, int>', isMap: true, isRecord: true),
      params: [],
    ),
    // NitroAnyMap return — now implemented on both Kotlin and Swift (Swift
    // previously had no NitroAnyMap encode/decode path anywhere at all).
    BridgeFunction(
      dartName: 'getAnyMap',
      cSymbol: 'returns_recorder_get_any_map',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'NitroAnyMap', isAnyMap: true),
      params: [],
    ),
    // @NitroCustomType return.
    BridgeFunction(
      dartName: 'getColor',
      cSymbol: 'returns_recorder_get_color',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'Color'),
      params: [],
    ),
    // Bare @HybridStruct return — both Kotlin (via a per-struct
    // post${Struct}ToPort JNI helper + pack_${Struct}_from_jni) and Swift.
    BridgeFunction(
      dartName: 'getPoint',
      cSymbol: 'returns_recorder_get_point',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'Point'),
      params: [],
    ),
    // Bare @HybridStruct param (Kotlin) — confirmed already correct without
    // any fix (the JNI bridge already delivers a typed object at this layer,
    // unlike records/variants/enums which arrive as raw ByteArray/Long).
    BridgeFunction(
      dartName: 'setPoint',
      cSymbol: 'returns_recorder_set_point',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'void'),
      params: [BridgeParam(name: 'value', type: BridgeType(name: 'Point'))],
    ),
    // uint64? return — Swift only (silent nil-collapses-to-0 bug).
    BridgeFunction(
      dartName: 'getBigNumberMaybe',
      cSymbol: 'returns_recorder_get_big_number_maybe',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'uint64?', isNullable: true),
      params: [],
    ),
    // Nullable AnyNativeObject return — Swift only (silent 0-vs-null bug).
    BridgeFunction(
      dartName: 'getObjectMaybe',
      cSymbol: 'returns_recorder_get_object_maybe',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'AnyNativeObject?', isAnyNativeObject: true, isNullable: true),
      params: [],
    ),
    // List<@HybridEnum> return — Kotlin regression (this fix's own earlier
    // record-return fix accidentally broke this by routing it into the
    // single-record fallback, calling `.encode()` on a Kotlin List).
    BridgeFunction(
      dartName: 'getModes',
      cSymbol: 'returns_recorder_get_modes',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'List<Mode>', isRecord: true, isEnumList: true, recordListItemType: 'Mode'),
      params: [],
    ),
    // List<@NitroVariant> return — same regression as getModes above.
    BridgeFunction(
      dartName: 'getGestures',
      cSymbol: 'returns_recorder_get_gestures',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'List<GestureEvent>', isRecord: true, isVariantList: true, recordListItemType: 'GestureEvent'),
      params: [],
    ),
  ],
);

BridgeSpec _cppOnlyNativeAsyncSpec() => BridgeSpec(
  dartClassName: 'Engine',
  lib: 'engine',
  namespace: 'engine',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'engine.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'process',
      cSymbol: 'engine_process',
      isAsync: false,
      isNativeAsync: true,
      returnType: BridgeType(name: 'int'),
      params: [
        BridgeParam(
          name: 'value',
          type: BridgeType(name: 'int'),
        ),
      ],
    ),
  ],
);

// ── DartFfiGenerator tests ────────────────────────────────────────────────────

void main() {
  group('DartFfiGenerator — @NitroNativeAsync', () {
    // ── Function pointer ──────────────────────────────────────────────────────

    test('int return: FFI type is Void Function(Int64, Int64, Pointer<NitroErrorFfi>, Int64) with error slot + dart_port', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(
        out,
        contains('Void Function(Int64, Int64, Pointer<NitroErrorFfi>, Int64)'),
        reason: 'native-async wrapper returns void and takes (param, fresh-per-call error slot, dart_port)',
      );
    });

    test('int return: Dart callable type is void Function(int, int, Pointer<NitroErrorFfi>, int)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('void Function(int, int, Pointer<NitroErrorFfi>, int)'));
    });

    test('String return: FFI type is Void Function(Pointer<Utf8>, Pointer<NitroErrorFfi>, Int64)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('Void Function(Int64, Pointer<Utf8>, Pointer<NitroErrorFfi>, Int64)'));
    });

    test('void return: FFI type is Void Function(Int64, Pointer<NitroErrorFfi>, Int64) — instanceId + error slot + dart_port', () {
      final out = DartFfiGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('Void Function(Int64, Pointer<NitroErrorFfi>, Int64)'));
    });

    // ── No isLeaf ─────────────────────────────────────────────────────────────

    test('isNativeAsync methods are NOT bound with isLeaf:true', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      // The compute pointer must use lookupFunction, not .asFunction(isLeaf:true).
      expect(out, isNot(contains('isLeaf: true')));
    });

    // ── Method return type ────────────────────────────────────────────────────

    test('int return: method signature is Future<int>', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('Future<int> compute(int x)'));
    });

    test('String return: method signature is Future<String>', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('Future<String> fetchData(String query)'));
    });

    test('void return: method signature is Future<void>', () {
      final out = DartFfiGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('Future<void> doWork()'));
    });

    // ── No async keyword ──────────────────────────────────────────────────────

    test('method body does NOT use the async keyword (returns Future directly)', () {
      // async keyword is only for @nitroAsync. @NitroNativeAsync returns the
      // Future produced by openNativeAsync without suspending.
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('compute(int x) async')));
      expect(out, contains('compute(int x) {'));
    });

    // ── openNativeAsync call ──────────────────────────────────────────────────

    test('method body calls NitroRuntime.openNativeAsync', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('NitroRuntime.openNativeAsync'));
    });

    test('method body does NOT call NitroRuntime.callAsync', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('NitroRuntime.callAsync')));
    });

    test('call: lambda passes the dart_port as last arg to the FFI ptr', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('call: (port) => _computePtr('));
      expect(out, contains(', port)'));
    });

    // ── Unpack expressions ────────────────────────────────────────────────────

    test('int return: unpack casts raw to int', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('(raw) => raw as int'));
    });

    test('double return: unpack casts raw to double', () {
      final out = DartFfiGenerator.generate(_nativeAsyncDoubleSpec());
      expect(out, contains('(raw) => raw as double'));
    });

    test('bool return: unpack casts raw to bool', () {
      final out = DartFfiGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('(raw) => raw as bool'));
    });

    test('String return: unpack casts raw to String (kString delivery)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('(raw) => raw as String'));
    });

    test('String return: openNativeAsync uses String transport type', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('NitroRuntime.openNativeAsync<String>'));
      expect(out, isNot(contains('NitroRuntime.openNativeAsync<Pointer<Utf8>>')));
    });

    test('nullable String return: openNativeAsync uses nullable API type', () {
      final out = DartFfiGenerator.generate(_nativeAsyncNullableStringSpec());
      expect(out, contains('NitroRuntime.openNativeAsync<String?>'));
      expect(out, contains('(raw) => raw as String?'));
      expect(out, isNot(contains('NitroRuntime.openNativeAsync<Pointer<Utf8>>')));
    });

    test('void return: unpack is _ => {}', () {
      final out = DartFfiGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('(_) {}'));
    });

    // ── Arena management ──────────────────────────────────────────────────────

    test('String param forces arena allocation with release in finally', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      // Must allocate arena for UTF-8 String encoding.
      expect(out, contains('final arena = Arena()'));
      expect(out, contains('arena.releaseAll()'));
      expect(out, contains('finally {'));
    });

    test('primitive-only params (int) require no arena', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('final arena = Arena()')));
    });

    // ── Mixed spec ───────────────────────────────────────────────────────────

    test('mixed spec: sync method still emits callSync path', () {
      final out = DartFfiGenerator.generate(_mixedSpec());
      expect(out, contains('syncAdd(int a, int b)'));
      expect(out, isNot(contains('syncAdd.*async')));
    });

    test('mixed spec: @nitroAsync method still emits callAsync', () {
      final out = DartFfiGenerator.generate(_mixedSpec());
      expect(out, contains('NitroRuntime.callAsync'));
    });

    test('mixed spec: @NitroNativeAsync method emits openNativeAsync', () {
      final out = DartFfiGenerator.generate(_mixedSpec());
      expect(out, contains('NitroRuntime.openNativeAsync'));
    });

    test('mixed spec: nativeCompute pointer is Void Function(Int64, Int64, Pointer<NitroErrorFfi>, Int64)', () {
      final out = DartFfiGenerator.generate(_mixedSpec());
      // nativeCompute takes one int param + fresh-per-call error slot + dart_port
      expect(out, contains('Void Function(Int64, Int64, Pointer<NitroErrorFfi>, Int64)'));
    });
  });

  // ── CppBridgeGenerator (direct C++ path) ─────────────────────────────────

  group('CppBridgeGenerator — @NitroNativeAsync (direct C++ path)', () {
    test('wrapper returns void (not the return type of the method)', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('void engine_process('));
    });

    test('wrapper has int64_t dart_port as last parameter', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('int64_t dart_port'));
    });

    test('wrapper does NOT call engine_clear_error()', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      // engine_clear_error() is declared globally but must NOT be called inside
      // the native-async wrapper — the wrapper has no error-slot logic.
      final wrapperStart = out.indexOf('void engine_process(');
      final wrapperBody = out.substring(wrapperStart, out.indexOf('\n}', wrapperStart));
      expect(wrapperBody, isNot(contains('engine_clear_error()')));
    });

    test('when impl is null, posts kNull to dart_port (not error slot)', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('Dart_CObject_kNull'));
      expect(out, contains('Dart_PostCObject_DL(dart_port, &_err)'));
    });

    test('delegates to _impl->process() passing dart_port as last arg', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('_impl->process('));
      expect(out, contains('dart_port)'));
    });

    test('wrapper has a NitroError* param and wraps the impl call in try/catch for synchronous setup throws', () {
      final out = CppBridgeGenerator.generate(_cppOnlyNativeAsyncSpec());
      // Catches SYNCHRONOUS setup exceptions only — the framework doesn't own
      // the impl's async completion thread here, so truly-async errors remain
      // the impl's own responsibility to report via _nitro_err before posting,
      // exactly like dart_port posting already is.
      expect(out, contains('void engine_process(int64_t instanceId, int64_t value, NitroError* _nitro_err, int64_t dart_port)'));
      final wrapperSection = out.substring(out.indexOf('void engine_process('));
      final nextFn = wrapperSection.indexOf('\n\n');
      final wrapper = nextFn > 0 ? wrapperSection.substring(0, nextFn) : wrapperSection;
      expect(wrapper, contains('} catch (const std::exception& e) {'));
      expect(wrapper, contains('_nitro_out_err(_nitro_err, "CppException", e.what());'));
      expect(wrapper, contains('} catch (...) {'));
    });
  });

  // ── CppInterfaceGenerator ─────────────────────────────────────────────────

  group('CppInterfaceGenerator — @NitroNativeAsync', () {
    test('pure-virtual method returns void (not the Dart return type)', () {
      final out = CppInterfaceGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('virtual void process('));
    });

    test('pure-virtual method has NitroError* before int64_t dartPort as the last two params', () {
      final out = CppInterfaceGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('NitroError* _nitro_err'));
      expect(out, contains('int64_t dartPort'));
    });

    test('pure-virtual is = 0 (must be overridden)', () {
      final out = CppInterfaceGenerator.generate(_cppOnlyNativeAsyncSpec());
      expect(out, contains('virtual void process(int64_t value, NitroError* _nitro_err, int64_t dartPort) = 0;'));
    });

    // Regression: the interface's pure-virtual declaration and the call site
    // in cpp_direct_emitter.dart/cpp_bridge_generator.dart's Apple-C++-direct
    // dispatch are emitted by three SEPARATE generators — nothing enforces
    // they agree except this test. A CI build across every desktop platform
    // (benchmark's `computeStatsNative`) broke because the call site was
    // updated to pass `_nitro_err, dart_port` while this interface still
    // declared only `dartPort` — "too many arguments to function call".
    test('pure-virtual param count matches the cpp_direct_emitter.dart call site exactly', () {
      final spec = _cppOnlyNativeAsyncSpec();
      final ifaceOut = CppInterfaceGenerator.generate(spec);
      final bridgeOut = CppBridgeGenerator.generate(spec);
      final ifaceDecl = ifaceOut.substring(ifaceOut.indexOf('virtual void process('), ifaceOut.indexOf(') = 0;') + 6);
      final ifaceParamCount = ifaceDecl.split(',').length;
      final callIdx = bridgeOut.indexOf('_impl->process(');
      expect(callIdx, greaterThan(-1));
      final callSite = bridgeOut.substring(callIdx, bridgeOut.indexOf(');', callIdx) + 1);
      final callParamCount = callSite.substring(callSite.indexOf('(') + 1, callSite.lastIndexOf(')')).split(',').length;
      expect(callParamCount, ifaceParamCount, reason: 'call-site arg count must equal the interface\'s declared param count: iface="$ifaceDecl" call="$callSite"');
    });
  });

  // ── KotlinGenerator ──────────────────────────────────────────────────────

  group('KotlinGenerator — @NitroNativeAsync', () {
    test('_call method accepts extra errPtr: Long and dartPort: Long parameters', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('compute_call(instanceId: Long, x: Long, errPtr: Long, dartPort: Long)'));
    });

    test('_call method returns Unit (void), not the Dart return type', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      // The wrapper accepts (params, dartPort) and returns Unit implicitly —
      // it must NOT declare ): Long { (that would be a non-void return type).
      expect(out, contains('fun compute_call(instanceId: Long, '));
      final callLine = out.split('\n').firstWhere((l) => l.contains('compute_call(instanceId: Long, '), orElse: () => '');
      // Closing paren followed by ): Long would indicate a Long return type.
      expect(callLine, isNot(contains('): Long')));
    });

    test('executes via _asyncExecutor.execute (non-blocking)', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('_asyncExecutor.execute'));
    });

    test('posts result via postInt64ToPort for int return', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('postInt64ToPort(dartPort,'));
    });

    test('posts result via postStringToPort for String return', () {
      final out = KotlinGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('postStringToPort(dartPort,'));
    });

    test('posts via postNullToPort for void return', () {
      final out = KotlinGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('postNullToPort(dartPort)'));
    });

    test('posts via postBoolToPort for bool return', () {
      final out = KotlinGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('postBoolToPort(dartPort,'));
    });

    test('posts via postDoubleToPort for double return', () {
      final out = KotlinGenerator.generate(_nativeAsyncDoubleSpec());
      expect(out, contains('postDoubleToPort(dartPort,'));
    });

    test('postXxxToPort helpers are declared as external JvmStatic', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('@JvmStatic external fun postNullToPort(dartPort: Long)'));
      expect(out, contains('@JvmStatic external fun postInt64ToPort(dartPort: Long, value: Long)'));
      expect(out, contains('@JvmStatic external fun postStringToPort(dartPort: Long, value: String)'));
    });

    test('postXxxToPort helpers are NOT emitted for specs with no @NitroNativeAsync', () {
      // simpleSpec() has @nitroAsync but no @NitroNativeAsync — no helper noise.
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, isNot(contains('postNullToPort')));
    });

    test('handles null impl gracefully by posting null to port', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('postNullToPort(dartPort)'));
    });

    test('interface suspend fun still declared for @NitroNativeAsync method', () {
      // The Kotlin interface uses `suspend` for any async-natured method.
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('suspend fun compute('));
    });

    test('mixed spec: regular @JvmStatic fun still emitted for non-native-async', () {
      final out = KotlinGenerator.generate(_mixedSpec());
      expect(out, contains('fun syncAdd_call(instanceId: Long, '));
      expect(out, contains('fun asyncFetch_call(instanceId: Long)'));
    });

    // ── Regression: @HybridRecord return used to be silently discarded ──────
    // (the trampoline called runBlocking, threw away the result, and always
    // posted null — see stopVideoRecording bug).

    test('record return: captures runBlocking result instead of discarding it', () {
      final out = KotlinGenerator.generate(_nativeAsyncRecordSpec());
      // The old bug's exact shape: call impl, discard, always post null.
      expect(out, isNot(contains('runBlocking { impl.stopVideoRecording(textureId) }\n            postNullToPort(dartPort)')));
      expect(out, contains('val result = runBlocking { impl.stopVideoRecording(textureId) }'));
    });

    test('record return: encodes via .encode() and posts via postBytesToPort', () {
      final out = KotlinGenerator.generate(_nativeAsyncRecordSpec());
      expect(out, contains('val _bytes = result.encode()'));
      expect(out, contains('postBytesToPort(dartPort, _bytes)'));
    });

    test('nullable record return: encodes via ?.encode(), still non-branching post', () {
      final out = KotlinGenerator.generate(_nativeAsyncNullableRecordSpec());
      expect(out, contains('val _bytes = result?.encode()'));
      expect(out, contains('postBytesToPort(dartPort, _bytes)'));
      // Must NOT branch on the record being null with postNullToPort — that
      // reintroduces the exact bug this fix exists for (Dart's unpack always
      // does `raw as int`). Assert the encode and post lines are adjacent
      // (no intervening `if (_bytes == null)` branch). Note: the unrelated
      // impl-not-found guard and the catch-all exception handler both
      // legitimately call postNullToPort elsewhere in the same stub — this
      // is not a blanket absence check.
      expect(out, isNot(contains('if (_bytes == null)')));
      expect(
        out,
        contains('val _bytes = result?.encode()\n            postBytesToPort(dartPort, _bytes)'),
      );
    });

    test('postBytesToPort is declared as external JvmStatic accepting a nullable ByteArray', () {
      final out = KotlinGenerator.generate(_nativeAsyncRecordSpec());
      expect(out, contains('@JvmStatic external fun postBytesToPort(dartPort: Long, value: ByteArray?)'));
    });
  });

  // ── KotlinGenerator param-decoding gap ────────────────────────────────────
  //
  // Regression: @NitroNativeAsync's own callParams builder only decoded
  // nullable-primitive params — every other category (enum, record, variant,
  // list-of-those, callback) was forwarded as its raw undecoded bridge value
  // (a Kotlin type mismatch against the impl's typed parameter — compile
  // failure). Each assertion below embeds the specific method/variable name,
  // so — unlike the record-return tests' first attempt — these can't collide
  // with unrelated legitimate code elsewhere in the same generated file.

  group('KotlinGenerator — @NitroNativeAsync param decoding', () {
    test('non-nullable enum param: decoded via Mode.fromNative(...)', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('impl.setMode(Mode.fromNative(mode))'));
      expect(out, isNot(contains('impl.setMode(mode)')));
    });

    test('nullable enum param: -1 sentinel decode into modeArg', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val modeArg: Mode? = if (mode < 0L) null else Mode.fromNative(mode)'));
      expect(out, contains('impl.setModeMaybe(modeArg)'));
    });

    test('non-nullable @HybridRecord param: decoded via decodeFrom before the call', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val resultDecoded = RecordingResult.decodeFrom(resultBuf)'));
      expect(out, contains('impl.saveRecording(resultDecoded)'));
      expect(out, isNot(contains('impl.saveRecording(result)')));
    });

    test('nullable @HybridRecord param: null-checked decode into resultDecoded', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val resultDecoded: RecordingResult? = if (result == null) null else {'));
      expect(out, contains('impl.saveRecordingMaybe(resultDecoded)'));
    });

    test('@NitroVariant param: decoded via fromReader before the call', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val eventDecoded = GestureEvent.fromReader(RecordReader(eventBuf))'));
      expect(out, contains('impl.handleGesture(eventDecoded)'));
      expect(out, isNot(contains('impl.handleGesture(event)')));
    });

    test('List<@HybridRecord> param: decoded into resultsDecoded before the call', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val resultsDecoded = mutableListOf<RecordingResult>()'));
      expect(out, contains('impl.saveRecordings(resultsDecoded)'));
      expect(out, isNot(contains('impl.saveRecordings(results)')));
    });

    test('List<@HybridEnum> param: decoded into modesDecoded before the call', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val modesDecoded = mutableListOf<Mode>()'));
      expect(out, contains('impl.setModes(modesDecoded)'));
      expect(out, isNot(contains('impl.setModes(modes)')));
    });

    test('List<@NitroVariant> param: decoded into eventsDecoded before the call', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val eventsDecoded = mutableListOf<GestureEvent>()'));
      expect(out, contains('impl.handleGestures(eventsDecoded)'));
      expect(out, isNot(contains('impl.handleGestures(events)')));
    });

    test('List<primitive> param: decoded into valuesDecoded before the call', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val valuesDecoded = ArrayList<Long>()'));
      expect(out, contains('impl.setValues(valuesDecoded)'));
      expect(out, isNot(contains('impl.setValues(values)')));
    });

    test('callback param: wrapped via the _invoke_* JNI lambda, not forwarded as a raw Long', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('_invoke_callback(callback,'));
      expect(out, isNot(contains('impl.onProgress(callback)')));
    });

    test('Map<String,V> param: decoded into a typed Map before the call (previously deferred/unhandled)', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val countsDecoded = mutableMapOf<String, Long>()'));
      expect(out, contains('impl.setCounts(countsDecoded)'));
      expect(out, isNot(contains('impl.setCounts(counts)')));
    });

    test('NitroAnyMap param: decoded via NitroAnyMapCodec.decode before the call (previously deferred/unhandled)', () {
      final out = KotlinGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('val dataDecoded: Map<String, Any?> = NitroAnyMapCodec.decode(data)'));
      expect(out, contains('impl.setAnyMap(dataDecoded)'));
      expect(out, isNot(contains('impl.setAnyMap(data)')));
    });
  });

  // ── KotlinGenerator return-type dispatch gap ──────────────────────────────
  //
  // Regression: the record-return fix's dispatch chain still had no branch
  // for several other return categories (they fell to the generic discard +
  // postNullToPort), and its own isRecord routing accidentally broke
  // List<@HybridEnum>/List<@NitroVariant> returns (`.encode()` on a Kotlin
  // List — compile error). Each assertion embeds the specific method name so
  // it can't collide with unrelated code elsewhere in the file.

  group('KotlinGenerator — @NitroNativeAsync return decoding', () {
    test('bare @NitroVariant return: encoded via RecordWriter, posted via postBytesToPort', () {
      final out = KotlinGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('val _vResult = runBlocking { impl.getGesture() }'));
      expect(out, contains('_vResult.writeFields(_vw)'));
      expect(out, isNot(contains('runBlocking { impl.getGesture() }\n            postNullToPort(dartPort)')));
    });

    test('Map<String,V> return: encoded via the binary map wire format, not discarded', () {
      final out = KotlinGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('val result = runBlocking { impl.getCounts() }'));
      expect(out, contains('val _outMap = result as? Map<String, Long> ?: emptyMap()'));
      expect(out, isNot(contains('runBlocking { impl.getCounts() }\n            postNullToPort(dartPort)')));
    });

    test('NitroAnyMap return: encoded via NitroAnyMapCodec, not discarded', () {
      final out = KotlinGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('val result = runBlocking { impl.getAnyMap() }'));
      expect(out, contains('postBytesToPort(dartPort, NitroAnyMapCodec.encode(_outMap))'));
    });

    test('@NitroCustomType return: impl\'s own ByteArray is posted directly, not discarded', () {
      final out = KotlinGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('val result = runBlocking { impl.getColor() }'));
      expect(out, contains('postBytesToPort(dartPort, result)'));
    });

    test('List<@HybridEnum> return: encodes the list, does NOT call .encode() on it', () {
      final out = KotlinGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('val result = runBlocking { impl.getModes() }'));
      expect(out, contains('result.forEach { buf.putLong(it.nativeValue) }'));
      // The regression: routing into the single-record fallback produced
      // `result.encode()`, which isn't a member of Kotlin's List type.
      expect(out, isNot(contains('result.encode()')));
    });

    test('List<@NitroVariant> return: encodes the list via RecordWriter per item', () {
      final out = KotlinGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('val result = runBlocking { impl.getGestures() }'));
      expect(out, contains('item.writeFields(_iw)'));
      expect(out, isNot(contains('result.encode()')));
    });

    test('bare @HybridStruct param: forwarded as-is (already a typed value at the JNI boundary)', () {
      final out = KotlinGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('fun setPoint_call('));
      expect(out, contains('impl.setPoint(value)'));
    });

    test('bare @HybridStruct return: posted via a per-struct postPointToPort helper (previously no wire format existed)', () {
      final out = KotlinGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('@JvmStatic external fun postPointToPort(dartPort: Long, value: Point?)'));
      expect(out, contains('val result = runBlocking { impl.getPoint() }'));
      expect(out, contains('postPointToPort(dartPort, result)'));
      expect(out, isNot(contains('runBlocking { impl.getPoint() }\n            postNullToPort(dartPort)')));
    });
  });

  // ── SwiftGenerator ───────────────────────────────────────────────────────

  group('SwiftGenerator — @NitroNativeAsync', () {
    test('stub does NOT use DispatchSemaphore (non-blocking path)', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('DispatchSemaphore')));
    });

    test('stub accepts extra _ dartPort: Int64 parameter', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('_ dartPort: Int64'));
    });

    test('stub uses Task.detached for non-blocking async execution', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('Task.detached'));
    });

    test('stub calls Dart_PostCObject_DL(dartPort, &_obj)', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('Dart_PostCObject_DL(dartPort'));
    });

    test('int return: posts via kInt64', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('Dart_CObject_kInt64'));
      expect(out, contains('as_int64'));
    });

    test('double return: posts via kDouble', () {
      final out = SwiftGenerator.generate(_nativeAsyncDoubleSpec());
      expect(out, contains('Dart_CObject_kDouble'));
      expect(out, contains('as_double'));
    });

    test('bool return: posts via kBool', () {
      final out = SwiftGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('Dart_CObject_kBool'));
      expect(out, contains('as_bool'));
    });

    test('stub has @_cdecl annotation', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      // namespace = 'compute' → _compute_call_compute
      expect(out, contains('@_cdecl("_compute_call_compute")'));
    });

    test('stub does NOT call sema.wait() — no thread blocking', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('sema.wait()')));
    });

    // ── Regression: @HybridRecord return used to be coerced through the
    // generic Int64 `else` branch (`(try? await ...) ?? 0`), which does not
    // type-check for a record struct and is broken in the same way as the
    // Kotlin discard-and-always-null bug.

    test('record return: encodes via .toNative(), not the generic Int64 coercion', () {
      final out = SwiftGenerator.generate(_nativeAsyncRecordSpec());
      expect(out, contains('.toNative()'));
      expect(out, isNot(contains('(try? await impl.stopVideoRecording(textureId: textureId)) ?? 0')));
    });

    test('record return: posts the encoded pointer as kInt64', () {
      final out = SwiftGenerator.generate(_nativeAsyncRecordSpec());
      final stubStart = out.indexOf('_recorder_call_stopVideoRecording');
      final stub = out.substring(stubStart);
      expect(stub, contains('Dart_CObject_kInt64'));
      expect(stub, contains('_recPtr'));
    });

    test('nullable record return: still posts kInt64, never Dart_CObject_kNull for the record value', () {
      final out = SwiftGenerator.generate(_nativeAsyncNullableRecordSpec());
      // Scope to the `do { ... }` success block only — the unrelated
      // impl-not-found guard above it, and the shared `catch` block below it
      // (added for error propagation), both legitimately post
      // Dart_CObject_kNull for their own cases, which this assertion isn't about.
      final doStart = out.indexOf('do {');
      final stubEnd = out.indexOf('} catch {', doStart);
      final stub = out.substring(doStart, stubEnd);
      expect(stub, contains('Dart_CObject_kInt64'));
      // A nil record posts address 0 via the same kInt64 branch — no separate
      // kNull post for the "no value" case (that would break Dart's `raw as
      // int` unpack for nullable records).
      expect(stub, isNot(contains('Dart_CObject_kNull')));
    });
  });

  // ── SwiftGenerator param-decoding gap ─────────────────────────────────────
  //
  // Regression: @NitroNativeAsync's own callArgs closure had no branch for
  // callbacks, TypedData, records, tuples, variants, structs, or lists of
  // any of those — they fell to the generic `'${p.name}: ${p.name}'`,
  // forwarding a raw pointer/function-pointer where a decoded Swift value
  // was expected (compile failure). Non-nullable and nullable enum params
  // were already handled correctly before this fix; covered here as
  // regression coverage since they had zero test coverage previously.

  group('SwiftGenerator — @NitroNativeAsync param decoding', () {
    test('non-nullable enum param: Mode(rawValue: mode)!', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('impl.setMode(mode: Mode(rawValue: mode)!)'));
    });

    test('nullable enum param: Mode(rawValue: mode), no force-unwrap', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('impl.setModeMaybe(mode: Mode(rawValue: mode))'));
    });

    test('non-nullable @HybridRecord param: pre-decoded via fromNative before Task.detached', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('let result_dec = RecordingResult.fromNative(result!.assumingMemoryBound(to: UInt8.self))'));
      expect(out, contains('impl.saveRecording(result: result_dec)'));
      expect(out, isNot(contains('impl.saveRecording(result: result)')));
    });

    test('nullable @HybridRecord param: pre-decoded via .map { fromNative }', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('let result_dec = result.map { RecordingResult.fromNative(\$0.assumingMemoryBound(to: UInt8.self)) }'));
      expect(out, contains('impl.saveRecordingMaybe(result: result_dec)'));
    });

    test('@NitroVariant param: pre-decoded via fromReader before Task.detached', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(
        out,
        contains('let event_dec = GestureEvent.fromReader(NitroRecordReader(ptr: event!.assumingMemoryBound(to: UInt8.self)))'),
      );
      expect(out, contains('impl.handleGesture(event: event_dec)'));
      expect(out, isNot(contains('impl.handleGesture(event: event)')));
    });

    test('List<@HybridRecord> param: decoded via NitroRecordReader.decodeIndexedList + fromReader', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('NitroRecordReader.decodeIndexedList'));
      expect(out, contains('RecordingResult.fromReader'));
      expect(out, contains('impl.saveRecordings(results: resultsDecoded)'));
      expect(out, isNot(contains('impl.saveRecordings(results: results)')));
    });

    test('List<@HybridEnum> param: decoded via NitroRecordReader.decodeList', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('Mode(rawValue: r.readInt())'));
      expect(out, contains('impl.setModes(modes: modesDecoded)'));
      expect(out, isNot(contains('impl.setModes(modes: modes)')));
    });

    test('List<@NitroVariant> param: decoded via NitroRecordReader.decodeList + fromReader', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('GestureEvent.fromReader(r)'));
      expect(out, contains('impl.handleGestures(events: eventsDecoded)'));
      expect(out, isNot(contains('impl.handleGestures(events: events)')));
    });

    test('List<primitive> param: decoded via NitroRecordReader.decodeIndexedList', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('impl.setValues(values: valuesDecoded)'));
      expect(out, isNot(contains('impl.setValues(values: values)')));
    });

    test('callback param: wrapped via callbackWrapper, not forwarded as a raw function pointer', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('callback(arg0)'));
      expect(out, isNot(contains('callback: callback')));
    });

    test('TypedData param: frameArr local is referenced at the call site (was dead code before this fix)', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('let frameArr = frame.map { Data(bytes: \$0, count: Int(frame_length)) } ?? Data()'));
      expect(out, contains('impl.uploadFrame(frame: frameArr)'));
      expect(out, isNot(contains('impl.uploadFrame(frame: frame)')));
    });

    test('Map<String,V> param: decoded via _nitroDecodeMapBinary before Task.detached (previously deferred/unhandled)', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('let counts_rawMap: [String: Any] = counts.map { _nitroDecodeMapBinary(\$0.assumingMemoryBound(to: UInt8.self)) } ?? [:]'));
      expect(out, contains('impl.setCounts(counts: counts_dec)'));
      expect(out, isNot(contains('impl.setCounts(counts: counts)')));
    });

    test('NitroAnyMap param: decoded via _nitroDecodeAnyMapBinary before Task.detached (Swift had no AnyMap codec at all before this)', () {
      final out = SwiftGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('_ data: UnsafeMutableRawPointer?')); // not `Any` — @_cdecl requires a C-compatible type
      expect(out, contains('let data_dec: [String: Any] = data.map { _nitroDecodeAnyMapBinary(\$0.assumingMemoryBound(to: UInt8.self)) } ?? [:]'));
      expect(out, contains('impl.setAnyMap(data: data_dec)'));
      expect(out, isNot(contains('impl.setAnyMap(data: data)')));
    });
  });

  // ── SwiftGenerator return-type dispatch gap ───────────────────────────────
  //
  // Regression: these categories all fell to the generic `(try? await ...)
  // ?? 0` / `Int64(_result)` fallback, which doesn't type-check against a
  // non-Int64-convertible Swift value (compile failure) — except uint64? and
  // nullable AnyNativeObject, which DO compile via the fallback but silently
  // collapse "no value" to 0 instead of a distinguishable sentinel.

  group('SwiftGenerator — @NitroNativeAsync return decoding', () {
    test('bare @NitroVariant return: encoded via NitroRecordWriter, not the generic Int64 coercion', () {
      final out = SwiftGenerator.generate(_nativeAsyncReturnsSpec());
      // A throw now exits to the shared catch (see errPtr tests), so this
      // branch declares a plain `try await` — no more `try?`/`?? 0` collapsing
      // a legitimate value with a swallowed error.
      expect(out, contains('let _vResult: GestureEvent? = try await impl.getGesture()'));
      expect(out, contains('_vr.writeFields(to: _vw)'));
      expect(out, isNot(contains('try? await impl.getGesture()')));
    });

    test('Map<String,V> return: encoded via _nitroEncodeMapBinary, not the generic Int64 coercion', () {
      final out = SwiftGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('let _result: Any? = try await impl.getCounts()'));
      expect(out, contains('_nitroEncodeMapBinary(_resultMap)'));
      expect(out, isNot(contains('try? await impl.getCounts()')));
    });

    test('@NitroCustomType return: fixed-size malloced copy, not the generic Int64 coercion', () {
      final out = SwiftGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('let _result: [UInt8]? = try await impl.getColor()'));
      expect(out, contains('UnsafeMutablePointer<UInt8>.allocate(capacity: 5)'));
      expect(out, isNot(contains('try? await impl.getColor()')));
    });

    test('bare @HybridStruct return: encoded via _PointC.fromSwift, not the generic Int64 coercion', () {
      final out = SwiftGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('let _result: Point? = try await impl.getPoint()'));
      expect(out, contains('_PointC.fromSwift(r)'));
      expect(out, isNot(contains('try? await impl.getPoint()')));
    });

    test('uint64? return: pointer-encode preserves nil, does not collapse to 0', () {
      final out = SwiftGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('let _result = try await impl.getBigNumberMaybe()'));
      expect(out, contains('_out_nu[0] = _result != nil ? 1 : 0'));
      // The bug: collapsing straight to `?? 0` loses the "was it null" bit.
      // A throw now exits to the shared catch instead of collapsing to a value at all.
      expect(out, isNot(contains('try? await impl.getBigNumberMaybe()')));
    });

    test('nullable AnyNativeObject return: -1 sentinel, not the generic 0 fallback', () {
      final out = SwiftGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('let _result = try await impl.getObjectMaybe()'));
      expect(out, contains('_obj.value.as_int64 = _result ?? -1'));
    });

    test('NitroAnyMap return: encoded via the new _nitroEncodeAnyMapBinary codec (Swift had no AnyMap codec at all before this)', () {
      final out = SwiftGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('let _result: Any? = try await impl.getAnyMap()'));
      expect(out, contains('_nitroEncodeAnyMapBinary(_resultMap)'));
      expect(out, isNot(contains('try? await impl.getAnyMap()')));
    });

    test('NitroAnyMap codec: recursive AnyValue read/write helpers are emitted', () {
      final out = SwiftGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('private func _nitroWriteAnyValue(_ payload: inout Data, _ v: Any)'));
      expect(out, contains('private func _nitroReadAnyValue(_ data: Data, _ pos: inout Int) -> Any'));
      expect(out, contains('private func _nitroEncodeAnyMapBinary(_ m: [String: Any]) -> UnsafeMutablePointer<UInt8>?'));
      expect(out, contains('private func _nitroDecodeAnyMapBinary(_ ptr: UnsafeMutablePointer<UInt8>) -> [String: Any]'));
    });
  });

  // ── C++/JNI bridge — real-device-discovered gaps ──────────────────────────
  //
  // The Kotlin/Swift-level fixes above were verified end-to-end in a real
  // plugin (nitro_type_coverage) built and run on Android/iOS/macOS. That
  // surfaced a THIRD layer with the same "native-async never learned this
  // category" pattern: the C++/JNI bridge's signature builder and per-param
  // JNI marshaling never threaded variant/customType names through for
  // native-async at all, so a variant param crashed the generator outright
  // (`Bad state: Unknown JNI signature type`) instead of producing wrong
  // output — worse than the Kotlin/Swift gaps, which at least compiled to
  // something (just semantically broken).

  group('CppBridgeGenerator — @NitroNativeAsync JNI signature/marshaling gaps', () {
    test('variant param: generation does not throw (regression — used to crash the whole build)', () {
      expect(() => CppBridgeGenerator.generate(_nativeAsyncParamsSpec()), returnsNormally);
    });

    test('NitroAnyMap param: C declaration/definition both use uint8_t*, not a void*/uint8_t* mismatch', () {
      // Regression: _typeToC's default fallback returned 'void*' for a
      // NitroAnyMap-named param (only Map<String,T> was matched by prefix),
      // but the separately-generated header declaration already correctly
      // used uint8_t* — a C++ "conflicting types" compile error, found by
      // actually building nitro_type_coverage for macOS.
      final out = CppBridgeGenerator.generate(_nativeAsyncParamsSpec());
      final declIdx = out.indexOf('param_recorder_set_any_map(int64_t instanceId, uint8_t* data');
      expect(declIdx, greaterThan(-1));
      final defIdx = out.indexOf('void param_recorder_set_any_map(');
      expect(defIdx, greaterThan(-1));
      final defLine = out.substring(defIdx, out.indexOf('\n', defIdx));
      expect(defLine, contains('uint8_t* data'));
      expect(defLine, isNot(contains('void* data')));
    });

    test('bare @HybridStruct param: already delivered as a typed jobject, no fix needed', () {
      // Confirms a finding, not a fix: the JNI bridge already converts a
      // struct param to a proper jobject (unpack_Point_to_jni) matching the
      // Kotlin _call method's typed `Point` parameter — unlike records/
      // variants/enums, which arrive as raw ByteArray/Long needing decode.
      final out = CppBridgeGenerator.generate(_nativeAsyncReturnsSpec());
      final startIdx = out.indexOf('void returns_recorder_set_point(');
      expect(startIdx, greaterThan(-1));
      final body = out.substring(startIdx, out.indexOf('\n}', startIdx));
      expect(body, contains('unpack_Point_to_jni'));
      expect(body, contains('jobj_value'));
    });

    test('variant param: JNI signature uses [B (ByteArray), not left unresolved', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('handleGesture_call'));
    });

    test('variant param: wrapped into a jbyteArray before the JNI call, not passed as a raw pointer', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncParamsSpec());
      final startIdx = out.indexOf('void param_recorder_handle_gesture(');
      expect(startIdx, greaterThan(-1));
      final body = out.substring(startIdx, out.indexOf('\n}', startIdx));
      expect(body, contains('NewByteArray'));
      expect(body, contains('SetByteArrayRegion'));
    });

    test('record param: wrapped into a jbyteArray before the JNI call (previously only Map params were)', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncParamsSpec());
      final startIdx = out.indexOf('void param_recorder_save_recording(');
      expect(startIdx, greaterThan(-1));
      final body = out.substring(startIdx, out.indexOf('\n}', startIdx));
      expect(body, contains('NewByteArray'));
    });

    test('callback param: generation does not throw and produces a valid C symbol', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('param_recorder_on_progress'));
    });

    test('enum param: C declaration is int64_t, not void* (void* cast of the -1 sentinel is implementation-defined)', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('void param_recorder_set_mode(int64_t instanceId, int64_t mode, NitroError* _nitro_err, int64_t dart_port)'));
    });

    test('returns spec (variant/map/struct/customtype returns): generation does not throw', () {
      expect(() => CppBridgeGenerator.generate(_nativeAsyncReturnsSpec()), returnsNormally);
    });

    test('bare @HybridStruct return: postPointToPort mallocs via pack_Point_from_jni, posts kInt64', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncReturnsSpec());
      final idx = out.indexOf('postPointToPort(JNIEnv* env, jclass, jlong dartPort, jobject value)');
      expect(idx, greaterThan(-1));
      final body = out.substring(idx, out.indexOf('\n}', idx));
      expect(body, contains('pack_Point_from_jni(env, value)'));
      expect(body, contains('Dart_CObject_kInt64'));
      expect(body, contains('obj.value.as_int64 = 0')); // null → address 0, not kNull
    });
  });

  // ── Dart FFI generator — real-device-discovered gaps ──────────────────────
  //
  // Two more bugs from the same real-device verification pass: nullable enum
  // *params* were forwarded as the raw enum object (not `.nativeValue`) since
  // the native-async-only `plainCallArgs` helper checked `spec.isEnumName(t)`
  // without stripping the `?` suffix first — so it silently never matched a
  // nullable enum's name and fell through to the generic passthrough. And two
  // *return* categories (bare @NitroVariant, uint64?) had no unpack branch at
  // all, so `raw` (the posted pointer/value) was cast directly to the wrong
  // Dart type instead of being decoded — a runtime crash for variant, and a
  // silent wrong-value bug for uint64? (returned the raw pointer address).

  group('DartFfiGenerator — @NitroNativeAsync param/return gaps', () {
    test('nullable enum param: call site uses .nativeValue with -1 sentinel, not the raw enum object', () {
      final out = DartFfiGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('mode == null ? -1 : mode.nativeValue'));
      expect(out, isNot(contains('_nativeAsyncParamsSpecSetModeMaybePtr(_instanceId, mode, port)')));
    });

    test('non-nullable enum param: call site still uses .nativeValue (unaffected by the fix)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncParamsSpec());
      expect(out, contains('mode.nativeValue'));
    });

    test('bare @NitroVariant return: unpack decodes via VariantExt.fromNative, not a raw cast', () {
      final out = DartFfiGenerator.generate(_nativeAsyncReturnsSpec());
      expect(out, contains('GestureEventVariantExt.fromNative(rawPtr)'));
      expect(out, isNot(contains('unpack: (raw) => raw as GestureEvent')));
    });

    test('uint64? return: unpack decodes via Pointer<NitroOptInt64>, not a raw cast of the pointer address', () {
      final out = DartFfiGenerator.generate(_nativeAsyncReturnsSpec());
      final anchor = out.indexOf('Future<uint64?> getBigNumberMaybe()');
      expect(anchor, greaterThan(-1));
      final unpackSection = out.substring(anchor, out.indexOf('methodName:', anchor) + 40);
      expect(unpackSection, contains('Pointer<NitroOptInt64>.fromAddress(raw as int)'));
      expect(unpackSection, isNot(contains('raw as uint64?')));
    });

    test('NitroAnyMap return: unpack decodes via NitroAnyMap.fromNative, not a raw cast (isAnyMap is a separate flag from isRecord)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncReturnsSpec());
      final anchor = out.indexOf('getAnyMap()');
      expect(anchor, greaterThan(-1));
      final unpackSection = out.substring(anchor, out.indexOf('methodName:', anchor) + 40);
      expect(unpackSection, contains('NitroAnyMap.fromNative(rawPtr)'));
      expect(unpackSection, isNot(contains('raw as NitroAnyMap')));
    });
  });

  // ── NitroRuntime.openNativeAsync contract ─────────────────────────────────

  group('NitroRuntime.openNativeAsync — contract via generated output', () {
    test('Dart output does not contain NitroRuntime.callAsync for native-async', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, isNot(contains('NitroRuntime.callAsync')));
    });

    test('Dart output does not reference _getErrorNativePtr for native-async', () {
      // Error slot checks are skipped — errors come via the port.
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      final computeMethod = out.substring(out.indexOf('Future<int> compute'));
      final endOfMethod = computeMethod.indexOf('\n  }');
      final methodBody = computeMethod.substring(0, endOfMethod);
      expect(methodBody, isNot(contains('_getErrorNativePtr')));
    });
  });

  // ── DartFfiGenerator — additional return / param types ───────────────────────

  group('DartFfiGenerator — @NitroNativeAsync additional coverage', () {
    test('enum return: unpack converts raw int via .toMode()', () {
      final out = DartFfiGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('(raw) => (raw as int).toMode()'));
    });

    test('enum return: openNativeAsync uses enum API type', () {
      final out = DartFfiGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('NitroRuntime.openNativeAsync<Mode>'));
      expect(out, isNot(contains('NitroRuntime.openNativeAsync<int>')));
    });

    test('enum return: method signature is Future<Mode>', () {
      final out = DartFfiGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('Future<Mode> getMode()'));
    });

    test('bool param: FFI type includes Bool for the bool parameter', () {
      final out = DartFfiGenerator.generate(_nativeAsyncBoolSpec());
      // instanceId -> Int64, bool flag -> Bool, error slot -> Pointer<NitroErrorFfi>, dart_port -> Int64
      expect(out, contains('Void Function(Int64, Bool, Pointer<NitroErrorFfi>, Int64)'));
    });

    test('bool param: Dart callable type uses bool for bool parameter', () {
      final out = DartFfiGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('void Function(int, bool, Pointer<NitroErrorFfi>, int)'));
    });

    test('String param: arena call arg uses toNativeUtf8(allocator: arena)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('query.toNativeUtf8(allocator: arena)'));
    });

    test('no-params void: call lambda is _doWorkPtr(_instanceId, _nitroErr, port)', () {
      final out = DartFfiGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('_doWorkPtr(_instanceId, _nitroErr, port)'));
    });
  });

  // ── SwiftGenerator — additional return types ──────────────────────────────────

  group('SwiftGenerator — @NitroNativeAsync additional coverage', () {
    test('void return: posts kNull after executing inside Task', () {
      final out = SwiftGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('Dart_CObject_kNull'));
    });

    test('void return: calls impl.doWork() before posting null', () {
      final out = SwiftGenerator.generate(_nativeAsyncVoidSpec());
      expect(out, contains('impl.doWork()'));
      expect(out, contains('Dart_PostCObject_DL(dartPort, &_null)'));
    });

    test('String return: uses kString type', () {
      final out = SwiftGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('Dart_CObject_kString'));
      expect(out, contains('as_string'));
    });

    test('String return: uses withCString to pass the string pointer', () {
      final out = SwiftGenerator.generate(_nativeAsyncStringSpec());
      expect(out, contains('withCString'));
    });

    test('nullable String return: posts kNull or kString', () {
      final out = SwiftGenerator.generate(_nativeAsyncNullableStringSpec());
      expect(out, contains('guard let _value = _result ?? nil else'));
      expect(out, contains('Dart_CObject_kNull'));
      expect(out, contains('Dart_CObject_kString'));
    });

    test('nullable String param: preserves nil instead of empty string', () {
      final out = SwiftGenerator.generate(_nativeAsyncNullableStringSpec());
      expect(out, contains('let queryStr: String? = _nitroStringOptFromCString(query)'));
    });

    test('no-params stub: signature has no comma before _ errPtr', () {
      final out = SwiftGenerator.generate(_nativeAsyncVoidSpec());
      // namespace = 'worker' → _worker_call_doWork
      expect(out, contains('public func _worker_call_doWork(_ errPtr: Int64, _ dartPort: Int64)'));
      expect(out, isNot(contains('(, _ errPtr')));
    });

    test('null guard: posts kNull to dartPort before Task when impl is nil', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      final guardIdx = out.indexOf('guard let impl = ComputeRegistry.impl else {');
      expect(guardIdx, isNot(-1), reason: 'null guard must be present');
      final guardBlock = out.substring(guardIdx, out.indexOf('\n    }', guardIdx) + 6);
      expect(guardBlock, contains('Dart_PostCObject_DL(dartPort, &_null)'));
    });

    test('enum return: posts via kInt64 using .rawValue', () {
      final out = SwiftGenerator.generate(_nativeAsyncEnumReturnSpec());
      // Non-nullable enum return: no more `?? 0` fallback — a throw now exits
      // to the shared catch instead of collapsing to a value that could be a
      // legitimate rawValue.
      expect(out, contains('let _resultEnum = try await impl.getMode()'));
      expect(out, contains('let _result = _resultEnum.rawValue'));
      expect(out, contains('Dart_CObject_kInt64'));
      expect(out, contains('as_int64'));
    });

    test('bool param converts Int8 ABI value to Swift Bool', () {
      final out = SwiftGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('impl.check(flag: flag != 0)'));
      expect(out, isNot(contains('impl.check(flag: flag)')));
    });
  });

  // ── KotlinGenerator — additional return types ─────────────────────────────────

  group('KotlinGenerator — @NitroNativeAsync additional coverage', () {
    test('enum return: posts nativeValue via postInt64ToPort', () {
      final out = KotlinGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('postInt64ToPort(dartPort, result.nativeValue)'));
    });

    test('enum return: interface uses suspend fun with enum return type', () {
      final out = KotlinGenerator.generate(_nativeAsyncEnumReturnSpec());
      expect(out, contains('suspend fun getMode('));
    });

    test('uses runBlocking inside _asyncExecutor.execute body', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('runBlocking {'));
    });

    test('executor catches thrown native async work, reports it, and completes port', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('} catch (e: Throwable) {'));
      expect(out, contains('reportNativeAsyncError(errPtr, e.javaClass.simpleName, e.message ?: "An unknown native exception occurred.")'));
      expect(out, contains('postNullToPort(dartPort)'));
    });

    test('nullable String return: posts null or string to port', () {
      final out = KotlinGenerator.generate(_nativeAsyncNullableStringSpec());
      expect(out, contains('suspend fun fetchMaybe(query: String?): String?'));
      expect(
        out,
        contains('if (result == null) postNullToPort(dartPort) else postStringToPort(dartPort, result)'),
      );
    });
  });

  // ── CppBridgeGenerator — param type conversions ───────────────────────────────

  group('CppBridgeGenerator — @NitroNativeAsync param conversions', () {
    test('String param is converted to std::string in the call args', () {
      final spec = BridgeSpec(
        dartClassName: 'Greeter',
        lib: 'greeter',
        namespace: 'greeter',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'greeter.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'greet',
            cSymbol: 'greeter_greet',
            isAsync: false,
            isNativeAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'name',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('std::string(name)'));
    });

    test('enum param is cast with static_cast<EnumType>()', () {
      final spec = BridgeSpec(
        dartClassName: 'Ctrl',
        lib: 'ctrl',
        namespace: 'ctrl',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'ctrl.native.dart',
        enums: [
          BridgeEnum(name: 'Mode', startValue: 0, values: ['on', 'off']),
        ],
        functions: [
          BridgeFunction(
            dartName: 'setMode',
            cSymbol: 'ctrl_set_mode',
            isAsync: false,
            isNativeAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'mode',
                type: BridgeType(name: 'Mode'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('static_cast<Mode>(mode)'));
    });

    test('String param has const char* type in the C function signature', () {
      final spec = BridgeSpec(
        dartClassName: 'Greeter',
        lib: 'greeter',
        namespace: 'greeter',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'greeter.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'greet',
            cSymbol: 'greeter_greet',
            isAsync: false,
            isNativeAsync: true,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'name',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('const char* name'));
    });
  });

  // ── CppBridgeGenerator — Android JNI @NitroNativeAsync ───────────────────

  BridgeSpec jniNativeAsyncSpec(String returnType) => BridgeSpec(
    dartClassName: 'Fetcher',
    lib: 'fetcher',
    namespace: 'fetcher',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'fetcher.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'fetch',
        cSymbol: 'fetcher_fetch',
        isAsync: false,
        isNativeAsync: true,
        returnType: BridgeType(name: returnType),
        params: [
          BridgeParam(
            name: 'key',
            type: BridgeType(name: 'String'),
          ),
        ],
      ),
    ],
  );

  group('CppBridgeGenerator — Android JNI @NitroNativeAsync', () {
    test('JNI_OnLoad caches method with (instanceId + params + errPtr + dartPort)V signature for native async', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('"(JLjava/lang/String;JJ)V"'));
    });

    test('Android C function is void with instanceId, error slot, and dart_port params', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('void fetcher_fetch(int64_t instanceId, const char* key, NitroError* _nitro_err, int64_t dart_port)'));
    });

    test('Android C function calls CallStaticVoidMethod with jlong dart_port', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('CallStaticVoidMethod('));
      expect(out, contains('(jlong)dart_port'));
    });

    test('Android C function\'s JNI exception check still routes to TLS (nullptr), not the errPtr out-param', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      // _nitro_err DOES now appear in this function (as a param, threaded down
      // to Kotlin as errPtr so the Kotlin-side catch block can report a
      // business-logic exception) — but the JNI-level ExceptionCheck() here
      // guards only the SYNCHRONOUS arg-marshalling code that runs before
      // Kotlin's _asyncExecutor.execute{} is scheduled, so it still can't use
      // the out-param (passing nullptr routes it to the TLS slot instead,
      // same as before).
      final start = out.indexOf('void fetcher_fetch(');
      expect(start, isNonNegative);
      final end = out.indexOf('\n}', start);
      expect(end, isNonNegative);
      final body = out.substring(start, end);
      expect(body, contains('NitroError* _nitro_err'));
      expect(body, contains('nitro_report_jni_exception(env, env->ExceptionOccurred(), nullptr);'));
    });

    test('Android/iOS bridge emits one extern C close per platform section', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(RegExp(r'} // extern "C"').allMatches(out), hasLength(2));
    });

    test('postNullToPort JNIEXPORT is emitted for specs with @NitroNativeAsync', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postNullToPort'));
    });

    test('postStringToPort JNIEXPORT uses GetStringUTFChars and Dart_PostCObject_DL', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postStringToPort'));
      expect(out, contains('GetStringUTFChars'));
      expect(out, contains('if (value == nullptr)'));
      expect(out, contains('Dart_CObject_kString'));
      expect(out, contains('Dart_CObject_kNull'));
      expect(out, contains('Dart_PostCObject_DL'));
    });

    test('postInt64ToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('int'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postInt64ToPort'));
      expect(out, contains('Dart_CObject_kInt64'));
    });

    test('postDoubleToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('double'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postDoubleToPort'));
      expect(out, contains('Dart_CObject_kDouble'));
    });

    test('postBoolToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('bool'));
      expect(out, contains('JNIEXPORT void JNICALL Java_nitro_fetcher_1module_FetcherJniBridge_postBoolToPort'));
      expect(out, contains('Dart_CObject_kBool'));
    });

    test('postXxxToPort helpers NOT emitted when no @NitroNativeAsync', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, isNot(contains('postNullToPort')));
      expect(out, isNot(contains('postStringToPort')));
    });

    test('Apple section for @NitroNativeAsync emits void + error slot + dart_port signature', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('String'));
      // The Apple #elif section should have void func(params, NitroError*, int64_t dart_port)
      expect(out, contains('void fetcher_fetch(int64_t instanceId, const char* key, NitroError* _nitro_err, int64_t dart_port)'));
      // And should declare the Swift extern as void too
      expect(out, contains('extern void _fetcher_call_fetch('));
    });
  });

  // ── CppBridgeGenerator — Android/Linux dlfcn.h ───────────────────────────

  group('CppBridgeGenerator — #include <dlfcn.h> for Android/Linux builds', () {
    // enable_native_bindings uses Dl_info, dladdr, dlopen, RTLD_* which require
    // <dlfcn.h> on Android and Linux. Without it, builds fail with:
    //   unknown type name 'Dl_info'
    //   identifier 'RTLD_LAZY' undeclared

    test('generated C++ bridge contains conditional dlfcn.h include', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('int'));
      expect(out, contains('#include <dlfcn.h>'));
    });

    test('dlfcn.h include is guarded for Android/Linux only', () {
      final out = CppBridgeGenerator.generate(jniNativeAsyncSpec('int'));
      expect(out, contains('#if defined(__ANDROID__) || defined(__linux__)'));
    });
  });

  // ── CppBridgeGenerator — bool? param type regression guard ───────────────

  group('CppBridgeGenerator — bool? param uses const uint8_t*, not int32_t', () {
    // Regression guard: a stale _paramTypeToC override previously returned
    // int32_t for bool? params, causing a conflicting-type error when the JNI
    // section (int32_t) and iOS section (const uint8_t*) declared the same
    // C function with different signatures.

    BridgeSpec boolNullableParamSpec() => BridgeSpec(
      dartClassName: 'Checker',
      lib: 'checker',
      namespace: 'checker',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'checker.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'checkMaybe',
          cSymbol: 'checker_check_maybe',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'bool'),
          params: [
            BridgeParam(
              name: 'flag',
              type: BridgeType(name: 'bool?'),
              isNamed: true,
              isOptional: true,
            ),
          ],
        ),
      ],
    );

    test('bool? NativeAsync param uses const uint8_t* in both JNI and iOS sections', () {
      final out = CppBridgeGenerator.generate(boolNullableParamSpec());
      // All occurrences of the function C signature must use const uint8_t*
      final matches = RegExp(r'checker_check_maybe\([^)]+\)').allMatches(out);
      for (final m in matches) {
        expect(m.group(0), contains('uint8_t'));
        expect(m.group(0), isNot(contains('int32_t')));
      }
    });

    test('bool? NativeAsync param: no int32_t anywhere in generated bridge', () {
      final out = CppBridgeGenerator.generate(boolNullableParamSpec());
      // int32_t was the stale sentinel type — must not appear
      expect(out, isNot(contains('int32_t flag')));
      expect(out, isNot(contains('int32_t value')));
    });
  });

  // ── CppBridgeGenerator — NativeAsync nullable prim params → jbyteArray ───

  group('CppBridgeGenerator — @NitroNativeAsync nullable prim params wrapped as jbyteArray', () {
    // Kotlin NativeAsync bridge expects ByteArray ([B JNI) for nullable prim params.
    // The C++ bridge must create a jbyteArray from the raw const uint8_t* pointer
    // before calling CallStaticVoidMethod, otherwise JNI crashes.

    BridgeSpec nullableIntParamNativeAsyncSpec() => BridgeSpec(
      dartClassName: 'Printer',
      lib: 'printer',
      namespace: 'printer',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'printer.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'print',
          cSymbol: 'printer_print',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'bool'),
          params: [
            BridgeParam(
              name: 'value',
              type: BridgeType(name: 'int?'),
              isNamed: true,
              isOptional: true,
            ),
          ],
        ),
      ],
    );

    BridgeSpec nullableBoolParamNativeAsyncSpec() => BridgeSpec(
      dartClassName: 'Toggle',
      lib: 'toggle',
      namespace: 'toggle',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'toggle.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'toggle',
          cSymbol: 'toggle_toggle',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'flag',
              type: BridgeType(name: 'bool?'),
              isNamed: true,
              isOptional: true,
            ),
          ],
        ),
      ],
    );

    test('int? NativeAsync param: C++ JNI wraps pointer in 9-byte jbyteArray', () {
      final out = CppBridgeGenerator.generate(nullableIntParamNativeAsyncSpec());
      // Must create a jbyteArray of 9 bytes for NitroOptInt64
      expect(out, contains('env->NewByteArray(9)'));
      // Must copy from the const uint8_t* pointer into the jbyteArray
      expect(out, contains('SetByteArrayRegion'));
      // Must NOT pass raw pointer as the JNI argument
      expect(out, isNot(contains('(jlong)value')));
    });

    test('bool? NativeAsync param: C++ JNI wraps pointer in 2-byte jbyteArray', () {
      final out = CppBridgeGenerator.generate(nullableBoolParamNativeAsyncSpec());
      // Must create a jbyteArray of 2 bytes for NitroOptBool
      expect(out, contains('env->NewByteArray(2)'));
      expect(out, contains('SetByteArrayRegion'));
    });

    test('int? NativeAsync param: JNI descriptor uses [B (ByteArray)', () {
      final out = CppBridgeGenerator.generate(nullableIntParamNativeAsyncSpec());
      // The JNI signature for (instanceId: Long, value: ByteArray, errPtr: Long, dartPort: Long) -> void
      expect(out, contains('(J[BJJ)V'));
    });
  });

  // ── CppBridgeGenerator — postOptXxxToPort JNIEXPORT helpers ─────────────

  group('CppBridgeGenerator — postOptXxxToPort JNIEXPORT helpers for nullable prim returns', () {
    // When @NitroNativeAsync returns int?/double?/bool?, the Kotlin side calls
    // postOptInt64ToPort/postOptFloat64ToPort/postOptBoolToPort. These helpers
    // malloc a NitroOptXxx buffer, fill it, and post the address as kInt64.
    // Dart decodes via Pointer<NitroOptXxx>.fromAddress(raw as int) and frees.

    BridgeSpec nullableIntReturnNativeAsyncSpec() => BridgeSpec(
      dartClassName: 'Scanner',
      lib: 'scanner',
      namespace: 'scanner',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'scanner.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'scan',
          cSymbol: 'scanner_scan',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'int?'),
          params: [],
        ),
      ],
    );

    BridgeSpec nullableDoubleReturnNativeAsyncSpec() => BridgeSpec(
      dartClassName: 'Sensor',
      lib: 'sensor',
      namespace: 'sensor',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'sensor.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'read',
          cSymbol: 'sensor_read',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'double?'),
          params: [],
        ),
      ],
    );

    BridgeSpec nullableBoolReturnNativeAsyncSpec() => BridgeSpec(
      dartClassName: 'Validator',
      lib: 'validator',
      namespace: 'validator',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'validator.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'validate',
          cSymbol: 'validator_validate',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'bool?'),
          params: [],
        ),
      ],
    );

    test('int? return: postOptInt64ToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(nullableIntReturnNativeAsyncSpec());
      expect(out, contains('postOptInt64ToPort'));
    });

    test('int? return: postOptInt64ToPort mallocs 9 bytes for NitroOptInt64', () {
      final out = CppBridgeGenerator.generate(nullableIntReturnNativeAsyncSpec());
      expect(out, contains('malloc(9)'));
    });

    test('int? return: postOptInt64ToPort posts address as Dart_CObject_kInt64', () {
      final out = CppBridgeGenerator.generate(nullableIntReturnNativeAsyncSpec());
      // Posts the native buffer address — Dart decodes via fromAddress
      expect(out, contains('Dart_CObject_kInt64'));
      expect(out, contains('(int64_t)(uintptr_t)buf'));
    });

    test('double? return: postOptFloat64ToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(nullableDoubleReturnNativeAsyncSpec());
      expect(out, contains('postOptFloat64ToPort'));
    });

    test('double? return: postOptFloat64ToPort mallocs 9 bytes for NitroOptFloat64', () {
      final out = CppBridgeGenerator.generate(nullableDoubleReturnNativeAsyncSpec());
      expect(out, contains('malloc(9)'));
    });

    test('bool? return: postOptBoolToPort JNIEXPORT emitted', () {
      final out = CppBridgeGenerator.generate(nullableBoolReturnNativeAsyncSpec());
      expect(out, contains('postOptBoolToPort'));
    });

    test('bool? return: postOptBoolToPort mallocs 2 bytes for NitroOptBool', () {
      final out = CppBridgeGenerator.generate(nullableBoolReturnNativeAsyncSpec());
      expect(out, contains('malloc(2)'));
    });
  });

  // ── KotlinGenerator — @NitroNativeAsync nullable prim returns ────────────

  group('KotlinGenerator — @NitroNativeAsync nullable prim returns use postOptXxxToPort', () {
    // Regression guard: old code used sentinel values for nullable prim returns:
    //   Long? → postInt64ToPort(port, result?.toLong() ?: Long.MIN_VALUE)
    //   Double? → postDoubleToPort(port, result ?: Double.NaN)
    //   Boolean? → if (result == null) postNullToPort(port) else postBoolToPort(port, result)
    //
    // Dart's NativeAsync unpack now expects a malloc'd NitroOptXxx pointer (kInt64 address),
    // not sentinel values. The new helpers postOptInt64ToPort/Float64ToPort/BoolToPort
    // allocate the struct on native heap and post the address.

    BridgeSpec nullableIntReturnSpec() => BridgeSpec(
      dartClassName: 'Scanner',
      lib: 'scanner',
      namespace: 'scanner',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'scanner.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'scan',
          cSymbol: 'scanner_scan',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'int?'),
          params: [],
        ),
      ],
    );

    BridgeSpec nullableDoubleReturnSpec() => BridgeSpec(
      dartClassName: 'Sensor',
      lib: 'sensor',
      namespace: 'sensor',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'sensor.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'read',
          cSymbol: 'sensor_read',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'double?'),
          params: [],
        ),
      ],
    );

    BridgeSpec nullableBoolReturnSpec() => BridgeSpec(
      dartClassName: 'Validator',
      lib: 'validator',
      namespace: 'validator',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'validator.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'validate',
          cSymbol: 'validator_validate',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'bool?'),
          params: [],
        ),
      ],
    );

    test('int? return: uses postOptInt64ToPort (pointer approach)', () {
      final out = KotlinGenerator.generate(nullableIntReturnSpec());
      expect(out, contains('postOptInt64ToPort(dartPort,'));
    });

    test('int? return: does NOT use Long.MIN_VALUE sentinel (old approach)', () {
      final out = KotlinGenerator.generate(nullableIntReturnSpec());
      expect(out, isNot(contains('Long.MIN_VALUE')));
    });

    test('int? return: passes result != null as hasValue flag', () {
      final out = KotlinGenerator.generate(nullableIntReturnSpec());
      expect(out, contains('result != null'));
    });

    test('double? return: uses postOptFloat64ToPort (pointer approach)', () {
      final out = KotlinGenerator.generate(nullableDoubleReturnSpec());
      expect(out, contains('postOptFloat64ToPort(dartPort,'));
    });

    test('double? return: does NOT use Double.NaN sentinel (old approach)', () {
      final out = KotlinGenerator.generate(nullableDoubleReturnSpec());
      expect(out, isNot(contains('Double.NaN')));
    });

    test('bool? return: uses postOptBoolToPort (pointer approach)', () {
      final out = KotlinGenerator.generate(nullableBoolReturnSpec());
      expect(out, contains('postOptBoolToPort(dartPort,'));
    });

    test('bool? return: does NOT use if-null postNullToPort/postBoolToPort pair (old approach)', () {
      // Old: if (result == null) postNullToPort(dartPort) else postBoolToPort(dartPort, result)
      final out = KotlinGenerator.generate(nullableBoolReturnSpec());
      expect(out, isNot(contains('if (result == null) postNullToPort')));
    });

    test('non-nullable bool return: still uses postBoolToPort (unchanged)', () {
      final out = KotlinGenerator.generate(_nativeAsyncBoolSpec());
      expect(out, contains('postBoolToPort(dartPort,'));
    });

    test('non-nullable int return: still uses postInt64ToPort (unchanged)', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('postInt64ToPort(dartPort,'));
    });

    test('postOptXxxToPort helpers declared as external JvmStatic', () {
      final out = KotlinGenerator.generate(nullableIntReturnSpec());
      expect(out, contains('@JvmStatic external fun postOptInt64ToPort(dartPort: Long, value: Long, hasValue: Boolean)'));
      expect(out, contains('@JvmStatic external fun postOptFloat64ToPort(dartPort: Long, value: Double, hasValue: Boolean)'));
      expect(out, contains('@JvmStatic external fun postOptBoolToPort(dartPort: Long, value: Boolean, hasValue: Boolean)'));
    });

    test('postOptXxxToPort NOT declared for specs with no @NitroNativeAsync', () {
      final out = KotlinGenerator.generate(simpleSpec());
      expect(out, isNot(contains('postOptInt64ToPort')));
    });
  });

  // ── @NitroNativeAsync error propagation ───────────────────────────────────
  //
  // Real error propagation for @nitroNativeAsync — previously a thrown native
  // exception was silently discarded and Dart received a "successful" null
  // (invisible for Future<void> methods entirely, since the native-async
  // unpack for void is `(_) {}` — the posted value is never even inspected).
  // Mirrors the S8 out-param mechanism sync/@nitroAsync already use, but with
  // a FRESH NitroErrorFfi struct allocated per call (not the one instance-
  // owned slot sync reuses) since native-async calls aren't serialized.

  group('KotlinGenerator — @NitroNativeAsync error propagation', () {
    test('reportNativeAsyncError declared as external JvmStatic alongside the post*ToPort family', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('@JvmStatic external fun reportNativeAsyncError(errPtr: Long, name: String, message: String)'));
    });

    test('_call method threads errPtr: Long before dartPort: Long', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('compute_call(instanceId: Long, x: Long, errPtr: Long, dartPort: Long)'));
    });

    test('impl-not-found early exit reports an error before posting null', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      final idx = out.indexOf('_implementations[instanceId]');
      final guard = out.substring(idx, out.indexOf('}', idx) + 1);
      expect(guard, contains('reportNativeAsyncError(errPtr, "IllegalStateException", "No implementation registered for instance")'));
      expect(guard, contains('postNullToPort(dartPort)'));
    });

    test('catch block reports the thrown exception before posting null', () {
      final out = KotlinGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('} catch (e: Throwable) {'));
      expect(out, contains('reportNativeAsyncError(errPtr, e.javaClass.simpleName, e.message ?: "An unknown native exception occurred.")'));
      expect(out, contains('postNullToPort(dartPort)'));
    });
  });

  group('CppBridgeGenerator — @NitroNativeAsync error propagation (JNI)', () {
    test('JNI signature gains a second trailing J for the error-struct address', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('"(JJJJ)V"'));
    });

    test('C bridge function threads NitroError* before dart_port and forwards it as a jlong', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('void compute_compute(int64_t instanceId, int64_t x, NitroError* _nitro_err, int64_t dart_port)'));
      expect(out, contains('(jlong)(uintptr_t)_nitro_err'));
    });

    test('reportNativeAsyncError JNIEXPORT reconstructs the NitroError* and strdups both jstrings', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncIntSpec());
      final idx = out.indexOf('reportNativeAsyncError(JNIEnv* env, jclass, jlong errPtr, jstring name, jstring message)');
      expect(idx, greaterThan(-1));
      final body = out.substring(idx, out.indexOf('\n}', idx));
      expect(body, contains('NitroError* err = (NitroError*)(uintptr_t)errPtr;'));
      expect(body, contains('if (err == nullptr) { return; }'));
      expect(body, contains('err->hasError = 1;'));
      expect(body, contains('GetStringUTFChars(name, nullptr)'));
      expect(body, contains('err->name = strdup(cName);'));
      expect(body, contains('GetStringUTFChars(message, nullptr)'));
      expect(body, contains('err->message = strdup(cMsg);'));
    });
  });

  group('CppBridgeGenerator — @NitroNativeAsync error propagation (Apple-C++-direct, mixed platforms)', () {
    // androidImpl: kotlin + iosImpl: cpp — exercises the embedded
    // _emitAppleCppDispatch path in cpp_bridge_generator.dart, a DIFFERENT
    // code path from the pure-C++-everywhere cpp_direct_emitter.dart tested
    // above (e.g. CppBridgeGenerator — @NitroNativeAsync (direct C++ path)).
    BridgeSpec mixedSpec() => BridgeSpec(
      dartClassName: 'Mixed',
      lib: 'mixed',
      namespace: 'mixed',
      iosImpl: NativeImpl.cpp,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mixed.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'doStuff',
          cSymbol: 'mixed_do_stuff',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'void'),
          params: [BridgeParam(name: 'x', type: BridgeType(name: 'int'))],
        ),
      ],
    );

    test('Apple section wraps the impl call in try/catch and threads NitroError* through', () {
      final out = CppBridgeGenerator.generate(mixedSpec());
      // Two definitions of mixed_do_stuff exist (Android JNI + Apple C++
      // direct) under separate #ifdef branches — the Apple one is the LAST
      // occurrence and is the only one with `g_impl->doStuff(`.
      final idx = out.lastIndexOf('void mixed_do_stuff(');
      final body = out.substring(idx, out.indexOf('\n}', idx));
      expect(body, contains('void mixed_do_stuff(int64_t instanceId, int64_t x, NitroError* _nitro_err, int64_t dart_port) {'));
      expect(body, contains('if (_nitro_err) { _nitro_err->hasError = 0; }'));
      expect(body, contains('try {'));
      expect(body, contains('g_impl->doStuff(x, _nitro_err, dart_port);'));
      expect(body, contains('} catch (const std::exception& e) {'));
      expect(body, contains('_nitro_desktop_err(_nitro_err, "CppException", e.what());'));
      expect(body, contains('} catch (...) {'));
    });
  });

  group('SwiftGenerator — @NitroNativeAsync error propagation', () {
    test('@_cdecl signature gains a trailing errPtr: Int64 before dartPort: Int64', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('public func _compute_call_compute(_ x: Int64, _ errPtr: Int64, _ dartPort: Int64) {'));
    });

    test('errPtr is reconstructed into an UnsafeMutablePointer<NitroError>?', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      // init?(bitPattern:) is already failable — no `?` after the type name,
      // or Swift tries (and fails) to resolve a nonexistent
      // Optional<T>.init(bitPattern:).
      expect(out, contains('let _errPtr = UnsafeMutablePointer<NitroError>(bitPattern: UInt(bitPattern: Int(errPtr)))'));
    });

    test('dispatch chain is wrapped in do/catch — a throw no longer collapses to a default value', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('        do {'));
      expect(out, isNot(contains('try? await impl.compute')));
      expect(out, contains('try await impl.compute'));
    });

    test('shared catch writes name/message into the error struct, then still posts exactly one message', () {
      final out = SwiftGenerator.generate(_nativeAsyncIntSpec());
      final idx = out.indexOf('} catch {');
      expect(idx, greaterThan(-1));
      final body = out.substring(idx, out.indexOf('\n    }\n}', idx));
      expect(body, contains('if let _errPtr = _errPtr {'));
      expect(body, contains('let _nsErr = error as NSError'));
      expect(body, contains('_errPtr.pointee.hasError = 1'));
      // Explicit UnsafePointer(_:) conversion — strdup returns a mutable
      // pointer but NitroError's fields are the immutable UnsafePointer<CChar>?.
      expect(body, contains('_errPtr.pointee.name = UnsafePointer(strdup(_nsErr.domain))'));
      expect(body, contains('_errPtr.pointee.message = UnsafePointer(strdup(_nsErr.localizedDescription))'));
      expect(body, contains('_null.type = Dart_CObject_kNull'));
      expect(body, contains('Dart_PostCObject_DL(dartPort, &_null)'));
    });

    test('ObjC++ wrapper (emitted by CppBridgeGenerator) passes err_ptr through with no @try/@catch (returns before Task.detached runs)', () {
      final out = CppBridgeGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('extern void _compute_call_compute(int64_t x, int64_t err_ptr, int64_t dart_port);'));
      expect(out, contains('void compute_compute(int64_t instanceId, int64_t x, NitroError* _nitro_err, int64_t dart_port) {'));
      expect(out, contains('_compute_call_compute(x, (int64_t)(uintptr_t)_nitro_err, dart_port);'));
    });
  });

  group('DartFfiGenerator — @NitroNativeAsync error propagation', () {
    test('a fresh NitroErrorFfi struct is allocated per call, not the instance field', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('final _nitroErr = calloc<NitroErrorFfi>();'));
    });

    test('the error slot is passed into the native call right before the port', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('_computePtr(_instanceId, x, _nitroErr, port)'));
    });

    test('unpack checks and frees the error slot before decoding the posted value', () {
      final out = DartFfiGenerator.generate(_nativeAsyncIntSpec());
      expect(out, contains('unpack: (raw) { NitroRuntime.throwIfOutParamErrorAndFree(_nitroErr); return'));
    });
  });
}
