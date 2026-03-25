// Tests for JNI performance optimizations in generated bridge code.
//
// Covers three high-impact fixes:
//
//   Fix 1 — JNI ID caching: FindClass, GetStaticMethodID, GetFieldID, GetMethodID
//     are called inside every bridge function in the old code. Now all IDs are
//     declared as static globals and initialized once in JNI_OnLoad, eliminating
//     per-call classloader traversal.
//
//   Fix 2 — Async thread pool: Kotlin bridge previously used runBlocking{} directly
//     in _call methods, blocking the calling thread. Now a private _asyncExecutor
//     (newCachedThreadPool) is used so blocking is moved off the Dart isolate threads.
//
//   Fix 3 — Exception method ID caching: nitro_report_jni_exception previously
//     called FindClass("java/lang/Class") and FindClass("java/lang/Throwable") on
//     every exception. Now g_exc_getName and g_exc_getMessage are cached globals.

import 'package:nitro/nitro.dart' show NativeImpl, Backpressure;
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:test/test.dart';

// ── Shared spec builders ─────────────────────────────────────────────────────

BridgeSpec _specWithFunctions() {
  return BridgeSpec(
    dartClassName: 'PerfMod',
    lib: 'perf_mod',
    namespace: 'perf_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'perf.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'multiply',
        cSymbol: 'perf_mod_multiply',
        isAsync: false,
        returnType: BridgeType(name: 'double'),
        params: [
          BridgeParam(name: 'a', type: BridgeType(name: 'double')),
          BridgeParam(name: 'b', type: BridgeType(name: 'double')),
        ],
      ),
      BridgeFunction(
        dartName: 'fetchData',
        cSymbol: 'perf_mod_fetch_data',
        isAsync: true,
        returnType: BridgeType(name: 'String'),
        params: [],
      ),
    ],
  );
}

BridgeSpec _specWithProperties() {
  return BridgeSpec(
    dartClassName: 'PropMod',
    lib: 'prop_mod',
    namespace: 'prop_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'prop.native.dart',
    properties: [
      BridgeProperty(
        dartName: 'count',
        getSymbol: 'prop_mod_get_count',
        setSymbol: 'prop_mod_set_count',
        type: BridgeType(name: 'int'),
        hasGetter: true,
        hasSetter: true,
      ),
    ],
  );
}

BridgeSpec _specWithStructs() {
  return BridgeSpec(
    dartClassName: 'StructMod',
    lib: 'struct_mod',
    namespace: 'struct_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'struct.native.dart',
    structs: [
      BridgeStruct(
        name: 'Point',
        packed: false,
        fields: [
          BridgeField(name: 'x', type: BridgeType(name: 'double')),
          BridgeField(name: 'y', type: BridgeType(name: 'double')),
        ],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'getPoint',
        cSymbol: 'struct_mod_get_point',
        isAsync: false,
        returnType: BridgeType(name: 'Point'),
        params: [],
      ),
    ],
  );
}

BridgeSpec _specWithStreams() {
  return BridgeSpec(
    dartClassName: 'StreamMod',
    lib: 'stream_mod',
    namespace: 'stream_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'stream.native.dart',
    streams: [
      BridgeStream(
        dartName: 'temperature',
        registerSymbol: 'stream_mod_register_temperature',
        releaseSymbol: 'stream_mod_release_temperature',
        itemType: BridgeType(name: 'double'),
        backpressure: Backpressure.dropLatest,
      ),
    ],
  );
}

BridgeSpec _specWithEnum() {
  return BridgeSpec(
    dartClassName: 'EnumMod',
    lib: 'enum_mod',
    namespace: 'enum_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'enum.native.dart',
    enums: [
      BridgeEnum(name: 'Color', startValue: 0, values: ['red', 'green', 'blue']),
    ],
    functions: [
      BridgeFunction(
        dartName: 'getColor',
        cSymbol: 'enum_mod_get_color',
        isAsync: false,
        returnType: BridgeType(name: 'Color'),
        params: [],
      ),
      BridgeFunction(
        dartName: 'fetchColor',
        cSymbol: 'enum_mod_fetch_color',
        isAsync: true,
        returnType: BridgeType(name: 'Color'),
        params: [],
      ),
    ],
  );
}

void main() {
  // ── Fix 3: Exception method ID caching ─────────────────────────────────────

  group('CppBridgeGenerator — Fix 3: exception method ID caching', () {
    test('declares g_exc_getName static global', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('static jmethodID g_exc_getName = nullptr;'));
    });

    test('declares g_exc_getMessage static global', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('static jmethodID g_exc_getMessage = nullptr;'));
    });

    test('JNI_OnLoad caches g_exc_getName via FindClass("java/lang/Class")', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('FindClass("java/lang/Class")'));
      expect(cpp, contains('g_exc_getName = env->GetMethodID(cls_class, "getName", "()Ljava/lang/String;")'));
    });

    test('JNI_OnLoad caches g_exc_getMessage via FindClass("java/lang/Throwable")', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('FindClass("java/lang/Throwable")'));
      expect(cpp, contains('g_exc_getMessage = env->GetMethodID(throwable_class, "getMessage", "()Ljava/lang/String;")'));
    });

    test('nitro_report_jni_exception uses g_exc_getName (not inline GetMethodID)', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('CallObjectMethod(ex_class, g_exc_getName)'));
    });

    test('nitro_report_jni_exception uses g_exc_getMessage (not inline GetMethodID)', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('CallObjectMethod(ex, g_exc_getMessage)'));
    });

    test('nitro_report_jni_exception does NOT re-fetch getName inline (only in JNI_OnLoad)', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      // Should appear exactly once — only in JNI_OnLoad initialization, not in the function body
      final count = 'GetMethodID(cls_class, "getName"'.allMatches(cpp).length;
      expect(count, equals(1), reason: 'getName GetMethodID must only appear once (in JNI_OnLoad)');
    });

    test('nitro_report_jni_exception does NOT call FindClass("java/lang/Throwable") inline in function body', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      // FindClass("java/lang/Throwable") must only appear in JNI_OnLoad, not repeated
      final count = 'FindClass("java/lang/Throwable")'.allMatches(cpp).length;
      expect(count, equals(1), reason: 'Only one call to FindClass for Throwable: in JNI_OnLoad');
    });
  });

  // ── Fix 1a: Function method ID caching ───────────────────────────────────────

  group('CppBridgeGenerator — Fix 1a: function method ID globals', () {
    test('declares g_mid_multiply_call static global', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('static jmethodID g_mid_multiply_call = nullptr;'));
    });

    test('declares g_mid_fetchData_call static global', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('static jmethodID g_mid_fetchData_call = nullptr;'));
    });

    test('JNI_OnLoad initializes g_mid_multiply_call via GetStaticMethodID', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('g_mid_multiply_call = env->GetStaticMethodID(g_bridgeClass, "multiply_call"'));
    });

    test('JNI_OnLoad initializes g_mid_fetchData_call via GetStaticMethodID', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('g_mid_fetchData_call = env->GetStaticMethodID(g_bridgeClass, "fetchData_call"'));
    });

    test('function body uses g_mid_multiply_call (not GetStaticMethodID inline)', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('jmethodID methodId = g_mid_multiply_call;'));
    });

    test('function body uses g_mid_fetchData_call (not GetStaticMethodID inline)', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('jmethodID methodId = g_mid_fetchData_call;'));
    });

    test('function body does NOT call GetStaticMethodID inline for multiply', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      // GetStaticMethodID for multiply should only be in JNI_OnLoad
      final inlinePattern = 'env->GetStaticMethodID(g_bridgeClass, "multiply_call"';
      final count = inlinePattern.allMatches(cpp).length;
      expect(count, equals(1), reason: 'GetStaticMethodID for multiply_call must appear only once (in JNI_OnLoad)');
    });
  });

  // ── Fix 1b: Property method ID caching ───────────────────────────────────────

  group('CppBridgeGenerator — Fix 1b: property method ID globals', () {
    test('declares g_mid_get and g_mid_set for count property', () {
      final cpp = CppBridgeGenerator.generate(_specWithProperties());
      expect(cpp, contains('static jmethodID g_mid_prop_mod_get_count_call = nullptr;'));
      expect(cpp, contains('static jmethodID g_mid_prop_mod_set_count_call = nullptr;'));
    });

    test('JNI_OnLoad initializes getter method ID', () {
      final cpp = CppBridgeGenerator.generate(_specWithProperties());
      expect(cpp, contains('g_mid_prop_mod_get_count_call = env->GetStaticMethodID(g_bridgeClass, "prop_mod_get_count_call"'));
    });

    test('JNI_OnLoad initializes setter method ID', () {
      final cpp = CppBridgeGenerator.generate(_specWithProperties());
      expect(cpp, contains('g_mid_prop_mod_set_count_call = env->GetStaticMethodID(g_bridgeClass, "prop_mod_set_count_call"'));
    });

    test('getter body uses cached method ID', () {
      final cpp = CppBridgeGenerator.generate(_specWithProperties());
      expect(cpp, contains('jmethodID methodId = g_mid_prop_mod_get_count_call;'));
    });

    test('setter body uses cached method ID', () {
      final cpp = CppBridgeGenerator.generate(_specWithProperties());
      expect(cpp, contains('jmethodID methodId = g_mid_prop_mod_set_count_call;'));
    });

    test('getter body does NOT call GetStaticMethodID inline', () {
      final cpp = CppBridgeGenerator.generate(_specWithProperties());
      final count = 'env->GetStaticMethodID(g_bridgeClass, "prop_mod_get_count_call"'.allMatches(cpp).length;
      expect(count, equals(1), reason: 'Only once in JNI_OnLoad');
    });
  });

  // ── Fix 1c: Stream method ID caching ─────────────────────────────────────────

  group('CppBridgeGenerator — Fix 1c: stream method ID globals', () {
    test('declares g_mid_register and g_mid_release for temperature stream', () {
      final cpp = CppBridgeGenerator.generate(_specWithStreams());
      expect(cpp, contains('static jmethodID g_mid_stream_mod_register_temperature_call = nullptr;'));
      expect(cpp, contains('static jmethodID g_mid_stream_mod_release_temperature_call = nullptr;'));
    });

    test('JNI_OnLoad initializes register method ID', () {
      final cpp = CppBridgeGenerator.generate(_specWithStreams());
      expect(cpp, contains('g_mid_stream_mod_register_temperature_call = env->GetStaticMethodID(g_bridgeClass, "stream_mod_register_temperature_call"'));
    });

    test('stream register body uses cached method ID', () {
      final cpp = CppBridgeGenerator.generate(_specWithStreams());
      expect(cpp, contains('jmethodID methodId = g_mid_stream_mod_register_temperature_call;'));
    });

    test('stream release body uses cached method ID', () {
      final cpp = CppBridgeGenerator.generate(_specWithStreams());
      expect(cpp, contains('jmethodID methodId = g_mid_stream_mod_release_temperature_call;'));
    });

    test('stream bodies do NOT call GetStaticMethodID inline', () {
      final cpp = CppBridgeGenerator.generate(_specWithStreams());
      final count = 'env->GetStaticMethodID(g_bridgeClass, "stream_mod_register_temperature_call"'.allMatches(cpp).length;
      expect(count, equals(1), reason: 'Only once in JNI_OnLoad');
    });
  });

  // ── Fix 1d: Struct class + ctor + field ID caching ───────────────────────────

  group('CppBridgeGenerator — Fix 1d: struct JNI ID globals', () {
    test('declares g_cls_Point global', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('static jclass g_cls_Point = nullptr;'));
    });

    test('declares g_ctor_Point global', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('static jmethodID g_ctor_Point = nullptr;'));
    });

    test('declares g_fid_Point_x and g_fid_Point_y globals', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('static jfieldID g_fid_Point_x = nullptr;'));
      expect(cpp, contains('static jfieldID g_fid_Point_y = nullptr;'));
    });

    test('JNI_OnLoad calls FindClass for Point struct', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('FindClass("nitro/struct_mod_module/Point")'));
    });

    test('JNI_OnLoad initializes g_cls_Point with NewGlobalRef', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('g_cls_Point = (jclass)env->NewGlobalRef(local_cls_Point);'));
    });

    test('JNI_OnLoad deletes local class ref after NewGlobalRef', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('env->DeleteLocalRef(local_cls_Point)'));
    });

    test('JNI_OnLoad initializes g_ctor_Point', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('g_ctor_Point = env->GetMethodID(g_cls_Point, "<init>"'));
    });

    test('JNI_OnLoad initializes g_fid_Point_x and g_fid_Point_y', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('g_fid_Point_x = env->GetFieldID(g_cls_Point, "x"'));
      expect(cpp, contains('g_fid_Point_y = env->GetFieldID(g_cls_Point, "y"'));
    });

    test('pack_from_jni uses cached g_fid_Point_x (not GetObjectClass/GetFieldID)', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('env->GetDoubleField(obj, g_fid_Point_x)'));
      expect(cpp, contains('env->GetDoubleField(obj, g_fid_Point_y)'));
    });

    test('pack_from_jni does NOT call GetObjectClass', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, isNot(contains('GetObjectClass(obj)')));
    });

    test('unpack_to_jni uses g_cls_Point and g_ctor_Point', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      expect(cpp, contains('env->NewObject(g_cls_Point, g_ctor_Point'));
    });

    test('unpack_to_jni does NOT call FindClass inline in helper body', () {
      final cpp = CppBridgeGenerator.generate(_specWithStructs());
      // FindClass for Point should only appear once (in JNI_OnLoad)
      final count = 'FindClass("nitro/struct_mod_module/Point")'.allMatches(cpp).length;
      expect(count, equals(1), reason: 'FindClass for Point struct must appear only in JNI_OnLoad');
    });
  });

  // ── Fix 2: Kotlin async executor ─────────────────────────────────────────────

  group('KotlinGenerator — Fix 2: async executor', () {
    test('JniBridge object declares _asyncExecutor', () {
      final kotlin = KotlinGenerator.generate(_specWithFunctions());
      expect(kotlin, contains('private val _asyncExecutor = java.util.concurrent.Executors.newCachedThreadPool()'));
    });

    test('async function uses _asyncExecutor.submit with Callable wrapping runBlocking', () {
      final kotlin = KotlinGenerator.generate(_specWithFunctions());
      // The generated code may put runBlocking on the next line inside Callable
      expect(kotlin, contains('_asyncExecutor.submit(java.util.concurrent.Callable {'));
      expect(kotlin, contains('runBlocking { impl.fetchData() }'));
    });

    test('async function result is retrieved with .get()', () {
      final kotlin = KotlinGenerator.generate(_specWithFunctions());
      expect(kotlin, contains('}).get()'));
    });

    test('sync function does NOT use _asyncExecutor', () {
      final kotlin = KotlinGenerator.generate(_specWithFunctions());
      expect(kotlin, contains('return impl.multiply('));
    });

    test('async enum return uses _asyncExecutor and .nativeValue', () {
      final kotlin = KotlinGenerator.generate(_specWithEnum());
      // Single-line emit for enum: Callable { runBlocking { impl.fetchColor() } }.get().nativeValue
      expect(kotlin, contains('_asyncExecutor.submit(java.util.concurrent.Callable { runBlocking { impl.fetchColor('));
      expect(kotlin, contains('.get().nativeValue'));
    });

    test('sync enum return does NOT use _asyncExecutor', () {
      final kotlin = KotlinGenerator.generate(_specWithEnum());
      expect(kotlin, contains('return impl.getColor().nativeValue'));
    });

    test('_asyncExecutor is declared once per bridge object', () {
      final kotlin = KotlinGenerator.generate(_specWithFunctions());
      final declarationCount = 'private val _asyncExecutor'.allMatches(kotlin).length;
      expect(declarationCount, equals(1));
    });

    test('bare runBlocking is not used directly for async String return', () {
      final kotlin = KotlinGenerator.generate(_specWithFunctions());
      // The old pattern was: return runBlocking {\n            impl.fetchData()
      // It must not appear; instead it should be wrapped in _asyncExecutor.submit
      expect(kotlin, isNot(matches(r'return runBlocking \{\s+impl\.fetchData')));
    });
  });

  // ── Regression: JNI_OnLoad structure ─────────────────────────────────────────

  group('CppBridgeGenerator — regression: JNI_OnLoad structure', () {
    test('JNI_OnLoad is present', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved)'));
    });

    test('JNI_OnLoad still initializes g_bridgeClass', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('g_bridgeClass = (jclass)env->NewGlobalRef(localClass)'));
    });

    test('GetEnv helper is still present', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('static JNIEnv* GetEnv()'));
    });

    test('iOS/Apple section is unchanged (no JNI caching needed)', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('#elif __APPLE__'));
      expect(cpp, contains('_call_multiply'));
    });

    test('JNI_OnLoad deletes localClass ref after NewGlobalRef', () {
      final cpp = CppBridgeGenerator.generate(_specWithFunctions());
      expect(cpp, contains('env->DeleteLocalRef(localClass)'));
    });
  });
}
