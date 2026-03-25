#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include "dart_api_dl.h"
#include "complex.bridge.g.h"

extern "C" {
intptr_t complex_init_dart_api_dl(void* data) {
    return Dart_InitializeApiDL(data);
}
}
static thread_local NitroError g_nitro_error = { 0, nullptr, nullptr, nullptr, nullptr };

extern "C" {
NitroError* complex_get_error() { return &g_nitro_error; }
void complex_clear_error() {
    g_nitro_error.hasError = 0;
    if (g_nitro_error.name) { free((void*)g_nitro_error.name); g_nitro_error.name = nullptr; }
    if (g_nitro_error.message) { free((void*)g_nitro_error.message); g_nitro_error.message = nullptr; }
    if (g_nitro_error.code) { free((void*)g_nitro_error.code); g_nitro_error.code = nullptr; }
    if (g_nitro_error.stackTrace) { free((void*)g_nitro_error.stackTrace); g_nitro_error.stackTrace = nullptr; }
}

static void nitro_report_error(const char* name, const char* message, const char* code, const char* stack) {
    complex_clear_error();
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
static jobject unpack_SensorData_to_jni(JNIEnv* env, const SensorData* st) {
    jclass cls = env->FindClass("nitro/complex_module/SensorData");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(DDJ)V");
    return env->NewObject(cls, ctor, (jdouble)st->temperature, (jdouble)st->humidity, (jlong)st->lastUpdate);
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
static jobject unpack_Packet_to_jni(JNIEnv* env, const Packet* st) {
    jclass cls = env->FindClass("nitro/complex_module/Packet");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(JLjava/nio/ByteBuffer;J)V");
    return env->NewObject(cls, ctor, (jlong)st->sequence, env->NewDirectByteBuffer((void*)st->buffer, st->size), (jlong)st->size);
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

    complex_clear_error();
    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId, seed, factor, enabled);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return 0; }
    return res;
}

const char* complex_module_fetch_metadata(const char* url) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return "";
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "fetchMetadata_call", "(Ljava/lang/String;)Ljava/lang/String;");
    if (methodId == nullptr) { LOGE("Method not found"); return ""; }

    complex_clear_error();
    jstring j_url = env->NewStringUTF(url);
    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId, j_url);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }
    if (jstr == nullptr) return nullptr;
    const char* nativeStr = env->GetStringUTFChars(jstr, 0);
    char* result = strdup(nativeStr);
    env->ReleaseStringUTFChars(jstr, nativeStr);
    env->DeleteLocalRef(j_url);
    env->DeleteLocalRef(jstr);
    return result;
}

int64_t complex_module_get_status(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getStatus_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }

    complex_clear_error();
    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return 0; }
    return res;
}

void complex_module_update_sensors(void* data) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "updateSensors_call", "(Lnitro/complex_module/SensorData;)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }

    complex_clear_error();
    jobject jobj_data = unpack_SensorData_to_jni(env, (const SensorData*)data);
    env->CallStaticVoidMethod(g_bridgeClass, methodId, jobj_data);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); }
}

void* complex_module_generate_packet(int64_t type) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "generatePacket_call", "(J)Lnitro/complex_module/Packet;");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }

    complex_clear_error();
    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId, type);
    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }
    if (jobj == nullptr) return nullptr;
    Packet* result = (Packet*)malloc(sizeof(Packet));
    *result = pack_Packet_from_jni(env, jobj);
    env->DeleteLocalRef(jobj);
    return result;
}

double complex_module_get_battery_level(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0.0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "complex_module_get_battery_level_call", "()D");
    if (methodId == nullptr) { LOGE("Method not found"); return 0.0; }
    return env->CallStaticDoubleMethod(g_bridgeClass, methodId);
}

void complex_module_set_config(const char* value) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "complex_module_set_config_call", "(Ljava/lang/String;)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    jstring jval = env->NewStringUTF(value);
    env->CallStaticVoidMethod(g_bridgeClass, methodId, jval);
    env->DeleteLocalRef(jval);
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

JNIEXPORT void JNICALL Java_nitro_complex_1module_ComplexModuleJniBridge_emit_1sensorStream(JNIEnv* env, jobject thiz, jlong dartPort, jobject item) {
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

JNIEXPORT void JNICALL Java_nitro_complex_1module_ComplexModuleJniBridge_emit_1dataStream(JNIEnv* env, jobject thiz, jlong dartPort, jobject item) {
    Dart_CObject obj;
    Packet* st_ptr = (Packet*)malloc(sizeof(Packet));
    *st_ptr = pack_Packet_from_jni(env, item);
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (intptr_t)st_ptr;
    Dart_PostCObject_DL(dartPort, &obj);
}

JNIEXPORT void JNICALL Java_nitro_complex_1module_ComplexModuleJniBridge_initialize(JNIEnv* env, jobject thiz, jclass bridgeClass) {
    if (g_bridgeClass == nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(bridgeClass);
    }
}

} // extern "C"
#elif __APPLE__
extern "C" {
extern int64_t _call_calculate(int64_t seed, double factor, int8_t enabled);
int64_t complex_module_calculate(int64_t seed, double factor, int8_t enabled) {
    complex_clear_error();
#ifdef __OBJC__
    @try {
        return _call_calculate(seed, factor, enabled);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return 0;
    }
#else
    return _call_calculate(seed, factor, enabled);
#endif
}

extern const char* _call_fetchMetadata(const char* url);
const char* complex_module_fetch_metadata(const char* url) {
    complex_clear_error();
#ifdef __OBJC__
    @try {
        return _call_fetchMetadata(url);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return "";
    }
#else
    return _call_fetchMetadata(url);
#endif
}

extern int64_t _call_getStatus(void);
int64_t complex_module_get_status(void) {
    complex_clear_error();
#ifdef __OBJC__
    @try {
        return _call_getStatus();
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return 0;
    }
#else
    return _call_getStatus();
#endif
}

extern void _call_updateSensors(void* data);
void complex_module_update_sensors(void* data) {
    complex_clear_error();
#ifdef __OBJC__
    @try {
        _call_updateSensors(data);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
    }
#else
    _call_updateSensors(data);
#endif
}

extern void* _call_generatePacket(int64_t type);
void* complex_module_generate_packet(int64_t type) {
    complex_clear_error();
#ifdef __OBJC__
    @try {
        return _call_generatePacket(type);
    } @catch (NSException* e) {
        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);
        return nullptr;
    }
#else
    return _call_generatePacket(type);
#endif
}

extern double _call_get_batteryLevel(void);
double complex_module_get_battery_level(void) {
    return _call_get_batteryLevel();
}

extern void _call_set_config(const char* value);
void complex_module_set_config(const char* value) {
    _call_set_config(value);
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
