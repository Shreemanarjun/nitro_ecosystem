part of '../cpp_bridge_generator.dart';

// `JNI_OnLoad`-time setup (class and method-id caches) and the
// `post*ToPort` helpers @nitroNativeAsync completions go through.

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
      jniSig = _jniNativeAsyncSig(func.params, enumNames, structNames, libPkg, variantNames: initVariantNames, customTypeNames: initCustomTypeNames);
    } else {
      jniSig = _jniSig(func.params, func.returnType, enumNames, structNames, libPkg, zeroCopyReturn: func.zeroCopyReturn, isResult: func.isResult, variantNames: initVariantNames, customTypeNames: initCustomTypeNames);
    }
    writer.line('        g_mid_${func.dartName}_call = env->GetStaticMethodID(g_bridgeClass, "${func.dartName}_call", "$jniSig");');
    writer.line('        if (!g_mid_${func.dartName}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${func.dartName}_call sig=$jniSig"); }');
  }
  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(prop.type.name);
    final isVariantPropInit = spec.isVariantName(bareTypeName(prop.type.name));
    if (prop.hasGetter) {
      final isNullablePrimPropInit = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?';
      // Nullable primitives and variants use [B (ByteArray) encoding; 'J' prefix for instanceId.
      final isCustomTypePropGet = initCustomTypeNames.contains(bareTypeName(prop.type.name));
      final jniRetSig = isNullablePrimPropInit
          ? '[B'
          : isEnum
          ? 'J'
          : isVariantPropInit
          ? '[B'
          : isCustomTypePropGet
          ? '[B'
          : _jniSigType(prop.type.name);
      writer.line('        g_mid_${prop.getSymbol}_call = env->GetStaticMethodID(g_bridgeClass, "${prop.getSymbol}_call", "(J)$jniRetSig");');
      writer.line('        if (!g_mid_${prop.getSymbol}_call && env->ExceptionCheck()) { env->ExceptionClear(); LOGE("Method not found: ${prop.getSymbol}_call sig=(J)$jniRetSig"); }');
    }
    if (prop.hasSetter) {
      final isNullablePrimPropInit2 = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?';
      // Nullable primitives and variants use [B (ByteArray) encoding; 'J' prefix for instanceId.
      final isCustomTypePropSet = initCustomTypeNames.contains(bareTypeName(prop.type.name));
      final jniParamSig = isNullablePrimPropInit2
          ? '[B'
          : isEnum
          ? 'J'
          : isVariantPropInit
          ? '[B'
          : isCustomTypePropSet
          ? '[B'
          : _jniSigType(prop.type.name);
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
      final recName = bareTypeName(stream.itemType.name);
      if (cachedRecordClasses.add(recName)) {
        final jniRecClass = '${spec.jniPackageOf(recName)}/$recName';
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
      final jniClass = '${spec.jniPackageOf(st.name)}/${st.name}';

      final ctorSig =
          '(${st.fields.map((f) {
            final isEnum = enumNames.contains(bareTypeName(f.type.name));
            final isNestedStruct = structNames.contains(bareTypeName(f.type.name));
            if (StructGenerator.needsHasValue(f, structNames)) return _structFieldJniSig(f, structNames, _jniSigType);
            if (isEnum) return 'J';
            if (_isZeroCopy(st, f.name)) return 'Ljava/nio/ByteBuffer;';
            if (isNestedStruct) return 'L${spec.jniPackageOf(bareTypeName(f.type.name))}/${bareTypeName(f.type.name)};';
            return _jniSigType(f.type.name);
          }).join('')})V';
      writer.line('    {');
      writer.line('        jclass local_cls_${st.name} = env->FindClass("$jniClass");');
      writer.line('        if (local_cls_${st.name} != nullptr) {');
      writer.line('            g_cls_${st.name} = (jclass)env->NewGlobalRef(local_cls_${st.name});');
      writer.line('            env->DeleteLocalRef(local_cls_${st.name});');
      writer.line('            g_ctor_${st.name} = env->GetMethodID(g_cls_${st.name}, "<init>", "$ctorSig");');
      for (final f in st.fields) {
        final isEnum = enumNames.contains(bareTypeName(f.type.name));
        final isZeroCopy = _isZeroCopy(st, f.name);
        final isNestedStruct = structNames.contains(bareTypeName(f.type.name));
        final sig = StructGenerator.needsHasValue(f, structNames)
            ? _structFieldJniSig(f, structNames, _jniSigType)
            : (isEnum ? 'J' : (isZeroCopy ? 'Ljava/nio/ByteBuffer;' : (isNestedStruct ? 'L${spec.jniPackageOf(bareTypeName(f.type.name))}/${bareTypeName(f.type.name)};' : _jniSigType(f.type.name))));
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

    // postOptXxxToPort — nullable prim NativeAsync return helpers.
    // Allocates a packed NitroOptXxx struct on the native heap (9 bytes for int64/float64,
    // 2 bytes for bool), fills hasValue + value, posts address as kInt64.
    // Dart side decodes via Pointer<NitroOptXxx>.fromAddress(raw as int) and frees.
    final jniPostOptInt64 = _jniMethodName(spec.lib, spec.dartClassName, 'postOptInt64ToPort');
    final jniPostOptFloat64 = _jniMethodName(spec.lib, spec.dartClassName, 'postOptFloat64ToPort');
    final jniPostOptBool = _jniMethodName(spec.lib, spec.dartClassName, 'postOptBoolToPort');

    // postOptInt64ToPort: int? / uint64? / DateTime? NativeAsync returns
    writer.line('JNIEXPORT void JNICALL $jniPostOptInt64(JNIEnv*, jclass, jlong dartPort, jlong value, jboolean hasValue) {');
    writer.line('    uint8_t* buf = (uint8_t*)malloc(9);');
    writer.line('    buf[0] = hasValue ? 1 : 0;');
    writer.line('    if (hasValue) { memcpy(buf + 1, &value, 8); }');
    writer.line('    Dart_CObject obj;');
    writer.line('    obj.type = Dart_CObject_kInt64;');
    writer.line('    obj.value.as_int64 = (int64_t)(uintptr_t)buf;');
    writer.line('    Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
    writer.line('}');
    writer.blankLine();

    // postOptFloat64ToPort: double? NativeAsync returns
    writer.line('JNIEXPORT void JNICALL $jniPostOptFloat64(JNIEnv*, jclass, jlong dartPort, jdouble value, jboolean hasValue) {');
    writer.line('    uint8_t* buf = (uint8_t*)malloc(9);');
    writer.line('    buf[0] = hasValue ? 1 : 0;');
    writer.line('    if (hasValue) { memcpy(buf + 1, &value, 8); }');
    writer.line('    Dart_CObject obj;');
    writer.line('    obj.type = Dart_CObject_kInt64;');
    writer.line('    obj.value.as_int64 = (int64_t)(uintptr_t)buf;');
    writer.line('    Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
    writer.line('}');
    writer.blankLine();

    // postOptBoolToPort: bool? NativeAsync returns (2-byte NitroOptBool)
    writer.line('JNIEXPORT void JNICALL $jniPostOptBool(JNIEnv*, jclass, jlong dartPort, jboolean value, jboolean hasValue) {');
    writer.line('    uint8_t* buf = (uint8_t*)malloc(2);');
    writer.line('    buf[0] = hasValue ? 1 : 0;');
    writer.line('    buf[1] = value ? 1 : 0;');
    writer.line('    Dart_CObject obj;');
    writer.line('    obj.type = Dart_CObject_kInt64;');
    writer.line('    obj.value.as_int64 = (int64_t)(uintptr_t)buf;');
    writer.line('    Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
    writer.line('}');
    writer.blankLine();

    // postBytesToPort: @HybridRecord / list-record NativeAsync returns.
    // Copies the Kotlin-encoded [4B len][payload] ByteArray into a malloc'd
    // native buffer (mirrors the sync-path record-return copy) and posts its
    // address as kInt64 — Dart decodes via Pointer<Uint8>.fromAddress and frees.
    // A null ByteArray (nullable record with no value) posts address 0
    // (nullptr) as kInt64 — NOT Dart_CObject_kNull — matching how the Dart
    // unpack for nullable records always expects a pointer-typed kInt64.
    final jniPostBytes = _jniMethodName(spec.lib, spec.dartClassName, 'postBytesToPort');
    writer.line('JNIEXPORT void JNICALL $jniPostBytes(JNIEnv* env, jclass, jlong dartPort, jbyteArray value) {');
    writer.line('    Dart_CObject obj;');
    writer.line('    obj.type = Dart_CObject_kInt64;');
    writer.line('    if (value == nullptr) {');
    writer.line('        obj.value.as_int64 = 0;');
    writer.line('    } else {');
    writer.line('        jsize len = env->GetArrayLength(value);');
    writer.line('        uint8_t* buf = (uint8_t*)malloc(len);');
    writer.line('        env->GetByteArrayRegion(value, 0, len, (jbyte*)buf);');
    writer.line('        obj.value.as_int64 = (int64_t)(uintptr_t)buf;');
    writer.line('    }');
    writer.line('    Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
    writer.line('}');
    writer.blankLine();

    // post${Struct}ToPort: bare @HybridStruct NativeAsync returns — one
    // helper per struct type actually used in a native-async return
    // position. Reuses the existing pack_${struct}_from_jni conversion
    // (already generated for every struct, for the sync-return/stream/
    // callback paths) to build a native copy, then posts its address —
    // same null-as-address-0 convention as postBytesToPort above.
    final structReturnNames = spec.functions.where((f) => f.isNativeAsync).map((f) => bareTypeName(f.returnType.name)).where((n) => spec.structs.any((s) => s.name == n)).toSet();
    for (final sn in structReturnNames) {
      final jniPostStruct = _jniMethodName(spec.lib, spec.dartClassName, 'post${sn}ToPort');
      writer.line('JNIEXPORT void JNICALL $jniPostStruct(JNIEnv* env, jclass, jlong dartPort, jobject value) {');
      writer.line('    Dart_CObject obj;');
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    if (value == nullptr) {');
      writer.line('        obj.value.as_int64 = 0;');
      writer.line('    } else {');
      writer.line('        $sn* result = ($sn*)malloc(sizeof($sn));');
      writer.line('        *result = pack_${sn}_from_jni(env, value);');
      writer.line('        obj.value.as_int64 = (int64_t)(uintptr_t)result;');
      writer.line('    }');
      writer.line('    Dart_PostCObject_DL((Dart_Port)dartPort, &obj);');
      writer.line('}');
      writer.blankLine();
    }

    // reportNativeAsyncError: writes a thrown Kotlin exception's name/message
    // into the fresh-per-call NitroError* whose address Dart passed down as
    // errPtr (see NitroRuntime.throwIfOutParamErrorAndFree). Called from the
    // native-async trampoline's catch block BEFORE it posts, so the port
    // still fires exactly once either way — Dart checks hasError first and
    // throws before ever decoding the posted value.
    final jniReportError = _jniMethodName(spec.lib, spec.dartClassName, 'reportNativeAsyncError');
    writer.line('JNIEXPORT void JNICALL $jniReportError(JNIEnv* env, jclass, jlong errPtr, jstring name, jstring message) {');
    writer.line('    NitroError* err = (NitroError*)(uintptr_t)errPtr;');
    writer.line('    if (err == nullptr) { return; }');
    writer.line('    err->hasError = 1;');
    writer.line('    if (name != nullptr) {');
    writer.line('        const char* cName = env->GetStringUTFChars(name, nullptr);');
    writer.line('        err->name = strdup(cName);');
    writer.line('        env->ReleaseStringUTFChars(name, cName);');
    writer.line('    } else {');
    writer.line('        err->name = strdup("NativeException");');
    writer.line('    }');
    writer.line('    if (message != nullptr) {');
    writer.line('        const char* cMsg = env->GetStringUTFChars(message, nullptr);');
    writer.line('        err->message = strdup(cMsg);');
    writer.line('        env->ReleaseStringUTFChars(message, cMsg);');
    writer.line('    } else {');
    writer.line('        err->message = strdup("An unknown native exception occurred.");');
    writer.line('    }');
    writer.line('    err->code = nullptr;');
    writer.line('    err->stackTrace = nullptr;');
    writer.line('}');
    writer.blankLine();
  }
}
