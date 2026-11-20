part of '../cpp_bridge_generator.dart';

// The `_invoke_*` JNI functions Kotlin calls to run a Dart callback: its
// arguments to the callback's real ABI, its return value back to Kotlin.

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
        final base = bareTypeName(t.name);
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
        final base = bareTypeName(t.name);
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
        final base = bareTypeName(cbParams[i].name);
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
        final base = bareTypeName(cbParams[i].name);
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
      final needsStringConversion = cbParams.any((t) => bareTypeName(t.name) == 'String');

      // Bidirectional callbacks: map Dart return type to JNI/C types.
      final cbReturnTypeDart = p.type.functionReturnType;
      final isVoidReturn = cbReturnTypeDart == null || cbReturnTypeDart == 'void';
      final isStringReturn = cbReturnTypeDart == 'String';
      final retBase = cbReturnTypeDart == null ? 'void' : bareTypeName(cbReturnTypeDart);
      // A flat @HybridStruct comes back as the same block a record does.
      final isRecordReturn = !isVoidReturn && !isStringReturn && (recordNames.contains(retBase) || spec.isFlatStruct(retBase));
      final isVariantReturn = !isVoidReturn && !isStringReturn && variantNames.contains(retBase);
      // JNI return: void, jstring (String), jbyteArray (record/variant), jlong (primitives)
      final cRetType = isVoidReturn
          ? 'void'
          : isStringReturn
          ? 'jstring'
          : (isRecordReturn || isVariantReturn)
          ? 'jbyteArray'
          : 'jlong';
      // C typedef return: void, const char* (String), uint8_t* (record/variant bytes), int64_t (prims)
      final cTypedefReturn = isVoidReturn
          ? 'void'
          : isStringReturn
          ? 'const char*'
          : (isRecordReturn || isVariantReturn)
          ? 'uint8_t*'
          : 'int64_t';

      writer.line('JNIEXPORT $cRetType JNICALL $jniMethName($cParams) {');
      writer.line('    typedef $cTypedefReturn (*CB)(${typedefParams.isEmpty ? 'void' : typedefParams});');
      // Convert jstring → const char* (release after call).
      // Unpack Kotlin data classes → C struct (stack-allocated).
      // Copy ByteArray record bytes → malloc'd length-prefixed buffer (Dart frees).
      for (var i = 0; i < cbParams.length; i++) {
        final base = bareTypeName(cbParams[i].name);
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
        final base = bareTypeName(cbParams[i].name);
        final isNullable = cbParams[i].name.endsWith('?');
        final struct = spec.structs.where((s) => s.name == base).firstOrNull;
        switch (base) {
          case _ when struct != null && _isExpandableStruct(struct):
            // Pass each field's raw int64_t value directly — Dart receives Int64 and reconstructs.
            callParts.addAll(struct.fields.map((f) => '(int64_t)arg${i}_${f.name}'));
          case _ when isNullable && (base == 'int' || base == 'double' || base == 'bool'):
            // Nullable primitive: two int64_t args (isNull flag + value bits).
            callParts.add('(int64_t)arg${i}Null');
            callParts.add('(int64_t)arg${i}Val');
          case 'String':
            callParts.add('s_arg$i');
          case 'double':
            callParts.add('(int64_t)arg$i');
          case 'bool':
            callParts.add('(int64_t)arg$i');
          case _ when structNames.contains(base):
            callParts.add('&c_arg$i');
          case _ when recordNames.contains(base):
            callParts.add('r_buf$i');
          case _ when variantNames.contains(base):
            callParts.add('v_buf$i');
          default:
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
          if (bareTypeName(cbParams[i].name) == 'String') {
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
    }
  }
}
