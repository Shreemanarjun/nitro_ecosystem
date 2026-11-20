part of '../cpp_bridge_generator.dart';

// JNI glue for one method: the sync / @nitroAsync body (parameters to JNI
// values, the call, the return back to C) and the @nitroNativeAsync body.

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
    if (p.type.isFunction) {
      paramsDeclParts.add(_callbackParamToC(p, enumNames, structNames: structNames, recordNames: recordNames));
      continue;
    }
    // Mirrors _emitJniRegularFuncBody's declaration loop: enum params must be
    // int64_t (rawValue), not void* — void* cast of the -1 null sentinel is
    // implementation-defined and may not equal int64_t -1 on some compilers.
    final paramBase = bareTypeName(p.type.name);
    final isEnumParam = enumNames.contains(paramBase);
    final String cParamType;
    if (p.type.isAnyNativeObject) {
      cParamType = 'int64_t';
    } else if (spec.isCustomTypeName(paramBase)) {
      cParamType = 'const uint8_t*';
    } else if (p.type.isNullableNitroPrim) {
      cParamType = 'const uint8_t*';
    } else {
      cParamType = isEnumParam ? 'int64_t' : _paramTypeToC(p.type.name, structNames);
    }
    paramsDeclParts.add('$cParamType ${p.name}');
    if (p.type.isTypedData) paramsDeclParts.add('size_t ${p.name}_length');
  }
  paramsDeclParts.add('NitroError* _nitro_err');
  paramsDeclParts.add('int64_t dart_port');
  final paramsDecl = paramsDeclParts.join(', ');
  final variantNames = spec.variants.map((v) => v.name).toSet();
  final customTypeNames = spec.customTypes.map((c) => c.name).toSet();
  final jniNativeAsyncSig = _jniNativeAsyncSig(func.params, enumNames, structNames, libPkg, variantNames: variantNames, customTypeNames: customTypeNames);

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
    switch (pt) {
      case 'String':
        writer.line('    jstring j_${p.name} = env->NewStringUTF(${p.name});');
        callArgsList.add('j_${p.name}');
      case 'String?':
        writer.line('    jstring j_${p.name} = (${p.name} != nullptr) ? env->NewStringUTF(${p.name}) : nullptr;');
        callArgsList.add('j_${p.name}');
      case _ when structNames.contains(bareTypeName(pt)):
        final baseType = bareTypeName(pt);
        if (pt.endsWith('?')) {
          writer.line('    jobject jobj_${p.name} = (${p.name} != nullptr) ? unpack_${baseType}_to_jni(env, (const $baseType*)${p.name}) : nullptr;');
        } else {
          writer.line('    jobject jobj_${p.name} = unpack_${baseType}_to_jni(env, (const $baseType*)${p.name});');
        }
        callArgsList.add('jobj_${p.name}');
      case _ when p.zeroCopy && p.type.isTypedData:
        _emitZeroCopyTypedDataParam(
          writer,
          p,
          returnExpr: null,
        );
        callArgsList.add('j_${p.name}');
      case _ when !p.zeroCopy && p.type.isTypedData:
        // Element type from the bare name: `Float32List?` must build a
        // jfloatArray (the JNI signature says [F), not the byte-array default.
        final ops = _typedDataJniOps(bareTypeName(pt));
        if (pt.endsWith('?')) {
          writer.line('    ${ops[0]} j_${p.name} = nullptr;');
          writer.line('    if (${p.name} != nullptr) {');
          writer.line('        j_${p.name} = env->${ops[1]}((jsize)${p.name}_length);');
          writer.line('        env->${ops[2]}(j_${p.name}, 0, (jsize)${p.name}_length, (const ${ops[3]}*)${p.name});');
          writer.line('    }');
        } else {
          writer.line('    ${ops[0]} j_${p.name} = env->${ops[1]}((jsize)${p.name}_length);');
          writer.line('    env->${ops[2]}(j_${p.name}, 0, (jsize)${p.name}_length, (const ${ops[3]}*)${p.name});');
        }
        callArgsList.add('j_${p.name}');
      case _ when p.type.isNativeHandle:
        callArgsList.add('(jlong)${p.name}');
      case _ when p.type.isAnyNativeObject:
        // AnyNativeObject: pass as Long; nullable: -1 sentinel for null.
        callArgsList.add('(jlong)${p.name}');
      case _ when spec.isCustomTypeName(bareTypeName(pt)):
        // @NitroCustomType: encode raw bytes as ByteArray — mirrors
        // _emitJniRegularFuncBody's equivalent branch.
        final ct = spec.customTypeByName(bareTypeName(pt))!;
        if (p.type.isNullable || pt.endsWith('?')) {
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
      case _ when p.type.isFunction:
        callArgsList.add('(jlong)${p.name}');
      case _ when p.type.isAnyMap || p.type.isMap:
        // NitroAnyMap / Map<String, T>: binary uint8_t* (with 4-byte length prefix) → jbyteArray.
        writer.line('    jsize j_${p.name}_len = (jsize)(*((int32_t*)${p.name} + 0)) + 4;');
        writer.line('    jbyteArray j_${p.name} = env->NewByteArray(j_${p.name}_len);');
        writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, j_${p.name}_len, (const jbyte*)${p.name});');
        callArgsList.add('j_${p.name}');
      case _ when p.type.isNullableNitroPrim:
        // Nullable prim param: Dart sends a packed NitroOptXxx struct as const uint8_t*.
        // Wrap in jbyteArray (Kotlin ByteArray) to pass over JNI.
        // bool? uses 2-byte NitroOptBool; all other nullable prims use 9-byte layout.
        final sz = p.type.name == 'bool?' ? 2 : 9;
        writer.line('    jbyteArray j_${p.name} = env->NewByteArray($sz);');
        writer.line('    if (${p.name} != nullptr) { env->SetByteArrayRegion(j_${p.name}, 0, $sz, (const jbyte*)${p.name}); }');
        callArgsList.add('j_${p.name}');
      case _ when p.type.isRecord:
        // @HybridRecord / @NitroTuple / List<@HybridRecord/@HybridEnum/@NitroVariant/
        // primitive> params arrive as void* (Dart Pointer<Uint8>), format
        // [4-byte payload_len][payload_bytes] — mirrors _emitJniRegularFuncBody's
        // equivalent branch (previously missing here: these params were passed
        // as a raw pointer where the JNI method signature expects a jbyteArray).
        final isNullableRecord = p.type.isNullable || pt.endsWith('?');
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
      case _ when spec.isVariantName(bareTypeName(pt)):
        // @NitroVariant param: same wire format as @HybridRecord — mirrors
        // _emitJniRegularFuncBody's equivalent branch.
        writer.line('    int32_t ${p.name}_var_len = *((const int32_t*)${p.name});');
        writer.line('    int32_t ${p.name}_var_total = ${p.name}_var_len + 4;');
        writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)${p.name}_var_total);');
        writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_var_total, (const jbyte*)${p.name});');
        callArgsList.add('j_${p.name}');
      default:
        callArgsList.add(p.name);
    }
  }
  callArgsList.add('(jlong)(uintptr_t)_nitro_err');
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

/// Number-only calls (every argument a JNI primitive, result a primitive or
/// void) create no JNI local references on the success path, so the
/// `PushLocalFrame`/`PopLocalFrame` pair around them is pure overhead on
/// every call. Their body is emitted as usual and the frame is then moved
/// into the exception branch, which is the only place references appear
/// (the throwable and the strings the reporter reads from it).
const _jniNumberReturns = {'void', 'int', 'double', 'bool', 'uint64', 'DateTime', 'float', 'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'intptr', 'size'};
const _jniNumberParams = {'int', 'double', 'bool', 'uint64', 'DateTime', 'float', 'int8', 'uint8', 'int16', 'uint16', 'int32', 'uint32', 'intptr', 'size'};

bool _jniNumbersOnly(BridgeFunction func, BridgeSpec spec) {
  if (func.isResult || func.zeroCopyReturn || !_jniNumberReturns.contains(func.returnType.name)) return false;
  return func.params.every((p) => !p.zeroCopy && (_jniNumberParams.contains(p.type.name) || p.type.isNativeHandle || spec.isEnumName(p.type.name)));
}

void _emitJniRegularFuncBodyFramed(
  CodeWriter writer,
  BridgeFunction func,
  BridgeSpec spec,
  String libStem,
  String libPkg,
  Set<String> enumNames,
  Set<String> structNames,
  Set<String> recordNames,
) {
  if (!_jniNumbersOnly(func, spec)) {
    _emitJniRegularFuncBody(writer, func, spec, libStem, libPkg, enumNames, structNames, recordNames);
    return;
  }
  final sub = CodeWriter();
  _emitJniRegularFuncBody(sub, func, spec, libStem, libPkg, enumNames, structNames, recordNames);
  const report = 'nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);';
  final out = <String>[];
  for (final line in sub.toString().split('\n')) {
    final t = line.trim();
    if (t.startsWith('if (env->PushLocalFrame(') || t == 'env->PopLocalFrame(nullptr);') continue;
    if (t == report) {
      final ind = line.substring(0, line.indexOf(t));
      out.add('${ind}env->PushLocalFrame(8);');
      out.add(line);
      out.add('${ind}env->PopLocalFrame(nullptr);');
      continue;
    }
    out.add(line);
  }
  writer.raw(out.join('\n'));
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
  final isEnum = enumNames.contains(bareTypeName(func.returnType.name));
  final isStruct = structNames.contains(bareTypeName(func.returnType.name));
  final isRecord = func.returnType.isRecord && !func.returnType.isMap;
  final isMap = func.returnType.isMap;
  final isAnyMap = func.returnType.isAnyMap;
  final isTypedData = func.returnType.isTypedData;
  // For enum returns: bridge returns Long (nativeValue); C returns int64_t
  // For struct returns: bridge returns jobject; C packs to C struct via malloc
  // For record returns: bridge returns ByteArray; C copies bytes to malloc'd buffer
  // For TypedData returns: bridge returns a JVM primitive array; C copies it
  // into a malloc-owned [int64 byte length][payload bytes] envelope.
  final retBase = bareTypeName(func.returnType.name);
  final isVariantReturn = spec.isVariantName(retBase);
  final isAnyNativeObjectReturn = func.returnType.isAnyNativeObject;
  final isCustomTypeReturn = spec.isCustomTypeName(retBase);
  // Nullable prim returns: malloc'd uint8_t* pointer (Dart casts to Pointer<NitroOptXxx> and frees).
  const narrowIntNullables = {'int8?', 'int16?', 'int32?', 'uint8?', 'uint16?', 'uint32?', 'intptr?', 'size?'};
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
      : narrowIntNullables.contains(func.returnType.name)
      ? 'uint8_t*'
      : func.returnType.name == 'float?'
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
      paramsDeclParts.add(_callbackParamToC(p, enumNames, structNames: structNames, recordNames: recordNames));
      continue;
    }
    // Enum params: must be int64_t (rawValue) not void* — void* cast of -1 (null
    // sentinel) is implementation-defined and may not equal int64_t -1 on some
    // Android/AArch64 compilers. Use int64_t to guarantee correct bit pattern.
    final paramBase = bareTypeName(p.type.name);
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
    if (p.type.isTypedData) paramsDeclParts.add('size_t ${p.name}_length');
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
    switch (pt) {
      case 'String':
        writer.line('    jstring j_${p.name} = env->NewStringUTF(${p.name});');
        callArgsList.add('j_${p.name}');
      case 'String?':
        writer.line('    jstring j_${p.name} = (${p.name} != nullptr) ? env->NewStringUTF(${p.name}) : nullptr;');
        callArgsList.add('j_${p.name}');
      case _ when structNames.contains(bareTypeName(pt)):
        final baseType = bareTypeName(pt);
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
      case _ when p.zeroCopy && p.type.isTypedData:
        _emitZeroCopyTypedDataParam(
          writer,
          p,
          returnExpr: func.returnType.name == 'void' ? null : _defaultValue(cReturnType),
        );
        callArgsList.add('j_${p.name}');
      case _ when !p.zeroCopy && p.type.isTypedData:
        // Element type from the bare name: `Float32List?` must build a
        // jfloatArray (the JNI signature says [F), not the byte-array default.
        final ops = _typedDataJniOps(bareTypeName(pt));
        if (pt.endsWith('?')) {
          writer.line('    ${ops[0]} j_${p.name} = nullptr;');
          writer.line('    if (${p.name} != nullptr) {');
          writer.line('        j_${p.name} = env->${ops[1]}((jsize)${p.name}_length);');
          writer.line('        env->${ops[2]}(j_${p.name}, 0, (jsize)${p.name}_length, (const ${ops[3]}*)${p.name});');
          writer.line('    }');
        } else {
          writer.line('    ${ops[0]} j_${p.name} = env->${ops[1]}((jsize)${p.name}_length);');
          writer.line('    env->${ops[2]}(j_${p.name}, 0, (jsize)${p.name}_length, (const ${ops[3]}*)${p.name});');
        }
        callArgsList.add('j_${p.name}');
      case _ when p.type.isNativeHandle:
        callArgsList.add('(jlong)${p.name}');
      case _ when p.type.isAnyNativeObject:
        // AnyNativeObject: pass as Long; nullable: -1 sentinel for null
        callArgsList.add('(jlong)${p.name}');
      case _ when spec.isCustomTypeName(bareTypeName(p.type.name)):
        // @NitroCustomType: encode raw bytes as ByteArray
        final ct = spec.customTypeByName(bareTypeName(p.type.name))!;
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
      case _ when p.type.isFunction:
        callArgsList.add('(jlong)${p.name}');
      case _ when p.type.isAnyMap || p.type.isMap:
        // NitroAnyMap / Map<String, T>: binary uint8_t* (4-byte length prefix + payload) → jbyteArray.
        // A null map stays a null ByteArray.
        final (guard, indent) = p.type.isNullable || p.type.name.endsWith('?') ? ('if (${p.name} != nullptr) ', '') : ('', '    ');
        if (guard.isNotEmpty) {
          writer.line('    jbyteArray j_${p.name} = nullptr;');
          writer.line('    $guard{');
        }
        writer.line('    ${guard.isEmpty ? '' : '    '}int32_t ${p.name}_map_len = *((const int32_t*)${p.name}) + 4;');
        writer.line('    ${guard.isEmpty ? 'jbyteArray ' : '    '}j_${p.name} = env->NewByteArray((jsize)${p.name}_map_len);');
        writer.line('    ${guard.isEmpty ? '' : '    '}env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_map_len, (const jbyte*)${p.name});');
        if (guard.isNotEmpty) writer.line('    }');
        callArgsList.add('j_${p.name}');
      case _ when p.type.isNullableNitroPrim:
        // Nullable primitive: NitroOpt* struct pointer — [1B hasValue][N bytes value].
        // No length prefix; the struct size is fixed. Pass raw bytes to Kotlin as ByteArray.
        final structSize = p.type.name == 'bool?' ? 'sizeof(NitroOptBool)' : 'sizeof(NitroOptInt64)';
        writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)$structSize);');
        writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)$structSize, (const jbyte*)${p.name});');
        callArgsList.add('j_${p.name}');
      case _ when p.type.isRecord:
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
      case _ when spec.isVariantName(bareTypeName(pt)):
        // @NitroVariant param: Dart encodes as [4B len][1B tag][fields] via toNative(alloc).
        // Same wire format as @HybridRecord — pass the full buffer (prefix + payload) to Kotlin.
        writer.line('    int32_t ${p.name}_var_len = *((const int32_t*)${p.name});');
        writer.line('    int32_t ${p.name}_var_total = ${p.name}_var_len + 4;');
        writer.line('    jbyteArray j_${p.name} = env->NewByteArray((jsize)${p.name}_var_total);');
        writer.line('    env->SetByteArrayRegion(j_${p.name}, 0, (jsize)${p.name}_var_total, (const jbyte*)${p.name});');
        callArgsList.add('j_${p.name}');
      default:
        callArgsList.add(p.name);
    }
  }

  final callArgs = callArgsList.join(', ');
  final bridgeArgs = callArgs.isEmpty ? '' : ', $callArgs';

  switch (func.returnType.name) {
    case 'void':
      writer.line(
        '    env->CallStaticVoidMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    env->PopLocalFrame(nullptr);');
    case _ when func.isResult:
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
    case _ when func.returnType.isNativeHandle:
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
    case _ when isAnyNativeObjectReturn:
      // AnyNativeObject: Kotlin returns Long (instanceId); nullable: -1 = null sentinel
      writer.line('    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return ${func.returnType.isNullable ? "-1" : "0"};');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    case _ when isCustomTypeReturn:
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
    case 'double':
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
    case 'double?':
      // Kotlin returns NitroOptFloat64 bytes as ByteArray — malloc ptr, copy bytes, return pointer.
      writer.line('    jbyteArray jarr_nd = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_nd == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    uint8_t* nd_result = ${func.isAsync ? "(uint8_t*)malloc((size_t)sizeof(NitroOptFloat64))" : "_g_opt_ret"};');
      writer.line('    env->GetByteArrayRegion(jarr_nd, 0, (jsize)sizeof(NitroOptFloat64), (jbyte*)nd_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return nd_result;');
    case 'uint64':
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
    case 'uint64?':
      // uint64? — same JNI as int? — Kotlin returns NitroOptInt64 ByteArray (same bit layout).
      writer.line('    jbyteArray jarr_nu = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_nu == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    uint8_t* nu_result = ${func.isAsync ? "(uint8_t*)malloc((size_t)sizeof(NitroOptInt64))" : "_g_opt_ret"};');
      writer.line('    env->GetByteArrayRegion(jarr_nu, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)nu_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return nu_result;');
    case 'int':
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
    case 'int?':
      // Kotlin returns NitroOptInt64 bytes as ByteArray — malloc ptr, copy bytes, return pointer.
      writer.line('    jbyteArray jarr_ni = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_ni == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    uint8_t* ni_result = ${func.isAsync ? "(uint8_t*)malloc((size_t)sizeof(NitroOptInt64))" : "_g_opt_ret"};');
      writer.line('    env->GetByteArrayRegion(jarr_ni, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)ni_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return ni_result;');
    case 'DateTime':
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
    case 'DateTime?':
      // DateTime? — same JNI as int? — Kotlin returns NitroOptInt64 ByteArray.
      writer.line('    jbyteArray jarr_nd_ = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_nd_ == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    uint8_t* nd_result = ${func.isAsync ? "(uint8_t*)malloc((size_t)sizeof(NitroOptInt64))" : "_g_opt_ret"};');
      writer.line('    env->GetByteArrayRegion(jarr_nd_, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)nd_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return nd_result;');
    case _ when narrowIntNullables.contains(func.returnType.name):
      // Narrow integer nullable (int8?, int32?, intptr?, etc.) — same as int? (NitroOptInt64 ByteArray).
      writer.line('    jbyteArray jarr_nn = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_nn == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    uint8_t* nn_result = ${func.isAsync ? "(uint8_t*)malloc((size_t)sizeof(NitroOptInt64))" : "_g_opt_ret"};');
      writer.line('    env->GetByteArrayRegion(jarr_nn, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)nn_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return nn_result;');
    case 'float?':
      // float? — same JNI as double? — Kotlin returns NitroOptFloat64 ByteArray.
      writer.line('    jbyteArray jarr_nf = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_nf == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    uint8_t* nf_result = ${func.isAsync ? "(uint8_t*)malloc((size_t)sizeof(NitroOptFloat64))" : "_g_opt_ret"};');
      writer.line('    env->GetByteArrayRegion(jarr_nf, 0, (jsize)sizeof(NitroOptFloat64), (jbyte*)nf_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return nf_result;');
    case 'float':
      // float: Kotlin returns Float (jfloat); C returns float.
      writer.line(
        '    float res = env->CallStaticFloatMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0.0f;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    case 'int8' || 'uint8':
      // int8 / uint8: Kotlin returns Byte (jbyte); C returns int8_t / uint8_t.
      final cCast = func.returnType.name == 'uint8' ? 'uint8_t' : 'int8_t';
      writer.line(
        '    $cCast res = ($cCast)env->CallStaticByteMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    case 'int16' || 'uint16':
      // int16 / uint16: Kotlin returns Short (jshort); C returns int16_t / uint16_t.
      final cCast = func.returnType.name == 'uint16' ? 'uint16_t' : 'int16_t';
      writer.line(
        '    $cCast res = ($cCast)env->CallStaticShortMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    case 'int32' || 'uint32':
      // int32 / uint32: Kotlin returns Int (jint); C returns int32_t / uint32_t.
      final cCast = func.returnType.name == 'uint32' ? 'uint32_t' : 'int32_t';
      writer.line(
        '    $cCast res = ($cCast)env->CallStaticIntMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    case 'intptr' || 'size':
      // intptr / size: Kotlin returns Long (jlong); C returns intptr_t / size_t.
      final cCast = func.returnType.name == 'size' ? 'size_t' : 'intptr_t';
      writer.line(
        '    $cCast res = ($cCast)env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);',
      );
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return 0;');
      writer.line('    }');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return res;');
    case 'bool':
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
    case 'bool?':
      // Kotlin returns NitroOptBool bytes as ByteArray — malloc ptr, copy bytes, return pointer.
      writer.line('    jbyteArray jarr_nb = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);');
      writer.line('    if (env->ExceptionCheck()) {');
      writer.line('        nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err);');
      writer.line('        env->PopLocalFrame(nullptr);');
      writer.line('        return nullptr;');
      writer.line('    }');
      writer.line('    if (jarr_nb == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
      writer.line('    uint8_t* nb_result = ${func.isAsync ? "(uint8_t*)malloc((size_t)sizeof(NitroOptBool))" : "_g_opt_ret"};');
      writer.line('    env->GetByteArrayRegion(jarr_nb, 0, (jsize)sizeof(NitroOptBool), (jbyte*)nb_result);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return nb_result;');
    case 'String' || 'String?':
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
      writer.line(func.isAsync ? '    char* result = strdup(nativeStr);' : '    _g_str_ret = nativeStr; char* result = const_cast<char*>(_g_str_ret.c_str());');
      writer.line('    env->ReleaseStringUTFChars(jstr, nativeStr);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return result;');
    case _ when isEnum:
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
    case _ when isStruct:
      // Bridge returns the Kotlin data class; pack it to C struct via malloc.
      // Strip '?' from the type name — nullable structs use null pointer for null.
      final stName = bareTypeName(func.returnType.name);
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
      if (func.isAsync) {
        writer.line('    $stName* result = ($stName*)malloc(sizeof($stName));');
      } else {
        writer.line('    static thread_local $stName _g_ret_st;');
        writer.line('    $stName* result = &_g_ret_st;');
      }
      writer.line('    *result = pack_${stName}_from_jni(env, jobj);');
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return result;');
    case _ when isAnyMap || isMap:
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
    case _ when isRecord:
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
    case _ when isTypedData:
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
    case _ when isVariantReturn:
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
    default:
      writer.line('    env->PopLocalFrame(nullptr);');
      writer.line('    return ${_defaultValue(cReturnType)};');
  }
  if (func.returnType.name == 'void') {
    writer.line('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred(), _nitro_err); }');
  }
  writer.line('}');
  writer.blankLine();
}
