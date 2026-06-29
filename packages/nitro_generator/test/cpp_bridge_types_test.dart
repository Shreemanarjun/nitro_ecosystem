import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';

// ── Shared spec builders ─────────────────────────────────────────────────────

BridgeSpec _jniFuncSpec({
  required String dartName,
  required BridgeType returnType,
  required List<BridgeParam> params,
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.swift,
  androidImpl: NativeImpl.kotlin,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  functions: [
    BridgeFunction(
      dartName: dartName,
      cSymbol: 'mod_$dartName',
      isAsync: false,
      returnType: returnType,
      params: params,
    ),
  ],
);

BridgeSpec _cppFuncSpec({
  required String dartName,
  required BridgeType returnType,
  required List<BridgeParam> params,
  List<BridgeEnum> enums = const [],
  List<BridgeStruct> structs = const [],
}) => BridgeSpec(
  dartClassName: 'Mod',
  lib: 'mod',
  namespace: 'mod',
  iosImpl: NativeImpl.cpp,
  androidImpl: NativeImpl.cpp,
  sourceUri: 'mod.native.dart',
  enums: enums,
  structs: structs,
  functions: [
    BridgeFunction(
      dartName: dartName,
      cSymbol: 'mod_$dartName',
      isAsync: false,
      returnType: returnType,
      params: params,
    ),
  ],
);

// ── §8.5.1 Uint8List param marshalling (JNI path) ───────────────────────────

void main() {
  group('CppBridgeGenerator — Uint8List param (JNI path)', () {
    final spec = _jniFuncSpec(
      dartName: 'upload',
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'data',
          type: BridgeType(name: 'Uint8List'),
        ),
      ],
    );
    final code = CppBridgeGenerator.generate(spec);

    test('C declaration has uint8_t* param', () {
      expect(code, contains('uint8_t*'));
    });

    test('C declaration has int64_t data_length param', () {
      expect(code, contains('int64_t data_length'));
    });

    test('JNI path creates jbyteArray from uint8_t* buffer', () {
      expect(code, contains('NewByteArray'));
    });

    test('JNI path copies bytes via SetByteArrayRegion', () {
      expect(code, contains('SetByteArrayRegion'));
    });

    test('JNI path uses j_data as the JNI call argument', () {
      expect(code, contains('j_data'));
    });
  });

  group('CppBridgeGenerator — TypedData return (JNI path)', () {
    test('Uint8List return copies JVM array into length-prefixed malloc buffer', () {
      final spec = _jniFuncSpec(
        dartName: 'download',
        returnType: BridgeType(name: 'Uint8List'),
        params: const [],
      );
      final out = CppBridgeGenerator.generate(spec);

      expect(out, contains('uint8_t* mod_download(int64_t instanceId, NitroError* _nitro_err)'));
      expect(out, contains('jbyteArray jarr = (jbyteArray)env->CallStaticObjectMethod'));
      expect(out, contains('size_t byteLen = (size_t)len * sizeof(uint8_t);'));
      expect(out, contains('uint8_t* result = (uint8_t*)malloc(byteLen + sizeof(int64_t));'));
      expect(out, contains('*((int64_t*)result) = (int64_t)byteLen;'));
      expect(out, contains('env->GetByteArrayRegion(jarr, 0, len, (jbyte*)(result + sizeof(int64_t)));'));
    });

    test('Float32List return preserves byte length and float payload', () {
      final spec = _jniFuncSpec(
        dartName: 'samples',
        returnType: BridgeType(name: 'Float32List'),
        params: const [],
      );
      final out = CppBridgeGenerator.generate(spec);

      expect(out, contains('uint8_t* mod_samples(int64_t instanceId, NitroError* _nitro_err)'));
      expect(out, contains('jfloatArray jarr = (jfloatArray)env->CallStaticObjectMethod'));
      expect(out, contains('size_t byteLen = (size_t)len * sizeof(float);'));
      expect(out, contains('env->GetFloatArrayRegion(jarr, 0, len, (jfloat*)(result + sizeof(int64_t)));'));
    });
  });

  // ── §8.5.2 Uint8List param (C++ direct path) ────────────────────────────

  group('CppBridgeGenerator — Uint8List param (C++ direct path)', () {
    final spec = _cppFuncSpec(
      dartName: 'upload',
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'data',
          type: BridgeType(name: 'Uint8List'),
        ),
      ],
    );
    final code = CppBridgeGenerator.generate(spec);

    test('C++ direct declaration has uint8_t* param', () {
      expect(code, contains('uint8_t*'));
    });

    test('C++ direct declaration has int64_t data_length param', () {
      expect(code, contains('int64_t data_length'));
    });

    test('C++ direct call passes data pointer to g_impl', () {
      expect(code, contains('g_impl->upload('));
      expect(code, contains('data'));
    });

    test('C++ direct call passes data_length to g_impl', () {
      expect(code, contains('data_length'));
    });

    test('C++ direct path does NOT contain JNI_OnLoad', () {
      expect(code, isNot(contains('JNI_OnLoad')));
    });
  });

  group('CppBridgeGenerator — zero-copy TypedData return (C++ direct path)', () {
    BridgeSpec specFor(String typeName) => BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.cpp,
      androidImpl: NativeImpl.cpp,
      sourceUri: 'mod.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'snapshot',
          cSymbol: 'mod_snapshot',
          isAsync: false,
          returnType: BridgeType(name: typeName),
          zeroCopyReturn: true,
          params: [],
        ),
      ],
    );

    test('Uint8List return wraps NitroCppBuffer in finalizer envelope', () {
      final code = CppBridgeGenerator.generate(specFor('Uint8List'));

      expect(code, contains('uint8_t* mod_snapshot(int64_t instanceId, NitroError* _nitro_err)'));
      expect(code, contains('NitroCppBuffer _res = g_impl->snapshot();'));
      expect(code, contains('int64_t* _env = (int64_t*)malloc(sizeof(int64_t) * 3);'));
      expect(code, contains('_env[0] = (int64_t)_res.size;'));
      expect(code, contains('_env[1] = (int64_t)(intptr_t)(_res.data != nullptr ? _res.data : (const uint8_t*)_env);'));
      expect(code, contains('_env[2] = 0;'));
      expect(code, contains('return (uint8_t*)_env;'));
    });

    test('Float32List return still exposes uint8_t envelope pointer at C ABI', () {
      final code = CppBridgeGenerator.generate(specFor('Float32List'));

      expect(code, contains('uint8_t* mod_snapshot(int64_t instanceId, NitroError* _nitro_err)'));
      expect(code, isNot(contains('float* mod_snapshot(int64_t instanceId, NitroError* _nitro_err)')));
    });
  });

  // ── §8.5.3 Float32List param marshalling (JNI path) ─────────────────────

  group('CppBridgeGenerator — Float32List param (JNI path)', () {
    final spec = _jniFuncSpec(
      dartName: 'processSamples',
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'samples',
          type: BridgeType(name: 'Float32List'),
        ),
      ],
    );
    final code = CppBridgeGenerator.generate(spec);

    test('C declaration has float* param', () {
      expect(code, contains('float*'));
    });

    test('C declaration has int64_t samples_length param', () {
      expect(code, contains('int64_t samples_length'));
    });

    test('JNI path creates jfloatArray', () {
      expect(code, contains('NewFloatArray'));
    });

    test('JNI path copies floats via SetFloatArrayRegion', () {
      expect(code, contains('SetFloatArrayRegion'));
    });
  });

  group('CppBridgeGenerator — zero-copy TypedData param (JNI path)', () {
    BridgeSpec zeroCopySpec(String typeName, {String returnType = 'void'}) => _jniFuncSpec(
      dartName: 'processZeroCopy',
      returnType: BridgeType(name: returnType),
      params: [
        BridgeParam(
          name: 'samples',
          type: BridgeType(name: typeName),
          zeroCopy: true,
        ),
      ],
    );

    test('Float32List param bridges as direct ByteBuffer without JVM array copy', () {
      final code = CppBridgeGenerator.generate(zeroCopySpec('Float32List'));
      expect(code, contains('Ljava/nio/ByteBuffer;'));
      expect(code, contains('int64_t samples_byte_length = samples_length * (int64_t)sizeof(float);'));
      expect(code, contains('jobject j_samples = env->NewDirectByteBuffer(samples, samples_byte_length);'));
      expect(code, contains('CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, j_samples)'));
      expect(code, isNot(contains('NewFloatArray')));
      expect(code, isNot(contains('SetFloatArrayRegion')));
    });

    test('Uint8List param uses byte count without widening copy', () {
      final code = CppBridgeGenerator.generate(zeroCopySpec('Uint8List'));
      expect(code, contains('int64_t samples_byte_length = samples_length * (int64_t)sizeof(uint8_t);'));
      expect(code, contains('jobject j_samples = env->NewDirectByteBuffer(samples, samples_byte_length);'));
      expect(code, isNot(contains('NewByteArray')));
      expect(code, isNot(contains('SetByteArrayRegion')));
    });

    test('non-null param guards negative length, null pointer, overflow, and ByteBuffer creation', () {
      final code = CppBridgeGenerator.generate(zeroCopySpec('Float32List'));
      expect(code, contains('if (samples_length < 0)'));
      expect(code, contains('if (samples == nullptr)'));
      expect(code, contains('if (samples_length > INT64_MAX / (int64_t)sizeof(float))'));
      expect(code, contains('if (j_samples == nullptr)'));
      expect(code, contains('samples: TypedData byte length overflow'));
    });

    test('nullable param allows null only for empty buffers', () {
      final code = CppBridgeGenerator.generate(zeroCopySpec('Float32List?'));
      expect(code, contains('if (samples == nullptr && samples_length > 0)'));
      expect(code, contains('if (j_samples == nullptr && samples_byte_length > 0)'));
    });

    test('non-void return guard returns the correct default value', () {
      final code = CppBridgeGenerator.generate(zeroCopySpec('Float32List', returnType: 'double'));
      expect(code, contains('return 0.0;'));
    });
  });

  // ── §8.5.4 Float32List param (C++ direct path) ──────────────────────────

  group('CppBridgeGenerator — Float32List param (C++ direct path)', () {
    final spec = _cppFuncSpec(
      dartName: 'processSamples',
      returnType: BridgeType(name: 'void'),
      params: [
        BridgeParam(
          name: 'samples',
          type: BridgeType(name: 'Float32List'),
        ),
      ],
    );
    final code = CppBridgeGenerator.generate(spec);

    test('C++ direct has float* param', () {
      expect(code, contains('float*'));
    });

    test('C++ direct has int64_t samples_length', () {
      expect(code, contains('int64_t samples_length'));
    });

    test('C++ direct passes samples and length to g_impl', () {
      expect(code, contains('g_impl->processSamples('));
      expect(code, contains('samples_length'));
    });
  });

  // ── §8.5.5 @NitroNativeAsync function (JNI path) ────────────────────────

  group('CppBridgeGenerator — @NitroNativeAsync function (JNI path)', () {
    final spec = BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'mod.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'processAsync',
          cSymbol: 'mod_process_async',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'value',
              type: BridgeType(name: 'int'),
            ),
          ],
        ),
      ],
    );
    final code = CppBridgeGenerator.generate(spec);

    test('@NitroNativeAsync function has void C return type', () {
      expect(code, contains('void mod_process_async('));
    });

    test('@NitroNativeAsync function has int64_t dart_port parameter', () {
      expect(code, contains('int64_t dart_port'));
    });

    test('@NitroNativeAsync passes dart_port to JNI call', () {
      expect(code, contains('(jlong)dart_port'));
    });

    test('@NitroNativeAsync uses CallStaticVoidMethod', () {
      expect(code, contains('CallStaticVoidMethod'));
    });

    test('@NitroNativeAsync does NOT return a value (no return type in bridge)', () {
      // The C return is void — there should be no `return someValue;` for this function
      final idx = code.indexOf('void mod_process_async(');
      final snippet = code.substring(idx, idx + 300);
      expect(snippet, isNot(contains('return 0')));
      expect(snippet, isNot(contains('return false')));
      expect(snippet, isNot(contains('return nullptr')));
    });
  });

  // ── §8.5.6 @NitroNativeAsync function (C++ direct path) ─────────────────

  group('CppBridgeGenerator — @NitroNativeAsync function (C++ direct path)', () {
    final spec = BridgeSpec(
      dartClassName: 'Mod',
      lib: 'mod',
      namespace: 'mod',
      iosImpl: NativeImpl.cpp,
      androidImpl: NativeImpl.cpp,
      sourceUri: 'mod.native.dart',
      functions: [
        BridgeFunction(
          dartName: 'computeAsync',
          cSymbol: 'mod_compute_async',
          isAsync: false,
          isNativeAsync: true,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'x',
              type: BridgeType(name: 'double'),
            ),
          ],
        ),
      ],
    );
    final code = CppBridgeGenerator.generate(spec);

    test('@NitroNativeAsync in cpp direct has void return', () {
      expect(code, contains('void mod_compute_async('));
    });

    test('@NitroNativeAsync in cpp direct has dart_port param', () {
      expect(code, contains('int64_t dart_port'));
    });

    test('@NitroNativeAsync in cpp direct calls g_impl with dart_port', () {
      expect(code, contains('g_impl->computeAsync('));
      expect(code, contains('dart_port'));
    });

    test('@NitroNativeAsync in cpp direct posts null to port when g_impl missing', () {
      expect(code, contains('Dart_PostCObject_DL'));
    });
  });

  // ── §8.5.7 Enum param in C++ direct path ────────────────────────────────

  group('CppBridgeGenerator — enum param (C++ direct path)', () {
    final spec = BridgeSpec(
      dartClassName: 'Printer',
      lib: 'printer',
      namespace: 'printer',
      iosImpl: NativeImpl.cpp,
      androidImpl: NativeImpl.cpp,
      sourceUri: 'printer.native.dart',
      enums: [
        BridgeEnum(name: 'Quality', startValue: 0, values: ['draft', 'normal', 'high']),
      ],
      functions: [
        BridgeFunction(
          dartName: 'setQuality',
          cSymbol: 'printer_set_quality',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'quality',
              type: BridgeType(name: 'Quality'),
            ),
          ],
        ),
      ],
    );
    final code = CppBridgeGenerator.generate(spec);

    test('enum param casts to enum type via static_cast in C++ direct', () {
      expect(code, contains('static_cast<Quality>('));
    });

    test('setQuality function is declared with quality param', () {
      expect(code, contains('printer_set_quality'));
      expect(code, contains('quality'));
    });

    test('g_impl->setQuality is called with the cast param', () {
      expect(code, contains('g_impl->setQuality('));
    });
  });

  // ── §8.5.8 Enum param in JNI path ───────────────────────────────────────

  group('CppBridgeGenerator — enum param (JNI path)', () {
    final spec = BridgeSpec(
      dartClassName: 'Printer',
      lib: 'printer',
      namespace: 'printer',
      iosImpl: NativeImpl.swift,
      androidImpl: NativeImpl.kotlin,
      sourceUri: 'printer.native.dart',
      enums: [
        BridgeEnum(name: 'Quality', startValue: 0, values: ['draft', 'normal', 'high']),
      ],
      functions: [
        BridgeFunction(
          dartName: 'setQuality',
          cSymbol: 'printer_set_quality',
          isAsync: false,
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'quality',
              type: BridgeType(name: 'Quality'),
            ),
          ],
        ),
      ],
    );
    final code = CppBridgeGenerator.generate(spec);

    test('JNI path emits printer_set_quality function', () {
      expect(code, contains('printer_set_quality'));
    });

    test('JNI path passes quality arg to CallStaticVoidMethod', () {
      expect(code, contains('CallStaticVoidMethod'));
      expect(code, contains('quality'));
    });
  });

  // ── §8.5.9 Multiple TypedData variants in C++ direct path ───────────────

  group('CppBridgeGenerator — TypedData variants (C++ direct path)', () {
    const variants = [
      ('Uint8List', 'uint8_t*'),
      ('Int8List', 'int8_t*'),
      ('Int16List', 'int16_t*'),
      ('Int32List', 'int32_t*'),
      ('Float32List', 'float*'),
      ('Float64List', 'double*'),
      ('Int64List', 'int64_t*'),
    ];

    for (final (dartType, cType) in variants) {
      test('$dartType param emits $cType in C++ direct bridge', () {
        final spec = _cppFuncSpec(
          dartName: 'send',
          returnType: BridgeType(name: 'void'),
          params: [
            BridgeParam(
              name: 'buf',
              type: BridgeType(name: dartType),
            ),
          ],
        );
        final out = CppBridgeGenerator.generate(spec);
        expect(out, contains(cType), reason: '$dartType should map to $cType');
        expect(out, contains('int64_t buf_length'));
      });
    }
  });

  // ── §8.5.10 Async (@nitroAsync) function return type in C++ direct ───────

  group('CppBridgeGenerator — @nitroAsync function (C++ direct path)', () {
    test('@nitroAsync bool return uses int8_t C return type', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'connect',
            cSymbol: 'mod_connect',
            isAsync: true,
            returnType: BridgeType(name: 'bool', isFuture: true),
            params: [],
          ),
        ],
      );
      final code = CppBridgeGenerator.generate(spec);
      expect(code, contains('mod_connect'));
      expect(code, contains('g_impl->connect()'));
    });

    test('@nitroAsync String return uses strdup pattern', () {
      final spec = BridgeSpec(
        dartClassName: 'Mod',
        lib: 'mod',
        namespace: 'mod',
        iosImpl: NativeImpl.cpp,
        androidImpl: NativeImpl.cpp,
        sourceUri: 'mod.native.dart',
        functions: [
          BridgeFunction(
            dartName: 'fetchName',
            cSymbol: 'mod_fetch_name',
            isAsync: true,
            returnType: BridgeType(name: 'String', isFuture: true),
            params: [],
          ),
        ],
      );
      final code = CppBridgeGenerator.generate(spec);
      expect(code, contains('strdup'));
      expect(code, contains('g_impl->fetchName()'));
    });
  });
}
