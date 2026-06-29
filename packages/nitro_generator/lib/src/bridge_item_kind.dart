// lib/src/bridge_item_kind.dart
//
// Granular classification of a single bridge value — combining base type name
// and nullability into one enum value.
//
// This is the sister type to [ReturnKind] (which classifies function return
// types) but is broader: used for stream item types, property types, and any
// place where a scalar value crosses the native/Dart boundary.
//
// **The core problem it solves**
// Emitters historically dispatched via `if (name == 'String')` chains. For
// `Stream<String?>`, `name` is `'String?'`, so the `'String'` branch was
// never reached and items silently fell through to an `obj.type = kNull`
// fallback, always posting null. A typed enum + exhaustive switch eliminates
// this class of silent fall-through.
//
// **Adding a new bridge type**
//   1. Add a non-nullable + `*Nullable` enum case here.
//   2. Handle them in [classifyBridgeItem].
//   3. The Dart compiler warns for any switch statement that doesn't cover the
//      new cases.

import 'bridge_spec.dart';

/// Structural kind of a single bridge scalar/item type.
///
/// Classifies a [BridgeType] into a canonical kind that combines base type
/// name and nullability. Emitters switch on this value instead of chaining
/// `type.name == 'String'` / `type.isNullable` checks.
///
/// Obtain via [classifyBridgeItem].
enum BridgeItemKind {
  // ── Scalar primitives ────────────────────────────────────────────────────
  int_,
  double_,
  bool_,
  string,
  dateTime,
  void_,

  // ── Nullable scalar primitives ───────────────────────────────────────────
  intNullable,
  doubleNullable,
  boolNullable,
  stringNullable,
  dateTimeNullable,

  // ── User-defined types ───────────────────────────────────────────────────
  hybridEnum,
  hybridEnumNullable,
  hybridStruct,
  hybridStructNullable,
  hybridRecord,
  hybridRecordNullable,
  nitroVariant,
  nitroVariantNullable,

  // ── Container / special ──────────────────────────────────────────────────
  typedData,
  typedDataNullable,

  /// Anything not matched above (unsupported as a scalar stream/property item).
  other,
}

extension BridgeItemKindX on BridgeItemKind {
  bool get isNullable => switch (this) {
    BridgeItemKind.intNullable ||
    BridgeItemKind.doubleNullable ||
    BridgeItemKind.boolNullable ||
    BridgeItemKind.stringNullable ||
    BridgeItemKind.dateTimeNullable ||
    BridgeItemKind.hybridEnumNullable ||
    BridgeItemKind.hybridStructNullable ||
    BridgeItemKind.hybridRecordNullable ||
    BridgeItemKind.nitroVariantNullable ||
    BridgeItemKind.typedDataNullable => true,
    _ => false,
  };

  bool get isNullablePrimitive => switch (this) {
    BridgeItemKind.intNullable ||
    BridgeItemKind.doubleNullable ||
    BridgeItemKind.boolNullable ||
    BridgeItemKind.dateTimeNullable => true,
    _ => false,
  };

  bool get isStringKind =>
      this == BridgeItemKind.string || this == BridgeItemKind.stringNullable;

  bool get isEnumKind =>
      this == BridgeItemKind.hybridEnum || this == BridgeItemKind.hybridEnumNullable;

  bool get isStructKind =>
      this == BridgeItemKind.hybridStruct || this == BridgeItemKind.hybridStructNullable;

  bool get isRecordKind =>
      this == BridgeItemKind.hybridRecord || this == BridgeItemKind.hybridRecordNullable;

  bool get isVariantKind =>
      this == BridgeItemKind.nitroVariant || this == BridgeItemKind.nitroVariantNullable;
}

/// Classify a [BridgeType] (stream item, property type, etc.) into its
/// [BridgeItemKind].
///
/// Requires [spec] to resolve user-defined names (enums, structs, records,
/// variants). The checks follow this priority order:
///   1. TypedData (before enum/struct name lookup)
///   2. @NitroVariant (before isRecord, since variant items are NOT flagged
///      as isRecord on the BridgeType)
///   3. @HybridRecord (isRecord flag)
///   4. @HybridEnum  (spec enum index)
///   5. @HybridStruct (spec struct index)
///   6. Primitives by name (int, double, bool, String, DateTime, void)
///   7. [BridgeItemKind.other] fallback
BridgeItemKind classifyBridgeItem(BridgeType type, BridgeSpec spec) {
  // isNullable is derived from both the explicit flag and the '?' suffix to
  // handle BridgeType instances built in tests or by older extractor code.
  final isNullable = type.isNullable || type.name.endsWith('?');
  final base = type.name.endsWith('?')
      ? type.name.substring(0, type.name.length - 1)
      : type.name;

  if (type.isTypedData) {
    return isNullable ? BridgeItemKind.typedDataNullable : BridgeItemKind.typedData;
  }

  // Variant must come before isRecord: @NitroVariant items are NOT flagged
  // as isRecord=true on the BridgeType.
  if (spec.isVariantName(base)) {
    return isNullable ? BridgeItemKind.nitroVariantNullable : BridgeItemKind.nitroVariant;
  }

  if (type.isRecord) {
    return isNullable ? BridgeItemKind.hybridRecordNullable : BridgeItemKind.hybridRecord;
  }

  if (spec.isEnumName(base)) {
    return isNullable ? BridgeItemKind.hybridEnumNullable : BridgeItemKind.hybridEnum;
  }

  if (spec.isStructName(base)) {
    return isNullable ? BridgeItemKind.hybridStructNullable : BridgeItemKind.hybridStruct;
  }

  return switch (base) {
    'int'      => isNullable ? BridgeItemKind.intNullable      : BridgeItemKind.int_,
    'double'   => isNullable ? BridgeItemKind.doubleNullable   : BridgeItemKind.double_,
    'bool'     => isNullable ? BridgeItemKind.boolNullable     : BridgeItemKind.bool_,
    'String'   => isNullable ? BridgeItemKind.stringNullable   : BridgeItemKind.string,
    'DateTime' => isNullable ? BridgeItemKind.dateTimeNullable : BridgeItemKind.dateTime,
    'void'     => BridgeItemKind.void_,
    _          => BridgeItemKind.other,
  };
}
