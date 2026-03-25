// Edge-case regression tests covering fixes made in the 0.2.x cycle.
//
// Organised into five groups:
//
//   1. RecordGenerator.generateKotlin
//        • decodeFrom(buf) companion method
//        • decode(bytes) delegates to decodeFrom
//        • encode() calls writeFieldsTo (not duplicating field writes)
//        • writeFieldsTo method signature
//        • listRecordObject uses decodeFrom(buf), not decode(bytes)
//
//   2. CppBridgeGenerator — @HybridRecord return type over JNI
//        • JNI signature is "[B" (ByteArray), not "Ljava/lang/Object;"
//        • Return path calls GetByteArrayRegion + malloc + DeleteLocalRef
//        • Exception check after CallStaticObjectMethod before byte copy
//
//   3. CppBridgeGenerator — JNI thread & exception safety
//        • NitroJniThreadGuard RAII struct is emitted
//        • thread_local g_thread_guard declared
//        • GetEnv() sets g_thread_guard.attached = true
//        • nitro_report_jni_exception calls ExceptionClear() before GetObjectClass
//        • _defaultValue for const char* returns nullptr (not "")
//
//   4. DartFfiGenerator — malloc.free after record / struct decode
//        • sync record return: malloc.free(rawPtr)
//        • async no-arena record return: malloc.free(rawPtr)
//        • async with-arena record return: malloc.free(rawPtr)
//        • async no-arena struct return: malloc.free(structPtr)
//        • async with-arena struct return: malloc.free(structPtr)
//        • sync struct return: malloc.free(structPtr)
//
//   5. KotlinGenerator — List<@HybridRecord> _call bridge
//        • _call return type is ByteArray (not List<X> or Any?)
//        • serialization uses countBuf, ByteArrayOutputStream, writeFieldsTo
//        • 4-byte length prefix via lenBuf prepended to payload

import 'package:nitro/nitro.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/cpp_bridge_generator.dart';
import 'package:nitro_generator/src/generators/dart_ffi_generator.dart';
import 'package:nitro_generator/src/generators/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/record_generator.dart';
import 'package:test/test.dart';

// ── Shared spec helpers ───────────────────────────────────────────────────────

/// Single @HybridRecord with flat primitives + an async return and a sync param.
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

/// Nested @HybridRecord with a List<@HybridRecord> field and a list return.
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

/// Async record return that also has a String param → forces withArena path.
BridgeSpec _arenaRecordSpec() => BridgeSpec(
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
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'findDevice',
      cSymbol: 'camera_module_find_device',
      isAsync: true,
      returnType: BridgeType(name: 'CameraDevice', isRecord: true),
      params: [
        BridgeParam(
          name: 'query',
          type: BridgeType(name: 'String'),
        ),
      ],
    ),
  ],
);

/// Sync @HybridRecord return (no arena, no await).
BridgeSpec _syncRecordSpec() => BridgeSpec(
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
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getDevice',
      cSymbol: 'camera_module_get_device',
      isAsync: false,
      returnType: BridgeType(name: 'CameraDevice', isRecord: true),
      params: [],
    ),
  ],
);

/// Async struct return (no arena params → no-arena path).
BridgeSpec _asyncStructSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  structs: [
    BridgeStruct(
      name: 'Reading',
      packed: false,
      fields: [
        BridgeField(name: 'value', type: BridgeType(name: 'double')),
        BridgeField(name: 'valid', type: BridgeType(name: 'bool')),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fetchReading',
      cSymbol: 'sensor_fetch_reading',
      isAsync: true,
      returnType: BridgeType(name: 'Reading'),
      params: [],
    ),
  ],
);

/// Async struct return with a String param → forces withArena path.
BridgeSpec _arenaStructSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  structs: [
    BridgeStruct(
      name: 'Reading',
      packed: false,
      fields: [
        BridgeField(name: 'value', type: BridgeType(name: 'double')),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'fetchByName',
      cSymbol: 'sensor_fetch_by_name',
      isAsync: true,
      returnType: BridgeType(name: 'Reading'),
      params: [
        BridgeParam(name: 'name', type: BridgeType(name: 'String')),
      ],
    ),
  ],
);

/// Sync struct return.
BridgeSpec _syncStructSpec() => BridgeSpec(
  dartClassName: 'Sensor',
  lib: 'sensor',
  namespace: 'sensor',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'sensor.native.dart',
  structs: [
    BridgeStruct(
      name: 'Reading',
      packed: false,
      fields: [
        BridgeField(name: 'value', type: BridgeType(name: 'double')),
      ],
    ),
  ],
  functions: [
    BridgeFunction(
      dartName: 'getReading',
      cSymbol: 'sensor_get_reading',
      isAsync: false,
      returnType: BridgeType(name: 'Reading'),
      params: [],
    ),
  ],
);

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  // ── 1. RecordGenerator.generateKotlin ─────────────────────────────────────

  group('RecordGenerator.generateKotlin — decodeFrom / decode / writeFieldsTo', () {
    test('companion object has a static decodeFrom(buf: ByteBuffer) method', () {
      final out = RecordGenerator.generateKotlin(_singleRecordSpec());
      expect(
        out,
        contains('fun decodeFrom(buf: java.nio.ByteBuffer): CameraDevice'),
        reason: 'decodeFrom shares the ByteBuffer cursor instead of slicing bytes',
      );
    });

    test('decode(bytes) wraps into ByteBuffer, skips 4-byte prefix, then delegates to decodeFrom', () {
      final out = RecordGenerator.generateKotlin(_singleRecordSpec());
      // Must skip the 4-byte length prefix
      expect(out, contains('buf.position(4)'));
      // Must delegate to decodeFrom rather than re-implementing field reads
      expect(out, contains('return decodeFrom(buf)'));
    });

    test('decode(bytes) does NOT inline field reads directly', () {
      // All field reads must go through decodeFrom, never re-implemented inline in decode.
      final out = RecordGenerator.generateKotlin(_singleRecordSpec());
      final decodeBlock = out.substring(
        out.indexOf('fun decode(bytes: ByteArray)'),
        out.indexOf('fun decode(bytes: ByteArray)') + 300,
      );
      // decode should only contain buf setup + position(4) + decodeFrom
      expect(decodeBlock, isNot(contains('buf.long')));
      expect(decodeBlock, isNot(contains('buf.get().toInt()')));
    });

    test('writeFieldsTo method accepts ByteArrayOutputStream + ByteBuffer params', () {
      final out = RecordGenerator.generateKotlin(_singleRecordSpec());
      expect(
        out,
        contains(
          'fun writeFieldsTo(out: java.io.ByteArrayOutputStream, buf: java.nio.ByteBuffer)',
        ),
      );
    });

    test('encode() calls writeFieldsTo instead of writing fields inline', () {
      final out = RecordGenerator.generateKotlin(_singleRecordSpec());
      // Locate the encode() body
      final encodeStart = out.indexOf('fun encode(): ByteArray');
      final encodeBlock = out.substring(encodeStart, encodeStart + 400);
      expect(encodeBlock, contains('writeFieldsTo(out, buf)'));
      // Must NOT duplicate the field writes inline
      expect(encodeBlock, isNot(contains('writeString(id)')));
    });

    test('encode() prepends 4-byte little-endian length prefix', () {
      final out = RecordGenerator.generateKotlin(_singleRecordSpec());
      expect(out, contains('lenBuf.putInt(payload.size)'));
      expect(out, contains('return lenBuf.array() + payload'));
    });

    test('listRecordObject field in decodeFrom uses ClassName.decodeFrom(buf)', () {
      // Resolution list inside CameraDevice must share the cursor, not slice bytes.
      final out = RecordGenerator.generateKotlin(_recordListSpec());
      expect(
        out,
        contains('Resolution.decodeFrom(buf)'),
        reason: 'list items must share the enclosing ByteBuffer cursor',
      );
    });

    test('listRecordObject field does NOT call ClassName.decode(…) with sliced bytes', () {
      final out = RecordGenerator.generateKotlin(_recordListSpec());
      // The old broken pattern — must not appear
      expect(out, isNot(contains('Resolution.decode(')));
    });

    test('recordObject field in decodeFrom uses ClassName.decodeFrom(buf)', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Inner',
            fields: [
              BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
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
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('Inner.decodeFrom(buf)'));
      expect(out, isNot(contains('Inner.decode(')));
    });

    test('nullable recordObject uses if(buf.get().toInt() == 0) null else decodeFrom', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Inner',
            fields: [
              BridgeRecordField(name: 'x', dartType: 'int', kind: RecordFieldKind.primitive),
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
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('if (buf.get().toInt() == 0) null else Inner.decodeFrom(buf)'));
    });

    test('int field reads via buf.long in decodeFrom', () {
      final out = RecordGenerator.generateKotlin(_recordListSpec());
      expect(out, contains('buf.long'));
    });

    test('bool field reads via buf.get().toInt() != 0 in decodeFrom', () {
      final out = RecordGenerator.generateKotlin(_singleRecordSpec());
      expect(out, contains('buf.get().toInt() != 0'));
    });

    test('double field reads via buf.double in decodeFrom', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        recordTypes: [
          BridgeRecordType(
            name: 'Measurement',
            fields: [
              BridgeRecordField(name: 'val', dartType: 'double', kind: RecordFieldKind.primitive),
            ],
          ),
        ],
      );
      final out = RecordGenerator.generateKotlin(spec);
      expect(out, contains('buf.double'));
    });
  });

  // ── 2. CppBridgeGenerator — @HybridRecord return over JNI ─────────────────

  group('CppBridgeGenerator — @HybridRecord return type', () {
    test('JNI method descriptor uses [B (ByteArray) for record return', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      // GetStaticMethodID call for getDevice_call must use "[B" as return sig
      expect(
        out,
        contains('"getDevice_call", "()[B"'),
        reason: '"[B" is the JNI descriptor for byte[]',
      );
    });

    test('record return uses CallStaticObjectMethod to retrieve jbyteArray', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(
        out,
        contains('(jbyteArray)env->CallStaticObjectMethod'),
        reason: 'ByteArray is an Object subtype; returned via CallStaticObjectMethod',
      );
    });

    test('record return copies bytes via GetByteArrayRegion into malloc buffer', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(
        out,
        contains('env->GetByteArrayRegion(jarr, 0, len, (jbyte*)result)'),
        reason: 'GetByteArrayRegion copies the Java byte[] into the malloc buffer',
      );
    });

    test('record return allocates buffer with malloc(len)', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(out, contains('uint8_t* result = (uint8_t*)malloc(len)'));
    });

    test('record return calls DeleteLocalRef on the jbyteArray after copy', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(out, contains('env->DeleteLocalRef(jarr)'));
    });

    test('record return checks exception after CallStaticObjectMethod', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      // Find the record return block and verify exception check precedes byte copy
      final idx = out.indexOf('(jbyteArray)env->CallStaticObjectMethod');
      final snippet = out.substring(idx, idx + 400);
      expect(snippet, contains('ExceptionCheck()'));
      // ExceptionCheck must come before GetByteArrayRegion
      final exceptionIdx = snippet.indexOf('ExceptionCheck()');
      final copyIdx = snippet.indexOf('GetByteArrayRegion');
      expect(
        exceptionIdx,
        lessThan(copyIdx),
        reason: 'must bail out on exception before trying to read the byte array',
      );
    });

    test('List<@HybridRecord> return also uses [B JNI descriptor', () {
      final out = CppBridgeGenerator.generate(_recordListSpec());
      expect(out, contains('"getAvailableDevices_call", "()[B"'));
    });

    test('record return does NOT use CallStaticDoubleMethod or CallStaticLongMethod', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      // Isolate the getDevice function body (up to next function)
      final idx = out.indexOf('camera_module_get_device(void)');
      final body = out.substring(idx, idx + 600);
      expect(body, isNot(contains('CallStaticDoubleMethod')));
      expect(body, isNot(contains('CallStaticLongMethod')));
    });
  });

  // ── 3. CppBridgeGenerator — JNI thread & exception safety ─────────────────

  group('CppBridgeGenerator — JNI thread safety (NitroJniThreadGuard)', () {
    test('NitroJniThreadGuard struct is emitted in the Android section', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(out, contains('struct NitroJniThreadGuard {'));
    });

    test('NitroJniThreadGuard destructor calls DetachCurrentThread', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(out, contains('g_jvm->DetachCurrentThread()'));
    });

    test('NitroJniThreadGuard has bool attached field defaulting to false', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(out, contains('bool attached = false;'));
    });

    test('static thread_local NitroJniThreadGuard g_thread_guard is declared', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(out, contains('static thread_local NitroJniThreadGuard g_thread_guard;'));
    });

    test('GetEnv sets g_thread_guard.attached = true when attaching', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(
        out,
        contains('g_thread_guard.attached = true'),
        reason: 'must mark the thread as attached so the RAII guard detaches on exit',
      );
    });

    test('GetEnv attaches via AttachCurrentThread when EDETACHED', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      expect(out, contains('g_jvm->AttachCurrentThread(&env, nullptr)'));
      expect(out, contains('JNI_EDETACHED'));
    });
  });

  group('CppBridgeGenerator — JNI exception safety (nitro_report_jni_exception)', () {
    test('nitro_report_jni_exception calls ExceptionClear() before GetObjectClass', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      // Locate the function body
      final fnStart = out.indexOf('static void nitro_report_jni_exception');
      final fnBody = out.substring(fnStart, fnStart + 800);
      // ExceptionClear must precede the actual env->GetObjectClass call (not the comment).
      final clearIdx = fnBody.indexOf('env->ExceptionClear()');
      // Search for the real JNI call, not the comment mentioning it.
      final getClassIdx = fnBody.indexOf('env->GetObjectClass');
      expect(
        clearIdx,
        greaterThanOrEqualTo(0),
        reason: 'ExceptionClear must be present',
      );
      expect(
        clearIdx,
        lessThan(getClassIdx),
        reason: 'ExceptionClear must come before GetObjectClass to avoid JNI abort',
      );
    });

    test('nitro_report_jni_exception guards j_name null before ReleaseStringUTFChars', () {
      final out = CppBridgeGenerator.generate(_singleRecordSpec());
      // Must check j_name is non-null before releasing
      expect(out, contains('if (j_name) env->ReleaseStringUTFChars'));
    });

    test('_defaultValue for const char* returns nullptr not empty string', () {
      // A function returning String should use nullptr as the default (safe) value
      // when there is an early-exit condition. Previously this was "" which
      // would crash in toDartStringWithFree() trying to free a static literal.
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'greet',
            cSymbol: 'mod_greet',
            isAsync: false,
            returnType: BridgeType(name: 'String'),
            params: [],
          ),
        ],
      );
      final out = CppBridgeGenerator.generate(spec);
      // The early-return for env == nullptr must return nullptr, not ""
      expect(
        out,
        contains('if (env == nullptr) return nullptr;'),
        reason: 'returning a static literal "" would crash toDartStringWithFree',
      );
      expect(out, isNot(contains('if (env == nullptr) return ""')));
    });
  });

  // ── 4. DartFfiGenerator — malloc.free after decode ────────────────────────

  group('DartFfiGenerator — malloc.free for record returns', () {
    test('sync record return calls malloc.free(rawPtr) after decode', () {
      final out = DartFfiGenerator.generate(_syncRecordSpec());
      expect(
        out,
        contains('malloc.free(rawPtr)'),
        reason: 'the C-malloc\'d buffer must be freed after Dart decodes it',
      );
    });

    test('async no-arena record return calls malloc.free(rawPtr)', () {
      // _singleRecordSpec().getDevice has no arena params → no-arena async path
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      expect(out, contains('malloc.free(rawPtr)'));
    });

    test('async with-arena record return calls malloc.free(rawPtr)', () {
      // _arenaRecordSpec().findDevice has a String param → withArena async path
      final out = DartFfiGenerator.generate(_arenaRecordSpec());
      expect(out, contains('malloc.free(rawPtr)'));
    });

    test('sync record return frees before returning decoded value', () {
      final out = DartFfiGenerator.generate(_syncRecordSpec());
      // Verify order: malloc.free(rawPtr) appears before return decoded
      final freeIdx = out.indexOf('malloc.free(rawPtr)');
      final returnIdx = out.indexOf('return decoded');
      expect(freeIdx, greaterThanOrEqualTo(0), reason: 'malloc.free(rawPtr) must be present');
      expect(returnIdx, greaterThanOrEqualTo(0), reason: 'return decoded must be present');
      expect(freeIdx, lessThan(returnIdx), reason: 'must free before returning');
    });

    test('async no-arena record return uses typed callAsync<Pointer<Uint8>>', () {
      final out = DartFfiGenerator.generate(_singleRecordSpec());
      expect(out, contains('callAsync<Pointer<Uint8>>'));
      expect(out, contains('final rawPtr = await NitroRuntime.callAsync<Pointer<Uint8>>'));
    });

    test('sync record return casts call result to Pointer<Uint8>', () {
      final out = DartFfiGenerator.generate(_syncRecordSpec());
      expect(out, contains('as Pointer<Uint8>'));
    });
  });

  group('DartFfiGenerator — malloc.free for struct returns', () {
    test('async no-arena struct return calls malloc.free(structPtr)', () {
      final out = DartFfiGenerator.generate(_asyncStructSpec());
      expect(
        out,
        contains('malloc.free(structPtr)'),
        reason: 'C malloc-allocated struct must be freed after Dart toDart() call',
      );
    });

    test('async with-arena struct return calls malloc.free(structPtr)', () {
      final out = DartFfiGenerator.generate(_arenaStructSpec());
      expect(out, contains('malloc.free(structPtr)'));
    });

    test('sync struct return calls malloc.free(structPtr)', () {
      final out = DartFfiGenerator.generate(_syncStructSpec());
      expect(out, contains('malloc.free(structPtr)'));
    });

    test('async no-arena struct return calls toDart() then frees', () {
      final out = DartFfiGenerator.generate(_asyncStructSpec());
      // Both must appear and toDart() must precede the free
      final toDartIdx = out.indexOf('toDart()');
      final freeIdx = out.indexOf('malloc.free(structPtr)');
      expect(toDartIdx, greaterThanOrEqualTo(0), reason: 'toDart() must be present');
      expect(freeIdx, greaterThanOrEqualTo(0), reason: 'malloc.free(structPtr) must be present');
      expect(toDartIdx, lessThan(freeIdx), reason: 'decode before free');
    });

    test('async no-arena struct return uses Pointer<ReadingFfi>.fromAddress', () {
      final out = DartFfiGenerator.generate(_asyncStructSpec());
      expect(out, contains('Pointer<ReadingFfi>.fromAddress'));
    });

    test('sync struct return uses Pointer<ReadingFfi>.fromAddress', () {
      final out = DartFfiGenerator.generate(_syncStructSpec());
      expect(out, contains('Pointer<ReadingFfi>.fromAddress'));
    });
  });

  // ── 5. KotlinGenerator — List<@HybridRecord> _call bridge ─────────────────

  group('KotlinGenerator — List<@HybridRecord> _call serialisation', () {
    test('_call method for List<@HybridRecord> return type is ByteArray', () {
      final out = KotlinGenerator.generate(_recordListSpec());
      expect(
        out,
        contains('fun getAvailableDevices_call(): ByteArray'),
        reason: 'must serialize to ByteArray so JNI can pass it to C as jbyteArray',
      );
    });

    test('_call does NOT return List<CameraDevice> (would not pass JNI boundary)', () {
      final out = KotlinGenerator.generate(_recordListSpec());
      expect(out, isNot(contains('fun getAvailableDevices_call(): List<CameraDevice>')));
    });

    test('_call serialises list count into countBuf before items', () {
      final out = KotlinGenerator.generate(_recordListSpec());
      expect(out, contains('countBuf.putInt(result.size)'));
      expect(out, contains('out.write(countBuf.array())'));
    });

    test('_call writes each item via writeFieldsTo (not encode())', () {
      // Using encode() would prepend a per-item 4-byte length prefix, breaking
      // the wire format expected by RecordReader.decodeList on the Dart side.
      final out = KotlinGenerator.generate(_recordListSpec());
      expect(out, contains('result.forEach { it.writeFieldsTo(out, buf) }'));
      expect(
        out,
        isNot(contains('result.forEach { out.write(it.encode()) }')),
        reason: 'encode() adds a per-item length prefix which is not expected by the reader',
      );
    });

    test('_call wraps payload with 4-byte length prefix via lenBuf', () {
      final out = KotlinGenerator.generate(_recordListSpec());
      expect(out, contains('lenBuf.putInt(payload.size)'));
      expect(out, contains('return lenBuf.array() + payload'));
    });

    test('_call uses pre-sized ByteArrayOutputStream for list serialisation', () {
      final out = KotlinGenerator.generate(_recordListSpec());
      // Must use a pre-sized stream; exact size depends on record fields
      expect(out, contains('val out = java.io.ByteArrayOutputStream(result.size *'));
    });

    test('interface return type is List<CameraDevice> (not ByteArray)', () {
      // The interface exposes the rich Kotlin type; only the _call bridge uses ByteArray.
      final out = KotlinGenerator.generate(_recordListSpec());
      expect(
        out,
        contains('suspend fun getAvailableDevices(): List<CameraDevice>'),
      );
      expect(
        out,
        isNot(contains('suspend fun getAvailableDevices(): ByteArray')),
      );
    });

    test('single @HybridRecord _call returns result.encode() not custom serialization', () {
      final out = KotlinGenerator.generate(_singleRecordSpec());
      expect(
        out,
        contains('return result.encode()'),
        reason: 'single record uses encode() which already prepends the 4-byte prefix',
      );
    });
  });

  // ── 6. Non-zero-copy TypedData JNI field descriptors ──────────────────────
  //
  // Regression: CppBridgeGenerator._jniSigType previously returned
  // "Ljava/lang/Object;" for all TypedData.  After the fix, each TypedData
  // type maps to the correct JNI array descriptor matching its Kotlin type.

  group('CppBridgeGenerator — non-zero-copy TypedData JNI field descriptors', () {
    // Helper: build a spec with a single non-zero-copy struct field.
    BridgeSpec specWithField(String typeName) => BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mod.native.dart',
      structs: [
        BridgeStruct(
          name: 'Buf',
          packed: false,
          fields: [
            BridgeField(name: 'data', type: BridgeType(name: typeName)),
            BridgeField(name: 'length', type: BridgeType(name: 'int')),
          ],
        ),
      ],
      functions: [
        BridgeFunction(
          dartName: 'get',
          cSymbol: 'mod_get',
          isAsync: false,
          returnType: BridgeType(name: 'Buf'),
          params: [],
        ),
      ],
    );

    final cases = {
      'Uint8List': '[B',
      'Int8List': '[B',
      'Int16List': '[S',
      'Uint16List': '[S',
      'Int32List': '[I',
      'Uint32List': '[I',
      'Float32List': '[F',
      'Float64List': '[D',
      'Int64List': '[J',
      'Uint64List': '[J',
    };

    for (final entry in cases.entries) {
      final typeName = entry.key;
      final expectedSig = entry.value;
      test('$typeName (non-zero-copy) maps to JNI descriptor "$expectedSig"', () {
        final cpp = CppBridgeGenerator.generate(specWithField(typeName));
        expect(
          cpp,
          contains('"data", "$expectedSig"'),
          reason: '$typeName → Kotlin ${_kotlinEquivalent(typeName)}, JNI descriptor $expectedSig',
        );
        // Must NOT keep the old catch-all Object descriptor
        expect(cpp, isNot(contains('"data", "Ljava/lang/Object;"')));
        // Must NOT become a zero-copy ByteBuffer (no zeroCopy annotation)
        expect(cpp, isNot(contains('"data", "Ljava/nio/ByteBuffer;"')));
      });
    }
  });

  // ── 6. CppBridgeGenerator — non-zero-copy TypedData JNI call arguments ────
  //
  // Regression coverage for the JNI call-argument bug: when a function
  // parameter is a non-zero-copy TypedData, the old code passed the raw C
  // pointer (float*, uint8_t*, …) as a JNI call argument. JNI interprets that
  // value as a jarray object reference → crash or silent wrong-method-call.
  //
  // After the fix, the generator must:
  //   (a) allocate a JNI typed array (NewFloatArray / NewIntArray / …)
  //   (b) copy data into it (SetFloatArrayRegion / …)
  //   (c) pass j_<param> to the Call, not the raw pointer
  //   (d) release the local ref with DeleteLocalRef after the call

  group('CppBridgeGenerator — non-zero-copy TypedData param: JNI array creation', () {
    // Helper: spec with one non-zero-copy TypedData function parameter.
    BridgeSpec specWithParam(String typeName) => BridgeSpec(
      dartClassName: 'Dsp',
      lib: 'dsp',
      namespace: 'dsp',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'dsp.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'process',
          cSymbol: 'dsp_process',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(name: 'inputs', type: BridgeType(name: typeName)),
          ],
        ),
      ],
    );

    // (a) correct New*Array call emitted
    final newArrayFns = {
      'Float32List': 'NewFloatArray',
      'Float64List': 'NewDoubleArray',
      'Int32List': 'NewIntArray',
      'Uint32List': 'NewIntArray',
      'Int16List': 'NewShortArray',
      'Uint16List': 'NewShortArray',
      'Uint8List': 'NewByteArray',
      'Int8List': 'NewByteArray',
      'Int64List': 'NewLongArray',
      'Uint64List': 'NewLongArray',
    };

    for (final entry in newArrayFns.entries) {
      final type = entry.key;
      final newFn = entry.value;
      test('$type param: emits env->$newFn(…) to allocate JNI array', () {
        final cpp = CppBridgeGenerator.generate(specWithParam(type));
        expect(cpp, contains('env->$newFn((jsize)inputs_length)'), reason: '$type non-zero-copy param must allocate JNI array via $newFn');
      });
    }

    // (b) correct Set*ArrayRegion call emitted
    final setRegionFns = {
      'Float32List': 'SetFloatArrayRegion',
      'Float64List': 'SetDoubleArrayRegion',
      'Int32List': 'SetIntArrayRegion',
      'Uint32List': 'SetIntArrayRegion',
      'Int16List': 'SetShortArrayRegion',
      'Uint16List': 'SetShortArrayRegion',
      'Uint8List': 'SetByteArrayRegion',
      'Int8List': 'SetByteArrayRegion',
      'Int64List': 'SetLongArrayRegion',
      'Uint64List': 'SetLongArrayRegion',
    };

    for (final entry in setRegionFns.entries) {
      final type = entry.key;
      final setFn = entry.value;
      test('$type param: emits env->$setFn(…) to copy data', () {
        final cpp = CppBridgeGenerator.generate(specWithParam(type));
        expect(cpp, contains('env->$setFn(j_inputs, 0, (jsize)inputs_length,'), reason: '$type non-zero-copy param must copy data via $setFn');
      });
    }
  });

  group('CppBridgeGenerator — non-zero-copy TypedData param: JNI call uses j_<param>', () {
    BridgeSpec specWithParam(String typeName) => BridgeSpec(
      dartClassName: 'Dsp',
      lib: 'dsp',
      namespace: 'dsp',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'dsp.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'process',
          cSymbol: 'dsp_process',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(name: 'inputs', type: BridgeType(name: typeName)),
          ],
        ),
      ],
    );

    for (final type in ['Float32List', 'Float64List', 'Int32List', 'Uint8List', 'Int64List']) {
      test('$type param: CallStaticVoidMethod passes j_inputs (not raw pointer)', () {
        final cpp = CppBridgeGenerator.generate(specWithParam(type));
        // The JNI call must pass j_inputs (the jarray), not the raw C pointer.
        expect(cpp, contains('CallStaticVoidMethod(g_bridgeClass, methodId, j_inputs)'), reason: '$type must pass j_inputs to JNI call, not raw C pointer');
        // Regression guard: raw pointer must NOT be passed directly.
        expect(cpp, isNot(contains('CallStaticVoidMethod(g_bridgeClass, methodId, inputs)')), reason: '$type raw pointer must not be passed as JNI arg');
      });
    }
  });

  group('CppBridgeGenerator — non-zero-copy TypedData param: DeleteLocalRef cleanup', () {
    BridgeSpec specWithParam(String typeName, {String returnType = 'void'}) => BridgeSpec(
      dartClassName: 'Dsp',
      lib: 'dsp',
      namespace: 'dsp',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'dsp.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'process',
          cSymbol: 'dsp_process',
          isAsync: false,
          returnType: BridgeType(name: returnType),
          params: [
            BridgeParam(name: 'inputs', type: BridgeType(name: typeName)),
          ],
        ),
      ],
    );

    test('void return: DeleteLocalRef(j_inputs) emitted after call', () {
      final cpp = CppBridgeGenerator.generate(specWithParam('Float32List'));
      expect(cpp, contains('env->DeleteLocalRef(j_inputs)'), reason: 'JNI array local ref must be deleted after the void call');
    });

    test('double return: DeleteLocalRef(j_inputs) emitted after call', () {
      final cpp = CppBridgeGenerator.generate(specWithParam('Float32List', returnType: 'double'));
      expect(cpp, contains('env->DeleteLocalRef(j_inputs)'), reason: 'JNI array local ref must be deleted after double return call');
    });

    test('int return: DeleteLocalRef(j_inputs) emitted after call', () {
      final cpp = CppBridgeGenerator.generate(specWithParam('Int32List', returnType: 'int'));
      expect(cpp, contains('env->DeleteLocalRef(j_inputs)'), reason: 'JNI array local ref must be deleted after int return call');
    });

    test('bool return: DeleteLocalRef(j_inputs) emitted after call', () {
      final cpp = CppBridgeGenerator.generate(specWithParam('Uint8List', returnType: 'bool'));
      expect(cpp, contains('env->DeleteLocalRef(j_inputs)'), reason: 'JNI array local ref must be deleted after bool return call');
    });

    test('String return: DeleteLocalRef(j_inputs) emitted after call', () {
      final cpp = CppBridgeGenerator.generate(specWithParam('Float64List', returnType: 'String'));
      expect(cpp, contains('env->DeleteLocalRef(j_inputs)'), reason: 'JNI array local ref must be deleted after String return call');
    });
  });

  // ── 7. CppBridgeGenerator — no redundant ExceptionClear at call sites ──────
  //
  // nitro_report_jni_exception already calls ExceptionClear() internally.
  // The call-site pattern must NOT duplicate the call.

  group('CppBridgeGenerator — ExceptionCheck call sites: no redundant ExceptionClear', () {
    test('no call site emits ExceptionClear after nitro_report_jni_exception', () {
      final cpp = CppBridgeGenerator.generate(_syncRecordSpec());
      expect(
        cpp,
        isNot(contains('nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear()')),
        reason: 'ExceptionClear() is already called inside nitro_report_jni_exception — no need to repeat it',
      );
    });

    test('nitro_report_jni_exception helper itself still calls ExceptionClear internally', () {
      final cpp = CppBridgeGenerator.generate(_syncRecordSpec());
      final helperIdx = cpp.indexOf('nitro_report_jni_exception');
      expect(helperIdx, greaterThan(-1));
      final helperBody = cpp.substring(helperIdx, helperIdx + 400);
      expect(helperBody, contains('env->ExceptionClear()'),
          reason: 'ExceptionClear must remain inside the helper body');
    });

    test('double-return call site: ExceptionCheck pattern has no trailing ExceptionClear', () {
      final spec = BridgeSpec(
        dartClassName: 'Calc',
        lib: 'calc',
        namespace: 'calc',
        iosImpl: NativeImpl.swift,
        androidImpl: NativeImpl.kotlin,
        sourceUri: 'calc.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'add',
            cSymbol: 'calc_add',
            isAsync: false,
            returnType: BridgeType(name: 'double'),
            params: [],
          ),
        ],
      );
      final cpp = CppBridgeGenerator.generate(spec);
      expect(
        cpp,
        isNot(contains('nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return')),
      );
      // The ExceptionCheck + report + return pattern must still be present.
      expect(cpp, contains('nitro_report_jni_exception(env, env->ExceptionOccurred()); return 0.0;'));
    });
  });

  // ── 8. KotlinGenerator — _streamJobs composite key ────────────────────────
  //
  // Using dartPort alone as the map key means two simultaneous subscriptions
  // on different streams that happen to receive the same port value would
  // overwrite each other's job.  The fix uses Pair(streamName, dartPort).

  group('KotlinGenerator — _streamJobs uses Pair(streamName, dartPort) composite key', () {
    BridgeSpec twoStreamSpec() => BridgeSpec(
      dartClassName: 'Camera',
      lib: 'camera',
      namespace: 'camera',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'camera.native.dart',
      streams: [
        BridgeStream(
          dartName: 'frames',
          registerSymbol: 'camera_frames_register',
          releaseSymbol: 'camera_frames_release',
          itemType: BridgeType(name: 'double'),
          backpressure: Backpressure.dropLatest,
        ),
        BridgeStream(
          dartName: 'coloredFrames',
          registerSymbol: 'camera_colored_frames_register',
          releaseSymbol: 'camera_colored_frames_release',
          itemType: BridgeType(name: 'double'),
          backpressure: Backpressure.dropLatest,
        ),
      ],
      functions: [],
    );

    test('_streamJobs map uses ConcurrentHashMap with Pair<String, Long> key', () {
      final kt = KotlinGenerator.generate(twoStreamSpec());
      expect(kt, contains('java.util.concurrent.ConcurrentHashMap<Pair<String, Long>, kotlinx.coroutines.Job>()'),
          reason: 'ConcurrentHashMap prevents data races on concurrent register/release calls');
      expect(kt, isNot(contains('mutableMapOf<Long, kotlinx.coroutines.Job>()')));
    });

    test('frames register uses Pair("frames", dartPort) as map key', () {
      final kt = KotlinGenerator.generate(twoStreamSpec());
      expect(kt, contains('_streamJobs[Pair("frames", dartPort)]'));
    });

    test('coloredFrames register uses Pair("coloredFrames", dartPort) as map key', () {
      final kt = KotlinGenerator.generate(twoStreamSpec());
      expect(kt, contains('_streamJobs[Pair("coloredFrames", dartPort)]'));
    });

    test('frames release uses Pair("frames", dartPort) in remove()', () {
      final kt = KotlinGenerator.generate(twoStreamSpec());
      expect(kt, contains('_streamJobs.remove(Pair("frames", dartPort))'));
    });

    test('coloredFrames release uses Pair("coloredFrames", dartPort) in remove()', () {
      final kt = KotlinGenerator.generate(twoStreamSpec());
      expect(kt, contains('_streamJobs.remove(Pair("coloredFrames", dartPort))'));
    });

    test('plain dartPort is not used directly as _streamJobs key', () {
      final kt = KotlinGenerator.generate(twoStreamSpec());
      expect(kt, isNot(contains('_streamJobs[dartPort]')),
          reason: 'bare port key must be replaced by composite Pair key');
      expect(kt, isNot(contains('_streamJobs.remove(dartPort)')));
    });
  });

  // ── 9. Issue 18 — spec-path attribution in generated files ────────────────

  group('Generators — "Generated from:" attribution', () {
    test('DartFfiGenerator emits Generated from: header', () {
      final out = DartFfiGenerator.generate(_syncRecordSpec());
      expect(out, contains('// Generated from: camera_module.native.dart'));
    });

    test('KotlinGenerator emits Generated from: header', () {
      final out = KotlinGenerator.generate(_syncRecordSpec());
      expect(out, contains('// Generated from: camera_module.native.dart'));
    });

    test('CppBridgeGenerator emits Generated from: header', () {
      final out = CppBridgeGenerator.generate(_syncRecordSpec());
      expect(out, contains('// Generated from: camera_module.native.dart'));
    });

    test('Generated from: line appears before functional code', () {
      // Attribution must be near the top — within the first 200 chars.
      final out = DartFfiGenerator.generate(_syncRecordSpec());
      final idx = out.indexOf('// Generated from:');
      expect(idx, lessThan(200),
          reason: 'attribution comment must appear at the top of the file');
    });
  });
}

// ── Helper used in test reason strings only ───────────────────────────────────

String _kotlinEquivalent(String dartType) {
  switch (dartType) {
    case 'Uint8List':
    case 'Int8List':
      return 'ByteArray';
    case 'Int16List':
    case 'Uint16List':
      return 'ShortArray';
    case 'Int32List':
    case 'Uint32List':
      return 'IntArray';
    case 'Float32List':
      return 'FloatArray';
    case 'Float64List':
      return 'DoubleArray';
    case 'Int64List':
    case 'Uint64List':
      return 'LongArray';
    default:
      return 'Unknown';
  }
}
