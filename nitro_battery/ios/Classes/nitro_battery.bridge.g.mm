#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include "dart_api_dl.h"
#include "nitro_battery.bridge.g.h"

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

static BatteryInfo pack_BatteryInfo_from_jni(JNIEnv* env, jobject obj) {
    BatteryInfo result;
    jclass cls = env->GetObjectClass(obj);
    jfieldID fid_level = env->GetFieldID(cls, "level", "J");
    result.level = env->GetLongField(obj, fid_level);
    jfieldID fid_chargingState = env->GetFieldID(cls, "chargingState", "J");
    result.chargingState = env->GetLongField(obj, fid_chargingState);
    jfieldID fid_voltage = env->GetFieldID(cls, "voltage", "D");
    result.voltage = env->GetDoubleField(obj, fid_voltage);
    jfieldID fid_temperature = env->GetFieldID(cls, "temperature", "D");
    result.temperature = env->GetDoubleField(obj, fid_temperature);
    return result;
}
static jobject unpack_BatteryInfo_to_jni(JNIEnv* env, const BatteryInfo* st) {
    jclass cls = env->FindClass("nitro/nitro_battery_module/BatteryInfo");
    jmethodID ctor = env->GetMethodID(cls, "<init>", "(JJDD)V");
    return env->NewObject(cls, ctor, (jlong)st->level, (jlong)st->chargingState, (jdouble)st->voltage, (jdouble)st->temperature);
}

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_jvm = vm;
    __android_log_print(ANDROID_LOG_INFO, "Nitrogen", "JNI_OnLoad called for nitro_battery");
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return -1;
    }
    jclass localClass = env->FindClass("nitro/nitro_battery_module/NitroBatteryJniBridge");
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

int64_t nitro_battery_get_battery_level(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getBatteryLevel_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return env->CallStaticLongMethod(g_bridgeClass, methodId);
}

int8_t nitro_battery_is_charging(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return false;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "isCharging_call", "()Z");
    if (methodId == nullptr) { LOGE("Method not found"); return false; }
    return env->CallStaticBooleanMethod(g_bridgeClass, methodId);
}

int64_t nitro_battery_get_charging_state(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getChargingState_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return (int64_t)env->CallStaticLongMethod(g_bridgeClass, methodId);
}

void* nitro_battery_get_battery_info(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return nullptr;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "getBatteryInfo_call", "()Lnitro/nitro_battery_module/BatteryInfo;");
    if (methodId == nullptr) { LOGE("Method not found"); return nullptr; }
    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId);
    if (jobj == nullptr) return nullptr;
    BatteryInfo* result = (BatteryInfo*)malloc(sizeof(BatteryInfo));
    *result = pack_BatteryInfo_from_jni(env, jobj);
    env->DeleteLocalRef(jobj);
    return result;
}

int64_t nitro_battery_get_low_power_threshold(void) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return 0;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "nitro_battery_get_low_power_threshold_call", "()J");
    if (methodId == nullptr) { LOGE("Method not found"); return 0; }
    return (int64_t)env->CallStaticLongMethod(g_bridgeClass, methodId);
}

void nitro_battery_set_low_power_threshold(int64_t value) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "nitro_battery_set_low_power_threshold_call", "(J)V");
    if (methodId == nullptr) { LOGE("Method not found"); return; }
    env->CallStaticVoidMethod(g_bridgeClass, methodId, value);
}

void nitro_battery_register_battery_level_changes_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "nitro_battery_register_battery_level_changes_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

void nitro_battery_release_battery_level_changes_stream(int64_t dart_port) {
    JNIEnv* env = GetEnv();
    if (env == nullptr) return;
    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "nitro_battery_release_battery_level_changes_stream_call", "(J)V");
    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);
}

JNIEXPORT void JNICALL Java_nitro_nitro_1battery_1module_NitroBatteryJniBridge_emit_1batteryLevelChanges(JNIEnv* env, jobject thiz, jlong dartPort, jlong item) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = item;
    Dart_PostCObject_DL(dartPort, &obj);
}

JNIEXPORT void JNICALL Java_nitro_nitro_1battery_1module_NitroBatteryJniBridge_initialize(JNIEnv* env, jobject thiz, jclass bridgeClass) {
    if (g_bridgeClass == nullptr) {
        g_bridgeClass = (jclass)env->NewGlobalRef(bridgeClass);
    }
}

} // extern "C"
#elif __APPLE__
extern "C" {
extern int64_t _call_getBatteryLevel(void);
int64_t nitro_battery_get_battery_level(void) {
    return _call_getBatteryLevel();
}

extern int8_t _call_isCharging(void);
int8_t nitro_battery_is_charging(void) {
    return _call_isCharging();
}

extern int64_t _call_getChargingState(void);
int64_t nitro_battery_get_charging_state(void) {
    return _call_getChargingState();
}

extern void* _call_getBatteryInfo(void);
void* nitro_battery_get_battery_info(void) {
    return _call_getBatteryInfo();
}

extern int64_t _call_get_lowPowerThreshold(void);
int64_t nitro_battery_get_low_power_threshold(void) {
    return _call_get_lowPowerThreshold();
}

extern void _call_set_lowPowerThreshold(int64_t value);
void nitro_battery_set_low_power_threshold(int64_t value) {
    _call_set_lowPowerThreshold(value);
}

void _emit_batteryLevelChanges_to_dart(int64_t dartPort, int64_t item) {
    Dart_CObject obj;
    obj.type = Dart_CObject_kInt64;
    obj.value.as_int64 = (int64_t)item;
    Dart_PostCObject_DL(dartPort, &obj);
}

extern void _register_batteryLevelChanges_stream(int64_t dartPort, void (*emitCb)(int64_t, int64_t));
void nitro_battery_register_battery_level_changes_stream(int64_t dart_port) {
    _register_batteryLevelChanges_stream(dart_port, _emit_batteryLevelChanges_to_dart);
}
extern void _release_batteryLevelChanges_stream(int64_t dart_port);
void nitro_battery_release_battery_level_changes_stream(int64_t dart_port) {
    _release_batteryLevelChanges_stream(dart_port);
}

} // extern "C"
#endif
