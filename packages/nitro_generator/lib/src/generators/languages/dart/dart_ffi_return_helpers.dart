// Shared helpers for DartFfiGenerator return-type classification and decode.
//
// These helpers eliminate the four duplicated if/else chains that previously
// appeared across the sync-needsArena, sync-no-arena, async-needsArena, and
// async-no-arena paths of the generator.

import '../../../bridge_spec.dart';

// ── Return type classification ─────────────────────────────────────────────

/// Classifies a function's return type once so generators can branch on it
/// without repeating `spec.structs.any(...)` / `spec.enums.any(...)` calls.
enum ReturnKind {
  voidType,
  record,
  typedData,
  struct,
  enumType,
  nativeHandle,
  boolNonNull,
  boolNullable,
  stringNonNull,
  stringNullable,
  intNullable,
  doubleNullable,
  variant, // @NitroVariant sealed class — encoded as [4B len][1B tag][fields]
  primitive, // int (non-null), double (non-null) — pass through unchanged
  dateTime, // DateTime (non-null) — wire: Int64 ms epoch
  dateTimeNullable, // DateTime? — wire: Pointer<NitroOptInt64>
  anyNativeObject, // AnyNativeObject (non-null) — wire: Int64 instanceId
  anyNativeObjectNullable, // AnyNativeObject? — wire: Int64, -1 = null sentinel
  customType, // @NitroCustomType (non-null) — wire: Pointer<Uint8>
  customTypeNullable, // @NitroCustomType? — wire: Pointer<Uint8>, nullptr = null
  uint64, // uint64 (non-null) — wire: Uint64 (bit-reinterp of int64_t); Dart int
  uint64Nullable, // uint64? — wire: Pointer<NitroOptInt64> (same layout); Dart int?
}

ReturnKind classifyReturn(BridgeType returnType, BridgeSpec spec) {
  final rt = returnType.name;
  // Nullable detection: prefer the explicit field, but fall back to the '?' suffix
  // in the type name. This handles BridgeType instances created in tests (and by
  // older spec-extractor code) where isNullable may not be explicitly set to true
  // even when the name ends with '?'.
  final isNullable = returnType.isNullable || rt.endsWith('?');
  // baseName strips '?' whether from the field or the name suffix.
  final base = isNullable ? rt.replaceFirst('?', '') : rt;

  if (rt == 'void') return ReturnKind.voidType;
  if (returnType.isAnyMap) return ReturnKind.record; // NitroAnyMap: same wire as @HybridRecord
  if (returnType.isRecord) return ReturnKind.record;
  if (returnType.isTypedData) return ReturnKind.typedData;
  if (returnType.isNativeHandle) return ReturnKind.nativeHandle;
  if (returnType.isAnyNativeObject) return isNullable ? ReturnKind.anyNativeObjectNullable : ReturnKind.anyNativeObject;
  if (spec.isCustomTypeName(base)) return isNullable ? ReturnKind.customTypeNullable : ReturnKind.customType;
  if (isEnumType(base, spec)) return ReturnKind.enumType;
  if (isStructType(base, spec)) return ReturnKind.struct;
  if (spec.isVariantName(base)) return ReturnKind.variant;
  if (base == 'bool') return isNullable ? ReturnKind.boolNullable : ReturnKind.boolNonNull;
  if (base == 'String') return isNullable ? ReturnKind.stringNullable : ReturnKind.stringNonNull;
  if (base == 'int' && isNullable) return ReturnKind.intNullable;
  if (base == 'double' && isNullable) return ReturnKind.doubleNullable;
  if (base == 'DateTime') return isNullable ? ReturnKind.dateTimeNullable : ReturnKind.dateTime;
  if (base == 'uint64') return isNullable ? ReturnKind.uint64Nullable : ReturnKind.uint64;
  // Narrow integer nullable types share NitroOptInt64 decode path.
  const narrowIntTypes = {'int8', 'int16', 'int32', 'uint8', 'uint16', 'uint32', 'intptr', 'size'};
  if (narrowIntTypes.contains(base) && isNullable) return ReturnKind.intNullable;
  if (base == 'float' && isNullable) return ReturnKind.doubleNullable;
  return ReturnKind.primitive;
}

bool isStructType(String baseName, BridgeSpec spec) => spec.isStructName(baseName);

bool isEnumType(String baseName, BridgeSpec spec) => spec.isEnumName(baseName);

// ── Transport type for callAsync<T> ───────────────────────────────────────

/// The Dart type that [callAsync]`<T>` resolves with for the given return type.
///
/// @nitroAsync nullable prims use typed Pointer<`NitroOptXxx`> — the C function
/// allocates the struct and returns the pointer; Dart decodes and frees.
String callAsyncTransportType(BridgeType returnType, BridgeSpec spec) {
  final kind = classifyReturn(returnType, spec);
  switch (kind) {
    case ReturnKind.voidType:
      return 'void';
    case ReturnKind.record:
      return 'Pointer<Uint8>';
    case ReturnKind.typedData:
      return 'Pointer<Uint8>';
    case ReturnKind.struct:
      return 'Pointer<Void>';
    case ReturnKind.nativeHandle:
      return 'Pointer<Void>';
    case ReturnKind.enumType:
      return 'int';
    case ReturnKind.boolNonNull:
      return 'bool'; // Bool FFI type → Dart bool
    case ReturnKind.boolNullable:
      return 'Pointer<NitroOptBool>';
    case ReturnKind.stringNonNull:
      return 'Pointer<Utf8>';
    case ReturnKind.stringNullable:
      return 'Pointer<Utf8>';
    case ReturnKind.intNullable:
      return 'Pointer<NitroOptInt64>';
    case ReturnKind.doubleNullable:
      return 'Pointer<NitroOptFloat64>';
    case ReturnKind.variant:
      return 'Pointer<Uint8>'; // variant binary [4B len][tag][fields]
    case ReturnKind.primitive:
      // float → double transport; all other scalars (int8, int32, intptr, etc.) → int
      return (returnType.name == 'double' || returnType.name == 'float') ? 'double' : 'int';
    case ReturnKind.dateTime:
      return 'int';
    case ReturnKind.dateTimeNullable:
      return 'Pointer<NitroOptInt64>';
    case ReturnKind.anyNativeObject:
      return 'int';
    case ReturnKind.anyNativeObjectNullable:
      return 'int'; // -1 = null sentinel
    case ReturnKind.customType:
      return 'Pointer<Uint8>';
    case ReturnKind.customTypeNullable:
      return 'Pointer<Uint8>'; // nullptr = null
    case ReturnKind.uint64:
      return 'int';
    case ReturnKind.uint64Nullable:
      return 'Pointer<NitroOptInt64>';
  }
}

// ── Property setter value expression ──────────────────────────────────────

/// Returns the Dart expression that encodes a property value into the
/// representation expected by the C setter function.
///
/// Returns a record of (expression, needsArena) — needsArena is true when
/// the expression requires an `arena` allocator variable in scope.
({String expr, bool needsArena}) encodePropertyValue(
  BridgeType type,
  BridgeSpec spec,
  String varName,
  String allocator,
) {
  final rt = type.name;
  final base = type.baseName;

  // String / String? — need arena for toNativeUtf8
  if (rt == 'String') return (expr: '$varName.toNativeUtf8(allocator: $allocator)', needsArena: true);
  if (rt == 'String?') return (expr: '$varName != null ? $varName.toNativeUtf8(allocator: $allocator) : nullptr', needsArena: true);

  // TypedData
  if (type.isTypedData) return (expr: '$varName.toPointer($allocator)', needsArena: true);

  // AnyNativeObject / AnyNativeObject? — encode as raw instanceId (Int64)
  if (type.isAnyNativeObject) {
    if (rt.endsWith('?')) return (expr: '$varName?.instanceId ?? -1', needsArena: false);
    return (expr: '$varName.instanceId', needsArena: false);
  }

  // @NitroCustomType — use codec encode
  final bareCustom = type.baseName;
  if (spec.isCustomTypeName(bareCustom)) {
    final ct = spec.customTypeByName(bareCustom)!;
    return (expr: 'const ${ct.codecClass}().encode($varName, $allocator)', needsArena: true);
  }

  // @HybridRecord — caller should use _encodeRecordParam from DartFfiGenerator
  // for full fidelity; this covers the common toNative() path.
  if (type.isAnyMap) return (expr: '$varName.toNative($allocator)', needsArena: true);
  if (type.isRecord) return (expr: '$varName.toNative($allocator)', needsArena: true);

  // @HybridStruct
  if (isStructType(base, spec)) return (expr: '$varName.toNative($allocator).cast<Void>()', needsArena: true);

  // Enum
  if (isEnumType(base, spec)) return (expr: '$varName.nativeValue', needsArena: false);

  // bool — Bool FFI type maps directly; no ? 1 : 0 conversion needed
  if (rt == 'bool') return (expr: varName, needsArena: false);
  // bool? — NitroOptBool packed struct via Arena
  if (rt == 'bool?') return (expr: '$allocator.packBool($varName)', needsArena: true);

  // int? — NitroOptInt64 packed struct via Arena
  if (rt == 'int?') return (expr: '$allocator.packInt($varName)', needsArena: true);

  // uint64? — same NitroOptInt64 struct (bit-compatible with uint64_t); Dart int holds the bits
  if (rt == 'uint64?') return (expr: '$allocator.packInt($varName)', needsArena: true);

  // double? — NitroOptFloat64 packed struct via Arena
  if (rt == 'double?') return (expr: '$allocator.packDouble($varName)', needsArena: true);

  // DateTime / DateTime?
  if (rt == 'DateTime') return (expr: '$varName.millisecondsSinceEpoch', needsArena: false);
  if (rt == 'DateTime?') return (expr: '$allocator.packInt($varName?.millisecondsSinceEpoch)', needsArena: true);

  // int, double, or any remaining primitive
  return (expr: varName, needsArena: false);
}
