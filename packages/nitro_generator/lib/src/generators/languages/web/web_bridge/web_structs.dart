part of '../web_bridge_generator.dart';

// @HybridStruct on wasm32: the field layout, and the read / write of a
// struct in the module heap.

/// Field names treated as an explicit element-count companion for a
/// zero-copy TypedData sibling. Mirrors struct_generator.dart — the two must
/// agree or the web layout drifts from the C typedef.
const _kLenFieldNames = {'length', 'size', 'stride', 'bytelength', 'bytelen', 'len'};

bool _structNeedsSyntheticLen(BridgeStruct st, String field) {
  for (final c in ['${field}Length', '${field}Size']) {
    if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return false;
  }
  return !st.fields.any((f) => _kLenFieldNames.contains(f.name) && f.type.name == 'int');
}

/// (size, align) of one struct field slot on wasm32. Pointers are 4/4;
/// int64/double are 8/8; bool is 1/1. Null = not representable on web.
(int, int)? _fieldSlot(BridgeSpec spec, BridgeType t) {
  final base = _bare(t.name);
  return switch (base) {
    // Every pointer-shaped field is a 4-byte wasm32 slot: TypedData buffers
    // (`uint8_t*`), strings (`const char*`) and NESTED STRUCTS, which the C
    // typedef stores as `Nested*`, not inline.
    'String' => (4, 4),
    _ when t.isTypedData || spec.isStructName(base) => (4, 4),
    _ when spec.isEnumName(base) => (4, 4), // C enum field is int32_t
    'int' || 'uint64' || 'DateTime' || 'double' => (8, 8),
    'bool' => (1, 1),
    _ => null,
  };
}

/// Byte offsets for every slot plus the total size. Honours `st.packed`,
/// which the C emitter turns into `#pragma pack(1)`: packed structs are
/// tight, unpacked ones follow natural C alignment — each member starts at
/// a multiple of its own alignment and the struct is rounded up to its
/// strictest member. A
/// zero-copy TypedData field occupies TWO slots — the pointer and, unless
/// the spec declares a companion length field, a synthesized int64 count.
/// Returns null when any field kind is not representable on web.
({Map<String, int> at, Map<String, int> lenAt, Map<String, int> hasAt, int size})? _structLayout(BridgeSpec spec, BridgeStruct st) {
  final at = <String, int>{};
  final lenAt = <String, int>{};
  final hasAt = <String, int>{};
  var off = 0;
  var maxAlign = 1;
  for (final f in st.fields) {
    final slot = _fieldSlot(spec, f.type);
    if (slot == null) return null;
    final (sz, rawAl) = slot;
    final al = st.packed ? 1 : rawAl;
    off = _alignUp(off, al);
    at[f.name] = off;
    off += sz;
    if (al > maxAlign) maxAlign = al;
    if (f.type.isTypedData && _structNeedsSyntheticLen(st, f.name)) {
      off = _alignUp(off, st.packed ? 1 : 8); // int64_t <name>Length
      lenAt[f.name] = off;
      off += 8;
      if (!st.packed && maxAlign < 8) maxAlign = 8;
    }
    // int8_t <name>HasValue — the presence byte for a nullable scalar/enum.
    // Alignment 1, so no padding of its own, but it shifts everything after.
    if (StructGenerator.needsHasValue(f, spec.structs.map((x) => x.name).toSet())) {
      hasAt[f.name] = off;
      off += 1;
    }
  }
  return (at: at, lenAt: lenAt, hasAt: hasAt, size: _alignUp(off, maxAlign));
}

int _alignUp(int v, int a) => (v + a - 1) & ~(a - 1);

void _emitStructCodecs(CodeWriter w, BridgeSpec spec) {
  final used = _usedStructs(spec);
  for (final stName in used) {
    final st = spec.structByName(stName);
    if (st == null) continue;
    final layout = _structLayout(spec, st);

    // Pack (Dart → heap bytes). Takes the arena because a TypedData field
    // stores a POINTER into module memory, not the bytes inline.
    w.line('Uint8List _nitroPackStruct$stName(NitroWasmModule m, WasmArena arena, $stName v) {');
    if (layout == null) {
      w.line("  throw UnsupportedError('$stName: has a field kind with no wasm32 struct layout on web');");
      w.line('}');
      w.blankLine();
      continue;
    }
    w.line('  final out = Uint8List(${layout.size});');
    w.line('  final bd = ByteData.sublistView(out);');
    for (final f in st.fields) {
      final base = _bare(f.type.name);
      final off = layout.at[f.name]!;
      // A nullable scalar/enum carries its value in the normal slot plus a
      // synthesized presence byte; the slot is zeroed when absent.
      final hasOff = layout.hasAt[f.name];
      if (hasOff != null) {
        final zero = base == 'double' || base == 'float' ? '0.0' : '0';
        final payload = switch (base) {
          'bool' => '(v.${f.name}! ? 1 : 0)',
          _ when spec.isEnumName(base) => 'v.${f.name}!.nativeValue',
          _ => 'v.${f.name}!',
        };
        w.line('  bd.setUint8($hasOff, v.${f.name} == null ? 0 : 1);');
        w.line('  ${_structScalarWrite(spec, base, off, 'v.${f.name} == null ? $zero : $payload')}');
        continue;
      }
      switch (base) {
        case _ when f.type.isTypedData:
          final bytes = base == 'Uint8List' ? 'v.${f.name}' : 'v.${f.name}.buffer.asUint8List(v.${f.name}.offsetInBytes, v.${f.name}.lengthInBytes)';
          w.line('  bd.setUint32($off, arena.copyIn($bytes), Endian.little);');
          final lenOff = layout.lenAt[f.name];
          if (lenOff != null) w.line('  setInt64LE(bd, $lenOff, v.${f.name}.length);');
        case 'String':
          final e = f.type.name.endsWith('?') ? "v.${f.name} == null ? 0 : arena.cString(v.${f.name}!)" : 'arena.cString(v.${f.name})';
          w.line('  bd.setUint32($off, $e, Endian.little);');
        case _ when spec.isStructName(base):
          final e = f.type.name.endsWith('?') ? "v.${f.name} == null ? 0 : arena.copyIn(_nitroPackStruct$base(m, arena, v.${f.name}!))" : 'arena.copyIn(_nitroPackStruct$base(m, arena, v.${f.name}))';
          w.line('  bd.setUint32($off, $e, Endian.little);');
        case _ when spec.isEnumName(base):
          w.line('  bd.setInt32($off, v.${f.name}.nativeValue, Endian.little);');
        case 'int' || 'uint64':
          w.line('  setInt64LE(bd, $off, v.${f.name});');
        case 'DateTime':
          w.line('  setInt64LE(bd, $off, v.${f.name}.millisecondsSinceEpoch);');
        case 'double':
          w.line('  bd.setFloat64($off, v.${f.name}, Endian.little);');
        default:
          w.line('  bd.setUint8($off, v.${f.name} ? 1 : 0);');
      }
    }
    w.line('  return out;');
    w.line('}');
    w.blankLine();

    // Read (heap offset → Dart value).
    w.line('$stName _nitroReadStruct$stName(NitroWasmModule m, int ptr) {');
    w.line('  final bd = ByteData.sublistView(m.readBytes(ptr, ${layout.size}));');
    final args = <String>[];
    for (final f in st.fields) {
      final base = _bare(f.type.name);
      final off = layout.at[f.name]!;
      String expr;
      final hasOff = layout.hasAt[f.name];
      if (hasOff != null) {
        final decoded = switch (base) {
          'bool' => 'bd.getUint8($off) != 0',
          _ when spec.isEnumName(base) => 'bd.getInt32($off, Endian.little).to$base()',
          'double' || 'float' => 'bd.getFloat64($off, Endian.little)',
          _ => 'getInt64LE(bd, $off)',
        };
        args.add('${f.name}: bd.getUint8($hasOff) != 0 ? $decoded : null');
        continue;
      }
      switch (base) {
        case _ when f.type.isTypedData:
          final elem = _typedDataElementSizeWeb(base);
          final synthLen = layout.lenAt[f.name];
          final lenExpr = synthLen != null ? 'getInt64LE(bd, $synthLen)' : 'getInt64LE(bd, ${layout.at[_structCompanionLen(st, f.name)!]!})';
          w.line('  final _p${f.name} = bd.getUint32($off, Endian.little);');
          w.line('  final _n${f.name} = $lenExpr;');
          final read = 'm.readBytes(_p${f.name}, _n${f.name} * $elem)';
          expr = base == 'Uint8List' ? '(_p${f.name} == 0 ? Uint8List(0) : $read)' : '(_p${f.name} == 0 ? $base(0) : ${_typedDataViewExpr(base, '_b${f.name}')})';
          if (base != 'Uint8List') {
            w.line('  final _b${f.name} = _p${f.name} == 0 ? Uint8List(0) : $read;');
          }
        case 'String':
          final p = 'bd.getUint32($off, Endian.little)';
          expr = f.type.name.endsWith('?') ? '(() { final _p = $p; return _p == 0 ? null : m.readCString(_p); })()' : "(() { final _p = $p; return _p == 0 ? '' : m.readCString(_p); })()";
        case _ when spec.isStructName(base):
          final p = 'bd.getUint32($off, Endian.little)';
          expr = f.type.name.endsWith('?') ? '(() { final _p = $p; return _p == 0 ? null : _nitroReadStruct$base(m, _p); })()' : '_nitroReadStruct$base(m, $p)';
        case _ when spec.isEnumName(base):
          expr = 'bd.getInt32($off, Endian.little).to$base()';
        case 'int' || 'uint64':
          expr = 'getInt64LE(bd, $off)';
        case 'DateTime':
          expr = 'DateTime.fromMillisecondsSinceEpoch(getInt64LE(bd, $off))';
        case 'double':
          expr = 'bd.getFloat64($off, Endian.little)';
        default:
          expr = 'bd.getUint8($off) != 0';
      }
      args.add('${f.name}: $expr');
    }
    w.line('  return $stName(${args.join(', ')});');
    w.line('}');
    w.blankLine();
  }
}

/// The spec-declared companion element-count field for [field], or null.
String? _structCompanionLen(BridgeStruct st, String field) {
  for (final c in ['${field}Length', '${field}Size']) {
    if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return c;
  }
  for (final f in st.fields) {
    if (_kLenFieldNames.contains(f.name) && f.type.name == 'int') return f.name;
  }
  return null;
}

String _typedDataViewExpr(String dartType, String bytesVar) => '${_typedDataViewCtor(dartType)}($bytesVar.buffer, $bytesVar.offsetInBytes, $bytesVar.lengthInBytes ~/ ${_typedDataElementSizeWeb(dartType)})';

String _typedDataViewCtor(String dartType) => '$dartType.view';

Set<String> _usedStructs(BridgeSpec spec) {
  final used = <String>{};
  void addType(BridgeType t) {
    final base = _bare(t.name);
    if (spec.isStructName(base)) used.add(base);
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
  for (final s in spec.streams) {
    addType(s.itemType);
  }
  // Transitive: a struct reached only as another struct's field still needs
  // its codec emitted. The set doubles as the cycle guard.
  var frontier = used.toList();
  while (frontier.isNotEmpty) {
    final next = <String>[];
    for (final name in frontier) {
      for (final f in spec.structByName(name)?.fields ?? const <BridgeField>[]) {
        final b = _bare(f.type.name);
        if (spec.isStructName(b) && used.add(b)) next.add(b);
      }
    }
    frontier = next;
  }
  return used;
}

String _structReadCall(BridgeSpec spec, String stName, String ptrVar) => '_nitroReadStruct$stName(_m, $ptrVar)';

/// Emits the scalar write for a struct slot, matching the non-nullable
/// arms below — used by the nullable path, which supplies its own value
/// expression.
String _structScalarWrite(BridgeSpec spec, String base, int off, String value) => switch (base) {
  _ when spec.isEnumName(base) => 'bd.setInt32($off, $value, Endian.little);',
  'int' || 'uint64' || 'int64' || 'DateTime' => 'setInt64LE(bd, $off, $value);',
  'double' || 'float' => 'bd.setFloat64($off, $value, Endian.little);',
  _ => 'bd.setUint8($off, $value);',
};
