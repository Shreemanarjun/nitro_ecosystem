part of '../cpp_bridge_generator.dart';

String _paramTypeToC(String dartType, Set<String> structNames) => CppBridgeGenerator._paramTypeToC(dartType, structNames);

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
  String libPkg,
) => CppBridgeGenerator._jniSig(params, returnType, enumNames, structNames, libPkg);

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
      writer.line('    if (env == nullptr) return;');
      writer.line('    jmethodID methodId = g_mid_${func.dartName}_call;');
      writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${func.dartName}_call sig=$jniNativeAsyncSig"); return; }');
      writer.blankLine();
      writer.line('    ${libStem}_clear_error();');
      writer.line('    if (env->PushLocalFrame(16) != 0) return;');

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
        } else {
          callArgsList.add(p.name);
        }
      }
      callArgsList.add('(jlong)dart_port');
      final callArgs = callArgsList.join(', ');
      writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, $callArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    final isEnum = enumNames.contains(func.returnType.name);
    final isStruct = structNames.contains(func.returnType.name);
    final isRecord = func.returnType.isRecord && !func.returnType.isMap;
    final isTypedData = func.returnType.isTypedData;
    // For enum returns: bridge returns Long (nativeValue); C returns int64_t
    // For struct returns: bridge returns jobject; C packs to C struct via malloc
    // For record returns: bridge returns ByteArray; C copies bytes to malloc'd buffer
    // For TypedData returns: bridge returns a JVM primitive array; C copies it
    // into a malloc-owned [int64 byte length][payload bytes] envelope.
    final cReturnType = isEnum
        ? 'int64_t'
        : isTypedData
        ? 'uint8_t*'
        : _typeToC(func.returnType.name);
    final paramsDeclParts = <String>[];
    for (final p in func.params) {
      paramsDeclParts.add('${_paramTypeToC(p.type.name, structNames)} ${p.name}');
      if (p.type.isTypedData) paramsDeclParts.add('int64_t ${p.name}_length');
    }
    final paramsDecl = paramsDeclParts.join(', ');

    writer.line(
      '$cReturnType ${func.cSymbol}(${paramsDecl.isEmpty ? 'void' : paramsDecl}) {',
    );
    writer.line('    JNIEnv* env = GetEnv();');
    if (func.returnType.name == 'void') {
      writer.line('    if (env == nullptr) return;');
    } else {
      writer.line(
        '    if (env == nullptr) return ${_defaultValue(cReturnType)};',
      );
    }
    writer.line('    jmethodID methodId = g_mid_${func.dartName}_call;');
    final jniSigForLog = _jniSig(func.params, func.returnType, enumNames, structNames, libPkg);
    if (func.returnType.name == 'void') {
      writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${func.dartName}_call sig=$jniSigForLog"); return; }');
    } else {
      writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${func.dartName}_call sig=$jniSigForLog"); return ${_defaultValue(cReturnType)}; }');
    }
    writer.blankLine();
    writer.line('    ${libStem}_clear_error();');
    if (func.returnType.name == 'void') {
      writer.line('    if (env->PushLocalFrame(16) != 0) return;');
    } else {
      writer.line('    if (env->PushLocalFrame(16) != 0) return ${_defaultValue(cReturnType)};');
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
    } else if (func.returnType.name == 'double' || func.returnType.name == 'double?') {
      writer.line(
        '    double res = env->CallStaticDoubleMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0.0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    } else if (func.returnType.name == 'int' || func.returnType.name == 'int?') {
      writer.line(
        '    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    } else if (func.returnType.name == 'bool' || func.returnType.name == 'bool?') {
      writer.line(
        '    bool res = env->CallStaticBooleanMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return false;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    } else if (func.returnType.name == 'String' || func.returnType.name == 'String?') {
      writer.line(
        '    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
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
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    } else if (isStruct) {
      // Bridge returns the Kotlin data class; pack it to C struct via malloc
      final stName = func.returnType.name;
      writer.line(
        '    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
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
    } else if (isRecord) {
      // Bridge returns ByteArray (serialized @HybridRecord / List<@HybridRecord>)
      // Copy bytes to malloc'd buffer and return as void* for Dart RecordReader
      writer.line('    jbyteArray jarr = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
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
      final ops = _typedDataJniOps(func.returnType.name);
      final elemSize = _typedDataElementSizeExpr(func.returnType.name);
      writer.line('    ${ops[0]} jarr = (${ops[0]})env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred());');
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
    } else {
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return ${_defaultValue(cReturnType)};');
    }
    if (func.returnType.name == 'void') {
      writer.line('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); }');
    }
    writer.line('}');
    writer.blankLine();
  }

  // ── Properties ────────────────────────────────────────────────────────────
  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(prop.type.name);
    final cType = isEnum ? 'int64_t' : _typeToC(prop.type.name);

    if (prop.hasGetter) {
      writer.line('$cType ${prop.getSymbol}(void) {');
      writer.line('    JNIEnv* env = GetEnv();');
      writer.line('    if (env == nullptr) return ${_defaultValue(cType)};');
      writer.line('    jmethodID methodId = g_mid_${prop.getSymbol}_call;');
      final jniGetSig = '()${isEnum ? 'J' : _jniSigType(prop.type.name)}';
      writer.line(
        '    if (methodId == nullptr) { LOGE("Method not found: ${prop.getSymbol}_call sig=$jniGetSig"); return ${_defaultValue(cType)}; }',
      );
      writer.line('    if (env->PushLocalFrame(8) != 0) return ${_defaultValue(cType)};');
      if (prop.type.name == 'double') {
        writer.line(
          '    double res = env->CallStaticDoubleMethod(g_bridgeClass, methodId);',
        );
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return res;');
      } else if (prop.type.name == 'int' || isEnum) {
        writer.line(
          '    $cType res = ($cType)env->CallStaticLongMethod(g_bridgeClass, methodId);',
        );
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return res;');
      } else if (prop.type.name == 'bool') {
        writer.line(
          '    bool res = env->CallStaticBooleanMethod(g_bridgeClass, methodId);',
        );
        writer.line('    env->PopLocalFrame(nullptr);');
        writer.line('    return res;');
      } else if (prop.type.name == 'String') {
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
      final paramCType = isEnum ? 'int64_t' : _typeToC(prop.type.name);
      writer.line('void ${prop.setSymbol}($paramCType value) {');
      writer.line('    JNIEnv* env = GetEnv();');
      writer.line('    if (env == nullptr) return;');
      writer.line('    jmethodID methodId = g_mid_${prop.setSymbol}_call;');
      final jniSetSig = '(${isEnum ? 'J' : _jniSigType(prop.type.name)})V';
      writer.line(
        '    if (methodId == nullptr) { LOGE("Method not found: ${prop.setSymbol}_call sig=$jniSetSig"); return; }',
      );
      writer.line('    if (env->PushLocalFrame(8) != 0) return;');
      if (prop.type.name == 'String') {
        writer.line('    jstring jval = env->NewStringUTF(value);');
        writer.line(
          '    env->CallStaticVoidMethod(g_bridgeClass, methodId, jval);',
        );
      } else if (structNames.contains(prop.type.name)) {
        writer.line('    jobject jval = unpack_${prop.type.name}_to_jni(env, (const ${prop.type.name}*)value);');
        writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, jval);');
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
    writer.line('    if (env == nullptr) return;');
    writer.line('    jmethodID methodId = g_mid_${stream.registerSymbol}_call;');
    writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${stream.registerSymbol}_call sig=(J)V"); return; }');
    writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);');
    writer.line('}');
    writer.blankLine();
    writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
    writer.line('    JNIEnv* env = GetEnv();');
    writer.line('    if (env == nullptr) return;');
    writer.line('    jmethodID methodId = g_mid_${stream.releaseSymbol}_call;');
    writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${stream.releaseSymbol}_call sig=(J)V"); return; }');
    writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);');
    writer.line('}');
    writer.blankLine();

    final jniEmit = _jniMethodName(
      spec.lib,
      spec.dartClassName,
      'emit_${stream.dartName}',
    );
    writer.line(
      'JNIEXPORT void JNICALL $jniEmit(JNIEnv* env, jobject thiz, jlong dartPort, ${_jniSigTypeC(stream.itemType.name)} item) {',
    );
    writer.line('    Dart_CObject obj;');
    if (stream.itemType.name == 'double') {
      writer.line('    obj.type = Dart_CObject_kDouble;');
      writer.line('    obj.value.as_double = item;');
    } else if (stream.itemType.name == 'int') {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = item;');
    } else if (stream.itemType.name == 'bool') {
      writer.line('    obj.type = Dart_CObject_kBool;');
      writer.line('    obj.value.as_bool = item;');
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
      writer.line('        return;');
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
      writer.line('        return;');
      writer.line('    }');
      writer.line('    jbyteArray encoded = (jbyteArray)env->CallObjectMethod(item, g_mid_${recName}_encode);');
      writer.line('    if (encoded == nullptr) { LOGE("$recName.encode() returned null"); return; }');
      writer.line('    jsize len = env->GetArrayLength(encoded);');
      writer.line('    uint8_t* buf = (uint8_t*)malloc((size_t)len);');
      writer.line('    env->GetByteArrayRegion(encoded, 0, len, (jbyte*)buf);');
      writer.line('    env->DeleteLocalRef(encoded);');
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (intptr_t)buf;');
    } else if (enumNames.contains(stream.itemType.name.replaceFirst('?', ''))) {
      writer.line('    // item is a jobject (Kotlin enum). Extract its nativeValue Long field.');
      writer.line('    jclass enumCls = env->GetObjectClass(item);');
      writer.line('    jfieldID fid = enumCls ? env->GetFieldID(enumCls, "nativeValue", "J") : nullptr;');
      writer.line('    if (fid == nullptr) { LOGE("emit_${stream.dartName}: cannot find nativeValue on ${stream.itemType.name}"); if (enumCls) env->DeleteLocalRef(enumCls); return; }');
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (int64_t)env->GetLongField(item, fid);');
      writer.line('    env->DeleteLocalRef(enumCls);');
    } else {
      writer.line('    obj.type = Dart_CObject_kNull;');
    }
    writer.line('    Dart_PostCObject_DL(dartPort, &obj);');
    writer.line('}');
    writer.blankLine();
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
  for (final func in spec.functions) {
    final String jniSig;
    if (func.isNativeAsync) {
      jniSig = _jniNativeAsyncSig(func.params, enumNames, structNames, libPkg);
    } else {
      jniSig = _jniSig(func.params, func.returnType, enumNames, structNames, libPkg);
    }
    writer.line('        g_mid_${func.dartName}_call = env->GetStaticMethodID(g_bridgeClass, "${func.dartName}_call", "$jniSig");');
  }
  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(prop.type.name);
    if (prop.hasGetter) {
      final jniRetSig = isEnum ? 'J' : _jniSigType(prop.type.name);
      writer.line('        g_mid_${prop.getSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${prop.getSymbol}_call", "()$jniRetSig");');
    }
    if (prop.hasSetter) {
      final jniParamSig = isEnum ? 'J' : _jniSigType(prop.type.name);
      writer.line('        g_mid_${prop.setSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${prop.setSymbol}_call", "($jniParamSig)V");');
    }
  }
  for (final stream in spec.streams) {
    writer.line('        g_mid_${stream.registerSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${stream.registerSymbol}_call", "(J)V");');
    writer.line('        g_mid_${stream.releaseSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${stream.releaseSymbol}_call", "(J)V");');
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
