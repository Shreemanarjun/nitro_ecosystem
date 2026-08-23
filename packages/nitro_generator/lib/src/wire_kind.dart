/// One closed classification of how a bridged type crosses the boundary.
///
/// [BridgeType]'s `is*` booleans overlap — `isTuple` and `isMap` both imply
/// `isRecord` — so the answer depends on CHECK ORDER. [wireKindOf] holds that
/// order once, and a `switch` over the enum is exhaustive: a new variant fails
/// to compile in every backend that ignores it.
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
  // Arm order IS the precedence — containers first, because isRecord is also
  // true for maps, lists and tuples, and a tuple shares the record wire.
  return switch (base) {
    'void' || '' => WireKind.none,
    _ when t.isAnyMap => WireKind.anyMap,
    _ when t.isMap => WireKind.map,
    _ when t.isEnumList || t.isVariantList || t.recordListItemType != null => WireKind.list,
    _ when t.isFunction => WireKind.function,
    _ when t.isNativeHandle || t.isAnyNativeObject => WireKind.handle,
    _ when t.isTypedData => WireKind.typedData,
    _ when t.isPointer => WireKind.pointer,
    _ when isStruct(base) => WireKind.struct,
    _ when isVariant(base) => WireKind.variant,
    _ when isEnum(base) => WireKind.enumeration,
    _ when t.isRecord || t.isTuple => WireKind.record,
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
