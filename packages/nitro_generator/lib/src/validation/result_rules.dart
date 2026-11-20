part of '../spec_validator.dart';

// Rules for `@NitroResult` methods (E015).

extension _ResultRules on _Rules {
  void results() {
    // ── E015: @NitroResult validation ─────────────────────────────────────
    for (final func in spec.functions) {
      if (!func.isResult) continue;
      // @nitroAsync is allowed: bridge dispatches on a background thread and
      // Dart receives Future<NitroResultValue<T>>. @NitroNativeAsync is blocked
      // because Dart_PostCObject_DL only supports primitive CObject types and
      // cannot encode a NitroResultValue buffer.
      if (func.isNativeAsync) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E015',
            message: '${func.dartName}() — @NitroResult cannot be combined with @NitroNativeAsync.',
            hint:
                'Remove @NitroNativeAsync from ${func.dartName}. '
                'For an async @NitroResult method use @nitroAsync instead.',
          ),
        );
      }
      if (func.returnType.name == 'void') {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E015',
            message: '${func.dartName}() — @NitroResult cannot wrap void return type.',
            hint: 'Use a non-void return type or remove @NitroResult if you only need error propagation.',
          ),
        );
      } else if (spec.resultCarrier(func) is NoCarrier) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E015',
            message: '${func.dartName}() — "${func.returnType.name}" is not supported as a @NitroResult value.',
            hint:
                'A @NitroResult value can be int, double, bool, String, DateTime, uint64, a @HybridEnum, '
                '@HybridStruct, @HybridRecord or @NitroVariant, typed data, a List of scalars, enums, '
                'records or variants, a Map<String, V>, a NitroAnyMap, or a nullable form of any of them. '
                'Put anything else in a @HybridRecord field, or return it from a plain method and '
                'report failure by throwing.',
          ),
        );
      }
    }
  }
}
