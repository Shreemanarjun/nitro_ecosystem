part of '../dart_ffi_generator.dart';

void _collectMapValueTypes(BridgeType t, Set<String> out) {
  if (!t.isMap) return;
  final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(t.name);
  final vt = m?.group(1)?.trim() ?? 'dynamic';
  out.add(vt);
}

// Type tags (must match Swift/Kotlin): 1=int64, 2=float64, 3=bool, 4=string, 5=record/variant blob
String _mapTypeSuffix(String vt) {
  // Convert type name to camelCase suffix: int→Int, double→Double, String→String, etc.
  return vt.isEmpty ? 'Dynamic' : vt[0].toUpperCase() + vt.substring(1);
}

void _emitMapBinaryHelpers(CodeWriter writer, String vt, BridgeSpec spec) {
  final suffix = _mapTypeSuffix(vt);
  final isEnum = spec.isEnumName(vt);
  final isRecord = spec.recordTypes.any((r) => r.name == vt);
  final isVariant = spec.isVariantName(vt);
  final isRecordOrVariant = isRecord || isVariant;
  // Encode helper: Map<String, VT> → length-prefixed binary Pointer<Uint8>
  // Use camelCase function names to satisfy Dart lint.
  writer.line('Pointer<Uint8> _nitroEncodeMapBinary$suffix(Map<String, $vt> m, Allocator alloc) {');
  writer.line('  final bytes = _nitroMapPayload(m, (h, bb, v) {');
  if (vt == 'int') {
    writer.line('    bb.addByte(1); h.setInt64(0, v as int, Endian.little); bb.add(h.buffer.asUint8List(0, 8));');
  } else if (vt == 'double') {
    writer.line('    bb.addByte(2); h.setFloat64(0, v as double, Endian.little); bb.add(h.buffer.asUint8List(0, 8));');
  } else if (vt == 'bool') {
    writer.line('    bb.addByte(3); bb.addByte((v as bool) ? 1 : 0);');
  } else if (vt == 'String') {
    writer.line('    bb.addByte(4); final vb = utf8.encode(v as String); h.setInt32(0, vb.length, Endian.little);');
    writer.line('    bb.add(h.buffer.asUint8List(0, 4)); bb.add(vb);');
  } else if (isEnum) {
    // @HybridEnum: encode rawValue as tag 1 (int64). Same on-wire format as Map<String,int>.
    writer.line('    bb.addByte(1); h.setInt64(0, (v as $vt).nativeValue, Endian.little); bb.add(h.buffer.asUint8List(0, 8));');
  } else if (isRecordOrVariant) {
    // @HybridRecord / @NitroVariant: tag 5 + record encode() bytes [4B payload_len][field bytes].
    writer.line('    bb.addByte(5);');
    writer.line('    final _rec = (v as $vt).toNative(alloc);');
    writer.line('    final _recLen = ByteData.sublistView(_rec.asTypedList(4)).getInt32(0, Endian.little) + 4;');
    writer.line('    h.setInt32(0, _recLen, Endian.little); bb.add(h.buffer.asUint8List(0, 4));');
    writer.line('    bb.add(_rec.asTypedList(_recLen));');
  } else {
    // dynamic fallback: encode as JSON string with tag 4
    writer.line('    bb.addByte(4); final vb = utf8.encode(jsonEncode(v)); h.setInt32(0, vb.length, Endian.little);');
    writer.line('    bb.add(h.buffer.asUint8List(0, 4)); bb.add(vb);');
  }
  writer.line('  });');
  writer.line('  final ptr = alloc<Uint8>(bytes.length);');
  writer.line('  ptr.asTypedList(bytes.length).setAll(0, bytes);');
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
  // For typed maps: skip tag byte (we know the type); for dynamic: dispatch on tag.
  if (vt == 'int') {
    writer.line('    pos += 1; // skip type tag (always 1=int64 for Map<String,int>)');
    writer.line('    final v = bd.getInt64(pos, Endian.little); pos += 8;');
  } else if (vt == 'double') {
    writer.line('    pos += 1; // skip type tag (always 2=float64 for Map<String,double>)');
    writer.line('    final v = bd.getFloat64(pos, Endian.little); pos += 8;');
  } else if (vt == 'bool') {
    writer.line('    pos += 1; // skip type tag (always 3=bool for Map<String,bool>)');
    writer.line('    final v = bd.getUint8(pos) != 0; pos += 1;');
  } else if (vt == 'String') {
    writer.line('    pos += 1; // skip type tag (always 4=string for Map<String,String>)');
    writer.line('    final vLen = bd.getInt32(pos, Endian.little); pos += 4;');
    writer.line('    final v = utf8.decode(bd.buffer.asUint8List(pos, vLen)); pos += vLen;');
  } else if (isEnum) {
    // @HybridEnum: decode tag 1 int64 rawValue → enum via generated .toEnumName() extension.
    writer.line('    pos += 1; // skip type tag (always 1=int64 for Map<String,$vt>)');
    writer.line('    final v = bd.getInt64(pos, Endian.little).to$vt(); pos += 8;');
  } else if (isRecord) {
    // @HybridRecord: tag 5 + 4B blob_len + record encode() bytes [4B payload_len][field bytes].
    writer.line('    pos += 1; // skip type tag (always 5=binary record for Map<String,$vt>)');
    writer.line('    final _bLen = bd.getInt32(pos, Endian.little); pos += 4;');
    writer.line('    final _bSlice = bd.buffer.asUint8List(pos, _bLen); pos += _bLen;');
    writer.line('    final _bPtr = malloc<Uint8>(_bLen);');
    writer.line('    _bPtr.asTypedList(_bLen).setAll(0, _bSlice);');
    writer.line('    final v = ${vt}RecordExt.fromNative(_bPtr);');
    writer.line('    malloc.free(_bPtr);');
  } else if (isVariant) {
    // @NitroVariant: tag 5 + 4B blob_len + variant encode() bytes [4B payload_len][1B tag][field bytes].
    writer.line('    pos += 1; // skip type tag (always 5=binary variant for Map<String,$vt>)');
    writer.line('    final _bLen = bd.getInt32(pos, Endian.little); pos += 4;');
    writer.line('    final _bSlice = bd.buffer.asUint8List(pos, _bLen); pos += _bLen;');
    writer.line('    final _bPtr = malloc<Uint8>(_bLen);');
    writer.line('    _bPtr.asTypedList(_bLen).setAll(0, _bSlice);');
    writer.line('    final v = ${vt}VariantExt.fromNative(_bPtr);');
    writer.line('    malloc.free(_bPtr);');
  } else {
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


