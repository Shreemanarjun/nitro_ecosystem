/// The String-key map wire contract, in one place.
///
/// A map entry is `[4B keyLen][key bytes][1B tag][value bytes]`. Five backends
/// (Dart FFI, Kotlin, Swift, C++, web) encode and decode this independently,
/// and each used to carry its own literal tag numbers plus a prose comment
/// describing the table. Those comments had already drifted apart — one listed
/// a `9=bytes` tag that exists nowhere, and two omitted `0=null` after it was
/// added — which is how the nullable-value gap went unnoticed.
///
/// Int-keyed maps are a DIFFERENT wire: their values are homogeneous and carry
/// no tag at all, which is why a nullable value type has nowhere to record
/// null there (E018).
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

/// Classifies a map VALUE type into its wire category.
///
/// Every backend used to re-derive this precedence in its own if/else ladder —
/// enum before record before variant before the dynamic fallback — so the five
/// orderings could disagree. [isEnum], [isRecord] and [isVariant] come from the
/// spec because this library does not depend on it.
MapValueWire mapValueWireOf(
  String valueType, {
  required bool Function(String) isEnum,
  required bool Function(String) isRecord,
  required bool Function(String) isVariant,
}) => switch (valueType) {
  'int' => MapValueWire.int64,
  'double' => MapValueWire.float64,
  'bool' => MapValueWire.boolean,
  'String' => MapValueWire.string,
  // A @HybridEnum rides the int64 wire as its raw value.
  final t when isEnum(t) => MapValueWire.int64,
  final t when isRecord(t) || isVariant(t) => MapValueWire.blob,
  // Anything else is JSON-encoded into the string wire.
  _ => MapValueWire.string,
};

/// Value types that may be nullable on the tagged String-key wire.
///
/// The others cannot: Swift decodes enum/record/variant maps through
/// `compactMapValues`, which DROPS a nil entry rather than keeping the key.
const nullableMapValueTypes = {'int', 'double', 'bool', 'String'};
