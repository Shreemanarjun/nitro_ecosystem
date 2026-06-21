part of '../cpp_bridge_generator.dart';

void _emitJniSwiftPrologue(
  CodeWriter writer,
  BridgeSpec spec,
  String libStem,
  Set<String> enumNames,
  Set<String> structNames,
) {
  writer.line('#include <jni.h>');
  writer.line('#include <android/log.h>');
  writer.line(
    '#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Nitrogen", __VA_ARGS__)',
  );
  writer.blankLine();
  writer.line('static JavaVM* g_jvm = nullptr;');
  writer.line('static jclass g_bridgeClass = nullptr;');
  writer.blankLine();
  writer.line('// ── Cached JNI IDs (initialized once in JNI_OnLoad, safe to use from any thread) ──');
  writer.line('static jmethodID g_exc_getName = nullptr;');
  writer.line('static jmethodID g_exc_getMessage = nullptr;');
  for (final func in spec.functions) {
    writer.line('static jmethodID g_mid_${func.dartName}_call = nullptr;');
  }
  for (final prop in spec.properties) {
    if (prop.hasGetter) writer.line('static jmethodID g_mid_${prop.getSymbol}_call = nullptr;');
    if (prop.hasSetter) writer.line('static jmethodID g_mid_${prop.setSymbol}_call = nullptr;');
  }
  for (final stream in spec.streams) {
    writer.line('static jmethodID g_mid_${stream.registerSymbol}_call = nullptr;');
    writer.line('static jmethodID g_mid_${stream.releaseSymbol}_call = nullptr;');
  }
  // Record types used in streams: cache class + encode() method ID for JNI emit
  final emittedRecordGlobals = <String>{};
  for (final stream in spec.streams) {
    if (stream.itemType.isRecord) {
      final recName = stream.itemType.name.replaceFirst('?', '');
      if (emittedRecordGlobals.add(recName)) {
        writer.line('static jclass g_cls_$recName = nullptr;');
        writer.line('static jmethodID g_mid_${recName}_encode = nullptr;');
      }
    }
  }
  for (final st in spec.structs) {
    writer.line('static jclass g_cls_${st.name} = nullptr;');
    writer.line('static jmethodID g_ctor_${st.name} = nullptr;');
    for (final f in st.fields) {
      writer.line('static jfieldID g_fid_${st.name}_${f.name} = nullptr;');
    }
  }
  writer.blankLine();
  final zeroCopyStreamStructs = spec.streams
      .where((st2) => structNames.contains(st2.itemType.name.replaceFirst('?', '')))
      .map((st2) => st2.itemType.name.replaceFirst('?', ''))
      .where((name) => spec.structs.any((st3) => st3.name == name && st3.fields.any((f) => f.zeroCopy)))
      .toSet();
  if (zeroCopyStreamStructs.isNotEmpty) {
    writer.line('#include <unordered_map>');
    writer.line('#include <mutex>');
    writer.line('// GlobalRef map: keeps zero-copy struct backing objects alive until Dart finalizer fires.');
    writer.line('static std::unordered_map<void*, jobject> g_zero_copy_refs;');
    writer.line('static std::mutex g_zero_copy_refs_mtx;');
    writer.blankLine();
  }
  writer.blankLine();
  writer.line('// RAII guard: auto-detaches a thread from the JVM when it exits.');
  writer.line('// One instance is stored in thread-local storage; its destructor fires');
  writer.line('// when the thread terminates, ensuring no JVM thread descriptor leaks.');
  writer.line('struct NitroJniThreadGuard {');
  writer.line('    bool attached = false;');
  writer.line('    ~NitroJniThreadGuard() {');
  writer.line('        if (attached && g_jvm != nullptr) {');
  writer.line('            g_jvm->DetachCurrentThread();');
  writer.line('        }');
  writer.line('    }');
  writer.line('};');
  writer.line('static thread_local NitroJniThreadGuard g_thread_guard;');
  writer.blankLine();
  // S8: JNI exception → NitroError* out-param.
  // Extracts the exception name + message via JNI reflection, writes them into
  // the out-param error slot, then releases all local JNI references.
  // The out-param must be non-null; callers ensure this via the Dart-side
  // pre-allocated _nitroErr slot.
  writer.line('static void nitro_report_jni_exception(JNIEnv* env, jthrowable ex, NitroError* _nitro_err) {');
  writer.line('    // MUST clear the pending exception before making any further JNI calls.');
  writer.line('    // JNI aborts if any JNI function (e.g. GetObjectClass) is called while');
  writer.line('    // an exception is still pending.');
  writer.line('    env->ExceptionClear();');
  writer.line('    jclass ex_class = env->GetObjectClass(ex);');
  writer.line('    jstring j_name = (jstring)env->CallObjectMethod(ex_class, g_exc_getName);');
  writer.line('    const char* name = (j_name != nullptr) ? env->GetStringUTFChars(j_name, 0) : "JavaException";');
  writer.blankLine();
  writer.line('    jstring j_msg = (jstring)env->CallObjectMethod(ex, g_exc_getMessage);');
  writer.line('    const char* msg = (j_msg != nullptr) ? env->GetStringUTFChars(j_msg, 0) : "No message provided";');
  writer.blankLine();
  writer.line('    // S8: write to out-param slot (sync) or TLS slot (async, _nitro_err == nullptr).');
  writer.line('    if (_nitro_err) {');
  writer.line('        _nitro_err->hasError = 1;');
  writer.line('        _nitro_err->name       = strdup(name);');
  writer.line('        _nitro_err->message    = strdup(msg);');
  writer.line('        _nitro_err->code       = nullptr;');
  writer.line('        _nitro_err->stackTrace = nullptr;');
  writer.line('    } else {');
  writer.line('        // Async functions use TLS slot (read by callAsync via get_error/clear_error).');
  writer.line('        nitro_report_error(name, msg, nullptr, nullptr);');
  writer.line('    }');
  writer.blankLine();
  writer.line('    if (j_name) {');
  writer.line('        env->ReleaseStringUTFChars(j_name, name);');
  writer.line('        env->DeleteLocalRef(j_name);');
  writer.line('    }');
  writer.line('    if (j_msg) {');
  writer.line('        env->ReleaseStringUTFChars(j_msg, msg);');
  writer.line('        env->DeleteLocalRef(j_msg);');
  writer.line('    }');
  writer.line('    env->DeleteLocalRef(ex_class);');
  writer.line('    env->DeleteLocalRef(ex);');
  writer.line('}');
  writer.blankLine();

  _emitJniTypeHelpers(writer, spec, enumNames, structNames);

  writer.line('extern "C" {');
  writer.blankLine();
  writer.line(
    'JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {',
  );
  writer.line('    g_jvm = vm;');
  writer.line(
    '    __android_log_print(ANDROID_LOG_INFO, "Nitrogen", "JNI_OnLoad called for ${spec.lib}");',
  );
  writer.line('    JNIEnv* env = nullptr;');
  writer.line(
    '    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {',
  );
  writer.line('        return -1;');
  writer.line('    }');
  writer.line(
    '    // Cache standard-library method IDs only — system class loader is always',
  );
  writer.line(
    '    // available here. Application class IDs are deferred to initialize().',
  );
  writer.line('    {');
  writer.line('        jclass cls_class = env->FindClass("java/lang/Class");');
  writer.line('        if (cls_class) { g_exc_getName = env->GetMethodID(cls_class, "getName", "()Ljava/lang/String;"); env->DeleteLocalRef(cls_class); }');
  writer.line('        jclass throwable_class = env->FindClass("java/lang/Throwable");');
  writer.line('        if (throwable_class) { g_exc_getMessage = env->GetMethodID(throwable_class, "getMessage", "()Ljava/lang/String;"); env->DeleteLocalRef(throwable_class); }');
  writer.line('    }');
  writer.line('    return JNI_VERSION_1_6;');
  writer.line('}');
  writer.blankLine();
  writer.line('static JNIEnv* GetEnv() {');
  writer.line('    if (g_jvm == nullptr) { return nullptr; }');

  writer.line('    JNIEnv* env = nullptr;');
  writer.line(
    '    int status = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);',
  );
  writer.line('    if (status == JNI_EDETACHED) {');
  writer.line('        g_jvm->AttachCurrentThread(&env, nullptr);');
  writer.line('        g_thread_guard.attached = true; // will DetachCurrentThread on thread exit');
  writer.line('    }');
  writer.line('    return env;');
  writer.line('}');
  writer.blankLine();
}
