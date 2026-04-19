// Pure type-mapping helpers used by CppBridgeGenerator.
//
// These functions map Dart type names → their C, JNI, and C JNI
// representations. They are stateless and have no dependencies on the
// surrounding generator class, which makes them trivial to unit test and
// safe to move between files.
//
// **Byte-identical output contract:** every function here must return the
// exact same string it returned before extraction. Golden tests in
// `test/cpp_bridge_generator_test.dart` and `test/jni_perf_test.dart` verify
// this — do not change behavior in this file without updating them.
import '../../bridge_spec.dart';

/// Stateless helpers that map Dart type names → C / JNI / JNI-C type strings.
///
/// Usage: `CppTypeMappings.typeToC('int')` → `'int64_t'`.
///
/// Every method is a pure function of its arguments. There is no mutable
/// state and no lazy caching — callers may invoke these in any order.
class CppTypeMappings {
  CppTypeMappings._();

  /// Maps a Dart type name to its matching C type.
  /// Unknown / aggregate types default to `void*`.
  static String typeToC(String dartType) {
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

  /// Like [typeToC] but for function parameters.
  /// Struct params are passed as `void*` by convention.
  static String paramTypeToC(String dartType, Set<String> structNames) {
    if (structNames.contains(dartType.replaceFirst('?', ''))) {
      return 'void*';
    }
    return typeToC(dartType);
  }

  /// Returns the field name used as the byte length for a zero-copy field.
  /// Heuristic: `stride` → `size` → `length`.
  static String zeroCopyLenField(BridgeStruct st, String zeroCopyField) {
    const candidates = ['stride', 'size', 'length'];
    for (final c in candidates) {
      if (st.fields.any((f) => f.name == c)) return c;
    }
    return 'size';
  }

  /// Returns the JNI `GetXxxField` method name for a Dart type.
  static String jniGetter(String t) {
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

  /// Returns the default value literal for a C type (used when the native
  /// call fails and a fallback return value is needed).
  static String defaultValue(String cType) {
    switch (cType) {
      case 'int64_t':
        return '0';
      case 'double':
        return '0.0';
      case 'int8_t':
        return 'false';
      case 'const char*':
        return 'nullptr';
      default:
        return 'nullptr';
    }
  }

  /// Maps a Dart type to its JVM type signature character(s).
  /// Used inside method signatures like `(JI)V`.
  static String jniSigType(String t) {
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
      // Non-@ZeroCopy TypedData → Kotlin array types
      // (@ZeroCopy variants are intercepted in jniSig before this is called)
      case 'Uint8List':
      case 'Int8List':
        return '[B'; // ByteArray
      case 'Int16List':
      case 'Uint16List':
        return '[S'; // ShortArray
      case 'Int32List':
      case 'Uint32List':
        return '[I'; // IntArray
      case 'Float32List':
        return '[F'; // FloatArray
      case 'Float64List':
        return '[D'; // DoubleArray
      case 'Int64List':
      case 'Uint64List':
        return '[J'; // LongArray
      default:
        return 'Ljava/lang/Object;';
    }
  }

  /// Maps a Dart type to the corresponding JNI C type (`jlong`, `jdouble`…).
  static String jniSigTypeC(String t) {
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

  /// Returns the C cast type used when storing a JNI value into a C variable.
  static String jniCast(String t) {
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

  /// Returns the C element-pointer cast type for a zero-copy TypedData struct
  /// field. `GetDirectBufferAddress` returns `void*`; this cast avoids the
  /// implicit conversion warning in C++.
  static String zeroCopyCElementCast(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'Uint8List':
        return 'uint8_t*';
      case 'Int8List':
        return 'int8_t*';
      case 'Int16List':
        return 'int16_t*';
      case 'Uint16List':
        return 'uint16_t*';
      case 'Int32List':
        return 'int32_t*';
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
      default:
        return 'uint8_t*';
    }
  }

  /// Returns a C expression suffix to multiply an element count by the
  /// element byte-size when calling `NewDirectByteBuffer` (which expects
  /// byte count).
  ///
  /// Returns `''` for byte-sized elements (no-op multiply) or
  /// ` * sizeof(T)` for multi-byte elements.
  static String zeroCopyElementSizeExpr(String dartType) {
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

  /// Escapes a single JNI identifier component: replaces `_` with `_1`.
  ///
  /// JNI spec §2.4: each `.` separator becomes `_`, and each `_` within an
  /// identifier becomes `_1`. This function handles the latter.
  static String jniMangle(String s) => s.replaceAll('_', '_1');

  /// Builds a fully-qualified JNI C function name from logical components.
  ///
  /// Kotlin package: `nitro.{lib}_module`.
  /// Examples:
  ///   `lib='my_camera', class='MyCamera', method='emit_frames'`
  ///     → `Java_nitro_my_1camera_1module_MyCameraJniBridge_emit_1frames`
  static String jniMethodName(
    String lib,
    String className,
    String methodName,
  ) {
    return [
      'Java',
      jniMangle('nitro'), // 'nitro' (no underscores)
      jniMangle('${lib.replaceAll('-', '_')}_module'),
      jniMangle('${className}JniBridge'),
      jniMangle(methodName),
    ].join('_');
  }

  /// Returns `[jniArrayType, newFn, setRegionFn, elemCast]` for a
  /// non-zero-copy TypedData param.
  static List<String> typedDataJniOps(String dartType) {
    switch (dartType) {
      case 'Uint8List':
      case 'Int8List':
        return ['jbyteArray', 'NewByteArray', 'SetByteArrayRegion', 'jbyte'];
      case 'Int16List':
      case 'Uint16List':
        return ['jshortArray', 'NewShortArray', 'SetShortArrayRegion', 'jshort'];
      case 'Int32List':
      case 'Uint32List':
        return ['jintArray', 'NewIntArray', 'SetIntArrayRegion', 'jint'];
      case 'Float32List':
        return ['jfloatArray', 'NewFloatArray', 'SetFloatArrayRegion', 'jfloat'];
      case 'Float64List':
        return ['jdoubleArray', 'NewDoubleArray', 'SetDoubleArrayRegion', 'jdouble'];
      case 'Int64List':
      case 'Uint64List':
        return ['jlongArray', 'NewLongArray', 'SetLongArrayRegion', 'jlong'];
      default:
        return ['jbyteArray', 'NewByteArray', 'SetByteArrayRegion', 'jbyte'];
    }
  }

  /// Builds the full JVM method signature `(params)return` string.
  ///
  /// Handles struct params (Kotlin data classes), zero-copy TypedData
  /// (direct ByteBuffer), enum returns (Long), struct returns, and
  /// `@HybridRecord` returns (byte array).
  static String jniSig(
    List<BridgeParam> params,
    BridgeType returnType,
    Set<String> enumNames,
    Set<String> structNames,
    String libPkg,
  ) {
    final sb = StringBuffer();
    sb.write('(');
    for (final p in params) {
      if (structNames.contains(p.type.name)) {
        // Struct params are passed as the Kotlin data class object
        sb.write('L$libPkg/${p.type.name};');
      } else if (p.zeroCopy && p.type.isTypedData) {
        // Zero-copy TypedData params bridge as java.nio.ByteBuffer (direct)
        sb.write('Ljava/nio/ByteBuffer;');
      } else {
        sb.write(jniSigType(p.type.name));
      }
    }
    sb.write(')');
    // Enum return type: bridge returns Long
    if (enumNames.contains(returnType.name)) {
      sb.write('J');
    } else if (structNames.contains(returnType.name)) {
      sb.write('L$libPkg/${returnType.name};');
    } else if (returnType.isRecord && !returnType.isMap) {
      // @HybridRecord / List<@HybridRecord>: bridge returns ByteArray ("[B")
      sb.write('[B');
    } else {
      sb.write(jniSigType(returnType.name));
    }
    return sb.toString();
  }
}
