part of '../spec_validator.dart';

// Rules for the declared types: record fields, enum values, names the
// native languages reserve, variant sizes.

extension _TypeRules on _Rules {
  void types() {
    // ── E013: @HybridRecord field type references ─────────────────────────
    for (final rt in spec.recordTypes) {
      for (final field in rt.fields) {
        // RecordFieldKind is set by the spec extractor — if kind is known
        // (primitive, enumValue, recordObject, etc.) the type is already resolved.
        // Only report E013 for primitive-kind fields whose dartType base name
        // is not in the known types set, which signals an unresolved reference.
        if (field.kind != RecordFieldKind.primitive) continue;
        final fName = bareTypeName(field.dartType).split('<').first.trim();
        if (!_isKnownType(fName, knownTypes)) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E013',
              message: '${rt.name}.${field.name} — unknown @HybridRecord field type "$fName".',
              hint:
                  'If "$fName" is an enum, annotate it with @HybridEnum. '
                  'If it is a struct, annotate it with @HybridStruct. '
                  'If it is a nested record, annotate it with @HybridRecord and mark it as imported.',
            ),
          );
        }
      }
    }

    // ── E020: duplicate @HybridEnum native values ─────────────────────────
    // Two cases sharing a raw value cannot round-trip: the wire carries the
    // number, so decoding picks whichever case the generated lookup happens to
    // reach first and the other silently becomes unreachable. It also emits
    // duplicate Dart switch cases and, on Swift, an invalid enum with two
    // identical raw values.
    for (final e in spec.enums) {
      final raw = e.rawValues;
      if (raw == null || raw.length != e.values.length) continue;
      final seen = <int, String>{};
      final dupes = <String>[];
      for (var i = 0; i < raw.length; i++) {
        final first = seen[raw[i]];
        if (first != null) {
          dupes.add('${e.values[i]} and $first both = ${raw[i]}');
        } else {
          seen[raw[i]] = e.values[i];
        }
      }
      if (dupes.isNotEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E020',
            message: '@HybridEnum ${e.name} has duplicate native values: ${dupes.join(', ')}.',
            hint: 'Every case needs a distinct native value — the wire carries the number, so duplicates make one case undecodable.',
          ),
        );
      }
    }

    // ── E021: a struct or enum with a name built into Objective-C ─────────
    // Each one becomes a C typedef of the same name at file scope, in a bridge
    // that is compiled as Objective-C++ on Apple. The bridge renames the names
    // Foundation defines while it imports it; a name the language itself
    // defines cannot be renamed, and the plugin does not compile there.
    if (spec.targetsIos || spec.targetsMacos) {
      final declared = {for (final st in spec.structs) st.name: '@HybridStruct', for (final e in spec.enums) e.name: '@HybridEnum'};
      for (final MapEntry(key: name, value: kind) in declared.entries) {
        if (!foundationNamesNotRenamable.contains(name)) continue;
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E021',
            message: '$kind $name has a name built into Objective-C, so the generated bridge does not compile on iOS or macOS.',
            hint: 'Rename it, for example ${spec.dartClassName}$name.',
          ),
        );
      }
    }

    // ── E022: a name the Swift bridge cannot declare ─────────────────────
    // The bridge writes spec names as they are, so a Swift keyword (`where`,
    // or the `default` a variant case named ModeDefault becomes) fails to
    // compile. Checked for exactly the modules that get a Swift bridge.
    if (spec.iosImpl != null || spec.macosImpl is SwiftImpl) {
      final iosCpp = spec.iosImpl is CppImpl;
      final macosCpp = spec.macosImpl == null ? iosCpp : spec.macosImpl is CppImpl;
      void check(String name, SwiftNameUse use, String what) {
        if (!swiftRejectsName(name, use, hasCallStubs: !(iosCpp && macosCpp))) return;
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E022',
            message: '$what "$name" is not a name the generated Swift bridge can declare, so the plugin does not compile on iOS or macOS.',
            hint: 'Rename it. Swift reserves the word, or the bridge uses it itself.',
          ),
        );
      }

      for (final f in spec.functions) {
        check(f.dartName, f.isGetter ? SwiftNameUse.property : SwiftNameUse.method, f.isGetter ? 'Getter' : 'Method');
        for (final p in f.params) {
          check(p.name, SwiftNameUse.parameter, 'Parameter of ${f.dartName}()');
        }
      }
      for (final p in spec.properties) {
        check(p.dartName, SwiftNameUse.property, 'Property');
      }
      for (final s in spec.streams) {
        check(s.dartName, SwiftNameUse.property, 'Stream');
      }
      for (final st in spec.localStructs) {
        for (final f in st.fields) {
          check(f.name, SwiftNameUse.field, 'Field of ${st.name}');
        }
      }
      for (final e in spec.localEnums) {
        for (final v in e.values) {
          check(v, SwiftNameUse.enumValue, 'Value of ${e.name}');
        }
      }
      for (final r in spec.localRecordTypes) {
        for (final f in r.fields) {
          check(f.name, SwiftNameUse.field, 'Field of ${r.name}');
        }
      }
      for (final v in spec.localVariants) {
        for (final c in v.cases) {
          check(c.label, SwiftNameUse.variantCase, 'Case ${c.name} of ${v.name}, whose Swift case is');
          for (final f in c.fields) {
            check(f.name, SwiftNameUse.variantField, 'Field of ${c.name}');
          }
        }
      }
    }

    // ── E014: @NitroVariant case count ────────────────────────────────────
    for (final variant in spec.variants) {
      if (variant.cases.isEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E014',
            message: '${variant.name} — @NitroVariant has no cases.',
            hint: 'Add at least one concrete subclass of ${variant.name}.',
          ),
        );
      } else if (variant.cases.length > 255) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E014',
            message: '${variant.name} — @NitroVariant has ${variant.cases.length} cases (max 255).',
            hint: 'Split "${variant.name}" into multiple variant types, each with ≤ 255 cases.',
          ),
        );
      }
    }
  }
}
