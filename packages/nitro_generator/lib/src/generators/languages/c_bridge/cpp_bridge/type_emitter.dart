part of '../cpp_bridge_generator.dart';

bool _isZeroCopy(BridgeStruct st, String fieldName) => CppBridgeGenerator._isZeroCopy(st, fieldName);

String _zeroCopyLenField(BridgeStruct st, String zeroCopyField) => CppBridgeGenerator._zeroCopyLenField(st, zeroCopyField);

bool _zeroCopyNeedsSynthetic(BridgeStruct st, String zeroCopyField) => CppBridgeGenerator._zeroCopyNeedsSynthetic(st, zeroCopyField);

String _elementSizeDivisorExpr(String dartType) => CppBridgeGenerator._elementSizeDivisorExpr(dartType);

String _jniGetter(String type) => CppBridgeGenerator._jniGetter(type);

String _jniCast(String type) => CppBridgeGenerator._jniCast(type);

String _zeroCopyCElementCast(String dartType) => CppBridgeGenerator._zeroCopyCElementCast(dartType);

String _zeroCopyElementSizeExpr(String dartType) => CppBridgeGenerator._zeroCopyElementSizeExpr(dartType);

List<String> _typedDataJniOps(String dartType) => CppBridgeGenerator._typedDataJniOps(dartType);

void _emitJniTypeHelpers(
  CodeWriter writer,
  BridgeSpec spec,
  Set<String> enumNames,
  Set<String> structNames,
) {
  // JNI struct unpack helpers (C struct → Java object)
  for (final st in spec.structs) {
    // pack: Java object → C struct (used for stream emit and return values)
    writer.line(
      'static ${st.name} pack_${st.name}_from_jni(JNIEnv* env, jobject obj) {',
    );
    writer.line('    ${st.name} result;');
    for (final f in st.fields) {
      final isEnumField = enumNames.contains(f.type.name.replaceFirst('?', ''));
      final isZeroCopyField = _isZeroCopy(st, f.name);
      final getter = isEnumField ? 'GetLongField' : _jniGetter(f.type.name);
      if (isZeroCopyField) {
        final elemCast = _zeroCopyCElementCast(f.type.name);
        writer.line(
          '    jobject buf_${f.name} = env->GetObjectField(obj, g_fid_${st.name}_${f.name});',
        );
        // Null guard: GetDirectBufferAddress(null) returns null — assign it
        // to the struct field unchecked causes a silent null-deref on use.
        writer.line('    if (buf_${f.name} == nullptr) {');
        writer.line('        jclass npe = env->FindClass("java/lang/NullPointerException");');
        writer.line('        if (npe) env->ThrowNew(npe, "${st.name}.${f.name}: TypedData ByteBuffer is null");');
        writer.line('        return result;');
        writer.line('    }');
        writer.line(
          '    result.${f.name} = ($elemCast)env->GetDirectBufferAddress(buf_${f.name});',
        );
        writer.line('    if (result.${f.name} == nullptr) {');
        writer.line('        jclass iae = env->FindClass("java/lang/IllegalArgumentException");');
        writer.line('        if (iae) env->ThrowNew(iae, "${st.name}.${f.name}: @ZeroCopy requires ByteBuffer.allocateDirect() — heap-backed ByteBuffer.wrap() is not supported.");');
        writer.line('        env->DeleteLocalRef(buf_${f.name});');
        writer.line('        return result;');
        writer.line('    }');
        // When no explicit companion length field exists, auto-populate the
        // synthesized '${field}Length' field from the ByteBuffer's capacity.
        if (_zeroCopyNeedsSynthetic(st, f.name)) {
          final divisor = _elementSizeDivisorExpr(f.type.name);
          writer.line(
            '    result.${f.name}Length = (int64_t)env->GetDirectBufferCapacity(buf_${f.name})$divisor;',
          );
        }
        writer.line('    env->DeleteLocalRef(buf_${f.name});');
      } else if (f.type.name == 'String') {
        writer.line(
          '    jstring j_${f.name} = (jstring)env->GetObjectField(obj, g_fid_${st.name}_${f.name});',
        );
        writer.line(
          '    const char* str_${f.name} = (j_${f.name} != nullptr) ? env->GetStringUTFChars(j_${f.name}, 0) : "";',
        );
        writer.line('    result.${f.name} = strdup(str_${f.name});');
        writer.line('    if (j_${f.name}) {');
        writer.line('        env->ReleaseStringUTFChars(j_${f.name}, str_${f.name});');
        writer.line('        env->DeleteLocalRef(j_${f.name});');
        writer.line('    }');
      } else if (isEnumField) {
        final enumType = f.type.name.replaceFirst('?', '');
        writer.line(
          '    result.${f.name} = ($enumType)(int32_t)env->$getter(obj, g_fid_${st.name}_${f.name});',
        );
      } else if (structNames.contains(f.type.name.replaceFirst('?', ''))) {
        final nestedType = f.type.name.replaceFirst('?', '');
        writer.line('    jobject j_${f.name} = env->GetObjectField(obj, g_fid_${st.name}_${f.name});');
        writer.line('    $nestedType* ${f.name}_ptr = ($nestedType*)malloc(sizeof($nestedType));');
        writer.line('    *${f.name}_ptr = pack_${nestedType}_from_jni(env, j_${f.name});');
        writer.line('    env->DeleteLocalRef(j_${f.name});');
        writer.line('    result.${f.name} = ${f.name}_ptr;');
      } else if (f.type.isTypedData) {
        // Non-zero-copy typed data: extract Java array bytes into a malloc'd C buffer.
        final ops = _typedDataJniOps(f.type.name);
        final cElemType = _zeroCopyCElementCast(f.type.name).replaceAll('*', '').trim();
        writer.line('    ${ops[0]} j_${f.name} = (${ops[0]})env->GetObjectField(obj, g_fid_${st.name}_${f.name});');
        writer.line('    jsize _len_${f.name} = (j_${f.name} != nullptr) ? env->GetArrayLength(j_${f.name}) : 0;');
        writer.line('    result.${f.name} = nullptr;');
        if (_zeroCopyNeedsSynthetic(st, f.name)) {
          writer.line('    result.${f.name}Length = 0;');
        }
        writer.line('    if (j_${f.name} != nullptr && _len_${f.name} > 0) {');
        writer.line('        result.${f.name} = ($cElemType*)malloc(_len_${f.name} * sizeof($cElemType));');
        writer.line('        env->Get${ops[2].replaceFirst('Set', '')}(j_${f.name}, 0, _len_${f.name}, (${ops[3]}*)result.${f.name});');
        if (_zeroCopyNeedsSynthetic(st, f.name)) {
          writer.line('        result.${f.name}Length = (int64_t)_len_${f.name};');
        }
        writer.line('        env->DeleteLocalRef(j_${f.name});');
        writer.line('    }');
      } else {
        writer.line('    result.${f.name} = env->$getter(obj, g_fid_${st.name}_${f.name});');
      }
    }
    writer.line('    return result;');
    writer.line('}');

    // unpack: C struct → Java object (used for passing struct params to Kotlin)
    writer.line(
      'static jobject unpack_${st.name}_to_jni(JNIEnv* env, const ${st.name}* st) {',
    );
    // Pre-compute zero-copy ByteBuffer objects with null guards.
    // NewDirectByteBuffer(nullptr, n) is undefined behaviour in JNI — guard
    // every zeroCopy pointer before passing it to the constructor.
    for (final f in st.fields) {
      if (!_isZeroCopy(st, f.name)) continue;
      final lenField = _zeroCopyLenField(st, f.name);
      final elemSize = _zeroCopyElementSizeExpr(f.type.name);
      writer.line('    if (st->${f.name} == nullptr) {');
      writer.line('        jclass npe = env->FindClass("java/lang/NullPointerException");');
      writer.line('        if (npe) env->ThrowNew(npe, "${st.name}.${f.name}: TypedData pointer is null");');
      writer.line('        return nullptr;');
      writer.line('    }');
      // NewDirectByteBuffer takes a BYTE count, not element count.
      writer.line('    jobject dbuf_${f.name} = env->NewDirectByteBuffer((void*)st->${f.name}, st->$lenField$elemSize);');
    }
    for (final f in st.fields) {
      if (_isZeroCopy(st, f.name)) continue;
      if (f.type.name == 'String') {
        writer.line('    jstring j_${f.name} = env->NewStringUTF(st->${f.name} ? st->${f.name} : "");');
      }
    }
    for (final f in st.fields) {
      if (_isZeroCopy(st, f.name)) continue;
      if (!structNames.contains(f.type.name.replaceFirst('?', ''))) continue;
      final nestedType = f.type.name.replaceFirst('?', '');
      writer.line('    jobject j_${f.name} = unpack_${nestedType}_to_jni(env, st->${f.name});');
    }
    // Pre-compute non-zero-copy typed data: create Java arrays from C buffers.
    for (final f in st.fields) {
      if (_isZeroCopy(st, f.name) || !f.type.isTypedData) continue;
      final ops = _typedDataJniOps(f.type.name);
      final lenField = _zeroCopyLenField(st, f.name);
      writer.line('    ${ops[0]} j_${f.name} = env->${ops[1]}((jsize)st->$lenField);');
      writer.line('    if (j_${f.name} != nullptr && st->${f.name} != nullptr) {');
      writer.line('        env->${ops[2]}(j_${f.name}, 0, (jsize)st->$lenField, (const ${ops[3]}*)st->${f.name});');
      writer.line('    }');
    }
    final ctorArgs = st.fields
        .map((f) {
          final isEnum = enumNames.contains(f.type.name.replaceFirst('?', ''));
          final isNestedStruct = structNames.contains(f.type.name.replaceFirst('?', ''));
          if (_isZeroCopy(st, f.name)) {
            return 'dbuf_${f.name}';
          } else if (f.type.isTypedData) {
            return 'j_${f.name}'; // non-ZC typed data → Java array created above
          } else if (f.type.name == 'String') {
            return 'j_${f.name}';
          } else if (isEnum) {
            return '(jlong)(int32_t)st->${f.name}';
          } else if (isNestedStruct) {
            return 'j_${f.name}';
          } else {
            return '(${_jniCast(f.type.name)})st->${f.name}';
          }
        })
        .join(', ');
    writer.line('    jobject result = env->NewObject(g_cls_${st.name}, g_ctor_${st.name}, $ctorArgs);');
    for (final f in st.fields) {
      if (_isZeroCopy(st, f.name)) {
        writer.line('    if (dbuf_${f.name}) env->DeleteLocalRef(dbuf_${f.name});');
      } else if (!_isZeroCopy(st, f.name) && f.type.isTypedData) {
        writer.line('    if (j_${f.name}) env->DeleteLocalRef(j_${f.name});');
      } else if (f.type.name == 'String') {
        writer.line('    if (j_${f.name}) env->DeleteLocalRef(j_${f.name});');
      } else if (structNames.contains(f.type.name.replaceFirst('?', ''))) {
        writer.line('    if (j_${f.name}) env->DeleteLocalRef(j_${f.name});');
      }
    }
    writer.line('    return result;');
    writer.line('}');
  }
  writer.blankLine();
}
