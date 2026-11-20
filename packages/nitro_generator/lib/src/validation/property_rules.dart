part of '../spec_validator.dart';

// Rules for properties.

extension _PropertyRules on _Rules {
  void properties() {
    // ── Properties ─────────────────────────────────────────────────────────
    for (final prop in spec.properties) {
      final pName = bareTypeName(prop.type.name);

      // E004: Stream<T> as a property type is not supported. The property bridge
      // generates a C getter/setter — it cannot register a Dart port for streaming.
      // Stream properties should be declared as a getter on the @NitroModule directly.
      if (prop.type.isStream || pName.startsWith('Stream<')) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E004',
            message:
                '${spec.dartClassName}.${prop.dartName} — Stream<T> cannot be a property type. '
                'The property bridge generates a C getter/setter, which cannot handle async streams.',
            hint:
                'Declare a getter `Stream<T> get ${prop.dartName}` directly on the abstract class '
                '(not annotated with @NitroProperty). The generator treats un-annotated Stream getters as streams automatically.',
          ),
        );
        continue;
      }

      // void property type generates invalid C++ (void getter returns void — illegal).
      if (pName == 'void') {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_PROPERTY_TYPE',
            message: '${spec.dartClassName}.${prop.dartName} — property type "void" is not valid.',
            hint: 'Properties must have a concrete return type. Use a method `void doX()` instead.',
          ),
        );
        continue;
      }
      if (prop.type.isFunction) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNSUPPORTED_FUNCTION_TYPE',
            message: '${spec.dartClassName}.${prop.dartName} — property type "${prop.type.name}" is a function type, which is not a supported native ABI type.',
            hint: 'Use a Stream<T> for event-like values, or expose explicit native register and release methods around a stable callback/token handle.',
          ),
        );
        continue;
      }
      final propNullableMap = _nullableMapValueIssue(prop.type, '${spec.dartClassName}.${prop.dartName}');
      if (propNullableMap != null) issues.add(propNullableMap);
      if (!prop.type.isRecord && !prop.type.isPointer && !_isKnownType(pName, knownTypes) && !_isKnownType(prop.type.name, knownTypes)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E012',
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
            hint: 'Use a method instead: a typed-data return needs no annotation. Or wrap it in a @HybridStruct with a sibling length field.',
          ),
        );
      }

      // The Kotlin and Swift property bridges have no map codec: the generated
      // getter would hand a dictionary to C. A method carries a map in any
      // position, so point there instead of emitting code that cannot build.
      final hasKotlinOrSwift = spec.androidImpl is KotlinImpl || spec.iosImpl is SwiftImpl || spec.macosImpl is SwiftImpl;
      if ((prop.type.isMap || prop.type.isAnyMap) && hasKotlinOrSwift) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_PROPERTY_TYPE',
            message: '${spec.dartClassName}.${prop.dartName} — a "${prop.type.name}" property is not supported on a Kotlin or Swift implementation.',
            hint: 'Use methods instead: `${prop.type.name} ${prop.dartName}();`${prop.hasSetter ? ' and `void set${prop.dartName[0].toUpperCase()}${prop.dartName.substring(1)}(${prop.type.name} value);`' : ''}.',
          ),
        );
      }
    }
  }
}
