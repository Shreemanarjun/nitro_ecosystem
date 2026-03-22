#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include "dart_api_dl.h"
#include "my_camera.bridge.g.h"

extern "C" {
intptr_t InitDartApiDL(void* data) {
    return Dart_InitializeApiDL(data);
}
}

#ifdef __ANDROID__
#include <jni.h>
#include <android/log.h>
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Nitrogen", __VA_ARGS__)

static JavaVM* g_jvm = nullptr;
static jclass g_bridgeClass = nullptr;

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
    return env->CallStaticDoubleMethod(g_bridgeClass, methodId, a, b);
}

const char* my_camera_get_greeting(const char* name) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return "";
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getGreeting_call", "(Ljava/lang/String;)Ljava/lang/String;");
    if (methodId == nullptr) { LOGE("Method not found"); return ""; }
    jstring j_name = env->NewStringUTF(name);
    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, j_name);
    const char* nativeStr = env->GetStringUTFChars(jstr, 0);
    char* result = strdup(nativeStr);
    env->ReleaseStringUTFChars(jstr, nativeStr);
    env->DeleteLocalRef(j_name);
    env->DeleteLocalRef(jstr);
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
    return _call_add(a, b);
}

extern const char* _call_getGreeting(const char* name);
const char* my_camera_get_greeting(const char* name) {
    return _call_getGreeting(name);
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

} // extern "C"
#endif
