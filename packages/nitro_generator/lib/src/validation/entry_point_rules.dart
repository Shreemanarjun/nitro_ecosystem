part of '../spec_validator.dart';

// Rules for `@NitroEntryPoint` background functions.

void _validateEntryPoints(BridgeSpec spec, List<ValidationIssue> issues) {
  if (spec.entryPoints.isEmpty) return;
  final seen = <String>{};
  final nativeTargets = spec.iosImpl != null || spec.androidImpl != null || spec.macosImpl != null || spec.windowsImpl != null || spec.linuxImpl != null;
  if (!nativeTargets) {
    issues.add(
      ValidationIssue(
        severity: ValidationSeverity.error,
        code: 'ENTRY_POINT_NO_NATIVE_TARGET',
        message: '${spec.dartClassName}: @NitroEntryPoint needs a native platform — background entry points are not available on web.',
        hint: 'Add at least one of ios/android/macos/windows/linux to @NitroModule.',
      ),
    );
  }
  for (final e in spec.entryPoints) {
    if (!seen.add(e.name)) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'ENTRY_POINT_DUPLICATE',
          message: '@NitroEntryPoint "${e.name}" is declared more than once.',
          hint: 'Entry point names must be unique within the spec file.',
        ),
      );
    }
    final problems = <String>[];
    for (final p in e.params) {
      final why = SpecValidator.entryPointTypeProblem(p.type);
      if (why != null) problems.add('parameter "${p.name}" (${p.type.name}): $why');
    }
    if (!e.returnsVoid) {
      final why = SpecValidator.entryPointTypeProblem(e.returnType);
      if (why != null) problems.add('return type ${e.returnType.name}: $why');
    }
    for (final why in problems) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'ENTRY_POINT_UNSUPPORTED_TYPE',
          message: '@NitroEntryPoint "${e.name}" — $why.',
          hint: 'Pass data by value: primitives, String, DateTime, enums, @HybridRecord/@HybridStruct/@NitroVariant/@NitroTuple, lists, maps, typed data, NitroAnyMap, @NitroCustomType; handles/pointers by address; void callbacks with positional parameters.',
        ),
      );
    }
  }
}
