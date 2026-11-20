part of '../dart_ffi_generator.dart';

/// [owned]: [ptrVar] is the buffer's own address and the caller releases it
/// with `_nitroFree` right after this expression. Only then may the reader
/// keep the buffer alive behind a byte field (see `RecordReader.keptAlive`).
String _decodeRecordExpr(BridgeType type, String ptrVar, BridgeSpec spec, {bool owned = false}) {
  // A nullable LIST return arrives as nullptr when absent. Decode it through a
  // guard so the list decoders below always see a real buffer; without this a
  // null return would be read as a zero-address buffer.
  if (type.recordListItemType != null && (type.isNullable || type.name.endsWith('?'))) {
    final inner = _decodeRecordExpr(
      BridgeType(
        name: type.name.replaceFirst(RegExp(r'\?$'), ''),
        isRecord: type.isRecord,
        recordListItemType: type.recordListItemType,
        recordListItemIsPrimitive: type.recordListItemIsPrimitive,
        recordListItemIsNullable: type.recordListItemIsNullable,
        isEnumList: type.isEnumList,
        isVariantList: type.isVariantList,
      ),
      ptrVar,
      spec,
    );
    return '$ptrVar == nullptr ? null : $inner';
  }
  // @NitroTuple: standalone free function (can't extend a typedef).
  if (type.isTuple) {
    final rt = type.name.endsWith('?') ? type.name.substring(0, type.name.length - 1) : type.name;
    if (type.isNullable || type.name.endsWith('?')) {
      return '_nitroDecodeNullable_$rt($ptrVar)';
    }
    return '_nitroDecode_$rt($ptrVar)';
  }
  if (type.isAnyMap || type.isMap) {
    // Binary map decoding — resolves NaN/Infinity, int64 precision, perf issues.
    // ptrVar is Pointer<Uint8> (4-byte length prefix + binary payload).
    final decode = type.isAnyMap ? 'nitroAnyMapFromNative($ptrVar)' : '_nitroDecodeMapBinary${_mapTypeSuffix(stringMapValueType(type.name) ?? 'dynamic')}($ptrVar)';
    // A null map arrives as nullptr.
    return type.isNullable || type.name.endsWith('?') ? '$ptrVar == nullptr ? null : $decode' : decode;
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
    // The buffer outlives this call (freed by the list's NativeFinalizer), so
    // the module's native free is passed instead of package:ffi's default.
    return 'LazyRecordList.decode($ptrVar, (r) => ${item}RecordExt.fromReader(r), nativeFree: _nitroFreeFinalizer)';
  }
  // Strip nullable '?' suffix — the extension/class is always named after the base type.
  final rt = bareTypeName(type.name);
  // Built-in library types decode via package:nitro's free functions (the
  // class statics were removed in the 0.7.0 web split).
  const libraryDecoders = {
    'NitroNullableInt': 'nitroNullableIntFromNative',
    'NitroNullableDouble': 'nitroNullableDoubleFromNative',
    'NitroNullableBool': 'nitroNullableBoolFromNative',
  };
  final libDecoder = libraryDecoders[rt];
  if (libDecoder != null) return '$libDecoder($ptrVar)';
  if (_nitroLibraryRecordTypes.contains(rt)) return '$rt.fromNative($ptrVar)';
  if (owned && spec.recordLendsBytes(rt)) {
    return '${rt}RecordExt.fromReader(RecordReader.fromNative($ptrVar, adopt: _nitroAdopt))';
  }
  return '${_recordDecodeExtName(spec, rt)}.fromNative($ptrVar)';
}

void _emitTypedDataDecodeReturn(
  CodeWriter writer,
  BridgeType type,
  String ptrVar,
  String indent, {
  bool zeroCopy = false,
  // Nullable TypedData return (e.g. @zeroCopy Uint8List?): native returns
  // nullptr for a null value, which decodes to Dart null instead of throwing.
  bool nullable = false,
}) {
  final rt = bareTypeName(type.name);
  final ffiElem = _typedDataFfiElement(rt);
  final lengthExpr = _typedDataElementSize(rt) == 1 ? 'byteLength' : 'byteLength ~/ ${_typedDataElementSize(rt)}';
  writer.line('${indent}if ($ptrVar == nullptr) {');
  if (nullable) {
    writer.line('$indent  return null;');
  } else {
    writer.line("$indent  throw StateError('Native $rt return was null');");
  }
  writer.line('$indent}');
  if (zeroCopy) {
    writer.line('$indent final byteLength = $ptrVar.cast<Int64>().value;');
    writer.line('$indent final dataAddress = Pointer<Int64>.fromAddress($ptrVar.address + 8).value;');
    writer.line('$indent final payloadPtr = Pointer<$ffiElem>.fromAddress(dataAddress);');
    // Register the view so passing it back to a @zeroCopy param is pointer-only.
    // The view owns the native memory through a finalizable handle, so it stays
    // valid when returned from another isolate (see _emitNitroAdopt).
    writer.line('$indent final view = payloadPtr.asTypedList($lengthExpr);');
    writer.line('$indent _nitroAdoptTypedDataReturn(view, $ptrVar.cast<Void>(), byteLength);');
    writer.line('$indent return nitroRegisterZeroCopyView(view, payloadPtr.cast<Void>());');
    return;
  }
  _typedDataBlockDecode(rt, ptrVar).forEach((l) => writer.line('$indent$l'));
}

/// Statements that turn the bridge's `[8B byteLength][bytes]` copy at [ptrVar]
/// into the Dart list and return it. A large block is not copied again: the
/// list views it and owns it (`_nitroAdopt`, see `_emitNitroAdopt`). The
/// payload is 8 bytes into a malloc block, so it is aligned for every element.
List<String> _typedDataBlockDecode(String rt, String ptrVar) {
  final lengthExpr = _typedDataElementSize(rt) == 1 ? 'byteLength' : 'byteLength ~/ ${_typedDataElementSize(rt)}';
  return [
    'final byteLength = $ptrVar.cast<Int64>().value;',
    'final payload = Pointer<${_typedDataFfiElement(rt)}>.fromAddress($ptrVar.address + 8).asTypedList($lengthExpr);',
    'if (byteLength >= RecordReader.lendMinBytes) {',
    '  _nitroAdopt(payload, $ptrVar.cast<Void>(), byteLength);',
    '  return payload;',
    '}',
    'try {',
    '  return $rt.fromList(payload);',
    '} finally {',
    '  _nitroFree($ptrVar);',
    '}',
  ];
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
    final rt = type.baseName;
    if (type.isNullable) {
      // Flow analysis promotes varName to non-null inside the true branch — no !.
      return '$varName != null ? _nitroEncode_$rt($varName, $allocator) : nullptr';
    }
    return '_nitroEncode_$rt($varName, $allocator)';
  }
  if (type.isAnyMap || type.isMap) {
    // Maps use binary encoding — resolves NaN/Infinity, int64 precision, and perf issues.
    final encode = type.isAnyMap ? '$varName.toNative($allocator)' : '_nitroEncodeMapBinary${_mapTypeSuffix(stringMapValueType(type.name) ?? 'dynamic')}($varName, $allocator)';
    // A null map is sent as nullptr.
    return type.isNullable || type.name.endsWith('?') ? '$varName == null ? nullptr : $encode' : encode;
  }
  // A nullable LIST (as opposed to a list of nullable items) passes nullptr
  // for "absent"; the guard has to wrap the encoder call because every encoder
  // below declares a non-null `List<T>`.
  final listIsNullable = type.recordListItemType != null && (type.isNullable || type.name.endsWith('?'));
  String listGuard(String encode) => listIsNullable ? '$varName != null ? $encode : nullptr' : encode;
  // List<@HybridEnum> / List<@HybridEnum?> — sequential, [4B count][8B×N] or [4B count][1B+8B×N]
  if (type.isEnumList) {
    if (type.recordListItemIsNullable) {
      return listGuard('RecordWriter.encodeNullableList($varName, (w, e) => w.writeInt(e.nativeValue), $allocator)');
    }
    return listGuard('RecordWriter.encodeList($varName, (w, e) => w.writeInt(e.nativeValue), $allocator)');
  }
  // List<@NitroVariant> / List<@NitroVariant?> — sequential, [4B count][tag+fields×N] or [4B count][1B+tag+fields×N]
  if (type.isVariantList) {
    if (type.recordListItemIsNullable) {
      return listGuard('RecordWriter.encodeNullableList($varName, (w, v) => v.writeFields(w), $allocator)');
    }
    return listGuard('RecordWriter.encodeList($varName, (w, v) => v.writeFields(w), $allocator)');
  }
  final item = type.recordListItemType;
  if (item != null) {
    if (type.recordListItemIsPrimitive) {
      final writeCall = _primitiveWriterCall(item);
      return listGuard('RecordWriter.encodeIndexedPrimitiveList($varName, (w, e) => w.$writeCall(e), $allocator)');
    }
    // Use indexed encoding so the receiving side can use LazyRecordList.
    return listGuard('RecordWriter.encodeIndexedList($varName, (w, e) => e.writeFields(w), $allocator)');
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
  BridgeFunction func,
  BridgeType returnType,
  String resVar,
  String indent,
  BridgeSpec spec,
) {
  // A bridge that could not run the method at all (an instance that is not
  // registered, a native throw before the call) returns null, not a blob.
  // Report it; reading the tag through a null pointer is a crash.
  writer.line('${indent}if ($resVar == nullptr) {');
  if (!func.isAsync) {
    // The sync bridge leaves the reason in the error slot.
    writer.line('$indent  try {');
    writer.line("$indent    NitroRuntime.throwIfOutParamError(_nitroErr, nativeFree: _nitroFree, methodName: '${func.dartName}');");
    writer.line('$indent  } on HybridException catch (e) {');
    writer.line('$indent    return NitroErr(e.message);');
    writer.line('$indent  }');
  }
  writer.line("$indent  return NitroErr('${func.dartName}: the native side returned no result');");
  writer.line('$indent}');
  // Wrap entire decode in try/finally to free the native buffer on both branches.
  // Native allocates with malloc; Dart must free it to avoid a memory leak.
  writer.line('${indent}try {');
  final i2 = '$indent  ';

  final carrier = spec.resultCarrier(func);
  writer.line('${i2}final _tag = $resVar[0];');
  // Tag 2: ok, and the value is null. Before the error branch, which takes
  // every other non-zero tag.
  if (carrier case BlockCarrier(isNullable: true)) {
    writer.line('${i2}if (_tag == 2) return NitroOk(null);');
  }
  // Error branch — common to all inner types
  writer.line('${i2}if (_tag != 0) {');
  writer.line('$i2  final _errR = RecordReader.fromNative($resVar + 1);');
  writer.line('$i2  return NitroErr(_errR.readString());');
  writer.line('$i2}');

  // Success branch — decode T from res + 1, the way its carrier sent it.
  final base = bareTypeName(returnType.name);
  final (String? reader, String value) = switch (carrier) {
    // A one-field record, whose wire form is the field's own.
    WrappedCarrier() => ('r', dartWrappedResultRead(carrier)),
    // A self-describing block: the decoder its plain return uses.
    BlockCarrier() || RecordCarrier() => (null, _resultBlockDecode(returnType, '$resVar + 1', spec)),
    ScalarCarrier(:final kind) => (
      '_r',
      switch (kind) {
        ScalarKind.int64 => '_r.readInt()',
        ScalarKind.float64 => '_r.readDouble()',
        ScalarKind.boolean => '_r.readBool()',
        ScalarKind.string => '_r.readString()',
        // The generated `to$base()` extension record fields use.
        ScalarKind.enumValue => '_r.readInt().to$base()',
      },
    ),
    // Rejected by the validator (E015); a spec built by hand still generates.
    NoCarrier() when returnType.isRecord => (null, _decodeRecordExpr(returnType, '$resVar + 1', spec)),
    NoCarrier() => ('_r', spec.isStructName(base) ? '${base}StructExt.fromReader(_r)' : '${base}RecordExt.fromReader(_r)'),
  };
  if (reader != null) writer.line('${i2}final $reader = RecordReader.fromNative($resVar + 1);');
  writer.line('${i2}return NitroOk($value);');

  writer.line('$indent} finally {');
  writer.line('$indent  _nitroFree($resVar);');
  writer.line('$indent}');
}

/// Decodes the self-describing block of a `@NitroResult` value at [ptr]. A
/// null value never reaches here (it is tag 2), so the type is read as
/// non-nullable.
String _resultBlockDecode(BridgeType type, String ptr, BridgeSpec spec) {
  final t = type.nonNullable;
  return switch (t.name) {
    _ when spec.isVariantName(t.name) => '${_variantDecodeExtName(spec, t.name)}.fromNative($ptr)',
    _ => _decodeRecordExpr(t, ptr, spec),
  };
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
