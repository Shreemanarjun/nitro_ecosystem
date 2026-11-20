part of '../spec_validator.dart';

// Rules for a callback parameter: its return type, its parameter types and
// where it may appear (E016, UNSUPPORTED_FUNCTION_TYPE).

List<ValidationIssue> _validateCallbackParam(
  BridgeSpec spec,
  BridgeFunction func,
  BridgeParam param,
) {
  final issues = <ValidationIssue>[];
  final callback = param.type;
  final returnName = bareTypeName((callback.functionReturnType ?? 'void'));
  final enumNames = spec.enums.map((e) => e.name).toSet();

  // E016: callback param on a plain @NitroAsync (non-native-async) method.
  // The registering FFI call is dispatched onto a different isolate via
  // callAsync, so the calling isolate can't guarantee native has switched
  // to the new callback pointer before NitroRuntime.deferredClose runs.
  if (func.isAsync && !func.isNativeAsync) {
    issues.add(
      ValidationIssue(
        severity: ValidationSeverity.error,
        code: 'E016',
        message:
            '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" is a callback type, '
            'which is not supported on @NitroAsync methods.',
        hint:
            'Callback replacement relies on the native registration call being synchronous on the calling '
            'isolate. Remove @NitroAsync from ${func.dartName}() (registering a callback pointer is normally '
            'cheap), or use @NitroNativeAsync if native must register it off the calling thread.',
      ),
    );
  }

  final recordNames = spec.recordTypes.map((r) => r.name).toSet();
  final variantNames = spec.variants.map((v) => v.name).toSet();
  // Supported callback return types: primitives, AnyNativeObject, enums, @HybridRecord, @NitroVariant.
  final supportedReturn =
      returnName == 'void' ||
      returnName == 'int' ||
      returnName == 'double' ||
      returnName == 'bool' ||
      returnName == 'String' ||
      returnName == 'AnyNativeObject' ||
      returnName == 'uint64' ||
      enumNames.contains(returnName) ||
      recordNames.contains(returnName) ||
      variantNames.contains(returnName) ||
      // A flat struct travels back as bytes, like a record.
      spec.isFlatStruct(returnName);
  if (!supportedReturn) {
    issues.add(
      ValidationIssue(
        severity: ValidationSeverity.error,
        code: 'UNSUPPORTED_FUNCTION_TYPE',
        message: '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" callback return type "$returnName" is not supported.',
        hint: spec.isStructName(returnName)
            ? 'A @HybridStruct returned from a callback may only have non-null int, double, bool and String fields. '
                  'Make "$returnName" a @HybridRecord instead.'
            : 'Callback returns support void, int, double, bool, String, @HybridEnum, @HybridRecord, @NitroVariant, '
                  'and a @HybridStruct of non-null int, double, bool and String fields.',
      ),
    );
  }

  for (final callbackParam in callback.functionParams) {
    final name = bareTypeName(callbackParam.name);
    final structNames = spec.structs.map((s) => s.name).toSet();
    final recordNames = spec.recordTypes.map((r) => r.name).toSet();
    final variantNames = spec.variants.map((v) => v.name).toSet();
    final supportedParam =
        callbackParam.isPointer ||
        callbackParam.isAnyNativeObject ||
        name == 'int' ||
        name == 'double' ||
        name == 'bool' ||
        name == 'String' ||
        name == 'AnyNativeObject' ||
        name == 'uint64' ||
        enumNames.contains(name) ||
        structNames.contains(name) ||
        recordNames.contains(name) ||
        variantNames.contains(name);
    if (!supportedParam) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'UNSUPPORTED_FUNCTION_TYPE',
          message: '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" callback parameter type "${callbackParam.name}" is not supported.',
          hint: 'Callback parameters support int, double, bool, String, Pointer<T>, @HybridEnum, @HybridStruct, @HybridRecord, and @NitroVariant.',
        ),
      );
    }
  }

  return issues;
}
