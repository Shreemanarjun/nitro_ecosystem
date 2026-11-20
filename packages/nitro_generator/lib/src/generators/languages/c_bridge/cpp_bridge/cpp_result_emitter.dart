part of '../cpp_bridge_generator.dart';

// What a C++ export returns when the value is not a plain scalar: the
// @NitroResult blob for each ResultCarrier, and the copy of a typed-data
// vector. Shared by both C++ paths.

/// The two helpers every `@NitroResult` method of a C++ implementation
/// returns through, on the desktop dispatch path and in an all-C++ bridge.
void _emitCppResultHelpers(CodeWriter writer) {
  // @NitroResult wire blob: [1B tag (0=ok, 1=err)][4B len][RecordWriter payload].
  // Dart reads res[0] then RecordReader.fromNative(res + 1), and frees res.
  writer.line('static uint8_t* _nitro_desktop_result_blob(uint8_t _tag, const NitroRecordWriter& _w) {');
  writer.line('    NitroCppBuffer _p = _w.toBuffer();');
  writer.line('    int32_t _len = (int32_t)_p.size;');
  writer.line('    uint8_t* _out = (uint8_t*)malloc((size_t)(1 + 4 + _len));');
  writer.line('    if (!_out) { return nullptr; }');
  writer.line('    _out[0] = _tag;');
  writer.line('    memcpy(_out + 1, &_len, 4);');
  writer.line('    if (_len > 0) { memcpy(_out + 5, _p.data, (size_t)_len); }');
  writer.line('    return _out;');
  writer.line('}');
  writer.line('static uint8_t* _nitro_desktop_result_err(const char* _msg) {');
  writer.line('    NitroRecordWriter _w;');
  writer.line('    _w.writeString(_msg ? std::string(_msg) : std::string());');
  writer.line('    return _nitro_desktop_result_blob(1, _w);');
  writer.line('}');
  writer.blankLine();
}

/// A `@NitroResult` method's call and ok return, after its arguments are
/// unpacked. The catch that follows is [_emitCppResultCatch]. The impl
/// signals the error case by throwing.
void _emitCppResultOk(CodeWriter writer, BridgeSpec spec, BridgeFunction func, String callArgStr) {
  final call = '_impl->${func.dartName}($callArgStr)';
  // A block that is already [4B len][payload] goes out behind the tag as is.
  void tagBlock() {
    writer.line('        uint8_t* _out = (uint8_t*)malloc(_res.size + 1);');
    writer.line('        if (!_out) { free((void*)_res.data); return nullptr; }');
    writer.line('        _out[0] = 0;');
    writer.line('        if (_res.size > 0 && _res.data) { memcpy(_out + 1, _res.data, _res.size); }');
    writer.line('        free((void*)_res.data);');
    writer.line('        return _out;');
  }

  // A single value in a record block.
  void scalar(String cppType, String write, [String Function(String) convert = _same]) {
    writer.line('        $cppType _val = ${convert(call)};');
    writer.line('        NitroRecordWriter _w;');
    writer.line('        _w.$write(_val);');
    writer.line('        return _nitro_desktop_result_blob(0, _w);');
  }

  switch (spec.resultCarrier(func)) {
    case ScalarCarrier(:final kind):
      switch (kind) {
        case ScalarKind.float64:
          scalar('double', 'writeDouble');
        case ScalarKind.int64:
          scalar('int64_t', 'writeInt');
        case ScalarKind.boolean:
          scalar('bool', 'writeBool');
        case ScalarKind.enumValue:
          scalar('int64_t', 'writeInt', (c) => 'static_cast<int64_t>($c)');
        case ScalarKind.string:
          scalar('std::string', 'writeString');
      }
    // A record or variant impl returns a NitroCppBuffer whose .data is
    // already a self-describing malloc'd [4B len][payload] block (see
    // toNativeBuffer()).
    case RecordCarrier():
      writer.line('        NitroCppBuffer _res = $call;');
      tagBlock();
    // A map, an any-map, a list of variants or a nullable variant is handed
    // over the same way; a buffer with no data is null, sent as tag 2.
    case BlockCarrier(:final kind, :final isNullable):
      switch (kind) {
        // An any-map impl returns the block's address; its size is the prefix.
        case BlockKind.anyMap:
          writer.line('        const uint8_t* _blk = static_cast<const uint8_t*>($call);');
          writer.line('        int32_t _blkLen = 0;');
          writer.line('        if (_blk) { memcpy(&_blkLen, _blk, 4); }');
          writer.line('        NitroCppBuffer _res = { _blk, _blk ? (size_t)_blkLen + 4 : 0 };');
        case BlockKind.map || BlockKind.variantList || BlockKind.variant:
          writer.line('        NitroCppBuffer _res = $call;');
      }
      writer.line(
        isNullable
            ? '        if (!_res.data) { NitroRecordWriter _w; return _nitro_desktop_result_blob(2, _w); }'
            : '        if (!_res.data) { return _nitro_desktop_result_err("${func.dartName} returned no value"); }',
      );
      tagBlock();
    // A nullable value, a list, typed data or a struct: the impl returns the
    // value itself and it is encoded as a one-field record
    // (BridgeSpec.resultWrapper), which is how Dart reads it back.
    case WrappedCarrier(:final wrapper):
      writer.line('        ${wrapper.name} _ok;');
      writer.line('        _ok.value = $call;');
      writer.line('        NitroCppBuffer _res = _ok.toNativeBuffer();');
      tagBlock();
    // Rejected by the validator (E015). What was always emitted for an
    // unknown type: right for an impl that returns std::string, a compile
    // error for anything else.
    case NoCarrier():
      scalar('std::string', 'writeString');
  }
}

String _same(String s) => s;

/// A typed-data return without `@zeroCopy`: the impl hands back a vector
/// (an optional one when nullable) and the bridge copies it into the
/// `[8B byteLength][bytes]` block Dart reads. A null value is a null pointer.
void _emitCppTypedDataCopy(CodeWriter writer, BridgeFunction func, String callArgStr) {
  final nullable = func.returnType.isNullable || func.returnType.name.endsWith('?');
  final v = nullable ? '(*_res)' : '_res';
  writer.line('        auto _res = _impl->${func.dartName}($callArgStr);');
  if (nullable) writer.line('        if (!_res) return nullptr;');
  writer.line('        const size_t _n = $v.size() * sizeof($v[0]);');
  writer.line('        uint8_t* _blk = (uint8_t*)malloc(sizeof(int64_t) + _n);');
  writer.line('        if (_blk == nullptr) throw std::bad_alloc();');
  writer.line('        *(int64_t*)_blk = (int64_t)_n;');
  writer.line('        if (_n != 0) memcpy(_blk + sizeof(int64_t), $v.data(), _n);');
  writer.line('        return _blk;');
}

void _emitCppResultCatch(CodeWriter writer) {
  // @NitroResult: the thrown message becomes the NitroErr payload —
  // Dart reads res[0] unconditionally, so never surface via NitroError.
  writer.line('    } catch (const std::exception& e) {');
  writer.line('        return _nitro_desktop_result_err(e.what());');
  writer.line('    } catch (...) {');
  writer.line('        return _nitro_desktop_result_err("Unknown C++ exception");');
  writer.line('    }');
}
