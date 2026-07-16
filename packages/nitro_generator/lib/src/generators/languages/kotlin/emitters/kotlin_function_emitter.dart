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
    // instanceId is the first param for per-instance dispatch (Point 13).
    final bridgeParamsDecl = ['instanceId: Long', ...func.params.map((p) => '${p.name}: ${mapper.bridgeParamType(p)}')].join(', ');

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
    final isMap = func.returnType.isMap || func.params.any((p) => p.type.isMap);
    final isAnyMap = func.returnType.isAnyMap;
    final isEnumListReturn = func.returnType.isEnumList;
    final isVariantListReturn = func.returnType.isVariantList;
    final isListRecord = isRecord && func.returnType.recordListItemType != null && !func.returnType.recordListItemIsPrimitive && !isEnumListReturn && !isVariantListReturn;
    final isNullableBoolReturn = retBaseName == 'bool' && func.returnType.name.endsWith('?');
    final isNullableIntReturn = (retBaseName == 'int' || retBaseName == 'uint64' || retBaseName == 'DateTime') && func.returnType.name.endsWith('?');
    final isNullableDoubleReturn = retBaseName == 'double' && func.returnType.name.endsWith('?');
    final isVariantReturn = mapper.variantNames.contains(retBaseName);

    final bridgeRetType = func.isResult
        ? 'ByteArray' // @NitroResult: [1B tag][record payload]
        : isVariantReturn
        ? 'ByteArray' // @NitroVariant: [4B len][1B tag][fields]
        : isEnumListReturn
        ? 'ByteArray' // List<@HybridEnum>: [4B len][4B count][8B×N]
        : isVariantListReturn
        ? 'ByteArray' // List<@NitroVariant>: [4B len][4B count][tag+fields×N]
        : (isNullableBoolReturn || isNullableIntReturn || isNullableDoubleReturn)
        ? 'ByteArray'
        : isEnum
        ? 'Long'
        : isRecord
        ? (func.returnType.name.endsWith('?') ? 'ByteArray?' : 'ByteArray')
        : isAnyMap
        ? 'ByteArray' // NitroAnyMap: type-tagged binary (same wire as @HybridRecord)
        : isMap && !isUnit
        ? 'ByteArray'
        : retType;

    bool isOptPrim(BridgeParam p) => p.type.isNullableNitroPrim || (p.isOptional && BridgeType.nitroPrimBases.contains(p.type.baseName));

    // Optional-primitive params that need NitroNullable ByteArray decoding.
    final optPrimParams = func.params.where(isOptPrim).toList();

    // Resolve call params — decode enums, records, variants, callbacks, nullable prims.
    final callParams = _buildCallParams(func, mapper);

    writer.line('    @JvmStatic fun ${func.dartName}_call($bridgeParamsDecl): $bridgeRetType {');
    writer.line('        val impl = _implementations[instanceId] ?: throw IllegalStateException("${spec.dartClassName} instance \$instanceId not registered")');

    // Decode nullable primitive params from NitroOpt* ByteArray ([1B hasValue][N bytes value]).
    for (final p in optPrimParams) {
      final bn = p.type.name.replaceFirst('?', '');
      if (bn == 'int') {
        writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
      } else if (bn == 'bool') {
        writer.line('        val ${p.name}Arg: Boolean? = NitroOptBool.decode(${p.name}).nullable');
      } else if (bn == 'double') {
        writer.line('        val ${p.name}Arg: Double? = NitroOptFloat64.decode(${p.name}).nullable');
      } else if (bn == 'DateTime') {
        writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
      } else if (bn == 'uint64') {
        writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
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

    if (func.isResult) {
      _emitResultBody(writer, func, mapper, callParams);
    } else if (isVariantReturn) {
      _emitVariantReturnBody(writer, func, retBaseName, callParams);
    } else if (isEnumListReturn) {
      _emitEnumListBody(writer, func, callParams);
    } else if (isVariantListReturn) {
      _emitVariantListBody(writer, func, callParams);
    } else if (isAnyMap) {
      _emitAnyMapBody(writer, func, callParams);
    } else if (isMap) {
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
          final baseName = p.type.name.replaceFirst('?', '');
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
    final retBaseName = func.returnType.name.replaceFirst('?', '');
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
      final bn = p.type.name.replaceFirst('?', '');
      if (bn == 'int') {
        writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
      } else if (bn == 'bool') {
        writer.line('        val ${p.name}Arg: Boolean? = NitroOptBool.decode(${p.name}).nullable');
      } else if (bn == 'double') {
        writer.line('        val ${p.name}Arg: Double? = NitroOptFloat64.decode(${p.name}).nullable');
      } else if (bn == 'DateTime') {
        writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
      } else if (bn == 'uint64') {
        writer.line('        val ${p.name}Arg: Long? = NitroOptInt64.decode(${p.name}).nullable');
      }
    }
    // Decode nullable enum params from Long sentinel (-1 = null) — mirrors the
    // sync path's equivalent block; native-async previously skipped this and
    // forwarded the raw Long where a nullable enum was expected.
    for (final p in func.params) {
      final bn = p.type.name.replaceFirst('?', '');
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
    // Decode Map<String,V> / NitroAnyMap params from ByteArray — previously
    // never handled for native-async either (this was the one param category
    // left deferred from the earlier param-decoding fix, since the sync
    // path's map decode is entangled with its own return-side dispatch).
    for (final p in func.params) {
      if (p.type.isAnyMap) {
        _emitNativeAsyncAnyMapParamDecode(writer, p);
      } else if (p.type.isMap) {
        _emitNativeAsyncMapParamDecode(writer, p, spec);
      }
    }

    writer.line('        _asyncExecutor.execute {');
    writer.line('            try {');
    if (isUnit) {
      writer.line('            ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postNullToPort(dartPort)');
    } else if (isEnum) {
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      if (isNullableReturn) {
        writer.line('            if (result == null) postInt64ToPort(dartPort, -1L) else postInt64ToPort(dartPort, result.nativeValue)');
      } else {
        writer.line('            postInt64ToPort(dartPort, result.nativeValue)');
      }
    } else if (retType == 'String') {
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postStringToPort(dartPort, result)');
    } else if (retType == 'String?') {
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            if (result == null) postNullToPort(dartPort) else postStringToPort(dartPort, result)');
    } else if (retType == 'Boolean') {
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postBoolToPort(dartPort, result)');
    } else if (retType == 'Boolean?') {
      // bool? NativeAsync: post pointer to NitroOptBool (2 bytes); Dart decodes via fromAddress.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postOptBoolToPort(dartPort, result ?: false, result != null)');
    } else if (func.returnType.isNativeHandle) {
      // NativeHandle NativeAsync (issue #18): the impl returns the raw
      // pointer address as Long — post it as kInt64. Address 0 means null
      // for a nullable handle (the Kotlin interface declares Long on every
      // path, so null is expressed as 0, matching the Dart-side unpack).
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postInt64ToPort(dartPort, result)');
    } else if (retType == 'Long' || retType == 'Int') {
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postInt64ToPort(dartPort, result.toLong())');
    } else if (retType == 'Long?' || retType == 'Int?') {
      // Long?/Int? NativeAsync: post pointer to NitroOptInt64 (9 bytes); Dart decodes via fromAddress.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postOptInt64ToPort(dartPort, result?.toLong() ?: 0L, result != null)');
    } else if (retType == 'Double') {
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postDoubleToPort(dartPort, result)');
    } else if (retType == 'Double?') {
      // Double? NativeAsync: post pointer to NitroOptFloat64 (9 bytes); Dart decodes via fromAddress.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postOptFloat64ToPort(dartPort, result ?: 0.0, result != null)');
    } else if (isEnumListReturn) {
      // List<@HybridEnum> NativeAsync: checked BEFORE isRecord — spec_extractor
      // sets isRecord alongside isEnumList, so without this branch these fell
      // into the isRecord path's single-record fallback and called `.encode()`
      // on a Kotlin List (not a member — compile error). Mirrors the encoding
      // _emitEnumListBody uses for the sync/@nitroAsync path.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      _emitNativeAsyncEnumListEncode(writer, func);
      writer.line('            postBytesToPort(dartPort, _bytes)');
    } else if (isVariantListReturn) {
      // List<@NitroVariant> NativeAsync: same reasoning as isEnumListReturn
      // above. Mirrors the encoding _emitVariantListBody uses for the
      // sync/@nitroAsync path.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      _emitNativeAsyncVariantListEncode(writer, func);
      writer.line('            postBytesToPort(dartPort, _bytes)');
    } else if (isVariantReturn) {
      // Bare @NitroVariant NativeAsync: previously fell to the generic else
      // (discard + always-null), the same bug class as the fixed record
      // return. Mirrors _emitVariantReturnBody's wire format.
      writer.line('            val _vResult = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            val _vw = RecordWriter()');
      writer.line('            _vResult.writeFields(_vw)');
      writer.line('            val _vPayload = _vw.toByteArray()');
      writer.line('            val _vBuf = java.nio.ByteBuffer.allocate(4 + _vPayload.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
      writer.line('            _vBuf.putInt(_vPayload.size)');
      writer.line('            _vBuf.put(_vPayload)');
      writer.line('            postBytesToPort(dartPort, _vBuf.array())');
    } else if (isAnyMapReturn) {
      // NitroAnyMap NativeAsync: previously fell to the generic else. Only
      // the return side is handled here — a NitroAnyMap *parameter* on a
      // @NitroNativeAsync method remains unfixed (deferred, see param-phase
      // notes) since it needs its own decode step this branch doesn't add.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            @Suppress("UNCHECKED_CAST")');
      writer.line('            val _outMap = result as? Map<String, Any?> ?: emptyMap()');
      writer.line('            postBytesToPort(dartPort, NitroAnyMapCodec.encode(_outMap))');
    } else if (isMapReturn) {
      // Map<String,V> NativeAsync: previously fell to the generic else. Same
      // return-only scope note as isAnyMapReturn above.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      _emitNativeAsyncMapEncode(writer, func, spec);
      writer.line('            postBytesToPort(dartPort, _bytes)');
    } else if (isCustomTypeReturn) {
      // @NitroCustomType NativeAsync: the impl already returns a raw,
      // user-encoded ByteArray (custom types have no generator-side
      // encode/decode) — post it directly instead of discarding it.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            postBytesToPort(dartPort, result)');
    } else if (isStructReturn) {
      // Bare @HybridStruct NativeAsync: previously had no wire format at all
      // (structs are plain Kotlin data classes at the JNI boundary, not
      // ByteArray-encoded, so nothing in the generic dispatch chain applied —
      // fell to discard + postNullToPort). The struct-specific post*ToPort
      // helper (declared in kotlin_generator.dart) packs the object to a
      // native struct via the JNI side's existing pack_${struct}_from_jni and
      // posts its address, reusing the postBytesToPort null-as-address-0
      // convention.
      writer.line('            val result = ${KotlinTypeMapper.runBlockingCall(func, "impl.${func.dartName}($callParams)")}');
      writer.line('            post${retBaseName}ToPort(dartPort, result)');
    } else if (isRecord) {
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
    } else {
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
      writer.line('                else { val _iw = RecordWriter(); item.writeFields(_iw); byteArrayOf(1) + _iw.toByteArray() }');
      writer.line('            }');
    } else {
      writer.line('            val _itemBytes = result.map { item ->');
      writer.line('                val _iw = RecordWriter(); item.writeFields(_iw); _iw.toByteArray()');
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

  /// Encodes the in-scope `result` (a `Map<String,V>` from a
  /// `@NitroNativeAsync` method) into `val _bytes`, mirroring the output side
  /// of `_emitMapBody`'s wire format. Return-only — does not decode a map
  /// *parameter* (see the `isMapReturn` dispatch branch's note).
  static void _emitNativeAsyncMapEncode(CodeWriter writer, BridgeFunction func, BridgeSpec spec) {
    final mapValueType = (() {
      final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(func.returnType.name);
      return m?.group(1)?.trim() ?? 'Any?';
    })();
    final isOutputEnum = spec.isEnumName(mapValueType);
    final isOutputRecord = spec.recordTypes.any((r) => r.name == mapValueType);
    final isOutputVariant = spec.isVariantName(mapValueType);
    final outKtValueType = switch (mapValueType) {
      'int' => 'Long',
      'double' => 'Double',
      'bool' => 'Boolean',
      'String' => 'String',
      _ when isOutputEnum => mapValueType,
      _ when isOutputRecord => mapValueType,
      _ when isOutputVariant => mapValueType,
      _ => 'Any?',
    };
    writer.line('            @Suppress("UNCHECKED_CAST")');
    writer.line('            val _outMap = result as? Map<String, $outKtValueType> ?: emptyMap()');
    writer.line('            val _outBb = java.io.ByteArrayOutputStream()');
    writer.line('            val _outBuf = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('            fun _writeInt32(v: Int) { _outBuf.clear(); _outBuf.putInt(v); _outBb.write(_outBuf.array(), 0, 4) }');
    writer.line('            fun _writeInt64(v: Long) { _outBuf.clear(); _outBuf.putLong(v); _outBb.write(_outBuf.array()) }');
    writer.line('            fun _writeDouble(v: Double) { _outBuf.clear(); _outBuf.putDouble(v); _outBb.write(_outBuf.array()) }');
    writer.line('            _writeInt32(_outMap.size)');
    writer.line('            for ((k, v) in _outMap) {');
    writer.line('                val kb = k.toByteArray(Charsets.UTF_8); _writeInt32(kb.size); _outBb.write(kb)');
    if (mapValueType == 'int' || mapValueType == 'Long') {
      writer.line('                _outBb.write(1) // tag: int64');
      writer.line('                _writeInt64(v)');
    } else if (mapValueType == 'double' || mapValueType == 'Double') {
      writer.line('                _outBb.write(2) // tag: float64');
      writer.line('                _writeDouble(v)');
    } else if (mapValueType == 'bool' || mapValueType == 'Boolean') {
      writer.line('                _outBb.write(3) // tag: bool');
      writer.line('                _outBb.write(if (v) 1 else 0)');
    } else if (mapValueType == 'String') {
      writer.line('                _outBb.write(4) // tag: string');
      writer.line('                val vb = v.toByteArray(Charsets.UTF_8); _writeInt32(vb.size); _outBb.write(vb)');
    } else if (isOutputEnum) {
      writer.line('                _outBb.write(1) // tag: int64 (enum rawValue)');
      writer.line('                _writeInt64((v as $mapValueType).nativeValue)');
    } else if (isOutputRecord) {
      writer.line('                _outBb.write(5) // tag: binary record');
      writer.line('                val _rBytes = (v as $mapValueType).encode()');
      writer.line('                _writeInt32(_rBytes.size); _outBb.write(_rBytes)');
    } else if (isOutputVariant) {
      writer.line('                _outBb.write(5) // tag: binary variant');
      writer.line('                val _rBytes = (v as $mapValueType).encode()');
      writer.line('                _writeInt32(_rBytes.size); _outBb.write(_rBytes)');
    } else {
      writer.line('                _outBb.write(4) // tag: string (generic fallback)');
      writer.line('                val vb = v.toString().toByteArray(Charsets.UTF_8); _writeInt32(vb.size); _outBb.write(vb)');
    }
    writer.line('            }');
    writer.line('            val _payload = _outBb.toByteArray()');
    writer.line('            val _lenBuf = java.nio.ByteBuffer.allocate(4).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('            _lenBuf.putInt(_payload.size)');
    writer.line('            val _bytes = _lenBuf.array() + _payload');
  }

  /// Decodes a `NitroAnyMap` param (param [p]) into `val ${p.name}Decoded`.
  /// Previously unhandled for native-async — the only param category left
  /// deferred from the earlier param-decoding fix.
  static void _emitNativeAsyncAnyMapParamDecode(CodeWriter writer, BridgeParam p) {
    writer.line('        val ${p.name}Decoded: Map<String, Any?> = NitroAnyMapCodec.decode(${p.name})');
  }

  /// Decodes a `Map<String,V>` param (param [p]) into `val ${p.name}Decoded`,
  /// mirroring the input-decode half of `_emitMapBody`'s wire format. Local
  /// variable names are namespaced by `${p.name}` so multiple map params on
  /// the same function don't collide. Previously unhandled for native-async.
  static void _emitNativeAsyncMapParamDecode(CodeWriter writer, BridgeParam p, BridgeSpec spec) {
    final mapValueType = (() {
      final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(p.type.name);
      return m?.group(1)?.trim() ?? 'Any?';
    })();
    final isValEnum = spec.isEnumName(mapValueType);
    final isValRecord = spec.recordTypes.any((r) => r.name == mapValueType);
    final isValVariant = spec.isVariantName(mapValueType);
    final ktValueType = switch (mapValueType) {
      'int' => 'Long',
      'double' => 'Double',
      'bool' => 'Boolean',
      'String' => 'String',
      _ when isValEnum => mapValueType,
      _ when isValRecord => mapValueType,
      _ when isValVariant => mapValueType,
      _ => 'Any?',
    };
    final useTyped = ktValueType != 'Any?';
    writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('        ${p.name}Buf.position(4) // skip 4-byte payload length prefix');
    writer.line('        val ${p.name}Count = ${p.name}Buf.int');
    if (useTyped) {
      writer.line('        val ${p.name}Decoded = mutableMapOf<String, $ktValueType>()');
    } else {
      writer.line('        val ${p.name}Decoded = mutableMapOf<String, Any?>()');
    }
    writer.line('        repeat(${p.name}Count) {');
    writer.line('            val _${p.name}KLen = ${p.name}Buf.int; val _${p.name}KBytes = ByteArray(_${p.name}KLen); ${p.name}Buf.get(_${p.name}KBytes)');
    writer.line('            val _${p.name}K = _${p.name}KBytes.toString(Charsets.UTF_8)');
    writer.line('            ${p.name}Buf.get() // skip 1-byte type tag');
    if (mapValueType == 'int' || mapValueType == 'Long') {
      writer.line('            ${p.name}Decoded[_${p.name}K] = ${p.name}Buf.long');
    } else if (mapValueType == 'double' || mapValueType == 'Double') {
      writer.line('            ${p.name}Decoded[_${p.name}K] = ${p.name}Buf.double');
    } else if (mapValueType == 'bool' || mapValueType == 'Boolean') {
      writer.line('            ${p.name}Decoded[_${p.name}K] = ${p.name}Buf.get().toInt() != 0');
    } else if (isValEnum) {
      writer.line('            ${p.name}Decoded[_${p.name}K] = $mapValueType.fromNative(${p.name}Buf.long)');
    } else if (isValRecord) {
      writer.line('            val _${p.name}BLen = ${p.name}Buf.int; val _${p.name}BBytes = ByteArray(_${p.name}BLen); ${p.name}Buf.get(_${p.name}BBytes)');
      writer.line(
        '            val _${p.name}BBuf = java.nio.ByteBuffer.wrap(_${p.name}BBytes).order(java.nio.ByteOrder.LITTLE_ENDIAN); _${p.name}BBuf.getInt()',
      );
      writer.line('            ${p.name}Decoded[_${p.name}K] = $mapValueType.decodeFrom(_${p.name}BBuf)');
    } else if (isValVariant) {
      writer.line('            val _${p.name}BLen = ${p.name}Buf.int; val _${p.name}BBytes = ByteArray(_${p.name}BLen); ${p.name}Buf.get(_${p.name}BBytes)');
      writer.line(
        '            val _${p.name}BBuf = java.nio.ByteBuffer.wrap(_${p.name}BBytes).order(java.nio.ByteOrder.LITTLE_ENDIAN); _${p.name}BBuf.getInt()',
      );
      writer.line('            ${p.name}Decoded[_${p.name}K] = $mapValueType.fromReader(RecordReader(_${p.name}BBuf))');
    } else {
      writer.line('            val _${p.name}VLen = ${p.name}Buf.int; val _${p.name}VBytes = ByteArray(_${p.name}VLen); ${p.name}Buf.get(_${p.name}VBytes)');
      writer.line('            ${p.name}Decoded[_${p.name}K] = _${p.name}VBytes.toString(Charsets.UTF_8)');
    }
    writer.line('        }');
  }

  // ── Parameter decoding helpers ──────────────────────────────────────────────

  static void _emitParamDecodes(CodeWriter writer, BridgeFunction func, KotlinTypeMapper mapper) {
    // Decode @NitroVariant params from ByteArray [4B len][1B tag][fields].
    for (final p in func.params) {
      final bn = p.type.name.replaceFirst('?', '');
      if (mapper.variantNames.contains(bn)) {
        writer.line('        val ${p.name}Buf = java.nio.ByteBuffer.wrap(${p.name}).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        ${p.name}Buf.getInt() // skip 4-byte length prefix');
        writer.line('        val ${p.name}Decoded = $bn.fromReader(RecordReader(${p.name}Buf))');
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
          writer.line('        val ${p.name}Rdr = RecordReader(${p.name}Buf)');
          writer.line('        repeat(${p.name}Count) { val _has = ${p.name}Rdr.readBool(); ${p.name}Decoded.add(if (_has) $itemType.fromReader(${p.name}Rdr) else null) }');
        } else {
          writer.line('        val ${p.name}Decoded = mutableListOf<$itemType>()');
          writer.line('        val ${p.name}Rdr = RecordReader(${p.name}Buf)');
          writer.line('        repeat(${p.name}Count) { ${p.name}Decoded.add($itemType.fromReader(${p.name}Rdr)) }');
        }
        continue;
      }

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
    if (func.returnType.recordListItemIsNullable) {
      // Nullable variant list: [4B count][1B hasValue][tag+fields (if hasValue)]×N
      writer.line('        val _itemBytes = result.map { item ->');
      writer.line('            if (item == null) byteArrayOf(0)');
      writer.line('            else { val _iw = RecordWriter(); item.writeFields(_iw); byteArrayOf(1) + _iw.toByteArray() }');
      writer.line('        }');
    } else {
      writer.line('        val _itemBytes = result.map { item ->');
      writer.line('            val _iw = RecordWriter(); item.writeFields(_iw); _iw.toByteArray()');
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
    writer.line('        return _buf.array()');
  }

  // ── NitroAnyMap body ──────────────────────────────────────────────────────────

  static void _emitAnyMapBody(
    CodeWriter writer,
    BridgeFunction func,
    String callParams,
  ) {
    // Decode input param (if any) from NitroAnyMap ByteArray.
    final anyMapParam = func.params.firstWhere(
      (p) => p.type.isAnyMap,
      orElse: () => func.params.isNotEmpty
          ? func.params.first
          : BridgeParam(
              name: '',
              type: BridgeType(name: 'NitroAnyMap', isAnyMap: true),
            ),
    );
    final paramName = anyMapParam.name;

    if (func.params.any((p) => p.type.isAnyMap)) {
      writer.line('        val ${paramName}Decoded: Map<String, Any?> = NitroAnyMapCodec.decode($paramName)');
    }

    // Resolve actual call params — replace the anymap param with decoded version.
    final resolvedCallParams = func.params
        .map((p) {
          if (p.type.isAnyMap) return '${p.name}Decoded';
          return p.name;
        })
        .join(', ');

    if (func.isAsync) {
      final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}($resolvedCallParams)');
      writer.line('        val _result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('        val _result = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($resolvedCallParams)")}');
    }

    // Encode result as NitroAnyMap ByteArray.
    if (func.returnType.name == 'void' || func.returnType.name == 'Unit') {
      writer.line('    }');
      return;
    }
    writer.line('        @Suppress("UNCHECKED_CAST")');
    writer.line('        val _outMap = _result as? Map<String, Any?> ?: emptyMap()');
    writer.line('        return NitroAnyMapCodec.encode(_outMap)');
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
    // Use the INPUT param's value type for the input map (may differ from return type).
    final inputMapValueType = (() {
      if (func.params.isNotEmpty && func.params.first.type.isMap) {
        final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(func.params.first.type.name);
        return m?.group(1)?.trim() ?? mapValueType;
      }
      return mapValueType;
    })();
    final isInputEnum = spec.isEnumName(inputMapValueType);
    final isOutputEnum = spec.isEnumName(mapValueType);
    final isInputRecord = spec.recordTypes.any((r) => r.name == inputMapValueType);
    final isOutputRecord = spec.recordTypes.any((r) => r.name == mapValueType);
    final isInputVariant = spec.isVariantName(inputMapValueType);
    final isOutputVariant = spec.isVariantName(mapValueType);
    final inputKtValueType = switch (inputMapValueType) {
      'int' => 'Long',
      'double' => 'Double',
      'bool' => 'Boolean',
      'String' => 'String',
      _ when isInputEnum => inputMapValueType,
      _ when isInputRecord => inputMapValueType,
      _ when isInputVariant => inputMapValueType,
      _ => 'Any?',
    };
    final useTypedInput = inputKtValueType != 'Any?';

    writer.line('        val _mapBuf = java.nio.ByteBuffer.wrap($mapParam).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
    writer.line('        _mapBuf.position(4) // skip 4-byte payload length prefix');
    writer.line('        val _mapCount = _mapBuf.int');
    if (useTypedInput) {
      writer.line('        val _inputMap = mutableMapOf<String, $inputKtValueType>()');
    } else {
      writer.line('        val _inputMap = mutableMapOf<String, Any?>()');
    }
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
    } else if (isInputEnum) {
      // @HybridEnum: decode Int64 rawValue → enum via fromNative companion factory.
      writer.line('            _inputMap[k] = $inputMapValueType.fromNative(_mapBuf.long)');
    } else if (isInputRecord) {
      // @HybridRecord: tag 5 + 4B blob_len + record encode() bytes [4B payload_len][field bytes].
      writer.line('            val _bLen = _mapBuf.int; val _bBytes = ByteArray(_bLen); _mapBuf.get(_bBytes)');
      writer.line('            val _bBuf = java.nio.ByteBuffer.wrap(_bBytes).order(java.nio.ByteOrder.LITTLE_ENDIAN); _bBuf.getInt()');
      writer.line('            _inputMap[k] = $inputMapValueType.decodeFrom(_bBuf)');
    } else if (isInputVariant) {
      // @NitroVariant: tag 5 + 4B blob_len + variant encode() bytes [4B payload_len][1B tag][fields].
      writer.line('            val _bLen = _mapBuf.int; val _bBytes = ByteArray(_bLen); _mapBuf.get(_bBytes)');
      writer.line('            val _bBuf = java.nio.ByteBuffer.wrap(_bBytes).order(java.nio.ByteOrder.LITTLE_ENDIAN); _bBuf.getInt()');
      writer.line('            _inputMap[k] = $inputMapValueType.fromReader(RecordReader(_bBuf))');
    } else {
      writer.line('            val vLen = _mapBuf.int; val vBytes = ByteArray(vLen); _mapBuf.get(vBytes)');
      writer.line('            _inputMap[k] = vBytes.toString(Charsets.UTF_8)');
    }
    writer.line('        }');

    // For void-returning functions with only a map input param, call impl and return.
    final isVoidReturn = func.returnType.name == 'void' || func.returnType.name == 'Unit';
    if (isVoidReturn) {
      if (func.isAsync) {
        final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}(_inputMap)');
        writer.line('        _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
      } else {
        writer.line('        ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}(_inputMap)")}');
      }
      return;
    }

    if (func.isAsync) {
      final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}(_inputMap)');
      writer.line('        val _result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('        val _result = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}(_inputMap)")}');
    }

    final outKtValueType = switch (mapValueType) {
      'int' => 'Long',
      'double' => 'Double',
      'bool' => 'Boolean',
      'String' => 'String',
      _ when isOutputEnum => mapValueType,
      _ when isOutputRecord => mapValueType,
      _ when isOutputVariant => mapValueType,
      _ => 'Any?',
    };
    if (outKtValueType != 'Any?') {
      writer.line('        @Suppress("UNCHECKED_CAST")');
      writer.line('        val _outMap = _result as? Map<String, $outKtValueType> ?: emptyMap()');
    } else {
      writer.line('        @Suppress("UNCHECKED_CAST")');
      writer.line('        val _outMap = _result as? Map<String, Any?> ?: emptyMap()');
    }
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
      writer.line('            _writeInt64(v)');
    } else if (mapValueType == 'double' || mapValueType == 'Double') {
      writer.line('            _outBb.write(2) // tag: float64');
      writer.line('            _writeDouble(v)');
    } else if (mapValueType == 'bool' || mapValueType == 'Boolean') {
      writer.line('            _outBb.write(3) // tag: bool');
      writer.line('            _outBb.write(if (v) 1 else 0)');
    } else if (mapValueType == 'String') {
      writer.line('            _outBb.write(4) // tag: string');
      writer.line('            val vb = v.toByteArray(Charsets.UTF_8); _writeInt32(vb.size); _outBb.write(vb)');
    } else if (isOutputEnum) {
      // @HybridEnum: encode rawValue as tag 1 (int64). Mirrors Dart/Swift encoding.
      writer.line('            _outBb.write(1) // tag: int64 (enum rawValue)');
      writer.line('            _writeInt64((v as $mapValueType).nativeValue)');
    } else if (isOutputRecord) {
      // @HybridRecord: tag 5 + 4B blob_len + record encode() bytes [4B payload_len][field bytes].
      writer.line('            _outBb.write(5) // tag: binary record');
      writer.line('            val _rBytes = (v as $mapValueType).encode()');
      writer.line('            _writeInt32(_rBytes.size); _outBb.write(_rBytes)');
    } else if (isOutputVariant) {
      // @NitroVariant: tag 5 + 4B blob_len + variant encode() bytes [4B payload_len][1B tag][fields].
      writer.line('            _outBb.write(5) // tag: binary variant');
      writer.line('            val _rBytes = (v as $mapValueType).encode()');
      writer.line('            _writeInt32(_rBytes.size); _outBb.write(_rBytes)');
    } else {
      writer.line('            _outBb.write(4) // tag: string (generic fallback)');
      writer.line('            @Suppress("UNCHECKED_CAST")');
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
    KotlinTypeMapper mapper,
    String callParams,
  ) {
    final retBaseName = func.returnType.name.replaceFirst('?', '');
    final encodeExpr = _kotlinResultEncodeOk(retBaseName, mapper);
    writer.line('        return try {');
    if (func.isAsync) {
      final rb = KotlinTypeMapper.runBlockingCall(func, 'impl.${func.dartName}($callParams)');
      writer.line('            val _result = _asyncExecutor.submit(java.util.concurrent.Callable { $rb }).get()');
    } else {
      writer.line('            val _result = ${KotlinTypeMapper.syncImplCall(func, "impl.${func.dartName}($callParams)")}');
    }
    writer.line('            $encodeExpr');
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
    writer.line('        val _vw = RecordWriter()');
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
