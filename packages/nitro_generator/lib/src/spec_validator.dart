import 'bridge_spec.dart';

enum ValidationSeverity { error, warning }

class ValidationIssue {
  final ValidationSeverity severity;
  final String code;
  final String message;
  final String? hint;

  const ValidationIssue({
    required this.severity,
    required this.code,
    required this.message,
    this.hint,
  });

  bool get isError => severity == ValidationSeverity.error;

  @override
  String toString() {
    final tag = isError ? 'ERROR' : 'WARNING';
    final hintLine = hint != null ? '\n         Hint: $hint' : '';
    return '$tag  [$code]  $message$hintLine';
  }
}

/// Validates a [BridgeSpec] and returns any issues found.
///
/// Call this before invoking the generators. If any [ValidationIssue.isError]
/// issues are returned, generation should be aborted.
class SpecValidator {
  static const _knownPrimitives = {
    'int',
    'double',
    'bool',
    'String',
    'void',
    'Uint8List',
    'int?',
    'double?',
    'bool?',
    'String?',
    'Uint8List?',
  };

  /// Runs all validation rules on [spec] and returns the list of issues.
  static List<ValidationIssue> validate(BridgeSpec spec) {
    final issues = <ValidationIssue>[];
    final enumNames = spec.enums.map((e) => e.name).toSet();
    final structNames = spec.structs.map((s) => s.name).toSet();
    final recordNames = spec.recordTypes.map((r) => r.name).toSet();
    final knownTypes = {
      ..._knownPrimitives,
      ...enumNames,
      ...structNames,
      ...recordNames,
    };

    // ── Functions ──────────────────────────────────────────────────────────
    final seenSymbols = <String>{};
    for (final func in spec.functions) {
      // Duplicate C symbols
      if (!seenSymbols.add(func.cSymbol)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'DUPLICATE_SYMBOL',
            message:
                '${spec.dartClassName}: duplicate C symbol "${func.cSymbol}".',
            hint: 'Two functions map to the same C symbol. Rename one of them.',
          ),
        );
      }

      // Return type
      final retName = func.returnType.name.replaceFirst('?', '');
      if (retName != 'void' &&
          !func.returnType.isRecord && // @HybridRecord types bridge as String
          !knownTypes.contains(retName) &&
          !knownTypes.contains(func.returnType.name)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNKNOWN_RETURN_TYPE',
            message:
                '${spec.dartClassName}.${func.dartName}() — unknown return type "$retName".',
            hint:
                'If "$retName" is a struct, annotate it with @HybridStruct. '
                'If it is an enum, annotate it with @HybridEnum. '
                'If it is a complex/nested type (lists, nested objects), annotate it with @HybridRecord.',
          ),
        );
      }

      // Warn: large struct returned synchronously
      if (!func.isAsync && structNames.contains(retName)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'SYNC_STRUCT_RETURN',
            message:
                '${spec.dartClassName}.${func.dartName}() returns struct "$retName" synchronously.',
            hint:
                'Add @nitroAsync to dispatch on a background isolate and avoid blocking the UI thread.',
          ),
        );
      }

      // Warn: @HybridRecord returned synchronously (JSON decode is non-trivial)
      if (!func.isAsync && func.returnType.isRecord) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'SYNC_RECORD_RETURN',
            message:
                '${spec.dartClassName}.${func.dartName}() returns a @HybridRecord type synchronously.',
            hint:
                'Add @nitroAsync to dispatch on a background isolate; JSON serialization blocks the calling thread.',
          ),
        );
      }

      // Parameter types
      for (final param in func.params) {
        final pName = param.type.name.replaceFirst('?', '');
        if (!param.type.isRecord && // @HybridRecord params bridge as String
            !knownTypes.contains(pName) &&
            !knownTypes.contains(param.type.name)) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'UNKNOWN_PARAM_TYPE',
              message:
                  '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" has unknown type "$pName".',
              hint:
                  'If "$pName" is a struct, annotate it with @HybridStruct. '
                  'If it is an enum, annotate it with @HybridEnum. '
                  'If it is a complex/nested type, annotate it with @HybridRecord.',
            ),
          );
        }
      }
    }

    // ── Properties ─────────────────────────────────────────────────────────
    for (final prop in spec.properties) {
      final pName = prop.type.name.replaceFirst('?', '');
      if (!prop.type.isRecord &&
          !knownTypes.contains(pName) &&
          !knownTypes.contains(prop.type.name)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNKNOWN_PROPERTY_TYPE',
            message:
                '${spec.dartClassName}.${prop.dartName} — unknown property type "$pName".',
            hint:
                'If "$pName" is a struct, annotate it with @HybridStruct. '
                'If it is an enum, annotate it with @HybridEnum. '
                'If it is a complex/nested type, annotate it with @HybridRecord.',
          ),
        );
      }
    }

    // ── Streams ────────────────────────────────────────────────────────────
    for (final stream in spec.streams) {
      final iName = stream.itemType.name.replaceFirst('?', '');
      if (!stream.itemType.isRecord &&
          !knownTypes.contains(iName) &&
          !knownTypes.contains(stream.itemType.name)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNKNOWN_STREAM_ITEM_TYPE',
            message:
                '${spec.dartClassName}.${stream.dartName} — unknown stream item type "$iName".',
            hint:
                'Stream item types must be primitives, String, Uint8List, a @HybridStruct, or a @HybridRecord. '
                'Wrap complex types in a @HybridRecord.',
          ),
        );
      }

      // Duplicate stream register symbols
      if (!seenSymbols.add(stream.registerSymbol)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'DUPLICATE_SYMBOL',
            message:
                '${spec.dartClassName}: duplicate C symbol "${stream.registerSymbol}".',
          ),
        );
      }
    }

    // ── Structs ────────────────────────────────────────────────────────────
    for (final st in spec.structs) {
      for (final field in st.fields) {
        final fName = field.type.name.replaceFirst('?', '');
        // Struct fields may only be primitives, String, Uint8List, or other structs.
        // Enums as struct fields are not supported in the current bridge.
        if (!_knownPrimitives.contains(fName) && !structNames.contains(fName)) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'INVALID_STRUCT_FIELD_TYPE',
              message:
                  '${st.name}.${field.name} — struct field type "$fName" is not supported.',
              hint:
                  'Struct fields must be int, double, bool, String, Uint8List, or another @HybridStruct. '
                  'For complex/nested fields, use @HybridRecord instead of @HybridStruct.',
            ),
          );
        }

        // Zero-copy only valid on Uint8List
        if (field.zeroCopy && fName != 'Uint8List') {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'INVALID_ZERO_COPY',
              message:
                  '${st.name}.${field.name} — @zero_copy is only valid on Uint8List fields (got "$fName").',
            ),
          );
        }
      }
    }

    return issues;
  }
}
