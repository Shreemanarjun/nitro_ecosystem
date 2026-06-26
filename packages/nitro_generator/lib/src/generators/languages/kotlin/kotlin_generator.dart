import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../enum_generator.dart';
import '../../generator_metadata.dart';
import '../../record_generator.dart';
import '../../struct_generator.dart';

class KotlinGenerator {
  static String generate(BridgeSpec spec) {
    if (spec.isTypeOnly) return _generateTypeOnly(spec);
    if (spec.androidImpl == null) {
      return '${generatedFileHeader('//', sourceUri: spec.sourceUri)}\n'
          '// Android not targeted — no Kotlin bridge generated.\n';
    }
    final writer = CodeWriter();
    // Pre-build O(1) lookup sets — avoids O(n×m) linear scans inside loops.
    final enumNames = spec.enums.map((e) => e.name).toSet();
    final structNames = spec.structs.map((st) => st.name).toSet();
    final recordNames = spec.recordTypes.map((rt) => rt.name).toSet();
    final hasStreams = spec.streams.isNotEmpty;
    final hasAsyncFunctions = spec.functions.any((f) => f.isAsync || f.isNativeAsync);
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    writer.line('package nitro.${spec.lib.replaceAll('-', '_')}_module');
    writer.blankLine();
    writer.line('import android.app.Activity');
    writer.line('import android.content.Context');
    writer.line('import androidx.annotation.Keep');
    if (hasStreams) {
      writer.line('import kotlinx.coroutines.flow.Flow');
      writer.line('import kotlinx.coroutines.launch');
      writer.line('import kotlinx.coroutines.CoroutineScope');
      writer.line('import kotlinx.coroutines.Dispatchers');
    }
    final hasTimeoutFunctions = spec.functions.any((f) => f.isAsync && f.asyncTimeout != null);
    if (hasAsyncFunctions) {
      writer.line('import kotlinx.coroutines.runBlocking');
    }
    if (hasTimeoutFunctions) {
      writer.line('import kotlinx.coroutines.withTimeout');
    }
    writer.blankLine();

    final kotlinEnums = EnumGenerator.generateKotlin(spec);
    if (kotlinEnums.isNotEmpty) writer.raw(kotlinEnums);

    final kotlinStructs = StructGenerator.generateKotlin(spec);
    if (kotlinStructs.isNotEmpty) writer.raw(kotlinStructs);

    final kotlinRecords = RecordGenerator.generateKotlin(spec);
    if (kotlinRecords.isNotEmpty) writer.raw(kotlinRecords);

    // ── Interface ─────────────────────────────────────────────────────────
    writer.line('/**');
    writer.line(' * Contract for the [${spec.dartClassName}] module.');
    writer.line(' * Implement this in your Kotlin source code.');
    writer.line(' * Nitro may call this implementation from any JNI thread.');
    writer.line(' * Keep mutable state thread-safe or marshal work onto your own dispatcher.');
    writer.line(' */');
    writer.line('interface Hybrid${spec.dartClassName}Spec {');
    writer.line(
      '    val applicationContext: Context get() = ${spec.dartClassName}JniBridge.applicationContext',
    );
    writer.line(
      '    val activity: Activity? get() = ${spec.dartClassName}JniBridge.activity',
    );
    writer.blankLine();
    writer.line('    // Optional lifecycle hooks — override only what you need.');
    writer.line('    fun onAttached() {}');
    writer.line('    fun onDetached() {}');
    writer.line('    fun onActivityAttached(activity: Activity) {}');
    writer.line('    fun onActivityDetached() {}');
    writer.blankLine();

    for (final func in spec.functions) {
      if (func.lineNumber != null) {
        writer.line('    // source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
      }
      final retType = _toKotlinFunctionRetType(enumNames, structNames, recordNames, func);
      final params = func.params.map((p) => '${p.name}: ${_toKotlinParamType(enumNames, structNames, recordNames, p)}').join(', ');
      final suspend = (func.isAsync || func.isNativeAsync) ? 'suspend ' : '';
      // Use the actual return type (enum/struct/record class) in the interface
      writer.line('    ${suspend}fun ${func.dartName}($params): $retType');
    }
    // Note: interface uses strong types; JniBridge _call methods may use primitive
    // bridge types (Long for enums) so that C JNI can read them directly.

    for (final prop in spec.properties) {
      final kt = _toKotlinPropertyType(enumNames, structNames, recordNames, prop.type.name);
      if (prop.hasSetter) {
        writer.line('    var ${prop.dartName}: $kt');
      } else {
        writer.line('    val ${prop.dartName}: $kt');
      }
    }

    for (final stream in spec.streams) {
      final itemType = _toKotlinType(enumNames, structNames, recordNames, stream.itemType.name, bridgeType: stream.itemType);
      writer.line('    val ${stream.dartName}: Flow<$itemType>');
    }

    writer.line('}');
    writer.blankLine();

    // ── JNI Bridge ────────────────────────────────────────────────────────
    writer.line('@Keep');
    writer.line('object ${spec.dartClassName}JniBridge {');
    writer.line(
      '    private var implementation: Hybrid${spec.dartClassName}Spec? = null',
    );
    if (hasAsyncFunctions) {
      writer.line(
        '    private val _asyncExecutor = java.util.concurrent.Executors.newCachedThreadPool()',
      );
    }
    writer.blankLine();
    writer.line('    lateinit var applicationContext: Context');
    writer.line('        private set');
    writer.blankLine();
    writer.line('    var activity: Activity? = null');
    writer.line('        private set');
    writer.blankLine();
    writer.line('    @JvmStatic external fun initialize(bridgeClass: Class<*>)');
    writer.blankLine();
    writer.line('    fun register(impl: Hybrid${spec.dartClassName}Spec, context: Context) {');
    writer.line('        applicationContext = context');
    writer.line('        implementation = impl');
    writer.line('        initialize(this::class.java)');
    writer.line('        impl.onAttached()');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun onDetached() {');
    writer.line('        implementation?.onDetached()');
    writer.line('        activity = null');
    writer.line('        implementation = null');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun onActivityAttached(newActivity: Activity) {');
    writer.line('        activity = newActivity');
    writer.line('        implementation?.onActivityAttached(newActivity)');
    writer.line('    }');
    writer.blankLine();
    writer.line('    fun onActivityDetached() {');
    writer.line('        activity = null');
    writer.line('        implementation?.onActivityDetached()');
    writer.line('    }');
    writer.blankLine();

    // Emit postXxxToPort helpers only when the spec has @NitroNativeAsync methods
    final hasNativeAsync = spec.functions.any((f) => f.isNativeAsync);
    if (hasNativeAsync) {
      writer.line('    // @NitroNativeAsync helpers — post primitive results via Dart_PostCObject_DL.');
      writer.line('    @JvmStatic external fun postNullToPort(dartPort: Long)');
      writer.line('    @JvmStatic external fun postInt64ToPort(dartPort: Long, value: Long)');
      writer.line('    @JvmStatic external fun postDoubleToPort(dartPort: Long, value: Double)');
      writer.line('    @JvmStatic external fun postBoolToPort(dartPort: Long, value: Boolean)');
      writer.line('    @JvmStatic external fun postStringToPort(dartPort: Long, value: String)');
      writer.blankLine();
    }

    for (final func in spec.functions) {
      if (func.lineNumber != null) {
        writer.line('    // source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
      }
      final retType = _toKotlinFunctionRetType(enumNames, structNames, recordNames, func);

      // JNI _call bridge must use non-nullable primitives (Long, Boolean, Double) for
      // optional int?/bool?/double? params so the JVM method descriptor (J/Z/D) matches
      // what C++ registers via GetStaticMethodID. Reference types (String?, structs) stay
      // nullable because JNI can pass null object references.
      // Kotlin auto-promotes Long → Long? when forwarding to the interface, so the call
      // body needs no special handling.
      final bridgeParamsDecl = func.params.map((p) => '${p.name}: ${_toKotlinBridgeParamType(enumNames, structNames, recordNames, p)}').join(', ');

      if (func.isNativeAsync) {
        // ── @NitroNativeAsync — launch a coroutine and post the result ────────
        // The _call method accepts an extra Long dartPort and returns immediately.
        // The coroutine runs on Dispatchers.IO and posts the result via JNI
        // Dart_PostCObject_DL when the suspend function completes.
        final isUnit = (retType == 'Unit');
        final isEnum = enumNames.contains(func.returnType.name);
        final portParamDecl = bridgeParamsDecl.isEmpty ? 'dartPort: Long' : '$bridgeParamsDecl, dartPort: Long';
        // Sentinel unwrapping for optional primitives (same logic as regular path).
        final nativeAsyncOptPrims = func.params.where((p) {
          final bn = p.type.name.replaceFirst('?', '');
          final isnull = p.type.name.endsWith('?') || p.isOptional;
          return isnull && (bn == 'int' || bn == 'bool' || bn == 'double');
        }).toList();
        final callParamsNativeAsync = func.params
            .map((p) {
              final bn = p.type.name.replaceFirst('?', '');
              final isnull = p.type.name.endsWith('?') || p.isOptional;
              if (isnull && (bn == 'int' || bn == 'bool' || bn == 'double')) {
                return '${p.name}Arg';
              }
              return p.name;
            })
            .join(', ');
        writer.line('    @JvmStatic fun ${func.dartName}_call($portParamDecl) {');
        writer.line('        val impl = implementation ?: run {');
        writer.line('            postNullToPort(dartPort)');
        writer.line('            return');
        writer.line('        }');
        // Emit NitroNullable decode before the execute block.
        for (final p in nativeAsyncOptPrims) {
          final bn = p.type.name.replaceFirst('?', '');
          if (bn == 'int') {
            writer.line('        val ${p.name}Arg: Long? = NitroNullableInt.decode(${p.name}).nullable');
          } else if (bn == 'bool') {
            writer.line('        val ${p.name}Arg: Boolean? = NitroNullableBool.decode(${p.name}).nullable');
          } else if (bn == 'double') {
            writer.line('        val ${p.name}Arg: Double? = NitroNullableDouble.decode(${p.name}).nullable');
          }
        }
        writer.line('        _asyncExecutor.execute {');
        if (isUnit) {
          writer.line('            runBlocking { impl.${func.dartName}($callParamsNativeAsync) }');
          writer.line('            postNullToPort(dartPort)');
        } else if (isEnum) {
          writer.line('            val result = runBlocking { impl.${func.dartName}($callParamsNativeAsync) }');
          writer.line('            postInt64ToPort(dartPort, result.nativeValue)');
        } else if (retType == 'String') {
          writer.line('            val result = runBlocking { impl.${func.dartName}($callParamsNativeAsync) }');
          writer.line('            postStringToPort(dartPort, result)');
        } else if (retType == 'Boolean') {
          writer.line('            val result = runBlocking { impl.${func.dartName}($callParamsNativeAsync) }');
          writer.line('            postBoolToPort(dartPort, result)');
        } else if (retType == 'Long' || retType == 'Int') {
          writer.line('            val result = runBlocking { impl.${func.dartName}($callParamsNativeAsync) }');
          writer.line('            postInt64ToPort(dartPort, result.toLong())');
        } else if (retType == 'Double') {
          writer.line('            val result = runBlocking { impl.${func.dartName}($callParamsNativeAsync) }');
          writer.line('            postDoubleToPort(dartPort, result)');
        } else {
          // Fallback for record/struct: post null (advanced types can be added later)
          writer.line('            runBlocking { impl.${func.dartName}($callParamsNativeAsync) }');
          writer.line('            postNullToPort(dartPort)');
        }
        writer.line('        }');
        writer.line('    }');
        continue;
      }

      // ── Regular (sync / @nitroAsync) method ────────────────────────────────
      final isUnit = (retType == 'Unit');
      final retBaseName = func.returnType.name.replaceFirst('?', '');
      final isEnum = enumNames.contains(retBaseName);
      final isNullableEnum = isEnum && func.returnType.name.endsWith('?');
      final isRecord = func.returnType.isRecord && !func.returnType.isMap;
      final isMap = func.returnType.isMap;
      final isListRecord = isRecord && func.returnType.recordListItemType != null && !func.returnType.recordListItemIsPrimitive;
      // Nullable bool? now uses NitroNullable ByteArray encoding.
      final isNullableBoolReturn = retBaseName == 'bool' && func.returnType.name.endsWith('?');
      final isNullableIntReturn = retBaseName == 'int' && func.returnType.name.endsWith('?');
      final isNullableDoubleReturn = retBaseName == 'double' && func.returnType.name.endsWith('?');
      // JniBridge _call methods expose primitive bridge types to JNI:
      // enums → Long (nativeValue), records → ByteArray (serialized binary),
      // maps → ByteArray (binary-encoded, replaces JSON for NaN/Inf/perf/precision),
      // nullable int?/double?/bool? → ByteArray (NitroNullable binary encoding),
      // else → actual type.
      final bridgeRetType = (isNullableBoolReturn || isNullableIntReturn || isNullableDoubleReturn)
          ? 'ByteArray'
          : isEnum
          ? 'Long'
          : isRecord
          // Nullable @HybridRecord returns ByteArray? (null when impl returns null).
          ? (func.returnType.name.endsWith('?') ? 'ByteArray?' : 'ByteArray')
          : isMap
          ? 'ByteArray'  // binary map encoding
          : retType;

      // Identify optional-primitive params that need NitroNullable decoding.
      // Dart sends ByteArray (NitroNullable binary) for int?/bool?/double?.
      // Decode to Kotlin nullable type before forwarding to interface.
      final optionalPrimParams = func.params.where((p) {
        final baseName = p.type.name.replaceFirst('?', '');
        final isNullable = p.type.name.endsWith('?') || p.isOptional;
        return isNullable && (baseName == 'int' || baseName == 'bool' || baseName == 'double');
      }).toList();

      // callParams: for optional-primitive params use the decoded Arg variable.
      // For callback params, wrap the Long function pointer in a Kotlin lambda
      // that invokes the C function via a native JNI bridge method.
      final callParamsResolved = func.params
          .map((p) {
            final baseName = p.type.name.replaceFirst('?', '');
            final isNullable = p.type.name.endsWith('?') || p.isOptional;
            // Nullable primitives decoded from NitroNullable ByteArray → Arg variable.
            if (isNullable && (baseName == 'int' || baseName == 'bool' || baseName == 'double')) {
              return '${p.name}Arg';
            }
            // Nullable enum: decoded from Long sentinel into EnumType? Arg variable above.
            if (isNullable && enumNames.contains(baseName)) {
              return '${p.name}Arg';
            }
            // Enum params: _call receives Long rawValue; decode to enum type for impl.
            if (enumNames.contains(baseName)) {
              if (isNullable) {
                return 'if (${p.name} < 0L) null else $baseName.fromNative(${p.name})';
              }
              return '$baseName.fromNative(${p.name})';
            }
            if (p.type.isFunction) {
              // Wrap Long function pointer in a Kotlin lambda.
              return _emitCallbackLambda(p, enumNames, structNames: structNames, recordNames: recordNames, structs: spec.structs);
            }
            // Record params are deserialized from ByteArray — use decoded variable.
            if (p.type.isRecord && p.type.recordListItemType == null && !p.type.isMap) {
              return '${p.name}Decoded';
            }
            if (p.type.isRecord && p.type.recordListItemType != null && !p.type.recordListItemIsPrimitive) {
              return '${p.name}Decoded';
            }
            if (p.type.isRecord && p.type.recordListItemIsPrimitive) {
              return '${p.name}Decoded';
            }
            return p.name;
          })
          .join(', ');

      writer.line(
        '    @JvmStatic fun ${func.dartName}_call($bridgeParamsDecl): $bridgeRetType {',
      );
      writer.line(
        '        val impl = implementation ?: throw IllegalStateException("${spec.dartClassName} not registered")',
      );
      // Emit NitroNullable decode for optional-primitive params.
      // Dart layer sends ByteArray (NitroNullable binary) for int?/double?/bool?.
      for (final p in optionalPrimParams) {
        final baseName = p.type.name.replaceFirst('?', '');
        if (baseName == 'int') {
          writer.line('        // Dart layer sends NitroNullableInt (ByteArray) for ${p.name}.');
          writer.line('        val ${p.name}Arg: Long? = NitroNullableInt.decode(${p.name}).nullable');
        } else if (baseName == 'bool') {
          writer.line('        // Dart layer sends NitroNullableBool (ByteArray) for ${p.name}.');
          writer.line('        val ${p.name}Arg: Boolean? = NitroNullableBool.decode(${p.name}).nullable');
        } else if (baseName == 'double') {
          writer.line('        // Dart layer sends NitroNullableDouble (ByteArray) for ${p.name}.');
          writer.line('        val ${p.name}Arg: Double? = NitroNullableDouble.decode(${p.name}).nullable');
        }
      }
      // Decode nullable enum params: _call receives Long sentinel (-1 = null).
      for (final p in func.params) {
        final baseName = p.type.name.replaceFirst('?', '');
        final isNullable = p.type.name.endsWith('?') || p.isOptional;
        if (isNullable && enumNames.contains(baseName)) {
          writer.line('        // Dart layer sends -1L as sentinel when caller passes null for ${p.name}.');
          writer.line('        val ${p.name}Arg: $baseName? = if (${p.name} < 0L) null else $baseName.fromNative(${p.name})');
        }
      }

      // Deserialize record params from ByteArray → Kotlin type.
      // Dart's RecordWriter.toNative() format: [4B payload_len][payload_bytes].
      // C passes the FULL buffer; skip the 4-byte prefix then call decodeFrom.
      for (final p in func.params) {
        if (p.type.isRecord && p.type.recordListItemType == null && !p.type.isMap) {
          final recordName = p.type.name.replaceFirst('?', '');
          final isNullableRec = p.type.isNullable || p.type.name.endsWith('?');
          if (isNullableRec) {
            // Nullable record: ByteArray? — null means the Dart caller passed null.
            writer.line('        val ${p.name}Decoded: $recordName? = if (${p.name} == null) null else {');
            writer.line('            val _buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
            writer.line('            _buf.getInt() // skip 4-byte prefix');
            writer.line('            $recordName.decodeFrom(_buf)');
            writer.line('        }');
          } else {
            writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
            writer.line('        ${p.name}Buf.getInt() // skip Dart 4-byte outer length prefix');
            writer.line('        val ${p.name}Decoded = $recordName.decodeFrom(${p.name}Buf)');
          }
        } else if (p.type.isRecord && p.type.recordListItemType != null && !p.type.recordListItemIsPrimitive) {
          // List<@HybridRecord> — decode from Dart's indexed binary format:
          // [4B outer_len][4B count][8B×count offsets][item_fields...]
          final itemTypeName = p.type.recordListItemType!;
          writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
          writer.line('        ${p.name}Buf.getInt() // skip outer length');
          writer.line('        val ${p.name}Count = ${p.name}Buf.getInt()');
          writer.line('        repeat(${p.name}Count) { ${p.name}Buf.getLong() } // skip offsets');
          // decodeFrom(ByteBuffer) is the overload that reads from an existing buffer position.
          // decode(ByteArray) wraps the array first — wrong here since we already have a buffer.
          writer.line('        val ${p.name}Decoded = mutableListOf<$itemTypeName>()');
          writer.line('        repeat(${p.name}Count) { ${p.name}Decoded.add($itemTypeName.decodeFrom(${p.name}Buf)) }');
        } else if (p.type.isRecord && p.type.recordListItemIsPrimitive) {
          // Primitive list — decode from Dart's indexed binary format:
          // [4B outer_len][4B count][8B×count offsets][items...]
          final itemTypeName = p.type.recordListItemType!;
          final listKtType = switch (itemTypeName) {
            'int' => 'ArrayList<Long>',
            'double' => 'ArrayList<Double>',
            'String' => 'ArrayList<String>',
            _ => 'ArrayList<Any>',
          };
          writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
          writer.line('        ${p.name}Buf.getInt() // skip outer length');
          writer.line('        val ${p.name}Count = ${p.name}Buf.getInt()');
          writer.line('        repeat(${p.name}Count) { ${p.name}Buf.getLong() } // skip offsets');
          writer.line('        val ${p.name}Decoded = $listKtType()');
          // ByteBuffer has no getString() — read length-prefixed UTF-8 bytes manually.
          if (itemTypeName == 'String') {
            writer.line('        repeat(${p.name}Count) {');
            writer.line('            val len = ${p.name}Buf.getInt()');
            writer.line('            val strBytes = ByteArray(len)');
            writer.line('            ${p.name}Buf.get(strBytes)');
            writer.line('            ${p.name}Decoded.add(strBytes.toString(Charsets.UTF_8))');
            writer.line('        }');
          } else {
            final readMethod = switch (itemTypeName) {
              'int' => 'getLong',
              'double' => 'getDouble',
              _ => 'getLong',
            };
            writer.line('        repeat(${p.name}Count) { ${p.name}Decoded.add(${p.name}Buf.$readMethod()) }');
          }
        }
      }
      // Timeout-aware runBlocking expression (used in isAsync paths).
      final rb = func.asyncTimeout != null
          ? 'runBlocking { withTimeout(${func.asyncTimeout}L) { impl.${func.dartName}($callParamsResolved) } }'
          : 'runBlocking { impl.${func.dartName}($callParamsResolved) }';
      if (isMap) {
        // Map<String, T>: binary decode input ByteArray, call impl, binary encode result.
        final mapParamName = func.params.isNotEmpty ? func.params.first.name : 'value';
        // Extract map value type from the return type annotation
        final mapValueType = (() {
          final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(func.returnType.name);
          return m?.group(1)?.trim() ?? 'Any?';
        })();
        writer.line('        @Suppress("UNCHECKED_CAST")');
        // Binary map decode: [4B payloadLen][4B count][entries: [4B kLen][kBytes][1B tag][vBytes]]
        // Tag values (must match Dart/Swift): 1=int64, 2=float64, 3=bool, 4=string
        writer.line('        val _mapBuf = java.nio.ByteBuffer.wrap($mapParamName).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        _mapBuf.position(4) // skip 4-byte payload length prefix');
        writer.line('        val _mapCount = _mapBuf.int');
        writer.line('        val _inputMap = mutableMapOf<String, Any?>()');
        writer.line('        repeat(_mapCount) {');
        writer.line('            val kLen = _mapBuf.int; val kBytes = ByteArray(kLen); _mapBuf.get(kBytes)');
        writer.line('            val k = kBytes.toString(Charsets.UTF_8)');
        // Skip the tag byte (typed maps have a fixed type, tag is always the same but must be consumed)
        writer.line('            _mapBuf.get() // skip 1-byte type tag');
        // Decode value based on known type
        if (mapValueType == 'int' || mapValueType == 'Long') {
          writer.line('            _inputMap[k] = _mapBuf.long');
        } else if (mapValueType == 'double' || mapValueType == 'Double') {
          writer.line('            _inputMap[k] = _mapBuf.double');
        } else if (mapValueType == 'bool' || mapValueType == 'Boolean') {
          writer.line('            _inputMap[k] = _mapBuf.get().toInt() != 0');
        } else if (mapValueType == 'String') {
          writer.line('            val vLen = _mapBuf.int; val vBytes = ByteArray(vLen); _mapBuf.get(vBytes)');
          writer.line('            _inputMap[k] = vBytes.toString(Charsets.UTF_8)');
        } else {
          // Generic/record: decode as string (tag 4 already consumed)
          writer.line('            val vLen = _mapBuf.int; val vBytes = ByteArray(vLen); _mapBuf.get(vBytes)');
          writer.line('            _inputMap[k] = vBytes.toString(Charsets.UTF_8)');
        }
        writer.line('        }');
        if (func.isAsync) {
          final rbMap = func.asyncTimeout != null
              ? 'runBlocking { withTimeout(${func.asyncTimeout}L) { impl.${func.dartName}(_inputMap) } }'
              : 'runBlocking { impl.${func.dartName}(_inputMap) }';
          writer.line('        val _result = _asyncExecutor.submit(java.util.concurrent.Callable { $rbMap }).get()');
        } else {
          writer.line('        val _result = impl.${func.dartName}(_inputMap)');
        }
        writer.line('        @Suppress("UNCHECKED_CAST")');
        // Inline binary map encode
        writer.line('        val _outMap = _result as? Map<String, Any?> ?: emptyMap()');
        writer.line('        val _outBb = java.io.ByteArrayOutputStream()');
        writer.line('        val _outBuf = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        fun _writeInt32(v: Int) { _outBuf.clear(); _outBuf.putInt(v); _outBb.write(_outBuf.array(), 0, 4) }');
        writer.line('        fun _writeInt64(v: Long) { _outBuf.clear(); _outBuf.putLong(v); _outBb.write(_outBuf.array()) }');
        writer.line('        fun _writeDouble(v: Double) { _outBuf.clear(); _outBuf.putDouble(v); _outBb.write(_outBuf.array()) }');
        writer.line('        _writeInt32(_outMap.size)');
        // Binary map encode: write [4B kLen][kBytes][1B tag][vBytes] per entry.
        // Tags must match Dart/Swift format: 1=int64, 2=float64, 3=bool, 4=string.
        writer.line('        for ((k, v) in _outMap) {');
        writer.line('            val kb = k.toByteArray(Charsets.UTF_8); _writeInt32(kb.size); _outBb.write(kb)');
        if (mapValueType == 'int' || mapValueType == 'Long') {
          writer.line('            _outBb.write(1) // tag: int64');
          writer.line('            _writeInt64(v as Long)');
        } else if (mapValueType == 'double' || mapValueType == 'Double') {
          writer.line('            _outBb.write(2) // tag: float64');
          writer.line('            _writeDouble(v as Double)');
        } else if (mapValueType == 'bool' || mapValueType == 'Boolean') {
          writer.line('            _outBb.write(3) // tag: bool');
          writer.line('            _outBb.write(if (v as Boolean) 1 else 0)');
        } else if (mapValueType == 'String') {
          writer.line('            _outBb.write(4) // tag: string');
          writer.line('            val vb = (v as String).toByteArray(Charsets.UTF_8); _writeInt32(vb.size); _outBb.write(vb)');
        } else {
          writer.line('            _outBb.write(4) // tag: string (generic fallback)');
          writer.line('            val vb = v.toString().toByteArray(Charsets.UTF_8); _writeInt32(vb.size); _outBb.write(vb)');
        }
        writer.line('        }');
        writer.line('        val _payload = _outBb.toByteArray()');
        writer.line('        val _lenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        _lenBuf.putInt(_payload.size)');
        writer.line('        return _lenBuf.array() + _payload');
      } else if (isRecord) {
        // Fetch the result, then serialize to ByteArray for JNI
        if (func.isAsync) {
          writer.line('        val result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
        } else {
          writer.line('        val result = impl.${func.dartName}($callParamsResolved)');
        }
        if (isListRecord) {
          // Serialize List<@HybridRecord> → indexed ByteArray.
          // Wire format (matches Dart LazyRecordList / encodeIndexedList):
          //   [4B outer_len] [4B count] [8B × count offsets] [item bytes...]
          // Offsets are byte positions FROM the payload start (i.e. after outer 4B prefix).
          // Each offset points to the start of that item's fields in the payload.
          final itemTypeName = func.returnType.recordListItemType!;
          final itemRt = spec.recordTypes.where((rt) => rt.name == itemTypeName).firstOrNull;
          final perItemHint = itemRt != null ? RecordGenerator.recordBytesHint(itemRt) : 64;
          writer.line('        val itemBufs = ArrayList<ByteArray>(result.size)');
          writer.line('        val tmpBuf = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
          writer.line('        for (item in result) {');
          writer.line('            val tmpOut = java.io.ByteArrayOutputStream($perItemHint)');
          writer.line('            item.writeFieldsTo(tmpOut, tmpBuf)');
          writer.line('            itemBufs.add(tmpOut.toByteArray())');
          writer.line('        }');
          writer.line('        // payload = [4B count][8B × n offsets][item bytes...]');
          writer.line('        var offsetPos = 4 + 8L * result.size  // start of item data in payload');
          writer.line('        val offsets = LongArray(result.size)');
          writer.line('        for (i in result.indices) { offsets[i] = offsetPos; offsetPos += itemBufs[i].size }');
          writer.line('        val payloadBuf = java.nio.ByteBuffer.allocate(offsetPos.toInt()).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
          writer.line('        payloadBuf.putInt(result.size)');
          writer.line('        offsets.forEach { payloadBuf.putLong(it) }');
          writer.line('        itemBufs.forEach { payloadBuf.put(it) }');
          writer.line('        val payload = payloadBuf.array()');
          writer.line('        val lenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
          writer.line('        lenBuf.putInt(payload.size)');
          writer.line('        return lenBuf.array() + payload');
        } else if (func.returnType.recordListItemIsPrimitive) {
          // Primitive list → binary encode: [4B outer_len][4B count][items...]
          final itemTypeName = func.returnType.recordListItemType!;
          final itemSize = switch (itemTypeName) {
            'int' => 8,
            'double' => 8,
            'String' => -1, // variable-length, handled separately
            _ => 8,
          };
          if (itemSize > 0) {
            // Fixed-size primitives (Long, Double)
            writer.line('        val count = result.size');
            writer.line('        val payloadSize = 4 + $itemSize * count');
            writer.line('        val buf = java.nio.ByteBuffer.allocate(4 + payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
            writer.line('        buf.putInt(payloadSize)');
            writer.line('        buf.putInt(count)');
            final putMethod = switch (itemTypeName) {
              'int' => 'putLong',
              'double' => 'putDouble',
              _ => 'putLong',
            };
            // bool is encoded as Long (0L/1L); Boolean needs explicit conversion.
            final encodeExpr = itemTypeName == 'bool' ? 'if (it) 1L else 0L' : 'it';
            writer.line('        result.forEach { buf.$putMethod($encodeExpr) }');
            writer.line('        return buf.array()');
          } else {
            // Variable-length strings
            writer.line('        val baos = java.io.ByteArrayOutputStream()');
            writer.line('        val lenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
            writer.line('        val strLenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
            writer.line('        val items = result.map { it.toByteArray(Charsets.UTF_8) }');
            writer.line('        val payloadSize = 4 + items.sumOf { 4 + it.size }');
            writer.line('        lenBuf.putInt(payloadSize)');
            writer.line('        baos.write(lenBuf.array())');
            writer.line('        lenBuf.clear(); lenBuf.putInt(items.size); lenBuf.flip()');
            writer.line('        baos.write(lenBuf.array())');
            writer.line('        for (item in items) { strLenBuf.clear(); strLenBuf.putInt(item.size); strLenBuf.flip(); baos.write(strLenBuf.array()); baos.write(item) }');
            writer.line('        return baos.toByteArray()');
          }
        } else {
          // Single @HybridRecord — encode() wraps with 4-byte length prefix.
          // Nullable record: return null ByteArray when result is null.
          final isNullableRecord = func.returnType.name.endsWith('?');
          if (isNullableRecord) {
            writer.line('        return result?.encode()');
          } else {
            writer.line('        return result.encode()');
          }
        }
      } else if (func.isAsync) {
        if (isEnum) {
          if (isNullableEnum) {
            writer.line('        val _enumResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
            writer.line('        return if (_enumResult == null) -1L else _enumResult.nativeValue');
          } else {
            writer.line(
              '        return _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get().nativeValue',
            );
          }
        } else if (isNullableBoolReturn) {
          // Nullable bool? async: encode via NitroNullableBool → ByteArray.
          writer.line('        val _boolResult = _asyncExecutor.submit(java.util.concurrent.Callable {');
          writer.line('            $rb');
          writer.line('        }).get()');
          writer.line('        return NitroNullableBool(_boolResult).encode()');
        } else if (isNullableIntReturn) {
          // Nullable int? async: encode via NitroNullableInt → ByteArray.
          writer.line('        val _intResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
          writer.line('        return NitroNullableInt(_intResult).encode()');
        } else if (isNullableDoubleReturn) {
          // Nullable double? async: encode via NitroNullableDouble → ByteArray.
          writer.line('        val _doubleResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
          writer.line('        return NitroNullableDouble(_doubleResult).encode()');
        } else {
          writer.line('        return _asyncExecutor.submit(java.util.concurrent.Callable {');
          writer.line('            $rb');
          writer.line('        }).get()');
        }
      } else {
        if (isUnit) {
          writer.line('        impl.${func.dartName}($callParamsResolved)');
        } else if (isEnum) {
          if (isNullableEnum) {
            // Explicit null check instead of ?. chain to avoid Kotlin JVM null-boxing edge cases
            writer.line('        val _enumResult = impl.${func.dartName}($callParamsResolved)');
            writer.line('        return if (_enumResult == null) -1L else _enumResult.nativeValue');
          } else {
            writer.line(
              '        return impl.${func.dartName}($callParamsResolved).nativeValue',
            );
          }
        } else if (isNullableBoolReturn) {
          // Nullable bool? sync: encode via NitroNullableBool → ByteArray.
          writer.line('        val _boolResult = impl.${func.dartName}($callParamsResolved)');
          writer.line('        return NitroNullableBool(_boolResult).encode()');
        } else if (isNullableIntReturn) {
          // Nullable int? sync: encode via NitroNullableInt → ByteArray.
          writer.line('        val _intResult = impl.${func.dartName}($callParamsResolved)');
          writer.line('        return NitroNullableInt(_intResult).encode()');
        } else if (isNullableDoubleReturn) {
          // Nullable double? sync: encode via NitroNullableDouble → ByteArray.
          writer.line('        val _doubleResult = impl.${func.dartName}($callParamsResolved)');
          writer.line('        return NitroNullableDouble(_doubleResult).encode()');
        } else {
          writer.line('        return impl.${func.dartName}($callParamsResolved)');
        }
      }
      writer.line('    }');
    }

    for (final prop in spec.properties) {
      final propTypeName = prop.type.name;
      final propBaseName = propTypeName.replaceFirst('?', '');
      final isNullableProp = propTypeName.endsWith('?');
      final isEnum = enumNames.contains(propBaseName);
      final isNullableEnum = isEnum && isNullableProp;
      final isNullableInt = propBaseName == 'int' && isNullableProp;
      final isNullableDouble = propBaseName == 'double' && isNullableProp;
      final isNullableBool = propBaseName == 'bool' && isNullableProp;

      // _call bridge type: must match C-side JVM descriptor (jni_method_emitter.dart).
      // Nullable primitives now use NitroNullable ByteArray encoding ([B JVM descriptor).
      final String bridgeKt;
      if (isEnum) {
        bridgeKt = 'Long'; // Enum rawValue as jlong
      } else if (isNullableInt) {
        bridgeKt = 'ByteArray'; // int? uses NitroNullableInt ([B)
      } else if (isNullableDouble) {
        bridgeKt = 'ByteArray'; // double? uses NitroNullableDouble ([B)
      } else if (isNullableBool) {
        bridgeKt = 'ByteArray'; // bool? uses NitroNullableBool ([B)
      } else {
        final kt = _toKotlinPropertyType(enumNames, structNames, recordNames, propTypeName);
        bridgeKt = kt;
      }

      if (prop.hasGetter) {
        writer.line('    @JvmStatic fun ${prop.getSymbol}_call(): $bridgeKt {');
        writer.line(
          '        val impl = implementation ?: throw IllegalStateException("${spec.dartClassName} not registered")',
        );
        if (isEnum && isNullableEnum) {
          // Explicit null check for nullable enum property getter
          writer.line('        val _propVal = impl.${prop.dartName}');
          writer.line('        return if (_propVal == null) -1L else _propVal.nativeValue');
        } else if (isEnum) {
          writer.line('        return impl.${prop.dartName}.nativeValue');
        } else if (isNullableInt) {
          // NitroNullableInt binary encoding — ByteArray return.
          writer.line('        return NitroNullableInt(impl.${prop.dartName}).encode()');
        } else if (isNullableDouble) {
          // NitroNullableDouble binary encoding — ByteArray return.
          writer.line('        return NitroNullableDouble(impl.${prop.dartName}).encode()');
        } else if (isNullableBool) {
          // NitroNullableBool binary encoding — ByteArray return.
          writer.line('        return NitroNullableBool(impl.${prop.dartName}).encode()');
        } else {
          writer.line('        return impl.${prop.dartName}');
        }
        writer.line('    }');
      }

      if (prop.hasSetter) {
        writer.line(
          '    @JvmStatic fun ${prop.setSymbol}_call(value: $bridgeKt) {',
        );
        writer.line(
          '        val impl = implementation ?: throw IllegalStateException("${spec.dartClassName} not registered")',
        );
        if (isEnum && isNullableEnum) {
          writer.line(
            '        impl.${prop.dartName} = if (value < 0L) null else $propBaseName.fromNative(value)',
          );
        } else if (isEnum) {
          writer.line('        impl.${prop.dartName} = $propBaseName.fromNative(value)');
        } else if (isNullableInt) {
          // NitroNullableInt binary decode from ByteArray.
          writer.line('        impl.${prop.dartName} = NitroNullableInt.decode(value).nullable');
        } else if (isNullableDouble) {
          // NitroNullableDouble binary decode from ByteArray.
          writer.line('        impl.${prop.dartName} = NitroNullableDouble.decode(value).nullable');
        } else if (isNullableBool) {
          // NitroNullableBool binary decode from ByteArray.
          writer.line('        impl.${prop.dartName} = NitroNullableBool.decode(value).nullable');
        } else {
          writer.line('        impl.${prop.dartName} = value');
        }
        writer.line('    }');
      }
    }

    writer.line(
      '    private val _streamJobs = java.util.concurrent.ConcurrentHashMap<Pair<String, Long>, kotlinx.coroutines.Job>()',
    );
    writer.blankLine();

    for (final stream in spec.streams) {
      final itemKotlinType = _toKotlinType(enumNames, structNames, recordNames, stream.itemType.name);
      if (stream.isBatch) {
        // Batch mode: accumulate up to batchMaxSize items, emit as LongArray.
        writer.line('    @JvmStatic external fun emit_${stream.dartName}_batch(dartPort: Long, batch: LongArray): Boolean');
      } else {
        writer.line('    @JvmStatic external fun emit_${stream.dartName}(dartPort: Long, item: $itemKotlinType): Boolean');
      }
      writer.blankLine();
      writer.line('    @JvmStatic fun ${stream.registerSymbol}_call(dartPort: Long) {');
      writer.line('        val impl = implementation ?: return');
      writer.line('        _streamJobs[Pair("${stream.dartName}", dartPort)] = CoroutineScope(Dispatchers.Default).launch {');
      if (stream.isBatch) {
        final batchMax = stream.batchMaxSize;
        final itemBase = stream.itemType.name.replaceFirst('?', '');
        writer.line('            val _buf = ArrayList<Long>($batchMax)');
        writer.line('            fun _flush() {');
        writer.line('                if (_buf.isEmpty()) return');
        writer.line('                val arr = LongArray(_buf.size + 1); arr[0] = _buf.size.toLong()');
        writer.line('                _buf.forEachIndexed { i, v -> arr[i + 1] = v }');
        writer.line('                _buf.clear()');
        writer.line('                emit_${stream.dartName}_batch(dartPort, arr)');
        writer.line('            }');
        // Periodic flush so partial batches (< batchMax items) are delivered when
        // the flow is a hot source (MutableSharedFlow etc.) that never completes.
        // delay() throws CancellationException when the job is cancelled — no need for isActive check.
        writer.line('            val _flushJob = launch { while (true) { kotlinx.coroutines.delay(10); _flush() } }');
        writer.line('            impl.${stream.dartName}.collect { item ->');
        // Encode item as Long (raw bits for double, 1/0 for bool, direct for int)
        if (itemBase == 'double') {
          writer.line('                _buf.add(java.lang.Double.doubleToRawLongBits(item))');
        } else if (itemBase == 'bool') {
          writer.line('                _buf.add(if (item) 1L else 0L)');
        } else {
          writer.line('                _buf.add(item.toLong())');
        }
        writer.line('                if (_buf.size >= $batchMax) _flush()');
        writer.line('            }');
        writer.line('            _flushJob.cancel()');
        writer.line('            _flush()');
      } else {
        writer.line('            impl.${stream.dartName}.collect { item -> ');
        writer.line('                if (!emit_${stream.dartName}(dartPort, item)) {');
        writer.line('                    _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
        writer.line('                    return@collect');
        writer.line('                }');
        writer.line('            }');
      }
      writer.line('        }');
      writer.line('    }');
      writer.line('    @JvmStatic fun ${stream.releaseSymbol}_call(dartPort: Long) {');
      writer.line('        _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
      writer.line('    }');
    }

    // ── Native callback invoker methods ──────────────────────────────────────
    // For each function-typed parameter, emit a native JNI method that invokes
    // the C function pointer.  The Kotlin _call method wraps the Long pointer
    // in a lambda that delegates to this native method.
    final callbackNativeMethods = <String>{};
    for (final func in spec.functions) {
      for (final p in func.params) {
        if (!p.type.isFunction) continue;
        final nativeName = '_invoke_${p.name}';
        if (!callbackNativeMethods.add(nativeName)) continue;
        final cbParams = p.type.functionParams;
        final paramDecl = StringBuffer('callbackPtr: Long');
        for (var i = 0; i < cbParams.length; i++) {
          final base = cbParams[i].name.replaceFirst('?', '');
          final struct = spec.structs.where((s) => s.name == base).firstOrNull;
          if (struct != null && _isExpandableStruct(struct)) {
            // Expand struct fields to individual Long params → fires NativeCallable synchronously.
            for (final f in struct.fields) {
              paramDecl.write(', arg${i}_${f.name}: Long');
            }
          } else {
            paramDecl.write(', arg$i: ${_callbackParamToKotlinJni(cbParams[i], structNames: structNames, recordNames: recordNames)}');
          }
        }
        // For bidirectional callbacks (non-void return), declare the JNI return type.
        final cbReturnType = p.type.functionReturnType;
        final kotlinReturnType = (cbReturnType != null && cbReturnType != 'void')
            ? ': ${_toKotlinType(enumNames, structNames, recordNames, cbReturnType)}'
            : '';
        writer.line('    @JvmStatic external fun $nativeName($paramDecl)$kotlinReturnType');
      }
    }
    if (callbackNativeMethods.isNotEmpty) writer.blankLine();

    writer.line('}');
    return writer.toString();
  }

  /// Generates Kotlin type declarations for a type-only .native.dart file.
  /// Emits only enum/struct/record declarations — no interface or JniBridge object.
  /// Returns a Kotlin expression wrapping [body] with timeout if [timeout] is non-null.
  /// Generates: `withTimeout(N) { body }` when N is set, or just `body` otherwise.
  static String _kotlinRunBlockingCall(BridgeFunction func, String body) {
    if (func.asyncTimeout != null) {
      return 'runBlocking { withTimeout(${func.asyncTimeout}L) { $body } }';
    }
    return 'runBlocking { $body }';
  }

  static String _generateTypeOnly(BridgeSpec spec) {
    final nodes = <CodeNode>[
      CodeSnippet(generatedFileHeader('//', sourceUri: spec.sourceUri)),
      CodeLine('package nitro.${spec.lib.replaceAll('-', '_')}_module'),
      const BlankLine(),
      const CodeLine('import androidx.annotation.Keep'),
      const BlankLine(),
    ];

    final kotlinEnums = EnumGenerator.generateKotlin(spec);
    if (kotlinEnums.isNotEmpty) nodes.add(CodeSnippet(kotlinEnums));

    final kotlinStructs = StructGenerator.generateKotlin(spec);
    if (kotlinStructs.isNotEmpty) nodes.add(CodeSnippet(kotlinStructs));

    final kotlinRecords = RecordGenerator.generateKotlin(spec);
    if (kotlinRecords.isNotEmpty) nodes.add(CodeSnippet(kotlinRecords));

    return CodeFile(nodes).render();
  }

  /// Returns the Kotlin return type for a function, handling @HybridRecord types.
  /// - `List<@HybridRecord T>` → `List<T>`
  /// - `List<primitive T>` → `List<KotlinType>`
  /// - `@HybridRecord T` → `T`
  /// - everything else → delegated to [_toKotlinType]
  static String _toKotlinRetType(
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
    BridgeType t,
  ) {
    if (t.isNativeHandle) return 'Long';  // raw pointer address
    if (t.isRecord && !t.isMap) {
      if (t.recordListItemType != null && !t.recordListItemIsPrimitive) {
        return 'List<${t.recordListItemType}>';
      } else if (t.recordListItemType != null && t.recordListItemIsPrimitive) {
        return 'List<${_toKotlinType(enumNames, structNames, recordNames, t.recordListItemType!)}>';
      }
      // Direct @HybridRecord — use the class name
      return t.name;
    }
    final base = _toKotlinType(enumNames, structNames, recordNames, t.name);
    final isNullable = t.name.endsWith('?');
    final baseName = t.name.replaceFirst('?', '');
    // bool? interface return uses Boolean? so implementations CAN return null.
    // The _call bridge now uses NitroNullableBool (ByteArray) for JNI transport.
    if (isNullable && baseName == 'bool') return 'Boolean?';
    // int? and double? interface returns now use nullable types.
    // The _call bridge uses NitroNullableInt/NitroNullableDouble (ByteArray) for JNI transport.
    if (isNullable && baseName == 'int') return 'Long?';
    if (isNullable && baseName == 'double') return 'Double?';
    // Non-primitive nullable types (Status?, String?) preserve '?'.
    final isPrimitive = const {'String'}.contains(baseName);
    if (isNullable && !isPrimitive && !base.endsWith('?')) return '$base?';
    return base;
  }

  static String _toKotlinFunctionRetType(
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
    BridgeFunction func,
  ) {
    if (func.zeroCopyReturn && func.returnType.isTypedData) {
      return 'java.nio.ByteBuffer';
    }
    return _toKotlinRetType(enumNames, structNames, recordNames, func.returnType);
  }

  /// Returns the Kotlin type for a function parameter used in the **interface**.
  ///
  /// Respects nullability so Kotlin implementations receive `Long?`, `Boolean?`,
  /// etc. for optional `int?`, `bool?` params. Zero-copy TypedData params use
  /// `java.nio.ByteBuffer` (direct buffer, no copy).
  static String _toKotlinParamType(
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
    BridgeParam p,
  ) {
    final isNullable = p.type.name.endsWith('?') || p.isOptional;
    if (p.zeroCopy && p.type.isTypedData) {
      return isNullable ? 'java.nio.ByteBuffer?' : 'java.nio.ByteBuffer';
    }
    final base = _toKotlinType(enumNames, structNames, recordNames, p.type.name, bridgeType: p.type);
    return isNullable ? '$base?' : base;
  }

  /// Returns the Kotlin type for a parameter in a **`_call` JNI bridge method**.
  ///
  /// JNI calls from C++ pass primitive types directly (`J` for long, `Z` for
  /// boolean, `D` for double). Kotlin's nullable wrappers (`Long?`, `Boolean?`,
  /// `Double?`) compile to boxed object descriptors (`Ljava/lang/Long;`, …)
  /// which do **not** match the primitive descriptors that C++ registers via
  /// `GetStaticMethodID`. This mismatch causes a `NoSuchMethodError` at runtime.
  ///
  /// Fix: for optional `int?`, `bool?`, `double?` params, use the non-nullable
  /// Kotlin primitive type (`Long`, `Boolean`, `Double`) in the `_call` signature.
  /// Kotlin automatically promotes `Long` → `Long?` when forwarding to the
  /// interface, so the call body requires no special handling.
  ///
  /// Only primitive JVM types are affected. Reference types (`String?`, structs,
  /// enums, TypedData arrays) can legitimately be null in JNI and remain nullable.
  static String _toKotlinBridgeParamType(
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
    BridgeParam p,
  ) {
    // Callback / function-typed params are passed as Long (function pointer) via JNI.
    if (p.type.isFunction) return 'Long';
    // Map<String, T> params are JSON-encoded strings (Ljava/lang/String;), not ByteArray.
    // Maps now use binary encoding → ByteArray ([B]) same as @HybridRecord.
    if (p.type.isMap) return 'ByteArray';
    // Record params (List<T> and @HybridRecord) are serialized as ByteArray ([B]) in the C++ bridge.
    // Nullable record params use ByteArray? — C passes null jbyteArray for null values.
    final isNullableRecord = p.type.isRecord && (p.type.isNullable || p.type.name.endsWith('?'));
    if (p.type.isRecord) return isNullableRecord ? 'ByteArray?' : 'ByteArray';
    final isNullable = p.type.name.endsWith('?') || p.isOptional;
    if (!isNullable) {
      // Enum params: C bridge passes rawValue as jlong — use Long, not the Kotlin enum type.
      // If we use the enum type, the JVM sig is (Lpackage/EnumName;)... but C looks for (J)...
      final base = p.type.name.replaceFirst('?', '');
      if (enumNames.contains(base)) return 'Long';
      return _toKotlinParamType(enumNames, structNames, recordNames, p);
    }
    if (p.zeroCopy && p.type.isTypedData) {
      // Zero-copy buffers are reference types — keep nullable.
      return 'java.nio.ByteBuffer?';
    }
    final baseName = p.type.name.replaceFirst('?', '');
    // Primitive JVM types: strip nullability so the JVM descriptor matches C++.
    // For nullable bool?, the C bridge sends Int (I) not Boolean (Z) in the JNI call,
    // because the Dart side encodes null as -1 which jboolean can't represent.
    // The _call param type must match what C passes — so nullable bool? uses Int.
    // KNOWN LIMITATION: null bool? is still indistinguishable from false/true at runtime
    // because CallStaticBooleanMethod on C side truncates, but the signature MUST match.
    switch (baseName) {
      case 'int':
        // int? uses NitroNullable ByteArray encoding — [B in JVM descriptor
        return 'ByteArray'; // JVM descriptor: [B
      case 'bool':
        // bool? uses NitroNullable ByteArray encoding — [B in JVM descriptor
        return 'ByteArray'; // JVM descriptor: [B
      case 'double':
        // double? uses NitroNullable ByteArray encoding — [B in JVM descriptor
        return 'ByteArray'; // JVM descriptor: [B
    }
    // Nullable enum: C bridge passes -1L as null sentinel, actual rawValue otherwise.
    // Must use Long (J) so JVM descriptor matches C bridge's (J) for enum params.
    if (enumNames.contains(baseName)) return 'Long';
    // Other reference types (String, structs, TypedData arrays) can be null in JNI — keep nullable.
    final base = _toKotlinType(enumNames, structNames, recordNames, baseName);
    return '$base?';
  }

  static String _toKotlinType(
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
    String t, {
    BridgeType? bridgeType,
  }) {
    // NativeHandle<T> bridges as a Long (raw pointer address) across JNI.
    if (bridgeType?.isNativeHandle == true) return 'Long';
    final name = t.replaceFirst('?', '');

    // Handle function types (callbacks)
    if (bridgeType != null && bridgeType.isFunction) {
      final returnType = bridgeType.functionReturnType ?? 'Unit';
      final params = bridgeType.functionParams;
      final paramList = params
          .asMap()
          .entries
          .map((entry) {
            final i = entry.key;
            final p = entry.value;
            final ktType = _toKotlinType(enumNames, structNames, recordNames, p.name);
            return 'p$i: $ktType';
          })
          .join(', ');
      final ktReturnType = _toKotlinType(enumNames, structNames, recordNames, returnType);
      return '($paramList) -> $ktReturnType';
    }

    switch (name) {
      case 'int':
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
    return 'Any?';
  }

  /// Maps a property type to its Kotlin type, preserving nullability for nullable properties.
  static String _toKotlinPropertyType(
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
    String t,
  ) {
    final base = _toKotlinType(enumNames, structNames, recordNames, t);
    if (t.endsWith('?') && !base.endsWith('?')) return '$base?';
    return base;
  }

  /// Maps a callback parameter type to its JNI-compatible Kotlin type.
  /// The `_invoke_` external native method must use these types so that
  /// the JVM method descriptor matches the C JNI function signature exactly.
  static String _callbackParamToKotlinJni(BridgeType t, {Set<String>? structNames, Set<String>? recordNames}) {
    final base = t.name.replaceFirst('?', '');
    switch (base) {
      // Use Long (jlong) for bool and double so the native invoker uses x0/GP registers.
      // NativeCallable.listener with Boolean/Double types may not fire synchronously
      // on Android — only Int64/Long has the synchronous fast-path.
      case 'double':
        return 'Long'; // encoded as raw IEEE 754 bits via java.lang.Double.doubleToRawLongBits
      case 'bool':
        return 'Long'; // encoded as 1L (true) or 0L (false)
      case 'String':
        return 'String?';
      default:
        if (structNames?.contains(base) == true) return base;        // data class
        if (recordNames?.contains(base) == true) return 'ByteArray'; // serialized record
        return 'Long'; // int, enum rawValue → Long (jlong)
    }
  }

  /// Generates a Kotlin lambda expression that wraps a Long function pointer
  /// and invokes the C function via a native JNI bridge method.
  ///
  /// For a callback `(TorchState) -> Unit`, generates:
  /// ```kotlin
  /// { p0: TorchState -> _invoke_onCallback(onCallbackPtr, p0.nativeValue) }
  /// ```
  static String _emitCallbackLambda(BridgeParam p, Set<String> enumNames, {Set<String>? structNames, Set<String>? recordNames, List<BridgeStruct>? structs}) {
    final cbParams = p.type.functionParams;
    final nativeMethodName = '_invoke_${p.name}';

    final lambdaParams = cbParams
        .asMap()
        .entries
        .map((entry) {
          final i = entry.key;
          final cbP = entry.value;
          final ktType = _toKotlinType(enumNames, structNames ?? {}, recordNames ?? {}, cbP.name);
          return 'p$i: $ktType';
        })
        .join(', ');

    final nativeArgs = <String>[p.name];
    for (var i = 0; i < cbParams.length; i++) {
      final cbP = cbParams[i];
      final base = cbP.name.replaceFirst('?', '');
      final struct = structs?.where((s) => s.name == base).firstOrNull;
      if (struct != null && _isExpandableStruct(struct)) {
        // Expand struct fields → individual Longs for synchronous NativeCallable.listener.
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
      } else if (base == 'bool') {
        nativeArgs.add('if (p$i) 1L else 0L');
      } else if (base == 'double') {
        nativeArgs.add('java.lang.Double.doubleToRawLongBits(p$i)');
      } else if (enumNames.contains(base)) {
        nativeArgs.add('p$i.nativeValue');
      } else if (recordNames?.contains(base) == true) {
        nativeArgs.add('p$i.encode()');
      } else {
        nativeArgs.add('p$i');
      }
    }

    final lambdaBody = '$nativeMethodName(${nativeArgs.join(', ')})';
    return '{ ${lambdaParams.isEmpty ? '' : '$lambdaParams -> '}$lambdaBody }';
  }

  /// Returns true when all struct fields are numeric (int/double/bool) — can be
  /// expanded to individual Long params for synchronous NativeCallable.listener.
  static bool _isExpandableStruct(BridgeStruct st) {
    const numeric = {'int', 'double', 'bool'};
    return st.fields.every((f) => numeric.contains(f.type.name.replaceFirst('?', '')) && !f.type.isTypedData);
  }
}
