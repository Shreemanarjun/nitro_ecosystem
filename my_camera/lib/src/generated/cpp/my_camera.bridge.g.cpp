#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include "dart_api_dl.h"
#include "my_camera.bridge.g.h"

extern "C" {
intptr_t my_camera_init_dart_api_dl(void* data) {
    return Dart_InitializeApiDL(data);
}
}
static thread_local NitroError g_nitro_error = { 0, nullptr, nullptr, nullptr, nullptr };

extern "C" {
NitroError* my_camera_get_error() { return &g_nitro_error; }
void my_camera_clear_error() {
    g_nitro_error.hasError = 0;
    if (g_nitro_error.name) { free((void*)g_nitro_error.name); g_nitro_error.name = nullptr; }
    if (g_nitro_error.message) { free((void*)g_nitro_error.message); g_nitro_error.message = nullptr; }
    if (g_nitro_error.code) { free((void*)g_nitro_error.code); g_nitro_error.code = nullptr; }
    if (g_nitro_error.stackTrace) { free((void*)g_nitro_error.stackTrace); g_nitro_error.stackTrace = nullptr; }
}

static void nitro_report_error(const char* name, const char* message, const char* code, const char* stack) {
    my_camera_clear_error();
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
    // MUST clear the pending exception before making any further JNI calls.
    // JNI aborts if any JNI function (e.g. GetObjectClass) is called while
    // an exception is still pending.
    env->ExceptionClear();
    jclass ex_class = env->GetObjectClass(ex);
    jclass cls_class = env->FindClass("java/lang/Class");
    jmethodID get_name = env->GetMethodID(cls_class, "getName", "()Ljava/lang/String;");
    jstring j_name = (jstring)env->CallObjectMethod(ex_class, get_name);
    const char* name = (j_name != nullptr) ? env->GetStringUTFChars(j_name, 0) : "JavaException";

    jmethodID get_msg = env->GetMethodID(env->FindClass("java/lang/Throwable"), "getMessage", "()Ljava/lang/String;");
    jstring j_msg = (jstring)env->CallObjectMethod(ex, get_msg);
    const char* msg = (j_msg != nullptr) ? env->GetStringUTFChars(j_msg, 0) : "No message provided";

    nitro_report_error(name, msg, nullptr, nullptr);

    if (j_name) env->ReleaseStringUTFChars(j_name, name);
    if (j_msg) env->ReleaseStringUTFChars(j_msg, msg);
    env->DeleteLocalRef(ex);
}

static CameraFrame pack_CameraFrame_from_jni(JNIEnv* env, jobject obj) {
    CameraFrame result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_data = env->GetFieldID(cls, "data", "Ljava/nio/ByteBuffer;");
    jobject buf_data = env->GetObjectField(obj, fid_data);
    result.data = (uint8_t*)env->GetDirectBufferAddress(buf_data);
    jfieldID fid_width = env->GetFieldID(cls, "width", "J");
    result.width = env->GetLongField(obj, fid_width);
    jfieldID fid_height = env->GetFieldID(cls, "height", "J");
    result.height = env->GetLongField(obj, fid_height);
    jfieldID fid_stride = env->GetFieldID(cls, "stride", "J");
    result.stride = env->GetLongField(obj, fid_stride);
    jfieldID fid_timestampNs = env->GetFieldID(cls, "timestampNs", "J");
    result.timestampNs = env->GetLongField(obj, fid_timestampNs);
    return result;
}
static jobject unpack_CameraFrame_to_jni(JNIEnv* env, const CameraFrame* st) {
    jclass cls = env->FindClass("nitro/my_camera_module/CameraFrame");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(Ljava/nio/ByteBuffer;JJJJ)V");
    return env->NewObject(cls, ctor, env->NewDirectByteBuffer((void*)st->data, st->stride), (jlong)st->width, (jlong)st->height, (jlong)st->stride, (jlong)st->timestampNs);
}

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_jvm = vm;
    __android_log_print(ANDROID_LOG_INFO, "Nitrogen", "JNI_OnLoad called for my_camera");
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return -1;
    }
    jclass localClass = env->FindClass("nitro/my_camera_module/MyCameraJniBridge");
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

double my_camera_add(double a, double b) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0.0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "add_call", "(DD)D");
    if (methodId == nullptr) { LOGE("Method not found"); return 0.0; }

    my_camera_clear_error();
    double res = env->CallStaticDoubleMethod(g_bridgeClass, methodId, a, b);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return 0.0; }
    return res;
}

const char* my_camera_get_greeting(const char* name) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return "";
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getGreeting_call", "(Ljava/lang/String;)Ljava/lang/String;");
    if (methodId == nullptr) { LOGE("Method not found"); return ""; }

    my_camera_clear_error();
    jstring j_name = env->NewStringUTF(name);
    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, j_name);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }
    if (jstr == nullptr) return nullptr;
    const char* nativeStr = env->GetStringUTFChars(jstr, 0);
    char* result = strdup(nativeStr);
    env->ReleaseStringUTFChars(jstr, nativeStr);
    env->DeleteLocalRef(j_name);
    env->DeleteLocalRef(jstr);
    return result;
}

void* my_camera_get_available_devices(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getAvailableDevices_call", "()[B");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }

    my_camera_clear_error();
    jbyteArray jarr = (jbyteArray)env->CallStaticObjectMethod(g_bridgeClass, methodId);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }
    if (jarr == nullptr) return nullptr;
    jsize len = env->GetArrayLength(jarr);
    uint8_t* result = (uint8_t*)malloc(len);
    env->GetByteArrayRegion(jarr, 0, len, (jbyte*)result);
    env->DeleteLocalRef(jarr);
    return result;
}

void my_camera_register_frames_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "my_camera_register_frames_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

void my_camera_release_frames_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "my_camera_release_frames_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

JNIEXPORT void JNICALL Java_nitro_my_1camera_1module_MyCameraJniBridge_emit_1frames(JNIEnv* env, jobject thiz, jlong dartPort, jobject item) {
    Dart_CObject obj;
    CameraFrame* st_ptr = (CameraFrame*)malloc(sizeof(CameraFrame));
    *st_ptr = pack_CameraFrame_from_jni(env, item);
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)st_ptr;
    Dart_PostCObject_DL(dartPort, &obj);
}

void my_camera_register_colored_frames_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "my_camera_register_colored_frames_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

void my_camera_release_colored_frames_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "my_camera_release_colored_frames_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

JNIEXPORT void JNICALL Java_nitro_my_1camera_1module_MyCameraJniBridge_emit_1coloredFrames(JNIEnv* env, jobject thiz, jlong dartPort, jobject item) {
    Dart_CObject obj;
    CameraFrame* st_ptr = (CameraFrame*)malloc(sizeof(CameraFrame));
    *st_ptr = pack_CameraFrame_from_jni(env, item);
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)st_ptr;
    Dart_PostCObject_DL(dartPort, &obj);
}

JNIEXPORT void JNICALL Java_nitro_my_1camera_1module_MyCameraJniBridge_initialize(JNIEnv* env, jobject thiz, jclass bridgeClass) {
    if (g_bridgeClass == nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(bridgeClass);
    }
}

} // extern "C"
#elif __APPLE__
extern "C" {
extern double _call_add(double a, double b);
double my_camera_add(double a, double b) {
    my_camera_clear_error();
#ifdef __OBJC__
    @try {
        return _call_add(a, b);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return 0.0;
    }
#else
    return _call_add(a, b);
#endif
}

extern const char* _call_getGreeting(const char* name);
const char* my_camera_get_greeting(const char* name) {
    my_camera_clear_error();
#ifdef __OBJC__
    @try {
        return _call_getGreeting(name);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return "";
    }
#else
    return _call_getGreeting(name);
#endif
}

extern void* _call_getAvailableDevices(void);
void* my_camera_get_available_devices(void) {
    my_camera_clear_error();
#ifdef __OBJC__
    @try {
        return _call_getAvailableDevices();
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return nullptr;
    }
#else
    return _call_getAvailableDevices();
#endif
}

void _emit_frames_to_dart(int64_t dartPort, void* item) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)item;
    Dart_PostCObject_DL(dartPort, &obj);
}

extern void _register_frames_stream(int64_t dartPort, void (*emitCb)(int64_t, void*));
void my_camera_register_frames_stream(int64_t dart_port) {
    _register_frames_stream(dart_port, _emit_frames_to_dart);
}
extern void _release_frames_stream(int64_t dart_port);
void my_camera_release_frames_stream(int64_t dart_port) {
    _release_frames_stream(dart_port);
}

void _emit_coloredFrames_to_dart(int64_t dartPort, void* item) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)item;
    Dart_PostCObject_DL(dartPort, &obj);
}

extern void _register_coloredFrames_stream(int64_t dartPort, void (*emitCb)(int64_t, void*));
void my_camera_register_colored_frames_stream(int64_t dart_port) {
    _register_coloredFrames_stream(dart_port, _emit_coloredFrames_to_dart);
}
extern void _release_coloredFrames_stream(int64_t dart_port);
void my_camera_release_colored_frames_stream(int64_t dart_port) {
    _release_coloredFrames_stream(dart_port);
}

} // extern "C"
#endif
