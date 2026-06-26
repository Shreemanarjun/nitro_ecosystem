part of '../cpp_bridge_generator.dart';

/// Returns true when all struct fields are numeric (int/double/bool) — can be
/// expanded to individual jlong params for synchronous NativeCallable.listener.
bool _isExpandableStruct(BridgeStruct st) {
  const numeric = {'int', 'double', 'bool'};
  return st.fields.isNotEmpty &&
      st.fields.every((f) => numeric.contains(f.type.name.replaceFirst('?', '')) && !f.type.isTypedData);
}

String _paramTypeToC(String dartType, Set<String> structNames) => CppBridgeGenerator._paramTypeToC(dartType, structNames);

String _jniCallbackParamToC(BridgeParam param, Set<String> enumNames, {Set<String>? structNames, Set<String>? recordNames}) => CppBridgeGenerator._callbackParamToC(param, enumNames, structNames: structNames, recordNames: recordNames);

void _emitZeroCopyTypedDataParam(
  CodeWriter writer,
  BridgeParam param, {
  required String? returnExpr,
}) => CppBridgeGenerator._emitZeroCopyTypedDataParam(writer, param, returnExpr: returnExpr);

String _jniNativeAsyncSig(
  List<BridgeParam> params,
  Set<String> enumNames,
  Set<String> structNames,
  String libPkg,
) => CppBridgeGenerator._jniNativeAsyncSig(params, enumNames, structNames, libPkg);

String _jniSig(
  List<BridgeParam> params,
  BridgeType returnType,
  Set<String> enumNames,
  Set<String> structNames,
  String libPkg, {
  bool zeroCopyReturn = false,
}) => CppBridgeGenerator._jniSig(params, returnType, enumNames, structNames, libPkg, zeroCopyReturn: zeroCopyReturn);

String _typedDataElementSizeExpr(String dartType) => CppBridgeGenerator._typedDataElementSizeExpr(dartType);

String _jniSigType(String dartType) => CppBridgeGenerator._jniSigType(dartType);

String _jniSigTypeC(String dartType) => CppBridgeGenerator._jniSigTypeC(dartType);

String _jniMethodName(String lib, String className, String methodName) => CppBridgeGenerator._jniMethodName(lib, className, methodName);

void _emitDartPostCObjectHelper(
  CodeWriter writer, {
  required String symbol,
  required String envParamDecl,
  required String valueParamDecl,
  required String cObjectType,
  String? valueAssignment,
  String? beforePost,
  String? afterPost,
}) {
  writer.line('JNIEXPORT void JNICALL $symbol($envParamDecl, jclass, jlong dartPort$valueParamDecl) {');
  if (beforePost != null) writer.line('    $beforePost');
  writer.line('    Dart_CObject obj;');
  writer.line('    obj.type = $cObjectType;');
  if (valueAssignment != null) writer.line('    $valueAssignment');
  writer.line('    Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
  if (afterPost != null) writer.line('    $afterPost');
  writer.line('}');
  writer.blankLine();
}

void _emitJniMethods(
  CodeWriter writer,
  BridgeSpec spec,
  String libStem,
  String libPkg,
  Set<String> enumNames,
  Set<String> structNames,
) {
  // Pre-built at function scope so all inner loops can reference it.
  final recordNames = spec.recordTypes.map((r) => r.name).toSet();

  if (spec.functions.any((f) => f.zeroCopyReturn && f.returnType.isTypedData)) {
    writer.line('NITRO_EXPORT void ${libStem}_release_typed_data_return(void* ptr) {');
    writer.line('    if (!ptr) { return; }');

    writer.line('    int64_t* words = (int64_t*)ptr;');
    writer.line('    void* owner = (void*)(intptr_t)words[2];');
    writer.line('    if (owner != nullptr) {');
    writer.line('        JNIEnv* env = GetEnv();');
    writer.line('        if (env != nullptr) { env->DeleteGlobalRef((jobject)owner); }');

    writer.line('    }');
    writer.line('    free(ptr);');
    writer.line('}');
    writer.blankLine();
  }

  // ── Functions ─────────────────────────────────────────────────────────────
  for (final func in spec.functions) {
    // ── @nitroNativeAsync: void + dart_port, delegates to CallStaticVoidMethod ──
    if (func.isNativeAsync) {
      final paramsDeclParts = <String>[];
      for (final p in func.params) {
        paramsDeclParts.add('${_paramTypeToC(p.type.name, structNames)} ${p.name}');
        if (p.type.isTypedData) paramsDeclParts.add('int64_t ${p.name}_length');
      }
      paramsDeclParts.add('int64_t dart_port');
      final paramsDecl = paramsDeclParts.join(', ');
      final jniNativeAsyncSig = _jniNativeAsyncSig(func.params, enumNames, structNames, libPkg);

      writer.line('void ${func.cSymbol}($paramsDecl) {');
      writer.line('    JNIEnv* env = GetEnv();');
      writer.line('    if (env == nullptr) { return; }');

      writer.line('    jmethodID methodId = g_mid_${func.dartName}_call;');
      writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${func.dartName}_call sig=$jniNativeAsyncSig"); return; }');
      writer.blankLine();
      writer.line('    ${libStem}_clear_error();');
      writer.line('    if (env->PushLocalFrame(16) != 0) { return; }');


      final callArgsList = <String>[];
      for (final p in func.params) {
        final pt = p.type.name;
        if (pt == 'String') {
          writer.line('    jstring j_${p.name} = env->NewStringUTF(${p.name});');
          callArgsList.add('j_${p.name}');
        } else if (pt == 'String?') {
          writer.line('    jstring j_${p.name} = (${p.name} != nullptr) ? env->NewStringUTF(${p.name}) : nullptr;');
          callArgsList.add('j_${p.name}');
        } else if (structNames.contains(pt.replaceFirst('?', ''))) {
          final baseType = pt.replaceFirst('?', '');
          if (pt.endsWith('?')) {
            writer.line('    jobject jobj_${p.name} = (${p.name} != nullptr) ? unpack_${baseType}_to_jni(env, (const $baseType*)${p.name}) : nullptr;');
          } else {
            writer.line('    jobject jobj_${p.name} = unpack_${baseType}_to_jni(env, (const $baseType*)${p.name});');
          }
          callArgsList.add('jobj_${p.name}');
        } else if (p.zeroCopy && p.type.isTypedData) {
          _emitZeroCopyTypedDataParam(
            writer,
            p,
            returnExpr: null,
          );
          callArgsList.add('j_${p.name}');
        } else if (!p.zeroCopy && p.type.isTypedData) {
          final ops = _typedDataJniOps(pt);
          writer.line('    ${ops[0]} j_${p.name} = env->${ops[1]}((jsize)${p.name}_length);');
          writer.line('    env->${ops[2]}(j_${p.name}, 0, (jsize)${p.name}_length, (const ${ops[3]}*)${p.name});');
          callArgsList.add('j_${p.name}');
        } else if (p.type.isMap) {
          // Map<String, T>: binary uint8_t* (with 4-byte length prefix) → jbyteArray.
          writer.line('    jsize j_${p.name}_len = (jsize)(*((int32_t*)${p.name} + 0)) + 4;');
          writer.line('    jbyteArray j_${p.name} = env->NewByteArray(j_${p.name}_len);');
          writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, j_${p.name}_len, (const jbyte*)${p.name});');
          callArgsList.add('j_${p.name}');
        } else {
          callArgsList.add(p.name);
        }
      }
      callArgsList.add('(jlong)dart_port');
      final callArgs = callArgsList.join(', ');
      writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, $callArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    final isEnum = enumNames.contains(func.returnType.name.replaceFirst('?', ''));
    final isStruct = structNames.contains(func.returnType.name.replaceFirst('?', ''));
    final isRecord = func.returnType.isRecord && !func.returnType.isMap;
    final isMap = func.returnType.isMap;
    final isTypedData = func.returnType.isTypedData;
    // For enum returns: bridge returns Long (nativeValue); C returns int64_t
    // For struct returns: bridge returns jobject; C packs to C struct via malloc
    // For record returns: bridge returns ByteArray; C copies bytes to malloc'd buffer
    // For TypedData returns: bridge returns a JVM primitive array; C copies it
    // into a malloc-owned [int64 byte length][payload bytes] envelope.
    final isNullablePrimReturn = func.returnType.name == 'int?' || func.returnType.name == 'double?' || func.returnType.name == 'bool?';
    final cReturnType = isNullablePrimReturn
        ? 'uint8_t*'
        : isEnum
        ? 'int64_t'
        : isTypedData
        ? 'uint8_t*'
        : _typeToC(func.returnType.name);
    final paramsDeclParts = <String>[];
    for (final p in func.params) {
      if (p.type.isFunction) {
        paramsDeclParts.add(_jniCallbackParamToC(p, enumNames, structNames: structNames, recordNames: recordNames));
        continue;
      }
      // Enum params: must be int64_t (rawValue) not void* — void* cast of -1 (null
      // sentinel) is implementation-defined and may not equal int64_t -1 on some
      // Android/AArch64 compilers. Use int64_t to guarantee correct bit pattern.
      final paramBase = p.type.name.replaceFirst('?', '');
      final isEnumParam = enumNames.contains(paramBase);
      // Nullable primitives arrive as void* (Pointer<Uint8> NitroNullable buffer).
      final isNullablePrimParam = p.type.name.endsWith('?') && (paramBase == 'int' || paramBase == 'double' || paramBase == 'bool');
      final cParamType = isNullablePrimParam ? 'void*' : (isEnumParam ? 'int64_t' : _paramTypeToC(p.type.name, structNames));
      paramsDeclParts.add('$cParamType ${p.name}');
      if (p.type.isTypedData) paramsDeclParts.add('int64_t ${p.name}_length');
    }
    // S8: SYNC functions take NitroError* as the last parameter.
    // @nitroAsync functions use the old TLS get_error/clear_error mechanism —
    // Dart's callAsync does NOT pass NitroError* so it must not be in the signature.
    if (!func.isAsync) {
      paramsDeclParts.add('NitroError* _nitro_err');
    }
    final paramsDecl = paramsDeclParts.join(', ');

    writer.line(
      '$cReturnType ${func.cSymbol}($paramsDecl) {',
    );
    if (func.isAsync) {
      // @nitroAsync uses old TLS get_error/clear_error — declare _nitro_err as null
      // local so nitro_report_jni_exception calls compile (errors go to TLS instead).
      writer.line('    NitroError* _nitro_err = nullptr; // async: errors use TLS not out-param');
    } else {
      // S8: sync functions reset the out-param error slot before each call.
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }  // S8: clear slot');
    }
    writer.line('    JNIEnv* env = GetEnv();');
    if (func.returnType.name == 'void') {
      writer.line('    if (env == nullptr) { return; }');

    } else {
      writer.line(
        '    if (env == nullptr) { return ${_defaultValue(cReturnType)}; }',
      );
    }
    writer.line('    jmethodID methodId = g_mid_${func.dartName}_call;');
    final jniSigForLog = _jniSig(func.params, func.returnType, enumNames, structNames, libPkg, zeroCopyReturn: func.zeroCopyReturn);
    if (func.returnType.name == 'void') {
      writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${func.dartName}_call sig=$jniSigForLog"); return; }');
    } else {
      writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${func.dartName}_call sig=$jniSigForLog"); return ${_defaultValue(cReturnType)}; }');
    }
    writer.blankLine();
    writer.line('    ${libStem}_clear_error();');
    if (func.returnType.name == 'void') {
      writer.line('    if (env->PushLocalFrame(16) != 0) { return; }');

    } else {
      writer.line('    if (env->PushLocalFrame(16) != 0) { return ${_defaultValue(cReturnType)}; }');
    }

    // Build call args (converting C types to JNI types)
    final callArgsList = <String>[];
    for (final p in func.params) {
      final pt = p.type.name;
      if (pt == 'String') {
        writer.line('    jstring j_${p.name} = env->NewStringUTF(${p.name});');
        callArgsList.add('j_${p.name}');
      } else if (pt == 'String?') {
        writer.line('    jstring j_${p.name} = (${p.name} != nullptr) ? env->NewStringUTF(${p.name}) : nullptr;');
        callArgsList.add('j_${p.name}');
      } else if (structNames.contains(pt.replaceFirst('?', ''))) {
        final baseType = pt.replaceFirst('?', '');
        if (pt.endsWith('?')) {
          writer.line(
            '    jobject jobj_${p.name} = (${p.name} != nullptr) ? unpack_${baseType}_to_jni(env, (const $baseType*)${p.name}) : nullptr;',
          );
        } else {
          writer.line(
            '    jobject jobj_${p.name} = unpack_${baseType}_to_jni(env, (const $baseType*)${p.name});',
          );
        }
        callArgsList.add('jobj_${p.name}');
      } else if (p.zeroCopy && p.type.isTypedData) {
        _emitZeroCopyTypedDataParam(
          writer,
          p,
          returnExpr: func.returnType.name == 'void' ? null : _defaultValue(cReturnType),
        );
        callArgsList.add('j_${p.name}');
      } else if (!p.zeroCopy && p.type.isTypedData) {
        final ops = _typedDataJniOps(pt);
        writer.line('    ${ops[0]} j_${p.name} = env->${ops[1]}((jsize)${p.name}_length);');
        writer.line('    env->${ops[2]}(j_${p.name}, 0, (jsize)${p.name}_length, (const ${ops[3]}*)${p.name});');
        callArgsList.add('j_${p.name}');
      } else if (p.type.isFunction) {
        callArgsList.add('(jlong)${p.name}');
      } else if (p.type.isMap) {
        // Map<String, T>: binary uint8_t* (4-byte length prefix + payload) → jbyteArray.
        writer.line('    int32_t ${p.name}_map_len = *((const int32_t*)${p.name}) + 4;');
        writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)${p.name}_map_len);');
        writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_map_len, (const jbyte*)${p.name});');
        callArgsList.add('j_${p.name}');
      } else if (p.type.name.endsWith('?') && ['int', 'double', 'bool'].contains(p.type.name.replaceFirst('?', ''))) {
        // Nullable primitive: NitroNullable binary buffer (void* pointing to Pointer<Uint8>).
        // Format: [4B outer_len][1B hasValue][nB value] — same as other records.
        // Pass as jbyteArray to Kotlin's ByteArray param.
        final paramBase2 = p.type.name.replaceFirst('?', '');
        final nullableSize = paramBase2 == 'bool' ? 2 : 9; // bool=2B, int/double=9B
        writer.line('    int32_t ${p.name}_payload_len = *((const int32_t*)${p.name});');
        writer.line('    int32_t ${p.name}_total = ${p.name}_payload_len + 4;');
        writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)${p.name}_total);');
        writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_total, (const jbyte*)${p.name});');
        callArgsList.add('j_${p.name}');
      } else if (p.type.isRecord) {
        // @HybridRecord / List<@HybridRecord> params arrive as void* (Dart Pointer<Uint8>).
        // Dart's RecordWriter.toNative() format: [4-byte payload_len][payload_bytes].
        // Pass the FULL buffer (prefix + payload) to Kotlin as jbyteArray.
        // Kotlin's record decode skips the 4-byte prefix before reading fields.
        //
        // NULLABLE records: Dart sends nullptr for null → guard before reading length prefix
        // to avoid SIGSEGV. Kotlin receives null jbyteArray and passes null to the impl.
        final isNullableRecord = p.type.isNullable || p.type.name.endsWith('?');
        if (isNullableRecord) {
          writer.line('    jbyteArray j_${p.name} = nullptr;');
          writer.line('    if (${p.name} != nullptr) {');
          writer.line('        int32_t ${p.name}_payload_len = *((const int32_t*)${p.name});');
          writer.line('        int32_t ${p.name}_total = ${p.name}_payload_len + 4;');
          writer.line('        j_${p.name} = env->NewByteArray((jsize)${p.name}_total);');
          writer.line('        env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_total, (const jbyte*)${p.name});');
          writer.line('    }');
        } else {
          writer.line('    int32_t ${p.name}_payload_len = *((const int32_t*)${p.name});');
          writer.line('    int32_t ${p.name}_total = ${p.name}_payload_len + 4;');
          writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)${p.name}_total);');
          writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_total, (const jbyte*)${p.name});');
        }
        callArgsList.add('j_${p.name}');
      } else {
        callArgsList.add(p.name);
      }
    }

    final callArgs = callArgsList.join(', ');
    final bridgeArgs = callArgs.isEmpty ? '' : ', $callArgs';

    if (func.returnType.name == 'void') {
      writer.line(
        '    env->CallStaticVoidMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    env->PopLocalFrame(nullptr);');
    } else if (func.returnType.name == 'double') {
      writer.line(
        '    double res = env->CallStaticDoubleMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0.0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    } else if (func.returnType.name == 'double?') {
      // Kotlin returns NitroNullableDouble as ByteArray — copy to malloc'd buffer.
      writer.line('    jbyteArray jarr_nd = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_nd == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    jsize nd_len = env->GetArrayLength(jarr_nd);');
      writer.line('    uint8_t* nd_result = (uint8_t*)malloc(nd_len);');
      writer.line('    env->GetByteArrayRegion(jarr_nd, 0, nd_len, (jbyte*)nd_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return nd_result;');
    } else if (func.returnType.name == 'int') {
      writer.line(
        '    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    } else if (func.returnType.name == 'int?') {
      // Kotlin returns NitroNullableInt as ByteArray — copy to malloc'd buffer.
      writer.line('    jbyteArray jarr_ni = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_ni == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    jsize ni_len = env->GetArrayLength(jarr_ni);');
      writer.line('    uint8_t* ni_result = (uint8_t*)malloc(ni_len);');
      writer.line('    env->GetByteArrayRegion(jarr_ni, 0, ni_len, (jbyte*)ni_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return ni_result;');
    } else if (func.returnType.name == 'bool') {
      // Non-nullable bool: use CallStaticBooleanMethod (()Z).
      writer.line(
        '    bool res = env->CallStaticBooleanMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return false;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    } else if (func.returnType.name == 'bool?') {
      // Nullable bool?: Kotlin returns NitroNullableBool as ByteArray — copy to malloc'd buffer.
      writer.line('    jbyteArray jarr_nb = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_nb == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    jsize nb_len = env->GetArrayLength(jarr_nb);');
      writer.line('    uint8_t* nb_result = (uint8_t*)malloc(nb_len);');
      writer.line('    env->GetByteArrayRegion(jarr_nb, 0, nb_len, (jbyte*)nb_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return nb_result;');
    } else if (func.returnType.name == 'String' || func.returnType.name == 'String?') {
      writer.line(
        '    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jstr == nullptr) {');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line(
        '    const char* nativeStr = env->GetStringUTFChars(jstr, 0);',
      );
      writer.line('    char* result = strdup(nativeStr);');
      writer.line('    env->ReleaseStringUTFChars(jstr, nativeStr);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return result;');
    } else if (isEnum) {
      // Bridge returns Long (nativeValue)
      writer.line(
        '    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    } else if (isStruct) {
      // Bridge returns the Kotlin data class; pack it to C struct via malloc.
      // Strip '?' from the type name — nullable structs use null pointer for null.
      final stName = func.returnType.name.replaceFirst('?', '');
      writer.line(
        '    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jobj == nullptr) {');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    $stName* result = ($stName*)malloc(sizeof($stName));');
      writer.line('    *result = pack_${stName}_from_jni(env, jobj);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return result;');
    } else if (isMap) {
      // Map<String, T>: bridge returns ByteArray (binary-encoded map).
      // Same path as @HybridRecord — copy bytes to malloc'd buffer and return uint8_t*.
      writer.line('    jbyteArray jmap = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jmap == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    jsize jmap_len = env->GetArrayLength(jmap);');
      writer.line('    uint8_t* jmap_buf = (uint8_t*)malloc((size_t)jmap_len);');
      writer.line('    env->GetByteArrayRegion(jmap, 0, jmap_len, (jbyte*)jmap_buf);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return jmap_buf;');
    } else if (isRecord) {
      // Bridge returns ByteArray (serialized @HybridRecord / List<@HybridRecord>)
      // Copy bytes to malloc'd buffer and return as void* for Dart RecordReader
      writer.line('    jbyteArray jarr = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr == nullptr) {');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    jsize len = env->GetArrayLength(jarr);');
      writer.line('    uint8_t* result = (uint8_t*)malloc(len);');
      writer.line('    env->GetByteArrayRegion(jarr, 0, len, (jbyte*)result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return result;');
    } else if (isTypedData) {
      if (func.zeroCopyReturn) {
        writer.line('    jobject jbuf = env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
        writer.line('    if (env->ExceptionCheck()) {');
        writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
        writer.line('        env->PopLocalFrame(nullptr);');
        writer.line('        return nullptr;');
        writer.line('    }');
        writer.line('    if (jbuf == nullptr) {');
        writer.line('        env->PopLocalFrame(nullptr);');
        writer.line('        return nullptr;');
        writer.line('    }');
        writer.line('    void* data = env->GetDirectBufferAddress(jbuf);');
        writer.line('    jlong byteLen = env->GetDirectBufferCapacity(jbuf);');
        writer.line('    if (byteLen < 0 || (byteLen > 0 && data == nullptr)) {');
        writer.line('        nitro_report_error("ArgumentError", "${func.dartName}: @zeroCopy return must be a direct ByteBuffer", nullptr, nullptr);');
        writer.line('        env->PopLocalFrame(nullptr);');
        writer.line('        return nullptr;');
        writer.line('    }');
        writer.line('    jobject owner = env->NewGlobalRef(jbuf);');
        writer.line('    if (owner == nullptr) {');
        writer.line('        nitro_report_error("OutOfMemoryError", "${func.dartName}: failed to retain zero-copy return buffer", nullptr, nullptr);');
        writer.line('        env->PopLocalFrame(nullptr);');
        writer.line('        return nullptr;');
        writer.line('    }');
        writer.line('    int64_t* result = (int64_t*)malloc(sizeof(int64_t) * 3);');
        writer.line('    if (result == nullptr) {');
        writer.line('        env->DeleteGlobalRef(owner);');
        writer.line('        nitro_report_error("OutOfMemoryError", "${func.dartName}: failed to allocate zero-copy return envelope", nullptr, nullptr);');
        writer.line('        env->PopLocalFrame(nullptr);');
        writer.line('        return nullptr;');
        writer.line('    }');
        writer.line('    result[0] = (int64_t)byteLen;');
        writer.line('    result[1] = (int64_t)(intptr_t)(data != nullptr ? data : result);');
        writer.line('    result[2] = (int64_t)(intptr_t)owner;');
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return (uint8_t*)result;');
      } else {
        final ops = _typedDataJniOps(func.returnType.name);
        final elemSize = _typedDataElementSizeExpr(func.returnType.name);
        writer.line('    ${ops[0]} jarr = (${ops[0]})env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
        writer.line('    if (env->ExceptionCheck()) {');
        writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
        writer.line('        env->PopLocalFrame(nullptr);');
        writer.line('        return nullptr;');
        writer.line('    }');
        writer.line('    if (jarr == nullptr) {');
        writer.line('        env->PopLocalFrame(nullptr);');
        writer.line('        return nullptr;');
        writer.line('    }');
        writer.line('    jsize len = env->GetArrayLength(jarr);');
        writer.line('    size_t byteLen = (size_t)len * $elemSize;');
        writer.line('    uint8_t* result = (uint8_t*)malloc(byteLen + sizeof(int64_t));');
        writer.line('    *((int64_t*)result) = (int64_t)byteLen;');
        writer.line('    env->${ops[4]}(jarr, 0, len, (${ops[3]}*)(result + sizeof(int64_t)));');
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return result;');
      }
    } else {
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return ${_defaultValue(cReturnType)};');
    }
    if (func.returnType.name == 'void') {
      writer.line('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err); }');
    }
    writer.line('}');
    writer.blankLine();
  }

  // ── Properties ────────────────────────────────────────────────────────────
  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(prop.type.name);
    final isNullablePrimProp = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?';
    final cType = isNullablePrimProp ? 'uint8_t*' : (isEnum ? 'int64_t' : _typeToC(prop.type.name));

    if (prop.hasGetter) {
      // S8: property getter receives NitroError* out-param.
      writer.line('$cType ${prop.getSymbol}(NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    JNIEnv* env = GetEnv();');
      writer.line('    if (env == nullptr) { return ${_defaultValue(cType)}; }');
      writer.line('    jmethodID methodId = g_mid_${prop.getSymbol}_call;');
      // Nullable primitive properties now use NitroNullable ByteArray transport → ()[B.
      final propGetBase = prop.type.name.replaceFirst('?', '');
      final propGetNullable = prop.type.name.endsWith('?');
      final isNullablePrimGet = propGetNullable && (propGetBase == 'int' || propGetBase == 'double' || propGetBase == 'bool');
      final jniGetSig = '()${isEnum ? 'J' : (isNullablePrimGet ? '[B' : _jniSigType(prop.type.name))}';
      writer.line(
        '    if (methodId == nullptr) { LOGE("Method not found: ${prop.getSymbol}_call sig=$jniGetSig"); return ${_defaultValue(cType)}; }',
      );
      writer.line('    if (env->PushLocalFrame(8) != 0) { return ${_defaultValue(cType)}; }');
      final propBase = prop.type.name.replaceFirst('?', '');
      if (propBase == 'double' && !prop.type.name.endsWith('?')) {
        // Non-nullable double: JNI double.
        writer.line(
          '    double res = env->CallStaticDoubleMethod(g_bridgeClass, methodId);',
        );
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return res;');
      } else if (propBase == 'double' && prop.type.name.endsWith('?')) {
        // Nullable double?: NitroNullableDouble ByteArray.
        writer.line('    jbyteArray jarr_nd = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId);');
        writer.line('    if (jarr_nd == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
        writer.line('    jsize nd_len = env->GetArrayLength(jarr_nd);');
        writer.line('    uint8_t* nd_res = (uint8_t*)malloc(nd_len);');
        writer.line('    env->GetByteArrayRegion(jarr_nd, 0, nd_len, (jbyte*)nd_res);');
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return nd_res;');
      } else if ((propBase == 'int' && !prop.type.name.endsWith('?')) || isEnum) {
        // Non-nullable int / enum return a JNI long.
        writer.line(
          '    $cType res = ($cType)env->CallStaticLongMethod(g_bridgeClass, methodId);',
        );
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return res;');
      } else if (prop.type.name == 'int?') {
        // Nullable int?: NitroNullableInt ByteArray.
        writer.line('    jbyteArray jarr_ni = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId);');
        writer.line('    if (jarr_ni == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
        writer.line('    jsize ni_len = env->GetArrayLength(jarr_ni);');
        writer.line('    uint8_t* ni_res = (uint8_t*)malloc(ni_len);');
        writer.line('    env->GetByteArrayRegion(jarr_ni, 0, ni_len, (jbyte*)ni_res);');
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return ni_res;');
      } else if (propBase == 'bool' && !prop.type.name.endsWith('?')) {
        // Non-nullable bool: use CallStaticBooleanMethod (()Z).
        writer.line(
          '    bool res = env->CallStaticBooleanMethod(g_bridgeClass, methodId);',
        );
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return res;');
      } else if (propBase == 'bool' && prop.type.name.endsWith('?')) {
        // Nullable bool?: NitroNullableBool ByteArray.
        writer.line('    jbyteArray jarr_nb = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId);');
        writer.line('    if (jarr_nb == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
        writer.line('    jsize nb_len = env->GetArrayLength(jarr_nb);');
        writer.line('    uint8_t* nb_res = (uint8_t*)malloc(nb_len);');
        writer.line('    env->GetByteArrayRegion(jarr_nb, 0, nb_len, (jbyte*)nb_res);');
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return nb_res;');
      } else if (propBase == 'String') {
        writer.line(
          '    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId);',
        );
        writer.line('    if (jstr == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
        writer.line(
          '    const char* nativeStr = env->GetStringUTFChars(jstr, 0);',
        );
        writer.line('    char* result = strdup(nativeStr);');
        writer.line('    env->ReleaseStringUTFChars(jstr, nativeStr);');
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return result;');
      } else {
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return ${_defaultValue(cType)};');
      }
      writer.line('}');
      writer.blankLine();
    }

    if (prop.hasSetter) {
      final paramCType = isNullablePrimProp ? 'void*' : (isEnum ? 'int64_t' : _typeToC(prop.type.name));
      // S8: property setter receives NitroError* out-param.
      writer.line('void ${prop.setSymbol}($paramCType value, NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    JNIEnv* env = GetEnv();');
      writer.line('    if (env == nullptr) { return; }');

      writer.line('    jmethodID methodId = g_mid_${prop.setSymbol}_call;');
      // bool? property setter uses Int (I) for 3-state encoding; bool uses Boolean (Z).
      final propSetBase2 = prop.type.name.replaceFirst('?', '');
      final propSetNullable2 = prop.type.name.endsWith('?');
      final jniSetSig = '(${isNullablePrimProp ? '[B' : (isEnum ? 'J' : _jniSigType(prop.type.name))})V';
      writer.line(
        '    if (methodId == nullptr) { LOGE("Method not found: ${prop.setSymbol}_call sig=$jniSetSig"); return; }',
      );
      writer.line('    if (env->PushLocalFrame(8) != 0) { return; }');

      final propSetBase = prop.type.name.replaceFirst('?', '');
      if (prop.type.name == 'String') {
        writer.line('    jstring jval = env->NewStringUTF(value);');
        writer.line(
          '    env->CallStaticVoidMethod(g_bridgeClass, methodId, jval);',
        );
      } else if (structNames.contains(prop.type.name)) {
        writer.line('    jobject jval = unpack_${prop.type.name}_to_jni(env, (const ${prop.type.name}*)value);');
        writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, jval);');
      } else if (propSetBase == 'bool' && !prop.type.name.endsWith('?')) {
        // Non-nullable bool: cast to jboolean for (Z)V param.
        writer.line(
          '    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jboolean)(value != 0));',
        );
      } else if (prop.type.name == 'bool?' || prop.type.name == 'int?' || prop.type.name == 'double?') {
        // Nullable primitives: NitroNullable ByteArray — pass as jbyteArray.
        writer.line('    int32_t ${prop.dartName}_payload_len = *((const int32_t*)value);');
        writer.line('    int32_t ${prop.dartName}_total = ${prop.dartName}_payload_len + 4;');
        writer.line('    jbyteArray j_${prop.dartName} = env->NewByteArray((jsize)${prop.dartName}_total);');
        writer.line('    env->SetByteArrayRegion(j_${prop.dartName}, 0, (jsize)${prop.dartName}_total, (const jbyte*)value);');
        writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, j_${prop.dartName});');
      } else {
        writer.line(
          '    env->CallStaticVoidMethod(g_bridgeClass, methodId, value);',
        );
      }
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('}');
      writer.blankLine();
    }
  }

  // ── Streams ───────────────────────────────────────────────────────────────
  for (final stream in spec.streams) {
    final isStruct = structNames.contains(stream.itemType.name);
    // JNI name: "nitro" + "_" + "{lib}_module" (with internal _ → _1)
    // e.g. nitro.my_camera_module → nitro_my_1camera_1module (NOT nitro_1my_1camera_1module)

    writer.line('void ${stream.registerSymbol}(int64_t dart_port) {');
    writer.line('    JNIEnv* env = GetEnv();');
    writer.line('    if (env == nullptr) { return; }');

    writer.line('    jmethodID methodId = g_mid_${stream.registerSymbol}_call;');
    writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${stream.registerSymbol}_call sig=(J)V"); return; }');
    writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);');
    writer.line('}');
    writer.blankLine();
    writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
    writer.line('    JNIEnv* env = GetEnv();');
    writer.line('    if (env == nullptr) { return; }');

    writer.line('    jmethodID methodId = g_mid_${stream.releaseSymbol}_call;');
    writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${stream.releaseSymbol}_call sig=(J)V"); return; }');
    writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);');
    writer.line('}');
    writer.blankLine();

    // For batch streams, emit an array of raw int64 values (count + items).
    if (stream.isBatch) {
      final jniBatchEmit = _jniMethodName(spec.lib, spec.dartClassName, 'emit_${stream.dartName}_batch');
      writer.line('JNIEXPORT jboolean JNICALL $jniBatchEmit(JNIEnv* env, jobject thiz, jlong dartPort, jlongArray batch) {');
      writer.line('    jsize n = env->GetArrayLength(batch);');
      writer.line('    jlong* elems = env->GetLongArrayElements(batch, nullptr);');
      writer.line('    Dart_CObject obj;');
      writer.line('    obj.type = Dart_CObject_kTypedData;');
      writer.line('    obj.value.as_typed_data.type = Dart_TypedData_kInt64;');
      writer.line('    obj.value.as_typed_data.length = (intptr_t)n;');
      writer.line('    obj.value.as_typed_data.values = (uint8_t*)elems;');
      writer.line('    bool ok = Dart_PostCObject_DL(dartPort, &obj);');
      writer.line('    env->ReleaseLongArrayElements(batch, elems, JNI_ABORT);');
      writer.line('    return ok ? JNI_TRUE : JNI_FALSE;');
      writer.line('}');
      writer.blankLine();
      continue; // Skip the normal single-item emit for batch streams
    }
    final jniEmit = _jniMethodName(
      spec.lib,
      spec.dartClassName,
      'emit_${stream.dartName}',
    );
    writer.line(
      'JNIEXPORT jboolean JNICALL $jniEmit(JNIEnv* env, jobject thiz, jlong dartPort, ${_jniSigTypeC(stream.itemType.name)} item) {',
    );
    writer.line('    Dart_CObject obj;');
    if (stream.itemType.name == 'double') {
      writer.line('    obj.type = Dart_CObject_kDouble;');
      writer.line('    obj.value.as_double = item;');
    } else if (stream.itemType.name == 'int') {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = item;');
    } else if (stream.itemType.name == 'bool') {
      // Use kInt64 (0/1) instead of kBool: Dart_PostCObject_DL with kBool
      // is unreliable on some Android versions and returns false.
      // The Dart stream unpack decodes int != 0 as true.
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = item ? 1 : 0;');
    } else if (isStruct) {
      final stName = stream.itemType.name.replaceFirst('?', '');
      writer.line(
        '    $stName* st_ptr = ($stName*)malloc(sizeof($stName));',
      );
      writer.line(
        '    *st_ptr = pack_${stream.itemType.name}_from_jni(env, item);',
      );
      writer.line('    // Check if pack_ threw an exception (e.g., heap ByteBuffer for @ZeroCopy)');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        env->ExceptionDescribe();');
      writer.line('        env->ExceptionClear();');
      writer.line('        free(st_ptr);');
      writer.line('        return JNI_FALSE;');
      writer.line('    }');
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (intptr_t)st_ptr;');
      final structDef = spec.structs.firstWhere((st3) => st3.name == stName, orElse: () => spec.structs.first);
      final hasZeroCopy = structDef.fields.any((f) => f.zeroCopy);
      if (hasZeroCopy) {
        writer.line('    // Keep item alive so JVM does not GC the ByteBuffer backing st_ptr\'s zero-copy fields.');
        writer.line('    {');
        writer.line('        std::lock_guard<std::mutex> _lk(g_zero_copy_refs_mtx);');
        writer.line('        g_zero_copy_refs[(void*)st_ptr] = env->NewGlobalRef(item);');
        writer.line('    }');
      }
    } else if (stream.itemType.isRecord) {
      // Serialize the Kotlin @HybridRecord to bytes via encode(), copy to a
      // malloc'd native buffer, and send the pointer as kInt64.
      // Dart reads it via RecordReader.fromNative and frees with malloc.free.
      final recName = stream.itemType.name.replaceFirst('?', '');
      writer.line('    if (g_cls_$recName == nullptr || g_mid_${recName}_encode == nullptr) {');
      writer.line('        LOGE("$recName encode method not cached — skipping emit");');
      writer.line('        return JNI_FALSE;');
      writer.line('    }');
      writer.line('    jbyteArray encoded = (jbyteArray)env->CallObjectMethod(item, g_mid_${recName}_encode);');
      writer.line('    if (encoded == nullptr) { LOGE("$recName.encode() returned null"); return JNI_FALSE; }');
      writer.line('    jsize len = env->GetArrayLength(encoded);');
      writer.line('    uint8_t* buf = (uint8_t*)malloc((size_t)len);');
      writer.line('    env->GetByteArrayRegion(encoded, 0, len, (jbyte*)buf);');
      writer.line('    env->DeleteLocalRef(encoded);');
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (intptr_t)buf;');
    } else if (stream.itemType.name == 'String') {
      // String stream: post kString. Dart_PostCObject_DL copies the string internally,
      // so we can release the JNI reference immediately after. Post inline and return early
      // to avoid the cleanup block that follows (which has no work to do for String).
      writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
      writer.line('    else {');
      writer.line('        const char* _cStr = env->GetStringUTFChars(item, nullptr);');
      writer.line('        if (_cStr == nullptr) return JNI_FALSE;');
      writer.line('        obj.type = Dart_CObject_kString;');
      writer.line('        obj.value.as_string = const_cast<char*>(_cStr);');
      writer.line('        bool _ok = Dart_PostCObject_DL(dartPort, &obj);');
      writer.line('        env->ReleaseStringUTFChars(item, _cStr);');
      writer.line('        return _ok ? JNI_TRUE : JNI_FALSE;');
      writer.line('    }');
    } else if (enumNames.contains(stream.itemType.name.replaceFirst('?', ''))) {
      writer.line('    // item is a jobject (Kotlin enum). Extract its nativeValue Long field.');
      writer.line('    jclass enumCls = env->GetObjectClass(item);');
      writer.line('    jfieldID fid = enumCls ? env->GetFieldID(enumCls, "nativeValue", "J") : nullptr;');
      writer.line('    if (fid == nullptr) { LOGE("emit_${stream.dartName}: cannot find nativeValue on ${stream.itemType.name}"); if (enumCls) env->DeleteLocalRef(enumCls); return JNI_FALSE; }');
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (int64_t)env->GetLongField(item, fid);');
      writer.line('    env->DeleteLocalRef(enumCls);');
    } else {
      writer.line('    obj.type = Dart_CObject_kNull;');
    }
    writer.line('    if (!Dart_PostCObject_DL(dartPort, &obj)) {');
    if (isStruct) {
      final stName = stream.itemType.name.replaceFirst('?', '');
      final structDef = spec.structs.firstWhere((st3) => st3.name == stName, orElse: () => spec.structs.first);
      final hasZeroCopy = structDef.fields.any((f) => f.zeroCopy);
      if (hasZeroCopy) {
        writer.line('        {');
        writer.line('            std::lock_guard<std::mutex> _lk(g_zero_copy_refs_mtx);');
        writer.line('            auto _it = g_zero_copy_refs.find((void*)st_ptr);');
        writer.line('            if (_it != g_zero_copy_refs.end()) {');
        writer.line('                env->DeleteGlobalRef(_it->second);');
        writer.line('                g_zero_copy_refs.erase(_it);');
        writer.line('            }');
        writer.line('        }');
      }
      writer.line('        free(st_ptr);');
    } else if (stream.itemType.isRecord) {
      writer.line('        free(buf);');
    }
    writer.line('        return JNI_FALSE;');
    writer.line('    }');
    writer.line('    return JNI_TRUE;');
    writer.line('}');
    writer.blankLine();
  }

  // ── Native callback invoker methods ────────────────────────────────────────
  // These are called from Kotlin to invoke C function pointers (callbacks).
  // For each function-typed parameter across all bridge functions, emit a JNI
  // native method that casts the callbackPtr to the correct C function pointer
  // type and invokes it.
  final callbackNativeImpls = <String>{};
  for (final func in spec.functions) {
    for (final p in func.params) {
      if (!p.type.isFunction) continue;
      final nativeName = '_invoke_${p.name}';
      if (!callbackNativeImpls.add(nativeName)) continue;

      final cbParams = p.type.functionParams;

      // Build JNI method name
      final jniMethName = _jniMethodName(spec.lib, spec.dartClassName, nativeName);

      // Map each callback param to its JNI C type and C typedef type.
      // Using type-specific JNI params ensures correct register allocation on ARM64
      // (floating-point values must flow through FP registers, not integer registers).

      String jniCParam(BridgeType t) {
        final base = t.name.replaceFirst('?', '');
        // bool and double are encoded as jlong (see _callbackParamToKotlinJni).
        // Using jlong ensures NativeCallable.listener fires synchronously on Android
        // (only the Int64/Long fast-path is guaranteed synchronous on the Dart isolate thread).
        if (base == 'double') return 'jlong'; // raw IEEE 754 bits via doubleToRawLongBits
        if (base == 'bool') return 'jlong';   // 1L = true, 0L = false
        if (base == 'String') return 'jstring';
        if (structNames.contains(base)) return 'jobject';    // Kotlin data class
        if (recordNames.contains(base)) return 'jbyteArray'; // serialized ByteArray
        return 'jlong'; // int, enum → jlong
      }

      String cTypedefParam(BridgeType t) {
        final base = t.name.replaceFirst('?', '');
        // bool and double are received as jlong (int64_t) and must use int64_t in the
        // C typedef so the call-site ABI exactly matches NativeCallable<Void Function(Int64)>.
        if (base == 'double') return 'int64_t';
        if (base == 'bool') return 'int64_t';
        if (base == 'String') return 'const char*';
        if (structNames.contains(base)) return 'const $base*';
        if (recordNames.contains(base)) return 'const uint8_t*'; // length-prefixed buffer
        return 'int64_t'; // int, enum → int64_t
      }

      // Build C parameter list with proper JNI types.
      // For expandable structs (all-numeric fields), expand each field as a separate jlong
      // so NativeCallable.listener fires synchronously on Android.
      final cParams = StringBuffer('JNIEnv* env, jobject thiz, jlong callbackPtr');
      for (var i = 0; i < cbParams.length; i++) {
        final base = cbParams[i].name.replaceFirst('?', '');
        final struct = spec.structs.where((s) => s.name == base).firstOrNull;
        if (struct != null && _isExpandableStruct(struct)) {
          for (final f in struct.fields) {
            cParams.write(', jlong arg${i}_${f.name}');
          }
        } else {
          cParams.write(', ${jniCParam(cbParams[i])} arg$i');
        }
      }

      // Build C typedef params — expanded struct fields use int64_t each.
      final typedefParts = <String>[];
      for (var i = 0; i < cbParams.length; i++) {
        final base = cbParams[i].name.replaceFirst('?', '');
        final struct = spec.structs.where((s) => s.name == base).firstOrNull;
        if (struct != null && _isExpandableStruct(struct)) {
          typedefParts.addAll(struct.fields.map((_) => 'int64_t'));
        } else {
          typedefParts.add(cTypedefParam(cbParams[i]));
        }
      }
      final typedefParams = typedefParts.join(', ');
      final needsStringConversion = cbParams.any((t) => t.name.replaceFirst('?', '') == 'String');

      // Bidirectional callbacks: map Dart return type to JNI/C types.
      final cbReturnTypeDart = p.type.functionReturnType;
      final isVoidReturn = cbReturnTypeDart == null || cbReturnTypeDart == 'void';
      final isStringReturn = cbReturnTypeDart == 'String';
      final cRetType = isVoidReturn ? 'void' : (isStringReturn ? 'jstring' : 'jlong');
      // C typedef: String → const char*, double/bool/int → int64_t
      final cTypedefReturn = isVoidReturn ? 'void' : (isStringReturn ? 'const char*' : 'int64_t');

      writer.line('JNIEXPORT $cRetType JNICALL $jniMethName($cParams) {');
      writer.line('    typedef $cTypedefReturn (*CB)(${typedefParams.isEmpty ? 'void' : typedefParams});');
      // Convert jstring → const char* (release after call).
      // Unpack Kotlin data classes → C struct (stack-allocated).
      // Copy ByteArray record bytes → malloc'd length-prefixed buffer (Dart frees).
      for (var i = 0; i < cbParams.length; i++) {
        final base = cbParams[i].name.replaceFirst('?', '');
        final struct = spec.structs.where((s) => s.name == base).firstOrNull;
        if (struct != null && _isExpandableStruct(struct)) {
          // Expanded struct: individual jlong values passed directly to Dart NativeCallable.
          // No reconstruction needed — Dart reconstructs via bitPattern on the Dart side.
        } else if (base == 'String') {
          writer.line('    const char* s_arg$i = arg$i ? env->GetStringUTFChars(arg$i, nullptr) : nullptr;');
        } else if (structNames.contains(base)) {
          writer.line('    $base c_arg$i = pack_${base}_from_jni(env, arg$i);');
        } else if (recordNames.contains(base)) {
          writer.line('    jsize r_len$i = env->GetArrayLength(arg$i);');
          writer.line('    uint8_t* r_buf$i = (uint8_t*)malloc((size_t)r_len$i);');
          writer.line('    env->GetByteArrayRegion(arg$i, 0, r_len$i, (jbyte*)r_buf$i);');
        }
      }
      final callParts = <String>[];
      for (var i = 0; i < cbParams.length; i++) {
        final base = cbParams[i].name.replaceFirst('?', '');
        final struct = spec.structs.where((s) => s.name == base).firstOrNull;
        if (struct != null && _isExpandableStruct(struct)) {
          // Pass each field's raw int64_t value directly — Dart receives Int64 and reconstructs.
          callParts.addAll(struct.fields.map((f) => '(int64_t)arg${i}_${f.name}'));
        } else if (base == 'String') {
          callParts.add('s_arg$i');
        } else if (base == 'double') {
          callParts.add('(int64_t)arg$i');
        } else if (base == 'bool') {
          callParts.add('(int64_t)arg$i');
        } else if (structNames.contains(base)) {
          callParts.add('&c_arg$i');
        } else if (recordNames.contains(base)) {
          callParts.add('r_buf$i');
        } else {
          callParts.add('(int64_t)arg$i');
        }
      }
      final callArgs = callParts.join(', ');
      if (isVoidReturn) {
        writer.line('    ((CB)callbackPtr)(${callArgs.isEmpty ? '' : callArgs});');
      } else {
        writer.line('    $cTypedefReturn _ret = ((CB)callbackPtr)(${callArgs.isEmpty ? '' : callArgs});');
      }
      if (needsStringConversion) {
        for (var i = 0; i < cbParams.length; i++) {
          if (cbParams[i].name.replaceFirst('?', '') == 'String') {
            writer.line('    if (s_arg$i) { env->ReleaseStringUTFChars(arg$i, s_arg$i); }');
          }
        }
      }
      if (!isVoidReturn) {
        if (isStringReturn) {
          // String return: wrap const char* in a JNI String, free the C string.
          writer.line('    jstring _jret = _ret ? env->NewStringUTF(_ret) : nullptr;');
          writer.line('    if (_ret) { free((void*)_ret); }');
          writer.line('    return _jret;');
        } else {
          writer.line('    return (jlong)_ret;');
        }
      }
      writer.line('}');
      writer.blankLine();
    }
  }

  final jniInit = _jniMethodName(spec.lib, spec.dartClassName, 'initialize');
  writer.line(
    'JNIEXPORT void JNICALL $jniInit(JNIEnv* env, jobject thiz, jclass localClass) {',
  );
  writer.line('    if (g_bridgeClass == nullptr) {');
  writer.line(
    '        g_bridgeClass = (jclass)env->NewGlobalRef(localClass);',
  );
  writer.line('        env->DeleteLocalRef(localClass);');
  writer.line('    }');
  writer.line(
    '    // Re-cache method IDs every time (safe; idempotent; works even if JNI_OnLoad',
  );
  writer.line(
    '    // could not find the app class. initialize() is called from Kotlin with the',
  );
  writer.line(
    '    // correct class loader.)',
  );
  writer.line('    if (g_bridgeClass != nullptr) {');
  writer.line('        // Cache bridge method IDs');
  writer.line('        // Each GetStaticMethodID is followed by an ExceptionClear() guard:');
  writer.line('        // if ANY lookup fails it throws NoSuchMethodError, and calling the');
  writer.line('        // NEXT GetStaticMethodID with a pending exception aborts the JVM on');
  writer.line('        // Android >= API 26 (strict JNI mode). Clearing after each failure');
  writer.line('        // lets the remaining lookups proceed and logs the missing method.');
  for (final func in spec.functions) {
    final String jniSig;
    if (func.isNativeAsync) {
      jniSig = _jniNativeAsyncSig(func.params, enumNames, structNames, libPkg);
    } else {
      jniSig = _jniSig(func.params, func.returnType, enumNames, structNames, libPkg, zeroCopyReturn: func.zeroCopyReturn);
    }
    writer.line('        g_mid_${func.dartName}_call = env->GetStaticMethodID(g_bridgeClass, "${func.dartName}_call", "$jniSig");');
    writer.line('        if (!g_mid_${func.dartName}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${func.dartName}_call sig=$jniSig"); }');
  }
  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(prop.type.name);
    if (prop.hasGetter) {
      final propInitBase = prop.type.name.replaceFirst('?', '');
      final propInitNullable = prop.type.name.endsWith('?');
      final isNullablePrimPropInit = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?';
      // Nullable primitives use [B (ByteArray) encoding.
      final jniRetSig = isNullablePrimPropInit ? '[B' : (isEnum ? 'J' : _jniSigType(prop.type.name));
      writer.line('        g_mid_${prop.getSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${prop.getSymbol}_call", "()$jniRetSig");');
      writer.line('        if (!g_mid_${prop.getSymbol}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${prop.getSymbol}_call sig=()$jniRetSig"); }');
    }
    if (prop.hasSetter) {
      final propInitBase2 = prop.type.name.replaceFirst('?', '');
      final propInitNullable2 = prop.type.name.endsWith('?');
      final isNullablePrimPropInit2 = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?';
      // Nullable primitives use [B (ByteArray) encoding.
      final jniParamSig = isNullablePrimPropInit2 ? '[B' : (isEnum ? 'J' : _jniSigType(prop.type.name));
      writer.line('        g_mid_${prop.setSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${prop.setSymbol}_call", "($jniParamSig)V");');
      writer.line('        if (!g_mid_${prop.setSymbol}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${prop.setSymbol}_call sig=($jniParamSig)V"); }');
    }
  }
  for (final stream in spec.streams) {
    writer.line('        g_mid_${stream.registerSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${stream.registerSymbol}_call", "(J)V");');
    writer.line('        if (!g_mid_${stream.registerSymbol}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${stream.registerSymbol}_call sig=(J)V"); }');
    writer.line('        g_mid_${stream.releaseSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${stream.releaseSymbol}_call", "(J)V");');
    writer.line('        if (!g_mid_${stream.releaseSymbol}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${stream.releaseSymbol}_call sig=(J)V"); }');
  }
  writer.line('    }');
  writer.blankLine();

  // Cache record class + encode() method IDs for record-typed stream items
  final cachedRecordClasses = <String>{};
  for (final stream in spec.streams) {
    if (stream.itemType.isRecord) {
      final recName = stream.itemType.name.replaceFirst('?', '');
      if (cachedRecordClasses.add(recName)) {
        final jniRecClass = 'nitro/${spec.lib.replaceAll('-', '_')}_module/$recName';
        writer.line('    // Cache $recName class + encode() for stream serialisation');
        writer.line('    {');
        writer.line('        jclass local_cls_$recName = env->FindClass("$jniRecClass");');
        writer.line('        if (local_cls_$recName != nullptr) {');
        writer.line('            g_cls_$recName = (jclass)env->NewGlobalRef(local_cls_$recName);');
        writer.line('            env->DeleteLocalRef(local_cls_$recName);');
        writer.line('            g_mid_${recName}_encode = env->GetMethodID(g_cls_$recName, "encode", "()[B");');
        writer.line('        } else {');
        writer.line('            LOGE("Failed to find class $jniRecClass");');
        writer.line('        }');
        writer.line('    }');
      }
    }
  }
  if (spec.structs.isNotEmpty) {
    writer.line('    // Cache struct class + ctor + field IDs');
    for (final st in spec.structs) {
      final jniClass = 'nitro/${spec.lib.replaceAll('-', '_')}_module/${st.name}';

      final ctorSig =
          '(${st.fields.map((f) {
            final isEnum = enumNames.contains(f.type.name.replaceFirst('?', ''));
            final isNestedStruct = structNames.contains(f.type.name.replaceFirst('?', ''));
            if (isEnum) return 'J';
            if (_isZeroCopy(st, f.name)) return 'Ljava/nio/ByteBuffer;';
            if (isNestedStruct) return 'L$libPkg/${f.type.name.replaceFirst('?', '')};';
            return _jniSigType(f.type.name);
          }).join('')})V';
      writer.line('    {');
      writer.line('        jclass local_cls_${st.name} = env->FindClass("$jniClass");');
      writer.line('        if (local_cls_${st.name} != nullptr) {');
      writer.line('            g_cls_${st.name} = (jclass)env->NewGlobalRef(local_cls_${st.name});');
      writer.line('            env->DeleteLocalRef(local_cls_${st.name});');
      writer.line('            g_ctor_${st.name} = env->GetMethodID(g_cls_${st.name}, "<init>", "$ctorSig");');
      for (final f in st.fields) {
        final isEnum = enumNames.contains(f.type.name.replaceFirst('?', ''));
        final isZeroCopy = _isZeroCopy(st, f.name);
        final isNestedStruct = structNames.contains(f.type.name.replaceFirst('?', ''));
        final sig = isEnum ? 'J' : (isZeroCopy ? 'Ljava/nio/ByteBuffer;' : (isNestedStruct ? 'L$libPkg/${f.type.name.replaceFirst('?', '')};' : _jniSigType(f.type.name)));
        writer.line('            g_fid_${st.name}_${f.name} = env->GetFieldID(g_cls_${st.name}, "${f.name}", "$sig");');
      }
      writer.line('        }');
      writer.line('    }');
    }
  }
  writer.line('}');
  writer.blankLine();

  // ── postXxxToPort helpers (used by @nitroNativeAsync Kotlin bridge) ──────
  final hasNativeAsync = spec.functions.any((f) => f.isNativeAsync);
  if (hasNativeAsync) {
    final jniPostNull = _jniMethodName(spec.lib, spec.dartClassName, 'postNullToPort');
    final jniPostInt64 = _jniMethodName(spec.lib, spec.dartClassName, 'postInt64ToPort');
    final jniPostDouble = _jniMethodName(spec.lib, spec.dartClassName, 'postDoubleToPort');
    final jniPostBool = _jniMethodName(spec.lib, spec.dartClassName, 'postBoolToPort');
    final jniPostString = _jniMethodName(spec.lib, spec.dartClassName, 'postStringToPort');

    writer.line('// ── postXxxToPort helpers for @nitroNativeAsync ──');
    // postNullToPort
    _emitDartPostCObjectHelper(
      writer,
      symbol: jniPostNull,
      envParamDecl: 'JNIEnv*',
      valueParamDecl: '',
      cObjectType: 'Dart_CObject_kNull',
    );
    // postInt64ToPort
    _emitDartPostCObjectHelper(
      writer,
      symbol: jniPostInt64,
      envParamDecl: 'JNIEnv*',
      valueParamDecl: ', jlong value',
      cObjectType: 'Dart_CObject_kInt64',
      valueAssignment: 'obj.value.as_int64 = (int64_t)value;',
    );
    // postDoubleToPort
    _emitDartPostCObjectHelper(
      writer,
      symbol: jniPostDouble,
      envParamDecl: 'JNIEnv*',
      valueParamDecl: ', jdouble value',
      cObjectType: 'Dart_CObject_kDouble',
      valueAssignment: 'obj.value.as_double = (double)value;',
    );
    // postBoolToPort
    _emitDartPostCObjectHelper(
      writer,
      symbol: jniPostBool,
      envParamDecl: 'JNIEnv*',
      valueParamDecl: ', jboolean value',
      cObjectType: 'Dart_CObject_kBool',
      valueAssignment: 'obj.value.as_bool = (bool)value;',
    );
    // postStringToPort
    _emitDartPostCObjectHelper(
      writer,
      symbol: jniPostString,
      envParamDecl: 'JNIEnv* env',
      valueParamDecl: ', jstring value',
      cObjectType: 'Dart_CObject_kString',
      beforePost: 'const char* cStr = env->GetStringUTFChars(value, nullptr);',
      valueAssignment: 'obj.value.as_string = const_cast<char*>(cStr);',
      afterPost: 'env->ReleaseStringUTFChars(value, cStr);',
    );
  }

  writer.line('} // extern "C"');
}
