import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import '../../../record_generator.dart';
import 'kotlin_map_emitter.dart';
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
    // instanceId is the first param for per-instance dispatch (Point 13).
    final bridgeParamsDecl = ['instanceId: Long', ...func.params.map((p) => '${p.name}: ${mapper.bridgeParamType(p)}')].join(', ');

    if (func.isNativeAsync) {
      _emitNativeAsync(writer, func, spec, mapper, retType, bridgeParamsDecl);
      return;
    }

    // ── Regular (sync / @nitroAsync) ─────────────────────────────────────────
    final retBaseName = bareTypeName(func.returnType.name);
    final isUnit = retType == 'Unit';
    final isEnum = mapper.enumNames.contains(retBaseName);
    final isNullableEnum = isEnum && func.returnType.name.endsWith('?');
    final isRecord = func.returnType.isRecord && !func.returnType.isMap;
    final isMap = func.returnType.isMap;
    final isAnyMap = func.returnType.isAnyMap;
    final isEnumListReturn = func.returnType.isEnumList;
    final isVariantListReturn = func.returnType.isVariantList;
    final isListRecord = isRecord && func.returnType.recordListItemType != null && !func.returnType.recordListItemIsPrimitive && !isEnumListReturn && !isVariantListReturn;
    final isNullableBoolReturn = retBaseName == 'bool' && func.returnType.name.endsWith('?');
    final isNullableIntReturn = (retBaseName == 'int' || retBaseName == 'uint64' || retBaseName == 'DateTime') && func.returnType.name.endsWith('?');
    final isNullableDoubleReturn = retBaseName == 'double' && func.returnType.name.endsWith('?');
    final isVariantReturn = mapper.variantNames.contains(retBaseName);

    final bridgeRetType = switch (func.returnType) {
      _ when func.isResult => 'ByteArray', // [1B tag][record payload]
      // @NitroVariant, List<@HybridEnum>, List<@NitroVariant>: a `[4B len]` block.
      _ when isVariantReturn || isEnumListReturn || isVariantListReturn => 'ByteArray',
      _ when isNullableBoolReturn || isNullableIntReturn || isNullableDoubleReturn => 'ByteArray',
      _ when isEnum => 'Long',
      // A null record or map is a null ByteArray.
      BridgeType(:final name) when isRecord || isAnyMap || isMap => name.endsWith('?') ? 'ByteArray?' : 'ByteArray',
      _ => retType,
    };

    bool isOptPrim(BridgeParam p) => p.type.isNullableNitroPrim || (p.isOptional && BridgeType.nitroPrimBases.contains(p.type.baseName));

    // Optional-primitive params that need NitroNullable ByteArray decoding.
    final optPrimParams = func.params.where(isOptPrim).toList();

    // Resolve call params — decode enums, records, variants, callbacks, nullable prims.
    final callParams = _buildCallParams(func, mapper);

    writer.line('    @JvmStatic fun ${func.dartName}_call($bridgeParamsDecl): $bridgeRetType {');
    writer.line('        val impl = _implementations[instanceId] ?: throw IllegalStateException("${spec.dartClassName} instance \$instanceId not registered")');

    // Decode nullable primitive params from NitroOpt* ByteArray ([1B hasValue][N bytes value]).
    for (final p in optPrimParams) {
      final bn = bareTypeName(p.type.name);
      switch (bn) {
        case 'int':
          writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
        case 'bool':
          writer.line('        val ${p.name}Arg: Boolean? = NitroOptBool.decode(${p.name}).nullable');
        case 'double':
          writer.line('        val ${p.name}Arg: Double? = NitroOptFloat64.decode(${p.name}).nullable');
        case 'DateTime':
          writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
        case 'uint64':
          writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
      }
    }
    // Decode nullable enum params from Long sentinel (-1 = null).
    for (final p in func.params) {
      final bn = bareTypeName(p.type.name);
      final isNull = p.type.name.endsWith('?') || p.isOptional;
      if (isNull && mapper.enumNames.contains(bn)) {
        writer.line('        // Dart layer sends -1L as sentinel when caller passes null for ${p.name}.');
        writer.line('        val ${p.name}Arg: $bn? = if (${p.name} < 0L) null else $bn.fromNative(${p.name})');
      }
    }
    // Decode record / list params from ByteArray, and maps in any position.
    _emitParamDecodes(writer, func, mapper);
    KotlinMapEmitter.emitParamDecodes(writer, func, spec);

    // Timeout-aware runBlocking expression.
    final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}($callParams)');

    if (func.isResult) {
      _emitResultBody(writer, func, spec, mapper, callParams);
    } else if (isVariantReturn) {
      _emitVariantReturnBody(writer, func, retBaseName, callParams);
    } else if (isEnumListReturn) {
      _emitEnumListBody(writer, func, callParams);
    } else if (isVariantListReturn) {
      _emitVariantListBody(writer, func, callParams);
    } else if (isAnyMap || isMap) {
      _emitMapReturnBody(writer, func, spec, callParams);
    } else if (isRecord) {
      _emitRecordBody(writer, func, spec, isListRecord, callParams, rb);
    } else if (func.isAsync) {
      _emitAsyncBody(writer, func, isEnum, isNullableEnum, isNullableBoolReturn, isNullableIntReturn, isNullableDoubleReturn, rb);
    } else {
      _emitSyncBody(writer, func, isUnit, isEnum, isNullableEnum, isNullableBoolReturn, isNullableIntReturn, isNullableDoubleReturn, callParams);
    }

    writer.line('    }');
  }

  /// Resolves the Kotlin call-argument list for `impl.${func.dartName}(...)` —
  /// decodes enums, records, variants, and callbacks from their bridge-wire
  /// representation, passes nullable-primitive args through their pre-decoded
  /// `${p.name}Arg` locals, and forwards everything else as-is. Shared by both
  /// the sync/`@nitroAsync` path and `_emitNativeAsync` — the two dispatch
  /// chains decode the exact same param categories the exact same way, so a
  /// shared implementation is what keeps them from drifting apart (this is how
  /// the native-async path picked up support for non-nullable enum, record/
  /// tuple, variant, and callback params, none of which it decoded before).
  static String _buildCallParams(BridgeFunction func, KotlinTypeMapper mapper) {
    bool isOptPrim(BridgeParam p) => p.type.isNullableNitroPrim || (p.isOptional && BridgeType.nitroPrimBases.contains(p.type.baseName));
    return func.params
        .map((p) {
          final baseName = bareTypeName(p.type.name);
          final isNull = p.type.name.endsWith('?') || p.isOptional;
          if (isOptPrim(p)) return '${p.name}Arg';
          if (isNull && mapper.enumNames.contains(baseName)) return '${p.name}Arg';
          if (mapper.enumNames.contains(baseName)) return '$baseName.fromNative(${p.name})';
          if (p.type.isFunction) return mapper.callbackLambda(p);
          if (p.type.isRecord && !p.type.isMap) return '${p.name}Decoded';
          if (mapper.variantNames.contains(baseName)) return '${p.name}Decoded';
          if (p.type.isAnyMap || p.type.isMap) return '${p.name}Decoded';
          return p.name;
        })
        .join(', ');
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
    final retBaseName = bareTypeName(func.returnType.name);
    final isEnum = mapper.enumNames.contains(retBaseName);
    final isNullableReturn = func.returnType.name.endsWith('?') || func.returnType.isNullable;
    final isEnumListReturn = func.returnType.isEnumList;
    final isVariantListReturn = func.returnType.isVariantList;
    final isVariantReturn = mapper.variantNames.contains(retBaseName);
    final isAnyMapReturn = func.returnType.isAnyMap;
    final isMapReturn = func.returnType.isMap;
    final isCustomTypeReturn = mapper.customTypeNames.contains(retBaseName);
    final isStructReturn = mapper.structNames.contains(retBaseName);
    final isRecord = func.returnType.isRecord && !func.returnType.isMap;
    final isListRecord = isRecord && func.returnType.recordListItemType != null && !func.returnType.recordListItemIsPrimitive && !func.returnType.isEnumList && !func.returnType.isVariantList;
    // instanceId is prepended; bridgeParamsDecl already includes it. errPtr is
    // the address of a fresh-per-call NitroError* Dart allocated (see
    // NitroRuntime.throwIfOutParamErrorAndFree) — unlike sync's one
    // instance-owned slot, native-async calls aren't serialized so each call
    // gets its own struct.
    final portParam = '$bridgeParamsDecl, errPtr: Long, dartPort: Long';

    bool isOptPrimNA(BridgeParam p) => p.type.isNullableNitroPrim || (p.isOptional && BridgeType.nitroPrimBases.contains(p.type.baseName));

    final optPrims = func.params.where(isOptPrimNA).toList();

    final callParams = _buildCallParams(func, mapper);

    writer.line('    @JvmStatic fun ${func.dartName}_call($portParam) {');
    writer.line('        val impl = _implementations[instanceId] ?: run {');
    writer.line('            reportNativeAsyncError(errPtr, "IllegalStateException", "No implementation registered for instance")');
    writer.line('            postNullToPort(dartPort)');
    writer.line('            return');
    writer.line('        }');

    for (final p in optPrims) {
      final bn = bareTypeName(p.type.name);
      switch (bn) {
        case 'int':
          writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
        case 'bool':
          writer.line('        val ${p.name}Arg: Boolean? = NitroOptBool.decode(${p.name}).nullable');
        case 'double':
          writer.line('        val ${p.name}Arg: Double? = NitroOptFloat64.decode(${p.name}).nullable');
        case 'DateTime':
          writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
        case 'uint64':
          writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
      }
    }
    // Decode nullable enum params from Long sentinel (-1 = null) — mirrors the
    // sync path's equivalent block; native-async previously skipped this and
    // forwarded the raw Long where a nullable enum was expected.
    for (final p in func.params) {
      final bn = bareTypeName(p.type.name);
      final isNull = p.type.name.endsWith('?') || p.isOptional;
      if (isNull && mapper.enumNames.contains(bn)) {
        writer.line('        // Dart layer sends -1L as sentinel when caller passes null for ${p.name}.');
        writer.line('        val ${p.name}Arg: $bn? = if (${p.name} < 0L) null else $bn.fromNative(${p.name})');
      }
    }
    // Decode record / tuple / variant / list-of-those params from ByteArray —
    // previously never called for native-async, so any such param produced
    // Kotlin that forwarded the raw ByteArray where a decoded value was
    // expected (compile failure).
    _emitParamDecodes(writer, func, mapper);
    KotlinMapEmitter.emitParamDecodes(writer, func, spec);

    writer.line('        _asyncExecutor.execute {');
    writer.line('            try {');
    switch (retType) {
      case _ when isUnit:
        writer.line('            ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postNullToPort(dartPort)');
      case _ when isEnum:
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        if (isNullableReturn) {
          writer.line('            if (result == null) postInt64ToPort(dartPort, -1L) else postInt64ToPort(dartPort, result.nativeValue)');
        } else {
          writer.line('            postInt64ToPort(dartPort, result.nativeValue)');
        }
      case 'String':
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postStringToPort(dartPort, result)');
      case 'String?':
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            if (result == null) postNullToPort(dartPort) else postStringToPort(dartPort, result)');
      case 'Boolean':
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postBoolToPort(dartPort, result)');
      case 'Boolean?':
        // bool? NativeAsync: post pointer to NitroOptBool (2 bytes); Dart decodes via fromAddress.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postOptBoolToPort(dartPort, result ?: false, result != null)');
      case _ when func.returnType.isNativeHandle:
        // NativeHandle NativeAsync (issue #18): the impl returns the raw
        // pointer address as Long — post it as kInt64. Address 0 means null
        // for a nullable handle (the Kotlin interface declares Long on every
        // path, so null is expressed as 0, matching the Dart-side unpack).
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postInt64ToPort(dartPort, result)');
      case 'Long' || 'Int':
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postInt64ToPort(dartPort, result.toLong())');
      case 'Long?' || 'Int?':
        // Long?/Int? NativeAsync: post pointer to NitroOptInt64 (9 bytes); Dart decodes via fromAddress.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postOptInt64ToPort(dartPort, result?.toLong() ?: 0L, result != null)');
      case 'Double':
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postDoubleToPort(dartPort, result)');
      case 'Double?':
        // Double? NativeAsync: post pointer to NitroOptFloat64 (9 bytes); Dart decodes via fromAddress.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postOptFloat64ToPort(dartPort, result ?: 0.0, result != null)');
      case _ when isEnumListReturn:
        // List<@HybridEnum> NativeAsync: checked BEFORE isRecord — spec_extractor
        // sets isRecord alongside isEnumList, so without this branch these fell
        // into the isRecord path's single-record fallback and called `.encode()`
        // on a Kotlin List (not a member — compile error). Mirrors the encoding
        // _emitEnumListBody uses for the sync/@nitroAsync path.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        _emitNativeAsyncEnumListEncode(writer, func);
        writer.line('            postBytesToPort(dartPort, _bytes)');
      case _ when isVariantListReturn:
        // List<@NitroVariant> NativeAsync: same reasoning as isEnumListReturn
        // above. Mirrors the encoding _emitVariantListBody uses for the
        // sync/@nitroAsync path.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        _emitNativeAsyncVariantListEncode(writer, func);
        writer.line('            postBytesToPort(dartPort, _bytes)');
      case _ when isVariantReturn:
        // Bare @NitroVariant NativeAsync: needs its own branch
        // (discard + always-null), the same bug class as the fixed record
        // return. Mirrors _emitVariantReturnBody's wire format.
        writer.line('            val _vResult = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            val _vw = ${KotlinTypeMapper.codec(func.returnType.name, 'RecordWriter')}()');
        writer.line('            _vResult.writeFields(_vw)');
        writer.line('            val _vPayload = _vw.toByteArray()');
        writer.line('            val _vBuf = java.nio.ByteBuffer.allocate(4 + _vPayload.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('            _vBuf.putInt(_vPayload.size)');
        writer.line('            _vBuf.put(_vPayload)');
        writer.line('            postBytesToPort(dartPort, _vBuf.array())');
      case _ when isAnyMapReturn || isMapReturn:
        // A null map is posted as a null ByteArray, like a null record.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postBytesToPort(dartPort, ${KotlinMapEmitter.encodeExpr(func.returnType, spec, 'result')})');
      case _ when isCustomTypeReturn:
        // @NitroCustomType NativeAsync: the impl already returns a raw,
        // user-encoded ByteArray (custom types have no generator-side
        // encode/decode) — post it directly instead of discarding it.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postBytesToPort(dartPort, result)');
      case _ when isStructReturn:
        // Bare @HybridStruct NativeAsync: needs an explicit wire format
        // (structs are plain Kotlin data classes at the JNI boundary, not
        // ByteArray-encoded, so nothing in the generic dispatch chain applied —
        // fell to discard + postNullToPort). The struct-specific post*ToPort
        // helper (declared in kotlin_generator.dart) packs the object to a
        // native struct via the JNI side's existing pack_${struct}_from_jni and
        // posts its address, reusing the postBytesToPort null-as-address-0
        // convention.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            post${retBaseName}ToPort(dartPort, result)');
      case _ when isRecord:
        // @HybridRecord (single, list, or primitive-item-list) NativeAsync: encode to the
        // same [4B len][payload] wire format every other record-returning path uses
        // (see _emitRecordBody), then post the ByteArray — mirrors the pointer-posting
        // idiom above instead of the previous discard-and-always-null trampoline.
        //
        // A null record is posted as a null ByteArray (not Dart_CObject_kNull) — the
        // Dart-side unpack for nullable records unconditionally does `raw as int` and
        // treats address 0 (nullptr) as "no value", exactly like the NitroOptXxx and
        // struct pointer-return paths above. Posting kNull here would throw the same
        // TypeError this fix exists to eliminate.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        _emitNativeAsyncRecordEncode(writer, func, spec, isListRecord);
        writer.line('            postBytesToPort(dartPort, _bytes)');
      case _ when func.returnType.isTypedData:
        // The `[8B byteLength][bytes]` block the sync path's JNI glue builds;
        // a null array is address 0.
        writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postBytesToPort(dartPort, ${_typedDataBlock(retType, 'result')})');
      default:
        writer.line('            ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('            postNullToPort(dartPort)');
    }
    writer.line('            } catch (e: Throwable) {');
    writer.line('                reportNativeAsyncError(errPtr, e.javaClass.simpleName, e.message ?: "An unknown native exception occurred.")');
    writer.line('                postNullToPort(dartPort)');
    writer.line('            }');
    writer.line('        }');
    writer.line('    }');
  }

  /// Kotlin expression for the `[8B byteLength][bytes]` block of [value], a
  /// typed-data array of Kotlin type [array] (`FloatArray`, `ByteArray?`, …).
  static String _typedDataBlock(String array, String value) {
    final (size, view) = switch (bareTypeName(array)) {
      'ByteArray' => (1, ''),
      'ShortArray' => (2, '.asShortBuffer()'),
      'IntArray' => (4, '.asIntBuffer()'),
      'FloatArray' => (4, '.asFloatBuffer()'),
      'LongArray' => (8, '.asLongBuffer()'),
      'DoubleArray' => (8, '.asDoubleBuffer()'),
      _ => throw ArgumentError('not a typed-data array: $array'),
    };
    final let = array.endsWith('?') ? '?.let' : '.let';
    return '$value$let { a -> java.nio.ByteBuffer.allocate(8 + a.size * $size).order(java.nio.ByteOrder.LITTLE_ENDIAN).also { it.putLong(a.size.toLong() * $size); it$view.put(a) }.array() }';
  }

  /// Emits Kotlin statements that encode the in-scope `result` (a decoded
  /// record / list-of-records value from a `@NitroNativeAsync` method) into a
  /// `val _bytes` in the exact `[4B len][payload]` wire format every other
  /// record-returning path produces (mirrors `_emitRecordBody`'s encoding,
  /// duplicated rather than shared so the already-working sync/`@nitroAsync`
  /// path can't regress from a native-async-only change).
  static void _emitNativeAsyncRecordEncode(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    bool isListRecord,
  ) {
    if (isListRecord) {
      final itemTypeName = func.returnType.recordListItemType!;
      final itemRt = spec.recordTypes.where((rt) => rt.name == itemTypeName).firstOrNull;
      final hint = itemRt != null ? RecordGenerator.recordBytesHint(itemRt) : 64;
      writer.line('            val itemBufs = ArrayList<ByteArray>(result.size)');
      writer.line('            val tmpBuf = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('            for (item in result) {');
      writer.line('                val tmpOut = java.io.ByteArrayOutputStream($hint)');
      writer.line('                item.writeFieldsTo(tmpOut, tmpBuf)');
      writer.line('                itemBufs.add(tmpOut.toByteArray())');
      writer.line('            }');
      writer.line('            // payload = [4B count][8B × n offsets][item bytes...]');
      writer.line('            var offsetPos = 4 + 8L * result.size  // start of item data in payload');
      writer.line('            val offsets = LongArray(result.size)');
      writer.line('            for (i in result.indices) { offsets[i] = offsetPos; offsetPos += itemBufs[i].size }');
      writer.line('            val payloadBuf = java.nio.ByteBuffer.allocate(offsetPos.toInt()).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('            payloadBuf.putInt(result.size)');
      writer.line('            offsets.forEach { payloadBuf.putLong(it) }');
      writer.line('            itemBufs.forEach { payloadBuf.put(it) }');
      writer.line('            val payload = payloadBuf.array()');
      writer.line('            val lenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('            lenBuf.putInt(payload.size)');
      writer.line('            val _bytes = lenBuf.array() + payload');
    } else if (func.returnType.recordListItemIsPrimitive) {
      final itemTypeName = func.returnType.recordListItemType!;
      if (itemTypeName == 'String') {
        writer.line('            val baos = java.io.ByteArrayOutputStream()');
        writer.line('            val lenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('            val strLenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('            val items = result.map { it.toByteArray(Charsets.UTF_8) }');
        writer.line('            val payloadSize = 4 + items.sumOf { 4 + it.size }');
        writer.line('            lenBuf.putInt(payloadSize)');
        writer.line('            baos.write(lenBuf.array())');
        writer.line('            lenBuf.clear(); lenBuf.putInt(items.size); lenBuf.flip()');
        writer.line('            baos.write(lenBuf.array())');
        writer.line('            for (item in items) { strLenBuf.clear(); strLenBuf.putInt(item.size); strLenBuf.flip(); baos.write(strLenBuf.array()); baos.write(item) }');
        writer.line('            val _bytes = baos.toByteArray()');
      } else {
        final itemSize = itemTypeName == 'bool' ? 1 : 8;
        final putMethod = switch (itemTypeName) {
          'int' => 'putLong',
          'double' => 'putDouble',
          'bool' => 'put',
          _ => 'putLong',
        };
        final encodeExpr = itemTypeName == 'bool' ? '(if (it) 1 else 0).toByte()' : 'it';
        writer.line('            val count = result.size');
        writer.line('            val payloadSize = 4 + $itemSize * count');
        writer.line('            val buf = java.nio.ByteBuffer.allocate(4 + payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('            buf.putInt(payloadSize)');
        writer.line('            buf.putInt(count)');
        writer.line('            result.forEach { buf.$putMethod($encodeExpr) }');
        writer.line('            val _bytes = buf.array()');
      }
    } else {
      // Single @HybridRecord
      if (func.returnType.name.endsWith('?')) {
        writer.line('            val _bytes = result?.encode()');
      } else {
        writer.line('            val _bytes = result.encode()');
      }
    }
  }

  /// Encodes the in-scope `result` (a `List<@HybridEnum>` from a
  /// `@NitroNativeAsync` method) into `val _bytes`, mirroring
  /// `_emitEnumListBody`'s wire format for the sync/`@nitroAsync` path
  /// (duplicated rather than shared for the same isolation reasons as
  /// [_emitNativeAsyncRecordEncode]).
  static void _emitNativeAsyncEnumListEncode(CodeWriter writer, BridgeFunction func) {
    writer.line('            val count = result.size');
    if (func.returnType.recordListItemIsNullable) {
      writer.line('            val payloadSize = 4 + 9 * count // 1B hasValue + 8B value per item');
      writer.line('            val buf = java.nio.ByteBuffer.allocate(4 + payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('            buf.putInt(payloadSize)');
      writer.line('            buf.putInt(count)');
      writer.line('            result.forEach { item -> buf.put(if (item != null) 1 else 0); if (item != null) buf.putLong(item.nativeValue) }');
    } else {
      writer.line('            val payloadSize = 4 + 8 * count');
      writer.line('            val buf = java.nio.ByteBuffer.allocate(4 + payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('            buf.putInt(payloadSize)');
      writer.line('            buf.putInt(count)');
      writer.line('            result.forEach { buf.putLong(it.nativeValue) }');
    }
    writer.line('            val _bytes = buf.array()');
  }

  /// Encodes the in-scope `result` (a `List<@NitroVariant>` from a
  /// `@NitroNativeAsync` method) into `val _bytes`, mirroring
  /// `_emitVariantListBody`'s wire format for the sync/`@nitroAsync` path.
  static void _emitNativeAsyncVariantListEncode(CodeWriter writer, BridgeFunction func) {
    if (func.returnType.recordListItemIsNullable) {
      writer.line('            val _itemBytes = result.map { item ->');
      writer.line('                if (item == null) byteArrayOf(0)');
      writer.line('                else { val _iw = ${KotlinTypeMapper.codec(func.returnType.recordListItemType, 'RecordWriter')}(); item.writeFields(_iw); byteArrayOf(1) + _iw.toByteArray() }');
      writer.line('            }');
    } else {
      writer.line('            val _itemBytes = result.map { item ->');
      writer.line('                val _iw = ${KotlinTypeMapper.codec(func.returnType.recordListItemType, 'RecordWriter')}(); item.writeFields(_iw); _iw.toByteArray()');
      writer.line('            }');
    }
    writer.line('            val _payloadSize = 4 + _itemBytes.sumOf { it.size }');
    writer.line('            val _payloadBuf = java.nio.ByteBuffer.allocate(_payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('            _payloadBuf.putInt(result.size)');
    writer.line('            _itemBytes.forEach { _payloadBuf.put(it) }');
    writer.line('            val _payload = _payloadBuf.array()');
    writer.line('            val _buf = java.nio.ByteBuffer.allocate(4 + _payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('            _buf.putInt(_payloadSize)');
    writer.line('            _buf.put(_payload)');
    writer.line('            val _bytes = _buf.array()');
  }

  // ── Parameter decoding helpers ──────────────────────────────────────────────

  static void _emitParamDecodes(CodeWriter writer, BridgeFunction func, KotlinTypeMapper mapper) {
    // Decode @NitroVariant params from ByteArray [4B len][1B tag][fields].
    for (final p in func.params) {
      final bn = bareTypeName(p.type.name);
      if (mapper.variantNames.contains(bn)) {
        writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        ${p.name}Buf.getInt() // skip 4-byte length prefix');
        writer.line('        val ${p.name}Decoded = $bn.fromReader(${KotlinTypeMapper.codec(bn, 'RecordReader')}(${p.name}Buf))');
        continue;
      }
    }
    // Decode @HybridRecord params from ByteArray.
    for (final p in func.params) {
      if (!p.type.isRecord || p.type.isMap) continue;

      // List<@HybridEnum> / List<@HybridEnum?>
      if (p.type.isEnumList) {
        final itemType = p.type.recordListItemType!;
        writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        ${p.name}Buf.getInt() // skip 4B payload_len');
        writer.line('        val ${p.name}Count = ${p.name}Buf.getInt()');
        if (p.type.recordListItemIsNullable) {
          // Nullable: [1B hasValue][8B nativeValue (if hasValue)]×N
          writer.line('        val ${p.name}Decoded = mutableListOf<$itemType?>()');
          writer.line('        repeat(${p.name}Count) { val _has = ${p.name}Buf.get().toInt() != 0; ${p.name}Decoded.add(if (_has) $itemType.fromNative(${p.name}Buf.getLong()) else null) }');
        } else {
          writer.line('        val ${p.name}Decoded = mutableListOf<$itemType>()');
          writer.line('        repeat(${p.name}Count) { ${p.name}Decoded.add($itemType.fromNative(${p.name}Buf.getLong())) }');
        }
        continue;
      }
      // List<@NitroVariant> / List<@NitroVariant?>
      if (p.type.isVariantList) {
        final itemType = p.type.recordListItemType!;
        writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        ${p.name}Buf.getInt() // skip 4B payload_len');
        writer.line('        val ${p.name}Count = ${p.name}Buf.getInt()');
        if (p.type.recordListItemIsNullable) {
          // Nullable: [1B hasValue][tag+fields (if hasValue)]×N
          writer.line('        val ${p.name}Decoded = mutableListOf<$itemType?>()');
          writer.line('        val ${p.name}Rdr = ${KotlinTypeMapper.codec(itemType, 'RecordReader')}(${p.name}Buf)');
          writer.line('        repeat(${p.name}Count) { val _has = ${p.name}Rdr.readBool(); ${p.name}Decoded.add(if (_has) $itemType.fromReader(${p.name}Rdr) else null) }');
        } else {
          writer.line('        val ${p.name}Decoded = mutableListOf<$itemType>()');
          writer.line('        val ${p.name}Rdr = ${KotlinTypeMapper.codec(itemType, 'RecordReader')}(${p.name}Buf)');
          writer.line('        repeat(${p.name}Count) { ${p.name}Decoded.add($itemType.fromReader(${p.name}Rdr)) }');
        }
        continue;
      }

      if (p.type.recordListItemType == null) {
        // Single @HybridRecord param
        final recordName = bareTypeName(p.type.name);
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
          'bool' => 'ArrayList<Boolean>',
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
            writer.line('            ${p.name}Decoded.add(itemBuf.get().toInt() != 0)');
          } else {
            writer.line('            ${p.name}Decoded.add(itemBuf.$readMethod())');
          }
          writer.line('        }');
        }
      }
    }
  }

  // ── List<@HybridEnum> return body ─────────────────────────────────────────────

  static void _emitEnumListBody(
    CodeWriter writer,
    BridgeFunction func,
    String callParams,
  ) {
    if (func.isAsync) {
      final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}($callParams)');
      writer.line('        val result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('        val result = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
    }
    writer.line('        val count = result.size');
    if (func.returnType.recordListItemIsNullable) {
      // Nullable enum list: [4B count][1B hasValue][8B nativeValue]×N
      writer.line('        val payloadSize = 4 + 9 * count // 1B hasValue + 8B value per item');
      writer.line('        val buf = java.nio.ByteBuffer.allocate(4 + payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('        buf.putInt(payloadSize)');
      writer.line('        buf.putInt(count)');
      writer.line('        result.forEach { item -> buf.put(if (item != null) 1 else 0); if (item != null) buf.putLong(item.nativeValue) }');
    } else {
      writer.line('        val payloadSize = 4 + 8 * count');
      writer.line('        val buf = java.nio.ByteBuffer.allocate(4 + payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('        buf.putInt(payloadSize)');
      writer.line('        buf.putInt(count)');
      writer.line('        result.forEach { buf.putLong(it.nativeValue) }');
    }
    writer.line('        return buf.array()');
  }

  // ── List<@NitroVariant> return body ───────────────────────────────────────────

  static void _emitVariantListBody(
    CodeWriter writer,
    BridgeFunction func,
    String callParams,
  ) {
    if (func.isAsync) {
      final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}($callParams)');
      writer.line('        val result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('        val result = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
    }
    writer.line('        return ${_emitVariantListEncode(writer, func)}');
  }

  /// Emits the statements that encode `result`, the `List<@NitroVariant>`
  /// [func] returns, and gives the expression for the finished block.
  static String _emitVariantListEncode(CodeWriter writer, BridgeFunction func) {
    if (func.returnType.recordListItemIsNullable) {
      // Nullable variant list: [4B count][1B hasValue][tag+fields (if hasValue)]×N
      writer.line('        val _itemBytes = result.map { item ->');
      writer.line('            if (item == null) byteArrayOf(0)');
      writer.line('            else { val _iw = ${KotlinTypeMapper.codec(func.returnType.recordListItemType, 'RecordWriter')}(); item.writeFields(_iw); byteArrayOf(1) + _iw.toByteArray() }');
      writer.line('        }');
    } else {
      writer.line('        val _itemBytes = result.map { item ->');
      writer.line('            val _iw = ${KotlinTypeMapper.codec(func.returnType.recordListItemType, 'RecordWriter')}(); item.writeFields(_iw); _iw.toByteArray()');
      writer.line('        }');
    }
    writer.line('        val _payloadSize = 4 + _itemBytes.sumOf { it.size }');
    writer.line('        val _payloadBuf = java.nio.ByteBuffer.allocate(_payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('        _payloadBuf.putInt(result.size)');
    writer.line('        _itemBytes.forEach { _payloadBuf.put(it) }');
    writer.line('        val _payload = _payloadBuf.array()');
    writer.line('        val _buf = java.nio.ByteBuffer.allocate(4 + _payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('        _buf.putInt(_payloadSize)');
    writer.line('        _buf.put(_payload)');
    return '_buf.array()';
  }

  // ── Map / NitroAnyMap return body ────────────────────────────────────────────

  /// A method that returns a `Map<String, V>` or a `NitroAnyMap`. Its
  /// parameters, maps included, were decoded by the generic path, so any
  /// parameter list works.
  static void _emitMapReturnBody(CodeWriter writer, BridgeFunction func, BridgeSpec spec, String callParams) {
    final call = 'impl.${func.dartName}($callParams)';
    writer.line(
      func.isAsync
          ? '        val _result = _asyncExecutor.submit(java.util.concurrent.Callable { ${KotlinTypeMapper.runBlockingCall(func, call)} }).get()'
          : '        val _result = ${KotlinTypeMapper.syncImplCall(func, call)}',
    );
    writer.line('        return ${KotlinMapEmitter.encodeExpr(func.returnType, spec, '_result')}');
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
      writer.line('        val result = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
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
      if (itemTypeName == 'String') {
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
      } else {
        final itemSize = itemTypeName == 'bool' ? 1 : 8;
        final putMethod = switch (itemTypeName) {
          'int' => 'putLong',
          'double' => 'putDouble',
          'bool' => 'put',
          _ => 'putLong',
        };
        final encodeExpr = itemTypeName == 'bool' ? '(if (it) 1 else 0).toByte()' : 'it';
        writer.line('        val count = result.size');
        writer.line('        val payloadSize = 4 + $itemSize * count');
        writer.line('        val buf = java.nio.ByteBuffer.allocate(4 + payloadSize).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        buf.putInt(payloadSize)');
        writer.line('        buf.putInt(count)');
        writer.line('        result.forEach { buf.$putMethod($encodeExpr) }');
        writer.line('        return buf.array()');
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
      writer.line('        return NitroOptBool(_boolResult).encode()');
    } else if (isNullableInt) {
      writer.line('        val _intResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
      writer.line('        return NitroOptInt64(_intResult).encode()');
    } else if (isNullableDouble) {
      writer.line('        val _doubleResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
      writer.line('        return NitroOptFloat64(_doubleResult).encode()');
    } else {
      writer.line('        return _asyncExecutor.submit(java.util.concurrent.Callable {');
      writer.line('            $rb');
      writer.line('        }).get()');
    }
  }

  // ── @NitroResult body ─────────────────────────────────────────────────────────

  /// Emits the JNI bridge body for a @NitroResult function.
  ///
  /// The Kotlin impl declares it as a throwing function (annotated with @Throws).
  /// The bridge wraps it in try/catch and encodes the result as ByteArray:
  ///   [1B tag: 0=ok, 1=err][record-codec payload]
  static void _emitResultBody(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    KotlinTypeMapper mapper,
    String callParams,
  ) {
    final retBaseName = bareTypeName(func.returnType.name);
    // A value with no encoding of its own (nullable, list, typed data, struct)
    // travels as a one-field record — see BridgeSpec.resultWrapper.
    writer.line('        return try {');
    if (func.isAsync) {
      final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}($callParams)');
      writer.line('            val _result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('            val _result = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
    }
    switch (spec.resultCarrier(func)) {
      // A value with no encoding of its own travels as a one-field record.
      case WrappedCarrier(:final wrapper):
        writer.line('            nitroWriteResultTag(0, ${wrapper.name}(_result).encode())');
      // The value's usual `[4B len][payload]` block behind the tag, built by
      // the encoder its plain return uses. Tag 2: ok, and the value is null.
      case BlockCarrier(:final kind, :final isNullable):
        final block = CodeWriter();
        final blob = switch (kind) {
          BlockKind.anyMap || BlockKind.map => KotlinMapEmitter.encodeExpr(func.returnType.nonNullable, spec, '_result'),
          BlockKind.variantList => _emitVariantListEncode(block..line('        val result = _result'), func),
          BlockKind.variant => '_result.encode()',
        };
        final pad = isNullable ? '        ' : '    ';
        if (isNullable) writer.line('            if (_result == null) byteArrayOf(2, 0, 0, 0, 0) else {');
        for (final l in block.toString().split('\n').where((l) => l.isNotEmpty)) {
          writer.line('$pad$l');
        }
        writer.line('$pad        nitroWriteResultTag(0, $blob)');
        if (isNullable) writer.line('            }');
      case ScalarCarrier() || RecordCarrier() || NoCarrier():
        writer.line('            ${_kotlinResultEncodeOk(retBaseName, mapper)}');
    }
    writer.line('        } catch (_e: Throwable) {');
    writer.line('            nitroEncodeResultError(_e.message ?: "Unknown error")');
    writer.line('        }');
  }

  static String _kotlinResultEncodeOk(String retBaseName, KotlinTypeMapper mapper) {
    switch (retBaseName) {
      case 'int':
        return 'nitroEncodeResultInt64(_result)';
      case 'double':
        return 'nitroEncodeResultFloat64(_result)';
      case 'bool':
        return 'nitroEncodeResultBool(_result)';
      case 'String':
        return 'nitroEncodeResultString(_result)';
      default:
        if (mapper.enumNames.contains(retBaseName)) return 'nitroEncodeResultInt64(_result.nativeValue)';
        return 'nitroEncodeResultRecord(_result)'; // @HybridRecord / variant
    }
  }

  // ── @NitroVariant return body ─────────────────────────────────────────────────

  static void _emitVariantReturnBody(
    CodeWriter writer,
    BridgeFunction func,
    String retBaseName,
    String callParams,
  ) {
    if (func.isAsync) {
      final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}($callParams)');
      writer.line('        val _vResult = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('        val _vResult = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
    }
    writer.line('        val _vw = ${KotlinTypeMapper.codec(retBaseName, 'RecordWriter')}()');
    writer.line('        _vResult.writeFields(_vw)');
    writer.line('        val _vPayload = _vw.toByteArray()');
    writer.line('        val _vBuf = java.nio.ByteBuffer.allocate(4 + _vPayload.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('        _vBuf.putInt(_vPayload.size)');
    writer.line('        _vBuf.put(_vPayload)');
    writer.line('        return _vBuf.array()');
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
      writer.line('        ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
    } else if (isEnum) {
      if (isNullableEnum) {
        writer.line('        val _enumResult = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
        writer.line('        return if (_enumResult == null) -1L else _enumResult.nativeValue');
      } else {
        writer.line('        return ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}.nativeValue');
      }
    } else if (isNullableBool) {
      writer.line('        val _boolResult = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('        return NitroOptBool(_boolResult).encode()');
    } else if (isNullableInt) {
      writer.line('        val _intResult = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('        return NitroOptInt64(_intResult).encode()');
    } else if (isNullableDouble) {
      writer.line('        val _doubleResult = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('        return NitroOptFloat64(_doubleResult).encode()');
    } else {
      writer.line('        return ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
    }
  }
}
