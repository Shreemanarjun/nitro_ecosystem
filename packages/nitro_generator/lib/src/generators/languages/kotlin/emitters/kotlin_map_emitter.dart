import '../../../../bridge_spec.dart';
import '../../../../map_wire.dart';
import '../../../code_writer.dart';
import 'kotlin_type_mapper.dart';

/// Kotlin codec for `Map<String, V>` and `NitroAnyMap` values on the JNI
/// bridge: ONE decoder and ONE encoder, used by every dispatch path (sync,
/// `@nitroAsync`, `@NitroNativeAsync`, `@NitroResult`) and for a map in any
/// parameter position.
///
/// Wire (see map_wire.dart): `[4B payloadLen][4B count]` then per entry
/// `[4B keyLen][key][1B tag][value]`; tag 0 is a null value.
class KotlinMapEmitter {
  /// Whether [spec] needs the helpers (and the array codec they build on).
  static bool usesMaps(BridgeSpec spec) => spec.functions.any((f) => _isStringMap(f.returnType) || f.params.any((p) => _isStringMap(p.type)));

  static bool _isStringMap(BridgeType t) => t.isMap && !t.isAnyMap;

  static bool _isNullable(BridgeType t) => t.isNullable || t.name.endsWith('?');

  /// The generic helpers, over `NitroRecordIn` / `NitroRecordOut`: values are
  /// read from and written into the array, with no stream or scratch buffer
  /// per entry.
  static void emitHelpers(CodeWriter writer) {
    const helpers = r'''
// Map<String, V> codec — [4B payloadLen][4B count], then per entry
// [4B keyLen][key][1B tag][value]. Tag 0 is a null value.
private inline fun <V> nitroDecodeMap(bytes: ByteArray, read: (NitroRecordIn) -> V): Map<String, V> {
    val r = NitroRecordIn(bytes, 4) // past the payload length
    val n = r.int32()
    val out = LinkedHashMap<String, V>(n + n / 3 + 1)
    repeat(n) { val k = r.string(); out[k] = read(r) }
    return out
}
/** A record or variant value: `[4B blobLen][4B len]` precede its fields. */
private inline fun <T> NitroRecordIn.blob(read: (NitroRecordIn) -> T): T {
    val n = int32(); val end = p + n
    p += 4
    val v = read(this)
    p = end
    return v
}
private inline fun <V : Any> nitroEncodeMap(map: Map<String, V?>, tag: Int, write: (NitroRecordOut, V) -> Unit): ByteArray {
    val out = NitroRecordOut(8 + map.size * 24)
    out.putInt32(0) // payload length, patched below
    out.putInt32(map.size)
    for ((k, v) in map) {
        out.putString(k)
        if (v == null) { out.putByte(0); continue }
        out.putByte(tag)
        write(out, v)
    }
    val bytes = out.toByteArray()
    val n = bytes.size - 4
    bytes[0] = n.toByte(); bytes[1] = (n shr 8).toByte(); bytes[2] = (n shr 16).toByte(); bytes[3] = (n shr 24).toByte()
    return bytes
}
''';
    helpers.trim().split('\n').forEach(writer.line);
    writer.blankLine();
  }

  /// Decodes every `Map<String, V>` / `NitroAnyMap` parameter of [func] into
  /// `val <name>Decoded`, which `_buildCallParams` passes to the impl. A null
  /// map arrives as a null ByteArray.
  static void emitParamDecodes(CodeWriter writer, BridgeFunction func, BridgeSpec spec) {
    for (final p in func.params) {
      final decode = switch (p.type) {
        BridgeType(isAnyMap: true) => 'NitroAnyMapCodec.decode(%s)',
        BridgeType(isMap: true) => 'nitroDecodeMap(%s) { r -> ${_MapValue.of(p.type.name, spec).read} }',
        _ => null,
      };
      if (decode == null) continue;
      final nullable = _isNullable(p.type) || p.isOptional;
      writer.line('        val ${p.name}Decoded = ${nullable ? '${p.name}?.let { ${decode.replaceFirst('%s', 'it')} }' : decode.replaceFirst('%s', p.name)}');
    }
  }

  /// The decoded Kotlin type of [mapType]: `Map<String, Long>`, with `?` when
  /// the map itself is nullable.
  static String kotlinType(BridgeType mapType, BridgeSpec spec) => 'Map<String, ${_MapValue.of(mapType.name, spec).kotlinType}>${_isNullable(mapType) ? '?' : ''}';

  /// Kotlin expression for the `[4B len][payload]` block of [value], a
  /// `Map<String, V>` or `NitroAnyMap` of [mapType]. A null map gives a null
  /// ByteArray.
  static String encodeExpr(BridgeType mapType, BridgeSpec spec, String value) {
    final v = _MapValue.of(mapType.name, spec);
    final encode = mapType.isAnyMap ? 'NitroAnyMapCodec.encode(%s)' : 'nitroEncodeMap(%s, ${v.kind.wire.tag}) { o, v -> ${v.write} }';
    return _isNullable(mapType) ? '$value?.let { ${encode.replaceFirst('%s', 'it')} }' : encode.replaceFirst('%s', value);
  }
}

/// The value type of a `Map<String, V>`, as Kotlin sees it.
final class _MapValue {
  const _MapValue({required this.base, required this.isNullable, required this.kind, required this.isLocalRecord});

  factory _MapValue.of(String mapTypeName, BridgeSpec spec) {
    final declared = stringMapValueType(mapTypeName);
    final base = declared == null ? '' : bareTypeName(declared);
    return _MapValue(
      base: base,
      isNullable: declared != null && declared.endsWith('?'),
      kind: mapValueKindOf(base, isEnum: spec.isEnumName, isRecord: spec.isRecordName, isVariant: spec.isVariantName, isStruct: spec.isStructName),
      isLocalRecord: spec.nativeRecordTypes.any((r) => r.name == base),
    );
  }

  /// The Dart value type without its `?`.
  final String base;

  /// Tag 0 on the wire: the value, not the map.
  final bool isNullable;
  final MapValueKind kind;

  /// A record of this file's package reads from the cursor; another module's
  /// has its own cursor class and is read through a ByteBuffer.
  final bool isLocalRecord;

  String get kotlinType {
    final t = switch (kind) {
      MapValueKind.int64 => 'Long',
      MapValueKind.float64 => 'Double',
      MapValueKind.boolean => 'Boolean',
      MapValueKind.string => 'String',
      MapValueKind.enumValue || MapValueKind.record || MapValueKind.variant || MapValueKind.struct => base,
      MapValueKind.dynamic => 'Any?',
    };
    return isNullable && kind != MapValueKind.dynamic ? '$t?' : t;
  }

  /// Body of a `{ r -> … }` lambda that reads the tag and one value.
  String get read {
    final value = switch (kind) {
      MapValueKind.int64 => 'r.int64()',
      MapValueKind.float64 => 'r.float64()',
      MapValueKind.boolean => 'r.byte() != 0',
      MapValueKind.string || MapValueKind.dynamic => 'r.string()',
      MapValueKind.enumValue => '$base.fromNative(r.int64())',
      MapValueKind.record when isLocalRecord => 'r.blob { $base.decodeFrom(it) }',
      // A struct's decoder, like another module's record's, takes a ByteBuffer.
      MapValueKind.record || MapValueKind.struct => 'r.blob { b -> b.via { $base.decodeFrom(it) } }',
      MapValueKind.variant => 'r.blob { b -> b.via { $base.fromReader(${KotlinTypeMapper.codec(base, 'RecordReader')}(it)) } }',
    };
    return isNullable ? 'if (r.byte() == ${MapValueWire.nul.tag}) null else $value' : 'r.p++; $value';
  }

  /// Body of a `{ o, v -> … }` lambda that writes one non-null value.
  String get write => switch (kind) {
    MapValueKind.int64 => 'o.putInt64(v)',
    MapValueKind.float64 => 'o.putFloat64(v)',
    MapValueKind.boolean => 'o.putByte(if (v) 1 else 0)',
    MapValueKind.string => 'o.putString(v)',
    // A @HybridEnum rides the int64 wire as its raw value.
    MapValueKind.enumValue => 'o.putInt64(v.nativeValue)',
    // `[4B blobLen]` then encode()'s bytes, which carry their own `[4B len]`.
    MapValueKind.record || MapValueKind.variant => 'val b = v.encode(); o.putInt32(b.size); o.write(b, 0, b.size)',
    // A struct's encode() is its bare fields: both lengths are written here.
    MapValueKind.struct => 'val b = v.encode(); o.putInt32(b.size + 4); o.putInt32(b.size); o.write(b, 0, b.size)',
    // A value type with no wire of its own goes out as its string form.
    MapValueKind.dynamic => 'o.putString(v.toString())',
  };
}
