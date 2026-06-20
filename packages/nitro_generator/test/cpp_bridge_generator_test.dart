import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('CppBridgeGenerator', () {
    test('emits InitDartApiDL', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('NITRO_EXPORT intptr_t my_camera_init_dart_api_dl(void* data)'));
      expect(out, contains('Dart_InitializeApiDL(data)'));
    });

    test('emits ABI version symbol', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(
        out,
        contains('NITRO_EXPORT uint32_t my_camera_nitro_abi_version(void)'),
      );
      expect(out, contains('return 1;'));
    });

    test('emits bridge checksum symbol', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(
        out,
        contains('NITRO_EXPORT const char* my_camera_nitro_bridge_checksum(void)'),
      );
      expect(out, matches(RegExp(r'return "[0-9a-f]{16}";')));
    });

    test('zero-copy TypedData JNI return wraps direct ByteBuffer without array copy', () {
      final out = CppBridgeGenerator.generate(
        BridgeSpec(
          dartClassName: 'Dsp',
          lib: 'dsp',
          namespace: 'dsp',
          androidImpl: NativeImpl.kotlin,
          sourceUri: 'dsp.native.dart',
          functions: [
            BridgeFunction(
              dartName: 'snapshot',
              cSymbol: 'dsp_snapshot',
              isAsync: false,
              returnType: BridgeType(name: 'Uint8List'),
              zeroCopyReturn: true,
              params: [],
            ),
          ],
        ),
      );

      expect(out, contains('GetStaticMethodID(g_bridgeClass, "snapshot_call", "()Ljava/nio/ByteBuffer;")'));
      expect(out, contains('void* data = env->GetDirectBufferAddress(jbuf);'));
      expect(out, contains('jobject owner = env->NewGlobalRef(jbuf);'));
      expect(out, contains('result[1] = (int64_t)(intptr_t)(data != nullptr ? data : result);'));
      expect(out, contains('NITRO_EXPORT void dsp_release_typed_data_return(void* ptr)'));
      expect(out, isNot(contains('GetByteArrayRegion(jarr')));
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
      expect(out, contains('if (methodId == nullptr) { LOGE("Method not found: doSomething_call sig=()V"); return; }'));
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
    test('JNI cleanup is emitted for object arguments', () {
      final spec = BridgeSpec(
        dartClassName: 'MyCamera',
        lib: 'my_camera',
        namespace: 'my_camera_module',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'my_camera.native.dart',
        structs: [
          BridgeStruct(
            name: 'Point',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'uploadData',
            cSymbol: 'my_camera_upload_data',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'name',
                type: BridgeType(name: 'String'),
                zeroCopy: false,
              ),
              BridgeParam(
                name: 'pt',
                type: BridgeType(name: 'Point'),
                zeroCopy: false,
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      // The generator uses PushLocalFrame/PopLocalFrame — all local refs
      // (j_name, jobj_pt) are freed automatically when the frame pops,
      // so explicit DeleteLocalRef per-param is not emitted.
      expect(out, contains('env->PushLocalFrame(16)'));
      expect(out, contains('env->PopLocalFrame(nullptr)'));
    });

    test('struct stream emit uses malloc', () {
      final out = CppBridgeGenerator.generate(structStreamSpec());
      expect(out, contains('CameraFrame* st_ptr = (CameraFrame*)malloc(sizeof(CameraFrame))'));
    });

    test('struct stream with ZeroCopy fields checks ExceptionCheck after pack_ and before NewGlobalRef', () {
      final out = CppBridgeGenerator.generate(structStreamSpec());
      expect(out, contains('*st_ptr = pack_CameraFrame_from_jni(env, item);'));
      expect(out, contains('if (env->ExceptionCheck()) {'));
      expect(out, contains('env->ExceptionDescribe();'));
      expect(out, contains('env->ExceptionClear();'));
      expect(out, contains('free(st_ptr);'));
      expect(out, contains('return;'));
      expect(
        out,
        contains('g_zero_copy_refs[(void*)st_ptr] = env->NewGlobalRef(item);'),
      );
      final packPos = out.indexOf('pack_CameraFrame_from_jni(env, item);');
      final exCheckPos = out.indexOf('env->ExceptionCheck()', packPos);
      final newGlobalRefPos = out.indexOf('NewGlobalRef(item)', packPos);
      expect(exCheckPos, lessThan(newGlobalRefPos), reason: 'ExceptionCheck must come BEFORE NewGlobalRef');
    });

    test('iOS section emits extern _call functions', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('#elif __APPLE__'));
      // namespace = 'my_camera_module' → _my_camera_module_call_add
      expect(out, contains('extern double _my_camera_module_call_add(double a, double b)'));
    });

    test('emits shared struct release functions', () {
      final out = CppBridgeGenerator.generate(structStreamSpec());
      // Should find the release function before the platform guards
      final releasePos = out.indexOf('void my_camera_release_CameraFrame(void* ptr)');
      final androidPos = out.indexOf('#ifdef __ANDROID__');
      expect(releasePos, isNot(-1));
      expect(androidPos, isNot(-1));
      expect(releasePos, lessThan(androidPos), reason: 'Release function should be in the shared section before platform guards');
    });

    test('struct with string release frees field', () {
      final spec = BridgeSpec(
        lib: 'test_lib',
        namespace: 'nitro.test',
        dartClassName: 'Test',
        sourceUri: 'test.native.dart',
        structs: [
          BridgeStruct(
            name: 'User',
            packed: false,
            fields: [
              BridgeField(
                name: 'id',
                type: BridgeType(name: 'int'),
              ),
              BridgeField(
                name: 'name',
                type: BridgeType(name: 'String'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('void test_lib_release_User(void* ptr)'));
      expect(out, contains('User* st_ptr = (User*)ptr;'));
      expect(out, contains('if (st_ptr->name) free((void*)st_ptr->name);'));
    });
  });

  group('CppBridgeGenerator (edge cases)', () {
    test('iOS functions wrap @try in #ifdef __OBJC__', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      final parts = out.split('#elif __APPLE__');
      expect(parts.length, greaterThan(1), reason: 'Output should contain "#elif __APPLE__"');
      final applePart = parts[1];
      expect(applePart, contains('#ifdef __OBJC__'));
      expect(applePart, contains('@try {'));
    });

    test('String return uses strdup and local-frame cleanup', () {
      final out = CppBridgeGenerator.generate(richSpec());
      expect(out, contains('strdup(nativeStr)'));
      // jstr lives inside the PushLocalFrame/PopLocalFrame region — freed
      // automatically when the frame pops rather than via a manual DeleteLocalRef.
      expect(out, contains('env->ReleaseStringUTFChars(jstr, nativeStr)'));
      expect(out, contains('env->PopLocalFrame(nullptr)'));
    });

    test('iOS section emits property getter extern', () {
      final out = CppBridgeGenerator.generate(richSpec());
      // namespace = 'sensor' → _sensor_call_get_enabled
      expect(out, contains('extern int8_t _sensor_call_get_enabled(void)'));
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

    // Both-platform C++ — no platform guard needed since the bridge is
    // platform-agnostic (no JNI, no Swift).
    test('both-platform cpp emits NO platform guard', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, isNot(contains('#ifdef __APPLE__')));
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });
  });

  group('CppBridgeGenerator (cpp direct path) — single-platform guards', () {
    test('iOS-only cpp wraps body in #ifdef __APPLE__', () {
      final spec = BridgeSpec(
        dartClassName: 'Renderer',
        lib: 'renderer',
        namespace: 'renderer',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'renderer.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'draw',
            cSymbol: 'renderer_draw',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('#ifdef __APPLE__'));
      expect(out, contains('#endif // __APPLE__'));
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('iOS-only cpp guard appears before #include', () {
      final spec = BridgeSpec(
        dartClassName: 'Renderer',
        lib: 'renderer',
        namespace: 'renderer',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'renderer.native.dart',
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(
        out.indexOf('#ifdef __APPLE__'),
        lessThan(out.indexOf('#include <stdint.h>')),
      );
    });

    test('iOS-only cpp guard end (#endif) appears after register_impl', () {
      final spec = BridgeSpec(
        dartClassName: 'Renderer',
        lib: 'renderer',
        namespace: 'renderer',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'renderer.native.dart',
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(
        out.indexOf('renderer_register_impl'),
        lessThan(out.lastIndexOf('#endif // __APPLE__')),
      );
    });

    test('Android-only cpp wraps body in #ifdef __ANDROID__', () {
      final spec = BridgeSpec(
        dartClassName: 'Scanner',
        lib: 'scanner',
        namespace: 'scanner',
        androidImpl: NativeImpl.cpp,
        sourceUri: 'scanner.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'scan',
            cSymbol: 'scanner_scan',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('#ifdef __ANDROID__'));
      expect(out, contains('#endif // __ANDROID__'));
      expect(out, isNot(contains('#ifdef __APPLE__')));
    });

    test('Android-only cpp guard appears before #include', () {
      final spec = BridgeSpec(
        dartClassName: 'Scanner',
        lib: 'scanner',
        namespace: 'scanner',
        androidImpl: NativeImpl.cpp,
        sourceUri: 'scanner.native.dart',
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(
        out.indexOf('#ifdef __ANDROID__'),
        lessThan(out.indexOf('#include <stdint.h>')),
      );
    });

    test('Android-only cpp guard end (#endif) appears after register_impl', () {
      final spec = BridgeSpec(
        dartClassName: 'Scanner',
        lib: 'scanner',
        namespace: 'scanner',
        androidImpl: NativeImpl.cpp,
        sourceUri: 'scanner.native.dart',
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(
        out.indexOf('scanner_register_impl'),
        lessThan(out.lastIndexOf('#endif // __ANDROID__')),
      );
    });

    test('iOS-only cpp does NOT emit JNI_OnLoad', () {
      final spec = BridgeSpec(
        dartClassName: 'AudioEngine',
        lib: 'audio_engine',
        namespace: 'audio_engine',
        iosImpl: NativeImpl.cpp,
        sourceUri: 'audio_engine.native.dart',
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, isNot(contains('JNI_OnLoad')));
      expect(out, contains('#ifdef __APPLE__'));
    });

    test('Android-only cpp does NOT emit Swift _call_ declarations', () {
      final spec = BridgeSpec(
        dartClassName: 'AudioEngine',
        lib: 'audio_engine',
        namespace: 'audio_engine',
        androidImpl: NativeImpl.cpp,
        sourceUri: 'audio_engine.native.dart',
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, isNot(contains('_call_')));
      expect(out, contains('#ifdef __ANDROID__'));
    });
  });

  group('CppBridgeGenerator (JNI parameters)', () {
    test('String param converts to jstring via NewStringUTF', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(out, contains('NewStringUTF(name)'));
      expect(out, contains('j_name'));
    });

    test('struct param calls unpack_X_to_jni', () {
      final out = CppBridgeGenerator.generate(richSpec());
      expect(out, contains('unpack_Reading_to_jni'));
    });

    test('int param is passed through unchanged to JNI call', () {
      final spec = BridgeSpec(
        dartClassName: 'Counter',
        lib: 'counter',
        namespace: 'counter',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'counter.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'increment',
            cSymbol: 'counter_increment',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [
              BridgeParam(
                name: 'amount',
                type: BridgeType(name: 'int'),
              ),
            ],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      // amount is an int64_t — passed as-is (no jstring wrapping etc.)
      expect(out, contains('amount'));
      expect(out, isNot(contains('NewStringUTF(amount)')));
    });

    test('bool return checks ExceptionCheck before returning', () {
      final spec = BridgeSpec(
        dartClassName: 'Flags',
        lib: 'flags',
        namespace: 'flags',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'flags.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'isOn',
            cSymbol: 'flags_is_on',
            isAsync: false,
            returnType: BridgeType(name: 'bool'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('ExceptionCheck'));
      expect(out, contains('return false'));
    });

    test('int return checks ExceptionCheck before returning', () {
      final spec = BridgeSpec(
        dartClassName: 'Counts',
        lib: 'counts',
        namespace: 'counts',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'counts.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'total',
            cSymbol: 'counts_total',
            isAsync: false,
            returnType: BridgeType(name: 'int'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('ExceptionCheck'));
      expect(out, contains('return 0'));
    });

    test('clear_error is called before each JNI function body', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      // Both add() and getGreeting() should clear error before invoking JNI.
      final count = 'my_camera_clear_error()'.allMatches(out).length;
      expect(count, greaterThanOrEqualTo(2));
    });

    test('error slot is thread-local for JNI and Swift bridge calls', () {
      final out = CppBridgeGenerator.generate(simpleSpec());
      expect(
        out,
        contains('static thread_local NitroError g_nitro_error'),
        reason: 'concurrent calls on separate native threads must not share error state',
      );
      expect(out, contains('NitroError* my_camera_get_error() { return &g_nitro_error; }'));
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

    test('emits ABI version symbol for cpp direct path', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(
        out,
        contains('NITRO_EXPORT uint32_t math_nitro_abi_version(void)'),
      );
      expect(out, contains('return 1;'));
    });

    test('emits bridge checksum symbol for cpp direct path', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(
        out,
        contains('NITRO_EXPORT const char* math_nitro_bridge_checksum(void)'),
      );
      expect(out, matches(RegExp(r'return "[0-9a-f]{16}";')));
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

    test('String return uses strdup on std::string result', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, contains('std::string _res = g_impl->greet('));
      expect(out, contains('return strdup(_res.c_str())'));
    });

    test('String param is wrapped in std::string()', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, contains('std::string(name)'));
    });

    test('clear_error is called before each cpp direct function', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      // libStem = spec.lib = 'math', so symbol is math_clear_error()
      final count = 'math_clear_error()'.allMatches(out).length;
      // add() + greet() + get_precision() + set_precision() = at least 4
      expect(count, greaterThanOrEqualTo(4));
    });

    test('error slot is thread-local for cpp direct calls', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(
        out,
        contains('static thread_local NitroError g_nitro_error'),
        reason: 'C++ direct calls may run on different native threads',
      );
      expect(out, contains('NitroError* math_get_error() { return &g_nitro_error; }'));
    });

    test('enum return uses static_cast<int64_t>', () {
      final out = CppBridgeGenerator.generate(cppEnumSpec());
      expect(out, contains('static_cast<int64_t>(g_impl->getMode())'));
    });

    test('enum property getter uses static_cast<int64_t>', () {
      final spec = BridgeSpec(
        dartClassName: 'Dev',
        lib: 'dev',
        namespace: 'dev',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'dev.native.dart',
        enums: [
          BridgeEnum(name: 'Mode', startValue: 0, values: ['a', 'b']),
        ],
        properties: [
          BridgeProperty(
            dartName: 'mode',
            type: BridgeType(name: 'Mode'),
            getSymbol: 'dev_get_mode',
            setSymbol: 'dev_set_mode',
            hasGetter: true,
            hasSetter: true,
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('static_cast<int64_t>(g_impl->get_mode())'));
    });

    test('stream register/release functions are emitted in cpp path', () {
      final out = CppBridgeGenerator.generate(cppStreamSpec());
      // Symbols come from stream.registerSymbol / stream.releaseSymbol directly
      expect(out, contains('void lidar_register_points_stream(int64_t dart_port)'));
      expect(out, contains('void lidar_release_points_stream(int64_t dart_port)'));
    });

    test('enum stream emits Int64 instead of Null', () {
      final spec = BridgeSpec(
        dartClassName: 'Device',
        lib: 'device',
        namespace: 'device',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'device.native.dart',
        enums: [
          BridgeEnum(name: 'Status', startValue: 0, values: ['idle', 'running']),
        ],
        streams: [
          BridgeStream(
            dartName: 'statusStream',
            registerSymbol: 'device_register_status_stream',
            releaseSymbol: 'device_release_status_stream',
            itemType: BridgeType(name: 'Status'),
            backpressure: Backpressure.block,
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      expect(out, contains('Dart_CObject_kInt64'));
      expect(out, isNot(contains('Dart_CObject_kNull')));
    });

    test('cpp direct bridge header comment identifies it as cpp path', () {
      final out = CppBridgeGenerator.generate(cppSpec());
      expect(out, contains('NativeImpl: cpp'));
    });

    group('nullable @HybridStruct param null guard', () {
      BridgeSpec nullableStructCppSpec({
        NativeImpl iosImpl = NativeImpl.cpp,
        NativeImpl androidImpl = NativeImpl.cpp,
        String returnType = 'int',
      }) => BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: iosImpl,
        androidImpl: androidImpl,
        sourceUri: 'mod.native.dart',
        structs: [
          BridgeStruct(
            name: 'Foo',
            packed: false,
            fields: [
              BridgeField(
                name: 'x',
                type: BridgeType(name: 'double'),
              ),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'fn',
            cSymbol: 'mod_fn',
            isAsync: false,
            returnType: BridgeType(name: returnType),
            params: [
              BridgeParam(
                name: 'x',
                type: BridgeType(name: 'Foo?', isNullable: true),
              ),
            ],
          ),
        ],
      );

      test('direct C++ bridge reports error before dereferencing nullable struct', () {
        final out = CppBridgeGenerator.generate(nullableStructCppSpec());
        final guard = out.indexOf('if (x == nullptr) {');
        final deref = out.indexOf('*static_cast<const Foo*>(x)');

        expect(guard, isNot(-1));
        expect(out, contains('nitro_report_error("NullPointerException", "Parameter x for fn cannot be null.", nullptr, nullptr);'));
        expect(out, contains('return 0;'));
        expect(deref, isNot(-1));
        expect(guard, lessThan(deref));
      });

      test('direct C++ void return guard returns without a value', () {
        final out = CppBridgeGenerator.generate(
          nullableStructCppSpec(returnType: 'void'),
        );
        expect(out, contains('if (x == nullptr) {\n        nitro_report_error("NullPointerException", "Parameter x for fn cannot be null.", nullptr, nullptr);\n        return;\n    }'));
      });

      test('Apple C++ dispatch reports error before dereferencing nullable struct', () {
        final out = CppBridgeGenerator.generate(
          nullableStructCppSpec(androidImpl: NativeImpl.kotlin),
        );
        final appleStart = out.indexOf('#elif __APPLE__');
        final guard = out.indexOf('if (x == nullptr) {', appleStart);
        final deref = out.indexOf('*static_cast<const Foo*>(x)', appleStart);

        expect(appleStart, isNot(-1));
        expect(guard, isNot(-1));
        expect(deref, isNot(-1));
        expect(guard, lessThan(deref));
        expect(out.substring(appleStart), contains('return 0;'));
      });
    });

    group('nullable primitive return types call JNI method (not just return 0)', () {
      BridgeSpec nullableReturnSpec(String returnTypeName) => BridgeSpec(
        dartClassName: 'MyModule',
        lib: 'my_module',
        namespace: 'my_module_ns',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'my_module.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'getValue',
            cSymbol: 'my_module_get_value',
            isAsync: false,
            returnType: BridgeType(name: returnTypeName),
            params: [],
          ),
        ],
      );

      test('int? return calls CallStaticLongMethod', () {
        final out = CppBridgeGenerator.generate(nullableReturnSpec('int?'));
        expect(out, contains('CallStaticLongMethod'), reason: 'int? must call CallStaticLongMethod, not just return 0');
      });

      test('double? return calls CallStaticDoubleMethod', () {
        final out = CppBridgeGenerator.generate(nullableReturnSpec('double?'));
        expect(out, contains('CallStaticDoubleMethod'), reason: 'double? must call CallStaticDoubleMethod');
      });

      test('bool? return calls CallStaticBooleanMethod', () {
        final out = CppBridgeGenerator.generate(nullableReturnSpec('bool?'));
        expect(out, contains('CallStaticBooleanMethod'), reason: 'bool? must call CallStaticBooleanMethod');
      });

      test('String? return calls CallStaticObjectMethod', () {
        final out = CppBridgeGenerator.generate(nullableReturnSpec('String?'));
        expect(out, contains('CallStaticObjectMethod'), reason: 'String? must call CallStaticObjectMethod');
      });

      test('int? return has same JNI call pattern as int return', () {
        final nullable = CppBridgeGenerator.generate(nullableReturnSpec('int?'));
        final nonNullable = CppBridgeGenerator.generate(nullableReturnSpec('int'));
        String extractAndroidBlock(String src) {
          final start = src.indexOf('#ifdef __ANDROID__');
          final end = src.indexOf('#endif // __ANDROID__');
          return end > start ? src.substring(start, end) : src;
        }

        expect(
          extractAndroidBlock(nullable),
          contains('CallStaticLongMethod'),
        );
        expect(
          extractAndroidBlock(nonNullable),
          contains('CallStaticLongMethod'),
        );
      });
    });
  });
}
