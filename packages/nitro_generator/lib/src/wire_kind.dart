/// One closed classification of how a bridged type crosses the boundary.
///
/// [BridgeType] carries a dozen overlapping `is*` booleans — `isTuple` implies
/// `isRecord`, `isMap` implies `isRecord`, `isEnumList` overlaps
/// `recordListItemType` — so "what kind of thing is this?" was answered by an
/// if/else ladder whose ORDER encoded the precedence. Every backend wrote its
/// own ladder, so the five orders could disagree, and a newly added wire type
/// silently fell into whichever `default:` branch it reached first.
///
/// [wireKindOf] is that precedence, written once. Because the result is a
/// closed enum, a `switch` over it is exhaustive: adding a variant fails to
/// compile in every backend that does not handle it.
library;

import 'bridge_spec.dart';

enum WireKind {
  /// `void` — no value crosses.
  none,

  /// int / intN / uintN / DateTime — an int64 slot.
  integer,

  /// double / float.
  float,

  bool_,

  /// `String` — a `const char*` on the native side.
  string,

  /// `@HybridEnum` — an int32 or int64 raw value.
  enumeration,

  /// Uint8List and friends — a pointer plus an element count.
  typedData,

  /// A raw `Pointer<T>`, passed through untouched.
  pointer,

  /// `@HybridStruct` — a C struct, by value or by pointer.
  struct,

  /// `@HybridRecord` / `@NitroTuple` — a framed `[4B len][fields]` blob.
  record,

  /// `@NitroVariant` — a framed blob with a leading case tag.
  variant,

  /// `List<T>` in any of its item flavours.
  list,

  /// `Map<K, V>` with a statically known value type.
  map,

  /// `NitroAnyMap` — a recursively type-tagged map.
  anyMap,

  /// A callback parameter.
  function,

  /// A `NativeHandle` / opaque hybrid-object handle.
  handle,

  /// `@NitroCustomType` and anything else with no dedicated wire.
  opaque,
}

/// Classifies [t] into exactly one [WireKind].
///
/// The ORDER of the checks is the contract — it is the precedence every
/// backend's if/else ladder used to spell out separately. Notably a map is
/// checked before a record (`isRecord` is also true for maps) and a tuple is a
/// record, not its own kind, because they share a wire.
WireKind wireKindOf(BridgeType t, {required bool Function(String) isEnum, required bool Function(String) isStruct, required bool Function(String) isVariant}) {
  final base = t.baseName;
  if (base == 'void' || base.isEmpty) return WireKind.none;
  // Containers first: isRecord is ALSO true for maps, lists and tuples.
  if (t.isAnyMap) return WireKind.anyMap;
  if (t.isMap) return WireKind.map;
  if (t.isEnumList || t.isVariantList || t.recordListItemType != null) return WireKind.list;
  if (t.isFunction) return WireKind.function;
  if (t.isNativeHandle || t.isAnyNativeObject) return WireKind.handle;
  if (t.isTypedData) return WireKind.typedData;
  if (t.isPointer) return WireKind.pointer;
  if (isStruct(base)) return WireKind.struct;
  if (isVariant(base)) return WireKind.variant;
  if (isEnum(base)) return WireKind.enumeration;
  // A tuple shares the record wire; isRecord covers both.
  if (t.isRecord || t.isTuple) return WireKind.record;
  return switch (base) {
    'double' || 'float' => WireKind.float,
    'bool' => WireKind.bool_,
    'String' => WireKind.string,
    _ when _integerBases.contains(base) => WireKind.integer,
    _ => WireKind.opaque,
  };
}

const _integerBases = {
  'int',
  'int8',
  'int16',
  'int32',
  'int64',
  'uint8',
  'uint16',
  'uint32',
  'uint64',
  'intptr',
  'size',
  'DateTime',
};

/// Convenience over a [BridgeSpec], which knows its own declared type names.
extension BridgeSpecWireKind on BridgeSpec {
  WireKind wireKind(BridgeType t) => wireKindOf(
    t,
    isEnum: isEnumName,
    isStruct: isStructName,
    isVariant: isVariantName,
  );
}
