part of '../spec_validator.dart';

// Rules for `@HybridStruct` declarations: field types and cycles.

/// DFS-based cycle detection over @HybridStruct field references.
///
/// A struct may reference another struct as a field type; if this forms a
/// cycle (directly or transitively) the generators would recurse infinitely.
List<ValidationIssue> _detectStructCycles(BridgeSpec spec) {
  // Build adjacency: structName → names of other structs referenced by fields.
  final adj = <String, List<String>>{};
  for (final st in spec.structs) {
    adj[st.name] = st.fields.map((f) => bareTypeName(f.type.name)).where(spec.isStructName).toList();
  }

  // 0 = unvisited, 1 = in DFS stack, 2 = fully processed.
  final state = <String, int>{for (final k in adj.keys) k: 0};
  final issues = <ValidationIssue>[];
  // Track which cycles have already been reported (by canonical sorted key).
  final reported = <String>{};

  void dfs(String node, List<String> path) {
    state[node] = 1;
    for (final neighbor in adj[node]!) {
      if (state[neighbor] == 1) {
        // Back-edge found — reconstruct cycle from path.
        final cycleStart = path.indexOf(neighbor);
        final cyclePath = [...path.sublist(cycleStart), neighbor];
        final key = (cyclePath.toSet().toList()..sort()).join(',');
        if (reported.add(key)) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'CYCLIC_STRUCT',
              message:
                  'Cyclic @HybridStruct dependency detected: '
                  '${cyclePath.join(' → ')}.',
              hint:
                  '@HybridStruct fields cannot form reference cycles — they '
                  'are value types laid out inline in C memory. '
                  'Break the cycle by replacing one side with @HybridRecord '
                  '(heap-allocated, binary-encoded).',
            ),
          );
        }
      } else if ((state[neighbor] ?? 0) == 0) {
        dfs(neighbor, [...path, neighbor]);
      }
    }
    state[node] = 2;
  }

  for (final name in adj.keys) {
    if (state[name] == 0) dfs(name, [name]);
  }
  return issues;
}

extension _StructRules on _Rules {
  void structs() {
    // ── Structs ────────────────────────────────────────────────────────────
    for (final st in spec.structs) {
      for (final field in st.fields) {
        final fName = bareTypeName(field.type.name);
        if (!_knownPrimitives.contains(fName) && !structNames.contains(fName) && !enumNames.contains(fName)) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'INVALID_STRUCT_FIELD_TYPE',
              message: '${st.name}.${field.name} — struct field type "$fName" is not supported.',
              hint:
                  'Struct fields must be int, double, bool, String, TypedData, '
                  'a @HybridEnum, or another @HybridStruct. '
                  'For complex/nested fields, use @HybridRecord instead of @HybridStruct.',
            ),
          );
        }

        if (field.zeroCopy && !field.type.isTypedData) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'INVALID_ZERO_COPY',
              message: '${st.name}.${field.name} — @zero_copy is only valid on TypedData fields like Uint8List or Float32List (got "$fName").',
            ),
          );
        }
      }
    }

    // ── Cyclic struct dependencies ─────────────────────────────────────────
    issues.addAll(_detectStructCycles(spec));
  }
}
