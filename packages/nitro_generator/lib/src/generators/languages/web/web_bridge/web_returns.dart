part of '../web_bridge_generator.dart';

// Module return value → Dart value: @NitroResult carriers, framed records,
// nullable primitives, structs and typed data read off the module heap.

/// Web twin of the FFI `_emitResultDecode`. Same wire format —
/// `[1B tag: 0=ok, 1=err][framed payload]` — read out of the module heap
/// instead of off a pointer. The buffer is malloc'd by native, so it is
/// freed on both branches.
void _emitResultDecode(
  CodeWriter w,
  BridgeSpec spec,
  BridgeFunction func,
  BridgeType type,
  String resVar,
  String indent,
) {
  final base = _bare(type.name);
  w.line('${indent}final _p = dartI64($resVar);');
  // No blob at all (allocation failure): never read a tag at address 0.
  w.line("${indent}if (_p == 0) return NitroErr<${type.name}>('${func.dartName}: the native side returned no result');");
  w.line('${indent}try {');
  final i2 = '$indent  ';
  final carrier = spec.resultCarrier(func);
  w.line('${i2}final _tag = _m.readBytes(_p, 1)[0];');
  // Tag 2: ok, and the value is null. Before the error branch, which takes
  // every other non-zero tag.
  if (carrier case BlockCarrier(isNullable: true)) {
    w.line('${i2}if (_tag == 2) return NitroOk(null);');
  }
  w.line('${i2}if (_tag != 0) {');
  // Explicit type argument: through an untyped callSync/callAsync closure a
  // bare NitroErr infers NitroErr<Object?> and fails callAsync's cast.
  w.line('$i2  return NitroErr<${type.name}>(RecordReader.fromFramedBytes(_m.readFramed(_p + 1)).readString());');
  w.line('$i2}');
  final framed = '_m.readFramed(_p + 1)';
  final (String? reader, String value) = switch (carrier) {
    // Sent as a one-field record (BridgeSpec.resultWrapper): read the field.
    WrappedCarrier() => ('r', dartWrappedResultRead(carrier)),
    BlockCarrier() || RecordCarrier() => (null, _framedDecodeExpr(spec, type, framed)),
    ScalarCarrier(:final kind) => (
      '_r',
      switch (kind) {
        ScalarKind.int64 => '_r.readInt()',
        ScalarKind.float64 => '_r.readDouble()',
        ScalarKind.boolean => '_r.readBool()',
        ScalarKind.string => '_r.readString()',
        ScalarKind.enumValue => '_r.readInt().to$base()',
      },
    ),
    // Rejected by the validator (E015); a spec built by hand still generates.
    NoCarrier() when type.isRecord => (null, _framedDecodeExpr(spec, type, framed)),
    NoCarrier() => (
      '_r',
      switch (base) {
        'uint64' => '_r.readInt()',
        'float' => '_r.readDouble()',
        _ => spec.isStructName(base) ? '${base}StructExt.fromReader(_r)' : '${base}RecordExt.fromReader(_r)',
      },
    ),
  };
  if (reader != null) w.line('${i2}final $reader = RecordReader.fromFramedBytes($framed);');
  w.line('${i2}return NitroOk($value);');
  w.line('$indent} finally {');
  w.line('$indent  _m.nitroFree(_p);');
  w.line('$indent}');
}

void _emitReturnDecode(
  CodeWriter w,
  BridgeSpec spec,
  BridgeType type,
  String resVar,
  String indent, {
  required bool borrowed,
  required bool zeroCopy,
  BridgeFunction? func,
}) {
  // @NitroResult: the C symbol returns [1B tag: 0=ok, 1=err][framed payload].
  // Errors travel in the tag, not the error slot, so this decode replaces the
  // ordinary return path entirely.
  if (func?.isResult ?? false) {
    _emitResultDecode(w, spec, func!, type, resVar, indent);
    return;
  }
  final rt = type.name;
  final rtBase = _bare(rt);
  final nullable = rt.endsWith('?');

  if (rt == 'void') {
    w.line('${indent}return;');
    return;
  }
  switch (rtBase) {
    case 'int':
    case 'uint64':
    case 'DateTime':
      if (nullable) {
        _decodeNullablePrim(w, spec, rtBase, resVar, indent, borrowed);
        return;
      }
      if (rtBase == 'DateTime') {
        w.line('${indent}return DateTime.fromMillisecondsSinceEpoch(dartI64($resVar));');
      } else {
        w.line('${indent}return dartI64($resVar);');
      }
      return;
    case 'double':
      if (nullable) {
        _decodeNullablePrim(w, spec, 'double', resVar, indent, borrowed);
        return;
      }
      w.line('${indent}return ($resVar as JSNumber).toDartDouble;');
      return;
    case 'bool':
      if (nullable) {
        _decodeNullablePrim(w, spec, 'bool', resVar, indent, borrowed);
        return;
      }
      w.line('${indent}return ($resVar as JSNumber).toDartInt != 0;');
      return;
    case 'String':
      // Sync string returns are borrowed (per-thread scratch); async owned.
      if (nullable) {
        w.line('${indent}final _p = dartI64($resVar);');
        w.line('${indent}if (_p == 0) return null;');
        w.line('${indent}final _s = _m.readCString(_p);');
        if (!borrowed) w.line('${indent}_m.nitroFree(_p);');
        w.line('${indent}return _s;');
      } else {
        if (borrowed) {
          w.line('${indent}return _m.readCString(dartI64($resVar));');
        } else {
          w.line('${indent}final _p = dartI64($resVar);');
          w.line('${indent}final _s = _m.readCString(_p);');
          w.line('${indent}_m.nitroFree(_p);');
          w.line('${indent}return _s;');
        }
      }
      return;
    case 'int8':
    case 'int16':
    case 'int32':
    case 'uint8':
    case 'uint16':
    case 'uint32':
    case 'intptr':
    case 'size':
      w.line('${indent}return ($resVar as JSNumber).toDartInt;');
      return;
    case 'float':
      w.line('${indent}return ($resVar as JSNumber).toDartDouble;');
      return;
  }
  if (spec.isEnumName(rtBase)) {
    if (nullable) {
      w.line('${indent}final _v = dartI64($resVar);');
      w.line('${indent}return _v == -1 ? null : _v.to$rtBase();');
    } else {
      w.line('${indent}return dartI64($resVar).to$rtBase();');
    }
    return;
  }
  if (type.isAnyNativeObject || rtBase == 'AnyNativeObject') {
    if (nullable) {
      w.line('${indent}final _id = dartI64($resVar);');
      w.line('${indent}return _id == -1 ? null : AnyNativeObject(_id);');
    } else {
      w.line('${indent}return AnyNativeObject(dartI64($resVar));');
    }
    return;
  }
  if (type.isNativeHandle) {
    final tp = type.nativeHandleTypeParam ?? 'Void';
    w.line('${indent}final _addr = dartI64($resVar);');
    if (nullable) w.line('${indent}if (_addr == 0) return null;');
    w.line('${indent}final _handle = NativeHandle<$tp>.fromAddress(_addr);');
    if (func != null && func.isOwned) {
      w.line("${indent}_handle.attachReleaseCallback((addr) => _m.call('${func.cSymbol}_release', [addr.toJS]));");
    }
    w.line('${indent}return _handle;');
    return;
  }
  if (type.isTypedData) {
    // Wire: [8B byteLength][data] — owned (freed after copy). zeroCopy:
    // [8B byteLength][8B dataAddress] — snapshot then release.
    w.line('${indent}final _ptr = dartI64($resVar);');
    if (nullable) w.line('${indent}if (_ptr == 0) return null;');
    w.line('${indent}final _byteLen = _m.readI64(_ptr);');
    if (zeroCopy) {
      w.line('${indent}final _dataAddr = _m.readI64(_ptr + 8);');
      w.line('${indent}final _bytes = _m.readBytes(_dataAddr, _byteLen);');
      w.line("${indent}_m.call('${spec.lib.replaceAll('-', '_')}_release_typed_data_return', [_ptr.toJS]);");
    } else {
      w.line('${indent}final _bytes = _m.readBytes(_ptr + 8, _byteLen);');
      w.line('${indent}_m.nitroFree(_ptr);');
    }
    w.line('${indent}return ${_typedDataFromBytes(rtBase, '_bytes')};');
    return;
  }
  if (spec.isStructName(rtBase)) {
    // Sync struct returns are owned heap structs with a release fn.
    w.line('${indent}final _ptr = dartI64($resVar);');
    if (nullable) w.line('${indent}if (_ptr == 0) return null;');
    w.line('${indent}final _v = ${_structReadCall(spec, rtBase, '_ptr')};');
    w.line("${indent}_m.call('${spec.lib.replaceAll('-', '_')}_release_$rtBase', [_ptr.toJS]);");
    w.line('${indent}return _v;');
    return;
  }
  if (spec.isCustomTypeName(rtBase)) {
    // Custom-type returns are owned on both sync and async paths (the FFI
    // decode frees them with _nitroFree).
    final ct = spec.customTypeByName(rtBase)!;
    w.line('${indent}final _ptr = dartI64($resVar);');
    if (nullable) w.line('${indent}if (_ptr == 0) return null;');
    w.line('${indent}final _bytes = _m.readBytes(_ptr, const ${ct.codecClass}().encodedSize);');
    w.line('${indent}_m.nitroFree(_ptr);');
    final bang = nullable ? '' : '!';
    w.line('${indent}return const ${ct.codecClass}().decodeBytes(_bytes)$bang;');
    return;
  }
  // Framed blobs (records, variants, maps, AnyMap, tuples, lists) are OWNED
  // on both sync and async paths — the impl mallocs them and the FFI decode
  // frees them; only C strings and nullable-prim scratch are borrowed.
  w.line('${indent}final _ptr = dartI64($resVar);');
  if (nullable) w.line('${indent}if (_ptr == 0) return null;');
  w.line('${indent}final _framed = _m.readFramed(_ptr);');
  w.line('${indent}_m.nitroFree(_ptr);');
  w.line('${indent}return ${_framedDecodeExpr(spec, type, '_framed')};');
}

void _decodeNullablePrim(CodeWriter w, BridgeSpec spec, String base, String resVar, String indent, bool borrowed) {
  // C returns uint8_t* to the packed NitroOpt* layout (borrowed on sync).
  final codec = base == 'double' ? 'NitroDoubleWireCodec' : (base == 'bool' ? 'NitroBoolWireCodec' : 'NitroIntWireCodec');
  final size = base == 'bool' ? 2 : 9;
  w.line('${indent}final _p = dartI64($resVar);');
  w.line('${indent}if (_p == 0) return null;');
  w.line('${indent}final _bytes = _m.readBytes(_p, $size);');
  if (!borrowed) w.line('${indent}_m.nitroFree(_p);');
  if (base == 'DateTime') {
    w.line('${indent}final _ms = const NitroIntWireCodec().decodeBytes(_bytes);');
    w.line('${indent}return _ms != null ? DateTime.fromMillisecondsSinceEpoch(_ms) : null;');
  } else {
    w.line('${indent}return const $codec().decodeBytes(_bytes);');
  }
}

/// Decode expression for a framed byte buffer (after the bulk copy).
String _framedDecodeExpr(BridgeSpec spec, BridgeType type, String framedVar) {
  final base = _bare(type.name);
  if (type.isAnyMap || base == 'NitroAnyMap') {
    return 'NitroAnyMap.readFrom(RecordReader.fromFramedBytes($framedVar))';
  }
  if (type.isTuple) {
    return '_nitroDecodeTuple_$base($framedVar)';
  }
  if (type.isMap) {
    return '_nitroDecodeMapBytes${_mapHelperSuffix(spec, base)}($framedVar)';
  }
  if (type.recordListItemType != null) {
    final item = type.recordListItemType!;
    // Mirrors the encode side: nullable items carry a per-entry presence
    // flag, so they need the nullable reader or every item after the first
    // shifts by a byte.
    final nullableItems = type.recordListItemIsNullable;
    if (type.isEnumList) {
      final read = 'r.readInt().to$item()';
      return nullableItems ? 'RecordReader.decodeNullableListBytes($framedVar, (r) => $read)' : 'RecordReader.decodeListBytes($framedVar, (r) => $read)';
    }
    if (type.recordListItemIsPrimitive) {
      final readCall = switch (item) {
        'int' => 'r.readInt()',
        'double' => 'r.readDouble()',
        'bool' => 'r.readBool()',
        'String' => 'r.readString()',
        _ => 'r.readInt()',
      };
      return 'RecordReader.decodeListBytes($framedVar, (r) => $readCall)';
    }
    if (spec.isVariantName(item)) {
      final read = '${item}VariantExt.fromReader(r)';
      return nullableItems ? 'RecordReader.decodeNullableListBytes($framedVar, (r) => $read)' : 'RecordReader.decodeListBytes($framedVar, (r) => $read)';
    }
    // Indexed record lists ([4B count][offset table][items]) are produced by
    // encodeIndexedList on native returns; web decodes them eagerly.
    return 'RecordReader.decodeIndexedListBytes($framedVar, (r) => ${item}RecordExt.fromReader(r))';
  }
  if (spec.isVariantName(base)) {
    return '${base}VariantExt.fromReader(RecordReader.fromFramedBytes($framedVar))';
  }
  const libraryRecords = {'NitroNullableInt', 'NitroNullableDouble', 'NitroNullableBool'};
  if (libraryRecords.contains(base)) {
    return '$base.fromReader(RecordReader.fromFramedBytes($framedVar))';
  }
  // Records (and struct-shaped records).
  return '${base}RecordExt.fromReader(RecordReader.fromFramedBytes($framedVar))';
}

String _typedDataFromBytes(String dartType, String bytesVar) {
  if (dartType == 'Uint8List') return bytesVar;
  final viewCtor = switch (dartType) {
    'Int8List' => 'Int8List.view',
    'Int16List' => 'Int16List.view',
    'Uint16List' => 'Uint16List.view',
    'Int32List' => 'Int32List.view',
    'Uint32List' => 'Uint32List.view',
    'Int64List' => 'Int64List.view',
    'Uint64List' => 'Uint64List.view',
    'Float32List' => 'Float32List.view',
    'Float64List' => 'Float64List.view',
    _ => 'Uint8List.view',
  };
  return '$viewCtor($bytesVar.buffer, $bytesVar.offsetInBytes, $bytesVar.lengthInBytes ~/ ${_typedDataElementSizeWeb(dartType)})';
}

int _typedDataElementSizeWeb(String dartType) => switch (dartType) {
  'Uint8List' || 'Int8List' => 1,
  'Int16List' || 'Uint16List' => 2,
  'Int32List' || 'Uint32List' || 'Float32List' => 4,
  _ => 8,
};
