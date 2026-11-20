import 'package:nitro_annotations/nitro_annotations.dart' show CppImpl, KotlinImpl, NativeImpl, SwiftImpl, WasmImpl;

import 'apple_system_names.dart';
import 'bridge_spec.dart';
import 'map_wire.dart';
import 'swift_reserved_names.dart';

part 'validation/known_types.dart';
part 'validation/map_rules.dart';
part 'validation/callback_rules.dart';
part 'validation/entry_point_rules.dart';
part 'validation/struct_rules.dart';
part 'validation/rules.dart';
part 'validation/platform_rules.dart';
part 'validation/function_rules.dart';
part 'validation/property_rules.dart';
part 'validation/stream_rules.dart';
part 'validation/type_rules.dart';
part 'validation/result_rules.dart';

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

  /// Runs all validation rules on [spec] and returns the list of issues.
  static List<ValidationIssue> validate(BridgeSpec spec) {
    final rules = _Rules(spec);
    _validateEntryPoints(spec, rules.issues);
    rules
      ..platforms()
      ..functions()
      ..properties()
      ..streams()
      ..types()
      ..results()
      ..structs();
    return rules.issues;
  }

  /// Nullable map values ride the String-key wire's per-value type tag as
  /// tag 0. Two cases still cannot: an int-key map's values are untagged
  /// (homogeneous, no room for a null marker), and enum/record/variant values
  /// go through Swift's `compactMapValues`, which silently DROPS nil entries
  /// rather than keeping the key.

  /// Why a [BridgeType] cannot cross the background job blob, or null when it
  /// can. The blob is the record wire format, so anything a record field or a
  /// function parameter can carry by value is allowed. Handles, pointers and
  /// AnyNativeObject cross by address/id (same process — the caller keeps
  /// ownership); custom types go through their codec; a void callback with
  /// positional parameters becomes a proxy that posts each call back to the
  /// submitting isolate. Only streams-as-parameters and nested futures have no
  /// by-value meaning.
  static String? entryPointTypeProblem(BridgeType t) {
    switch (t.kind) {
      case BridgeTypeKind.function_:
        if (t.functionReturnType != 'void') return 'a callback must return void — its result cannot cross back to the background isolate';
        if (t.name.contains('{') || t.name.contains('[')) return 'callback parameters must be positional';
        return null;
      case BridgeTypeKind.stream:
        return 'a stream cannot be passed in (return Stream<T> to stream results out instead)';
      case BridgeTypeKind.future:
        return 'nested Future types are not supported (the entry point itself may be async)';
      default:
        return null;
    }
  }

}
