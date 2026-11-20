part of '../cpp_bridge_generator.dart';

// JNI glue for property getters and setters.

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
    // the generic default branch is wrong for these.
    final propKind = classifyBridgeItem(prop.type, spec);

    // C return type for the getter (and const-qualified param type for the setter).
    // Nullable primitives and variants are transported as uint8_t* (ByteArray / NitroOpt*).
    final cType = switch (propKind) {
      BridgeItemKind.intNullable || BridgeItemKind.doubleNullable || BridgeItemKind.boolNullable || BridgeItemKind.dateTimeNullable || BridgeItemKind.nitroVariant || BridgeItemKind.nitroVariantNullable => 'uint8_t*',
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
        BridgeItemKind.intNullable || BridgeItemKind.doubleNullable || BridgeItemKind.boolNullable || BridgeItemKind.dateTimeNullable || BridgeItemKind.nitroVariant || BridgeItemKind.nitroVariantNullable => '(J)[B',
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
          writer.line('    uint8_t* ni_result = _g_opt_ret;');
          writer.line('    env->GetByteArrayRegion(jarr_ni, 0, (jsize)sizeof(NitroOptInt64), (jbyte*)ni_result);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return ni_result;');

        case BridgeItemKind.doubleNullable:
          writer.line('    jbyteArray jarr_nd = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    if (jarr_nd == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
          writer.line('    uint8_t* nd_result = _g_opt_ret;');
          writer.line('    env->GetByteArrayRegion(jarr_nd, 0, (jsize)sizeof(NitroOptFloat64), (jbyte*)nd_result);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return nd_result;');

        case BridgeItemKind.boolNullable:
          writer.line('    jbyteArray jarr_nb = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    if (jarr_nb == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
          writer.line('    uint8_t* nb_result = _g_opt_ret;');
          writer.line('    env->GetByteArrayRegion(jarr_nb, 0, (jsize)sizeof(NitroOptBool), (jbyte*)nb_result);');
          writer.line('    env->PopLocalFrame(nullptr);');
          writer.line('    return nb_result;');

        case BridgeItemKind.string || BridgeItemKind.stringNullable:
          // Both String and String? use the same null-guarded UTF path.
          writer.line('    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, (jlong)instanceId);');
          writer.line('    if (jstr == nullptr) { env->PopLocalFrame(nullptr); return nullptr; }');
          writer.line('    const char* nativeStr = env->GetStringUTFChars(jstr, 0);');
          writer.line('    _g_str_ret = nativeStr; char* result = const_cast<char*>(_g_str_ret.c_str());');
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
        BridgeItemKind.intNullable || BridgeItemKind.doubleNullable || BridgeItemKind.boolNullable || BridgeItemKind.dateTimeNullable || BridgeItemKind.nitroVariant || BridgeItemKind.nitroVariantNullable => '(J[B)V',
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
