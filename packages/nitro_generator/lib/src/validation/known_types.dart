part of '../spec_validator.dart';

// Which type names the validator accepts without a declaration in the spec.

const _knownPrimitives = {
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
  'int?',
  'double?',
  'bool?',
  'String?',
  'DateTime',
  'DateTime?',
  'uint64',
  'uint64?',
  'int8',
  'int16',
  'int32',
  'uint8',
  'uint16',
  'uint32',
  'float',
  'intptr',
  'size',
  'int8?',
  'int16?',
  'int32?',
  'uint8?',
  'uint16?',
  'uint32?',
  'float?',
  'intptr?',
  'size?',
  'AnyNativeObject',
  'AnyNativeObject?',
  'Uint8List?',
  'Int8List?',
  'Int16List?',
  'Int32List?',
  'Uint16List?',
  'Uint32List?',
  'Float32List?',
  'Float64List?',
  'Int64List?',
  'Uint64List?',
};

bool _isKnownType(String typeName, Set<String> knownTypes) {
  if (knownTypes.contains(typeName)) return true;

  final withoutNullability = bareTypeName(typeName);
  if (knownTypes.contains(withoutNullability)) return true;

  final genericMatch = RegExp(r'^(\w+)<(.+)>$').firstMatch(typeName);
  if (genericMatch != null) {
    final containerType = genericMatch.group(1)!;
    final innerType = genericMatch.group(2)!;

    if (containerType == 'List' || containerType == 'Set') {
      final innerWithoutNullability = bareTypeName(innerType);
      return knownTypes.contains(innerWithoutNullability) || knownTypes.contains(innerType);
    }
  }

  return false;
}
