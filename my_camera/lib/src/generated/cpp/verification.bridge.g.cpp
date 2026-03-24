#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include "dart_api_dl.h"
#include "verification.bridge.g.h"

extern "C" {
intptr_t InitDartApiDL(void* data) {
    return Dart_InitializeApiDL(data);
}
}
static thread_local NitroError g_nitro_error = { 0, nullptr, nullptr, nullptr, nullptr };

extern "C" {
NitroError* NitroGetError() { return &g_nitro_error; }
void NitroClearError() {
    g_nitro_error.hasError = 0;
    if (g_nitro_error.name) { free((void*)g_nitro_error.name); g_nitro_error.name = nullptr; }
    if (g_nitro_error.message) { free((void*)g_nitro_error.message); g_nitro_error.message = nullptr; }
    if (g_nitro_error.code) { free((void*)g_nitro_error.code); g_nitro_error.code = nullptr; }
    if (g_nitro_error.stackTrace) { free((void*)g_nitro_error.stackTrace); g_nitro_error.stackTrace = nullptr; }
}

static void nitro_report_error(const char* name, const char* message, const char* code, const char* stack) {
    NitroClearError();
    g_nitro_error.hasError = 1;
    g_nitro_error.name = name ? strdup(name) : strdup("NativeException");
    g_nitro_error.message = message ? strdup(message) : strdup("An unknown native exception occurred.");
    g_nitro_error.code = code ? strdup(code) : nullptr;
    g_nitro_error.stackTrace = stack ? strdup(stack) : nullptr;
}
}

#ifdef __ANDROID__
#include <jni.h>
#include <android/log.h>
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Nitrogen", __VA_ARGS__)

static JavaVM* g_jvm = nullptr;
static jclass g_bridgeClass = nullptr;

static void nitro_report_jni_exception(JNIEnv* env, jthrowable ex) {
    jclass ex_class = env->GetObjectClass(ex);
    jclass cls_class = env->FindClass("java/lang/Class");
    jmethodID get_name = env->GetMethodID(cls_class, "getName", "()Ljava/lang/String;");
    jstring j_name = (jstring)env->CallObjectMethod(ex_class, get_name);
    const char* name = env->GetStringUTFChars(j_name, 0);

    jmethodID get_msg = env->GetMethodID(env->FindClass("java/lang/Throwable"), "getMessage", "()Ljava/lang/String;");
    jstring j_msg = (jstring)env->CallObjectMethod(ex, get_msg);
    const char* msg = (j_msg != nullptr) ? env->GetStringUTFChars(j_msg, 0) : "No message provided";

    nitro_report_error(name, msg, nullptr, nullptr);

    env->ReleaseStringUTFChars(j_name, name);
    if (j_msg) env->ReleaseStringUTFChars(j_msg, msg);
    env->DeleteLocalRef(ex);
}

static FloatBuffer pack_FloatBuffer_from_jni(JNIEnv* env, jobject obj) {
    FloatBuffer result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_data = env->GetFieldID(cls, "data", "Ljava/lang/Object;");
    jobject buf_data = env->GetObjectField(obj, fid_data);
    result.data = (uint8_t*)env->GetDirectBufferAddress(buf_data);
    jfieldID fid_length = env->GetFieldID(cls, "length", "J");
    result.length = env->GetLongField(obj, fid_length);
    return result;
}
static jobject unpack_FloatBuffer_to_jni(JNIEnv* env, const FloatBuffer* st) {
    jclass cls = env->FindClass("nitro/verification_module/FloatBuffer");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(Ljava/lang/Object;J)V");
    return env->NewObject(cls, ctor, env->NewDirectByteBuffer((void*)st->data, st->length), (jlong)st->length);
}

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_jvm = vm;
    __android_log_print(ANDROID_LOG_INFO, "Nitrogen", "JNI_OnLoad called for verification");
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return -1;
    }
    jclass localClass = env->FindClass("nitro/verification_module/VerificationModuleJniBridge");
    if (localClass != nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(localClass);
    } else {
        LOGE("Failed to find JniBridge class");
    }
    return JNI_VERSION_1_6;
}

static JNIEnv* GetEnv() {
    if (g_jvm == nullptr) return nullptr;
    JNIEnv* env = nullptr;
    int status = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        g_jvm->AttachCurrentThread(&env, nullptr);
    }
    return env;
}

double verification_module_multiply(double a, double b) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0.0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "multiply_call", "(DD)D");
    if (methodId == nullptr) { LOGE("Method not found"); return 0.0; }

    NitroClearError();
    double res = env->CallStaticDoubleMethod(g_bridgeClass, methodId, a, b);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return 0.0; }
    return res;
}

const char* verification_module_ping(const char* message) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return "";
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "ping_call", "(Ljava/lang/String;)Ljava/lang/String;");
    if (methodId == nullptr) { LOGE("Method not found"); return ""; }

    NitroClearError();
    jstring j_message = env->NewStringUTF(message);
    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, j_message);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }
    if (jstr == nullptr) return nullptr;
    const char* nativeStr = env->GetStringUTFChars(jstr, 0);
    char* result = strdup(nativeStr);
    env->ReleaseStringUTFChars(jstr, nativeStr);
    env->DeleteLocalRef(j_message);
    env->DeleteLocalRef(jstr);
    return result;
}

const char* verification_module_ping_async(const char* message) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return "";
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "pingAsync_call", "(Ljava/lang/String;)Ljava/lang/String;");
    if (methodId == nullptr) { LOGE("Method not found"); return ""; }

    NitroClearError();
    jstring j_message = env->NewStringUTF(message);
    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, j_message);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }
    if (jstr == nullptr) return nullptr;
    const char* nativeStr = env->GetStringUTFChars(jstr, 0);
    char* result = strdup(nativeStr);
    env->ReleaseStringUTFChars(jstr, nativeStr);
    env->DeleteLocalRef(j_message);
    env->DeleteLocalRef(jstr);
    return result;
}

void verification_module_throw_error(const char* message) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "throwError_call", "(Ljava/lang/String;)V");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }

    NitroClearError();
    jstring j_message = env->NewStringUTF(message);
    env->CallStaticVoidMethod(g_bridgeClass, methodId, j_message);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); }
}

void* verification_module_process_floats(float* inputs) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "processFloats_call", "(Ljava/lang/Object;)Lnitro/verification_module/FloatBuffer;");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }

    NitroClearError();
    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId, inputs);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }
    if (jobj == nullptr) return nullptr;
    FloatBuffer* result = (FloatBuffer*)malloc(sizeof(FloatBuffer));
    *result = pack_FloatBuffer_from_jni(env, jobj);
    env->DeleteLocalRef(jobj);
    return result;
}

JNIEXPORT void JNICALL Java_nitro_verification_1module_VerificationModuleJniBridge_initialize(JNIEnv* env, jobject thiz, jclass bridgeClass) {
    if (g_bridgeClass == nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(bridgeClass);
    }
}

} // extern "C"
#elif __APPLE__
extern "C" {
extern double _call_multiply(double a, double b);
double verification_module_multiply(double a, double b) {
    NitroClearError();
    @try {
        return _call_multiply(a, b);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return 0.0;
    }
}

extern const char* _call_ping(const char* message);
const char* verification_module_ping(const char* message) {
    NitroClearError();
    @try {
        return _call_ping(message);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return "";
    }
}

extern const char* _call_pingAsync(const char* message);
const char* verification_module_ping_async(const char* message) {
    NitroClearError();
    @try {
        return _call_pingAsync(message);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return "";
    }
}

extern void _call_throwError(const char* message);
void verification_module_throw_error(const char* message) {
    NitroClearError();
    @try {
        _call_throwError(message);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
    }
}

extern void* _call_processFloats(float* inputs);
void* verification_module_process_floats(float* inputs) {
    NitroClearError();
    @try {
        return _call_processFloats(inputs);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return nullptr;
    }
}

} // extern "C"
#endif
