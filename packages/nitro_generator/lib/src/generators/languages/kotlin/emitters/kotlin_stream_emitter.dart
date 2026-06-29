import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'kotlin_type_mapper.dart';

/// Emits stream registration/release `_call` methods and the `emit_*` external
/// JNI declarations for a single [BridgeStream].
class KotlinStreamEmitter {
  static void emit(CodeWriter writer, BridgeStream stream, KotlinTypeMapper mapper) {
    if (stream.isBatch) {
      if (stream.itemType.name == 'String') {
        writer.line('    @JvmStatic external fun emit_${stream.dartName}_string_batch(dartPort: Long, batch: Array<String>): Boolean');
      } else {
        writer.line('    @JvmStatic external fun emit_${stream.dartName}_batch(dartPort: Long, batch: LongArray): Boolean');
      }
    } else {
      // For nullable primitive types, Kotlin boxed types (Long?, Double?, Boolean?) map to
      // JNI jobject — the C bridge checks for nullptr to post kNull to the Dart port.
      final isNullable = stream.itemType.isNullable;
      final base = stream.itemType.name.replaceFirst('?', '');
      final String itemKt;
      if (isNullable && (base == 'int' || base == 'double' || base == 'bool')) {
        itemKt = '${mapper.type(base)}?';
      } else {
        itemKt = mapper.type(stream.itemType.name);
      }
      writer.line('    @JvmStatic external fun emit_${stream.dartName}(dartPort: Long, item: $itemKt): Boolean');
    }
    writer.blankLine();

    writer.line('    @JvmStatic fun ${stream.registerSymbol}_call(instanceId: Long, dartPort: Long) {');
    writer.line('        val impl = _implementations[instanceId] ?: return');
    writer.line('        _streamJobs[Pair("${stream.dartName}", dartPort)] = CoroutineScope(Dispatchers.Default).launch(start = CoroutineStart.UNDISPATCHED) {');

    if (stream.isBatch && stream.itemType.name == 'String') {
      _emitStringBatchCollect(writer, stream);
    } else if (stream.isBatch) {
      _emitBatchCollect(writer, stream, mapper);
    } else {
      _emitDropLatestCollect(writer, stream);
    }

    writer.line('        }');
    writer.line('    }');
    writer.line('    @JvmStatic fun ${stream.releaseSymbol}_call(dartPort: Long) {');
    writer.line('        _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
    writer.line('    }');
  }

  static void _emitBatchCollect(CodeWriter writer, BridgeStream stream, KotlinTypeMapper mapper) {
    final batchMax = stream.batchMaxSize;
    final itemBase = stream.itemType.name.replaceFirst('?', '');
    // _buf is accessed from both the collect coroutine and the periodic _flushJob,
    // both of which run on Dispatchers.Default (multi-threaded). A Mutex serialises
    // all reads and writes to prevent ConcurrentModificationException.
    writer.line('            val _buf = ArrayList<Long>($batchMax)');
    writer.line('            val _lock = kotlinx.coroutines.sync.Mutex()');
    writer.line('            suspend fun _flush() {');
    writer.line('                _lock.withLock {');
    writer.line('                    if (_buf.isEmpty()) return@withLock');
    writer.line('                    val arr = LongArray(_buf.size + 1); arr[0] = _buf.size.toLong()');
    writer.line('                    _buf.forEachIndexed { i, v -> arr[i + 1] = v }');
    writer.line('                    _buf.clear()');
    writer.line('                    emit_${stream.dartName}_batch(dartPort, arr)');
    writer.line('                }');
    writer.line('            }');
    // Periodic flush for hot sources (MutableSharedFlow etc.) that never complete.
    writer.line('            val _flushJob = launch { while (true) { kotlinx.coroutines.delay(10); _flush() } }');
    writer.line('            impl.${stream.dartName}.collect { item ->');
    writer.line('                val _full = _lock.withLock {');
    if (itemBase == 'double') {
      writer.line('                    _buf.add(java.lang.Double.doubleToRawLongBits(item))');
    } else if (itemBase == 'bool') {
      writer.line('                    _buf.add(if (item) 1L else 0L)');
    } else if (mapper.enumNames.contains(itemBase)) {
      // Enum batch: pack enum rawValue (Long) into the Int64 batch buffer.
      writer.line('                    _buf.add(item.nativeValue)');
    } else {
      writer.line('                    _buf.add(item.toLong())');
    }
    writer.line('                    _buf.size >= $batchMax');
    writer.line('                }');
    writer.line('                if (_full) _flush()');
    writer.line('            }');
    writer.line('            _flushJob.cancel()');
    writer.line('            _flush()');
  }

  static void _emitStringBatchCollect(CodeWriter writer, BridgeStream stream) {
    final batchMax = stream.batchMaxSize;
    // String batches use Array<String> wire format (Dart_CObject_kArray of kStrings).
    // Same Mutex guard as the numeric batch to prevent ConcurrentModificationException.
    writer.line('            val _buf = ArrayList<String>($batchMax)');
    writer.line('            val _lock = kotlinx.coroutines.sync.Mutex()');
    writer.line('            suspend fun _flush() {');
    writer.line('                _lock.withLock {');
    writer.line('                    if (_buf.isEmpty()) return@withLock');
    writer.line('                    val arr = _buf.toTypedArray()');
    writer.line('                    _buf.clear()');
    writer.line('                    emit_${stream.dartName}_string_batch(dartPort, arr)');
    writer.line('                }');
    writer.line('            }');
    writer.line('            val _flushJob = launch { while (true) { kotlinx.coroutines.delay(10); _flush() } }');
    writer.line('            impl.${stream.dartName}.collect { item ->');
    writer.line('                val _full = _lock.withLock {');
    writer.line('                    _buf.add(item)');
    writer.line('                    _buf.size >= $batchMax');
    writer.line('                }');
    writer.line('                if (_full) _flush()');
    writer.line('            }');
    writer.line('            _flushJob.cancel()');
    writer.line('            _flush()');
  }

  static void _emitDropLatestCollect(CodeWriter writer, BridgeStream stream) {
    // Nullable primitives (Long?, Double?, Boolean?) auto-box in Kotlin and arrive
    // at the C JNI bridge as jobject — the C layer checks nullptr and posts kNull.
    // Non-nullable and enum/struct/record items work unchanged.
    writer.line('            impl.${stream.dartName}.collect { item -> ');
    writer.line('                if (!emit_${stream.dartName}(dartPort, item)) {');
    writer.line('                    _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
    writer.line('                    return@collect');
    writer.line('                }');
    writer.line('            }');
  }
}
