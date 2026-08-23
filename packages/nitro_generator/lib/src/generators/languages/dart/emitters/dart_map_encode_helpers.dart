part of '../dart_ffi_generator.dart';

void _collectMapValueTypes(BridgeType t, Set<String> out) {
  if (!t.isMap) return;
  final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(t.name);
  final vt = m?.group(1)?.trim() ?? 'dynamic';
  out.add(vt);
}

// ── Int-key map support (Gap #3) ─────────────────────────────────────────────

/// Recognised integer key types (all map to Dart [int]).
const _intKeyTypes = {
  'int',
  'int8',
  'int16',
  'int32',
  'int64',
  'uint8',
  'uint16',
  'uint32',
  'uint64',
};

/// Collects (keyType, valueType) pairs from [t] when [t] is a `Map<K, V>` with
/// an integer key. Adds nothing when the key is String or an unsupported type.
void _collectIntKeyMapTypes(
  BridgeType t,
  Set<({String keyType, String valueType})> out,
  BridgeSpec spec,
) {
  // Detect by name pattern — isMap is only set for Map<String, V>.
  if (!t.name.startsWith('Map<')) return;
  final m = RegExp(r'^Map<(\w+),\s*(.+)>$').firstMatch(t.name);
  if (m == null) return;
  final keyType = m.group(1)!.trim();
  final valueType = m.group(2)!.trim();
  // Accept integer key types and @HybridEnum key types.
  if (!_intKeyTypes.contains(keyType) && !spec.isEnumName(keyType)) return;
  out.add((keyType: keyType, valueType: valueType));
}

/// Returns the number of bytes used to encode a key of [keyType] on the wire.
int _intKeyByteSize(String keyType) {
  switch (keyType) {
    case 'int8':
    case 'uint8':
      return 1;
    case 'int16':
    case 'uint16':
      return 2;
    case 'int32':
    case 'uint32':
      return 4;
    default:
      return 8; // int, int64, uint64, and enums all use 8 bytes
  }
}

/// Capitalises the first letter of [s] for use as a camelCase function suffix.
String _intKeySuffix(String keyType) => keyType[0].toUpperCase() + keyType.substring(1);

/// Emits `_nitroEncodeIntKeyMapBinary{KS}{VS}` and
/// `_nitroDecodeIntKeyMapBinary{KS}{VS}` helper functions for a
/// `Map<keyType, valueType>` where keyType is an integer or enum type.
///
/// Wire format (replaces the String key's `[4B strlen][key bytes]` with):
///   `[N bytes key — little-endian, N = _intKeyByteSize(keyType)]`
void _emitIntKeyMapBinaryHelpers(
  CodeWriter writer,
  String keyType,
  String valueType,
  BridgeSpec spec,
) {
  final ks = _intKeySuffix(keyType);
  final vs = _mapTypeSuffix(valueType);
  final byteSize = _intKeyByteSize(keyType);
  final isEnum = spec.isEnumName(keyType); // key is @HybridEnum
  final isValueEnum = spec.isEnumName(valueType);
  final isValueRecord = spec.recordTypes.any((r) => r.name == valueType);
  final isValueVariant = spec.isVariantName(valueType);

  // ── Encode helper ──────────────────────────────────────────────────────────
  writer.line('Pointer<Uint8> _nitroEncodeIntKeyMapBinary$ks$vs(Map<${isEnum ? keyType : "int"}, $valueType> m, Allocator alloc) {');
  writer.line('  final bb = BytesBuilder();');
  writer.line('  final hdr = ByteData(8);');
  writer.line('  hdr.setInt32(0, m.length, Endian.little); bb.add(hdr.buffer.asUint8List(0, 4));');
  writer.line('  for (final e in m.entries) {');
  // Write key
  final keyExpr = isEnum ? 'e.key.nativeValue' : 'e.key';
  if (byteSize == 1) {
    writer.line('    bb.addByte($keyExpr & 0xFF);');
  } else if (byteSize == 2) {
    writer.line('    hdr.setInt16(0, $keyExpr, Endian.little); bb.add(hdr.buffer.asUint8List(0, 2));');
  } else if (byteSize == 4) {
    writer.line('    hdr.setInt32(0, $keyExpr, Endian.little); bb.add(hdr.buffer.asUint8List(0, 4));');
  } else {
    if (keyType == 'uint64') {
      writer.line('    hdr.setUint64(0, $keyExpr, Endian.little); bb.add(hdr.buffer.asUint8List(0, 8));');
    } else {
      writer.line('    hdr.setInt64(0, $keyExpr, Endian.little); bb.add(hdr.buffer.asUint8List(0, 8));');
    }
  }
  // Write value. UNLIKE the String-key map, int-key values carry NO type
  // tag — they are homogeneous, so the type is known from context. That is
  // why a nullable value type has nowhere to record null (E018).
  switch (valueType) {
    case 'int':
      writer.line('    hdr.setInt64(0, e.value, Endian.little); bb.add(hdr.buffer.asUint8List(0, 8));');
    case 'double':
      writer.line('    hdr.setFloat64(0, e.value, Endian.little); bb.add(hdr.buffer.asUint8List(0, 8));');
    case 'bool':
      writer.line('    bb.addByte(e.value ? 1 : 0);');
    case 'String':
      writer.line('    final vb = utf8.encode(e.value); hdr.setInt32(0, vb.length, Endian.little);');
      writer.line('    bb.add(hdr.buffer.asUint8List(0, 4)); bb.add(vb);');
    case _ when isValueEnum:
      writer.line('    hdr.setInt64(0, e.value.nativeValue, Endian.little); bb.add(hdr.buffer.asUint8List(0, 8));');
    case _ when isValueRecord || isValueVariant:
      writer.line('    final _rec = e.value.toNative(alloc);');
      writer.line('    final _recLen = ByteData.sublistView(_rec.asTypedList(4)).getInt32(0, Endian.little) + 4;');
      writer.line('    hdr.setInt32(0, _recLen, Endian.little); bb.add(hdr.buffer.asUint8List(0, 4));');
      writer.line('    bb.add(_rec.asTypedList(_recLen));');
    default:
      writer.line('    final vb = utf8.encode(jsonEncode(e.value)); hdr.setInt32(0, vb.length, Endian.little);');
      writer.line('    bb.add(hdr.buffer.asUint8List(0, 4)); bb.add(vb);');
  }
  writer.line('  }');
  writer.line('  final payload = bb.toBytes();');
  writer.line('  final lenBuf = ByteData(4)..setInt32(0, payload.length, Endian.little);');
  writer.line('  final allBytes = Uint8List.fromList([...lenBuf.buffer.asUint8List(0, 4), ...payload]);');
  writer.line('  final ptr = alloc<Uint8>(allBytes.length);');
  writer.line('  ptr.asTypedList(allBytes.length).setAll(0, allBytes);');
  writer.line('  return ptr;');
  writer.line('}');
  writer.blankLine();

  // ── Decode helper ──────────────────────────────────────────────────────────
  writer.line('Map<${isEnum ? keyType : "int"}, $valueType> _nitroDecodeIntKeyMapBinary$ks$vs(Pointer<Uint8> ptr) {');
  writer.line('  final payLen = ByteData.sublistView(ptr.asTypedList(4)).getInt32(0, Endian.little);');
  writer.line('  final bd = ByteData.sublistView(Uint8List.fromList((ptr + 4).asTypedList(payLen)));');
  writer.line('  int pos = 0;');
  writer.line('  final count = bd.getInt32(pos, Endian.little); pos += 4;');
  writer.line('  final result = <${isEnum ? keyType : "int"}, $valueType>{};');
  writer.line('  for (var i = 0; i < count; i++) {');
  // Read key
  if (byteSize == 1) {
    if (isEnum) {
      writer.line('    final key = bd.getUint8(pos).to$keyType(); pos += 1;');
    } else {
      writer.line('    final key = bd.getUint8(pos); pos += 1;');
    }
  } else if (byteSize == 2) {
    if (isEnum) {
      writer.line('    final key = bd.getInt16(pos, Endian.little).to$keyType(); pos += 2;');
    } else {
      writer.line('    final key = bd.getInt16(pos, Endian.little); pos += 2;');
    }
  } else if (byteSize == 4) {
    if (isEnum) {
      writer.line('    final key = bd.getInt32(pos, Endian.little).to$keyType(); pos += 4;');
    } else {
      writer.line('    final key = bd.getInt32(pos, Endian.little); pos += 4;');
    }
  } else {
    if (keyType == 'uint64') {
      if (isEnum) {
        writer.line('    final key = bd.getUint64(pos, Endian.little).to$keyType(); pos += 8;');
      } else {
        writer.line('    final key = bd.getUint64(pos, Endian.little); pos += 8;');
      }
    } else {
      if (isEnum) {
        writer.line('    final key = bd.getInt64(pos, Endian.little).to$keyType(); pos += 8;');
      } else {
        writer.line('    final key = bd.getInt64(pos, Endian.little); pos += 8;');
      }
    }
  }
  // Read value
  switch (valueType) {
    case 'int':
      writer.line('    final v = bd.getInt64(pos, Endian.little); pos += 8;');
    case 'double':
      writer.line('    final v = bd.getFloat64(pos, Endian.little); pos += 8;');
    case 'bool':
      writer.line('    final v = bd.getUint8(pos) != 0; pos += 1;');
    case 'String':
      writer.line('    final vLen = bd.getInt32(pos, Endian.little); pos += 4;');
      writer.line('    final v = utf8.decode(bd.buffer.asUint8List(pos, vLen)); pos += vLen;');
    case _ when isValueEnum:
      writer.line('    final v = bd.getInt64(pos, Endian.little).to$valueType(); pos += 8;');
    case _ when isValueRecord:
      writer.line('    final _bLen = bd.getInt32(pos, Endian.little); pos += 4;');
      writer.line('    final _bSlice = bd.buffer.asUint8List(pos, _bLen); pos += _bLen;');
      writer.line('    final _bPtr = malloc<Uint8>(_bLen);');
      writer.line('    _bPtr.asTypedList(_bLen).setAll(0, _bSlice);');
      writer.line('    final v = ${_recordDecodeExtName(spec, valueType)}.fromNative(_bPtr);');
      writer.line('    malloc.free(_bPtr);');
    case _ when isValueVariant:
      writer.line('    final _bLen = bd.getInt32(pos, Endian.little); pos += 4;');
      writer.line('    final _bSlice = bd.buffer.asUint8List(pos, _bLen); pos += _bLen;');
      writer.line('    final _bPtr = malloc<Uint8>(_bLen);');
      writer.line('    _bPtr.asTypedList(_bLen).setAll(0, _bSlice);');
      writer.line('    final v = ${_variantDecodeExtName(spec, valueType)}.fromNative(_bPtr);');
      writer.line('    malloc.free(_bPtr);');
    default:
      writer.line('    final vLen = bd.getInt32(pos, Endian.little); pos += 4;');
      writer.line('    final vs = utf8.decode(bd.buffer.asUint8List(pos, vLen)); pos += vLen;');
      writer.line('    final v = jsonDecode(vs);');
  }
  writer.line('    result[key] = v;');
  writer.line('  }');
  writer.line('  return result;');
  writer.line('}');
  writer.blankLine();
}

// Type tags (must match Kotlin/Swift/C++/web): 0=null, 1=int64, 2=float64,
// 3=bool, 4=string, 5=record/variant blob
String _mapTypeSuffix(String vt) {
  // int→Int, double→Double, int?→IntNullable ('?' is not an identifier char).
  final nullable = vt.endsWith('?');
  final base = nullable ? vt.substring(0, vt.length - 1) : vt;
  if (base.isEmpty) return 'Dynamic';
  return base[0].toUpperCase() + base.substring(1) + (nullable ? 'Nullable' : '');
}

void _emitMapBinaryHelpers(CodeWriter writer, String vt, BridgeSpec spec) {
  final suffix = _mapTypeSuffix(vt);
  // Tag 0 = null. Every value already carries a type tag, so a nullable value
  // costs one tag byte and no layout change; non-nullable maps are untouched.
  final nullable = vt.endsWith('?');
  final base = nullable ? vt.substring(0, vt.length - 1) : vt;
  final isEnum = spec.isEnumName(base);
  final isRecord = spec.recordTypes.any((r) => r.name == base);
  final isVariant = spec.isVariantName(base);
  final isRecordOrVariant = isRecord || isVariant;
  // Encode helper: Map<String, VT> → length-prefixed binary Pointer<Uint8>
  // Use camelCase function names to satisfy Dart lint.
  writer.line('Pointer<Uint8> _nitroEncodeMapBinary$suffix(Map<String, $vt> m, Allocator alloc) {');
  writer.line('  final bytes = _nitroMapPayload(m, (h, bb, v) {');
  if (nullable) {
    writer.line('    if (v == null) { bb.addByte(${MapValueWire.nul.tag}); return; }');
  }
  switch (base) {
    case 'int':
      writer.line('    bb.addByte(${MapValueWire.int64.tag}); h.setInt64(0, v as int, Endian.little); bb.add(h.buffer.asUint8List(0, 8));');
    case 'double':
      writer.line('    bb.addByte(${MapValueWire.float64.tag}); h.setFloat64(0, v as double, Endian.little); bb.add(h.buffer.asUint8List(0, 8));');
    case 'bool':
      writer.line('    bb.addByte(${MapValueWire.boolean.tag}); bb.addByte((v as bool) ? 1 : 0);');
    case 'String':
      writer.line('    bb.addByte(${MapValueWire.string.tag}); final vb = utf8.encode(v as String); h.setInt32(0, vb.length, Endian.little);');
      writer.line('    bb.add(h.buffer.asUint8List(0, 4)); bb.add(vb);');
    case _ when isEnum:
      // @HybridEnum: encode rawValue as tag 1 (int64). Same on-wire format as Map<String,int>.
      writer.line('    bb.addByte(${MapValueWire.int64.tag}); h.setInt64(0, (v as \$base).nativeValue, Endian.little); bb.add(h.buffer.asUint8List(0, 8));');
    case _ when isRecordOrVariant:
      // @HybridRecord / @NitroVariant: tag 5 + record encode() bytes [4B payload_len][field bytes].
      writer.line('    bb.addByte(${MapValueWire.blob.tag});');
      writer.line('    final _rec = (v as $base).toNative(alloc);');
      writer.line('    final _recLen = ByteData.sublistView(_rec.asTypedList(4)).getInt32(0, Endian.little) + 4;');
      writer.line('    h.setInt32(0, _recLen, Endian.little); bb.add(h.buffer.asUint8List(0, 4));');
      writer.line('    bb.add(_rec.asTypedList(_recLen));');
    default:
      // dynamic fallback: encode as JSON string with tag 4
      writer.line('    bb.addByte(${MapValueWire.string.tag}); final vb = utf8.encode(jsonEncode(v)); h.setInt32(0, vb.length, Endian.little);');
      writer.line('    bb.add(h.buffer.asUint8List(0, 4)); bb.add(vb);');
  }
  writer.line('  });');
  // Emit [4B payload_len][payload] straight into native memory: length prefix
  // via a ByteData view, payload copied once with setRange.
  writer.line('  final total = 4 + bytes.length;');
  writer.line('  final ptr = alloc<Uint8>(total);');
  writer.line('  final out = ptr.asTypedList(total);');
  writer.line('  ByteData.sublistView(out, 0, 4).setInt32(0, bytes.length, Endian.little);');
  writer.line('  out.setRange(4, total, bytes);');
  writer.line('  return ptr;');
  writer.line('}');
  writer.blankLine();
  // Decode helper: Pointer<Uint8> → Map<String, VT>
  writer.line('Map<String, $vt> _nitroDecodeMapBinary$suffix(Pointer<Uint8> ptr) {');
  // Copy to Dart heap first — native-backed ByteData has bd.offsetInBytes = raw pointer address,
  // causing bd.buffer.asUint8List(offset + pos, kLen) to compute a huge offset → OOM crash.
  writer.line('  final payLen = ByteData.sublistView(ptr.asTypedList(4)).getInt32(0, Endian.little);');
  writer.line('  final bd = ByteData.sublistView(Uint8List.fromList((ptr + 4).asTypedList(payLen)));');
  writer.line('  int pos = 0;');
  writer.line('  final count = bd.getInt32(pos, Endian.little); pos += 4;');
  writer.line('  final result = <String, $vt>{};');
  writer.line('  for (var i = 0; i < count; i++) {');
  writer.line('    final kLen = bd.getInt32(pos, Endian.little); pos += 4;');
  // Use offset 0 (Uint8List.fromList gives offsetInBytes=0, so bd.buffer.asUint8List(pos) is correct)
  writer.line('    final key = utf8.decode(bd.buffer.asUint8List(pos, kLen)); pos += kLen;');
  // For typed maps: skip tag byte (we know the type); for dynamic: dispatch on
  // tag. A nullable value type reads the tag instead — 0 means null.
  if (nullable) {
    writer.line('    final _tag = bd.getUint8(pos); pos += 1;');
    writer.line('    if (_tag == ${MapValueWire.nul.tag}) { result[key] = null; continue; }');
  }
  // A statically-typed value already knows its tag, so the non-nullable path
  // skips the byte. The nullable path consumed it above to check for null.
  void skipTag(String always) {
    if (!nullable) writer.line('    pos += 1; // skip type tag (always $always)');
  }

  switch (base) {
    case 'int':
      skipTag('1=int64 for Map<String,int>');
      writer.line('    final v = bd.getInt64(pos, Endian.little); pos += 8;');
    case 'double':
      skipTag('2=float64 for Map<String,double>');
      writer.line('    final v = bd.getFloat64(pos, Endian.little); pos += 8;');
    case 'bool':
      skipTag('3=bool for Map<String,bool>');
      writer.line('    final v = bd.getUint8(pos) != 0; pos += 1;');
    case 'String':
      skipTag('4=string for Map<String,String>');
      writer.line('    final vLen = bd.getInt32(pos, Endian.little); pos += 4;');
      writer.line('    final v = utf8.decode(bd.buffer.asUint8List(pos, vLen)); pos += vLen;');
    case _ when isEnum:
      // @HybridEnum: decode tag 1 int64 rawValue → enum via generated .toEnumName() extension.
      skipTag('1=int64 for Map<String,$vt>');
      writer.line('    final v = bd.getInt64(pos, Endian.little).to$base(); pos += 8;');
    // @HybridRecord / @NitroVariant: tag 5 + 4B blob_len + encode() bytes.
    // Both read an identical blob; only the decode entry point differs.
    case _ when isRecord || isVariant:
      skipTag('5=binary ${isRecord ? 'record' : 'variant'} for Map<String,$vt>');
      writer.line('    final _bLen = bd.getInt32(pos, Endian.little); pos += 4;');
      writer.line('    final _bSlice = bd.buffer.asUint8List(pos, _bLen); pos += _bLen;');
      writer.line('    final _bPtr = malloc<Uint8>(_bLen);');
      writer.line('    _bPtr.asTypedList(_bLen).setAll(0, _bSlice);');
      final decodeExt = isRecord ? _recordDecodeExtName(spec, base) : _variantDecodeExtName(spec, base);
      writer.line('    final v = $decodeExt.fromNative(_bPtr);');
      writer.line('    malloc.free(_bPtr);');
    default:
      // dynamic: dispatch on tag to decode the right type
      writer.line('    final tag = bd.getUint8(pos); pos += 1;');
      writer.line('    final Object? v;');
      writer.line('    if (tag == 1) { v = bd.getInt64(pos, Endian.little); pos += 8; }');
      writer.line('    else if (tag == 2) { v = bd.getFloat64(pos, Endian.little); pos += 8; }');
      writer.line('    else if (tag == 3) { v = bd.getUint8(pos) != 0; pos += 1; }');
      writer.line('    else { final vLen = bd.getInt32(pos, Endian.little); pos += 4;');
      writer.line('      final vs = utf8.decode(bd.buffer.asUint8List(pos, vLen)); pos += vLen;');
      writer.line('      v = jsonDecode(vs); }');
  }
  // No cast needed — v's type is already inferred correctly from the decode expression.
  writer.line('    result[key] = v;');
  writer.line('  }');
  writer.line('  return result;');
  writer.line('}');
  writer.blankLine();
}
