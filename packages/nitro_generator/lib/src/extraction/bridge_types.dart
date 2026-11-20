// ignore_for_file: deprecated_member_use
part of '../spec_extractor.dart';

// A resolved Dart type → `BridgeType`, the one description of a type every
// generator reads. A new bridged type is recognised here first.

const _primitiveNames = {
  'int',
  'double',
  'bool',
  'String',
  'void',
  'Uint8List',
  'Int8List',
  'Int16List',
  'Int32List',
  'Uint16List',
  'Uint32List',
  'Float32List',
  'Float64List',
  'Int64List',
  'Uint64List',
  'Pointer',
};

/// Converts a [DartType] to a [BridgeType], marking JSON-bridged types:
/// - `@HybridRecord` class  → `isRecord: true`
/// - `List<@HybridRecord T>` → `isRecord: true, recordListItemType: T`
/// - `List<@HybridStruct T>` → `isRecord: true, recordListItemType: T`
/// - `List<@HybridEnum T>`  → `isRecord: true, isEnumList: true, recordListItemType: T`
/// - `List<@NitroVariant T>`→ `isRecord: true, isVariantList: true, recordListItemType: T`
/// - `List<primitive T>`    → `isRecord: true, recordListItemType: T, recordListItemIsPrimitive: true`
/// - `Map<String, T>`       → `isRecord: true, isMap: true`
BridgeType _makeBridgeType(
  DartType type,
  Set<String> recordTypeNames, {
  bool isFuture = false,
  Set<String> knownTypeNames = const {},
  Set<String> structTypeNames = const {},
  Set<String> enumTypeNames = const {},
  Set<String> variantTypeNames = const {},
  Set<String> tupleTypeNames = const {},
}) {
  final displayName = type.getDisplayString();
  final isNullable = type.nullabilitySuffix == NullabilitySuffix.question;

  // ── Type alias early checks ──────────────────────────────────────────────
  // Inspect alias metadata before InterfaceType dispatch so that named type
  // aliases (e.g. `typedef uint64 = int`) are handled before the underlying
  // primitive type swallows them.
  final aliasName = type.alias?.element.name;

  // L13: uint64 — lowercase alias for unsigned 64-bit int (mirrors C uint64_t).
  if (aliasName == 'uint64' || displayName == 'uint64' || displayName == 'uint64?') {
    return BridgeType(name: isNullable ? 'uint64?' : 'uint64', isNullable: isNullable, isFuture: isFuture);
  }

  // L12: @NitroTuple positional record typedefs.
  if (tupleTypeNames.isNotEmpty) {
    final baseName = aliasName ?? (isNullable && displayName.endsWith('?') ? displayName.substring(0, displayName.length - 1) : displayName);
    if (tupleTypeNames.contains(baseName)) {
      return BridgeType(
        name: isNullable ? '$baseName?' : baseName,
        isRecord: true,
        isTuple: true,
        isNullable: isNullable,
        isFuture: isFuture,
      );
    }
  }

  // Handle function types (callbacks)
  if (type is FunctionType) {
    final returnType = type.returnType;
    final returnTypeName = returnType.getDisplayString();
    final params = <BridgeType>[];

    for (final param in type.formalParameters) {
      params.add(
        _makeBridgeType(
          param.type,
          recordTypeNames,
          knownTypeNames: knownTypeNames,
          structTypeNames: structTypeNames,
          enumTypeNames: enumTypeNames,
          variantTypeNames: variantTypeNames,
        ),
      );
    }

    return BridgeType(
      name: displayName,
      isNullable: isNullable,
      isFuture: isFuture,
      isFunction: true,
      functionReturnType: returnTypeName,
      functionParams: params,
    );
  }

  if (type is InterfaceType) {
    final elName = type.element.name;

    // List<T> — enum, variant, record, struct, or primitive items
    if (elName == 'List' && type.typeArguments.isNotEmpty) {
      final itemType = type.typeArguments.first;
      final itemName = itemType.getDisplayString(withNullability: false);
      final itemIsNullable = itemType.nullabilitySuffix == NullabilitySuffix.question;
      if (enumTypeNames.contains(itemName)) {
        return BridgeType(
          name: displayName,
          isRecord: true,
          isNullable: isNullable,
          recordListItemType: itemName,
          isEnumList: true,
          recordListItemIsNullable: itemIsNullable,
          isFuture: isFuture,
        );
      }
      if (variantTypeNames.contains(itemName)) {
        return BridgeType(
          name: displayName,
          isRecord: true,
          isNullable: isNullable,
          recordListItemType: itemName,
          isVariantList: true,
          recordListItemIsNullable: itemIsNullable,
          isFuture: isFuture,
        );
      }
      if (recordTypeNames.contains(itemName)) {
        return BridgeType(
          name: displayName,
          isRecord: true,
          isNullable: isNullable,
          recordListItemType: itemName,
          isFuture: isFuture,
        );
      }
      if (structTypeNames.contains(itemName)) {
        return BridgeType(
          name: displayName,
          isRecord: true,
          isNullable: isNullable,
          recordListItemType: itemName,
          isFuture: isFuture,
        );
      }
      if (_primitiveNames.contains(itemName)) {
        return BridgeType(
          name: displayName,
          isRecord: true,
          isNullable: isNullable,
          recordListItemType: itemName,
          recordListItemIsPrimitive: true,
          isFuture: isFuture,
        );
      }
    }

    // NitroAnyMap — heterogeneous typed map (RN Nitro AnyMap equivalent)
    if (elName == 'NitroAnyMap') {
      return BridgeType(
        name: displayName,
        isAnyMap: true,
        isNullable: isNullable,
        isFuture: isFuture,
      );
    }

    // Map<String, T> — JSON object bridge
    if (elName == 'Map' && type.typeArguments.length == 2 && type.typeArguments.first.getDisplayString(withNullability: false) == 'String') {
      return BridgeType(
        name: displayName,
        isRecord: true,
        isNullable: isNullable,
        isMap: true,
        isFuture: isFuture,
      );
    }

    // Direct @HybridRecord class
    if (recordTypeNames.contains(elName)) {
      return BridgeType(name: displayName, isRecord: true, isNullable: isNullable, isFuture: isFuture);
    }

    // AnyNativeObject — opaque int64_t instance ID (RN Nitro AnyHybridObject)
    if (elName == 'AnyNativeObject') {
      return BridgeType(
        name: displayName,
        isAnyNativeObject: true,
        isNullable: isNullable,
        isFuture: isFuture,
      );
    }

    // NativeHandle<T> — raw opaque pointer, zero codec overhead
    if (elName == 'NativeHandle' && type.typeArguments.isNotEmpty) {
      final typeParam = type.typeArguments.first.getDisplayString(withNullability: false);
      return BridgeType(
        name: displayName,
        isNativeHandle: true,
        isNullable: isNullable,
        nativeHandleTypeParam: typeParam,
        isFuture: isFuture,
      );
    }

    // Pointer<T> — raw FFI bridge
    if (elName == 'Pointer' && type.typeArguments.isNotEmpty) {
      final inner = type.typeArguments.first.getDisplayString(withNullability: false);
      return BridgeType(
        name: displayName,
        isPointer: true,
        isNullable: isNullable,
        pointerInnerType: inner,
        isFuture: isFuture,
      );
    }

    // Known type from @HybridEnum or @HybridStruct (but NOT @HybridRecord)
    if (knownTypeNames.contains(elName) && !recordTypeNames.contains(elName)) {
      return BridgeType(name: displayName, isNullable: isNullable, isFuture: isFuture);
    }
  }

  return BridgeType(name: displayName, isNullable: isNullable, isFuture: isFuture);
}
