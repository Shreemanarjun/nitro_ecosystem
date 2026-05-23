import 'package:nitro_annotations/nitro_annotations.dart' show CppImpl, KotlinImpl, WasmImpl;

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

  /// Runs all validation rules on [spec] and returns the list of issues.
  static List<ValidationIssue> validate(BridgeSpec spec) {
    final issues = <ValidationIssue>[];

    // ── Platform targeting ─────────────────────────────────────────────────
    if (spec.iosImpl == null && spec.androidImpl == null && spec.macosImpl == null && spec.windowsImpl == null && spec.linuxImpl == null && spec.webImpl == null) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'NO_TARGET_PLATFORM',
          message: '${spec.dartClassName}: at least one platform must be specified in @NitroModule.',
          hint:
              'Add one or more platform fields: `ios: NativeImpl.swift`, '
              '`android: NativeImpl.kotlin`, `macos: NativeImpl.cpp`, '
              '`windows: NativeImpl.cpp`, `linux: NativeImpl.cpp`, '
              'or `web: NativeImpl.wasm`.',
        ),
      );
    }

    // Defensive platform impl checks. At the @NitroModule annotation level these
    // are compile-time errors (marker interfaces prevent invalid assignments).
    // The checks below guard against BridgeSpec being constructed directly.

    // macOS: only Swift or C++ — not Kotlin.
    if (spec.macosImpl is KotlinImpl) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'INVALID_MACOS_IMPL',
          message: '${spec.dartClassName}: macOS does not support NativeImpl.kotlin.',
          hint: 'Use `macos: NativeImpl.cpp` or `macos: NativeImpl.swift` instead.',
        ),
      );
    }

    // Windows: only C++.
    if (spec.windowsImpl != null && spec.windowsImpl is! CppImpl) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'INVALID_WINDOWS_IMPL',
          message: '${spec.dartClassName}: Windows only supports NativeImpl.cpp.',
          hint: 'Use `windows: NativeImpl.cpp` — Windows requires direct C++ via CMake/MSVC.',
        ),
      );
    }

    // Linux: only C++.
    if (spec.linuxImpl != null && spec.linuxImpl is! CppImpl) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'INVALID_LINUX_IMPL',
          message: '${spec.dartClassName}: Linux only supports NativeImpl.cpp.',
          hint: 'Use `linux: NativeImpl.cpp` — Linux requires direct C++ via CMake/GCC/Clang.',
        ),
      );
    }

    // Web: only WASM. This is the most critical check — CppImpl on web would
    // generate dart:ffi code that fails to compile for web targets.
    if (spec.webImpl != null && spec.webImpl is! WasmImpl) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'INVALID_WEB_IMPL',
          message: '${spec.dartClassName}: Web only supports NativeImpl.wasm.',
          hint:
              'Use `web: NativeImpl.wasm` — dart:ffi is unavailable on web. '
              'Web requires WASM/JS interop. Compile your C++ to WASM using Emscripten.',
        ),
      );
    }

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
            message: '${spec.dartClassName}: duplicate C symbol "${func.cSymbol}".',
            hint: 'Two functions map to the same C symbol. Rename one of them.',
          ),
        );
      }

      // E001: Map<K, V> where K is not String.
      // isMap is only set by the extractor for Map<String, V>; a bare Map<K,V>
      // with a non-String key falls through here and needs a specific hint.
      if (func.returnType.name.startsWith('Map<') && !func.returnType.isMap) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E001',
            message:
                '${spec.dartClassName}.${func.dartName}() — return type "${func.returnType.name}" uses a non-String Map key. '
                'Only Map<String, V> is supported.',
            hint: 'Change the key type to String: Map<String, ${func.returnType.name.contains(',') ? func.returnType.name.split(',').last.trim().replaceFirst('>', '') : 'V'}>.',
          ),
        );
      }

      // Return type
      final retName = func.returnType.name.replaceFirst('?', '');
      if (retName != 'void' &&
          !func.returnType.isRecord && // @HybridRecord types bridge as String
          !func.returnType.isPointer && // raw FFI pointers
          !_isKnownType(retName, knownTypes) &&
          !_isKnownType(func.returnType.name, knownTypes)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNKNOWN_RETURN_TYPE',
            message: '${spec.dartClassName}.${func.dartName}() — unknown return type "$retName".',
            hint:
                'If "$retName" is a struct, annotate it with @HybridStruct. '
                'If it is an enum, annotate it with @HybridEnum. '
                'If it is a complex/nested type (lists, nested objects), annotate it with @HybridRecord.',
          ),
        );
      }

      // Prohibit naked TypedData return
      if (func.returnType.isTypedData) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_RETURN_TYPE',
            message: '${spec.dartClassName}.${func.dartName}() — naked TypedData return type "${func.returnType.name}" is not supported.',
            hint: 'Wrap TypedData in a @HybridStruct with a sibling length field and mark it as @ZeroCopy.',
          ),
        );
      }

      // Warn: large struct returned synchronously
      if (!func.isAsync && structNames.contains(retName)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'SYNC_STRUCT_RETURN',
            message: '${spec.dartClassName}.${func.dartName}() returns struct "$retName" synchronously.',
            hint: 'Add @nitroAsync to dispatch on a background isolate and avoid blocking the UI thread.',
          ),
        );
      }

      // Warn: @HybridRecord returned synchronously (JSON decode is non-trivial)
      if (!func.isAsync && func.returnType.isRecord) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'SYNC_RECORD_RETURN',
            message: '${spec.dartClassName}.${func.dartName}() returns a @HybridRecord type synchronously.',
            hint: 'Add @nitroAsync to dispatch on a background isolate; JSON serialization blocks the calling thread.',
          ),
        );
      }

      // E002: @nitroAsync on a non-Future return type.
      // Void is permitted (fire-and-forget async); any other non-Future type is invalid.
      if (func.isAsync && func.returnType.name != 'void' && !func.returnType.isFuture) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E002',
            message:
                '${spec.dartClassName}.${func.dartName}() — @nitroAsync requires a Future<T> return type, '
                'got "${func.returnType.name}".',
            hint:
                'Change the return type to Future<${func.returnType.name}>, or remove @nitroAsync.',
          ),
        );
      }

      // Parameter types
      for (final param in func.params) {
        // E001: Map<K, V> where K is not String.
        if (param.type.name.startsWith('Map<') && !param.type.isMap) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E001',
              message:
                  '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" type "${param.type.name}" uses a non-String Map key. '
                  'Only Map<String, V> is supported.',
              hint: 'Change the key type to String.',
            ),
          );
        }

        final pName = param.type.name.replaceFirst('?', '');
        if (!param.type.isRecord && // @HybridRecord params bridge as String
            !param.type.isPointer && // raw FFI pointers
            !_isKnownType(pName, knownTypes) &&
            !_isKnownType(param.type.name, knownTypes)) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'UNKNOWN_PARAM_TYPE',
              message: '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" has unknown type "$pName".',
              hint:
                  'If "$pName" is a struct, annotate it with @HybridStruct. '
                  'If it is an enum, annotate it with @HybridEnum. '
                  'If it is a complex/nested type, annotate it with @HybridRecord.',
            ),
          );
        }

        // W001/W002/W003: non-nullable named optional param with no defaultLiteral.
        // The generated `{Type name}` is invalid Dart — non-nullable named params
        // must be `required` or have a default value.
        // Nullability is signalled by either the `isNullable` flag OR a trailing `?`
        // in the type name string (the convention used throughout the generators).
        // W002 is emitted for @HybridEnum types; W003 for @HybridStruct types;
        // W001 for all other (primitive) types.
        final paramIsNullable = param.type.isNullable || param.type.name.endsWith('?');
        if (param.isNamed &&
            param.isOptional &&
            !paramIsNullable &&
            param.defaultLiteral == null) {
          final bareTypeName = param.type.name.replaceFirst('?', '');
          if (enumNames.contains(bareTypeName)) {
            issues.add(
              ValidationIssue(
                severity: ValidationSeverity.warning,
                code: 'W002',
                message:
                    '${spec.dartClassName}.${func.dartName}() — named param '
                    '"${param.name}: ${param.type.name}" is a non-nullable @HybridEnum with no default value. '
                    'The generated `{${param.type.name} ${param.name}}` is invalid Dart.',
                hint:
                    'Add a default value (e.g. ${param.type.name}.firstCase) to the spec, '
                    'or make the param nullable (`${param.type.name}? ${param.name}`).',
              ),
            );
          } else if (structNames.contains(bareTypeName)) {
            issues.add(
              ValidationIssue(
                severity: ValidationSeverity.warning,
                code: 'W003',
                message:
                    '${spec.dartClassName}.${func.dartName}() — named param '
                    '"${param.name}: ${param.type.name}" is a non-nullable @HybridStruct with no default value. '
                    'The generated `{${param.type.name} ${param.name}}` is invalid Dart.',
                hint:
                    'Add a default value (e.g. ${param.type.name}()) to the spec, '
                    'or make the param nullable (`${param.type.name}? ${param.name}`).',
              ),
            );
          } else {
            issues.add(
              ValidationIssue(
                severity: ValidationSeverity.warning,
                code: 'W001',
                message:
                    '${spec.dartClassName}.${func.dartName}() — named param '
                    '"${param.name}: ${param.type.name}" is non-nullable with no default value. '
                    'The generated `{${param.type.name} ${param.name}}` is invalid Dart.',
                hint:
                    'Use `${param.type.name}? ${param.name}` (nullable) and handle the default '
                    'in native code, or add a default value to the spec.',
              ),
            );
          }
        }
      }
    }

    // ── Properties ─────────────────────────────────────────────────────────
    for (final prop in spec.properties) {
      final pName = prop.type.name.replaceFirst('?', '');
      if (!prop.type.isRecord && !prop.type.isPointer && !_isKnownType(pName, knownTypes) && !_isKnownType(prop.type.name, knownTypes)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNKNOWN_PROPERTY_TYPE',
            message: '${spec.dartClassName}.${prop.dartName} — unknown property type "$pName".',
            hint:
                'If "$pName" is a struct, annotate it with @HybridStruct. '
                'If it is an enum, annotate it with @HybridEnum. '
                'If it is a complex/nested type, annotate it with @HybridRecord.',
          ),
        );
      }

      if (prop.type.isTypedData) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_PROPERTY_TYPE',
            message: '${spec.dartClassName}.${prop.dartName} — naked TypedData property type "${prop.type.name}" is not supported.',
            hint: 'Wrap TypedData in a @HybridStruct with a sibling length field and mark it as @ZeroCopy.',
          ),
        );
      }
    }

    // ── Streams ────────────────────────────────────────────────────────────
    for (final stream in spec.streams) {
      final iName = stream.itemType.name.replaceFirst('?', '');
      if (!_isKnownType(iName, knownTypes) && !_isKnownType(stream.itemType.name, knownTypes)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNKNOWN_STREAM_ITEM_TYPE',
            message: '${spec.dartClassName}.${stream.dartName} — unknown stream item type "$iName".',
            hint:
                'If "$iName" is a struct, annotate it with @HybridStruct. '
                'If it is an enum, annotate it with @HybridEnum. '
                'If it is a complex/nested type, annotate it with @HybridRecord.',
          ),
        );
      }

      if (!seenSymbols.add(stream.registerSymbol)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'DUPLICATE_SYMBOL',
            message: '${spec.dartClassName}: duplicate C symbol "${stream.registerSymbol}".',
          ),
        );
      }
    }

    // ── Structs ────────────────────────────────────────────────────────────
    for (final st in spec.structs) {
      for (final field in st.fields) {
        final fName = field.type.name.replaceFirst('?', '');
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

    return issues;
  }

  /// DFS-based cycle detection over @HybridStruct field references.
  ///
  /// A struct may reference another struct as a field type; if this forms a
  /// cycle (directly or transitively) the generators would recurse infinitely.
  static List<ValidationIssue> _detectStructCycles(BridgeSpec spec) {
    // Build adjacency: structName → names of other structs referenced by fields.
    final adj = <String, List<String>>{};
    for (final st in spec.structs) {
      adj[st.name] = st.fields.map((f) => f.type.name.replaceFirst('?', '')).where((t) => spec.structs.any((s) => s.name == t)).toList();
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
                    '(heap-allocated, JSON-bridged).',
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

  static bool _isKnownType(String typeName, Set<String> knownTypes) {
    if (knownTypes.contains(typeName)) return true;

    final withoutNullability = typeName.replaceFirst('?', '');
    if (knownTypes.contains(withoutNullability)) return true;

    final genericMatch = RegExp(r'^(\w+)<(.+)>$').firstMatch(typeName);
    if (genericMatch != null) {
      final containerType = genericMatch.group(1)!;
      final innerType = genericMatch.group(2)!;

      if (containerType == 'List' || containerType == 'Set') {
        final innerWithoutNullability = innerType.replaceFirst('?', '');
        return knownTypes.contains(innerWithoutNullability) || knownTypes.contains(innerType);
      }
    }

    return false;
  }
}
