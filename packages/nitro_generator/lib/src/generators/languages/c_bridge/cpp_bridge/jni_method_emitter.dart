part of '../cpp_bridge_generator.dart';

/// Returns true when all struct fields are numeric (int/double/bool) — can be
/// expanded to individual jlong params for synchronous NativeCallable.listener.
bool _isExpandableStruct(BridgeStruct st) {
  const numeric = {'int', 'double', 'bool'};
  return st.fields.isNotEmpty && st.fields.every((f) => numeric.contains(bareTypeName(f.type.name)) && !f.type.isTypedData);
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

  if (spec.hasZeroCopyTypedDataReturn) {
    writer.line('NITRO_EXPORT void ${libStem}_release_typed_data_return(void* ptr) {');
    writer.line('    if (!ptr) { return; }');

    writer.line('    int64_t* words = (int64_t*)ptr;');
    writer.line('    void* owner = (void*)(intptr_t)words[2];');
    writer.line('    if (owner != nullptr) {');
    writer.line('        JNIEnv* env = GetEnv();');
    writer.line('        if (env != nullptr) {');
    // Dart is done with the view at this point, so the buffer can be pooled for
    // reuse — without this, per-call allocateDirect churn fragments ART's
    // malloc_space until a small allocation fails with free memory left (#48).
    // Pool first, THEN drop the global ref: the pool's own strong reference is
    // what keeps the buffer alive afterwards.
    writer.line('            jmethodID _relMid = env->GetStaticMethodID(g_bridgeClass, "releaseZeroCopyBuffer", "(Ljava/nio/ByteBuffer;)V");');
    writer.line('            if (_relMid != nullptr) {');
    writer.line('                env->CallStaticVoidMethod(g_bridgeClass, _relMid, (jobject)owner);');
    writer.line('                if (env->ExceptionCheck()) { env->ExceptionClear(); }');
    writer.line('            } else if (env->ExceptionCheck()) { env->ExceptionClear(); }');
    writer.line('            env->DeleteGlobalRef((jobject)owner);');
    writer.line('        }');
    writer.line('    }');
    writer.line('    free(ptr);');
    writer.line('}');
    writer.blankLine();
  }

  // Universal free for native-owned memory handed to Dart. Dart must not use
  // package:ffi's malloc.free on these pointers (CoTaskMemFree on Windows).
  writer.line('NITRO_EXPORT void ${libStem}_nitro_free(void* ptr) { if (ptr) { free(ptr); } }');
  _emitNitroAdopt(writer, spec, libStem);
  writer.line('NITRO_EXPORT void* ${libStem}_nitro_alloc(size_t size) { return malloc(size); }');
  writer.blankLine();

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
    _emitJniRegularFuncBodyFramed(writer, func, spec, libStem, libPkg, enumNames, structNames, recordNames);
  }

  _emitJniPropertyBridges(writer, spec, enumNames, structNames);
  _emitJniStreamBridges(writer, spec, enumNames, structNames);
  final variantNames = spec.variants.map((v) => v.name).toSet();
  _emitJniCallbackInvokers(writer, spec, enumNames, structNames, recordNames, variantNames: variantNames);
  _emitJniInitializeAndPostHelpers(writer, spec, libStem, libPkg, enumNames, structNames, recordNames);

  writer.line('} // extern "C"');
}

/// JNI descriptor for a struct field. A nullable scalar/enum is a BOXED type
/// on the Kotlin data class (`Long?` → `Ljava/lang/Long;`), not a primitive —
/// getting this wrong makes `GetMethodID("<init>")` return null and the process
/// aborts during plugin registration.
String _structFieldJniSig(BridgeField f, Set<String> structNames, String Function(String) fallback) {
  if (!StructGenerator.needsHasValue(f, structNames)) return fallback(f.type.name);
  return switch (bareTypeName(f.type.name)) {
    'bool' => 'Ljava/lang/Boolean;',
    'double' || 'float' => 'Ljava/lang/Double;',
    _ => 'Ljava/lang/Long;',
  };
}
