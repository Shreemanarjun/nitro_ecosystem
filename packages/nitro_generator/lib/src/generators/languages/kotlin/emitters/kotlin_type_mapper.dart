import '../../../../bridge_spec.dart';
import '../../../type_mapper.dart';

/// Type mapping for Kotlin code generation.
///
/// Constructed once per [BridgeSpec] so enum/struct/record name sets
/// are computed once and reused across all emitters rather than being
/// threaded as parameters through every static call.
///
/// Implements [TypeMapper] so it can be injected into any generator
/// that accepts a generic `TypeMapper`.
class KotlinTypeMapper implements TypeMapper {
  final Set<String> enumNames;
  final Set<String> structNames;
  final Set<String> recordNames;
  final Set<String> variantNames;
  final List<BridgeStruct> structs;

  KotlinTypeMapper({
    required this.enumNames,
    required this.structNames,
    required this.recordNames,
    required this.variantNames,
    required this.structs,
  });

  factory KotlinTypeMapper.fromSpec(BridgeSpec spec) => KotlinTypeMapper(
    enumNames: spec.enums.map((e) => e.name).toSet(),
    structNames: spec.structs.map((s) => s.name).toSet(),
    recordNames: spec.recordTypes.map((r) => r.name).toSet(),
    variantNames: spec.variants.map((v) => v.name).toSet(),
    structs: spec.structs,
  );

  // ── Core type → Kotlin string ───────────────────────────────────────────────

  /// Maps a Dart type name to its Kotlin equivalent.
  ///
  /// Handles primitives, TypedData, function types, enums, structs, and records.
  /// Returns `'Any?'` for unrecognised types.
  String type(String t, {BridgeType? bridgeType}) {
    if (bridgeType?.isNativeHandle == true) return 'Long';
    final name = t.replaceFirst('?', '');

    if (bridgeType != null && bridgeType.isFunction) {
      final returnType = bridgeType.functionReturnType ?? 'Unit';
      final params = bridgeType.functionParams;
      final paramList = params.asMap().entries.map((e) => 'p${e.key}: ${type(e.value.name)}').join(', ');
      return '($paramList) -> ${type(returnType)}';
    }

    switch (name) {
      case 'int':
        return 'Long';
      case 'DateTime':
        return 'Long';
      case 'double':
        return 'Double';
      case 'bool':
        return 'Boolean';
      case 'String':
        return 'String';
      case 'void':
        return 'Unit';
      case 'Uint8List':
      case 'Int8List':
        return 'ByteArray';
      case 'Int16List':
      case 'Uint16List':
        return 'ShortArray';
      case 'Int32List':
      case 'Uint32List':
        return 'IntArray';
      case 'Float32List':
        return 'FloatArray';
      case 'Float64List':
        return 'DoubleArray';
      case 'Int64List':
      case 'Uint64List':
        return 'LongArray';
    }
    if (enumNames.contains(name)) return name;
    if (structNames.contains(name)) return name;
    if (recordNames.contains(name)) return name;
    if (variantNames.contains(name)) return name;
    // Typed generic collections — parse value/item type for type-safe Kotlin interfaces.
    if (name.startsWith('List<') && name.endsWith('>')) {
      final inner = name.substring(5, name.length - 1).trim();
      return 'List<${type(inner)}>';
    }
    if (name.startsWith('Map<') && name.endsWith('>')) {
      final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(name);
      if (m != null) {
        final valueType = m.group(1)!.trim();
        return 'Map<String, ${type(valueType)}>';
      }
    }
    return 'Any?';
  }

  // ── Return types ────────────────────────────────────────────────────────────

  /// Return type for use in the **interface** declaration.
  ///
  /// `List<@HybridRecord>` → `List<T>`, `List<primitive>` → `List<KotlinType>`,
  /// `@HybridRecord` → class name, nullable primitives → nullable Kotlin types.
  String retType(BridgeType t) {
    if (t.isNativeHandle) return 'Long';
    if (t.isAnyMap) return 'Map<String, Any?>';
    if (t.isRecord && !t.isMap) {
      if (t.recordListItemType != null && !t.recordListItemIsPrimitive) {
        final nullSuffix = t.recordListItemIsNullable ? '?' : '';
        return 'List<${t.recordListItemType}$nullSuffix>';
      }
      if (t.recordListItemType != null && t.recordListItemIsPrimitive) {
        return 'List<${type(t.recordListItemType!)}>';
      }
      return t.name;
    }
    final base = type(t.name);
    final isNullable = t.name.endsWith('?');
    final baseName = t.name.replaceFirst('?', '');
    if (isNullable && baseName == 'bool') return 'Boolean?';
    if (isNullable && baseName == 'int') return 'Long?';
    if (isNullable && baseName == 'double') return 'Double?';
    if (isNullable && baseName == 'DateTime') return 'Long?';
    if (isNullable && !base.endsWith('?')) return '$base?';
    return base;
  }

  /// Return type for a function, accounting for `@zeroCopy` TypedData.
  String functionRetType(BridgeFunction func) {
    if (func.zeroCopyReturn && func.returnType.isTypedData) return 'java.nio.ByteBuffer';
    return retType(func.returnType);
  }

  // ── Parameter types ─────────────────────────────────────────────────────────

  /// Parameter type for the **interface** declaration (preserves nullability,
  /// uses `java.nio.ByteBuffer` for zero-copy TypedData params).
  String paramType(BridgeParam p) {
    final isNullable = p.type.name.endsWith('?') || p.isOptional;
    if (p.zeroCopy && p.type.isTypedData) {
      return isNullable ? 'java.nio.ByteBuffer?' : 'java.nio.ByteBuffer';
    }
    final base = type(p.type.name, bridgeType: p.type);
    return isNullable ? '$base?' : base;
  }

  /// Parameter type for the **`_call` JNI bridge method**.
  ///
  /// JNI calls from C++ use primitive descriptors (`J`, `Z`, `D`).
  /// Kotlin nullable wrappers (`Long?`, `Boolean?`) have boxed descriptors
  /// (`Ljava/lang/Long;`) that don't match — causing `NoSuchMethodError`.
  /// For `int?`, `bool?`, `double?` we use the non-nullable primitive type;
  /// Kotlin promotes it automatically when forwarding to the interface.
  String bridgeParamType(BridgeParam p) {
    if (p.type.isFunction) return 'Long';
    if (p.type.isAnyMap) return 'ByteArray';
    if (p.type.isMap) return 'ByteArray';
    final isNullableRecord = p.type.isRecord && (p.type.isNullable || p.type.name.endsWith('?'));
    if (p.type.isRecord) return isNullableRecord ? 'ByteArray?' : 'ByteArray';
    // @NitroVariant params arrive as ByteArray [4B len][1B tag][fields]
    if (variantNames.contains(p.type.name.replaceFirst('?', ''))) return 'ByteArray';

    final isNullable = p.type.name.endsWith('?') || p.isOptional;
    if (!isNullable) {
      final base = p.type.name.replaceFirst('?', '');
      if (enumNames.contains(base)) return 'Long';
      return paramType(p);
    }
    if (p.zeroCopy && p.type.isTypedData) return 'java.nio.ByteBuffer?';

    final baseName = p.type.name.replaceFirst('?', '');
    // Nullable primitives use NitroNullable ByteArray ([B) for JVM descriptor compatibility.
    if (baseName == 'int' || baseName == 'bool' || baseName == 'double' || baseName == 'DateTime') return 'ByteArray';
    if (enumNames.contains(baseName)) return 'Long';
    return '${type(baseName)}?';
  }

  /// Property type for the interface, preserving nullability.
  String propertyType(String t) {
    final base = type(t);
    if (t.endsWith('?') && !base.endsWith('?')) return '$base?';
    return base;
  }

  // ── Callback helpers ────────────────────────────────────────────────────────

  /// JNI-compatible type for a callback parameter in an `_invoke_*` external method.
  ///
  /// All numeric/bool/enum values encode as `Long` to match the synchronous
  /// NativeCallable fast-path. Records encode as `ByteArray`.
  String callbackParamJni(BridgeType t) {
    final base = t.name.replaceFirst('?', '');
    switch (base) {
      case 'double':
        return 'Long'; // IEEE 754 bits via doubleToRawLongBits
      case 'bool':
        return 'Long'; // 1L (true) or 0L (false)
      case 'String':
        return 'String?';
      default:
        if (structNames.contains(base)) return base; // data class
        if (recordNames.contains(base)) return 'ByteArray'; // serialised record
        if (variantNames.contains(base)) return 'ByteArray'; // encoded variant bytes
        return 'Long'; // int, enum rawValue → Long
    }
  }

  /// Kotlin lambda expression that wraps a `Long` function pointer and calls
  /// the C function via a generated `_invoke_*` JNI external method.
  String callbackLambda(BridgeParam p) {
    final cbParams = p.type.functionParams;
    final nativeMethodName = '_invoke_${p.name}';

    // For nullable int/double/bool, use nullable Kotlin types (Long?, Double?, Boolean?).
    String _lambdaParamType(BridgeType cbP) {
      final base = cbP.name.replaceFirst('?', '');
      final isNullable = cbP.name.endsWith('?');
      if (isNullable && (base == 'int' || base == 'double' || base == 'bool')) {
        return '${type(base)}?';
      }
      return type(cbP.name);
    }

    final lambdaParams = cbParams.asMap().entries.map((e) => 'p${e.key}: ${_lambdaParamType(e.value)}').join(', ');

    final nativeArgs = <String>[p.name];
    for (var i = 0; i < cbParams.length; i++) {
      final cbP = cbParams[i];
      final base = cbP.name.replaceFirst('?', '');
      final isNullable = cbP.name.endsWith('?');
      final struct = structs.where((s) => s.name == base).firstOrNull;
      if (struct != null && isExpandableStruct(struct)) {
        for (final f in struct.fields) {
          final fBase = f.type.name.replaceFirst('?', '');
          if (fBase == 'double') {
            nativeArgs.add('java.lang.Double.doubleToRawLongBits(p$i.${f.name})');
          } else if (fBase == 'bool') {
            nativeArgs.add('if (p$i.${f.name}) 1L else 0L');
          } else {
            nativeArgs.add('p$i.${f.name}.toLong()');
          }
        }
      } else if (isNullable && base == 'int') {
        // Nullable int: two-arg (isNull flag, value) to avoid Int64.min sentinel corruption.
        nativeArgs.add('if (p$i == null) 1L else 0L');
        nativeArgs.add('p$i ?: 0L');
      } else if (isNullable && base == 'double') {
        nativeArgs.add('if (p$i == null) 1L else 0L');
        nativeArgs.add('if (p$i != null) java.lang.Double.doubleToRawLongBits(p$i) else 0L');
      } else if (isNullable && base == 'bool') {
        nativeArgs.add('if (p$i == null) 1L else 0L');
        nativeArgs.add('if (p$i == true) 1L else 0L');
      } else if (base == 'bool') {
        nativeArgs.add('if (p$i) 1L else 0L');
      } else if (base == 'double') {
        nativeArgs.add('java.lang.Double.doubleToRawLongBits(p$i)');
      } else if (enumNames.contains(base)) {
        nativeArgs.add('p$i.nativeValue');
      } else if (recordNames.contains(base)) {
        nativeArgs.add('p$i.encode()');
      } else if (variantNames.contains(base)) {
        nativeArgs.add('p$i.encode()');
      } else {
        nativeArgs.add('p$i');
      }
    }

    final invocation = '$nativeMethodName(${nativeArgs.join(', ')})';
    final returnType = (p.type.functionReturnType ?? 'void').replaceFirst('?', '');
    final body = switch (returnType) {
      'void' => invocation,
      'bool' => '$invocation != 0L',
      'double' => 'java.lang.Double.longBitsToDouble($invocation)',
      'String' => invocation,
      final t when enumNames.contains(t) => '$t.fromNative($invocation)',
      // @HybridRecord return: C JNI returns ByteArray with [4B len][payload]; skip prefix and decode.
      final t when recordNames.contains(t) =>
        'run { val _b = $invocation; val _bb = java.nio.ByteBuffer.wrap(_b).order(java.nio.ByteOrder.LITTLE_ENDIAN); _bb.getInt(); $t.decodeFrom(_bb) }',
      // @NitroVariant return: same wire format; decode via fromReader.
      final t when variantNames.contains(t) =>
        'run { val _b = $invocation; val _bb = java.nio.ByteBuffer.wrap(_b).order(java.nio.ByteOrder.LITTLE_ENDIAN); _bb.getInt(); $t.fromReader(RecordReader(_bb)) }',
      _ => invocation,
    };
    return '{ ${lambdaParams.isEmpty ? '' : '$lambdaParams -> '}$body }';
  }

  String callbackReturnJniType(String? dartType) {
    final base = (dartType ?? 'void').replaceFirst('?', '');
    if (base == 'void') return 'Unit';
    if (base == 'String') return 'String';
    // @HybridRecord / @NitroVariant: C JNI invoker returns jbyteArray (encoded bytes).
    if (recordNames.contains(base) || variantNames.contains(base)) return 'ByteArray';
    return 'Long';
  }

  /// Returns `true` when all struct fields are numeric (int/double/bool),
  /// meaning the struct can be expanded to individual `Long` JNI params
  /// for the synchronous NativeCallable.listener fast-path.
  bool isExpandableStruct(BridgeStruct st) {
    const numeric = {'int', 'double', 'bool'};
    return st.fields.every((f) => numeric.contains(f.type.name.replaceFirst('?', '')) && !f.type.isTypedData);
  }

  /// Wraps [body] in a `runBlocking { kotlinx.coroutines.withTimeout(N) { ... } }` block when
  /// the function has an [BridgeFunction.asyncTimeout], otherwise just [body].
  static String runBlockingCall(BridgeFunction func, String body) {
    if (func.asyncTimeout != null) {
      return 'runBlocking { kotlinx.coroutines.withTimeout(${func.asyncTimeout}L) { $body } }';
    }
    return 'runBlocking { $body }';
  }

  // ── TypeMapper interface ─────────────────────────────────────────────────────

  @override
  String forKotlin(BridgeType t, {bool forParam = false}) => forParam ? bridgeParamType(BridgeParam(name: '', type: t)) : type(t.name, bridgeType: t);

  @override
  String forSwift(BridgeType t, {bool forCDecl = false}) => throw UnimplementedError('KotlinTypeMapper does not map Swift types');

  @override
  String forDart(BridgeType t, {bool forNative = false}) => throw UnimplementedError('KotlinTypeMapper does not map Dart FFI types');

  @override
  String forC(BridgeType t) => throw UnimplementedError('KotlinTypeMapper does not map C types');
}
