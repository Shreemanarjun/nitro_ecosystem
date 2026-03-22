#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include "dart_api_dl.h"
#include "complex.bridge.g.h"

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

static SensorData pack_SensorData_from_jni(JNIEnv* env, jobject obj) {
    SensorData result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_temperature = env->GetFieldID(cls, "temperature", "D");
    result.temperature = env->GetDoubleField(obj, fid_temperature);
    jfieldID fid_humidity = env->GetFieldID(cls, "humidity", "D");
    result.humidity = env->GetDoubleField(obj, fid_humidity);
    jfieldID fid_lastUpdate = env->GetFieldID(cls, "lastUpdate", "J");
    result.lastUpdate = env->GetLongField(obj, fid_lastUpdate);
    return result;
}
static Packet pack_Packet_from_jni(JNIEnv* env, jobject obj) {
    Packet result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_sequence = env->GetFieldID(cls, "sequence", "J");
    result.sequence = env->GetLongField(obj, fid_sequence);
    jfieldID fid_buffer = env->GetFieldID(cls, "buffer", "Ljava/nio/ByteBuffer;");
    jobject buf_buffer = env->GetObjectField(obj, fid_buffer);
    result.buffer = (uint8_t*)env->GetDirectBufferAddress(buf_buffer);
    jfieldID fid_size = env->GetFieldID(cls, "size", "J");
    result.size = env->GetLongField(obj, fid_size);
    return result;
}

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_jvm = vm;
    __android_log_print(ANDROID_LOG_INFO, "Nitrogen", "JNI_OnLoad called for complex");
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return -1;
    }
    jclass localClass = env->FindClass("nitro/complex_module/ComplexModuleJniBridge");
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

int64_t complex_module_calculate(int64_t seed, double factor, int8_t enabled) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "calculate_call", "(JDZ)J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return 0;
}

const char* complex_module_fetch_metadata(const char* url) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return "";
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "fetchMetadata_call", "(Ljava/lang/String;)Ljava/lang/String;");
    if (methodId == nullptr) { LOGE("Method not found"); return ""; }
    jstring j_url = env->NewStringUTF(url);
    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, j_url);
    const char* nativeStr = env->GetStringUTFChars(jstr, 0);
    char* result = strdup(nativeStr);
    env->ReleaseStringUTFChars(jstr, nativeStr);
    env->DeleteLocalRef(j_url);
    env->DeleteLocalRef(jstr);
    return result;
}

void* complex_module_get_status(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getStatus_call", "()Ljava/lang/Object;");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }
    return nullptr;
}

void complex_module_update_sensors(void* data) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "updateSensors_call", "(Ljava/lang/Object;)V");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, data);
}

void* complex_module_generate_packet(int64_t type) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "generatePacket_call", "(J)Ljava/lang/Object;");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }
    return nullptr;
}

void complex_module_register_sensor_stream_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "complex_module_register_sensor_stream_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

void complex_module_release_sensor_stream_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "complex_module_release_sensor_stream_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

JNIEXPORT void JNICALL Java_nitro_1complex_1module_ComplexModuleJniBridge_emit_1sensorStream(JNIEnv* env, jobject thiz, jlong dartPort, jobject item) {
    Dart_CObject obj;
    SensorData* st_ptr = (SensorData*)malloc(sizeof(SensorData));
    *st_ptr = pack_SensorData_from_jni(env, item);
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)st_ptr;
    Dart_PostCObject_DL(dartPort, &obj);
}

void complex_module_register_data_stream_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "complex_module_register_data_stream_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

void complex_module_release_data_stream_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "complex_module_release_data_stream_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

JNIEXPORT void JNICALL Java_nitro_1complex_1module_ComplexModuleJniBridge_emit_1dataStream(JNIEnv* env, jobject thiz, jlong dartPort, jobject item) {
    Dart_CObject obj;
    Packet* st_ptr = (Packet*)malloc(sizeof(Packet));
    *st_ptr = pack_Packet_from_jni(env, item);
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)st_ptr;
    Dart_PostCObject_DL(dartPort, &obj);
}

JNIEXPORT void JNICALL Java_nitro_1complex_1module_ComplexModuleJniBridge_initialize(JNIEnv* env, jobject thiz, jclass bridgeClass) {
    if (g_bridgeClass == nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(bridgeClass);
    }
}

} // extern "C"
#elif __APPLE__
extern "C" {
extern int64_t _call_calculate(int64_t seed, double factor, int8_t enabled);
int64_t complex_module_calculate(int64_t seed, double factor, int8_t enabled) {
    return _call_calculate(seed, factor, enabled);
}

extern const char* _call_fetchMetadata(const char* url);
const char* complex_module_fetch_metadata(const char* url) {
    return _call_fetchMetadata(url);
}

extern void* _call_getStatus(void);
void* complex_module_get_status(void) {
    return _call_getStatus();
}

extern void _call_updateSensors(void* data);
void complex_module_update_sensors(void* data) {
    _call_updateSensors(data);
}

extern void* _call_generatePacket(int64_t type);
void* complex_module_generate_packet(int64_t type) {
    return _call_generatePacket(type);
}

void _emit_sensorStream_to_dart(int64_t dartPort, void* item) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)item;
    Dart_PostCObject_DL(dartPort, &obj);
}

extern void _register_sensorStream_stream(int64_t dartPort, void (*emitCb)(int64_t, void*));
void complex_module_register_sensor_stream_stream(int64_t dart_port) {
    _register_sensorStream_stream(dart_port, _emit_sensorStream_to_dart);
}
extern void _release_sensorStream_stream(int64_t dart_port);
void complex_module_release_sensor_stream_stream(int64_t dart_port) {
    _release_sensorStream_stream(dart_port);
}

void _emit_dataStream_to_dart(int64_t dartPort, void* item) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)item;
    Dart_PostCObject_DL(dartPort, &obj);
}

extern void _register_dataStream_stream(int64_t dartPort, void (*emitCb)(int64_t, void*));
void complex_module_register_data_stream_stream(int64_t dart_port) {
    _register_dataStream_stream(dart_port, _emit_dataStream_to_dart);
}
extern void _release_dataStream_stream(int64_t dart_port);
void complex_module_release_data_stream_stream(int64_t dart_port) {
    _release_dataStream_stream(dart_port);
}

} // extern "C"
#endif
