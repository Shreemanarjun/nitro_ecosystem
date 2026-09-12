part of '../cpp_bridge_generator.dart';
/// `@NitroEntryPoint` C side: one process-wide job table per library
/// (nitro_background.h) plus the exported `<lib>_bg_*` symbols the generated
/// Dart binds. Host hooks — a Kotlin static method over JNI, a Swift
/// `@_cdecl` on iOS — start a headless engine at the entry wrapper; where no
/// host exists (desktop, Apple C++ impls, macOS) `has_host` is 0 and Dart
/// runs the wrapper on a spawned isolate instead.

/// Include + table definition. Emitted in the includes section of every
/// bridge path; guarded so a file that emits both paths defines it once.
void emitBackgroundTable(CodeWriter w, BridgeSpec spec, String libStem) {
  if (spec.entryPoints.isEmpty) return;
  final guard = 'NITRO_BG_TABLE_${libStem.toUpperCase()}';
  w.line('#ifndef $guard');
  w.line('#define $guard');
  w.line('#include "nitro_background.h"');
  w.line('static NitroBgTable g_bg_$libStem;');
  w.line('#endif');
}

/// Forward declarations the JNI prologue needs before `JNI_OnLoad`.
void emitBackgroundJniForwardDecls(CodeWriter w, BridgeSpec spec) {
  if (spec.entryPoints.isEmpty || spec.androidImpl is! KotlinImpl) return;
  w.line('static int nitro_bg_jni_start(const char* entry, int64_t jobId, void* ctx);');
  w.line('static void nitro_bg_jni_done(int64_t jobId, const char* error, void* ctx);');
}

/// Registration line for the end of `JNI_OnLoad`.
void emitBackgroundJniRegistration(CodeWriter w, BridgeSpec spec, String libStem) {
  if (spec.entryPoints.isEmpty || spec.androidImpl is! KotlinImpl) return;
  w.line('    g_bg_$libStem.registerHost(&nitro_bg_jni_start, &nitro_bg_jni_done, nullptr);');
}

/// The exported symbols and host hook bodies. Emitted once at the END of the
/// bridge (after every prologue) so `GetEnv`/`g_bridgeClass` are in scope.
void emitBackgroundExports(CodeWriter w, BridgeSpec spec, String libStem) {
  if (spec.entryPoints.isEmpty) return;
  final guard = 'NITRO_BG_EXPORTS_${libStem.toUpperCase()}';
  final t = 'g_bg_$libStem';
  w.blankLine();
  w.line('// ── @NitroEntryPoint: background job table exports ─────────────────────');
  w.line('#ifndef $guard');
  w.line('#define $guard');
  w.line('extern "C" {');
  w.line('NITRO_EXPORT int64_t ${libStem}_bg_submit(const char* entry, const uint8_t* args, int64_t argsLen, int64_t dartPort, int8_t* hostStarted) {');
  w.line('    bool started = false;');
  w.line('    int64_t id = $t.submit(entry, args, argsLen < 0 ? 0 : (size_t)argsLen, dartPort, &started);');
  w.line('    if (hostStarted) *hostStarted = started ? 1 : 0;');
  w.line('    return id;');
  w.line('}');
  w.line('NITRO_EXPORT int8_t ${libStem}_bg_has_host(void) {');
  w.line('    return $t.hasHost() ? 1 : 0;');
  w.line('}');
  w.line('// Returns a malloc\'d copy of the args blob (free with ${libStem}_nitro_free), or');
  w.line('// nullptr when nothing is queued for this entry.');
  w.line('NITRO_EXPORT uint8_t* ${libStem}_bg_take_job(const char* entry, int64_t jobId, int64_t* outId, int64_t* outLen) {');
  w.line('    int64_t id = 0;');
  w.line('    std::string args;');
  w.line('    if (!$t.take(entry, jobId, &id, &args)) return nullptr;');
  w.line('    uint8_t* out = (uint8_t*)malloc(args.size() + 1);');
  w.line('    if (!out) return nullptr;');
  w.line('    if (!args.empty()) memcpy(out, args.data(), args.size());');
  w.line('    out[args.size()] = 0;');
  w.line('    if (outId) *outId = id;');
  w.line('    if (outLen) *outLen = (int64_t)args.size();');
  w.line('    return out;');
  w.line('}');
  w.line('NITRO_EXPORT int64_t ${libStem}_bg_active_count() {');
  w.line('    return $t.activeCount();');
  w.line('}');
  w.line('NITRO_EXPORT int8_t ${libStem}_bg_complete(int64_t jobId, const uint8_t* result, int64_t len) {');
  w.line('    return $t.complete(jobId, result, len < 0 ? 0 : (size_t)len) ? 1 : 0;');
  w.line('}');
  w.line('NITRO_EXPORT int8_t ${libStem}_bg_fail(int64_t jobId, const char* error, const char* stackTrace) {');
  w.line('    return $t.fail(jobId, error, stackTrace) ? 1 : 0;');
  w.line('}');
  w.line('// Stream entries: one blob per item; end posts null; cancel forgets the job.');
  w.line('NITRO_EXPORT int8_t ${libStem}_bg_emit(int64_t jobId, const uint8_t* item, int64_t len) {');
  w.line('    return $t.emit(jobId, item, len < 0 ? 0 : (size_t)len) ? 1 : 0;');
  w.line('}');
  w.line('NITRO_EXPORT int8_t ${libStem}_bg_end(int64_t jobId) {');
  w.line('    return $t.end(jobId) ? 1 : 0;');
  w.line('}');
  w.line('NITRO_EXPORT int8_t ${libStem}_bg_cancel(int64_t jobId) {');
  w.line('    return $t.cancel(jobId) ? 1 : 0;');
  w.line('}');
  w.line('// Native-initiated job (no Dart submitter): a single String argument in the');
  w.line('// record wire ([int32 LE length][utf8]). Returns the job id, or -1 when no');
  w.line('// host is registered to start an engine.');
  w.line('NITRO_EXPORT int64_t ${libStem}_bg_run_string(const char* entry, const char* text) {');
  w.line('    std::string s = text ? text : "";');
  w.line('    uint32_t n = (uint32_t)s.size();');
  w.line('    std::string blob;');
  w.line('    blob.push_back((char)(n & 0xff)); blob.push_back((char)((n >> 8) & 0xff));');
  w.line('    blob.push_back((char)((n >> 16) & 0xff)); blob.push_back((char)((n >> 24) & 0xff));');
  w.line('    blob += s;');
  w.line('    return $t.runNative(entry, (const uint8_t*)blob.data(), blob.size());');
  w.line('}');
  w.line('// For hosts written in C/C++ (desktop apps): start engines yourself.');
  w.line('NITRO_EXPORT void ${libStem}_bg_register_host(int (*starter)(const char*, int64_t, void*), void (*done)(int64_t, const char*, void*), void* ctx) {');
  w.line('    $t.registerHost(starter, done, ctx);');
  w.line('}');

  if (spec.androidImpl is KotlinImpl) {
    final failSym = CppBridgeGenerator._jniMethodName(spec.lib, spec.dartClassName, 'nitroBgFail');
    w.line('#ifdef __ANDROID__');
    w.line('// Host hooks over JNI: the Kotlin bridge object starts/destroys headless');
    w.line('// FlutterEngines on the main looper.');
    w.line('static int nitro_bg_jni_start(const char* entry, int64_t jobId, void*) {');
    w.line('    JNIEnv* env = GetEnv();');
    w.line('    if (env == nullptr || g_bridgeClass == nullptr) return 0;');
    w.line('    jmethodID m = env->GetStaticMethodID(g_bridgeClass, "nitroBgStart", "(Ljava/lang/String;J)V");');
    w.line('    if (m == nullptr) { env->ExceptionClear(); return 0; }');
    w.line('    jstring js = env->NewStringUTF(entry ? entry : "");');
    w.line('    env->CallStaticVoidMethod(g_bridgeClass, m, js, (jlong)jobId);');
    w.line('    env->DeleteLocalRef(js);');
    w.line('    if (env->ExceptionCheck()) { env->ExceptionClear(); return 0; }');
    w.line('    return 1;');
    w.line('}');
    w.line('static void nitro_bg_jni_done(int64_t jobId, const char* error, void*) {');
    w.line('    JNIEnv* env = GetEnv();');
    w.line('    if (env == nullptr || g_bridgeClass == nullptr) return;');
    w.line('    jmethodID m = env->GetStaticMethodID(g_bridgeClass, "nitroBgDone", "(JLjava/lang/String;)V");');
    w.line('    if (m == nullptr) { env->ExceptionClear(); return; }');
    w.line('    jstring js = error ? env->NewStringUTF(error) : nullptr;');
    w.line('    env->CallStaticVoidMethod(g_bridgeClass, m, (jlong)jobId, js);');
    w.line('    if (js) env->DeleteLocalRef(js);');
    w.line('    if (env->ExceptionCheck()) env->ExceptionClear();');
    w.line('}');
    final runSym = CppBridgeGenerator._jniMethodName(spec.lib, spec.dartClassName, 'nitroBgRunString');
    w.line('// Kotlin → C: native-initiated job (WorkManager, BroadcastReceiver, ...).');
    w.line('JNIEXPORT jlong JNICALL $runSym(JNIEnv* env, jclass, jstring entry, jstring text) {');
    w.line('    const char* e = entry ? env->GetStringUTFChars(entry, nullptr) : nullptr;');
    w.line('    const char* s = text ? env->GetStringUTFChars(text, nullptr) : nullptr;');
    w.line('    jlong id = (jlong)${libStem}_bg_run_string(e ? e : "", s ? s : "");');
    w.line('    if (e) env->ReleaseStringUTFChars(entry, e);');
    w.line('    if (s) env->ReleaseStringUTFChars(text, s);');
    w.line('    return id;');
    w.line('}');
    w.line('// Kotlin → C: an engine could not be started; fail the job so Dart sees it.');
    w.line('JNIEXPORT void JNICALL $failSym(JNIEnv* env, jclass, jlong jobId, jstring error) {');
    w.line('    const char* s = error ? env->GetStringUTFChars(error, nullptr) : nullptr;');
    w.line('    $t.fail((int64_t)jobId, s ? s : "background engine start failed", "");');
    w.line('    if (s) env->ReleaseStringUTFChars(error, s);');
    w.line('}');
    w.line('#endif');
  }
  if (spec.iosImpl is SwiftImpl) {
    final ns = spec.namespace;
    w.line('#if defined(__APPLE__)');
    w.line('#include <TargetConditionals.h>');
    w.line('#if TARGET_OS_IOS');
    w.line('// Host hooks implemented in the generated Swift bridge (@_cdecl). iOS only:');
    w.line('// FlutterMacOS has no runWithEntrypoint:libraryURI:, so macOS uses the');
    w.line('// Dart-side isolate fallback.');
    w.line('extern int _${ns}_bg_start(const char* entry, int64_t jobId);');
    w.line('extern void _${ns}_bg_done(int64_t jobId, const char* error);');
    w.line('static int nitro_bg_swift_start(const char* entry, int64_t jobId, void*) { return _${ns}_bg_start(entry, jobId); }');
    w.line('static void nitro_bg_swift_done(int64_t jobId, const char* error, void*) { _${ns}_bg_done(jobId, error); }');
    w.line('struct NitroBgSwiftReg_$libStem { NitroBgSwiftReg_$libStem() { $t.registerHost(&nitro_bg_swift_start, &nitro_bg_swift_done, nullptr); } };');
    w.line('static NitroBgSwiftReg_$libStem g_bg_swift_reg_$libStem;');
    w.line('#endif');
    w.line('#endif');
  }
  w.line('}  // extern "C"');
  w.line('#endif  // $guard');
}
