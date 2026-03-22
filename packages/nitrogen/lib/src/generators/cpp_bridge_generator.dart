import '../bridge_spec.dart';

class CppBridgeGenerator {
  static String generate(BridgeSpec spec) {
    final s = StringBuffer();
    final headerName = '${spec.lib.replaceAll('-', '_')}.bridge.g.h';

    s.writeln('#include <stdint.h>');
    s.writeln('#include <stdbool.h>');
    s.writeln('#include <string.h>');
    s.writeln('#include <stdlib.h>');
    s.writeln('#include "dart_api_dl.h"');
    s.writeln('#include "$headerName"');
    s.writeln();

    s.writeln('extern "C" {');
    s.writeln('intptr_t InitDartApiDL(void* data) {');
    s.writeln('    return Dart_InitializeApiDL(data);');
    s.writeln('}');
    s.writeln('}');
    s.writeln('');

    // Preprocessor branch for Android JNI vs iOS Swift
    s.writeln('#ifdef __ANDROID__');
    s.writeln('#include <jni.h>');
    s.writeln('#include <android/log.h>');
    s.writeln('#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Nitrogen", __VA_ARGS__)');
    s.writeln();
    s.writeln('static JavaVM* g_jvm = nullptr;');
    s.writeln('static jclass g_bridgeClass = nullptr;');
    s.writeln();

    // JNI struct packing helpers
    for (final st in spec.structs) {
      s.writeln('static ${st.name} pack_${st.name}_from_jni(JNIEnv* env, jobject obj) {');
      s.writeln('    ${st.name} result;');
      s.writeln('    jclass cls = env->GetObjectClass(obj);');
      for (final f in st.fields) {
        final sig = _jniSigType(f.type.name);
        final getter = _jniGetter(f.type.name);
        s.writeln('    jfieldID fid_${f.name} = env->GetFieldID(cls, "${f.name}", "$sig");');
        if (_isZeroCopy(st, f.name)) {
          s.writeln('    jobject buf_${f.name} = env->GetObjectField(obj, fid_${f.name});');
          s.writeln('    result.${f.name} = (uint8_t*)env->GetDirectBufferAddress(buf_${f.name});');
        } else if (f.type.name == 'String') {
          s.writeln('    jstring j_${f.name} = (jstring)env->GetObjectField(obj, fid_${f.name});');
          s.writeln('    const char* str_${f.name} = env->GetStringUTFChars(j_${f.name}, 0);');
          s.writeln('    result.${f.name} = strdup(str_${f.name});');
          s.writeln('    env->ReleaseStringUTFChars(j_${f.name}, str_${f.name});');
        } else {
          s.writeln('    result.${f.name} = env->$getter(obj, fid_${f.name});');
        }
      }
      s.writeln('    return result;');
      s.writeln('}');
    }
    s.writeln();

    s.writeln('extern "C" {');
    s.writeln();
    s.writeln('JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {');
    s.writeln('    g_jvm = vm;');
    s.writeln('    __android_log_print(ANDROID_LOG_INFO, "Nitrogen", "JNI_OnLoad called for ${spec.lib}");');
    s.writeln('    JNIEnv* env = nullptr;');
    s.writeln('    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {');
    s.writeln('        return -1;');
    s.writeln('    }');
    s.writeln('    jclass localClass = env->FindClass("nitro/${spec.lib.replaceAll('-', '_')}_module/${spec.dartClassName}JniBridge");');
    s.writeln('    if (localClass != nullptr) {');
    s.writeln('        g_bridgeClass = (jclass)env->NewGlobalRef(localClass);');
    s.writeln('    } else {');
    s.writeln('        LOGE("Failed to find JniBridge class");');
    s.writeln('    }');
    s.writeln('    return JNI_VERSION_1_6;');
    s.writeln('}');
    s.writeln();
    s.writeln('static JNIEnv* GetEnv() {');
    s.writeln('    if (g_jvm == nullptr) return nullptr;');
    s.writeln('    JNIEnv* env = nullptr;');
    s.writeln('    int status = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);');
    s.writeln('    if (status == JNI_EDETACHED) {');
    s.writeln('        g_jvm->AttachCurrentThread(&env, nullptr);');
    s.writeln('    }');
    s.writeln('    return env;');
    s.writeln('}');
    s.writeln();

    for (final func in spec.functions) {
      final cType = _typeToC(func.returnType.name);
      final paramsDecl = func.params.map((p) => '${_typeToC(p.type.name)} ${p.name}').join(', ');
      final jniSig = _jniSig(func.params, func.returnType.name);

      s.writeln('$cType ${func.cSymbol}(${paramsDecl.isEmpty ? 'void' : paramsDecl}) {');
      s.writeln('    JNIEnv* env = GetEnv();');
      s.writeln('    if (env == nullptr) return ${_defaultValue(func.returnType.name)};');
      s.writeln('    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "${func.dartName}_call", "$jniSig");');
      s.writeln('    if (methodId == nullptr) { LOGE("Method not found"); return ${_defaultValue(func.returnType.name)}; }');

      final callArgsList = <String>[];
      for (final p in func.params) {
        if (p.type.name == 'String') {
          s.writeln('    jstring j_${p.name} = env->NewStringUTF(${p.name});');
          callArgsList.add('j_${p.name}');
        } else {
          callArgsList.add(p.name);
        }
      }

      final callArgs = callArgsList.join(', ');
      final bridgePrefix = callArgs.isEmpty ? '' : ', $callArgs';

      if (func.returnType.name == 'void') {
        s.writeln('    env->CallStaticVoidMethod(g_bridgeClass, methodId$bridgePrefix);');
      } else if (func.returnType.name == 'double') {
        s.writeln('    return env->CallStaticDoubleMethod(g_bridgeClass, methodId$bridgePrefix);');
      } else if (func.returnType.name == 'String') {
        s.writeln('    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgePrefix);');
        s.writeln('    const char* nativeStr = env->GetStringUTFChars(jstr, 0);');
        s.writeln('    char* result = strdup(nativeStr);');
        s.writeln('    env->ReleaseStringUTFChars(jstr, nativeStr);');
        for (final p in func.params) {
          if (p.type.name == 'String') s.writeln('    env->DeleteLocalRef(j_${p.name});');
        }
        s.writeln('    env->DeleteLocalRef(jstr);');
        s.writeln('    return result;');
      } else {
        s.writeln('    return ${_defaultValue(func.returnType.name)};');
      }
      s.writeln('}');
      s.writeln('');
    }

    for (final stream in spec.streams) {
      final isStruct = spec.structs.any((st) => st.name == stream.itemType.name);
      s.writeln('void ${stream.registerSymbol}(int64_t dart_port) {');
      s.writeln('    JNIEnv* env = GetEnv();');
      s.writeln('    if (env == nullptr) return;');
      s.writeln('    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "${stream.registerSymbol}_call", "(J)V");');
      s.writeln('    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);');
      s.writeln('}');
      s.writeln('');
      s.writeln('void ${stream.releaseSymbol}(int64_t dart_port) {');
      s.writeln('    JNIEnv* env = GetEnv();');
      s.writeln('    if (env == nullptr) return;');
      s.writeln('    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "${stream.releaseSymbol}_call", "(J)V");');
      s.writeln('    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);');
      s.writeln('}');
      s.writeln('');

      s.writeln('JNIEXPORT void JNICALL Java_nitro_${spec.lib.replaceAll('-', '_')}_module_${spec.dartClassName}JniBridge_00024emit_${stream.dartName}(JNIEnv* env, jobject thiz, jlong dartPort, ${_jniSigTypeC(stream.itemType.name)} item) {');
      s.writeln('    Dart_CObject obj;');
      if (stream.itemType.name == 'double') {
        s.writeln('    obj.type = Dart_CObject_kDouble;');
        s.writeln('    obj.value.as_double = item;');
      } else if (stream.itemType.name == 'int') {
        s.writeln('    obj.type = Dart_CObject_kInt64;');
        s.writeln('    obj.value.as_int64 = item;');
      } else if (stream.itemType.name == 'bool') {
        s.writeln('    obj.type = Dart_CObject_kBool;');
        s.writeln('    obj.value.as_bool = item;');
      } else if (isStruct) {
        s.writeln('    ${stream.itemType.name}* st_ptr = (${stream.itemType.name}*)malloc(sizeof(${stream.itemType.name}));');
        s.writeln('    *st_ptr = pack_${stream.itemType.name}_from_jni(env, item);');
        s.writeln('    obj.type = Dart_CObject_kInt64;');
        s.writeln('    obj.value.as_int64 = (intptr_t)st_ptr;');
      } else {
        s.writeln('    obj.type = Dart_CObject_kNull;');
      }
      s.writeln('    Dart_PostCObject_DL(dartPort, &obj);');
      s.writeln('}');
      s.writeln('');
    }

    s.writeln('} // extern "C"');
    s.writeln('#elif __APPLE__');
    s.writeln('extern "C" {');
    for (final func in spec.functions) {
      final cType = _typeToC(func.returnType.name);
      final params = func.params.map((p) => '${_typeToC(p.type.name)} ${p.name}').join(', ');
      final callParams = func.params.map((p) => p.name).join(', ');
      s.writeln('extern $cType _call_${func.dartName}(${params.isEmpty ? 'void' : params});');
      s.writeln('$cType ${func.cSymbol}(${params.isEmpty ? 'void' : params}) {');
      if (func.returnType.name != 'void') {
        s.writeln('    return _call_${func.dartName}($callParams);');
      } else {
        s.writeln('    _call_${func.dartName}($callParams);');
      }
      s.writeln('}');
      s.writeln('');
    }

    for (final stream in spec.streams) {
      final isStruct = spec.structs.any((st) => st.name == stream.itemType.name);
      final itemCType = _typeToC(stream.itemType.name);
      s.writeln('void _emit_${stream.dartName}_to_dart(int64_t dartPort, $itemCType item) {');
      s.writeln('    Dart_CObject obj;');
      if (stream.itemType.name == 'double') {
        s.writeln('    obj.type = Dart_CObject_kDouble;');
        s.writeln('    obj.value.as_double = item;');
      } else if (stream.itemType.name == 'int') {
        s.writeln('    obj.type = Dart_CObject_kInt64;');
        s.writeln('    obj.value.as_int64 = (int64_t)item;');
      } else if (stream.itemType.name == 'bool') {
        s.writeln('    obj.type = Dart_CObject_kBool;');
        s.writeln('    obj.value.as_bool = item;');
      } else if (isStruct) {
        s.writeln('    obj.type = Dart_CObject_kInt64;');
        s.writeln('    obj.value.as_int64 = (intptr_t)item;');
      } else {
        s.writeln('    obj.type = Dart_CObject_kNull;');
      }
      s.writeln('    Dart_PostCObject_DL(dartPort, &obj);');
      s.writeln('}');
      s.writeln('');
      s.writeln('extern void _register_${stream.dartName}_stream(int64_t dartPort, void (*emitCb)(int64_t, $itemCType));');
      s.writeln('void ${stream.registerSymbol}(int64_t dart_port) {');
      s.writeln('    _register_${stream.dartName}_stream(dart_port, _emit_${stream.dartName}_to_dart);');
      s.writeln('}');
      s.writeln('extern void _release_${stream.dartName}_stream(int64_t dart_port);');
      s.writeln('void ${stream.releaseSymbol}(int64_t dart_port) {');
      s.writeln('    _release_${stream.dartName}_stream(dart_port);');
      s.writeln('}');
      s.writeln('');
    }
    s.writeln('} // extern "C"');
    s.writeln('#endif');
    return s.toString();
  }

  static String _typeToC(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'int': return 'int64_t';
      case 'double': return 'double';
      case 'bool': return 'int8_t';
      case 'String': return 'const char*';
      case 'Uint8List': return 'uint8_t*';
      case 'void': return 'void';
      default: return 'void*';
    }
  }

  static bool _isZeroCopy(BridgeStruct st, String fieldName) {
    return st.fields.any((f) => f.name == fieldName && f.zeroCopy);
  }

  static String _jniGetter(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int': return 'GetLongField';
      case 'double': return 'GetDoubleField';
      case 'bool': return 'GetBooleanField';
      default: return 'GetObjectField';
    }
  }

  static String _defaultValue(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int': return '0';
      case 'double': return '0.0';
      case 'bool': return 'false';
      case 'String': return '""';
      default: return 'nullptr';
    }
  }

  static String _jniSigType(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int': return 'J';
      case 'double': return 'D';
      case 'bool': return 'Z';
      case 'String': return 'Ljava/lang/String;';
      case 'void': return 'V';
      case 'Uint8List': return 'Ljava/nio/ByteBuffer;';
      default: return 'Ljava/lang/Object;';
    }
  }

  static String _jniSigTypeC(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int': return 'jlong';
      case 'double': return 'jdouble';
      case 'bool': return 'jboolean';
      case 'String': return 'jstring';
      case 'void': return 'void';
      case 'Uint8List': return 'jobject';
      default: return 'jobject';
    }
  }

  static String _jniSig(List<BridgeParam> params, String returnType) {
    final sb = StringBuffer();
    sb.write('(');
    for (final p in params) {
      sb.write(_jniSigType(p.type.name));
    }
    sb.write(')');
    sb.write(_jniSigType(returnType));
    return sb.toString();
  }
}
