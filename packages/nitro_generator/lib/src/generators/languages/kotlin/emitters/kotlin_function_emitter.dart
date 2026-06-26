import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import '../../../record_generator.dart';
import 'kotlin_type_mapper.dart';

/// Emits the `_call` JNI bridge method for a single [BridgeFunction].
///
/// Handles all three dispatch paths:
/// - `@NitroNativeAsync` — coroutine + Dart_PostCObject_DL
/// - `@nitroAsync` — `_asyncExecutor.submit` + `runBlocking`
/// - Sync — direct `impl.fn(params)`
class KotlinFunctionEmitter {
  static void emit(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    KotlinTypeMapper mapper,
  ) {
    if (func.lineNumber != null) {
      writer.line('    // source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
    }

    final retType = mapper.functionRetType(func);
    final bridgeParamsDecl = func.params.map((p) => '${p.name}: ${mapper.bridgeParamType(p)}').join(', ');

    if (func.isNativeAsync) {
      _emitNativeAsync(writer, func, spec, mapper, retType, bridgeParamsDecl);
      return;
    }

    // ── Regular (sync / @nitroAsync) ─────────────────────────────────────────
    final retBaseName = func.returnType.name.replaceFirst('?', '');
    final isUnit = retType == 'Unit';
    final isEnum = mapper.enumNames.contains(retBaseName);
    final isNullableEnum = isEnum && func.returnType.name.endsWith('?');
    final isRecord = func.returnType.isRecord && !func.returnType.isMap;
    final isMap = func.returnType.isMap;
    final isListRecord = isRecord && func.returnType.recordListItemType != null && !func.returnType.recordListItemIsPrimitive;
    final isNullableBoolReturn = retBaseName == 'bool' && func.returnType.name.endsWith('?');
    final isNullableIntReturn = retBaseName == 'int' && func.returnType.name.endsWith('?');
    final isNullableDoubleReturn = retBaseName == 'double' && func.returnType.name.endsWith('?');

    final bridgeRetType = (isNullableBoolReturn || isNullableIntReturn || isNullableDoubleReturn)
        ? 'ByteArray'
        : isEnum
        ? 'Long'
        : isRecord
        ? (func.returnType.name.endsWith('?') ? 'ByteArray?' : 'ByteArray')
        : isMap
        ? 'ByteArray'
        : retType;

    // Optional-primitive params that need NitroNullable ByteArray decoding.
    final optPrimParams = func.params.where((p) {
      final bn = p.type.name.replaceFirst('?', '');
      final isNull = p.type.name.endsWith('?') || p.isOptional;
      return isNull && (bn == 'int' || bn == 'bool' || bn == 'double');
    }).toList();

    // Resolve call params — decode enums, records, callbacks, nullable prims.
    final callParams = func.params
        .map((p) {
          final baseName = p.type.name.replaceFirst('?', '');
          final isNull = p.type.name.endsWith('?') || p.isOptional;
          if (isNull && (baseName == 'int' || baseName == 'bool' || baseName == 'double')) {
            return '${p.name}Arg';
          }
          if (isNull && mapper.enumNames.contains(baseName)) return '${p.name}Arg';
          if (mapper.enumNames.contains(baseName)) return '$baseName.fromNative(${p.name})';
          if (p.type.isFunction) return mapper.callbackLambda(p);
          if (p.type.isRecord && !p.type.isMap) return '${p.name}Decoded';
          return p.name;
        })
        .join(', ');

    writer.line('    @JvmStatic fun ${func.dartName}_call($bridgeParamsDecl): $bridgeRetType {');
    writer.line('        val impl = implementation ?: throw IllegalStateException("${spec.dartClassName} not registered")');

    // Decode nullable primitive params from NitroNullable ByteArray.
    for (final p in optPrimParams) {
      final bn = p.type.name.replaceFirst('?', '');
      if (bn == 'int') {
        writer.line('        // Dart layer sends NitroNullableInt (ByteArray) for ${p.name}.');
        writer.line('        val ${p.name}Arg: Long? = NitroNullableInt.decode(${p.name}).nullable');
      } else if (bn == 'bool') {
        writer.line('        // Dart layer sends NitroNullableBool (ByteArray) for ${p.name}.');
        writer.line('        val ${p.name}Arg: Boolean? = NitroNullableBool.decode(${p.name}).nullable');
      } else if (bn == 'double') {
        writer.line('        // Dart layer sends NitroNullableDouble (ByteArray) for ${p.name}.');
        writer.line('        val ${p.name}Arg: Double? = NitroNullableDouble.decode(${p.name}).nullable');
      }
    }
    // Decode nullable enum params from Long sentinel (-1 = null).
    for (final p in func.params) {
      final bn = p.type.name.replaceFirst('?', '');
      final isNull = p.type.name.endsWith('?') || p.isOptional;
      if (isNull && mapper.enumNames.contains(bn)) {
        writer.line('        // Dart layer sends -1L as sentinel when caller passes null for ${p.name}.');
        writer.line('        val ${p.name}Arg: $bn? = if (${p.name} < 0L) null else $bn.fromNative(${p.name})');
      }
    }
    // Decode record / list params from ByteArray.
    _emitParamDecodes(writer, func, mapper);

    // Timeout-aware runBlocking expression.
    final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}($callParams)');

    if (isMap) {
      _emitMapBody(writer, func, spec, mapper, callParams);
    } else if (isRecord) {
      _emitRecordBody(writer, func, spec, isListRecord, callParams, rb);
    } else if (func.isAsync) {
      _emitAsyncBody(writer, func, isEnum, isNullableEnum, isNullableBoolReturn, isNullableIntReturn, isNullableDoubleReturn, rb);
    } else {
      _emitSyncBody(writer, func, isUnit, isEnum, isNullableEnum, isNullableBoolReturn, isNullableIntReturn, isNullableDoubleReturn, callParams);
    }

    writer.line('    }');
  }

  // ── NativeAsync ─────────────────────────────────────────────────────────────

  static void _emitNativeAsync(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    KotlinTypeMapper mapper,
    String retType,
    String bridgeParamsDecl,
  ) {
    final isUnit = retType == 'Unit';
    final retBaseName = func.returnType.name.replaceFirst('?', '');
    final isEnum = mapper.enumNames.contains(retBaseName);
    final isNullableReturn = func.returnType.name.endsWith('?') || func.returnType.isNullable;
    final portParam = bridgeParamsDecl.isEmpty ? 'dartPort: Long' : '$bridgeParamsDecl, dartPort: Long';

    final optPrims = func.params.where((p) {
      final bn = p.type.name.replaceFirst('?', '');
      final isNull = p.type.name.endsWith('?') || p.isOptional;
      return isNull && (bn == 'int' || bn == 'bool' || bn == 'double');
    }).toList();

    final callParams = func.params
        .map((p) {
          final bn = p.type.name.replaceFirst('?', '');
          final isNull = p.type.name.endsWith('?') || p.isOptional;
          return (isNull && (bn == 'int' || bn == 'bool' || bn == 'double')) ? '${p.name}Arg' : p.name;
        })
        .join(', ');

    writer.line('    @JvmStatic fun ${func.dartName}_call($portParam) {');
    writer.line('        val impl = implementation ?: run {');
    writer.line('            postNullToPort(dartPort)');
    writer.line('            return');
    writer.line('        }');

    for (final p in optPrims) {
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
    writer.line('            try {');
    if (isUnit) {
      writer.line('            runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            postNullToPort(dartPort)');
    } else if (isEnum) {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      if (isNullableReturn) {
        writer.line('            if (result == null) postInt64ToPort(dartPort, -1L) else postInt64ToPort(dartPort, result.nativeValue)');
      } else {
        writer.line('            postInt64ToPort(dartPort, result.nativeValue)');
      }
    } else if (retType == 'String') {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            postStringToPort(dartPort, result)');
    } else if (retType == 'String?') {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            if (result == null) postNullToPort(dartPort) else postStringToPort(dartPort, result)');
    } else if (retType == 'Boolean') {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            postBoolToPort(dartPort, result)');
    } else if (retType == 'Boolean?') {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            if (result == null) postNullToPort(dartPort) else postBoolToPort(dartPort, result)');
    } else if (retType == 'Long' || retType == 'Int') {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            postInt64ToPort(dartPort, result.toLong())');
    } else if (retType == 'Long?' || retType == 'Int?') {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            postInt64ToPort(dartPort, result?.toLong() ?: Long.MIN_VALUE)');
    } else if (retType == 'Double') {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            postDoubleToPort(dartPort, result)');
    } else if (retType == 'Double?') {
      writer.line('            val result = runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            postDoubleToPort(dartPort, result ?: Double.NaN)');
    } else {
      writer.line('            runBlocking { impl.${func.dartName}($callParams) }');
      writer.line('            postNullToPort(dartPort)');
    }
    writer.line('            } catch (_: Throwable) {');
    writer.line('                postNullToPort(dartPort)');
    writer.line('            }');
    writer.line('        }');
    writer.line('    }');
  }

  // ── Parameter decoding helpers ──────────────────────────────────────────────

  static void _emitParamDecodes(CodeWriter writer, BridgeFunction func, KotlinTypeMapper mapper) {
    for (final p in func.params) {
      if (!p.type.isRecord || p.type.isMap) continue;

      if (p.type.recordListItemType == null) {
        // Single @HybridRecord param
        final recordName = p.type.name.replaceFirst('?', '');
        final isNullableRec = p.type.isNullable || p.type.name.endsWith('?');
        if (isNullableRec) {
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
      } else if (!p.type.recordListItemIsPrimitive) {
        // List<@HybridRecord>
        final itemType = p.type.recordListItemType!;
        writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        ${p.name}Buf.getInt() // skip outer length');
        writer.line('        val ${p.name}Count = ${p.name}Buf.getInt()');
        writer.line('        val ${p.name}Offsets = LongArray(${p.name}Count) { ${p.name}Buf.getLong() }');
        writer.line('        val ${p.name}Decoded = mutableListOf<$itemType>()');
        writer.line('        for (${p.name}Offset in ${p.name}Offsets) {');
        writer.line('            val itemBuf = java.nio.ByteBuffer.wrap(${p.name}, 4 + ${p.name}Offset.toInt(), ${p.name}.size - 4 - ${p.name}Offset.toInt()).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('            ${p.name}Decoded.add($itemType.decodeFrom(itemBuf))');
        writer.line('        }');
      } else {
        // List<primitive>
        final itemType = p.type.recordListItemType!;
        final listKtType = switch (itemType) {
          'int' => 'ArrayList<Long>',
          'double' => 'ArrayList<Double>',
          'String' => 'ArrayList<String>',
          _ => 'ArrayList<Any>',
        };
        writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        ${p.name}Buf.getInt() // skip outer length');
        writer.line('        val ${p.name}Count = ${p.name}Buf.getInt()');
        writer.line('        val ${p.name}Offsets = LongArray(${p.name}Count) { ${p.name}Buf.getLong() }');
        writer.line('        val ${p.name}Decoded = $listKtType()');
        if (itemType == 'String') {
          writer.line('        for (${p.name}Offset in ${p.name}Offsets) {');
          writer.line('            val itemBuf = java.nio.ByteBuffer.wrap(${p.name}, 4 + ${p.name}Offset.toInt(), ${p.name}.size - 4 - ${p.name}Offset.toInt()).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
          writer.line('            val len = itemBuf.getInt()');
          writer.line('            val strBytes = ByteArray(len)');
          writer.line('            itemBuf.get(strBytes)');
          writer.line('            ${p.name}Decoded.add(strBytes.toString(Charsets.UTF_8))');
          writer.line('        }');
        } else {
          final readMethod = switch (itemType) {
            'int' => 'getLong',
            'double' => 'getDouble',
            'bool' => 'get',
            _ => 'getLong',
          };
          writer.line('        for (${p.name}Offset in ${p.name}Offsets) {');
          writer.line('            val itemBuf = java.nio.ByteBuffer.wrap(${p.name}, 4 + ${p.name}Offset.toInt(), ${p.name}.size - 4 - ${p.name}Offset.toInt()).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
          if (itemType == 'bool') {
            writer.line('            ${p.name}Decoded.add(if (itemBuf.get().toInt() != 0) 1L else 0L)');
          } else {
            writer.line('            ${p.name}Decoded.add(itemBuf.$readMethod())');
          }
          writer.line('        }');
        }
      }
    }
  }

  // ── Map body ─────────────────────────────────────────────────────────────────

  static void _emitMapBody(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    KotlinTypeMapper mapper,
    String callParams,
  ) {
    final mapParam = func.params.isNotEmpty ? func.params.first.name : 'value';
    final mapValueType = (() {
      final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(func.returnType.name);
      return m?.group(1)?.trim() ?? 'Any?';
    })();

    writer.line('        @Suppress("UNCHECKED_CAST")');
    writer.line('        val _mapBuf = java.nio.ByteBuffer.wrap($mapParam).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('        _mapBuf.position(4) // skip 4-byte payload length prefix');
    writer.line('        val _mapCount = _mapBuf.int');
    writer.line('        val _inputMap = mutableMapOf<String, Any?>()');
    writer.line('        repeat(_mapCount) {');
    writer.line('            val kLen = _mapBuf.int; val kBytes = ByteArray(kLen); _mapBuf.get(kBytes)');
    writer.line('            val k = kBytes.toString(Charsets.UTF_8)');
    writer.line('            _mapBuf.get() // skip 1-byte type tag');
    if (mapValueType == 'int' || mapValueType == 'Long') {
      writer.line('            _inputMap[k] = _mapBuf.long');
    } else if (mapValueType == 'double' || mapValueType == 'Double') {
      writer.line('            _inputMap[k] = _mapBuf.double');
    } else if (mapValueType == 'bool' || mapValueType == 'Boolean') {
      writer.line('            _inputMap[k] = _mapBuf.get().toInt() != 0');
    } else {
      writer.line('            val vLen = _mapBuf.int; val vBytes = ByteArray(vLen); _mapBuf.get(vBytes)');
      writer.line('            _inputMap[k] = vBytes.toString(Charsets.UTF_8)');
    }
    writer.line('        }');

    if (func.isAsync) {
      final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}(_inputMap)');
      writer.line('        val _result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('        val _result = impl.${func.dartName}(_inputMap)');
    }

    writer.line('        @Suppress("UNCHECKED_CAST")');
    writer.line('        val _outMap = _result as? Map<String, Any?> ?: emptyMap()');
    writer.line('        val _outBb = java.io.ByteArrayOutputStream()');
    writer.line('        val _outBuf = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('        fun _writeInt32(v: Int) { _outBuf.clear(); _outBuf.putInt(v); _outBb.write(_outBuf.array(), 0, 4) }');
    writer.line('        fun _writeInt64(v: Long) { _outBuf.clear(); _outBuf.putLong(v); _outBb.write(_outBuf.array()) }');
    writer.line('        fun _writeDouble(v: Double) { _outBuf.clear(); _outBuf.putDouble(v); _outBb.write(_outBuf.array()) }');
    writer.line('        _writeInt32(_outMap.size)');
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
  }

  // ── Record body ──────────────────────────────────────────────────────────────

  static void _emitRecordBody(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    bool isListRecord,
    String callParams,
    String rb,
  ) {
    if (func.isAsync) {
      writer.line('        val result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('        val result = impl.${func.dartName}($callParams)');
    }

    if (isListRecord) {
      final itemTypeName = func.returnType.recordListItemType!;
      final itemRt = spec.recordTypes.where((rt) => rt.name == itemTypeName).firstOrNull;
      final hint = itemRt != null ? RecordGenerator.recordBytesHint(itemRt) : 64;
      writer.line('        val itemBufs = ArrayList<ByteArray>(result.size)');
      writer.line('        val tmpBuf = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('        for (item in result) {');
      writer.line('            val tmpOut = java.io.ByteArrayOutputStream($hint)');
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
      final itemTypeName = func.returnType.recordListItemType!;
      final itemSize = switch (itemTypeName) {
        'int' => 8,
        'double' => 8,
        'String' => -1,
        _ => 8,
      };
      if (itemSize > 0) {
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
        final encodeExpr = itemTypeName == 'bool' ? 'if (it) 1L else 0L' : 'it';
        writer.line('        result.forEach { buf.$putMethod($encodeExpr) }');
        writer.line('        return buf.array()');
      } else {
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
      // Single @HybridRecord
      if (func.returnType.name.endsWith('?')) {
        writer.line('        return result?.encode()');
      } else {
        writer.line('        return result.encode()');
      }
    }
  }

  // ── Async body ───────────────────────────────────────────────────────────────

  static void _emitAsyncBody(
    CodeWriter writer,
    BridgeFunction func,
    bool isEnum,
    bool isNullableEnum,
    bool isNullableBool,
    bool isNullableInt,
    bool isNullableDouble,
    String rb,
  ) {
    if (isEnum) {
      if (isNullableEnum) {
        writer.line('        val _enumResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
        writer.line('        return if (_enumResult == null) -1L else _enumResult.nativeValue');
      } else {
        writer.line('        return _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get().nativeValue');
      }
    } else if (isNullableBool) {
      writer.line('        val _boolResult = _asyncExecutor.submit(java.util.concurrent.Callable {');
      writer.line('            $rb');
      writer.line('        }).get()');
      writer.line('        return NitroNullableBool(_boolResult).encode()');
    } else if (isNullableInt) {
      writer.line('        val _intResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
      writer.line('        return NitroNullableInt(_intResult).encode()');
    } else if (isNullableDouble) {
      writer.line('        val _doubleResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
      writer.line('        return NitroNullableDouble(_doubleResult).encode()');
    } else {
      writer.line('        return _asyncExecutor.submit(java.util.concurrent.Callable {');
      writer.line('            $rb');
      writer.line('        }).get()');
    }
  }

  // ── Sync body ────────────────────────────────────────────────────────────────

  static void _emitSyncBody(
    CodeWriter writer,
    BridgeFunction func,
    bool isUnit,
    bool isEnum,
    bool isNullableEnum,
    bool isNullableBool,
    bool isNullableInt,
    bool isNullableDouble,
    String callParams,
  ) {
    if (isUnit) {
      writer.line('        impl.${func.dartName}($callParams)');
    } else if (isEnum) {
      if (isNullableEnum) {
        writer.line('        val _enumResult = impl.${func.dartName}($callParams)');
        writer.line('        return if (_enumResult == null) -1L else _enumResult.nativeValue');
      } else {
        writer.line('        return impl.${func.dartName}($callParams).nativeValue');
      }
    } else if (isNullableBool) {
      writer.line('        val _boolResult = impl.${func.dartName}($callParams)');
      writer.line('        return NitroNullableBool(_boolResult).encode()');
    } else if (isNullableInt) {
      writer.line('        val _intResult = impl.${func.dartName}($callParams)');
      writer.line('        return NitroNullableInt(_intResult).encode()');
    } else if (isNullableDouble) {
      writer.line('        val _doubleResult = impl.${func.dartName}($callParams)');
      writer.line('        return NitroNullableDouble(_doubleResult).encode()');
    } else {
      writer.line('        return impl.${func.dartName}($callParams)');
    }
  }
}
