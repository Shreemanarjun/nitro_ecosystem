part of '../dart_ffi_generator.dart';

String _decodeRecordExpr(BridgeType type, String ptrVar) {
  // @NitroTuple: standalone free function (can't extend a typedef).
  if (type.isTuple) {
    final rt = type.name.endsWith('?') ? type.name.substring(0, type.name.length - 1) : type.name;
    if (type.isNullable || type.name.endsWith('?')) {
      return '_nitroDecodeNullable_$rt($ptrVar)';
    }
    return '_nitroDecode_$rt($ptrVar)';
  }
  if (type.isAnyMap) {
    // NitroAnyMap — type-tagged binary codec (mirrors RN Nitro AnyMap).
    return 'NitroAnyMap.fromNative($ptrVar)';
  }
  if (type.isMap) {
    // Binary map decoding — resolves NaN/Infinity, int64 precision, perf issues.
    // ptrVar is Pointer<Uint8> (4-byte length prefix + binary payload).
    final mapMatch = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(type.name);
    final valueType = mapMatch?.group(1)?.trim() ?? 'dynamic';
    return '_nitroDecodeMapBinary${_mapTypeSuffix(valueType)}($ptrVar)';
  }
  // List<@HybridEnum> — [4B len][4B count][8B×N nativeValues]
  // List<@HybridEnum?> — [4B len][4B count][1B hasValue][8B nativeValue]×N
  if (type.isEnumList) {
    final item = type.recordListItemType!;
    if (type.recordListItemIsNullable) {
      return 'RecordReader.decodeNullableList($ptrVar, (r) => r.readInt().to$item())';
    }
    return 'RecordReader.decodeList($ptrVar, (r) => r.readInt().to$item())';
  }
  // List<@NitroVariant> — [4B len][4B count][tag+fields×N]
  // List<@NitroVariant?> — [4B len][4B count][1B hasValue][tag+fields]×N
  if (type.isVariantList) {
    final item = type.recordListItemType!;
    if (type.recordListItemIsNullable) {
      return 'RecordReader.decodeNullableList($ptrVar, (r) => ${item}VariantExt.fromReader(r))';
    }
    return 'RecordReader.decodeList($ptrVar, (r) => ${item}VariantExt.fromReader(r))';
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
  // @NitroTuple: standalone free function (can't extend a typedef).
  if (type.isTuple) {
    final rt = type.name.endsWith('?') ? type.name.substring(0, type.name.length - 1) : type.name;
    if (type.isNullable || type.name.endsWith('?')) {
      return '$varName != null ? _nitroEncode_$rt($varName!, $allocator) : nullptr';
    }
    return '_nitroEncode_$rt($varName, $allocator)';
  }
  if (type.isAnyMap) {
    // NitroAnyMap — type-tagged binary codec (mirrors RN Nitro AnyMap).
    return '$varName.toNative($allocator)';
  }
  if (type.isMap) {
    // Maps use binary encoding — resolves NaN/Infinity, int64 precision, and perf issues.
    final mapMatch = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(type.name);
    final valueType = mapMatch?.group(1)?.trim() ?? 'dynamic';
    return '_nitroEncodeMapBinary${_mapTypeSuffix(valueType)}($varName, $allocator)';
  }
  // List<@HybridEnum> / List<@HybridEnum?> — sequential, [4B count][8B×N] or [4B count][1B+8B×N]
  if (type.isEnumList) {
    if (type.recordListItemIsNullable) {
      return 'RecordWriter.encodeNullableList($varName, (w, e) => w.writeInt(e.nativeValue), $allocator)';
    }
    return 'RecordWriter.encodeList($varName, (w, e) => w.writeInt(e.nativeValue), $allocator)';
  }
  // List<@NitroVariant> / List<@NitroVariant?> — sequential, [4B count][tag+fields×N] or [4B count][1B+tag+fields×N]
  if (type.isVariantList) {
    if (type.recordListItemIsNullable) {
      return 'RecordWriter.encodeNullableList($varName, (w, v) => v.writeFields(w), $allocator)';
    }
    return 'RecordWriter.encodeList($varName, (w, v) => v.writeFields(w), $allocator)';
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

// ── @NitroResult decode ──────────────────────────────────────────────────

/// Emits the `[1B tag]`-based decode for a `@NitroResult` function.
///
/// Wire format: `[1B tag: 0=ok, 1=err][record-codec payload]`
///
/// All success payloads — even primitives — are wrapped in the record codec
/// (4-byte length prefix + data). This keeps the decode uniform: always
/// `RecordReader.fromNative(res + 1)` then read the appropriate type.
void _emitResultDecode(
  CodeWriter writer,
  BridgeType returnType,
  String resVar,
  String indent,
  BridgeSpec spec,
) {
  // Wrap entire decode in try/finally to free the native buffer on both branches.
  // Native allocates with malloc; Dart must free it to avoid a memory leak.
  writer.line('${indent}try {');
  final i2 = '$indent  ';

  // Error branch — common to all inner types
  writer.line('${i2}final _tag = $resVar[0];');
  writer.line('${i2}if (_tag != 0) {');
  writer.line('$i2  final _errR = RecordReader.fromNative($resVar + 1);');
  writer.line('$i2  return NitroErr(_errR.readString());');
  writer.line('$i2}');

  // Success branch — decode T from res + 1
  final rt = returnType.name;
  final base = rt.replaceFirst('?', '');

  if (returnType.isRecord) {
    // @HybridRecord / Map / List<Record>
    final decodeExpr = _decodeRecordExpr(returnType, '$resVar + 1');
    writer.line('${i2}return NitroOk($decodeExpr);');
  } else {
    // Primitives: wrapped in record codec on native side
    writer.line('${i2}final _r = RecordReader.fromNative($resVar + 1);');
    String valueExpr;
    switch (base) {
      case 'int':
        valueExpr = '_r.readInt()';
      case 'double':
        valueExpr = '_r.readDouble()';
      case 'bool':
        valueExpr = '_r.readBool()';
      case 'String':
        valueExpr = '_r.readString()';
      default:
        if (spec.isEnumName(base)) {
          // Enum: stored as int64 on wire, converted to enum case
          valueExpr = '${base}EnumExt.fromNativeValue(_r.readInt())';
        } else if (spec.isStructName(base)) {
          // @HybridStruct: stored as record-codec on wire
          valueExpr = '${base}StructExt.fromReader(_r)';
        } else {
          // Unknown — best-effort record decode
          valueExpr = '${base}RecordExt.fromReader(_r)';
        }
    }
    writer.line('${i2}return NitroOk($valueExpr);');
  }

  writer.line('$indent} finally {');
  writer.line('$indent  malloc.free($resVar);');
  writer.line('$indent}');
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
