part of '../dart_ffi_generator.dart';

// ── Library-private FFI helpers ────────────────────────────────────────────
// All functions below were originally static members of DartFfiGenerator.
// They are library-private (`_` prefix) and accessible from all `part` files.

String _paramList(List<BridgeParam> params) {
  final positional = params.where((p) => !p.isNamed).map((p) => '${p.type.name} ${p.name}').join(', ');
  final named = params.where((p) => p.isNamed).toList();
  if (named.isEmpty) return positional;
  final namedStr = named
      .map((p) {
        if (p.defaultLiteral != null) return '${p.type.name} ${p.name} = ${p.defaultLiteral}';
        return '${p.type.name} ${p.name}';
      })
      .join(', ');
  final sep = positional.isEmpty ? '' : ', ';
  return '$positional$sep{$namedStr}';
}

String _cap(String name) => name[0].toUpperCase() + name.substring(1);

String _toNativeType(BridgeFunction func, BridgeSpec spec) {
  // NativeAsync: C function returns void and takes an extra Int64 dart_port.
  final ret = func.isNativeAsync ? 'Void' : _typeToFFI(func.returnType, spec);
  final effectiveRet = func.returnType.isTypedData ? 'Pointer<Uint8>' : ret;
  final params = [
    ...func.params.expand((p) {
      if (p.type.isTypedData) return [_typeToFFI(p.type, spec), 'Int64'];
      return [_typeToFFI(p.type, spec)];
    }),
    if (func.isNativeAsync) 'Int64', // dart_port
    // S8: sync functions receive a NitroError* out-param instead of using
    // the two-call get_error()/clear_error() pattern.
    if (!func.isAsync && !func.isNativeAsync) 'Pointer<NitroErrorFfi>',
  ].join(', ');
  return '$effectiveRet Function($params)';
}

String _toDartType(BridgeFunction func, BridgeSpec spec) {
  // NativeAsync: Dart callable returns void and takes an extra int dart_port.
  final ret = func.isNativeAsync ? 'void' : _typeToDartFFI(func.returnType, spec);
  final effectiveRet = func.returnType.isTypedData ? 'Pointer<Uint8>' : ret;
  final params = [
    ...func.params.expand((p) {
      if (p.type.isTypedData) return [_typeToDartFFI(p.type, spec), 'int'];
      return [_typeToDartFFI(p.type, spec)];
    }),
    if (func.isNativeAsync) 'int', // dart_port
    // S8: sync functions receive a Pointer<NitroErrorFfi> out-param.
    if (!func.isAsync && !func.isNativeAsync) 'Pointer<NitroErrorFfi>',
  ].join(', ');
  return '$effectiveRet Function($params)';
}

String _typeToFFI(BridgeType bt, BridgeSpec spec) {
  if (bt.isFunction) {
    return 'Pointer<NativeFunction<${_callbackNativeSignature(bt, spec)}>>';
  }
  if (bt.isRecord) {
    // Maps use binary encoding → same Pointer<Uint8> wire as @HybridRecord.
    return 'Pointer<Uint8>';
  }
  if (bt.isPointer) {
    return 'Pointer<${bt.pointerInnerType}>';
  }
  if (bt.isNativeHandle) return 'Pointer<Void>';
  final name = bt.name.replaceFirst('?', '');
  // Nullable primitives: NitroNullable binary encoding → Pointer<Uint8>
  if (bt.name == 'int?' || bt.name == 'double?' || bt.name == 'bool?') return 'Pointer<Uint8>';
  switch (name) {
    case 'int':
      return 'Int64';
    case 'double':
      return 'Double';
    case 'bool':
      return 'Int8';
    case 'String':
      return 'Pointer<Utf8>';
    case 'Uint8List':
      return 'Pointer<Uint8>';
    case 'Int8List':
      return 'Pointer<Int8>';
    case 'Int16List':
      return 'Pointer<Int16>';
    case 'Int32List':
      return 'Pointer<Int32>';
    case 'Uint16List':
      return 'Pointer<Uint16>';
    case 'Uint32List':
      return 'Pointer<Uint32>';
    case 'Float32List':
      return 'Pointer<Float>';
    case 'Float64List':
      return 'Pointer<Double>';
    case 'Int64List':
      return 'Pointer<Int64>';
    case 'Uint64List':
      return 'Pointer<Uint64>';
    case 'void':
      return 'Void';
  }
  if (spec.enums.any((en) => en.name == name)) return 'Int64';
  return 'Pointer<Void>';
}

String _typeToDartFFI(BridgeType bt, BridgeSpec spec) {
  if (bt.isFunction) {
    return 'Pointer<NativeFunction<${_callbackNativeSignature(bt, spec)}>>';
  }
  if (bt.isRecord) {
    // Maps use binary encoding → same Pointer<Uint8> wire as @HybridRecord.
    return 'Pointer<Uint8>';
  }
  if (bt.isPointer) {
    return 'Pointer<${bt.pointerInnerType}>';
  }
  if (bt.isNativeHandle) return 'Pointer<Void>';
  final name = bt.name.replaceFirst('?', '');
  // Nullable primitives: NitroNullable binary encoding → Pointer<Uint8>
  if (bt.name == 'int?' || bt.name == 'double?' || bt.name == 'bool?') return 'Pointer<Uint8>';
  switch (name) {
    case 'int':
      return 'int';
    case 'double':
      return 'double';
    case 'bool':
      return 'int';
    case 'String':
      return 'Pointer<Utf8>';
    case 'Uint8List':
      return 'Pointer<Uint8>';
    case 'Int8List':
      return 'Pointer<Int8>';
    case 'Int16List':
      return 'Pointer<Int16>';
    case 'Int32List':
      return 'Pointer<Int32>';
    case 'Uint16List':
      return 'Pointer<Uint16>';
    case 'Uint32List':
      return 'Pointer<Uint32>';
    case 'Float32List':
      return 'Pointer<Float>';
    case 'Float64List':
      return 'Pointer<Double>';
    case 'Int64List':
      return 'Pointer<Int64>';
    case 'Uint64List':
      return 'Pointer<Uint64>';
    case 'void':
      return 'void';
  }
  if (spec.enums.any((en) => en.name == name)) return 'int';
  return 'Pointer<Void>';
}

/// Returns true when any function or property uses `Map<String, double>`.
void _collectMapValueTypes(BridgeType t, Set<String> out) {
  if (!t.isMap) return;
  final m = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(t.name);
  final vt = m?.group(1)?.trim() ?? 'dynamic';
  out.add(vt);
}

// Type tags (must match Swift/Kotlin): 1=int64, 2=float64, 3=bool, 4=string, 9=bytes
String _mapTypeSuffix(String vt) {
  // Convert type name to camelCase suffix: int→Int, double→Double, String→String, etc.
  return vt.isEmpty ? 'Dynamic' : vt[0].toUpperCase() + vt.substring(1);
}

void _emitMapBinaryHelpers(CodeWriter writer, String vt, BridgeSpec spec) {
  final suffix = _mapTypeSuffix(vt);
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
  } else {
    // dynamic/record: encode as JSON string with tag 4
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

// Keep for backward compat — no longer used (binary helpers replace JSON helpers)
bool _hasDoubleMapType(BridgeSpec spec) => false;

String _decodeRecordExpr(BridgeType type, String ptrVar) {
  if (type.isMap) {
    // Binary map decoding — resolves NaN/Infinity, int64 precision, perf issues.
    // ptrVar is Pointer<Uint8> (4-byte length prefix + binary payload).
    final mapMatch = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(type.name);
    final valueType = mapMatch?.group(1)?.trim() ?? 'dynamic';
    return '_nitroDecodeMapBinary${_mapTypeSuffix(valueType)}($ptrVar)';
  }
  final item = type.recordListItemType;
  if (item != null) {
    if (type.recordListItemIsPrimitive) {
      // Primitive lists are small scalars — eager decode is fast enough.
      final readCall = _primitiveReaderCall(item);
      return 'RecordReader.decodePrimitiveList($ptrVar, (r) => r.$readCall())';
    }
    // Object lists: decode lazily — items are only deserialized when accessed.
    // Requires the native buffer to have been written by encodeIndexedList.
    return 'LazyRecordList.decode($ptrVar, (r) => ${item}RecordExt.fromReader(r))';
  }
  // Strip nullable '?' suffix — the extension/class is always named after the base type.
  final rt = type.name.replaceFirst('?', '');
  // Built-in library types define fromNative on the class itself (package:nitro).
  // Call directly instead of via the generated *RecordExt extension.
  if (_nitroLibraryRecordTypes.contains(rt)) return '$rt.fromNative($ptrVar)';
  return '${rt}RecordExt.fromNative($ptrVar)';
}

void _emitTypedDataDecodeReturn(
  CodeWriter writer,
  BridgeType type,
  String ptrVar,
  String indent, {
  bool zeroCopy = false,
}) {
  final rt = type.name.replaceFirst('?', '');
  final ffiElem = _typedDataFfiElement(rt);
  final lengthExpr = _typedDataElementSize(rt) == 1 ? 'byteLength' : 'byteLength ~/ ${_typedDataElementSize(rt)}';
  writer.line('${indent}if ($ptrVar == nullptr) {');
  writer.line("$indent  throw StateError('Native $rt return was null');");
  writer.line('$indent}');
  if (zeroCopy) {
    writer.line('$indent final byteLength = $ptrVar.cast<Int64>().value;');
    writer.line('$indent final dataAddress = Pointer<Int64>.fromAddress($ptrVar.address + 8).value;');
    writer.line('$indent final payloadPtr = Pointer<$ffiElem>.fromAddress(dataAddress);');
    writer.line('$indent return payloadPtr.asTypedList($lengthExpr, finalizer: _typedDataReturnFinalizer, token: $ptrVar.cast<Void>());');
    return;
  }
  writer.line('${indent}try {');
  writer.line('$indent  final byteLength = $ptrVar.cast<Int64>().value;');
  writer.line('$indent  final payloadPtr = Pointer<$ffiElem>.fromAddress($ptrVar.address + 8);');
  writer.line('$indent  return $rt.fromList(payloadPtr.asTypedList($lengthExpr));');
  writer.line('$indent} finally {');
  writer.line('$indent  malloc.free($ptrVar);');
  writer.line('$indent}');
}

String _typedDataFfiElement(String dartType) {
  switch (dartType) {
    case 'Uint8List':
      return 'Uint8';
    case 'Int8List':
      return 'Int8';
    case 'Int16List':
      return 'Int16';
    case 'Int32List':
      return 'Int32';
    case 'Uint16List':
      return 'Uint16';
    case 'Uint32List':
      return 'Uint32';
    case 'Float32List':
      return 'Float';
    case 'Float64List':
      return 'Double';
    case 'Int64List':
      return 'Int64';
    case 'Uint64List':
      return 'Uint64';
    default:
      throw StateError('Unknown typed-data return type "$dartType".');
  }
}

int _typedDataElementSize(String dartType) {
  switch (dartType) {
    case 'Uint8List':
    case 'Int8List':
      return 1;
    case 'Int16List':
    case 'Uint16List':
      return 2;
    case 'Int32List':
    case 'Uint32List':
    case 'Float32List':
      return 4;
    case 'Float64List':
    case 'Int64List':
    case 'Uint64List':
      return 8;
    default:
      throw StateError('Unknown typed-data return type "$dartType".');
  }
}

String _primitiveReaderCall(String item) {
  switch (item) {
    case 'int':
      return 'readInt';
    case 'double':
      return 'readDouble';
    case 'bool':
      return 'readBool';
    default:
      return 'readString';
  }
}

String _primitiveWriterCall(String item) {
  switch (item) {
    case 'int':
      return 'writeInt';
    case 'double':
      return 'writeDouble';
    case 'bool':
      return 'writeBool';
    default:
      return 'writeString';
  }
}

String _encodeRecordParam(BridgeType type, String varName, String allocator) {
  if (type.isMap) {
    // Maps use binary encoding — resolves NaN/Infinity, int64 precision, and perf issues.
    final mapMatch = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(type.name);
    final valueType = mapMatch?.group(1)?.trim() ?? 'dynamic';
    return '_nitroEncodeMapBinary${_mapTypeSuffix(valueType)}($varName, $allocator)';
  }
  final item = type.recordListItemType;
  if (item != null) {
    if (type.recordListItemIsPrimitive) {
      final writeCall = _primitiveWriterCall(item);
      return 'RecordWriter.encodeIndexedPrimitiveList($varName, (w, e) => w.$writeCall(e), $allocator)';
    }
    // Use indexed encoding so the receiving side can use LazyRecordList.
    return 'RecordWriter.encodeIndexedList($varName, (w, e) => e.writeFields(w), $allocator)';
  }
  // Nullable @HybridRecord: pass nullptr when null, otherwise encode normally.
  if (type.isNullable || type.name.endsWith('?')) {
    return '$varName != null ? $varName.toNative($allocator) : nullptr';
  }
  return '$varName.toNative($allocator)';
}

// ── NativeAsync helpers ───────────────────────────────────────────────────

/// Emits the body of a @NitroNativeAsync method.
///
/// The generated code:
///  1. Opens a ReceivePort and passes its native port to the C bridge.
///  2. Awaits exactly one message (the native result).
///  3. Unpacks the raw message to the Dart return type.
///
/// Arena params (String, TypedData, Record) are allocated, passed to the
/// bridge call, then immediately freed — the native side must copy them.
void _emitNativeAsyncBody(
  CodeWriter writer,
  BridgeFunction func,
  BridgeSpec spec,
  String callArgs,
  bool needsArena,
) {
  final unpack = _nativeAsyncUnpack(func, spec);
  final openType = _nativeAsyncOpenType(func, spec);

  if (needsArena) {
    writer.line('    final arena = Arena();');
    writer.line('    try {');
    writer.line('      return NitroRuntime.openNativeAsync<$openType>(');
    writer.line('        call: (port) => _${func.dartName}Ptr($callArgs, port),');
    writer.line('        unpack: $unpack,');
    writer.line("        methodName: '${func.dartName}',");
    writer.line('      );');
    writer.line('    } finally {');
    writer.line('      arena.releaseAll();');
    writer.line('    }');
  } else {
    final plainCallArgs = func.params
        .map((p) {
          final t = p.type.name;
          if (spec.enums.any((en) => en.name == t)) return '${p.name}.nativeValue';
          if (t == 'bool') return '${p.name} ? 1 : 0';
          if (p.type.isFunction) return _callbackArgExpr(func, p);
          // Optional primitives: NitroNullable binary encoding for zero-collision transport.
          // NOTE: These need an arena; needsArena now includes int?/double?/bool?.
          if (t == 'int?') return 'NitroNullableInt.fromNullable(${p.name}).toNative(arena)';
          if (t == 'double?') return 'NitroNullableDouble.fromNullable(${p.name}).toNative(arena)';
          if (t == 'bool?') return 'NitroNullableBool.fromNullable(${p.name}).toNative(arena)';
          return p.name;
        })
        .join(', ');

    final portSep = plainCallArgs.isEmpty ? '' : ', ';
    writer.line('    return NitroRuntime.openNativeAsync<$openType>(');
    writer.line('      call: (port) => _${func.dartName}Ptr($plainCallArgs${portSep}port),');
    writer.line('      unpack: $unpack,');
    writer.line("      methodName: '${func.dartName}',");
    writer.line('    );');
  }
}

/// The Dart type parameter for openNativeAsync`<T>` for this function.
String _nativeAsyncOpenType(BridgeFunction func, BridgeSpec spec) {
  final rt = func.returnType.name;
  // For the openNativeAsync<T> type param, strip the nullable suffix — the
  // native post mechanism uses sentinel values (−1 / NaN / nullptr) for null,
  // not Dart null, so the transport type is always non-nullable.
  final rtBase = rt.replaceFirst('?', '');
  if (rt == 'void') return 'void';
  if (rtBase == 'bool') return 'bool';
  if (rtBase == 'String') return 'Pointer<Utf8>';
  if (func.returnType.isRecord) return 'Pointer<Uint8>';
  if (spec.structs.any((st) => st.name == rtBase)) return 'Pointer<Void>';
  if (spec.enums.any((en) => en.name == rtBase)) return 'int';
  if (rtBase == 'int') return 'int';
  if (rtBase == 'double') return 'double';
  return rtBase;
}

/// Returns the unpack lambda expression for a @NitroNativeAsync method.
///
/// The native side posts via Dart_PostCObject_DL:
///  • primitives (int/double) → kInt64/kDouble → received as int/double
///  • bool                   → kBool          → received as bool
///  • void                   → kNull           → received as null
///  • String                 → kString         → received as Dart String
///  • record/struct/list     → kInt64 (ptr)    → decode from Pointer`<Uint8>`
///  • enum                   → kInt64          → call .toEnumType()
String _nativeAsyncUnpack(BridgeFunction func, BridgeSpec spec) {
  final rt = func.returnType.name;
  final rtBase = rt.replaceFirst('?', '');
  final isNullable = rt.endsWith('?');

  if (rt == 'void') return '(_) {}';

  // bool / bool?
  if (rtBase == 'bool') {
    return isNullable
        ? '(raw) => (raw as bool?) == null ? null : raw as bool'
        : '(raw) => raw as bool';
  }

  // String / String?  — native posts kString or kNull
  if (rtBase == 'String') {
    return isNullable
        ? '(raw) { final p = Pointer<Utf8>.fromAddress(raw as int); return p == nullptr ? null : p.toDartStringWithFree(); }'
        : '(raw) => raw as String';
  }

  // @HybridRecord  — native posts kInt64 (pointer to binary buffer)
  if (func.returnType.isRecord) {
    final decodeExpr = _decodeRecordExpr(func.returnType, 'rawPtr');
    final isLazy = func.returnType.recordListItemType != null && !func.returnType.recordListItemIsPrimitive;
    if (isNullable) {
      if (isLazy) {
        return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); if (rawPtr == nullptr) return null; return $decodeExpr; }';
      }
      return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); if (rawPtr == nullptr) return null; try { return $decodeExpr; } finally { malloc.free(rawPtr); } }';
    }
    if (isLazy) {
      return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); return $decodeExpr; }';
    }
    return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); try { return $decodeExpr; } finally { malloc.free(rawPtr); } }';
  }

  // @HybridStruct  — native posts kInt64 (pointer to heap struct)
  if (spec.structs.any((st) => st.name == rtBase)) {
    if (isNullable) {
      return '(raw) { final ptr = Pointer<${rtBase}Ffi>.fromAddress(raw as int); if (ptr == nullptr) return null; try { return ptr.ref.toDart(); } finally { ptr.ref.freeFields(); malloc.free(ptr); } }';
    }
    return '(raw) { final ptr = Pointer<${rtBase}Ffi>.fromAddress(raw as int); try { return ptr.ref.toDart(); } finally { ptr.ref.freeFields(); malloc.free(ptr); } }';
  }

  // @HybridEnum  — native posts kInt64 rawValue
  if (spec.enums.any((en) => en.name == rtBase)) {
    return isNullable
        ? '(raw) { final v = raw as int; return v == -1 ? null : v.to$rtBase(); }'
        : '(raw) => (raw as int).to$rtBase()';
  }

  // int / int?  — native posts kInt64; sentinel Int64.min = null
  if (rtBase == 'int') {
    return isNullable
        ? '(raw) { final v = raw as int; return v == -9223372036854775808 ? null : v; }'
        : '(raw) => raw as int';
  }

  // double / double?  — native posts kDouble; sentinel NaN = null
  if (rtBase == 'double') {
    return isNullable
        ? '(raw) { final v = raw as double; return v.isNaN ? null : v; }'
        : '(raw) => raw as double';
  }

  // Fallthrough: unknown type — cast directly (should not normally occur).
  return '(raw) => raw as $rt';
}

// S8: always-on error check via the pre-allocated out-param slot.
// This replaces the old assert-gated get_error()/clear_error() pattern.
// Errors are now detected in BOTH debug AND release builds.
String _inlineCheckError() {
  return 'NitroRuntime.throwIfOutParamError(_nitroErr);';
}

// ── Unified return decode helper ──────────────────────────────────────────
// Single source of truth for decoding raw FFI results into Dart values.
// Replaces four duplicated if/else chains (sync-arena, sync-no-arena,
// async-arena, async-no-arena). Calls existing _decodeRecordExpr /
// _emitTypedDataDecodeReturn so emitted code is byte-for-byte identical.
void _emitReturnDecode(
  CodeWriter writer,
  BridgeType returnType,
  String resVar,
  String indent,
  BridgeSpec spec, {
  bool zeroCopy = false,
  bool isOwned = false,
  String? dartName,
  String nativeHandleTypeParam = 'Void',
}) {
  final rt = returnType.name;
  final kind = classifyReturn(returnType, spec);
  final base = returnType.baseName;

  switch (kind) {
    case ReturnKind.voidType:
      return;
    case ReturnKind.record:
      final decodeExpr = _decodeRecordExpr(returnType, resVar);
      final isLazy = returnType.recordListItemType != null && !returnType.recordListItemIsPrimitive;
      // Nullable @HybridRecord: C returns nullptr when Kotlin returns null ByteArray?.
      final isNullableRecord = returnType.isNullable || returnType.name.endsWith('?');
      if (isNullableRecord) {
        writer.line('${indent}if ($resVar == nullptr) return null;');
      }
      if (isLazy) {
        writer.line('${indent}return $decodeExpr;');
      } else {
        writer.line('${indent}final $rt decoded;');
        writer.line('${indent}try {');
        writer.line('$indent  decoded = $decodeExpr;');
        writer.line('$indent} finally {');
        writer.line('$indent  malloc.free($resVar);');
        writer.line('$indent}');
        writer.line('${indent}return decoded;');
      }
    case ReturnKind.typedData:
      _emitTypedDataDecodeReturn(writer, returnType, resVar, indent, zeroCopy: zeroCopy);
    case ReturnKind.struct:
      // Nullable struct (T?): null pointer → Dart null.
      // Non-nullable struct: null pointer → StateError (should never happen).
      if (returnType.isNullable || returnType.name.endsWith('?')) {
        writer.line('${indent}if ($resVar == nullptr) return null;');
      } else {
        writer.line('${indent}if ($resVar == nullptr) {');
        writer.line('$indent  throw StateError(\'${dartName ?? rt} returned null\');');
        writer.line('$indent}');
      }
      writer.line('${indent}final structPtr = Pointer<${base}Ffi>.fromAddress($resVar.address);');
      writer.line('${indent}final $base decoded;');
      writer.line('${indent}try {');
      writer.line('$indent  decoded = structPtr.ref.toDart();');
      writer.line('$indent} finally {');
      writer.line('$indent  structPtr.ref.freeFields();');
      writer.line('$indent  malloc.free(structPtr);');
      writer.line('$indent}');
      writer.line('${indent}return decoded;');
    case ReturnKind.nativeHandle:
      if (isOwned && dartName != null) {
        writer.line('${indent}final handle = NativeHandle<$nativeHandleTypeParam>.fromAddress($resVar.address);');
        writer.line('${indent}_${dartName}Finalizer.attach(handle, $resVar.cast(), detach: handle);');
        writer.line("${indent}handle._releaseCallback = (addr) { _${dartName}ReleaseFn(Pointer<Void>.fromAddress(addr)); _${dartName}Finalizer.detach(handle); };");
        writer.line('${indent}return handle;');
      } else {
        writer.line('${indent}return NativeHandle<$nativeHandleTypeParam>.fromAddress($resVar.address);');
      }
    case ReturnKind.enumType:
      // Nullable enum: -1 sentinel = null; otherwise decode rawValue.
      final isNullableEnum = returnType.isNullable || returnType.name.endsWith('?');
      if (isNullableEnum) {
        writer.line('${indent}return $resVar == -1 ? null : $resVar.to$base();');
      } else {
        writer.line('${indent}return $resVar.to$base();');
      }
    case ReturnKind.boolNonNull:
      writer.line('${indent}return $resVar != 0;');
    case ReturnKind.boolNullable:
      // NitroNullable binary encoding — decode from Pointer<Uint8>
      writer.line('${indent}return NitroNullableBool.fromNative($resVar).nullable;');
    case ReturnKind.stringNonNull:
      writer.line('${indent}return $resVar.toDartStringWithFree();');
    case ReturnKind.stringNullable:
      writer.line('${indent}return $resVar == nullptr ? null : $resVar.toDartStringWithFree();');
    case ReturnKind.intNullable:
      // NitroNullable binary encoding — decode from Pointer<Uint8>
      writer.line('${indent}return NitroNullableInt.fromNative($resVar).nullable;');
    case ReturnKind.doubleNullable:
      // NitroNullable binary encoding — decode from Pointer<Uint8>
      writer.line('${indent}return NitroNullableDouble.fromNative($resVar).nullable;');
    case ReturnKind.primitive:
      writer.line('${indent}return $resVar;');
  }
}

/// Variable name used for the raw async result based on return kind.
/// Keeps emitted code readable: `rawPtr` for pointer types, `res` for scalars.
String _asyncResVarName(ReturnKind kind) => switch (kind) {
  ReturnKind.record    => 'rawPtr',
  ReturnKind.typedData => 'rawPtr',
  ReturnKind.struct    => 'rawPtr',
  _                    => 'res',
};

// Kept for callers that already pass an indent; delegates to the S8 form.
String _assertCheckError(String indent) => '$indent${_inlineCheckError()}';

// ── Leaf / isLeaf helpers ─────────────────────────────────────────────────

/// Returns true when [bt] maps to a plain FFI scalar (int, double, bool, or
/// a known enum) — types that require no arena allocation and no Dart heap
/// object creation on the call boundary.
bool _isPrimitiveType(BridgeType bt, BridgeSpec spec) {
  if (bt.isRecord || bt.isTypedData || bt.isPointer || bt.isFunction || bt.isNativeHandle) return false;
  final name = bt.name.replaceFirst('?', '');
  if (name == 'String' || name == 'void') return false;
  if (spec.structs.any((st) => st.name == name)) return false;
  // Nullable primitives now use NitroNullable (Pointer<Uint8>) — not scalars.
  if (bt.name == 'int?' || bt.name == 'double?' || bt.name == 'bool?') return false;
  // int, double, bool, and known enums are all FFI scalars.
  return true;
}

/// Returns true when the function pointer should be bound with `isLeaf: true`.
///
/// `isLeaf: true` skips the Dart VM safepoint transition, shaving ~50–200 ns
/// per call.  It is safe when the C++ body never calls back into Dart and the
/// call is expected to be short-lived (no blocking I/O).
///
/// Conditions:
///  • Not async (async calls dispatch to isolates, irrelevant here).
///  • Explicitly named "Fast" — a developer contract that the method is hot.
///  • OR all params and the return type are plain scalars (no arena needed).
bool _isLeafCandidate(BridgeFunction func, BridgeSpec spec) {
  if (func.isAsync || func.isNativeAsync) return false;
  if (func.dartName.endsWith('Fast')) return true;
  final rt = func.returnType;
  if (!_isPrimitiveType(rt, spec) && rt.name != 'void') return false;
  return func.params.every((p) => _isPrimitiveType(p.type, spec));
}

bool _hasFunctionTypeParams(BridgeSpec spec) {
  return spec.functions.any((f) => f.params.any((p) => p.type.isFunction));
}

void _assertSupportedFunctionTypes(BridgeSpec spec) {
  for (final func in spec.functions) {
    if (func.returnType.isFunction) {
      throw UnsupportedError(
        '${spec.dartClassName}.${func.dartName}() returns function type "${func.returnType.name}", which is not a supported native ABI type.',
      );
    }
    for (final param in func.params) {
      if (param.type.isFunction) {
        _assertSupportedCallbackType(spec, func, param);
      }
    }
  }
  for (final prop in spec.properties) {
    if (prop.type.isFunction) {
      throw UnsupportedError(
        '${spec.dartClassName}.${prop.dartName} uses function type "${prop.type.name}", which is not a supported native ABI type.',
      );
    }
  }
}

void _assertSupportedCallbackType(
  BridgeSpec spec,
  BridgeFunction func,
  BridgeParam param,
) {
  final callback = param.type;
  final returnName = (callback.functionReturnType ?? 'void').replaceFirst('?', '');
  // String is now supported as bidirectional callback return type (#4).
  if (returnName != 'void' && returnName != 'int' && returnName != 'double'
      && returnName != 'bool' && returnName != 'String'
      && !spec.enums.any((e) => e.name == returnName)) {
    throw UnsupportedError(
      '${spec.dartClassName}.${func.dartName}() parameter "${param.name}" has callback return type "$returnName", which is not supported. Callback returns currently support void, int, double, bool, String, and @HybridEnum.',
    );
  }
  for (final callbackParam in callback.functionParams) {
    if (!_isSupportedCallbackParam(callbackParam, spec)) {
      throw UnsupportedError(
        '${spec.dartClassName}.${func.dartName}() parameter "${param.name}" has callback parameter type "${callbackParam.name}", which is not supported. Callback parameters currently support int, double, bool, String, Pointer<T>, and @HybridEnum.',
      );
    }
  }
}

bool _isSupportedCallbackParam(BridgeType type, BridgeSpec spec) {
  if (type.isPointer) return true;
  final name = type.name.replaceFirst('?', '');
  if (name == 'int' || name == 'double' || name == 'bool' || name == 'String') return true;
  if (spec.enums.any((e) => e.name == name)) return true;
  if (spec.structs.any((s) => s.name == name)) return true;
  if (spec.recordTypes.any((r) => r.name == name)) return true;
  return false;
}

void _emitCallbackHelpers(CodeWriter writer, BridgeSpec spec) {
  writer.line('  // Native callback handles are cached so native code can retain');
  writer.line('  // callback pointers safely until this HybridObject is disposed.');
  for (final func in spec.functions) {
    for (final param in func.params.where((p) => p.type.isFunction)) {
      final helperName = _callbackHelperName(func, param);
      final dartType = _callbackDartType(param.type, spec, nullable: false);
      final nativeSig = _callbackNativeSignature(param.type, spec);
      final callbackFactory = _callbackFactory(param.type);
      final exceptionalReturn = _callbackExceptionalReturn(param.type, spec);
      final exceptionalArg = exceptionalReturn == null ? '' : ', exceptionalReturn: $exceptionalReturn';
      writer.line('  NativeCallable<$nativeSig> $helperName($dartType callback) {');
      writer.line("    final key = ('${func.dartName}.${param.name}', callback);");
      writer.line('    return _nativeCallbackCache.putIfAbsent(key, () {');
      writer.line('      return NativeCallable<$nativeSig>.$callbackFactory((${_callbackWrapperParams(param.type, spec)}) {');
      final invocationArgs = _callbackInvocationArgs(param.type, spec);
      final callbackInvocation = 'callback($invocationArgs)';
      final returnExpr = _callbackReturnExpression(param.type, spec, callbackInvocation);
      if (returnExpr == null) {
        writer.line('        $callbackInvocation;');
      } else {
        writer.line('        return $returnExpr;');
      }
      writer.line('      }$exceptionalArg);');
      writer.line('    }) as NativeCallable<$nativeSig>;');
      writer.line('  }');
      writer.blankLine();
    }
  }
}

String _callbackFactory(BridgeType callbackType) {
  final returnName = (callbackType.functionReturnType ?? 'void').replaceFirst('?', '');
  return returnName == 'void' ? 'listener' : 'isolateLocal';
}

String? _callbackExceptionalReturn(BridgeType callbackType, BridgeSpec spec) {
  final returnName = (callbackType.functionReturnType ?? 'void').replaceFirst('?', '');
  if (returnName == 'void') return null;
  // double now encodes as Int64 raw bits → exceptionalReturn must be int 0, not 0.0.
  if (returnName == 'double') return '0';
  if (returnName == 'bool') return '0';
  if (returnName == 'int' || spec.enums.any((e) => e.name == returnName)) return '0';
  // String returns Pointer<Utf8> — isolateLocal doesn't allow exceptionalReturn for Pointer types.
  // Let exceptions propagate naturally; the caller handles errors via NitroError*.
  if (returnName == 'String') return null;
  return null;
}

String _callbackArgExpr(BridgeFunction func, BridgeParam param) {
  final helper = _callbackHelperName(func, param);
  final nullable = param.type.isNullable || param.type.name.endsWith('?');
  if (nullable) {
    return '${param.name} == null ? nullptr : $helper(${param.name}!).nativeFunction';
  }
  return '$helper(${param.name}).nativeFunction';
}

String _callbackHelperName(BridgeFunction func, BridgeParam param) {
  return '_nativeCallback${_cap(func.dartName)}${_cap(param.name)}';
}

String _callbackNativeSignature(BridgeType callbackType, BridgeSpec spec) {
  final ret = _callbackReturnToFFI(callbackType.functionReturnType ?? 'void', spec);
  // Expandable structs become multiple Int64 params (one per field) for synchronous NativeCallable.
  final paramsList = <String>[];
  for (final p in callbackType.functionParams) {
    final base = p.name.replaceFirst('?', '');
    final struct = spec.structs.where((s) => s.name == base).firstOrNull;
    if (struct != null && _isExpandableCallbackStruct(struct)) {
      paramsList.addAll(struct.fields.map((_) => 'Int64'));
    } else {
      paramsList.add(_callbackParamToFFI(p, spec));
    }
  }
  return '$ret Function(${paramsList.join(', ')})';
}

/// Returns true when a struct's fields are all numeric and can be
/// expanded to individual Int64 params for synchronous NativeCallable.listener.
bool _isExpandableCallbackStruct(BridgeStruct st) {
  const numeric = {'int', 'double', 'bool'};
  return st.fields.isNotEmpty &&
      st.fields.every((f) => numeric.contains(f.type.name.replaceFirst('?', '')) && !f.type.isTypedData);
}

String _callbackDartType(BridgeType callbackType, BridgeSpec spec, {required bool nullable}) {
  final ret = callbackType.functionReturnType ?? 'void';
  final params = callbackType.functionParams.map((p) => p.name).join(', ');
  final suffix = nullable ? '?' : '';
  return '$ret Function($params)$suffix';
}

String _callbackReturnToFFI(String dartType, BridgeSpec spec) {
  final name = dartType.replaceFirst('?', '');
  if (name == 'void') return 'Void';
  if (name == 'int') return 'Int64';
  if (name == 'double') return 'Int64'; // raw bits, same GP-register path as int
  if (name == 'bool') return 'Int64';   // 0/1 via GP register
  if (name == 'String') return 'Pointer<Utf8>'; // strdup'd from native
  if (spec.enums.any((e) => e.name == name)) return 'Int64';
  return 'Void';
}

String _callbackParamToFFI(BridgeType type, BridgeSpec spec) {
  if (type.isPointer) return 'Pointer<${type.pointerInnerType ?? 'Void'}>';
  final name = type.name.replaceFirst('?', '');
  if (name == 'int') return 'Int64';
  // bool and double are routed through Int64 on Android to ensure NativeCallable.listener
  // fires synchronously (only Int64/Long has the synchronous fast-path on Android).
  // The C JNI invoker encodes bool as 1L/0L and double as raw IEEE 754 bits.
  if (name == 'double') return 'Int64';
  if (name == 'bool') return 'Int64';
  if (name == 'String') return 'Pointer<Utf8>';
  if (spec.enums.any((e) => e.name == name)) return 'Int64';
  if (spec.structs.any((s) => s.name == name)) return 'Pointer<Void>';
  if (spec.recordTypes.any((r) => r.name == name)) return 'Pointer<Uint8>';
  return 'Pointer<Void>';
}

String _callbackWrapperParams(BridgeType callbackType, BridgeSpec spec) {
  final parts = <String>[];
  for (var i = 0; i < callbackType.functionParams.length; i++) {
    final type = callbackType.functionParams[i];
    final base = type.name.replaceFirst('?', '');
    final struct = spec.structs.where((s) => s.name == base).firstOrNull;
    if (struct != null && _isExpandableCallbackStruct(struct)) {
      // Use camelCase names (arg0X not arg0_x) to satisfy Dart lint.
      for (final f in struct.fields) {
        parts.add('int arg$i${_cap(f.name)}');
      }
    } else {
      parts.add('${_callbackParamToDartFFI(type, spec)} arg$i');
    }
  }
  return parts.join(', ');
}

String _callbackParamToDartFFI(BridgeType type, BridgeSpec spec) {
  if (type.isPointer) return 'Pointer<${type.pointerInnerType ?? 'Void'}>';
  final name = type.name.replaceFirst('?', '');
  if (name == 'int') return 'int';
  if (name == 'double') return 'int'; // received as Int64 (IEEE 754 bits)
  if (name == 'bool') return 'int';   // received as Int64 (1 = true, 0 = false)
  if (name == 'String') return 'Pointer<Utf8>';
  if (spec.enums.any((e) => e.name == name)) return 'int';
  if (spec.structs.any((s) => s.name == name)) return 'Pointer<Void>';
  if (spec.recordTypes.any((r) => r.name == name)) return 'Pointer<Uint8>';
  return 'Pointer<Void>';
}

String _callbackInvocationArgs(BridgeType callbackType, BridgeSpec spec) {
  final args = <String>[];
  for (var i = 0; i < callbackType.functionParams.length; i++) {
    final type = callbackType.functionParams[i];
    final name = type.name.replaceFirst('?', '');
    final struct = spec.structs.where((s) => s.name == name).firstOrNull;
    if (struct != null && _isExpandableCallbackStruct(struct)) {
      // Reconstruct struct from individual Int64 field args (synchronous path).
      final fieldExprs = struct.fields.map((f) {
        final fBase = f.type.name.replaceFirst('?', '');
        final argName = 'arg$i${_cap(f.name)}'; // camelCase: arg0X, arg0Y, arg0Z
        if (fBase == 'double') {
          return '${f.name}: Int64List.fromList([$argName]).buffer.asFloat64List()[0]';
        } else if (fBase == 'bool') {
          return '${f.name}: $argName != 0';
        } else {
          return '${f.name}: $argName';
        }
      }).join(', ');
      args.add('$name($fieldExprs)');
    } else if (name == 'bool') {
      args.add('arg$i != 0');
    } else if (name == 'double') {
      args.add('Int64List.fromList([arg$i]).buffer.asFloat64List()[0]');
    } else if (name == 'String') {
      args.add('arg$i.toDartString()');
    } else if (spec.enums.any((e) => e.name == name)) {
      args.add('arg$i.to$name()');
    } else if (spec.structs.any((s) => s.name == name)) {
      args.add('arg$i.cast<${name}Ffi>().ref.toDart()');
    } else if (spec.recordTypes.any((r) => r.name == name)) {
      args.add('(() { final _r = $name.fromNative(arg$i); malloc.free(arg$i); return _r; })()');
    } else {
      args.add('arg$i');
    }
  }
  return args.join(', ');
}

String? _callbackReturnExpression(BridgeType callbackType, BridgeSpec spec, String invocation) {
  final returnName = (callbackType.functionReturnType ?? 'void').replaceFirst('?', '');
  if (returnName == 'void') return null;
  // double → raw IEEE 754 bits as Int64 (GP register, NativeCallable sync path)
  if (returnName == 'double') return 'Float64List.fromList([$invocation]).buffer.asInt64List()[0]';
  if (returnName == 'bool') return '$invocation ? 1 : 0';
  // String → strdup'd pointer; native will call free() on it
  if (returnName == 'String') return '$invocation.toNativeUtf8()';
  if (spec.enums.any((e) => e.name == returnName)) return '$invocation.nativeValue';
  return invocation;
}
