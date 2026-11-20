part of '../cpp_bridge_generator.dart';

// Dart type → C type, JNI type and JNI signature tables for the C bridge.
// Every emitter in this library reads these, so a new bridged type starts here.

/// Imported type → owner lib, for JNI class paths built by the static
/// signature helpers below (set per [generate] call; generation is synchronous).
Map<String, String> _jniTypeLibs = const {};

/// JNI package of struct [base]: its owner's when imported, else [libPkg].
String _jniPkg(String base, String libPkg) => _jniTypeLibs.containsKey(base) ? 'nitro/${_jniTypeLibs[base]}_module' : libPkg;

String _typeToC(String dartType, {bool isNativeHandle = false}) {
  if (isNativeHandle) return 'void*'; // NativeHandle<T> is always void*
  if (dartType == 'AnyNativeObject' || dartType == 'AnyNativeObject?') return 'int64_t';
  // Nullable primitives → raw byte pointers (matches Dart Pointer<NitroOptXxx> ABI).
  if (dartType == 'int?') return 'const uint8_t*';
  if (dartType == 'uint64?') return 'const uint8_t*';
  if (dartType == 'double?') return 'const uint8_t*';
  if (dartType == 'bool?') return 'const uint8_t*';
  if (dartType == 'DateTime?') return 'const uint8_t*';
  switch (bareTypeName(dartType)) {
    case 'int':
      return 'int64_t';
    case 'uint64':
      return 'uint64_t';
    case 'DateTime':
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
      // Map<String, T> now bridges as binary uint8_t* (same as @HybridRecord)
      if (dartType.startsWith('Map<')) return 'uint8_t*';
      // NitroAnyMap: same binary uint8_t* wire as Map<String,T> — matched
      // by name since this function only sees the raw type-name string.
      // Without this, the definition fell to the 'void*' default while the
      // separately-generated header declaration already correctly used
      // uint8_t*, producing a C++ "conflicting types" compile error.
      if (bareTypeName(dartType) == 'NitroAnyMap') return 'uint8_t*';
      return 'void*';
  }
}

String _callbackParamToC(BridgeParam param, Set<String> enumNames, {Set<String>? structNames, Set<String>? recordNames, Set<String>? variantNames}) {
  final callback = param.type;
  final ret = _callbackTypeToC(callback.functionReturnType ?? 'void', enumNames, structNames: structNames, recordNames: recordNames);
  // Nullable int/double/bool expand to two int64_t params (isNull + value) to avoid sentinels.
  final paramParts = <String>[];
  for (final p in callback.functionParams) {
    final base = bareTypeName(p.name);
    final isNullable = p.name.endsWith('?');
    if (isNullable && (base == 'int' || base == 'double' || base == 'bool')) {
      paramParts.add('int64_t'); // isNull flag
      paramParts.add('int64_t'); // value bits
    } else {
      paramParts.add(_callbackTypeToC(p.name, enumNames, bridgeType: p, structNames: structNames, recordNames: recordNames));
    }
  }
  final paramStr = paramParts.isEmpty ? 'void' : paramParts.join(', ');
  return '$ret (*${param.name})($paramStr)';
}

String _callbackTypeToC(String dartType, Set<String> enumNames, {BridgeType? bridgeType, Set<String>? structNames, Set<String>? recordNames}) {
  if (bridgeType?.isPointer == true) {
    return _pointerInnerToC(bridgeType!.pointerInnerType);
  }
  final base = bareTypeName(dartType);
  if (enumNames.contains(base)) return 'int64_t';
  // @HybridStruct callback params use void* — uniform across JNI and Swift paths.
  if (structNames?.contains(base) == true) return 'void*';
  // Length-prefixed record buffer: void* like structs/variants, so the definition
  // matches the bridge header's declaration (bodies cast to const uint8_t*).
  if (recordNames?.contains(base) == true) return 'void*';
  // @NitroVariant callback params: void* at the public C API level; the JNI body
  // typedef-casts to (const uint8_t*) and Swift uses @convention(c) (UnsafeMutablePointer<UInt8>?).
  // Both are ABI-compatible with void* on all Nitro target platforms.
  return _typeToC(base);
}

String _pointerInnerToC(String? innerType) {
  switch (innerType) {
    case 'Uint8':
      return 'uint8_t*';
    case 'Int8':
      return 'int8_t*';
    case 'Int16':
      return 'int16_t*';
    case 'Int32':
      return 'int32_t*';
    case 'Uint16':
      return 'uint16_t*';
    case 'Uint32':
      return 'uint32_t*';
    case 'Float':
      return 'float*';
    case 'Double':
      return 'double*';
    case 'Int64':
      return 'int64_t*';
    case 'Uint64':
      return 'uint64_t*';
    case 'Utf8':
    case 'Char':
      return 'char*';
    default:
      return 'void*';
  }
}

/// Like _typeToC but for function parameters (struct params pass as void*)
String _paramTypeToC(String dartType, Set<String> structNames) {
  if (structNames.contains(bareTypeName(dartType))) {
    return 'void*';
  }
  return _typeToC(dartType);
}

/// Element-count divisor when storing capacity from GetDirectBufferCapacity
/// (byte count) into a synthetic length field (element count).
String _elementSizeDivisorExpr(String dartType) {
  switch (bareTypeName(dartType)) {
    case 'Uint8List':
    case 'Int8List':
      return ''; // 1 byte each — no division
    case 'Int16List':
    case 'Uint16List':
      return ' / (jlong)sizeof(int16_t)';
    case 'Int32List':
    case 'Uint32List':
      return ' / (jlong)sizeof(int32_t)';
    case 'Float32List':
      return ' / (jlong)sizeof(float)';
    case 'Float64List':
      return ' / (jlong)sizeof(double)';
    case 'Int64List':
    case 'Uint64List':
      return ' / (jlong)sizeof(int64_t)';
    default:
      return '';
  }
}

String _jniGetter(String t) {
  switch (bareTypeName(t)) {
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

String _defaultValue(String cType) {
  switch (cType) {
    case 'int64_t':
      return '0';
    case 'uint64_t':
      return '0';
    case 'double':
      return '0.0';
    case 'int8_t':
      return 'false'; // used by both bool (explicitly) and int8 (0 == false in C)
    case 'int16_t':
    case 'int32_t':
    case 'uint8_t':
    case 'uint16_t':
    case 'uint32_t':
      return '0';
    case 'intptr_t':
    case 'size_t':
      return '0';
    case 'float':
      return '0.0f';
    case 'const char*':
      return 'nullptr';
    // NitroOpt* value types: zero-initialized struct (hasValue=0 means null).
    case 'NitroOptInt64':
      return 'NitroOptInt64{}';
    case 'NitroOptFloat64':
      return 'NitroOptFloat64{}';
    case 'NitroOptBool':
      return 'NitroOptBool{}';
    default:
      return 'nullptr';
  }
}

String _jniSigType(String t) {
  final base = bareTypeName(t);
  if (base.startsWith('NativeHandle<')) return 'J';
  switch (base) {
    case 'int':
    case 'uint64':
    case 'DateTime':
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
    // (@ZeroCopy variants are intercepted in _jniSig before this is called)
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
    case 'int8':
    case 'uint8':
      return 'B'; // jbyte
    case 'int16':
    case 'uint16':
      return 'S'; // jshort
    case 'int32':
    case 'uint32':
      return 'I'; // jint
    case 'float':
      return 'F'; // jfloat
    case 'intptr':
    case 'size':
      return 'J'; // jlong (64-bit for both)
    default:
      throw StateError(
        'Unknown JNI signature type "$t". Add @HybridStruct/@HybridEnum metadata or a typed-data mapping before generating the C bridge.',
      );
  }
}

String _jniSigTypeC(String t) {
  final base = bareTypeName(t);
  if (base.startsWith('NativeHandle<')) return 'jlong';
  switch (base) {
    case 'int':
    case 'uint64':
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
    case 'int8':
    case 'uint8':
      return 'jbyte';
    case 'int16':
    case 'uint16':
      return 'jshort';
    case 'int32':
    case 'uint32':
      return 'jint';
    case 'float':
      return 'jfloat';
    case 'intptr':
    case 'size':
      return 'jlong';
    default:
      return 'jobject';
  }
}

String _jniCast(String t) {
  switch (bareTypeName(t)) {
    case 'int':
    case 'uint64':
      return 'jlong';
    case 'double':
      return 'jdouble';
    case 'bool':
      return 'jboolean';
    case 'int8':
    case 'uint8':
      return 'jbyte';
    case 'int16':
    case 'uint16':
      return 'jshort';
    case 'int32':
    case 'uint32':
      return 'jint';
    case 'float':
      return 'jfloat';
    case 'intptr':
    case 'size':
      return 'jlong';
    default:
      return 'jobject';
  }
}

/// Returns the C cast type for a zero-copy TypedData struct field.
///
/// `GetDirectBufferAddress` returns `void*`. The struct field type is the
/// element pointer (e.g. `float*` for Float32List).  An explicit cast avoids
/// the implicit `void* → typed pointer` conversion warning in C++.
String _zeroCopyCElementCast(String dartType) {
  switch (bareTypeName(dartType)) {
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

/// Returns a C expression suffix to multiply the element count by element
/// byte-size when calling `NewDirectByteBuffer` (which expects byte count).
///
/// Returns `''` for byte-sized elements (no-op multiply) or
/// ` * N` for multi-byte elements (e.g. ` * sizeof(float)`).
String _zeroCopyElementSizeExpr(String dartType) {
  switch (bareTypeName(dartType)) {
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
String _jniMangle(String s) => s.replaceAll('_', '_1');

/// Builds a fully-qualified JNI C function name from logical components.
///
/// Kotlin package: "nitro.{lib}_module"
/// Examples:
///   lib='my_camera', class='MyCamera', method='emit_frames'
///     → 'Java_nitro_my_1camera_1module_MyCameraJniBridge_emit_1frames'
///   lib='sensor_hub', class='SensorHub', method='emit_sensor_data'
///     → 'Java_nitro_sensor_1hub_1module_SensorHubJniBridge_emit_1sensor_1data'
String _jniMethodName(
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

/// Returns [jniArrayType, newFn, setRegionFn, elemCast, getRegionFn] for a non-zero-copy TypedData param/return.
List<String> _typedDataJniOps(String dartType) {
  // The bare name: `Float64List?` has a jdoubleArray too, not the byte default.
  switch (bareTypeName(dartType)) {
    case 'Uint8List':
    case 'Int8List':
      return ['jbyteArray', 'NewByteArray', 'SetByteArrayRegion', 'jbyte', 'GetByteArrayRegion'];
    case 'Int16List':
    case 'Uint16List':
      return ['jshortArray', 'NewShortArray', 'SetShortArrayRegion', 'jshort', 'GetShortArrayRegion'];
    case 'Int32List':
    case 'Uint32List':
      return ['jintArray', 'NewIntArray', 'SetIntArrayRegion', 'jint', 'GetIntArrayRegion'];
    case 'Float32List':
      return ['jfloatArray', 'NewFloatArray', 'SetFloatArrayRegion', 'jfloat', 'GetFloatArrayRegion'];
    case 'Float64List':
      return ['jdoubleArray', 'NewDoubleArray', 'SetDoubleArrayRegion', 'jdouble', 'GetDoubleArrayRegion'];
    case 'Int64List':
    case 'Uint64List':
      return ['jlongArray', 'NewLongArray', 'SetLongArrayRegion', 'jlong', 'GetLongArrayRegion'];
    default:
      return ['jbyteArray', 'NewByteArray', 'SetByteArrayRegion', 'jbyte', 'GetByteArrayRegion'];
  }
}

String _typedDataElementSizeExpr(String dartType) {
  switch (bareTypeName(dartType)) {
    case 'Uint8List':
    case 'Int8List':
      return 'sizeof(uint8_t)';
    case 'Int16List':
    case 'Uint16List':
      return 'sizeof(int16_t)';
    case 'Int32List':
    case 'Uint32List':
      return 'sizeof(int32_t)';
    case 'Float32List':
      return 'sizeof(float)';
    case 'Float64List':
      return 'sizeof(double)';
    case 'Int64List':
    case 'Uint64List':
      return 'sizeof(int64_t)';
    default:
      return 'sizeof(uint8_t)';
  }
}

String _jniSig(
  List<BridgeParam> params,
  BridgeType returnType,
  Set<String> enumNames,
  Set<String> structNames,
  String libPkg, {
  bool zeroCopyReturn = false,
  bool isResult = false,
  Set<String> variantNames = const {},
  Set<String> customTypeNames = const {},
}) {
  // 'J' prefix for instanceId (Point 13 per-instance dispatch).
  final paramSig = 'J${params.map((p) => _jniParamSig(p, enumNames, structNames, libPkg, variantNames: variantNames, customTypeNames: customTypeNames)).join()}';
  // @NitroResult: Kotlin returns ByteArray [1B tag][payload] → '[B'
  if (isResult) return '($paramSig)[B';
  // Enum return type: bridge returns Long.
  // Nullable bool?: bridge returns Int (I) with -1=null/0=false/1=true.
  final baseRetType = bareTypeName(returnType.name);
  // @NitroVariant: Kotlin returns ByteArray [4B len][1B tag][fields] → '[B'
  final isVariantRet = variantNames.contains(baseRetType);
  final returnSig = switch (baseRetType) {
    _ when isVariantRet => '[B', // @NitroVariant ByteArray
    _ when returnType.isNullableNitroPrim => '[B', // nullable prim ByteArray
    _ when returnType.isAnyNativeObject => 'J', // AnyNativeObject → Long
    final base when customTypeNames.contains(base) => '[B', // @NitroCustomType → ByteArray
    final base when enumNames.contains(base) => 'J',
    final base when structNames.contains(base) => 'L${_jniPkg(base, libPkg)}/$base;',
    _ when zeroCopyReturn && returnType.isTypedData => 'Ljava/nio/ByteBuffer;',
    _ when returnType.isRecord && !returnType.isMap => '[B', // binary record
    _ when returnType.isAnyMap => '[B', // NitroAnyMap: type-tagged binary
    _ when returnType.isMap => '[B', // binary map (replaces JSON)
    _ when returnType.isFunction => 'J',
    _ => _jniSigType(returnType.name),
  };
  return '($paramSig)$returnSig';
}

String _jniNativeAsyncSig(
  List<BridgeParam> params,
  Set<String> enumNames,
  Set<String> structNames,
  String libPkg, {
  Set<String> variantNames = const {},
  Set<String> customTypeNames = const {},
}) {
  final paramSig = params
      .map(
        (p) => _jniParamSig(
          p,
          enumNames,
          structNames,
          libPkg,
          variantNames: variantNames,
          customTypeNames: customTypeNames,
        ),
      )
      .join();
  // 'J' prefix for instanceId, then params, then 'J' for the error-struct
  // address (errPtr), then 'J' for dartPort (Point 13).
  return '(J${paramSig}JJ)V';
}

String _jniParamSig(
  BridgeParam param,
  Set<String> enumNames,
  Set<String> structNames,
  String libPkg, {
  Set<String> variantNames = const {},
  Set<String> customTypeNames = const {},
}) {
  final baseParamType = bareTypeName(param.type.name);
  if (structNames.contains(baseParamType)) {
    // Struct params are passed as the Kotlin data class object.
    return 'L${_jniPkg(baseParamType, libPkg)}/$baseParamType;';
  }
  if (param.zeroCopy && param.type.isTypedData) {
    // Zero-copy TypedData params bridge as java.nio.ByteBuffer.
    return 'Ljava/nio/ByteBuffer;';
  }
  if (enumNames.contains(baseParamType)) return 'J';
  if (param.type.isAnyNativeObject) return 'J'; // AnyNativeObject → Long
  if (customTypeNames.contains(baseParamType)) return '[B'; // @NitroCustomType → ByteArray
  if (param.type.isRecord && !param.type.isMap) return '[B'; // binary record
  if (param.type.isAnyMap) return '[B'; // NitroAnyMap: type-tagged binary
  if (param.type.isMap) return '[B'; // binary map (replaces JSON)
  // @NitroVariant params: encoded as ByteArray [4B len][1B tag][fields]
  if (variantNames.contains(baseParamType)) return '[B';
  // Callback / function-typed params are passed as a long (function pointer).
  if (param.type.isFunction) return 'J';
  // Nullable primitives use NitroNullable ByteArray encoding ([B).
  if (param.type.isNullableNitroPrim) return '[B';
  return _jniSigType(param.type.name);
}
