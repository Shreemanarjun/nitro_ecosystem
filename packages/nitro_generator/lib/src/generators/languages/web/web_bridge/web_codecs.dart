part of '../web_bridge_generator.dart';

// Top-level codec helpers of the generated web library: framed encoders,
// nullable variants, tuples and maps (see map_wire.dart for the map wire).

void _emitWebHelpers(CodeWriter w, BridgeSpec spec) {
  w.line('// ── Wire helpers (web) ──────────────────────────────────────────────────');
  w.blankLine();
  w.line('Uint8List _nitroEncodeFramed(void Function(RecordWriter w) write) {');
  w.line('  final w = RecordWriter();');
  w.line('  write(w);');
  w.line('  return w.takeFramedBytes();');
  w.line('}');
  w.blankLine();

  _emitStructCodecs(w, spec);
  _emitVariantNullableEncoders(w, spec);
  _emitTupleCodecs(w, spec);
  _emitMapCodecs(w, spec);
  _emitCallbackHelpers(w, spec);
}

void _emitVariantNullableEncoders(CodeWriter w, BridgeSpec spec) {
  final used = <String>{};
  void addType(BridgeType t) {
    final base = _bare(t.name);
    if (spec.isVariantName(base) && (t.name.endsWith('?') || (spec.variantByName(base)!.cases.any((c) => c.name.toLowerCase() == 'null')))) {
      used.add(base);
    }
  }

  for (final f in spec.functions) {
    addType(f.returnType);
    for (final p in f.params) {
      addType(p.type);
    }
  }
  for (final p in spec.properties) {
    addType(p.type);
  }

  for (final name in used) {
    final variant = spec.variantByName(name)!;
    final nullTag = variant.cases.indexWhere((c) => c.name.toLowerCase() == 'null');
    w.line('Uint8List _nitroEncodeVariantNullable$name($name? value) {');
    w.line('  final w = RecordWriter();');
    if (nullTag >= 0) {
      w.line('  if (value == null) {');
      w.line('    w.writeInt8($nullTag);');
      w.line('  } else {');
      w.line('    value.writeFields(w);');
      w.line('  }');
    } else {
      w.line("  if (value == null) { throw ArgumentError('$name has no null case'); }");
      w.line('  value.writeFields(w);');
    }
    w.line('  return w.takeFramedBytes();');
    w.line('}');
    w.blankLine();
  }
}

void _emitTupleCodecs(CodeWriter w, BridgeSpec spec) {
  final tuples = spec.localRecordTypes.where((r) => r.isTuple).toList();
  for (final rt in tuples) {
    final fieldTypes = rt.fields
        .map((f) {
          if (f.isNullable) return '${f.dartType.replaceFirst("?", "")}?';
          return f.dartType;
        })
        .join(', ');
    final tupleType = '($fieldTypes)';

    w.line('$tupleType _nitroDecodeTuple_${rt.name}(Uint8List framed) {');
    w.line('  final r = RecordReader.fromFramedBytes(framed);');
    final reads = rt.fields.map((f) => _tupleFieldReadExpr(spec, f)).join(', ');
    w.line('  return ($reads);');
    w.line('}');
    w.blankLine();

    w.line('Uint8List _nitroEncodeTuple_${rt.name}($tupleType v) {');
    w.line('  final w = RecordWriter();');
    for (var i = 0; i < rt.fields.length; i++) {
      _emitTupleFieldWrite(w, spec, rt.fields[i], i + 1);
    }
    w.line('  return w.takeFramedBytes();');
    w.line('}');
    w.blankLine();
  }
}

String _tupleFieldReadExpr(BridgeSpec spec, BridgeRecordField f) {
  final base = _bare(f.dartType);
  String inner;
  switch (f.kind) {
    case RecordFieldKind.primitive:
      inner = switch (base) {
        'int' => 'r.readInt()',
        'double' => 'r.readDouble()',
        'bool' => 'r.readBool()',
        'String' => 'r.readString()',
        'Uint8List' => 'r.readBlob()',
        _ => 'r.readInt()',
      };
    case RecordFieldKind.enumValue:
      inner = 'r.readInt().to$base()';
    case RecordFieldKind.recordObject || RecordFieldKind.struct:
      inner = '${base}RecordExt.fromReader(r)';
    case RecordFieldKind.listPrimitive:
      final item = f.itemTypeName ?? 'int';
      final read = switch (item) {
        'int' => 'r.readInt()',
        'double' => 'r.readDouble()',
        'bool' => 'r.readBool()',
        'String' => 'r.readString()',
        _ => 'r.readInt()',
      };
      inner = 'List.generate(r.readInt32(), (_) => $read)';
    case RecordFieldKind.listEnumValue:
      inner = 'List.generate(r.readInt32(), (_) => r.readInt().to${f.itemTypeName}())';
    case RecordFieldKind.listRecordObject:
      inner = 'List.generate(r.readInt32(), (_) => ${f.itemTypeName}RecordExt.fromReader(r))';
    case RecordFieldKind.typedData:
      inner = base == 'Uint8List' ? 'r.readBlob()' : '$base.view(r.readBlob().buffer)';
  }
  if (f.isNullable) return 'r.readNullTag() ? null : $inner';
  return inner;
}

void _emitTupleFieldWrite(CodeWriter w, BridgeSpec spec, BridgeRecordField f, int index) {
  final accessor = 'v.\$$index';
  final base = _bare(f.dartType);
  if (f.isNullable) {
    w.line('  w.writeNullTag($accessor == null);');
    w.line('  if ($accessor != null) {');
    w.line('    ${_tupleFieldWriteStmt(spec, f, '$accessor!', base)}');
    w.line('  }');
    return;
  }
  w.line('  ${_tupleFieldWriteStmt(spec, f, accessor, base)}');
}

String _tupleFieldWriteStmt(BridgeSpec spec, BridgeRecordField f, String expr, String base) {
  switch (f.kind) {
    case RecordFieldKind.primitive:
      return switch (base) {
        'int' => 'w.writeInt($expr);',
        'double' => 'w.writeDouble($expr);',
        'bool' => 'w.writeBool($expr);',
        'String' => 'w.writeString($expr);',
        'Uint8List' => 'w.writeBlob($expr);',
        _ => 'w.writeInt($expr);',
      };
    case RecordFieldKind.enumValue:
      return 'w.writeInt($expr.nativeValue);';
    case RecordFieldKind.recordObject || RecordFieldKind.struct:
      return '$expr.writeFields(w);';
    case RecordFieldKind.listPrimitive:
      final item = f.itemTypeName ?? 'int';
      final writeCall = switch (item) {
        'int' => 'w.writeInt(e)',
        'double' => 'w.writeDouble(e)',
        'bool' => 'w.writeBool(e)',
        'String' => 'w.writeString(e)',
        _ => 'w.writeInt(e)',
      };
      return 'w.writeInt32($expr.length); for (final e in $expr) { $writeCall; }';
    case RecordFieldKind.listEnumValue:
      return 'w.writeInt32($expr.length); for (final e in $expr) { w.writeInt(e.nativeValue); }';
    case RecordFieldKind.listRecordObject:
      return 'w.writeInt32($expr.length); for (final e in $expr) { e.writeFields(w); }';
    case RecordFieldKind.typedData:
      // Bound to the VIEW: a shared backing buffer would otherwise be
      // serialised whole (see the struct codec, which already does this).
      final toBytes = base == 'Uint8List' ? expr : '$expr.buffer.asUint8List($expr.offsetInBytes, $expr.lengthInBytes)';
      return 'w.writeBlob($toBytes);';
  }
}

void _emitMapCodecs(CodeWriter w, BridgeSpec spec) {
  final mapTypes = <String>{};
  void addType(BridgeType t) {
    final base = _bare(t.name);
    if (t.isMap && !t.isAnyMap) mapTypes.add(base);
  }

  for (final f in spec.functions) {
    addType(f.returnType);
    for (final p in f.params) {
      addType(p.type);
    }
  }
  for (final p in spec.properties) {
    addType(p.type);
  }

  for (final mapType in mapTypes) {
    final (keyType, valueType) = _mapKeyValue(mapType);
    final suffix = _mapHelperSuffix(spec, mapType);
    final isIntKey = keyType != 'String';
    final keyIsEnum = spec.isEnumName(keyType);

    // ── Encode ──
    w.line('Uint8List _nitroEncodeMapBytes$suffix($mapType m) {');
    w.line('  final w = RecordWriter();');
    w.line('  w.writeInt32(m.length);');
    w.line('  for (final e in m.entries) {');
    if (!isIntKey) {
      w.line('    w.writeString(e.key);');
    } else if (keyIsEnum) {
      w.line('    ${_intKeyWrite(spec, keyType, 'e.key.nativeValue')}');
    } else {
      w.line('    ${_intKeyWrite(spec, keyType, 'e.key')}');
    }
    // String-key maps tag every value; int-key maps are tag-less.
    _emitMapValueWrite(w, spec, valueType, tagged: !isIntKey);
    w.line('  }');
    w.line('  return w.takeFramedBytes();');
    w.line('}');
    w.blankLine();

    // ── Decode ──
    w.line('$mapType _nitroDecodeMapBytes$suffix(Uint8List framed) {');
    w.line('  final r = RecordReader.fromFramedBytes(framed);');
    w.line('  final count = r.readInt32();');
    w.line('  final result = <$keyType, $valueType>{};');
    w.line('  for (var i = 0; i < count; i++) {');
    if (!isIntKey) {
      w.line('    final key = r.readString();');
    } else if (keyIsEnum) {
      w.line('    final key = ${_intKeyRead(spec, keyType)}.to$keyType();');
    } else {
      w.line('    final key = ${_intKeyRead(spec, keyType)};');
    }
    _emitMapValueRead(w, spec, valueType, tagged: !isIntKey);
    w.line('    result[key] = v;');
    w.line('  }');
    w.line('  return result;');
    w.line('}');
    w.blankLine();
  }
}

/// Map value wire, mirroring the native helpers exactly.
///
/// String-key maps TAG every value (0=null, 1=int64, 2=f64, 3=bool,
/// 4=string, 5=record/variant blob); int-key maps are tag-less. Record/variant blobs
/// are `[4B blob_len][framed bytes]` — the framed bytes keep their own
/// inner 4B length prefix.
void _emitMapValueWrite(CodeWriter w, BridgeSpec spec, String valueType, {required bool tagged}) {
  void tag(int t) {
    if (tagged) w.line('    w.writeInt8($t);');
  }

  // Bound to a local: `e.value` is a public getter, which Dart will not
  // promote to non-null after the guard.
  var valueExpr = 'e.value';
  if (valueType.endsWith('?')) {
    w.line('    final _v = e.value;');
    w.line('    if (_v == null) { w.writeInt8(${MapValueWire.nul.tag}); continue; }');
    valueType = valueType.substring(0, valueType.length - 1);
    valueExpr = '_v';
  }
  tag(_wireOf(spec, valueType).tag);
  switch (valueType) {
    case 'int':
      w.line('    w.writeInt($valueExpr);');
    case 'double':
      w.line('    w.writeDouble($valueExpr);');
    case 'bool':
      w.line('    w.writeBool($valueExpr);');
    case 'String':
      w.line('    w.writeString($valueExpr);');
    case final t when spec.isEnumName(t):
      w.line('    w.writeInt($valueExpr.nativeValue);');
    case final t when spec.isRecordName(t) || spec.isVariantName(t) || spec.isStructName(t):
      w.line('    w.writeBlob(_nitroEncodeFramed((rw) => $valueExpr.writeFields(rw)));');
    default:
      w.line('    w.writeString(jsonEncode($valueExpr));');
  }
}

void _emitMapValueRead(CodeWriter w, BridgeSpec spec, String valueType, {required bool tagged}) {
  if (valueType.endsWith('?')) {
    w.line('    if (r.readInt8() == ${MapValueWire.nul.tag}) { result[key] = null; continue; }');
    valueType = valueType.substring(0, valueType.length - 1);
  } else if (tagged) {
    w.line('    r.readInt8(); // skip the value type tag');
  }
  switch (valueType) {
    case 'int':
      w.line('    final v = r.readInt();');
    case 'double':
      w.line('    final v = r.readDouble();');
    case 'bool':
      w.line('    final v = r.readBool();');
    case 'String':
      w.line('    final v = r.readString();');
    case final t when spec.isEnumName(t):
      w.line('    final v = r.readInt().to$t();');
    // A @HybridStruct's byte codec is its RecordExt too.
    case final t when spec.isRecordName(t) || spec.isStructName(t):
      w.line('    final v = ${t}RecordExt.fromReader(RecordReader.fromFramedBytes(r.readBlob()));');
    case final t when spec.isVariantName(t):
      w.line('    final v = ${t}VariantExt.fromReader(RecordReader.fromFramedBytes(r.readBlob()));');
    default:
      w.line('    final v = jsonDecode(r.readString()) as $valueType;');
  }
}

String _intKeyWrite(BridgeSpec spec, String keyType, String expr) {
  final size = _intKeyByteSizeWeb(spec, keyType);
  return switch (size) {
    1 => 'w.writeInt8($expr);',
    4 => 'w.writeInt32($expr);',
    _ => 'w.writeInt($expr);',
  };
}

String _intKeyRead(BridgeSpec spec, String keyType) {
  final size = _intKeyByteSizeWeb(spec, keyType);
  return switch (size) {
    1 => 'r.readInt8()',
    4 => 'r.readInt32()',
    _ => 'r.readInt()',
  };
}

int _intKeyByteSizeWeb(BridgeSpec spec, String keyType) {
  if (spec.isEnumName(keyType)) return 8;
  return switch (keyType) {
    'int8' || 'uint8' => 1,
    'int16' || 'uint16' => 2,
    'int32' || 'uint32' => 4,
    _ => 8,
  };
}

/// Strips a TRAILING '?' only. replaceFirst would eat the inner one in
/// `Map<String, int?>` and silently drop the value's nullability.
MapValueWire _wireOf(BridgeSpec spec, String valueType) => mapValueWireOf(
  valueType,
  isEnum: spec.isEnumName,
  isRecord: spec.isRecordName,
  isVariant: spec.isVariantName,
  isStruct: spec.isStructName,
);

String _bare(String t) => t.endsWith('?') ? t.substring(0, t.length - 1) : t;

(String, String) _mapKeyValue(String mapTypeName) {
  final lt = mapTypeName.indexOf('<');
  final gt = mapTypeName.lastIndexOf('>');
  if (lt < 0 || gt < 0) return ('String', 'dynamic');
  final inner = mapTypeName.substring(lt + 1, gt);
  final comma = inner.indexOf(',');
  if (comma < 0) return ('String', 'dynamic');
  return (inner.substring(0, comma).trim(), inner.substring(comma + 1).trim());
}

String _mapHelperSuffix(BridgeSpec spec, String mapTypeName) {
  final (k, v) = _mapKeyValue(mapTypeName);
  String capName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return cleaned.isEmpty ? 'Dynamic' : cleaned[0].toUpperCase() + cleaned.substring(1);
  }

  return '${capName(k)}${capName(v)}${v.endsWith('?') ? 'Nullable' : ''}';
}
