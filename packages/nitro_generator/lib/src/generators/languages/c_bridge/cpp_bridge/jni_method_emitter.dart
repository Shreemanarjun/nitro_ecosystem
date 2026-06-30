part of '../cpp_bridge_generator.dart';

/// Returns true when all struct fields are numeric (int/double/bool) — can be
/// expanded to individual jlong params for synchronous NativeCallable.listener.
bool _isExpandableStruct(BridgeStruct st) {
  const numeric = {'int', 'double', 'bool'};
  return st.fields.isNotEmpty && st.fields.every((f) => numeric.contains(f.type.name.replaceFirst('?', '')) && !f.type.isTypedData);
}

String _paramTypeToC(String dartType, Set<String> structNames) => CppBridgeGenerator._paramTypeToC(dartType, structNames);

String _jniCallbackParamToC(BridgeParam param, Set<String> enumNames, {Set<String>? structNames, Set<String>? recordNames}) =>
    CppBridgeGenerator._callbackParamToC(param, enumNames, structNames: structNames, recordNames: recordNames);

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
  bool isResult = false,
  Set<String> variantNames = const {},
  Set<String> customTypeNames = const {},
}) => CppBridgeGenerator._jniSig(params, returnType, enumNames, structNames, libPkg, zeroCopyReturn: zeroCopyReturn, isResult: isResult, variantNames: variantNames, customTypeNames: customTypeNames);

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

/// Emits the C bridge function body for a `@nitroNativeAsync` method.
void _emitJniNativeAsyncFuncBody(
  CodeWriter writer,
  BridgeFunction func,
  BridgeSpec spec,
  String libStem,
  String libPkg,
  Set<String> enumNames,
  Set<String> structNames,
  Set<String> recordNames,
) {
  // instanceId is the first C param for per-instance dispatch (Point 13).
  final paramsDeclParts = <String>['int64_t instanceId'];
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

  // instanceId is always the first JNI call arg (Point 13).
  final callArgsList = <String>['(jlong)instanceId'];
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
  writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), nullptr);');
  writer.line('    }');
  writer.line('    env->PopLocalFrame(nullptr);');
  writer.line('}');
  writer.blankLine();
}

/// Emits the C bridge function body for a regular sync or `@nitroAsync` method.
void _emitJniRegularFuncBody(
  CodeWriter writer,
  BridgeFunction func,
  BridgeSpec spec,
  String libStem,
  String libPkg,
  Set<String> enumNames,
  Set<String> structNames,
  Set<String> recordNames,
) {
  final isEnum = enumNames.contains(func.returnType.name.replaceFirst('?', ''));
  final isStruct = structNames.contains(func.returnType.name.replaceFirst('?', ''));
  final isRecord = func.returnType.isRecord && !func.returnType.isMap;
  final isMap = func.returnType.isMap;
  final isAnyMap = func.returnType.isAnyMap;
  final isTypedData = func.returnType.isTypedData;
  // For enum returns: bridge returns Long (nativeValue); C returns int64_t
  // For struct returns: bridge returns jobject; C packs to C struct via malloc
  // For record returns: bridge returns ByteArray; C copies bytes to malloc'd buffer
  // For TypedData returns: bridge returns a JVM primitive array; C copies it
  // into a malloc-owned [int64 byte length][payload bytes] envelope.
  final retBase = func.returnType.name.replaceFirst('?', '');
  final isVariantReturn = spec.isVariantName(retBase);
  final isAnyNativeObjectReturn = func.returnType.isAnyNativeObject;
  final isCustomTypeReturn = spec.isCustomTypeName(retBase);
  // Nullable prim returns: malloc'd uint8_t* pointer (Dart casts to Pointer<NitroOptXxx> and frees).
  final cReturnType = func.isResult
      ? 'uint8_t*'
      : isAnyNativeObjectReturn
      ? 'int64_t'
      : isCustomTypeReturn
      ? 'uint8_t*'
      : isVariantReturn
      ? 'uint8_t*'
      : func.returnType.name == 'int?'
      ? 'uint8_t*'
      : func.returnType.name == 'uint64?'
      ? 'uint8_t*'
      : func.returnType.name == 'double?'
      ? 'uint8_t*'
      : func.returnType.name == 'bool?'
      ? 'uint8_t*'
      : func.returnType.name == 'DateTime?'
      ? 'uint8_t*'
      : isEnum
      ? 'int64_t'
      : isTypedData
      ? 'uint8_t*'
      : _typeToC(func.returnType.name);
  // instanceId is the first C param for per-instance dispatch (Point 13).
  final paramsDeclParts = <String>['int64_t instanceId'];
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
    // Nullable primitives: raw byte pointer (Dart passes Pointer<NitroOptXxx> = uint8_t*).
    String cParamType;
    if (p.type.isAnyNativeObject) {
      cParamType = 'int64_t'; // AnyNativeObject (nullable uses -1 sentinel)
    } else if (spec.isCustomTypeName(paramBase)) {
      cParamType = 'const uint8_t*'; // @NitroCustomType byte buffer
    } else if (p.type.isNullableNitroPrim) {
      cParamType = 'const uint8_t*';
    } else {
      cParamType = isEnumParam ? 'int64_t' : _paramTypeToC(p.type.name, structNames);
    }
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
  final variantNames = spec.variants.map((v) => v.name).toSet();
  final customTypeNames = spec.customTypes.map((c) => c.name).toSet();
  final jniSigForLog = _jniSig(func.params, func.returnType, enumNames, structNames, libPkg, zeroCopyReturn: func.zeroCopyReturn, isResult: func.isResult, variantNames: variantNames, customTypeNames: customTypeNames);
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

  // Build call args (converting C types to JNI types); instanceId is always first.
  final callArgsList = <String>['(jlong)instanceId'];
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
    } else if (p.type.isNativeHandle) {
      callArgsList.add('(jlong)${p.name}');
    } else if (p.type.isAnyNativeObject) {
      // AnyNativeObject: pass as Long; nullable: -1 sentinel for null
      callArgsList.add('(jlong)${p.name}');
    } else if (spec.isCustomTypeName(p.type.name.replaceFirst('?', ''))) {
      // @NitroCustomType: encode raw bytes as ByteArray
      final ct = spec.customTypeByName(p.type.name.replaceFirst('?', ''))!;
      if (p.type.isNullable || p.type.name.endsWith('?')) {
        writer.line('    jbyteArray j_${p.name} = nullptr;');
        writer.line('    if (${p.name} != nullptr) {');
        writer.line('        j_${p.name} = env->NewByteArray((jsize)${ct.encodedSize});');
        writer.line('        env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${ct.encodedSize}, (const jbyte*)${p.name});');
        writer.line('    }');
      } else {
        writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)${ct.encodedSize});');
        writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${ct.encodedSize}, (const jbyte*)${p.name});');
      }
      callArgsList.add('j_${p.name}');
    } else if (p.type.isFunction) {
      callArgsList.add('(jlong)${p.name}');
    } else if (p.type.isAnyMap || p.type.isMap) {
      // NitroAnyMap / Map<String, T>: binary uint8_t* (4-byte length prefix + payload) → jbyteArray.
      writer.line('    int32_t ${p.name}_map_len = *((const int32_t*)${p.name}) + 4;');
      writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)${p.name}_map_len);');
      writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_map_len, (const jbyte*)${p.name});');
      callArgsList.add('j_${p.name}');
    } else if (p.type.isNullableNitroPrim) {
      // Nullable primitive: NitroOpt* struct pointer — [1B hasValue][N bytes value].
      // No length prefix; the struct size is fixed. Pass raw bytes to Kotlin as ByteArray.
      final structSize = p.type.name == 'bool?' ? 'sizeof(NitroOptBool)' : 'sizeof(NitroOptInt64)';
      writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)$structSize);');
      writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)$structSize, (const jbyte*)${p.name});');
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
    } else if (spec.isVariantName(pt.replaceFirst('?', ''))) {
      // @NitroVariant param: Dart encodes as [4B len][1B tag][fields] via toNative(alloc).
      // Same wire format as @HybridRecord — pass the full buffer (prefix + payload) to Kotlin.
      writer.line('    int32_t ${p.name}_var_len = *((const int32_t*)${p.name});');
      writer.line('    int32_t ${p.name}_var_total = ${p.name}_var_len + 4;');
      writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)${p.name}_var_total);');
      writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_var_total, (const jbyte*)${p.name});');
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
  } else if (func.isResult) {
    // @NitroResult: Kotlin returns ByteArray [1B tag: 0=ok, 1=err][record payload].
    // Copy bytes to malloc'd uint8_t* buffer.
    writer.line('    jbyteArray jarr_res = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    if (jarr_res == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
    writer.line('    jsize res_len = env->GetArrayLength(jarr_res);');
    writer.line('    uint8_t* res_buf = (uint8_t*)malloc((size_t)res_len);');
    writer.line('    env->GetByteArrayRegion(jarr_res, 0, res_len, (jbyte*)res_buf);');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return res_buf;');
  } else if (func.returnType.isNativeHandle) {
    writer.line(
      '    jlong res = env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);',
    );
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return reinterpret_cast<void*>(res);');
  } else if (isAnyNativeObjectReturn) {
    // AnyNativeObject: Kotlin returns Long (instanceId); nullable: -1 = null sentinel
    writer.line('    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return ${func.returnType.isNullable ? "-1" : "0"};');
    writer.line('    }');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return res;');
  } else if (isCustomTypeReturn) {
    // @NitroCustomType: Kotlin returns ByteArray (user-encoded bytes); C mallocs and copies
    writer.line('    jbyteArray jarr_ct = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    if (jarr_ct == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
    writer.line('    jsize ct_len = env->GetArrayLength(jarr_ct);');
    writer.line('    uint8_t* ct_buf = (uint8_t*)malloc((size_t)ct_len);');
    writer.line('    env->GetByteArrayRegion(jarr_ct, 0, ct_len, (jbyte*)ct_buf);');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return ct_buf;');
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
    // Kotlin returns NitroOptFloat64 bytes as ByteArray — malloc ptr, copy bytes, return pointer.
    writer.line('    jbyteArray jarr_nd = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    if (jarr_nd == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
    writer.line('    uint8_t* nd_result = (uint8_t*)malloc((size_t)sizeof(NitroOptFloat64));');
    writer.line('    env->GetByteArrayRegion(jarr_nd, 0, (jsize)sizeof(NitroOptFloat64), (jbyte*)nd_result);');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return nd_result;');
  } else if (func.returnType.name == 'uint64') {
    // uint64: Kotlin returns Long (jlong); cast to uint64_t preserves all bits.
    writer.line(
      '    uint64_t res = (uint64_t)env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);',
    );
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return 0;');
    writer.line('    }');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return res;');
  } else if (func.returnType.name == 'uint64?') {
    // uint64? — same JNI as int? — Kotlin returns NitroOptInt64 ByteArray (same bit layout).
    writer.line('    jbyteArray jarr_nu = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    if (jarr_nu == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
    writer.line('    uint8_t* nu_result = (uint8_t*)malloc((size_t)sizeof(NitroOptInt64));');
    writer.line('    env->GetByteArrayRegion(jarr_nu, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)nu_result);');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return nu_result;');
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
    // Kotlin returns NitroOptInt64 bytes as ByteArray — malloc ptr, copy bytes, return pointer.
    writer.line('    jbyteArray jarr_ni = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    if (jarr_ni == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
    writer.line('    uint8_t* ni_result = (uint8_t*)malloc((size_t)sizeof(NitroOptInt64));');
    writer.line('    env->GetByteArrayRegion(jarr_ni, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)ni_result);');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return ni_result;');
  } else if (func.returnType.name == 'DateTime') {
    // DateTime non-null: same JNI as int — Long (ms since epoch).
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
  } else if (func.returnType.name == 'DateTime?') {
    // DateTime? — same JNI as int? — Kotlin returns NitroOptInt64 ByteArray.
    writer.line('    jbyteArray jarr_nd_ = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    if (jarr_nd_ == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
    writer.line('    uint8_t* nd_result = (uint8_t*)malloc((size_t)sizeof(NitroOptInt64));');
    writer.line('    env->GetByteArrayRegion(jarr_nd_, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)nd_result);');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return nd_result;');
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
    // Kotlin returns NitroOptBool bytes as ByteArray — malloc ptr, copy bytes, return pointer.
    writer.line('    jbyteArray jarr_nb = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    if (jarr_nb == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
    writer.line('    uint8_t* nb_result = (uint8_t*)malloc((size_t)sizeof(NitroOptBool));');
    writer.line('    env->GetByteArrayRegion(jarr_nb, 0, (jsize)sizeof(NitroOptBool), (jbyte*)nb_result);');
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
  } else if (isAnyMap || isMap) {
    // NitroAnyMap / Map<String, T>: bridge returns ByteArray (binary-encoded map).
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
  } else if (isVariantReturn) {
    // @NitroVariant return: Kotlin returns ByteArray [4B len][1B tag][fields].
    // Copy bytes to malloc'd uint8_t* buffer.
    writer.line('    jbyteArray jarr_var = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
    writer.line('    if (env->ExceptionCheck()) {');
    writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        return nullptr;');
    writer.line('    }');
    writer.line('    if (jarr_var == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
    writer.line('    jsize var_len = env->GetArrayLength(jarr_var);');
    writer.line('    uint8_t* var_buf = (uint8_t*)malloc((size_t)var_len);');
    writer.line('    env->GetByteArrayRegion(jarr_var, 0, var_len, (jbyte*)var_buf);');
    writer.line('    env->PopLocalFrame(nullptr);');
    writer.line('    return var_buf;');
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

/// Emits C bridge getter and setter functions for all properties.
void _emitJniPropertyBridges(
  CodeWriter writer,
  BridgeSpec spec,
  Set<String> enumNames,
  Set<String> structNames,
) {
  // ── Properties ────────────────────────────────────────────────────────────
  for (final prop in spec.properties) {
    // Classify once — used for C type selection, JNI sig, and dispatch body.
    // This replaces the previous manually-maintained boolean flag soup
    // (isEnum, isVariantProp, isNullablePrimGet/Prop, propBase, etc.) with a
    // single canonical source, and fixes the DateTime / DateTime? cases that
    // previously fell through to incorrect default branches.
    final propKind = classifyBridgeItem(prop.type, spec);

    // C return type for the getter (and const-qualified param type for the setter).
    // Nullable primitives and variants are transported as uint8_t* (ByteArray / NitroOpt*).
    final cType = switch (propKind) {
      BridgeItemKind.intNullable ||
      BridgeItemKind.doubleNullable ||
      BridgeItemKind.boolNullable ||
      BridgeItemKind.dateTimeNullable ||
      BridgeItemKind.nitroVariant ||
      BridgeItemKind.nitroVariantNullable => 'uint8_t*',
      BridgeItemKind.hybridEnum => 'int64_t',
      _ => _typeToC(prop.type.name),
    };
    final paramCType = switch (propKind) {
      BridgeItemKind.intNullable ||
      BridgeItemKind.doubleNullable ||
      BridgeItemKind.boolNullable ||
      BridgeItemKind.dateTimeNullable ||
      BridgeItemKind.nitroVariant ||
      BridgeItemKind.nitroVariantNullable => 'const uint8_t*',
      BridgeItemKind.hybridEnum => 'int64_t',
      _ => _typeToC(prop.type.name),
    };

    if (prop.hasGetter) {
      // S8: property getter receives NitroError* out-param; instanceId for dispatch (Point 13).
      writer.line('$cType ${prop.getSymbol}(int64_t instanceId, NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    JNIEnv* env = GetEnv();');
      writer.line('    if (env == nullptr) { return ${_defaultValue(cType)}; }');
      writer.line('    jmethodID methodId = g_mid_${prop.getSymbol}_call;');
      // JNI method signature: (J) prefix = instanceId long; return type depends on kind.
      // Nullable prims + variants return ByteArray ([B). Enum returns long (J).
      final jniGetSig = switch (propKind) {
        BridgeItemKind.hybridEnum => '(J)J',
        BridgeItemKind.intNullable ||
        BridgeItemKind.doubleNullable ||
        BridgeItemKind.boolNullable ||
        BridgeItemKind.dateTimeNullable ||
        BridgeItemKind.nitroVariant ||
        BridgeItemKind.nitroVariantNullable => '(J)[B',
        _ => '(J)${_jniSigType(prop.type.name)}',
      };
      writer.line(
        '    if (methodId == nullptr) { LOGE("Method not found: ${prop.getSymbol}_call sig=$jniGetSig"); return ${_defaultValue(cType)}; }',
      );
      writer.line('    if (env->PushLocalFrame(8) != 0) { return ${_defaultValue(cType)}; }');
      switch (propKind) {
        case BridgeItemKind.double_:
          writer.line('    double res = env->CallStaticDoubleMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return res;');

        case BridgeItemKind.int_ || BridgeItemKind.dateTime || BridgeItemKind.hybridEnum:
          // int, DateTime, and non-nullable enum all return a JNI long (J).
          // Previously DateTime fell through to the else-branch and returned 0 always.
          writer.line('    $cType res = ($cType)env->CallStaticLongMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return res;');

        case BridgeItemKind.bool_:
          writer.line('    bool res = env->CallStaticBooleanMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return res;');

        case BridgeItemKind.intNullable || BridgeItemKind.dateTimeNullable:
          // DateTime? shares the NitroOptInt64 wire (ms-since-epoch int64).
          writer.line('    jbyteArray jarr_ni = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    if (jarr_ni == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
          writer.line('    uint8_t* ni_result = (uint8_t*)malloc((size_t)sizeof(NitroOptInt64));');
          writer.line('    env->GetByteArrayRegion(jarr_ni, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)ni_result);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return ni_result;');

        case BridgeItemKind.doubleNullable:
          writer.line('    jbyteArray jarr_nd = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    if (jarr_nd == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
          writer.line('    uint8_t* nd_result = (uint8_t*)malloc((size_t)sizeof(NitroOptFloat64));');
          writer.line('    env->GetByteArrayRegion(jarr_nd, 0, (jsize)sizeof(NitroOptFloat64), (jbyte*)nd_result);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return nd_result;');

        case BridgeItemKind.boolNullable:
          writer.line('    jbyteArray jarr_nb = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    if (jarr_nb == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
          writer.line('    uint8_t* nb_result = (uint8_t*)malloc((size_t)sizeof(NitroOptBool));');
          writer.line('    env->GetByteArrayRegion(jarr_nb, 0, (jsize)sizeof(NitroOptBool), (jbyte*)nb_result);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return nb_result;');

        case BridgeItemKind.string || BridgeItemKind.stringNullable:
          // Both String and String? use the same null-guarded UTF path.
          writer.line('    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    if (jstr == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
          writer.line('    const char* nativeStr = env->GetStringUTFChars(jstr, 0);');
          writer.line('    char* result = strdup(nativeStr);');
          writer.line('    env->ReleaseStringUTFChars(jstr, nativeStr);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return result;');

        case BridgeItemKind.nitroVariant || BridgeItemKind.nitroVariantNullable:
          // Variant: Kotlin returns ByteArray [4B len][1B tag][fields]; copy to malloc'd buf.
          writer.line('    jbyteArray jvarr_v = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    if (jvarr_v == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
          writer.line('    jsize jvarr_len = env->GetArrayLength(jvarr_v);');
          writer.line('    uint8_t* v_result = (uint8_t*)malloc((size_t)jvarr_len);');
          writer.line('    env->GetByteArrayRegion(jvarr_v, 0, jvarr_len, (jbyte*)v_result);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return v_result;');

        default:
          // hybridStruct, hybridRecord, typedData, void, other.
          // Struct getter is covered by the C bridge's pack_*_from_jni path (not reached here).
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return ${_defaultValue(cType)};');
      }
      writer.line('}');
      writer.blankLine();
    }

    if (prop.hasSetter) {
      // S8: property setter receives NitroError* out-param; instanceId for dispatch (Point 13).
      writer.line('void ${prop.setSymbol}(int64_t instanceId, $paramCType value, NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    JNIEnv* env = GetEnv();');
      writer.line('    if (env == nullptr) { return; }');
      writer.line('    jmethodID methodId = g_mid_${prop.setSymbol}_call;');
      // JNI setter signature: (J<value>)V. DateTime? was previously missing [B here.
      final jniSetSig = switch (propKind) {
        BridgeItemKind.intNullable ||
        BridgeItemKind.doubleNullable ||
        BridgeItemKind.boolNullable ||
        BridgeItemKind.dateTimeNullable ||
        BridgeItemKind.nitroVariant ||
        BridgeItemKind.nitroVariantNullable => '(J[B)V',
        BridgeItemKind.hybridEnum => '(JJ)V',
        _ => '(J${_jniSigType(prop.type.name)})V',
      };
      writer.line(
        '    if (methodId == nullptr) { LOGE("Method not found: ${prop.setSymbol}_call sig=$jniSetSig"); return; }',
      );
      writer.line('    if (env->PushLocalFrame(8) != 0) { return; }');
      switch (propKind) {
        case BridgeItemKind.string || BridgeItemKind.stringNullable:
          writer.line('    jstring jval = env->NewStringUTF(value);');
          writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, jval);');

        case BridgeItemKind.hybridStruct:
          // Non-nullable struct: convert C shadow struct to JVM object via unpack helper.
          final stName = prop.type.name;
          writer.line('    jobject jval = unpack_${stName}_to_jni(env, (const $stName*)value);');
          writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, jval);');

        case BridgeItemKind.bool_:
          // Non-nullable bool: cast to jboolean for (Z)V param.
          writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, (jboolean)(value != 0));');

        case BridgeItemKind.intNullable || BridgeItemKind.dateTimeNullable:
          // DateTime? shares the NitroOptInt64 wire — fixed size, no length prefix.
          writer.line('    jbyteArray j_${prop.dartName} = env->NewByteArray((jsize)sizeof(NitroOptInt64));');
          writer.line('    env->SetByteArrayRegion(j_${prop.dartName}, 0, (jsize)sizeof(NitroOptInt64), (const jbyte*)value);');
          writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, j_${prop.dartName});');

        case BridgeItemKind.doubleNullable:
          writer.line('    jbyteArray j_${prop.dartName} = env->NewByteArray((jsize)sizeof(NitroOptFloat64));');
          writer.line('    env->SetByteArrayRegion(j_${prop.dartName}, 0, (jsize)sizeof(NitroOptFloat64), (const jbyte*)value);');
          writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, j_${prop.dartName});');

        case BridgeItemKind.boolNullable:
          writer.line('    jbyteArray j_${prop.dartName} = env->NewByteArray((jsize)sizeof(NitroOptBool));');
          writer.line('    env->SetByteArrayRegion(j_${prop.dartName}, 0, (jsize)sizeof(NitroOptBool), (const jbyte*)value);');
          writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, j_${prop.dartName});');

        case BridgeItemKind.nitroVariant || BridgeItemKind.nitroVariantNullable:
          // Variant: full blob is [4B payload_len][1B tag][fields]; total = 4 + payload_len.
          writer.line('    jsize _vsp_len = (jsize)((*(int32_t*)value) + 4);');
          writer.line('    jbyteArray j_v_prop = env->NewByteArray(_vsp_len);');
          writer.line('    env->SetByteArrayRegion(j_v_prop, 0, _vsp_len, (const jbyte*)value);');
          writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, j_v_prop);');

        default:
          // int_, double_, dateTime, hybridEnum, hybridRecord, and remaining types:
          // value is already the correct primitive/pointer for CallStaticVoidMethod.
          writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, value);');
      }
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('}');
      writer.blankLine();
    }
  }
}

/// Emits C bridge register/release/emit functions for all streams.
void _emitJniStreamBridges(
  CodeWriter writer,
  BridgeSpec spec,
  Set<String> enumNames,
  Set<String> structNames,
) {
  // ── Streams ───────────────────────────────────────────────────────────────
  for (final stream in spec.streams) {
    // JNI name: "nitro" + "_" + "{lib}_module" (with internal _ → _1)
    // e.g. nitro.my_camera_module → nitro_my_1camera_1module (NOT nitro_1my_1camera_1module)

    // instanceId selects which impl handles this stream subscription (Point 13).
    writer.line('void ${stream.registerSymbol}(int64_t instanceId, int64_t dart_port) {');
    writer.line('    JNIEnv* env = GetEnv();');
    writer.line('    if (env == nullptr) { return; }');

    writer.line('    jmethodID methodId = g_mid_${stream.registerSymbol}_call;');
    writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${stream.registerSymbol}_call sig=(JJ)V"); return; }');
    writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, dart_port);');
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

    // For batch streams, emit using the appropriate wire format.
    if (stream.isBatch) {
      if (stream.itemType.name == 'String') {
        // String batches use Dart_CObject_kArray of kString elements (jobjectArray).
        final jniBatchEmit = _jniMethodName(spec.lib, spec.dartClassName, 'emit_${stream.dartName}_string_batch');
        writer.line('JNIEXPORT jboolean JNICALL $jniBatchEmit(JNIEnv* env, jobject thiz, jlong dartPort, jobjectArray batch) {');
        writer.line('    jsize n = env->GetArrayLength(batch);');
        writer.line('    Dart_CObject** elems = (Dart_CObject**)malloc((size_t)n * sizeof(Dart_CObject*));');
        writer.line('    Dart_CObject* cobjs = (Dart_CObject*)malloc((size_t)n * sizeof(Dart_CObject));');
        writer.line('    for (jsize i = 0; i < n; i++) {');
        writer.line('        jstring js = (jstring)env->GetObjectArrayElement(batch, i);');
        writer.line('        const char* cs = env->GetStringUTFChars(js, nullptr);');
        writer.line('        cobjs[i].type = Dart_CObject_kString;');
        writer.line('        cobjs[i].value.as_string = (char*)cs;');
        writer.line('        elems[i] = &cobjs[i];');
        writer.line('        env->DeleteLocalRef(js);');
        writer.line('    }');
        writer.line('    Dart_CObject obj;');
        writer.line('    obj.type = Dart_CObject_kArray;');
        writer.line('    obj.value.as_array.length = (intptr_t)n;');
        writer.line('    obj.value.as_array.values = elems;');
        writer.line('    bool ok = Dart_PostCObject_DL(dartPort, &obj);');
        // Release UTF chars after posting (Dart_PostCObject_DL copies the data).
        writer.line('    for (jsize i = 0; i < n; i++) {');
        writer.line('        jstring js = (jstring)env->GetObjectArrayElement(batch, i);');
        writer.line('        env->ReleaseStringUTFChars(js, cobjs[i].value.as_string);');
        writer.line('        env->DeleteLocalRef(js);');
        writer.line('    }');
        writer.line('    free(elems); free(cobjs);');
        writer.line('    return ok ? JNI_TRUE : JNI_FALSE;');
        writer.line('}');
        writer.blankLine();
      } else {
        final batchItemBase = stream.itemType.name.replaceFirst('?', '');
        final isBatchRecord = spec.recordTypes.any((r) => r.name == batchItemBase);
        final isBatchVariant = spec.variants.any((v) => v.name == batchItemBase);
        if (isBatchRecord || isBatchVariant) {
          // Record/variant batches: Kotlin emits [4B outer_len][4B count][item bytes...]
          // as a ByteArray. Post as kTypedData/kUint8 so Dart receives Uint8List.
          final jniBatchEmit = _jniMethodName(spec.lib, spec.dartClassName, 'emit_${stream.dartName}_bytes_batch');
          writer.line('JNIEXPORT jboolean JNICALL $jniBatchEmit(JNIEnv* env, jobject thiz, jlong dartPort, jbyteArray batch) {');
          writer.line('    jsize len = env->GetArrayLength(batch);');
          writer.line('    jbyte* bytes = env->GetByteArrayElements(batch, nullptr);');
          writer.line('    Dart_CObject obj;');
          writer.line('    obj.type = Dart_CObject_kTypedData;');
          writer.line('    obj.value.as_typed_data.type = Dart_TypedData_kUint8;');
          writer.line('    obj.value.as_typed_data.length = (intptr_t)len;');
          writer.line('    obj.value.as_typed_data.values = (uint8_t*)bytes;');
          writer.line('    bool ok = Dart_PostCObject_DL(dartPort, &obj);');
          writer.line('    env->ReleaseByteArrayElements(batch, bytes, JNI_ABORT);');
          writer.line('    return ok ? JNI_TRUE : JNI_FALSE;');
          writer.line('}');
          writer.blankLine();
        } else {
          // Numeric batches: raw int64 values [count, item0, item1, ...] as TypedData.
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
        }
      }
      continue; // Skip the normal single-item emit for batch streams
    }
    final jniEmit = _jniMethodName(
      spec.lib,
      spec.dartClassName,
      'emit_${stream.dartName}',
    );
    // Classify the item type once — drives both the JNI signature and the
    // dispatch body. Using BridgeItemKind (not raw name comparisons) eliminates
    // silent fall-throughs: e.g. 'String?' previously missed the 'String'
    // branch and always posted kNull on Android.
    final itemKind = classifyBridgeItem(stream.itemType, spec);
    // Determine the JNI C parameter type for the emit function signature.
    //  • Nullable scalar primitives → jobject (boxed JVM: Long?, Double?, Boolean?)
    //  • Nullable enums            → jobject (Kotlin passes the boxed enum or null)
    //  • Records and variants      → jbyteArray (Kotlin calls .encode())
    //  • All others                → _jniSigTypeC lookup (jstring, jlong, etc.)
    final jniItemType = switch (itemKind) {
      BridgeItemKind.intNullable ||
      BridgeItemKind.doubleNullable ||
      BridgeItemKind.boolNullable ||
      BridgeItemKind.dateTimeNullable ||
      BridgeItemKind.uint64Nullable ||
      BridgeItemKind.hybridEnumNullable => 'jobject',
      BridgeItemKind.hybridRecord ||
      BridgeItemKind.hybridRecordNullable ||
      BridgeItemKind.nitroVariant ||
      BridgeItemKind.nitroVariantNullable => 'jbyteArray',
      _ => _jniSigTypeC(stream.itemType.name),
    };
    writer.line(
      'JNIEXPORT jboolean JNICALL $jniEmit(JNIEnv* env, jobject thiz, jlong dartPort, $jniItemType item) {',
    );
    writer.line('    Dart_CObject obj;');
    switch (itemKind) {
      case BridgeItemKind.double_:
        writer.line('    obj.type = Dart_CObject_kDouble;');
        writer.line('    obj.value.as_double = item;');

      case BridgeItemKind.int_ || BridgeItemKind.dateTime || BridgeItemKind.uint64_:
        // DateTime and uint64 use the same int64_t/kInt64 wire as int.
        // For uint64_, the bit pattern is preserved; Dart int holds the raw bits.
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = (int64_t)item;');

      case BridgeItemKind.bool_:
        // Use kInt64 (0/1) instead of kBool: Dart_PostCObject_DL with kBool
        // is unreliable on some Android versions and returns false.
        // The Dart stream unpack decodes int != 0 as true.
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = item ? 1 : 0;');

      case BridgeItemKind.doubleNullable:
        // Nullable Double: jobject (java.lang.Double), nullptr = null.
        writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
        writer.line('    else {');
        writer.line('        jmethodID _mid = env->GetMethodID(env->GetObjectClass(item), "doubleValue", "()D");');
        writer.line('        obj.type = Dart_CObject_kDouble;');
        writer.line('        obj.value.as_double = env->CallDoubleMethod(item, _mid);');
        writer.line('    }');

      case BridgeItemKind.boolNullable:
        // Nullable Boolean: jobject (java.lang.Boolean), nullptr = null.
        writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
        writer.line('    else {');
        writer.line('        jmethodID _mid = env->GetMethodID(env->GetObjectClass(item), "booleanValue", "()Z");');
        writer.line('        obj.type = Dart_CObject_kInt64;');
        writer.line('        obj.value.as_int64 = env->CallBooleanMethod(item, _mid) ? 1 : 0;');
        writer.line('    }');

      case BridgeItemKind.intNullable || BridgeItemKind.dateTimeNullable || BridgeItemKind.uint64Nullable:
        // Nullable Long / nullable DateTime / nullable uint64: jobject (java.lang.Long), nullptr = null.
        // All share the same Long wire; uint64? bits are preserved as int64_t.
        writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
        writer.line('    else {');
        writer.line('        jmethodID _mid = env->GetMethodID(env->GetObjectClass(item), "longValue", "()J");');
        writer.line('        obj.type = Dart_CObject_kInt64;');
        writer.line('        obj.value.as_int64 = (int64_t)env->CallLongMethod(item, _mid);');
        writer.line('    }');

      case BridgeItemKind.hybridStruct || BridgeItemKind.hybridStructNullable:
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

      case BridgeItemKind.hybridRecord ||
           BridgeItemKind.hybridRecordNullable ||
           BridgeItemKind.nitroVariant ||
           BridgeItemKind.nitroVariantNullable:
        // @HybridRecord and @NitroVariant: Kotlin calls .encode() → jbyteArray.
        // Nullable items arrive as nullptr → post kNull.
        // C copies bytes to a malloc'd native buffer and sends the pointer as kInt64.
        // Dart reads via RecordType.fromNative/VariantExt.fromNative and frees with malloc.free.
        if (itemKind.isNullable) {
          writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
          writer.line('    else {');
          writer.line('        jsize len = env->GetArrayLength(item);');
          writer.line('        uint8_t* buf = (uint8_t*)malloc((size_t)len);');
          writer.line('        env->GetByteArrayRegion(item, 0, len, (jbyte*)buf);');
          writer.line('        obj.type = Dart_CObject_kInt64;');
          writer.line('        obj.value.as_int64 = (intptr_t)buf;');
          writer.line('    }');
        } else {
          writer.line('    jsize len = env->GetArrayLength(item);');
          writer.line('    uint8_t* buf = (uint8_t*)malloc((size_t)len);');
          writer.line('    env->GetByteArrayRegion(item, 0, len, (jbyte*)buf);');
          writer.line('    obj.type = Dart_CObject_kInt64;');
          writer.line('    obj.value.as_int64 = (intptr_t)buf;');
        }

      case BridgeItemKind.string || BridgeItemKind.stringNullable:
        // Both String and String? are handled here — the original bug:
        // only 'String' was matched, so String? always fell through to kNull.
        // BridgeItemKind unifies both, making this case impossible to miss.
        // Post inline and return early — Dart_PostCObject_DL copies the string
        // internally so we release the JNI chars immediately after.
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

      case BridgeItemKind.hybridEnum:
        // Non-nullable enum: item is a jobject (Kotlin enum). Extract nativeValue.
        writer.line('    // item is a jobject (Kotlin enum). Extract its nativeValue Long field.');
        writer.line('    jclass enumCls = env->GetObjectClass(item);');
        writer.line('    jfieldID fid = enumCls ? env->GetFieldID(enumCls, "nativeValue", "J") : nullptr;');
        writer.line('    if (fid == nullptr) { LOGE("emit_${stream.dartName}: cannot find nativeValue on ${stream.itemType.name}"); if (enumCls) env->DeleteLocalRef(enumCls); return JNI_FALSE; }');
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = (int64_t)env->GetLongField(item, fid);');
        writer.line('    env->DeleteLocalRef(enumCls);');

      case BridgeItemKind.hybridEnumNullable:
        // Nullable enum: item is jobject or nullptr → post kNull.
        writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
        writer.line('    else {');
        writer.line('        jclass enumCls = env->GetObjectClass(item);');
        writer.line('        jfieldID fid = enumCls ? env->GetFieldID(enumCls, "nativeValue", "J") : nullptr;');
        writer.line('        if (fid == nullptr) { LOGE("emit_${stream.dartName}: cannot find nativeValue on ${stream.itemType.name}"); if (enumCls) env->DeleteLocalRef(enumCls); return JNI_FALSE; }');
        writer.line('        obj.type = Dart_CObject_kInt64;');
        writer.line('        obj.value.as_int64 = (int64_t)env->GetLongField(item, fid);');
        writer.line('        env->DeleteLocalRef(enumCls);');
        writer.line('    }');

      case BridgeItemKind.typedData ||
           BridgeItemKind.typedDataNullable ||
           BridgeItemKind.void_ ||
           BridgeItemKind.other:
        // Not valid as stream item types — emit null as a safe no-op.
        // Explicit cases so the compiler enforces exhaustiveness when new
        // BridgeItemKind values are added.
        writer.line('    obj.type = Dart_CObject_kNull;');
    }
    writer.line('    if (!Dart_PostCObject_DL(dartPort, &obj)) {');
    if (itemKind.isStructKind) {
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
    } else if (itemKind.isRecordKind || itemKind.isVariantKind) {
      writer.line('        free(buf);');
    }
    writer.line('        return JNI_FALSE;');
    writer.line('    }');
    writer.line('    return JNI_TRUE;');
    writer.line('}');
    writer.blankLine();
  }
}

/// Emits JNI native methods that invoke C callback function pointers.
void _emitJniCallbackInvokers(
  CodeWriter writer,
  BridgeSpec spec,
  Set<String> enumNames,
  Set<String> structNames,
  Set<String> recordNames, {
  Set<String> variantNames = const {},
}) {
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
        if (base == 'bool') return 'jlong'; // 1L = true, 0L = false
        if (base == 'String') return 'jstring';
        if (structNames.contains(base)) return 'jobject'; // Kotlin data class
        if (recordNames.contains(base)) return 'jbyteArray'; // serialized ByteArray
        if (variantNames.contains(base)) return 'jbyteArray'; // encoded variant [4B len][tag][fields]
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
        if (variantNames.contains(base)) return 'const uint8_t*'; // length-prefixed variant bytes
        return 'int64_t'; // int, enum → int64_t
      }

      // Build C parameter list with proper JNI types.
      // For expandable structs (all-numeric fields), expand each field as a separate jlong
      // so NativeCallable.listener fires synchronously on Android.
      // For nullable int/double/bool, expand to two jlong params (isNull flag + value bits).
      final cParams = StringBuffer('JNIEnv* env, jobject thiz, jlong callbackPtr');
      for (var i = 0; i < cbParams.length; i++) {
        final base = cbParams[i].name.replaceFirst('?', '');
        final isNullable = cbParams[i].name.endsWith('?');
        final struct = spec.structs.where((s) => s.name == base).firstOrNull;
        if (struct != null && _isExpandableStruct(struct)) {
          for (final f in struct.fields) {
            cParams.write(', jlong arg${i}_${f.name}');
          }
        } else if (isNullable && (base == 'int' || base == 'double' || base == 'bool')) {
          cParams.write(', jlong arg${i}Null, jlong arg${i}Val');
        } else {
          cParams.write(', ${jniCParam(cbParams[i])} arg$i');
        }
      }

      // Build C typedef params — expanded struct fields use int64_t each.
      // Nullable int/double/bool also become two int64_t params.
      final typedefParts = <String>[];
      for (var i = 0; i < cbParams.length; i++) {
        final base = cbParams[i].name.replaceFirst('?', '');
        final isNullable = cbParams[i].name.endsWith('?');
        final struct = spec.structs.where((s) => s.name == base).firstOrNull;
        if (struct != null && _isExpandableStruct(struct)) {
          typedefParts.addAll(struct.fields.map((_) => 'int64_t'));
        } else if (isNullable && (base == 'int' || base == 'double' || base == 'bool')) {
          typedefParts.add('int64_t'); // isNull flag
          typedefParts.add('int64_t'); // value bits
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
      final retBase = cbReturnTypeDart?.replaceFirst('?', '') ?? 'void';
      final isRecordReturn = !isVoidReturn && !isStringReturn && recordNames.contains(retBase);
      final isVariantReturn = !isVoidReturn && !isStringReturn && variantNames.contains(retBase);
      // JNI return: void, jstring (String), jbyteArray (record/variant), jlong (primitives)
      final cRetType = isVoidReturn ? 'void'
          : isStringReturn ? 'jstring'
          : (isRecordReturn || isVariantReturn) ? 'jbyteArray'
          : 'jlong';
      // C typedef return: void, const char* (String), uint8_t* (record/variant bytes), int64_t (prims)
      final cTypedefReturn = isVoidReturn ? 'void'
          : isStringReturn ? 'const char*'
          : (isRecordReturn || isVariantReturn) ? 'uint8_t*'
          : 'int64_t';

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
        } else if (variantNames.contains(base)) {
          writer.line('    jsize v_len$i = env->GetArrayLength(arg$i);');
          writer.line('    uint8_t* v_buf$i = (uint8_t*)malloc((size_t)v_len$i);');
          writer.line('    env->GetByteArrayRegion(arg$i, 0, v_len$i, (jbyte*)v_buf$i);');
        }
      }
      final callParts = <String>[];
      for (var i = 0; i < cbParams.length; i++) {
        final base = cbParams[i].name.replaceFirst('?', '');
        final isNullable = cbParams[i].name.endsWith('?');
        final struct = spec.structs.where((s) => s.name == base).firstOrNull;
        if (struct != null && _isExpandableStruct(struct)) {
          // Pass each field's raw int64_t value directly — Dart receives Int64 and reconstructs.
          callParts.addAll(struct.fields.map((f) => '(int64_t)arg${i}_${f.name}'));
        } else if (isNullable && (base == 'int' || base == 'double' || base == 'bool')) {
          // Nullable primitive: two int64_t args (isNull flag + value bits).
          callParts.add('(int64_t)arg${i}Null');
          callParts.add('(int64_t)arg${i}Val');
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
        } else if (variantNames.contains(base)) {
          callParts.add('v_buf$i');
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
        } else if (isRecordReturn || isVariantReturn) {
          // Record/variant return: Dart malloc'd [4B payload_len][payload].
          // Read length, wrap as jbyteArray for Kotlin, then free the C buffer.
          writer.line('    if (!_ret) return nullptr;');
          writer.line('    uint32_t _plen; memcpy(&_plen, _ret, 4);');
          writer.line('    jsize _tlen = (jsize)(4 + _plen);');
          writer.line('    jbyteArray _jarr = env->NewByteArray(_tlen);');
          writer.line('    env->SetByteArrayRegion(_jarr, 0, _tlen, (jbyte*)_ret);');
          writer.line('    free(_ret);');
          writer.line('    return _jarr;');
        } else {
          writer.line('    return (jlong)_ret;');
        }
      }
      writer.line('}');
      writer.blankLine();

      // Per-callback release: posts the callbackPtr int64 to the stored Dart release port,
      // which triggers the Dart bridge to close the corresponding NativeCallable.
      final releaseJniName = _jniMethodName(spec.lib, spec.dartClassName, '_release_${p.name}');
      if (callbackNativeImpls.add('_release_${p.name}')) {
        writer.line('JNIEXPORT void JNICALL $releaseJniName(JNIEnv*, jobject, jlong callbackPtr) {');
        writer.line('    std::lock_guard<std::mutex> _lk(g_cb_release_mtx);');
        writer.line('    auto it = g_cb_release_ports.find(callbackPtr);');
        writer.line('    if (it != g_cb_release_ports.end()) {');
        writer.line('        Dart_CObject msg; msg.type = Dart_CObject_kInt64; msg.value.as_int64 = callbackPtr;');
        writer.line('        Dart_PostCObject_DL(it->second, &msg);');
        writer.line('        g_cb_release_ports.erase(it);');
        writer.line('    }');
        writer.line('}');
        writer.blankLine();
      }
    }
  }
}

/// Emits the JNI `initialize()` method (method-ID caching) and postXxxToPort helpers.
void _emitJniInitializeAndPostHelpers(
  CodeWriter writer,
  BridgeSpec spec,
  String libStem,
  String libPkg,
  Set<String> enumNames,
  Set<String> structNames,
  Set<String> recordNames,
) {
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
  // Instance lifecycle method IDs (factory-pattern creation / disposal).
  writer.line('        g_mid_create_instance_call = env->GetStaticMethodID(g_bridgeClass, "create_instance_call", "(Ljava/lang/String;)J");');
  writer.line('        if (!g_mid_create_instance_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: create_instance_call sig=(Ljava/lang/String;)J"); }');
  writer.line('        g_mid_destroy_instance_call = env->GetStaticMethodID(g_bridgeClass, "destroy_instance_call", "(J)V");');
  writer.line('        if (!g_mid_destroy_instance_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: destroy_instance_call sig=(J)V"); }');
  final initVariantNames = spec.variants.map((v) => v.name).toSet();
  final initCustomTypeNames = spec.customTypes.map((c) => c.name).toSet();
  for (final func in spec.functions) {
    final String jniSig;
    if (func.isNativeAsync) {
      jniSig = _jniNativeAsyncSig(func.params, enumNames, structNames, libPkg);
    } else {
      jniSig = _jniSig(func.params, func.returnType, enumNames, structNames, libPkg, zeroCopyReturn: func.zeroCopyReturn, isResult: func.isResult, variantNames: initVariantNames, customTypeNames: initCustomTypeNames);
    }
    writer.line('        g_mid_${func.dartName}_call = env->GetStaticMethodID(g_bridgeClass, "${func.dartName}_call", "$jniSig");');
    writer.line('        if (!g_mid_${func.dartName}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${func.dartName}_call sig=$jniSig"); }');
  }
  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(prop.type.name);
    final isVariantPropInit = spec.isVariantName(prop.type.name.replaceFirst('?', ''));
    if (prop.hasGetter) {
      final isNullablePrimPropInit = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?';
      // Nullable primitives and variants use [B (ByteArray) encoding; 'J' prefix for instanceId.
      final isCustomTypePropGet = initCustomTypeNames.contains(prop.type.name.replaceFirst('?', ''));
      final jniRetSig = isNullablePrimPropInit ? '[B' : isEnum ? 'J' : isVariantPropInit ? '[B' : isCustomTypePropGet ? '[B' : _jniSigType(prop.type.name);
      writer.line('        g_mid_${prop.getSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${prop.getSymbol}_call", "(J)$jniRetSig");');
      writer.line('        if (!g_mid_${prop.getSymbol}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${prop.getSymbol}_call sig=(J)$jniRetSig"); }');
    }
    if (prop.hasSetter) {
      final isNullablePrimPropInit2 = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?';
      // Nullable primitives and variants use [B (ByteArray) encoding; 'J' prefix for instanceId.
      final isCustomTypePropSet = initCustomTypeNames.contains(prop.type.name.replaceFirst('?', ''));
      final jniParamSig = isNullablePrimPropInit2 ? '[B' : isEnum ? 'J' : isVariantPropInit ? '[B' : isCustomTypePropSet ? '[B' : _jniSigType(prop.type.name);
      writer.line('        g_mid_${prop.setSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${prop.setSymbol}_call", "(J$jniParamSig)V");');
      writer.line('        if (!g_mid_${prop.setSymbol}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${prop.setSymbol}_call sig=(J$jniParamSig)V"); }');
    }
  }
  for (final stream in spec.streams) {
    // Register takes instanceId + dartPort (JJ)V; release takes only dartPort (J)V (Point 13).
    writer.line('        g_mid_${stream.registerSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${stream.registerSymbol}_call", "(JJ)V");');
    writer.line('        if (!g_mid_${stream.registerSymbol}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${stream.registerSymbol}_call sig=(JJ)V"); }');
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
    writer.line('JNIEXPORT void JNICALL $jniPostString(JNIEnv* env, jclass, jlong dartPort, jstring value) {');
    writer.line('    Dart_CObject obj;');
    writer.line('    if (value == nullptr) {');
    writer.line('        obj.type = Dart_CObject_kNull;');
    writer.line('        Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
    writer.line('        return;');
    writer.line('    }');
    writer.line('    const char* cStr = env->GetStringUTFChars(value, nullptr);');
    writer.line('    if (cStr == nullptr) {');
    writer.line('        obj.type = Dart_CObject_kNull;');
    writer.line('        Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
    writer.line('        return;');
    writer.line('    }');
    writer.line('    obj.type = Dart_CObject_kString;');
    writer.line('    obj.value.as_string = const_cast<char*>(cStr);');
    writer.line('    Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
    writer.line('    env->ReleaseStringUTFChars(value, cStr);');
    writer.line('}');
    writer.blankLine();
  }
}

void _emitJniMethods(
  CodeWriter writer,
  BridgeSpec spec,
  String libStem,
  String libPkg,
  Set<String> enumNames,
  Set<String> structNames,
) {
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

  // ── Instance lifecycle (factory pattern — like RN Nitro's HybridObjectRegistry) ──
  // create_instance: called by Dart on first getInstance(key). Kotlin invokes the
  // registered factory, stores the new impl keyed by an auto-incremented int64,
  // and returns that id. All subsequent bridge calls use that id.
  writer.line('NITRO_EXPORT int64_t ${libStem}_create_instance(const char* key) {');
  writer.line('    JNIEnv* env = GetEnv();');
  writer.line('    if (env == nullptr) { return -1; }');
  writer.line('    jmethodID mid = g_mid_create_instance_call;');
  writer.line('    if (mid == nullptr) { LOGE("create_instance_call JNI method not cached"); return -1; }');
  writer.line('    jstring j_key = env->NewStringUTF(key ? key : "default");');
  writer.line('    jlong id = env->CallStaticLongMethod(g_bridgeClass, mid, j_key);');
  writer.line('    env->DeleteLocalRef(j_key);');
  writer.line('    if (env->ExceptionCheck()) { env->ExceptionClear(); LOGE("create_instance_call threw"); return -1; }');
  writer.line('    return (int64_t)id;');
  writer.line('}');
  writer.blankLine();
  // destroy_instance: called by Dart from dispose(). Kotlin removes the impl from
  // its _implementations map and calls onDetached() on it.
  writer.line('NITRO_EXPORT void ${libStem}_destroy_instance(int64_t instanceId) {');
  writer.line('    JNIEnv* env = GetEnv();');
  writer.line('    if (env == nullptr) { return; }');
  writer.line('    jmethodID mid = g_mid_destroy_instance_call;');
  writer.line('    if (mid == nullptr) { LOGE("destroy_instance_call JNI method not cached"); return; }');
  writer.line('    env->CallStaticVoidMethod(g_bridgeClass, mid, (jlong)instanceId);');
  writer.line('    if (env->ExceptionCheck()) { env->ExceptionClear(); }');
  writer.line('}');
  writer.blankLine();

  for (final func in spec.functions) {
    if (func.isNativeAsync) {
      _emitJniNativeAsyncFuncBody(writer, func, spec, libStem, libPkg, enumNames, structNames, recordNames);
      continue;
    }
    _emitJniRegularFuncBody(writer, func, spec, libStem, libPkg, enumNames, structNames, recordNames);
  }

  _emitJniPropertyBridges(writer, spec, enumNames, structNames);
  _emitJniStreamBridges(writer, spec, enumNames, structNames);
  final variantNames = spec.variants.map((v) => v.name).toSet();
  _emitJniCallbackInvokers(writer, spec, enumNames, structNames, recordNames, variantNames: variantNames);
  _emitJniInitializeAndPostHelpers(writer, spec, libStem, libPkg, enumNames, structNames, recordNames);

  writer.line('} // extern "C"');
}
