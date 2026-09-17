import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'kotlin_type_mapper.dart';

/// Emits stream registration/release `_call` methods and the `emit_*` external
/// JNI declarations for a single [BridgeStream].
class KotlinStreamEmitter {
  static void emit(CodeWriter writer, BridgeStream stream, KotlinTypeMapper mapper) {
    // Every mode posts per item — Backpressure.batch is coalesced by the C bridge.
    // For nullable primitive types, Kotlin boxed types (Long?, Double?, Boolean?) map to
    // JNI jobject — the C bridge checks for nullptr to post kNull to the Dart port.
    // Variant items are encoded as ByteArray (same wire format as records).
    final isNullable = stream.itemType.isNullable || stream.itemType.name.endsWith('?');
    final base = bareTypeName(stream.itemType.name);
    final String itemKt;
    if (isNullable && stream.itemType.isAnyNativeObject) {
      // Nullable AnyNativeObject: boxed Long? so null can be passed to JNI.
      itemKt = 'Long?';
    } else if (isNullable && BridgeType.nitroPrimBases.contains(base)) {
      // Nullable prim (int?, double?, bool?, DateTime?, uint64?): boxed Kotlin type.
      itemKt = '${mapper.type(base)}?';
    } else if (isNullable && mapper.enumNames.contains(base)) {
      // Nullable enum → boxed jobject so null can be passed to JNI.
      itemKt = '${mapper.type(base)}?';
    } else if (isNullable && base == 'String') {
      // Nullable String → String? so null can be passed to JNI.
      itemKt = 'String?';
    } else if (mapper.variantNames.contains(base) || mapper.recordNames.contains(base)) {
      // Variant and @HybridRecord items: Kotlin calls .encode() before emitting.
      // Nullable record/variant → ByteArray? so null can pass through to C as nullptr.
      itemKt = isNullable ? 'ByteArray?' : 'ByteArray';
    } else {
      itemKt = mapper.type(stream.itemType.name, bridgeType: stream.itemType);
    }
    writer.line('    @JvmStatic external fun emit_${stream.dartName}(dartPort: Long, item: $itemKt): Boolean');
    writer.blankLine();

    writer.line('    @JvmStatic fun ${stream.registerSymbol}_call(instanceId: Long, dartPort: Long) {');
    writer.line('        val impl = _implementations[instanceId] ?: return');
    writer.line('        _streamJobs[Pair("${stream.dartName}", dartPort)] = CoroutineScope(Dispatchers.Default).launch(start = CoroutineStart.UNDISPATCHED) {');

    if (stream.isBufferDrop) {
      _emitBufferDropCollect(writer, stream, mapper);
    } else if (stream.isBlock) {
      _emitBlockCollect(writer, stream, mapper);
    } else {
      _emitDropLatestCollect(writer, stream, mapper);
    }

    writer.line('        }');
    writer.line('    }');
    writer.line('    @JvmStatic fun ${stream.releaseSymbol}_call(dartPort: Long) {');
    writer.line('        _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
    writer.line('    }');
  }

  /// Backpressure.bufferDrop: ring buffer of [batchMaxSize] items; oldest item is
  /// dropped when the buffer is full. Uses Kotlin Flow's BufferOverflow.DROP_OLDEST.
  static void _emitBufferDropCollect(CodeWriter writer, BridgeStream stream, KotlinTypeMapper mapper) {
    final bufferCap = stream.batchMaxSize;
    final base = bareTypeName(stream.itemType.name);
    final isVariant = mapper.variantNames.contains(base);
    final isRecord = mapper.recordNames.contains(base);
    final itemExpr = (isVariant || isRecord) ? 'item${stream.itemType.isNullable ? '?' : ''}.encode()' : 'item';
    writer.line('            impl.${stream.dartName}');
    writer.line('                .buffer(capacity = $bufferCap, onBufferOverflow = kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST)');
    writer.line('                .collect { item ->');
    writer.line('                    if (!emit_${stream.dartName}(dartPort, $itemExpr)) {');
    writer.line('                        _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
    writer.line('                        return@collect');
    writer.line('                    }');
    writer.line('                }');
  }

  /// Backpressure.block: bounded buffer of [batchMaxSize] items with SUSPEND overflow.
  /// When the buffer is full, the upstream producer coroutine is suspended until
  /// a slot is available — providing true backpressure without data loss.
  static void _emitBlockCollect(CodeWriter writer, BridgeStream stream, KotlinTypeMapper mapper) {
    final bufferCap = stream.batchMaxSize;
    final base = bareTypeName(stream.itemType.name);
    final isVariant = mapper.variantNames.contains(base);
    final isRecord = mapper.recordNames.contains(base);
    final itemExpr = (isVariant || isRecord) ? 'item${stream.itemType.isNullable ? '?' : ''}.encode()' : 'item';
    writer.line('            impl.${stream.dartName}');
    writer.line('                .buffer(capacity = $bufferCap)');
    writer.line('                .collect { item ->');
    writer.line('                    if (!emit_${stream.dartName}(dartPort, $itemExpr)) {');
    writer.line('                        _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
    writer.line('                        return@collect');
    writer.line('                    }');
    writer.line('                }');
  }

  static void _emitDropLatestCollect(CodeWriter writer, BridgeStream stream, KotlinTypeMapper mapper) {
    // Nullable primitives (Long?, Double?, Boolean?) auto-box in Kotlin and arrive
    // at the C JNI bridge as jobject — the C layer checks nullptr and posts kNull.
    // Variant and @HybridRecord items are encoded to ByteArray before emit.
    final base = bareTypeName(stream.itemType.name);
    final isVariant = mapper.variantNames.contains(base);
    final isRecord = mapper.recordNames.contains(base);
    final itemExpr = (isVariant || isRecord) ? 'item${stream.itemType.isNullable ? '?' : ''}.encode()' : 'item';
    writer.line('            impl.${stream.dartName}.collect { item -> ');
    writer.line('                if (!emit_${stream.dartName}(dartPort, $itemExpr)) {');
    writer.line('                    _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
    writer.line('                    return@collect');
    writer.line('                }');
    writer.line('            }');
  }
}
