part of '../cpp_bridge_generator.dart';

// JNI glue for streams: register / release exports and the `emit_*`
// functions Kotlin calls for each item.

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
    _emitStreamCoalesce(writer, spec, 'coalesce', stream);
    writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, (jlong)instanceId, dart_port);');
    writer.line('}');
    writer.blankLine();
    writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
    writer.line('    JNIEnv* env = GetEnv();');
    writer.line('    if (env == nullptr) { return; }');

    writer.line('    jmethodID methodId = g_mid_${stream.releaseSymbol}_call;');
    writer.line('    if (methodId == nullptr) { LOGE("Method not found: ${stream.releaseSymbol}_call sig=(J)V"); return; }');
    writer.line('    env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);');
    _emitStreamCoalesce(writer, spec, 'uncoalesce');
    writer.line('}');
    writer.blankLine();

    final jniEmit = _jniMethodName(
      spec.lib,
      spec.dartClassName,
      'emit_${stream.dartName}',
    );
    if (stream.itemType.isTypedData) {
      // Kotlin passes a primitive array (null for a null item). The elements
      // are read under a critical section and copied by the post itself.
      writer.line('JNIEXPORT jboolean JNICALL $jniEmit(JNIEnv* env, jobject thiz, jlong dartPort, jobject item) {');
      writer.line('    Dart_CObject obj;');
      writer.line('    if (item == nullptr) {');
      writer.line('        obj.type = Dart_CObject_kNull;');
      writer.line('        return Dart_PostCObject_DL(dartPort, &obj) ? JNI_TRUE : JNI_FALSE;');
      writer.line('    }');
      writer.line('    const jsize _n = env->GetArrayLength((jarray)item);');
      writer.line('    void* _elems = env->GetPrimitiveArrayCritical((jarray)item, nullptr);');
      _emitTypedDataObj(writer, bareTypeName(stream.itemType.name), '_elems', '_n', '    ');
      writer.line('    const bool _ok = Dart_PostCObject_DL(dartPort, &obj);');
      writer.line('    env->ReleasePrimitiveArrayCritical((jarray)item, _elems, JNI_ABORT);');
      writer.line('    return _ok ? JNI_TRUE : JNI_FALSE;');
      writer.line('}');
      writer.blankLine();
      continue;
    }
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
      BridgeItemKind.intNullable || BridgeItemKind.doubleNullable || BridgeItemKind.boolNullable || BridgeItemKind.dateTimeNullable || BridgeItemKind.uint64Nullable || BridgeItemKind.hybridEnumNullable => 'jobject',
      BridgeItemKind.hybridRecord || BridgeItemKind.hybridRecordNullable || BridgeItemKind.nitroVariant || BridgeItemKind.nitroVariantNullable => 'jbyteArray',
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
        final stName = bareTypeName(stream.itemType.name);
        writer.line(
          '    $stName* st_ptr = ($stName*)malloc(sizeof($stName));',
        );
        writer.line(
          '    *st_ptr = pack_${stream.itemType.name}_from_jni(env, item);',
        );
        // pack_ can throw (e.g. a heap ByteBuffer where @zeroCopy needs a direct
        // one). The item is dropped and JNI_FALSE returned; name the stream in
        // the log so a missing emission is attributable, matching the LOGE style
        // used for the method-ID lookups.
        writer.line('    if (env->ExceptionCheck()) {');
        writer.line('        env->ExceptionDescribe();');
        writer.line('        env->ExceptionClear();');
        writer.line('        LOGE("emit_${stream.dartName}: packing $stName threw; item dropped");');
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

      case BridgeItemKind.hybridRecord || BridgeItemKind.hybridRecordNullable || BridgeItemKind.nitroVariant || BridgeItemKind.nitroVariantNullable:
        // @HybridRecord and @NitroVariant: Kotlin calls .encode() → jbyteArray.
        // Nullable items arrive as nullptr → post kNull.
        // C copies bytes to a malloc'd native buffer and sends the pointer as kInt64.
        // Dart reads via RecordType.fromNative/VariantExt.fromNative and frees via <lib>_nitro_free.
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

      case BridgeItemKind.typedData || BridgeItemKind.typedDataNullable || BridgeItemKind.void_ || BridgeItemKind.other:
        // Not valid as stream item types — emit null as a safe no-op.
        // Explicit cases so the compiler enforces exhaustiveness when new
        // BridgeItemKind values are added.
        writer.line('    obj.type = Dart_CObject_kNull;');
    }
    writer.line('    if (!Dart_PostCObject_DL(dartPort, &obj)) {');
    if (itemKind.isStructKind) {
      final stName = bareTypeName(stream.itemType.name);
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
