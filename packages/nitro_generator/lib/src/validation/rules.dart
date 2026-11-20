part of '../spec_validator.dart';

/// What every rule group reads: the spec, the name sets derived from it, and
/// the list the issues go into. Each group is an extension in this folder;
/// [SpecValidator.validate] runs them in order.
final class _Rules {
  _Rules(this.spec);

  final BridgeSpec spec;
  final issues = <ValidationIssue>[];

  late final Set<String> enumNames = spec.enums.map((e) => e.name).toSet();
  late final Set<String> structNames = spec.structs.map((s) => s.name).toSet();
  late final Set<String> recordNames = spec.recordTypes.map((r) => r.name).toSet();
  late final Set<String> variantNames = spec.variants.map((v) => v.name).toSet();
  late final Set<String> customTypeNames = spec.customTypes.map((c) => c.name).toSet();
  late final Set<String> knownTypes = {
    ..._knownPrimitives,
    ...enumNames,
    ...structNames,
    ...recordNames,
    ...variantNames,
    ...customTypeNames,
  };

  /// C symbols seen so far: a method and a stream must not share one.
  final seenSymbols = <String>{};
}
