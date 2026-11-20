import '../../../../bridge_spec.dart';
import '../../../../map_wire.dart';
import '../../../code_writer.dart';

/// Swift codec for `Map<String, V>` values on the bridge: typed dictionaries
/// (`[String: Int64]`, `[String: Config]`, …) decoded and encoded straight
/// through `NitroRecordReader` / `NitroRecordWriter`, for every dispatch path
/// and for a map in any parameter position.
///
/// Wire (see map_wire.dart): `[4B payloadLen][4B count]` then per entry
/// `[4B keyLen][key][1B tag][value]`; tag 0 is a null value.
class SwiftMapEmitter {
  /// Whether [spec] needs the helpers (and the reader/writer they build on).
  static bool usesMaps(BridgeSpec spec) =>
      spec.functions.any((f) => f.returnType.isMap || f.params.any((p) => p.type.isMap)) || spec.properties.any((p) => p.type.isMap);

  /// The four generic helpers. One reader and one writer pass each, with no
  /// `[String: Any]` boxing in between.
  static void emitHelpers(CodeWriter writer) {
    const helpers = r'''
// Map<String, V> codec — [4B payloadLen][4B count], then per entry
// [4B keyLen][key][1B tag][value]. Tag 0 is a null value.
private func _nitroDecodeMap<V>(_ ptr: UnsafeMutableRawPointer, _ read: (NitroRecordReader) -> V) -> [String: V] {
    let r = NitroRecordReader(ptr: ptr.assumingMemoryBound(to: UInt8.self))
    let count = Int(r.readInt32())
    var out = [String: V](minimumCapacity: count)
    for _ in 0..<count {
        let key = r.readString()
        r.pos += 1 // the tag: a non-null value type has exactly one
        out[key] = read(r)
    }
    return out
}
private func _nitroDecodeNullableMap<V>(_ ptr: UnsafeMutableRawPointer, _ read: (NitroRecordReader) -> V) -> [String: V?] {
    let r = NitroRecordReader(ptr: ptr.assumingMemoryBound(to: UInt8.self))
    let count = Int(r.readInt32())
    var out = [String: V?](minimumCapacity: count)
    for _ in 0..<count {
        let key = r.readString()
        // updateValue, not a subscript assignment: `out[key] = nil` would drop the key.
        out.updateValue(r.readNullTag() ? nil : read(r), forKey: key)
    }
    return out
}
private func _nitroEncodeMap<V>(_ map: [String: V], _ tag: UInt8, _ write: (NitroRecordWriter, V) -> Void) -> UnsafeMutablePointer<UInt8>? {
    let w = NitroRecordWriter()
    w.writeInt32(Int32(map.count))
    for (key, value) in map {
        w.writeString(key)
        w.writeByte(tag)
        write(w, value)
    }
    return w.toNative()
}
private func _nitroEncodeNullableMap<V>(_ map: [String: V?], _ tag: UInt8, _ write: (NitroRecordWriter, V) -> Void) -> UnsafeMutablePointer<UInt8>? {
    let w = NitroRecordWriter()
    w.writeInt32(Int32(map.count))
    for (key, value) in map {
        w.writeString(key)
        if let value = value {
            w.writeByte(tag)
            write(w, value)
        } else {
            w.writeByte(0)
        }
    }
    return w.toNative()
}
''';
    helpers.trim().split('\n').forEach(writer.line);
    writer.blankLine();
  }

  /// The Swift type of [mapTypeName]: `[String: Int64]`, `[String: Config?]`,
  /// with a trailing `?` when the map itself is nullable.
  static String swiftType(String mapTypeName, BridgeSpec spec) {
    final value = _MapValue.of(mapTypeName, spec);
    return '[String: ${value.swiftType}]${mapTypeName.endsWith('?') ? '?' : ''}';
  }

  /// The local a decoded map (or any-map) parameter is bound to.
  static String argName(BridgeParam p) => '${p.name}Map';

  /// Decodes every `Map<String, V>` / `NitroAnyMap` parameter of [func] into
  /// an owned dictionary, `let <name>Map`. Emitted at the top of the stub, so
  /// it is safe to capture in a `Task`.
  static void emitParamDecodes(CodeWriter writer, BridgeFunction func, BridgeSpec spec) {
    for (final p in func.params) {
      final nullable = p.type.isNullable || p.type.name.endsWith('?') || p.isOptional;
      // A null map arrives as a null pointer.
      final orEmpty = nullable ? '' : ' ?? [:]';
      switch (p.type) {
        case BridgeType(isAnyMap: true):
          writer.line(
            '    let ${argName(p)}: [String: Any]${nullable ? '?' : ''} = ${p.name}.map { _nitroDecodeAnyMapBinary(\$0.assumingMemoryBound(to: UInt8.self)) }$orEmpty',
          );
        case BridgeType(isMap: true):
          final value = _MapValue.of(p.type.name, spec);
          final decode = value.isNullable ? '_nitroDecodeNullableMap' : '_nitroDecodeMap';
          writer.line('    let ${argName(p)}: [String: ${value.swiftType}]${nullable ? '?' : ''} = ${p.name}.map { $decode(\$0) { r in ${value.read} } }$orEmpty');
        default:
      }
    }
  }

  /// Swift expression that encodes [value], a non-nil dictionary of
  /// [mapType], into a `[4B len][payload]` block.
  static String encodeExpr(BridgeType mapType, BridgeSpec spec, String value) {
    final v = _MapValue.of(mapType.name, spec);
    final encode = v.isNullable ? '_nitroEncodeNullableMap' : '_nitroEncodeMap';
    return '$encode($value, ${v.kind.wire.tag}) { w, v in ${v.write} }';
  }
}

/// The value type of a `Map<String, V>`, as Swift sees it.
final class _MapValue {
  const _MapValue({required this.base, required this.isNullable, required this.kind});

  factory _MapValue.of(String mapTypeName, BridgeSpec spec) {
    final declared = stringMapValueType(mapTypeName);
    final base = declared == null ? '' : bareTypeName(declared);
    return _MapValue(
      base: base,
      isNullable: declared != null && declared.endsWith('?'),
      kind: mapValueKindOf(base, isEnum: spec.isEnumName, isRecord: spec.isRecordName, isVariant: spec.isVariantName, isStruct: spec.isStructName),
    );
  }

  /// The Dart value type without its `?`.
  final String base;

  /// Tag 0 on the wire: the value, not the map.
  final bool isNullable;
  final MapValueKind kind;

  String get swiftType {
    final t = switch (kind) {
      MapValueKind.int64 => 'Int64',
      MapValueKind.float64 => 'Double',
      MapValueKind.boolean => 'Bool',
      MapValueKind.string => 'String',
      MapValueKind.enumValue || MapValueKind.record || MapValueKind.variant || MapValueKind.struct => base,
      MapValueKind.dynamic => 'Any',
    };
    return isNullable ? '$t?' : t;
  }

  /// Body of a `{ r in … }` closure that reads one value.
  String get read => switch (kind) {
    MapValueKind.int64 => 'r.readInt()',
    MapValueKind.float64 => 'r.readDouble()',
    MapValueKind.boolean => 'r.readBool()',
    MapValueKind.string => 'r.readString()',
    MapValueKind.enumValue => '$base(rawValue: r.readInt())!',
    // `[4B blobLen][4B len]` precede the value's own fields.
    MapValueKind.record || MapValueKind.variant || MapValueKind.struct => 'r.pos += 8; return $base.fromReader(r)',
    MapValueKind.dynamic => 'r.readString() as Any',
  };

  /// Body of a `{ w, v in … }` closure that writes one value.
  String get write => switch (kind) {
    MapValueKind.int64 => 'w.writeInt(v)',
    MapValueKind.float64 => 'w.writeDouble(v)',
    MapValueKind.boolean => 'w.writeBool(v)',
    MapValueKind.string => 'w.writeString(v)',
    // A @HybridEnum rides the int64 wire as its raw value.
    MapValueKind.enumValue => 'w.writeInt(v.rawValue)',
    MapValueKind.record || MapValueKind.struct => r'w.writeFramed { v.writeFields($0) }',
    MapValueKind.variant => r'w.writeFramed { v.writeFields(to: $0) }',
    // A value type with no wire of its own goes out as its string form.
    MapValueKind.dynamic => r'w.writeString("\(v)")',
  };
}
