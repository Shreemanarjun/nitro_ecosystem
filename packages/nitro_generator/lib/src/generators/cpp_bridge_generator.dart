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

    final libStem = spec.lib.replaceAll('-', '_');
    s.writeln('extern "C" {');
    s.writeln('intptr_t ${libStem}_init_dart_api_dl(void* data) {');
    s.writeln('    return Dart_InitializeApiDL(data);');
    s.writeln('}');
    s.writeln('}');

    s.writeln('static thread_local NitroError g_nitro_error = { 0, nullptr, nullptr, nullptr, nullptr };');
    s.writeln();
    s.writeln('extern "C" {');
    s.writeln('NitroError* ${libStem}_get_error() { return &g_nitro_error; }');
    s.writeln('void ${libStem}_clear_error() {');
    s.writeln('    g_nitro_error.hasError = 0;');
    s.writeln('    if (g_nitro_error.name) { free((void*)g_nitro_error.name); g_nitro_error.name = nullptr; }');
    s.writeln('    if (g_nitro_error.message) { free((void*)g_nitro_error.message); g_nitro_error.message = nullptr; }');
    s.writeln('    if (g_nitro_error.code) { free((void*)g_nitro_error.code); g_nitro_error.code = nullptr; }');
    s.writeln('    if (g_nitro_error.stackTrace) { free((void*)g_nitro_error.stackTrace); g_nitro_error.stackTrace = nullptr; }');
    s.writeln('}');
    s.writeln();
    s.writeln('static void nitro_report_error(const char* name, const char* message, const char* code, const char* stack) {');
    s.writeln('    ${libStem}_clear_error();');
    s.writeln('    g_nitro_error.hasError = 1;');
    s.writeln('    g_nitro_error.name = name ? strdup(name) : strdup("NativeException");');
    s.writeln('    g_nitro_error.message = message ? strdup(message) : strdup("An unknown native exception occurred.");');
    s.writeln('    g_nitro_error.code = code ? strdup(code) : nullptr;');
    s.writeln('    g_nitro_error.stackTrace = stack ? strdup(stack) : nullptr;');
    s.writeln('}');
    s.writeln('}');
    s.writeln('');

    // Preprocessor branch for Android JNI vs iOS Swift
    s.writeln('#ifdef __ANDROID__');
    s.writeln('#include <jni.h>');
    s.writeln('#include <android/log.h>');
    s.writeln(
      '#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "Nitrogen", __VA_ARGS__)',
    );
    s.writeln();
    s.writeln('static JavaVM* g_jvm = nullptr;');
    s.writeln('static jclass g_bridgeClass = nullptr;');
    s.writeln();
    s.writeln('static void nitro_report_jni_exception(JNIEnv* env, jthrowable ex) {');
    s.writeln('    jclass ex_class = env->GetObjectClass(ex);');
    s.writeln('    jclass cls_class = env->FindClass("java/lang/Class");');
    s.writeln('    jmethodID get_name = env->GetMethodID(cls_class, "getName", "()Ljava/lang/String;");');
    s.writeln('    jstring j_name = (jstring)env->CallObjectMethod(ex_class, get_name);');
    s.writeln('    const char* name = env->GetStringUTFChars(j_name, 0);');
    s.writeln();
    s.writeln('    jmethodID get_msg = env->GetMethodID(env->FindClass("java/lang/Throwable"), "getMessage", "()Ljava/lang/String;");');
    s.writeln('    jstring j_msg = (jstring)env->CallObjectMethod(ex, get_msg);');
    s.writeln('    const char* msg = (j_msg != nullptr) ? env->GetStringUTFChars(j_msg, 0) : "No message provided";');
    s.writeln();
    s.writeln('    nitro_report_error(name, msg, nullptr, nullptr);');
    s.writeln();
    s.writeln('    env->ReleaseStringUTFChars(j_name, name);');
    s.writeln('    if (j_msg) env->ReleaseStringUTFChars(j_msg, msg);');
    s.writeln('    env->DeleteLocalRef(ex);');
    s.writeln('}');
    s.writeln();

    // JNI struct unpack helpers (C struct → Java object)
    final enumNames = spec.enums.map((e) => e.name).toSet();
    for (final st in spec.structs) {
      // pack: Java object → C struct (used for stream emit and return values)
      s.writeln(
        'static ${st.name} pack_${st.name}_from_jni(JNIEnv* env, jobject obj) {',
      );
      s.writeln('    ${st.name} result;');
      s.writeln('    jclass cls = env->GetObjectClass(obj);');
      for (final f in st.fields) {
        final isEnumField =
            enumNames.contains(f.type.name.replaceFirst('?', ''));
        final isZeroCopyField = _isZeroCopy(st, f.name);
        // Zero-copy TypedData fields always bridge as java.nio.ByteBuffer.
        final sig = isEnumField
            ? 'J'
            : (isZeroCopyField
                ? 'Ljava/nio/ByteBuffer;'
                : _jniSigType(f.type.name));
        final getter = isEnumField ? 'GetLongField' : _jniGetter(f.type.name);
        s.writeln(
          '    jfieldID fid_${f.name} = env->GetFieldID(cls, "${f.name}", "$sig");',
        );
        if (isZeroCopyField) {
          // GetDirectBufferAddress returns void*; cast to the actual element
          // pointer type so the assignment to the C struct field is valid.
          final elemCast = _zeroCopyCElementCast(f.type.name);
          s.writeln(
            '    jobject buf_${f.name} = env->GetObjectField(obj, fid_${f.name});',
          );
          s.writeln(
            '    result.${f.name} = ($elemCast)env->GetDirectBufferAddress(buf_${f.name});',
          );
        } else if (f.type.name == 'String') {
          s.writeln(
            '    jstring j_${f.name} = (jstring)env->GetObjectField(obj, fid_${f.name});',
          );
          s.writeln(
            '    const char* str_${f.name} = env->GetStringUTFChars(j_${f.name}, 0);',
          );
          s.writeln('    result.${f.name} = strdup(str_${f.name});');
          s.writeln(
            '    env->ReleaseStringUTFChars(j_${f.name}, str_${f.name});',
          );
        } else if (isEnumField) {
          final enumType = f.type.name.replaceFirst('?', '');
          s.writeln(
            '    result.${f.name} = ($enumType)(int32_t)env->$getter(obj, fid_${f.name});',
          );
        } else {
          s.writeln('    result.${f.name} = env->$getter(obj, fid_${f.name});');
        }
      }
      s.writeln('    return result;');
      s.writeln('}');

      // unpack: C struct → Java object (used for passing struct params to Kotlin)
      final jniClass =
          'nitro/${spec.lib.replaceAll('-', '_')}_module/${st.name}';
      // Zero-copy TypedData fields are java.nio.ByteBuffer in Kotlin.
      final ctorSig = '(${st.fields.map((f) {
        final isEnum = enumNames.contains(f.type.name.replaceFirst('?', ''));
        if (isEnum) return 'J';
        if (_isZeroCopy(st, f.name)) return 'Ljava/nio/ByteBuffer;';
        return _jniSigType(f.type.name);
      }).join('')})V';
      s.writeln(
        'static jobject unpack_${st.name}_to_jni(JNIEnv* env, const ${st.name}* st) {',
      );
      s.writeln('    jclass cls = env->FindClass("$jniClass");');
      s.writeln(
        '    jmethodID ctor = env->GetMethodID(cls, "<init>", "$ctorSig");',
      );
      final ctorArgs = st.fields
          .map((f) {
            final isEnum =
                enumNames.contains(f.type.name.replaceFirst('?', ''));
            if (_isZeroCopy(st, f.name)) {
              final lenField = _zeroCopyLenField(st, f.name);
              final elemSize = _zeroCopyElementSizeExpr(f.type.name);
              // NewDirectByteBuffer takes a BYTE count, not element count.
              return 'env->NewDirectByteBuffer((void*)st->${f.name}, st->$lenField$elemSize)';
            } else if (f.type.name == 'String') {
              return 'env->NewStringUTF(st->${f.name})';
            } else if (isEnum) {
              return '(jlong)(int32_t)st->${f.name}';
            } else {
              return '(${_jniCast(f.type.name)})st->${f.name}';
            }
          })
          .join(', ');
      s.writeln('    return env->NewObject(cls, ctor, $ctorArgs);');
      s.writeln('}');
    }
    s.writeln();

    s.writeln('extern "C" {');
    s.writeln();
    s.writeln(
      'JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {',
    );
    s.writeln('    g_jvm = vm;');
    s.writeln(
      '    __android_log_print(ANDROID_LOG_INFO, "Nitrogen", "JNI_OnLoad called for ${spec.lib}");',
    );
    s.writeln('    JNIEnv* env = nullptr;');
    s.writeln(
      '    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {',
    );
    s.writeln('        return -1;');
    s.writeln('    }');
    s.writeln(
      '    jclass localClass = env->FindClass("nitro/${spec.lib.replaceAll('-', '_')}_module/${spec.dartClassName}JniBridge");',
    );
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
    s.writeln(
      '    int status = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);',
    );
    s.writeln('    if (status == JNI_EDETACHED) {');
    s.writeln('        g_jvm->AttachCurrentThread(&env, nullptr);');
    s.writeln('    }');
    s.writeln('    return env;');
    s.writeln('}');
    s.writeln();

    // ── Functions ─────────────────────────────────────────────────────────────
    for (final func in spec.functions) {
      final isEnum = spec.enums.any((en) => en.name == func.returnType.name);
      final isStruct = spec.structs.any(
        (st) => st.name == func.returnType.name,
      );
      // For enum returns: bridge returns Long (nativeValue); C returns int64_t
      // For struct returns: bridge returns jobject; C packs to C struct via malloc
      final cReturnType = isEnum ? 'int64_t' : _typeToC(func.returnType.name);
      final paramsDeclParts = <String>[];
      for (final p in func.params) {
        paramsDeclParts.add('${_paramTypeToC(p.type.name, spec)} ${p.name}');
        if (p.type.isTypedData) paramsDeclParts.add('int64_t ${p.name}_length');
      }
      final paramsDecl = paramsDeclParts.join(', ');
      // JNI signature: enum return is "J" (Long), struct is "Ljava/lang/Object;"
      final jniSig = _jniSig(func.params, func.returnType.name, spec);

      s.writeln(
        '$cReturnType ${func.cSymbol}(${paramsDecl.isEmpty ? 'void' : paramsDecl}) {',
      );
      s.writeln('    JNIEnv* env = GetEnv();');
      if (func.returnType.name == 'void') {
        s.writeln('    if (env == nullptr) return;');
      } else {
        s.writeln(
          '    if (env == nullptr) return ${_defaultValue(cReturnType)};',
        );
      }
      s.writeln(
        '    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "${func.dartName}_call", "$jniSig");',
      );
      if (func.returnType.name == 'void') {
        s.writeln('    if (methodId == nullptr) { LOGE("Method not found"); return; }');
      } else {
        s.writeln('    if (methodId == nullptr) { LOGE("Method not found"); return ${_defaultValue(cReturnType)}; }');
      }
      s.writeln();
      s.writeln('    ${libStem}_clear_error();');

      // Build call args (converting C types to JNI types)
      final callArgsList = <String>[];
      for (final p in func.params) {
        final pt = p.type.name;
        if (pt == 'String') {
          s.writeln('    jstring j_${p.name} = env->NewStringUTF(${p.name});');
          callArgsList.add('j_${p.name}');
        } else if (spec.structs.any((st) => st.name == pt)) {
          s.writeln(
            '    jobject jobj_${p.name} = unpack_${pt}_to_jni(env, (const $pt*)${p.name});',
          );
          callArgsList.add('jobj_${p.name}');
        } else {
          callArgsList.add(p.name);
        }
      }

      final callArgs = callArgsList.join(', ');
      final bridgeArgs = callArgs.isEmpty ? '' : ', $callArgs';

      if (func.returnType.name == 'void') {
        s.writeln(
          '    env->CallStaticVoidMethod(g_bridgeClass, methodId$bridgeArgs);',
        );
      } else if (func.returnType.name == 'double') {
        s.writeln(
          '    double res = env->CallStaticDoubleMethod(g_bridgeClass, methodId$bridgeArgs);',
        );
        s.writeln('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return 0.0; }');
        s.writeln('    return res;');
      } else if (func.returnType.name == 'int') {
        s.writeln(
          '    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);',
        );
        s.writeln('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return 0; }');
        s.writeln('    return res;');
      } else if (func.returnType.name == 'bool') {
        s.writeln(
          '    bool res = env->CallStaticBooleanMethod(g_bridgeClass, methodId$bridgeArgs);',
        );
        s.writeln('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return false; }');
        s.writeln('    return res;');
      } else if (func.returnType.name == 'String') {
        s.writeln(
          '    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);',
        );
        s.writeln('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }');
        s.writeln('    if (jstr == nullptr) return nullptr;');
        s.writeln(
          '    const char* nativeStr = env->GetStringUTFChars(jstr, 0);',
        );
        s.writeln('    char* result = strdup(nativeStr);');
        s.writeln('    env->ReleaseStringUTFChars(jstr, nativeStr);');
        for (final p in func.params) {
          if (p.type.name == 'String') {
            s.writeln('    env->DeleteLocalRef(j_${p.name});');
          }
        }
        s.writeln('    env->DeleteLocalRef(jstr);');
        s.writeln('    return result;');
      } else if (isEnum) {
        // Bridge returns Long (nativeValue)
        s.writeln(
          '    int64_t res = env->CallStaticLongMethod(g_bridgeClass, methodId$bridgeArgs);',
        );
        s.writeln('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return 0; }');
        s.writeln('    return res;');
      } else if (isStruct) {
        // Bridge returns the Kotlin data class; pack it to C struct via malloc
        final stName = func.returnType.name;
        s.writeln(
          '    jobject jobj = env->CallStaticObjectMethod(g_bridgeClass, methodId$bridgeArgs);',
        );
        s.writeln('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); return nullptr; }');
        s.writeln('    if (jobj == nullptr) return nullptr;');
        s.writeln('    $stName* result = ($stName*)malloc(sizeof($stName));');
        s.writeln('    *result = pack_${stName}_from_jni(env, jobj);');
        s.writeln('    env->DeleteLocalRef(jobj);');
        s.writeln('    return result;');
      } else {
        s.writeln('    return ${_defaultValue(cReturnType)};');
      }
      if (func.returnType.name == 'void') {
        s.writeln('    if (env->ExceptionCheck()) { nitro_report_jni_exception(env, env->ExceptionOccurred()); env->ExceptionClear(); }');
      }
      s.writeln('}');
      s.writeln('');
    }

    // ── Properties ────────────────────────────────────────────────────────────
    for (final prop in spec.properties) {
      final isEnum = spec.enums.any((en) => en.name == prop.type.name);
      final cType = isEnum ? 'int64_t' : _typeToC(prop.type.name);

      if (prop.hasGetter) {
        final jniRetSig = isEnum ? 'J' : _jniSigType(prop.type.name);
        s.writeln('$cType ${prop.getSymbol}(void) {');
        s.writeln('    JNIEnv* env = GetEnv();');
        s.writeln('    if (env == nullptr) return ${_defaultValue(cType)};');
        s.writeln(
          '    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "${prop.getSymbol}_call", "()$jniRetSig");',
        );
        s.writeln(
          '    if (methodId == nullptr) { LOGE("Method not found"); return ${_defaultValue(cType)}; }',
        );
        if (prop.type.name == 'double') {
          s.writeln(
            '    return env->CallStaticDoubleMethod(g_bridgeClass, methodId);',
          );
        } else if (prop.type.name == 'int' || isEnum) {
          s.writeln(
            '    return ($cType)env->CallStaticLongMethod(g_bridgeClass, methodId);',
          );
        } else if (prop.type.name == 'bool') {
          s.writeln(
            '    return env->CallStaticBooleanMethod(g_bridgeClass, methodId);',
          );
        } else if (prop.type.name == 'String') {
          s.writeln(
            '    jstring jstr = (jstring)env->CallStaticObjectMethod(g_bridgeClass, methodId);',
          );
          s.writeln(
            '    const char* nativeStr = env->GetStringUTFChars(jstr, 0);',
          );
          s.writeln('    char* result = strdup(nativeStr);');
          s.writeln('    env->ReleaseStringUTFChars(jstr, nativeStr);');
          s.writeln('    env->DeleteLocalRef(jstr);');
          s.writeln('    return result;');
        } else {
          s.writeln('    return ${_defaultValue(cType)};');
        }
        s.writeln('}');
        s.writeln('');
      }

      if (prop.hasSetter) {
        final paramCType = isEnum ? 'int64_t' : _typeToC(prop.type.name);
        final jniParamSig = isEnum ? 'J' : _jniSigType(prop.type.name);
        s.writeln('void ${prop.setSymbol}($paramCType value) {');
        s.writeln('    JNIEnv* env = GetEnv();');
        s.writeln('    if (env == nullptr) return;');
        s.writeln(
          '    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "${prop.setSymbol}_call", "($jniParamSig)V");',
        );
        s.writeln(
          '    if (methodId == nullptr) { LOGE("Method not found"); return; }',
        );
        if (prop.type.name == 'String') {
          s.writeln('    jstring jval = env->NewStringUTF(value);');
          s.writeln(
            '    env->CallStaticVoidMethod(g_bridgeClass, methodId, jval);',
          );
          s.writeln('    env->DeleteLocalRef(jval);');
        } else {
          s.writeln(
            '    env->CallStaticVoidMethod(g_bridgeClass, methodId, value);',
          );
        }
        s.writeln('}');
        s.writeln('');
      }
    }

    // ── Streams ───────────────────────────────────────────────────────────────
    for (final stream in spec.streams) {
      final isStruct = spec.structs.any(
        (st) => st.name == stream.itemType.name,
      );
      // JNI name: "nitro" + "_" + "{lib}_module" (with internal _ → _1)
      // e.g. nitro.my_camera_module → nitro_my_1camera_1module (NOT nitro_1my_1camera_1module)

      s.writeln('void ${stream.registerSymbol}(int64_t dart_port) {');
      s.writeln('    JNIEnv* env = GetEnv();');
      s.writeln('    if (env == nullptr) return;');
      s.writeln(
        '    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "${stream.registerSymbol}_call", "(J)V");',
      );
      s.writeln(
        '    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);',
      );
      s.writeln('}');
      s.writeln('');
      s.writeln('void ${stream.releaseSymbol}(int64_t dart_port) {');
      s.writeln('    JNIEnv* env = GetEnv();');
      s.writeln('    if (env == nullptr) return;');
      s.writeln(
        '    jmethodID methodId = env->GetStaticMethodID(g_bridgeClass, "${stream.releaseSymbol}_call", "(J)V");',
      );
      s.writeln(
        '    if (methodId != nullptr) env->CallStaticVoidMethod(g_bridgeClass, methodId, dart_port);',
      );
      s.writeln('}');
      s.writeln('');

      final jniEmit = _jniMethodName(
        spec.lib,
        spec.dartClassName,
        'emit_${stream.dartName}',
      );
      s.writeln(
        'JNIEXPORT void JNICALL $jniEmit(JNIEnv* env, jobject thiz, jlong dartPort, ${_jniSigTypeC(stream.itemType.name)} item) {',
      );
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
        s.writeln(
          '    ${stream.itemType.name}* st_ptr = (${stream.itemType.name}*)malloc(sizeof(${stream.itemType.name}));',
        );
        s.writeln(
          '    *st_ptr = pack_${stream.itemType.name}_from_jni(env, item);',
        );
        s.writeln('    obj.type = Dart_CObject_kInt64;');
        s.writeln('    obj.value.as_int64 = (intptr_t)st_ptr;');
      } else {
        s.writeln('    obj.type = Dart_CObject_kNull;');
      }
      s.writeln('    Dart_PostCObject_DL(dartPort, &obj);');
      s.writeln('}');
      s.writeln('');
    }

    final jniInit = _jniMethodName(spec.lib, spec.dartClassName, 'initialize');
    s.writeln(
      'JNIEXPORT void JNICALL $jniInit(JNIEnv* env, jobject thiz, jclass bridgeClass) {',
    );
    s.writeln('    if (g_bridgeClass == nullptr) {');
    s.writeln(
      '        g_bridgeClass = (jclass)env->NewGlobalRef(bridgeClass);',
    );
    s.writeln('    }');
    s.writeln('}');
    s.writeln();

    s.writeln('} // extern "C"');

    // ── iOS Swift section ──────────────────────────────────────────────────────
    s.writeln('#elif __APPLE__');
    s.writeln('extern "C" {');
    for (final func in spec.functions) {
      final isEnum = spec.enums.any((en) => en.name == func.returnType.name);
      final cReturnType = isEnum ? 'int64_t' : _typeToC(func.returnType.name);
      final paramParts = <String>[];
      final callParamParts = <String>[];
      for (final p in func.params) {
        paramParts.add('${_paramTypeToC(p.type.name, spec)} ${p.name}');
        callParamParts.add(p.name);
        if (p.type.isTypedData) {
          paramParts.add('int64_t ${p.name}_length');
          callParamParts.add('${p.name}_length');
        }
      }
      final params = paramParts.join(', ');
      final callParams = callParamParts.join(', ');
      s.writeln(
        'extern $cReturnType _call_${func.dartName}(${params.isEmpty ? 'void' : params});',
      );
      s.writeln(
        '$cReturnType ${func.cSymbol}(${params.isEmpty ? 'void' : params}) {',
      );
      s.writeln('    ${libStem}_clear_error();');
      s.writeln('#ifdef __OBJC__');
      s.writeln('    @try {');
      if (func.returnType.name != 'void') {
        s.writeln('        return _call_${func.dartName}($callParams);');
      } else {
        s.writeln('        _call_${func.dartName}($callParams);');
      }
      s.writeln('    } @catch (NSException* e) {');
      s.writeln('        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);');
      if (func.returnType.name != 'void') {
        s.writeln('        return ${_defaultValue(cReturnType)};');
      }
      s.writeln('    }');
      s.writeln('#else');
      if (func.returnType.name != 'void') {
        s.writeln('    return _call_${func.dartName}($callParams);');
      } else {
        s.writeln('    _call_${func.dartName}($callParams);');
      }
      s.writeln('#endif');
      s.writeln('}');
      s.writeln('');
    }

    for (final prop in spec.properties) {
      final isEnum = spec.enums.any((en) => en.name == prop.type.name);
      final cType = isEnum ? 'int64_t' : _typeToC(prop.type.name);
      if (prop.hasGetter) {
        s.writeln('extern $cType _call_get_${prop.dartName}(void);');
        s.writeln('$cType ${prop.getSymbol}(void) {');
        s.writeln('    return _call_get_${prop.dartName}();');
        s.writeln('}');
        s.writeln('');
      }
      if (prop.hasSetter) {
        final paramCType = isEnum ? 'int64_t' : _typeToC(prop.type.name);
        s.writeln('extern void _call_set_${prop.dartName}($paramCType value);');
        s.writeln('void ${prop.setSymbol}($paramCType value) {');
        s.writeln('    _call_set_${prop.dartName}(value);');
        s.writeln('}');
        s.writeln('');
      }
    }

    for (final stream in spec.streams) {
      final isStruct = spec.structs.any(
        (st) => st.name == stream.itemType.name,
      );
      final itemCType = isStruct ? 'void*' : _typeToC(stream.itemType.name);
      s.writeln(
        'void _emit_${stream.dartName}_to_dart(int64_t dartPort, $itemCType item) {',
      );
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
      s.writeln(
        'extern void _register_${stream.dartName}_stream(int64_t dartPort, void (*emitCb)(int64_t, $itemCType));',
      );
      s.writeln('void ${stream.registerSymbol}(int64_t dart_port) {');
      s.writeln(
        '    _register_${stream.dartName}_stream(dart_port, _emit_${stream.dartName}_to_dart);',
      );
      s.writeln('}');
      s.writeln(
        'extern void _release_${stream.dartName}_stream(int64_t dart_port);',
      );
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
      case 'int':
        return 'int64_t';
      case 'double':
        return 'double';
      case 'bool':
        return 'int8_t';
      case 'String':
        return 'const char*';
      case 'Uint8List':
        return 'uint8_t*';
      case 'Int8List':
        return 'int8_t*';
      case 'Int16List':
        return 'int16_t*';
      case 'Int32List':
        return 'int32_t*';
      case 'Uint16List':
        return 'uint16_t*';
      case 'Uint32List':
        return 'uint32_t*';
      case 'Float32List':
        return 'float*';
      case 'Float64List':
        return 'double*';
      case 'Int64List':
        return 'int64_t*';
      case 'Uint64List':
        return 'uint64_t*';
      case 'void':
        return 'void';
      default:
        return 'void*';
    }
}

  /// Like _typeToC but for function parameters (struct params pass as void*)
  static String _paramTypeToC(String dartType, BridgeSpec spec) {
    if (spec.structs.any((st) => st.name == dartType.replaceFirst('?', ''))) {
      return 'void*';
    }
    return _typeToC(dartType);
  }

  static bool _isZeroCopy(BridgeStruct st, String fieldName) {
    return st.fields.any((f) => f.name == fieldName && f.zeroCopy);
  }

  /// Returns the field name used as the byte length for a zero-copy field.
  static String _zeroCopyLenField(BridgeStruct st, String zeroCopyField) {
    // Heuristic: use 'stride' if present, otherwise 'size', otherwise 'length'
    const candidates = ['stride', 'size', 'length'];
    for (final c in candidates) {
      if (st.fields.any((f) => f.name == c)) return c;
    }
    return 'size';
  }

  static String _jniGetter(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int':
        return 'GetLongField';
      case 'double':
        return 'GetDoubleField';
      case 'bool':
        return 'GetBooleanField';
      default:
        return 'GetObjectField';
    }
  }

  static String _defaultValue(String cType) {
    switch (cType) {
      case 'int64_t':
        return '0';
      case 'double':
        return '0.0';
      case 'int8_t':
        return 'false';
      case 'const char*':
        return '""';
      default:
        return 'nullptr';
    }
  }

  static String _jniSigType(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int':
        return 'J';
      case 'double':
        return 'D';
      case 'bool':
        return 'Z';
      case 'String':
        return 'Ljava/lang/String;';
      case 'void':
        return 'V';
      case 'Uint8List':
        return 'Ljava/nio/ByteBuffer;';
      default:
        return 'Ljava/lang/Object;';
    }
  }

  static String _jniSigTypeC(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int':
        return 'jlong';
      case 'double':
        return 'jdouble';
      case 'bool':
        return 'jboolean';
      case 'String':
        return 'jstring';
      case 'void':
        return 'void';
      case 'Uint8List':
        return 'jobject';
      default:
        return 'jobject';
    }
  }

  static String _jniCast(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int':
        return 'jlong';
      case 'double':
        return 'jdouble';
      case 'bool':
        return 'jboolean';
      default:
        return 'jobject';
    }
  }

  /// Returns the C cast type for a zero-copy TypedData struct field.
  ///
  /// `GetDirectBufferAddress` returns `void*`. The struct field type is the
  /// element pointer (e.g. `float*` for Float32List).  An explicit cast avoids
  /// the implicit `void* → typed pointer` conversion warning in C++.
  static String _zeroCopyCElementCast(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'Uint8List':  return 'uint8_t*';
      case 'Int8List':   return 'int8_t*';
      case 'Int16List':  return 'int16_t*';
      case 'Uint16List': return 'uint16_t*';
      case 'Int32List':  return 'int32_t*';
      case 'Uint32List': return 'uint32_t*';
      case 'Float32List': return 'float*';
      case 'Float64List': return 'double*';
      case 'Int64List':  return 'int64_t*';
      case 'Uint64List': return 'uint64_t*';
      default:           return 'uint8_t*';
    }
  }

  /// Returns a C expression suffix to multiply the element count by element
  /// byte-size when calling `NewDirectByteBuffer` (which expects byte count).
  ///
  /// Returns `''` for byte-sized elements (no-op multiply) or
  /// ` * N` for multi-byte elements (e.g. ` * sizeof(float)`).
  static String _zeroCopyElementSizeExpr(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'Uint8List':
      case 'Int8List':
        return ''; // 1 byte — no multiplication needed
      case 'Int16List':
      case 'Uint16List':
        return ' * sizeof(int16_t)';
      case 'Int32List':
      case 'Uint32List':
        return ' * sizeof(int32_t)';
      case 'Float32List':
        return ' * sizeof(float)';
      case 'Float64List':
        return ' * sizeof(double)';
      case 'Int64List':
      case 'Uint64List':
        return ' * sizeof(int64_t)';
      default:
        return '';
    }
  }

  /// Escapes a single JNI identifier component: replaces '_' with '_1'.
  /// JNI spec §2.4: each '.' separator becomes '_', and each '_' within
  /// an identifier becomes '_1'. This function handles the latter.
  static String _jniMangle(String s) => s.replaceAll('_', '_1');

  /// Builds a fully-qualified JNI C function name from logical components.
  ///
  /// Kotlin package: "nitro.{lib}_module"
  /// Examples:
  ///   lib='my_camera', class='MyCamera', method='emit_frames'
  ///     → 'Java_nitro_my_1camera_1module_MyCameraJniBridge_emit_1frames'
  ///   lib='sensor_hub', class='SensorHub', method='emit_sensor_data'
  ///     → 'Java_nitro_sensor_1hub_1module_SensorHubJniBridge_emit_1sensor_1data'
  static String _jniMethodName(
    String lib,
    String className,
    String methodName,
  ) {
    return [
      'Java',
      _jniMangle('nitro'), // 'nitro' (no underscores)
      _jniMangle(
        '${lib.replaceAll('-', '_')}_module',
      ), // e.g. 'my_1camera_1module'
      _jniMangle('${className}JniBridge'), // usually CamelCase — no underscores
      _jniMangle(methodName), // e.g. 'emit_1frames'
    ].join('_');
  }

  static String _jniSig(
    List<BridgeParam> params,
    String returnType,
    BridgeSpec spec,
  ) {
    final sb = StringBuffer();
    sb.write('(');
    for (final p in params) {
      if (spec.structs.any((st) => st.name == p.type.name)) {
        // Struct params are passed as the Kotlin data class object
        final jniClass =
            'nitro/${spec.lib.replaceAll('-', '_')}_module/${p.type.name}';
        sb.write('L${jniClass.replaceAll('/', '/')};');
      } else {
        sb.write(_jniSigType(p.type.name));
      }
    }
    sb.write(')');
    // Enum return type: bridge returns Long
    if (spec.enums.any((en) => en.name == returnType)) {
      sb.write('J');
    } else if (spec.structs.any((st) => st.name == returnType)) {
      final jniClass =
          'nitro/${spec.lib.replaceAll('-', '_')}_module/$returnType';
      sb.write('L${jniClass.replaceAll('/', '/')};');
    } else {
      sb.write(_jniSigType(returnType));
    }
    return sb.toString();
  }
}
