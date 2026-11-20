/// The String-key map wire contract, in one place.
///
/// A map entry is `[4B keyLen][key bytes][1B tag][value bytes]`. Five backends
/// encode and decode it independently, so the tags live here rather than as
/// literals in each.
///
/// Int-keyed maps are a DIFFERENT wire: values are homogeneous and carry no
/// tag, which is why a nullable value type cannot record null there (E018).
library;

/// One wire category for a map value. The set is closed, so a `switch` over it
/// is exhaustive: adding a category fails to compile in every backend that
/// does not handle it, instead of silently falling into a `default:` branch.
enum MapValueWire {
  /// Absent value. Only the tag byte is written.
  nul(0),

  /// 8-byte little-endian int64. Also carries `@HybridEnum` raw values.
  int64(1),

  /// 8-byte little-endian IEEE-754 double.
  float64(2),

  /// Single byte, 0 or 1.
  boolean(3),

  /// `[4B byteLen][UTF-8 bytes]`. Also the JSON fallback for dynamic values.
  string(4),

  /// `[4B blobLen][framed record/variant bytes]` — the framed bytes keep their
  /// own inner 4-byte length prefix.
  blob(5);

  const MapValueWire(this.tag);

  /// The byte written before the value.
  final int tag;
}

final _stringKeyMap = RegExp(r'^Map<String,\s*(.+)>\??$');

/// The declared value type of `Map<String, V>` or `Map<String, V>?`: `V` with
/// its own `?` kept. Null when [mapTypeName] is not a String-key map.
String? stringMapValueType(String mapTypeName) => _stringKeyMap.firstMatch(mapTypeName)?.group(1)?.trim();

/// What a map VALUE type is. Several kinds share a wire ([wire]): an emitter
/// switches over the kind to pick the conversion, and writes the kind's tag.
enum MapValueKind {
  int64(MapValueWire.int64),
  float64(MapValueWire.float64),
  boolean(MapValueWire.boolean),
  string(MapValueWire.string),

  /// A `@HybridEnum`, as its raw value.
  enumValue(MapValueWire.int64),

  /// A `@HybridRecord`, framed.
  record(MapValueWire.blob),

  /// A `@NitroVariant`, framed.
  variant(MapValueWire.blob),

  /// A `@HybridStruct`, framed like a record: its fields in declaration order.
  struct(MapValueWire.blob),

  /// Anything else: its string form on the string wire.
  dynamic(MapValueWire.string);

  const MapValueKind(this.wire);
  final MapValueWire wire;
}

/// Classifies a map VALUE type.
///
/// Every backend used to re-derive this precedence in its own if/else ladder —
/// enum before record before variant before the dynamic fallback — so the five
/// orderings could disagree. [isEnum], [isRecord], [isVariant] and [isStruct]
/// come from the spec because this library does not depend on it.
MapValueKind mapValueKindOf(
  String valueType, {
  required bool Function(String) isEnum,
  required bool Function(String) isRecord,
  required bool Function(String) isVariant,
  bool Function(String)? isStruct,
}) => switch (valueType) {
  'int' => MapValueKind.int64,
  'double' => MapValueKind.float64,
  'bool' => MapValueKind.boolean,
  'String' => MapValueKind.string,
  final t when isEnum(t) => MapValueKind.enumValue,
  final t when isRecord(t) => MapValueKind.record,
  final t when isVariant(t) => MapValueKind.variant,
  final t when isStruct != null && isStruct(t) => MapValueKind.struct,
  _ => MapValueKind.dynamic,
};

/// The wire category of a map VALUE type (see [mapValueKindOf]).
MapValueWire mapValueWireOf(
  String valueType, {
  required bool Function(String) isEnum,
  required bool Function(String) isRecord,
  required bool Function(String) isVariant,
  bool Function(String)? isStruct,
}) => mapValueKindOf(valueType, isEnum: isEnum, isRecord: isRecord, isVariant: isVariant, isStruct: isStruct).wire;

/// Value types that may be nullable on the tagged String-key wire.
///
/// The others cannot: Swift decodes enum/record/variant maps through
/// `compactMapValues`, which DROPS a nil entry rather than keeping the key.
const nullableMapValueTypes = {'int', 'double', 'bool', 'String'};
