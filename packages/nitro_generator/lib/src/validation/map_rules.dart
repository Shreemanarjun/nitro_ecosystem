part of '../spec_validator.dart';

// Rules for `Map<K, V>` values, shared by returns, parameters, properties and
// streams (E008, E018).

/// The value type of a `Map<K, V>` type string, or null when it is not a map.
/// Splits on the LAST comma so `Map<String, List<int>>` yields `List<int>`.
String? _mapValueType(String typeName) {
  if (!typeName.startsWith('Map<')) return null;
  final inner = typeName.substring(4, typeName.lastIndexOf('>'));
  final comma = inner.lastIndexOf(',');
  return comma < 0 ? null : inner.substring(comma + 1).trim();
}

/// E008: a `Map<String, @HybridStruct>` whose struct some backend cannot
/// carry as bytes. A flat struct ([BridgeSpec.isFlatStruct]) is fine.
ValidationIssue? _structMapValueIssue(BridgeSpec spec, BridgeType map, String where) {
  final value = bareTypeName(stringMapValueType(map.name) ?? '');
  if (!spec.isStructName(value) || spec.isFlatStruct(value)) return null;
  return ValidationIssue(
    severity: ValidationSeverity.error,
    code: 'E008',
    message:
        '$where — Map<String, @HybridStruct> value type "$value" is not supported: '
        'a struct map value may only have non-null int, double, bool and String fields.',
    hint: 'Use List<$value> instead, or make "$value" a @HybridRecord.',
  );
}

ValidationIssue? _nullableMapValueIssue(BridgeType t, String where) {
  if (!t.isMap) return null;
  if (_mapValueType(t.name) case final String v when v.endsWith('?')) {
    final bare = v.substring(0, v.length - 1);
    final intKey = !t.name.startsWith('Map<String,');
    if (!intKey && nullableMapValueTypes.contains(bare)) return null;
    return ValidationIssue(
      severity: ValidationSeverity.error,
      code: 'E018',
      message: intKey
          ? '$where — an int-keyed map cannot have a nullable value type ("$v"); its values carry no type tag.'
          : '$where — Map value type "$v" is nullable, which only ${nullableMapValueTypes.join('/')} values support.',
      hint:
          'Use NitroAnyMap, whose wire format tags each value and already carries nulls; '
          'or Map<..., $bare> omitting absent keys; or a @HybridRecord with a nullable field.',
    );
  }
  return null;
}
