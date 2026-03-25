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
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
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
      BridgeStream(
        dartName: 'pressure',
        registerSymbol: 'stream_mod_register_pressure',
        releaseSymbol: 'stream_mod_release_pressure',
        itemType: BridgeType(name: 'double'),
        backpressure: Backpressure.dropLatest,
      ),
    ],
  );
}

BridgeSpec _specWithRecords() {
  return BridgeSpec(
    dartClassName: 'RecordMod',
    lib: 'record_mod',
    namespace: 'record_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'record.native.dart',
    recordTypes: [
      BridgeRecordType(
        name: 'SensorReading',
        fields: [
          BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'timestamp', dartType: 'int', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'label', dartType: 'String', kind: RecordFieldKind.primitive),
        ],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'getReading',
        cSymbol: 'record_mod_get_reading',
        isAsync: false,
        returnType: BridgeType(name: 'SensorReading', isRecord: true),
        params: [],
      ),
      BridgeFunction(
        dartName: 'getReadings',
        cSymbol: 'record_mod_get_readings',
        isAsync: false,
        returnType: BridgeType(
          name: 'List<SensorReading>',
          isRecord: true,
          recordListItemType: 'SensorReading',
          recordListItemIsPrimitive: false,
        ),
        params: [],
      ),
    ],
  );
}

BridgeSpec _specWithNumericRecord() {
  return BridgeSpec(
    dartClassName: 'NumericMod',
    lib: 'numeric_mod',
    namespace: 'numeric_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'numeric.native.dart',
    recordTypes: [
      BridgeRecordType(
        name: 'Vec3',
        fields: [
          BridgeRecordField(name: 'x', dartType: 'double', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'y', dartType: 'double', kind: RecordFieldKind.primitive),
          BridgeRecordField(name: 'z', dartType: 'double', kind: RecordFieldKind.primitive),
        ],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'getVec',
        cSymbol: 'numeric_mod_get_vec',
        isAsync: false,
        returnType: BridgeType(name: 'Vec3', isRecord: true),
        params: [],
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

  // ── Fix 4: _streamJobs thread safety ─────────────────────────────────────────

  group('KotlinGenerator — Fix 4: _streamJobs thread safety', () {
    test('_streamJobs uses ConcurrentHashMap (not mutableMapOf)', () {
      final kotlin = KotlinGenerator.generate(_specWithStreams());
      expect(
        kotlin,
        contains('java.util.concurrent.ConcurrentHashMap<Pair<String, Long>, kotlinx.coroutines.Job>()'),
      );
    });

    test('_streamJobs does NOT use mutableMapOf', () {
      final kotlin = KotlinGenerator.generate(_specWithStreams());
      expect(kotlin, isNot(contains('mutableMapOf<Pair<String, Long>')));
    });

    test('_streamJobs is still Pair<String, Long> keyed (not just Long)', () {
      final kotlin = KotlinGenerator.generate(_specWithStreams());
      expect(kotlin, contains('ConcurrentHashMap<Pair<String, Long>'));
      expect(kotlin, isNot(contains('ConcurrentHashMap<Long')));
    });

    test('register and release still use Pair(streamName, dartPort) key', () {
      final kotlin = KotlinGenerator.generate(_specWithStreams());
      expect(kotlin, contains('_streamJobs[Pair("temperature", dartPort)]'));
      expect(kotlin, contains('_streamJobs.remove(Pair("temperature", dartPort))'));
    });
  });

  // ── Fix 5: ByteArrayOutputStream pre-sizing ───────────────────────────────────

  group('RecordGenerator — Fix 5: encode() uses pre-sized ByteArrayOutputStream', () {
    test('encode() has a non-zero initial capacity for numeric record', () {
      final kotlin = RecordGenerator.generateKotlin(_specWithNumericRecord());
      // Vec3: 3 × double = 3 × 8 = 24 bytes
      expect(kotlin, contains('java.io.ByteArrayOutputStream(24)'));
    });

    test('encode() has correct capacity for mixed record (double + int + String)', () {
      final kotlin = RecordGenerator.generateKotlin(_specWithRecords());
      // SensorReading: double(8) + int(8) + String(36) = 52
      expect(kotlin, contains('java.io.ByteArrayOutputStream(52)'));
    });

    test('encode() does NOT use bare ByteArrayOutputStream() with no capacity', () {
      final kotlin = RecordGenerator.generateKotlin(_specWithRecords());
      expect(kotlin, isNot(contains('java.io.ByteArrayOutputStream()')));
    });

    test('recordBytesHint returns 8 per double field', () {
      final rt = BridgeRecordType(
        name: 'OneDouble',
        fields: [BridgeRecordField(name: 'v', dartType: 'double', kind: RecordFieldKind.primitive)],
      );
      expect(RecordGenerator.recordBytesHint(rt), equals(8));
    });

    test('recordBytesHint returns 8 per int field', () {
      final rt = BridgeRecordType(
        name: 'OneInt',
        fields: [BridgeRecordField(name: 'n', dartType: 'int', kind: RecordFieldKind.primitive)],
      );
      expect(RecordGenerator.recordBytesHint(rt), equals(8));
    });

    test('recordBytesHint returns 1 per bool field', () {
      final rt = BridgeRecordType(
        name: 'OneBool',
        fields: [BridgeRecordField(name: 'b', dartType: 'bool', kind: RecordFieldKind.primitive)],
      );
      expect(RecordGenerator.recordBytesHint(rt), equals(1));
    });

    test('recordBytesHint returns 36 per String field (4-byte len + 32 avg content)', () {
      final rt = BridgeRecordType(
        name: 'OneString',
        fields: [BridgeRecordField(name: 's', dartType: 'String', kind: RecordFieldKind.primitive)],
      );
      expect(RecordGenerator.recordBytesHint(rt), equals(36));
    });

    test('recordBytesHint adds 1 for nullable tag on nullable fields', () {
      final rt = BridgeRecordType(
        name: 'NullableDouble',
        fields: [BridgeRecordField(name: 'v', dartType: 'double?', kind: RecordFieldKind.primitive, isNullable: true)],
      );
      // 1 (null tag) + 8 (double) = 9
      expect(RecordGenerator.recordBytesHint(rt), equals(9));
    });

    test('recordBytesHint returns at least 32 for empty record (fallback)', () {
      final rt = BridgeRecordType(name: 'Empty', fields: []);
      expect(RecordGenerator.recordBytesHint(rt), greaterThanOrEqualTo(32));
    });
  });

  group('KotlinGenerator — Fix 5: list-record path uses pre-sized ByteArrayOutputStream', () {
    test('list _call uses result.size * perItemHint + 8 as initial capacity', () {
      final kotlin = KotlinGenerator.generate(_specWithRecords());
      // SensorReading hint = 52; list path: result.size * 52 + 8
      expect(kotlin, contains('java.io.ByteArrayOutputStream(result.size * 52 + 8)'));
    });

    test('list _call does NOT use bare ByteArrayOutputStream() with no capacity', () {
      final kotlin = KotlinGenerator.generate(_specWithRecords());
      expect(kotlin, isNot(contains('java.io.ByteArrayOutputStream()')));
    });

    test('numeric list _call pre-sizes based on record field types', () {
      // Vec3: 3 doubles = 24 bytes; list: result.size * 24 + 8
      final spec = BridgeSpec(
        dartClassName: 'VecMod',
        lib: 'vec_mod',
        namespace: 'vec_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'vec.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Vec3',
            fields: [
              BridgeRecordField(name: 'x', dartType: 'double', kind: RecordFieldKind.primitive),
              BridgeRecordField(name: 'y', dartType: 'double', kind: RecordFieldKind.primitive),
              BridgeRecordField(name: 'z', dartType: 'double', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getVecs',
            cSymbol: 'vec_mod_get_vecs',
            isAsync: false,
            returnType: BridgeType(
              name: 'List<Vec3>',
              isRecord: true,
              recordListItemType: 'Vec3',
              recordListItemIsPrimitive: false,
            ),
            params: [],
          ),
        ],
      );
      final kotlin = KotlinGenerator.generate(spec);
      expect(kotlin, contains('java.io.ByteArrayOutputStream(result.size * 24 + 8)'));
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

  // ── Issue 7: O(1) type-lookup sets in KotlinGenerator ────────────────────

  group('KotlinGenerator — Issue 7: O(1) type lookups via pre-built Sets', () {
    test('enum type resolves to enum name in interface (not Any?)', () {
      final kt = KotlinGenerator.generate(_specWithEnum());
      // Interface should use the enum class name, not Any?
      expect(kt, contains('fun getColor(): Color'));
      expect(kt, isNot(contains('fun getColor(): Any?')));
    });

    test('struct type resolves to struct name in interface (not Any?)', () {
      final kt = KotlinGenerator.generate(_specWithStructs());
      expect(kt, contains('fun getPoint(): Point'));
      expect(kt, isNot(contains('fun getPoint(): Any?')));
    });

    test('record type resolves to record name in interface (not Any?)', () {
      final kt = KotlinGenerator.generate(_specWithRecords());
      expect(kt, contains('fun getReading(): SensorReading'));
      expect(kt, isNot(contains('fun getReading(): Any?')));
    });

    test('enum property type resolves correctly', () {
      final spec = BridgeSpec(
        dartClassName: 'EnumPropMod',
        lib: 'enum_prop_mod',
        namespace: 'enum_prop_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'ep.native.dart',
        enums: [BridgeEnum(name: 'Status', startValue: 0, values: ['active', 'idle'])],
        properties: [
          BridgeProperty(
            dartName: 'status',
            getSymbol: 'enum_prop_mod_get_status',
            setSymbol: 'enum_prop_mod_set_status',
            type: BridgeType(name: 'Status'),
            hasGetter: true,
            hasSetter: true,
          ),
        ],
      );
      final kt = KotlinGenerator.generate(spec);
      // Interface: strong type
      expect(kt, contains('var status: Status'));
      // Bridge getter: Long (primitive bridge type for JNI)
      expect(kt, contains('fun enum_prop_mod_get_status_call(): Long'));
      // Bridge setter: Long
      expect(kt, contains('fun enum_prop_mod_set_status_call(value: Long)'));
    });

    test('stream item type resolves correctly for enum stream', () {
      final spec = BridgeSpec(
        dartClassName: 'EnumStreamMod',
        lib: 'enum_stream_mod',
        namespace: 'enum_stream_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'es.native.dart',
        enums: [BridgeEnum(name: 'Event', startValue: 0, values: ['start', 'stop'])],
        streams: [
          BridgeStream(
            dartName: 'events',
            registerSymbol: 'enum_stream_mod_register_events',
            releaseSymbol: 'enum_stream_mod_release_events',
            itemType: BridgeType(name: 'Event'),
            backpressure: Backpressure.dropLatest,
          ),
        ],
      );
      final kt = KotlinGenerator.generate(spec);
      expect(kt, contains('val events: Flow<Event>'));
      expect(kt, contains('emit_events(dartPort: Long, item: Event)'));
    });

    test('unknown type falls back to Any? without exception', () {
      final spec = BridgeSpec(
        dartClassName: 'UnknownMod',
        lib: 'unknown_mod',
        namespace: 'unknown_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'u.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'doThing',
            cSymbol: 'unknown_mod_do_thing',
            isAsync: false,
            returnType: BridgeType(name: 'UnregisteredType'),
            params: [],
          ),
        ],
      );
      final kt = KotlinGenerator.generate(spec);
      expect(kt, contains('fun doThing(): Any?'));
    });

    test('spec with many enums and structs produces correct types for all', () {
      final spec = BridgeSpec(
        dartClassName: 'BigMod',
        lib: 'big_mod',
        namespace: 'big_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'big.native.dart',
        enums: [
          BridgeEnum(name: 'ColorA', startValue: 0, values: ['r', 'g', 'b']),
          BridgeEnum(name: 'ColorB', startValue: 0, values: ['x', 'y', 'z']),
          BridgeEnum(name: 'ColorC', startValue: 0, values: ['p', 'q']),
        ],
        structs: [
          BridgeStruct(name: 'Vec2', packed: false, fields: [
            BridgeField(name: 'x', type: BridgeType(name: 'double')),
            BridgeField(name: 'y', type: BridgeType(name: 'double')),
          ]),
          BridgeStruct(name: 'Vec3', packed: false, fields: [
            BridgeField(name: 'x', type: BridgeType(name: 'double')),
            BridgeField(name: 'y', type: BridgeType(name: 'double')),
            BridgeField(name: 'z', type: BridgeType(name: 'double')),
          ]),
        ],
        functions: [
          BridgeFunction(
            dartName: 'getColorA',
            cSymbol: 'big_mod_get_color_a',
            isAsync: false,
            returnType: BridgeType(name: 'ColorA'),
            params: [],
          ),
          BridgeFunction(
            dartName: 'getColorC',
            cSymbol: 'big_mod_get_color_c',
            isAsync: false,
            returnType: BridgeType(name: 'ColorC'),
            params: [],
          ),
          BridgeFunction(
            dartName: 'getVec3',
            cSymbol: 'big_mod_get_vec3',
            isAsync: false,
            returnType: BridgeType(name: 'Vec3'),
            params: [BridgeParam(name: 'scale', type: BridgeType(name: 'Vec2'))],
          ),
        ],
      );
      final kt = KotlinGenerator.generate(spec);
      // All types should resolve to their class names, never Any?
      expect(kt, contains('fun getColorA(): ColorA'));
      expect(kt, contains('fun getColorC(): ColorC'));
      expect(kt, contains('fun getVec3(scale: Vec2): Vec3'));
      expect(kt, isNot(contains('Any?')));
    });
  });

  // ── Fix 8: Arena lifetime for async+arena functions ────────────────────────

  // Spec: async struct return (no arena params).
  BridgeSpec asyncStructNoArenaSpec() => BridgeSpec(
    dartClassName: 'StructAsyncMod',
    lib: 'struct_async_mod',
    namespace: 'struct_async_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'struct_async.native.dart',
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
        dartName: 'getPointAsync',
        cSymbol: 'struct_async_mod_get_point_async',
        isAsync: true,
        returnType: BridgeType(name: 'Point'),
        params: [],
      ),
    ],
  );

  // Spec: async record return (no arena params).
  BridgeSpec asyncRecordNoArenaSpec() => BridgeSpec(
    dartClassName: 'RecordAsyncMod',
    lib: 'record_async_mod',
    namespace: 'record_async_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'record_async.native.dart',
    recordTypes: [
      BridgeRecordType(
        name: 'Item',
        fields: [BridgeRecordField(name: 'value', dartType: 'double', kind: RecordFieldKind.primitive)],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'getItemAsync',
        cSymbol: 'record_async_mod_get_item_async',
        isAsync: true,
        returnType: BridgeType(name: 'Item', isRecord: true),
        params: [],
      ),
    ],
  );

  // Spec: async function with a String param → needsArena = true.
  BridgeSpec asyncArenaStringSpec() => BridgeSpec(
    dartClassName: 'SearchMod',
    lib: 'search_mod',
    namespace: 'search_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'search.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'findItem',
        cSymbol: 'search_mod_find_item',
        isAsync: true,
        returnType: BridgeType(name: 'String'),
        params: [BridgeParam(name: 'query', type: BridgeType(name: 'String'))],
      ),
    ],
  );

  // Spec: async function with a String param returning a record.
  BridgeSpec asyncArenaRecordSpec() => BridgeSpec(
    dartClassName: 'LookupMod',
    lib: 'lookup_mod',
    namespace: 'lookup_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'lookup.native.dart',
    recordTypes: [
      BridgeRecordType(
        name: 'Result',
        fields: [BridgeRecordField(name: 'value', dartType: 'String', kind: RecordFieldKind.primitive)],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'lookup',
        cSymbol: 'lookup_mod_lookup',
        isAsync: true,
        returnType: BridgeType(name: 'Result', isRecord: true),
        params: [BridgeParam(name: 'key', type: BridgeType(name: 'String'))],
      ),
    ],
  );

  group('DartFfiGenerator — Fix 8: arena lifetime for async+arena functions', () {
    test('async+arena does NOT use withArena (use-after-free risk)', () {
      final out = DartFfiGenerator.generate(asyncArenaStringSpec());
      // Find only the findItem function body
      final start = out.indexOf('Future<String> findItem(');
      final end = out.indexOf('\n  }', start) + 4;
      final body = out.substring(start, end);
      expect(body, isNot(contains('withArena')),
          reason: 'withArena frees arena when Future is returned, not when it completes');
    });

    test('async+arena uses Arena() directly', () {
      final out = DartFfiGenerator.generate(asyncArenaStringSpec());
      final start = out.indexOf('Future<String> findItem(');
      final end = out.indexOf('\n  }', start) + 4;
      final body = out.substring(start, end);
      expect(body, contains('final arena = Arena();'));
    });

    test('async+arena has try/finally wrapping the await', () {
      final out = DartFfiGenerator.generate(asyncArenaStringSpec());
      final start = out.indexOf('Future<String> findItem(');
      final end = out.indexOf('\n  }', start) + 4;
      final body = out.substring(start, end);
      expect(body, contains('try {'));
      expect(body, contains('} finally {'));
      expect(body, contains('arena.releaseAll();'));
    });

    test('arena.releaseAll() is in finally, after the await', () {
      final out = DartFfiGenerator.generate(asyncArenaStringSpec());
      final awaitIdx = out.indexOf('await NitroRuntime.callAsync');
      final releaseIdx = out.indexOf('arena.releaseAll()');
      expect(awaitIdx, greaterThan(0));
      expect(releaseIdx, greaterThan(awaitIdx),
          reason: 'arena must be freed after the await, not before');
    });

    test('async+arena arena args are still passed to callAsync', () {
      final out = DartFfiGenerator.generate(asyncArenaStringSpec());
      // String param should still be arena-allocated and passed to callAsync
      expect(out, contains('toNativeUtf8(allocator: arena)'));
    });

    test('async+arena record return still frees rawPtr after decode', () {
      final out = DartFfiGenerator.generate(asyncArenaRecordSpec());
      expect(out, contains('malloc.free(rawPtr)'));
      // malloc.free must appear before arena.releaseAll()
      final freeIdx = out.indexOf('malloc.free(rawPtr)');
      final releaseIdx = out.indexOf('arena.releaseAll()');
      expect(freeIdx, lessThan(releaseIdx),
          reason: 'result buffer freed inside try, before finally releases arena');
    });

    test('sync+arena function still uses withArena (no regression)', () {
      // A sync function with a String param must still use withArena
      final spec = BridgeSpec(
        dartClassName: 'SyncMod',
        lib: 'sync_mod',
        namespace: 'sync_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'sync.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'doWork',
            cSymbol: 'sync_mod_do_work',
            isAsync: false,
            returnType: BridgeType(name: 'void'),
            params: [BridgeParam(name: 'tag', type: BridgeType(name: 'String'))],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      final start = out.indexOf('void doWork(');
      final end = out.indexOf('\n  }', start) + 4;
      final body = out.substring(start, end);
      expect(body, contains('withArena'));
    });
  });

  // ── Fix 9: Typed callAsync<T> — no raw pointer casts ─────────────────────

  group('DartFfiGenerator — Fix 9: typed callAsync<T> removes raw casts', () {
    test('async record return (no arena) uses callAsync<Pointer<Uint8>>', () {
      final out = DartFfiGenerator.generate(asyncRecordNoArenaSpec());
      expect(out, contains('callAsync<Pointer<Uint8>>'));
    });

    test('async record return (no arena) has no untyped pointer cast', () {
      final out = DartFfiGenerator.generate(asyncRecordNoArenaSpec());
      expect(out, isNot(contains('result as Pointer<Uint8>')));
      expect(out, isNot(contains('rawResult as Pointer<Uint8>')));
    });

    test('async record return (arena) uses callAsync<Pointer<Uint8>>', () {
      final out = DartFfiGenerator.generate(asyncArenaRecordSpec());
      expect(out, contains('callAsync<Pointer<Uint8>>'));
    });

    test('async struct return (no arena) uses callAsync<Pointer<Void>>', () {
      final out = DartFfiGenerator.generate(asyncStructNoArenaSpec());
      expect(out, contains('callAsync<Pointer<Void>>'));
    });

    test('async struct return (no arena) has no "asyncResult as Pointer<Void>" cast', () {
      final out = DartFfiGenerator.generate(asyncStructNoArenaSpec());
      expect(out, isNot(contains('asyncResult as Pointer<Void>')));
      expect(out, isNot(contains('result as Pointer<Void>')));
    });

    test('async enum return uses callAsync<int>', () {
      final out = DartFfiGenerator.generate(_specWithEnum());
      expect(out, contains('callAsync<int>'));
    });

    test('async enum return has no untyped int cast', () {
      final out = DartFfiGenerator.generate(_specWithEnum());
      // Old: (await callAsync(...)) as int — new: callAsync<int>(...)
      expect(out, isNot(contains(') as int')));
    });

    test('async double return uses callAsync<double>', () {
      final spec = BridgeSpec(
        dartClassName: 'MathMod',
        lib: 'math_mod',
        namespace: 'math_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'math.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'computeAsync',
            cSymbol: 'math_mod_compute_async',
            isAsync: true,
            returnType: BridgeType(name: 'double'),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('callAsync<double>'));
      expect(out, isNot(contains('res as double')));
    });

    test('async int return uses callAsync<int>', () {
      final spec = BridgeSpec(
        dartClassName: 'CountMod',
        lib: 'count_mod',
        namespace: 'count_mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'count.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'countAsync',
            cSymbol: 'count_mod_count_async',
            isAsync: true,
            returnType: BridgeType(name: 'int'),
            params: [],
          ),
        ],
      );
      final out = DartFfiGenerator.generate(spec);
      expect(out, contains('callAsync<int>'));
      expect(out, isNot(contains('res as int')));
    });

    test('async+arena String return uses callAsync<Pointer<Utf8>>', () {
      final out = DartFfiGenerator.generate(asyncArenaStringSpec());
      expect(out, contains('callAsync<Pointer<Utf8>>'));
    });
  });

  // ── Fix 10: TypedData null guard in pack_from_jni ─────────────────────────

  BridgeSpec typedDataStructSpec() => BridgeSpec(
    dartClassName: 'BufferMod',
    lib: 'buffer_mod',
    namespace: 'buffer_mod',
    iosImpl: NativeImpl.swift,
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'buffer.native.dart',
    structs: [
      BridgeStruct(
        name: 'Frame',
        packed: false,
        fields: [
          BridgeField(name: 'pixels', type: BridgeType(name: 'Uint8List'), zeroCopy: true),
          BridgeField(name: 'pixelsLength', type: BridgeType(name: 'int')),
          BridgeField(name: 'width', type: BridgeType(name: 'int')),
        ],
      ),
    ],
    functions: [
      BridgeFunction(
        dartName: 'getFrame',
        cSymbol: 'buffer_mod_get_frame',
        isAsync: false,
        returnType: BridgeType(name: 'Frame'),
        params: [],
      ),
    ],
  );

  group('CppBridgeGenerator — Fix 10: TypedData null guard in pack_from_jni', () {
    test('null guard emitted for zero-copy ByteBuffer field', () {
      final cpp = CppBridgeGenerator.generate(typedDataStructSpec());
      expect(cpp, contains('if (buf_pixels == nullptr)'));
    });

    test('null guard throws NullPointerException via ThrowNew', () {
      final cpp = CppBridgeGenerator.generate(typedDataStructSpec());
      expect(cpp, contains('env->FindClass("java/lang/NullPointerException")'));
      expect(cpp, contains('env->ThrowNew(npe,'));
    });

    test('null guard error message names the struct and field', () {
      final cpp = CppBridgeGenerator.generate(typedDataStructSpec());
      expect(cpp, contains('"Frame.pixels: TypedData ByteBuffer is null"'));
    });

    test('null guard returns early before GetDirectBufferAddress', () {
      final cpp = CppBridgeGenerator.generate(typedDataStructSpec());
      final nullCheckIdx = cpp.indexOf('if (buf_pixels == nullptr)');
      final bufAddrIdx = cpp.indexOf('GetDirectBufferAddress(buf_pixels)');
      expect(nullCheckIdx, greaterThan(0));
      expect(bufAddrIdx, greaterThan(nullCheckIdx),
          reason: 'null check must precede GetDirectBufferAddress call');
    });

    test('GetDirectBufferAddress still emitted after null guard', () {
      final cpp = CppBridgeGenerator.generate(typedDataStructSpec());
      expect(cpp, contains('GetDirectBufferAddress(buf_pixels)'));
    });

    test('non-TypedData fields have no null guard', () {
      final cpp = CppBridgeGenerator.generate(typedDataStructSpec());
      // width is an int field, not zero-copy — no null guard for it
      expect(cpp, isNot(contains('if (buf_width == nullptr)')));
    });
  });
}
