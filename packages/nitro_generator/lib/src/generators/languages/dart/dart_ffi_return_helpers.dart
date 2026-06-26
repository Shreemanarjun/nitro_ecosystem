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
  primitive, // int (non-null), double (non-null) — pass through unchanged
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
  if (returnType.isRecord) return ReturnKind.record;
  if (returnType.isTypedData) return ReturnKind.typedData;
  if (returnType.isNativeHandle) return ReturnKind.nativeHandle;
  if (isEnumType(base, spec)) return ReturnKind.enumType;
  if (isStructType(base, spec)) return ReturnKind.struct;
  if (base == 'bool') return isNullable ? ReturnKind.boolNullable : ReturnKind.boolNonNull;
  if (base == 'String') return isNullable ? ReturnKind.stringNullable : ReturnKind.stringNonNull;
  if (base == 'int' && isNullable) return ReturnKind.intNullable;
  if (base == 'double' && isNullable) return ReturnKind.doubleNullable;
  return ReturnKind.primitive;
}

bool isStructType(String baseName, BridgeSpec spec) => spec.isStructName(baseName);

bool isEnumType(String baseName, BridgeSpec spec) => spec.isEnumName(baseName);

// ── Transport type for callAsync<T> ───────────────────────────────────────

/// The Dart type that [callAsync]`<T>` resolves with for the given return type.
///
/// Nullable sentinel variants use the same transport as non-nullable:
///   - `bool?`   → `int`          (sentinel −1/0/1)
///   - `String?` → `Pointer<Utf8>`(sentinel nullptr)
///   - `int?`    → `int`          (sentinel −1)
///   - `double?` → `double`       (sentinel NaN)
String callAsyncTransportType(BridgeType returnType, BridgeSpec spec) {
  final kind = classifyReturn(returnType, spec);
  switch (kind) {
    case ReturnKind.voidType:    return 'void';
    case ReturnKind.record:      return 'Pointer<Uint8>';
    case ReturnKind.typedData:   return 'Pointer<Uint8>';
    case ReturnKind.struct:      return 'Pointer<Void>';
    case ReturnKind.nativeHandle:return 'Pointer<Void>';
    case ReturnKind.enumType:    return 'int';
    case ReturnKind.boolNonNull: return 'int';           // bool→Int8
    case ReturnKind.boolNullable:return 'Pointer<Uint8>'; // NitroNullable binary
    case ReturnKind.stringNonNull:  return 'Pointer<Utf8>';
    case ReturnKind.stringNullable: return 'Pointer<Utf8>';
    case ReturnKind.intNullable:    return 'Pointer<Uint8>'; // NitroNullable binary
    case ReturnKind.doubleNullable: return 'Pointer<Uint8>'; // NitroNullable binary
    case ReturnKind.primitive:      return returnType.name; // int or double
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

  // @HybridRecord — caller should use _encodeRecordParam from DartFfiGenerator
  // for full fidelity; this covers the common toNative() path.
  if (type.isRecord) return (expr: '$varName.toNative($allocator)', needsArena: true);

  // @HybridStruct
  if (isStructType(base, spec)) return (expr: '$varName.toNative($allocator).cast<Void>()', needsArena: true);

  // Enum
  if (isEnumType(base, spec)) return (expr: '$varName.nativeValue', needsArena: false);

  // bool
  if (rt == 'bool') return (expr: '$varName ? 1 : 0', needsArena: false);
  // bool? — NitroNullable binary encoding
  if (rt == 'bool?') return (expr: 'NitroNullableBool.fromNullable($varName).toNative($allocator)', needsArena: true);

  // int? — NitroNullable binary encoding (zero collision)
  if (rt == 'int?') return (expr: 'NitroNullableInt.fromNullable($varName).toNative($allocator)', needsArena: true);

  // double? — NitroNullable binary encoding
  if (rt == 'double?') return (expr: 'NitroNullableDouble.fromNullable($varName).toNative($allocator)', needsArena: true);

  // int, double, or any remaining primitive
  return (expr: varName, needsArena: false);
}

