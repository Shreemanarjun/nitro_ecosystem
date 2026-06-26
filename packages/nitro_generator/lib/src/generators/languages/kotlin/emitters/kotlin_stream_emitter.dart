import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'kotlin_type_mapper.dart';

/// Emits stream registration/release `_call` methods and the `emit_*` external
/// JNI declarations for a single [BridgeStream].
class KotlinStreamEmitter {
  static void emit(CodeWriter writer, BridgeStream stream, KotlinTypeMapper mapper) {
    if (stream.isBatch) {
      writer.line(
          '    @JvmStatic external fun emit_${stream.dartName}_batch(dartPort: Long, batch: LongArray): Boolean');
    } else {
      final itemKt = mapper.type(stream.itemType.name);
      writer.line(
          '    @JvmStatic external fun emit_${stream.dartName}(dartPort: Long, item: $itemKt): Boolean');
    }
    writer.blankLine();

    writer.line('    @JvmStatic fun ${stream.registerSymbol}_call(dartPort: Long) {');
    writer.line('        val impl = implementation ?: return');
    writer.line(
        '        _streamJobs[Pair("${stream.dartName}", dartPort)] = CoroutineScope(Dispatchers.Default).launch {');

    if (stream.isBatch) {
      _emitBatchCollect(writer, stream);
    } else {
      _emitDropLatestCollect(writer, stream);
    }

    writer.line('        }');
    writer.line('    }');
    writer.line('    @JvmStatic fun ${stream.releaseSymbol}_call(dartPort: Long) {');
    writer.line(
        '        _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
    writer.line('    }');
  }

  static void _emitBatchCollect(CodeWriter writer, BridgeStream stream) {
    final batchMax = stream.batchMaxSize;
    final itemBase = stream.itemType.name.replaceFirst('?', '');
    writer.line('            val _buf = ArrayList<Long>($batchMax)');
    writer.line('            fun _flush() {');
    writer.line('                if (_buf.isEmpty()) return');
    writer.line(
        '                val arr = LongArray(_buf.size + 1); arr[0] = _buf.size.toLong()');
    writer.line('                _buf.forEachIndexed { i, v -> arr[i + 1] = v }');
    writer.line('                _buf.clear()');
    writer.line('                emit_${stream.dartName}_batch(dartPort, arr)');
    writer.line('            }');
    // Periodic flush for hot sources (MutableSharedFlow etc.) that never complete.
    writer.line(
        '            val _flushJob = launch { while (true) { kotlinx.coroutines.delay(10); _flush() } }');
    writer.line('            impl.${stream.dartName}.collect { item ->');
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
  }

  static void _emitDropLatestCollect(CodeWriter writer, BridgeStream stream) {
    writer.line('            impl.${stream.dartName}.collect { item -> ');
    writer.line(
        '                if (!emit_${stream.dartName}(dartPort, item)) {');
    writer.line(
        '                    _streamJobs.remove(Pair("${stream.dartName}", dartPort))?.cancel()');
    writer.line('                    return@collect');
    writer.line('                }');
    writer.line('            }');
  }
}
