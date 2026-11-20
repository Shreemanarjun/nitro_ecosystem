part of '../web_bridge_generator.dart';

// Dart value → JS call argument: scalars, strings, typed data, structs and
// framed records copied into the module heap.

/// The JS argument expression for one parameter, mirroring the C signature.
String _jsArgExpr(BridgeSpec spec, BridgeType t, String name, String ownerFn) {
  final base = _bare(t.name);
  final nullable = t.name.endsWith('?');

  if (t.isFunction) return _callbackArgExpr(spec, t, name, ownerFn);
  // Pointer/NativeHandle params are typed `dynamic` in the override — cast
  // the duck-typed .address back to int so the .toJS extension applies.
  if (t.isNativeHandle || t.isPointer) {
    return t.name.endsWith('?') ? '(($name as dynamic)?.address as int? ?? 0).toJS' : '(($name as dynamic).address as int).toJS';
  }
  if (t.isAnyNativeObject) {
    return nullable ? 'jsI64($name?.instanceId ?? -1)' : 'jsI64($name.instanceId)';
  }
  if (spec.isCustomTypeName(base)) {
    final ct = spec.customTypeByName(base)!;
    return 'arena.copyIn(const ${ct.codecClass}().encodeBytes($name)).toJS';
  }
  if (nullable && (base == 'int' || base == 'uint64' || base == 'DateTime')) {
    final expr = base == 'DateTime' ? '$name?.millisecondsSinceEpoch' : name;
    return 'arena.copyIn(const NitroIntWireCodec().encodeBytes($expr)).toJS';
  }
  if (nullable && base == 'double') {
    return 'arena.copyIn(const NitroDoubleWireCodec().encodeBytes($name)).toJS';
  }
  if (nullable && base == 'bool') {
    return 'arena.copyIn(const NitroBoolWireCodec().encodeBytes($name)).toJS';
  }
  switch (base) {
    case 'int':
    case 'uint64':
      return 'jsI64($name)';
    case 'DateTime':
      return 'jsI64($name.millisecondsSinceEpoch)';
    case 'double':
      return '$name.toJS';
    case 'bool':
      return '($name ? 1 : 0).toJS';
    case 'String':
      return nullable ? '($name == null ? 0 : arena.cString($name)).toJS' : 'arena.cString($name).toJS';
    case 'int8':
    case 'int16':
    case 'int32':
    case 'uint8':
    case 'uint16':
    case 'uint32':
    case 'intptr':
    case 'size':
      return '$name.toJS';
    case 'float':
      return '$name.toJS';
  }
  if (spec.isEnumName(base)) {
    return nullable ? 'jsI64($name == null ? -1 : $name.nativeValue)' : 'jsI64($name.nativeValue)';
  }
  if (t.isTypedData) {
    if (nullable) {
      // The null check above promotes the parameter; no `!` needed.
      final bytes = base == 'Uint8List' ? name : '$name.buffer.asUint8List($name.offsetInBytes, $name.lengthInBytes)';
      return '($name == null ? 0 : arena.copyIn($bytes)).toJS';
    }
    final bytes = base == 'Uint8List' ? name : '$name.buffer.asUint8List($name.offsetInBytes, $name.lengthInBytes)';
    return 'arena.copyIn($bytes).toJS';
  }
  if (spec.isStructName(base)) {
    // Pack takes the arena: a TypedData field stores a pointer.
    return nullable ? '($name == null ? 0 : arena.copyIn(_nitroPackStruct$base(_m, arena, $name))).toJS' : 'arena.copyIn(_nitroPackStruct$base(_m, arena, $name)).toJS';
  }
  if (spec.isVariantName(base)) {
    final variant = spec.variantByName(base)!;
    final nullTag = variant.cases.indexWhere((c) => c.name.toLowerCase() == 'null');
    if (nullable || nullTag >= 0) {
      return 'arena.copyIn(_nitroEncodeVariantNullable$base($name)).toJS';
    }
    return 'arena.copyIn(_nitroEncodeFramed((w) => $name.writeFields(w))).toJS';
  }
  if (t.isAnyMap || base == 'NitroAnyMap') {
    return nullable ? '($name == null ? 0 : arena.copyIn(_nitroEncodeFramed($name.writeTo))).toJS' : 'arena.copyIn(_nitroEncodeFramed($name.writeTo)).toJS';
  }
  if (t.isTuple) {
    // A nullable tuple passes 0 for "absent" like every other framed param;
    // the encoder itself declares the non-null record type.
    return nullable ? '($name == null ? 0 : arena.copyIn(_nitroEncodeTuple_$base($name))).toJS' : 'arena.copyIn(_nitroEncodeTuple_$base($name)).toJS';
  }
  if (t.isMap) {
    final suffix = _mapHelperSuffix(spec, base);
    return nullable ? '($name == null ? 0 : arena.copyIn(_nitroEncodeMapBytes$suffix($name))).toJS' : 'arena.copyIn(_nitroEncodeMapBytes$suffix($name)).toJS';
  }
  if (t.isRecord || spec.isRecordName(base)) {
    const libraryRecords = {'NitroNullableInt', 'NitroNullableDouble', 'NitroNullableBool'};
    final writeCall = libraryRecords.contains(base) || spec.isRecordName(base) || spec.isStructName(base) ? '$name.writeFields' : '$name.writeFields';
    if (t.recordListItemType != null) {
      // A nullable LIST passes 0 (nullptr) for "absent" — the C++ bridge
      // unpacks that into an empty buffer and the decode side maps it back
      // to null. Without the guard the encoders receive a `List<T>?` where
      // they declare `List<T>`.
      // No `!` on the encode side: the ternary already promotes $name to
      // non-null, so an assertion here is dead code the analyzer flags.
      final encode = 'arena.copyIn(${_encodeRecordListExpr(spec, t, name)})';
      return nullable ? '($name == null ? 0 : $encode).toJS' : '$encode.toJS';
    }
    return nullable ? '($name == null ? 0 : arena.copyIn(_nitroEncodeFramed((w) => $name.writeFields(w)))).toJS' : 'arena.copyIn(_nitroEncodeFramed((w) => $writeCall(w))).toJS';
  }
  // Fallback: framed record-style value.
  return 'arena.copyIn(_nitroEncodeFramed((w) => $name.writeFields(w))).toJS';
}

String _encodeRecordListExpr(BridgeSpec spec, BridgeType t, String name) {
  final item = t.recordListItemType!;
  // Nullable ITEMS carry a presence flag per entry: [4B count][1B has][item?].
  // Only enum and variant lists can have nullable items today (see
  // spec_extractor) — a plain encode here drops the flag and desynchronises
  // the reader by one byte per item.
  final nullableItems = t.recordListItemIsNullable;
  if (t.isEnumList) {
    final write = 'w.writeInt(e.nativeValue)';
    return nullableItems ? 'RecordWriter.encodeNullableListBytes($name, (w, e) => $write)' : 'RecordWriter.encodeListBytes($name, (w, e) => $write)';
  }
  if (t.recordListItemIsPrimitive) {
    final writeCall = switch (item) {
      'int' => 'w.writeInt(e)',
      'double' => 'w.writeDouble(e)',
      'bool' => 'w.writeBool(e)',
      'String' => 'w.writeString(e)',
      _ => 'w.writeInt(e)',
    };
    // Primitive list ARGUMENTS are indexed, same as record lists — Kotlin and
    // Swift both skip an 8-byte-per-item offset table when reading a
    // primitive list param, and the native Dart twin encodes with
    // encodeIndexedPrimitiveList. Note the asymmetry is deliberate: primitive
    // list RETURNS are plain on every backend, so the decode side stays
    // decodeListBytes.
    return 'RecordWriter.encodeIndexedListBytes($name, (w, e) => $writeCall)';
  }
  if (spec.isVariantName(item)) {
    const write = 'e.writeFields(w)';
    return nullableItems ? 'RecordWriter.encodeNullableListBytes($name, (w, e) => $write)' : 'RecordWriter.encodeListBytes($name, (w, e) => $write)';
  }
  // True @HybridRecord lists are indexed in BOTH directions —
  // [4B count][8B×n offsets][item bytes] — matching the native Dart encoder
  // (dart_record_ffi_helpers.dart) and the Kotlin/Swift emitters. The decode
  // side already expects the offset table; encoding plain here made the
  // receiver read item bytes as offsets.
  //
  // C++ is not in that list on purpose: its bridge forwards lists as an
  // opaque [4B len][payload] blob and never parses them, so a hand-written
  // C++ impl must read/write the offset table itself.
  return 'RecordWriter.encodeIndexedListBytes($name, (w, e) => e.writeFields(w))';
}
