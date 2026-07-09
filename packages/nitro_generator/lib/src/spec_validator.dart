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
    'DateTime',
    'DateTime?',
    'uint64',
    'uint64?',
    'int8', 'int16', 'int32', 'uint8', 'uint16', 'uint32', 'float', 'intptr', 'size',
    'int8?', 'int16?', 'int32?', 'uint8?', 'uint16?', 'uint32?', 'float?', 'intptr?', 'size?',
    'AnyNativeObject',
    'AnyNativeObject?',
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

    // ── D4: @HybridStruct String field advisory ───────────────────────────────
    // String fields are heap-copied (strdup/free) on every bridge call.
    // For structs with string-heavy fields, @HybridRecord is more efficient.
    for (final st in spec.structs) {
      final stringFields = st.fields.where((f) => f.type.name == 'String' || f.type.name == 'String?').toList();
      if (stringFields.isNotEmpty) {
        final names = stringFields.map((f) => f.name).join(', ');
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'STRUCT_STRING_FIELD',
            message:
                '${spec.dartClassName}: @HybridStruct "${st.name}" has String field(s): $names.',
            hint:
                'String fields are heap-copied (strdup/free) on every bridge call. '
                'If this struct is on a hot path or carries large strings, '
                'consider @HybridRecord instead — it encodes once and decodes lazily.',
          ),
        );
      }
    }

    // ── PX5 / D7: Missing-platform warnings ──────────────────────────────────
    // Advisory: warn when a module targets only one side of the mobile duopoly.
    // Pure-desktop (windows/linux) and pure-web plugins are not warned about
    // because they are valid single-platform configurations.
    final hasAppleTarget = spec.iosImpl != null || spec.macosImpl != null;
    final hasAndroidTarget = spec.androidImpl != null;
    final hasMobileTarget = hasAppleTarget || hasAndroidTarget;
    if (hasMobileTarget && hasAppleTarget && !hasAndroidTarget) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          code: 'MISSING_ANDROID_TARGET',
          message:
              '${spec.dartClassName}: iOS/macOS is targeted but Android is not.',
          hint:
              'Add `android: NativeImpl.kotlin` (or `.cpp`) to target Android. '
              'If Android is intentionally excluded, add @NitroModule(android: null) or suppress this warning.',
        ),
      );
    }
    if (hasMobileTarget && hasAndroidTarget && !hasAppleTarget) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          code: 'MISSING_IOS_TARGET',
          message:
              '${spec.dartClassName}: Android is targeted but iOS/macOS is not.',
          hint:
              'Add `ios: NativeImpl.swift` (or `.cpp`) to target Apple platforms. '
              'If iOS is intentionally excluded, add @NitroModule(ios: null) or suppress this warning.',
        ),
      );
    }

    // W007: Web target with streams or @NitroNativeAsync — these throw UnsupportedError
    // at runtime because the web bridge generator does not implement them.
    if (spec.webImpl != null) {
      if (spec.streams.isNotEmpty) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'W007',
            message:
                '${spec.dartClassName}: ${spec.streams.length} stream(s) declared but the web '
                'bridge does not support Stream<T>. Calling stream getters on web will throw '
                'UnsupportedError at runtime.',
            hint:
                'Guard stream usage with `if (!kIsWeb)` or provide a web-specific stub. '
                'Consider using a polling function instead for web.',
          ),
        );
      }
      final hasNativeAsync = spec.functions.any((f) => f.isNativeAsync);
      if (hasNativeAsync) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'W007',
            message:
                '${spec.dartClassName}: @NitroNativeAsync method(s) declared but the web '
                'bridge does not support NativeAsync. Calling these methods on web will throw '
                'UnsupportedError at runtime.',
            hint:
                'Guard @NitroNativeAsync methods with `if (!kIsWeb)` or use @nitroAsync instead.',
          ),
        );
      }
    }


    final enumNames = spec.enums.map((e) => e.name).toSet();
    final structNames = spec.structs.map((s) => s.name).toSet();
    final recordNames = spec.recordTypes.map((r) => r.name).toSet();
    final variantNames = spec.variants.map((v) => v.name).toSet();
    final customTypeNames = spec.customTypes.map((c) => c.name).toSet();
    final knownTypes = {
      ..._knownPrimitives,
      ...enumNames,
      ...structNames,
      ...recordNames,
      ...variantNames,
      ...customTypeNames,
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

      // E001: Map<K, V> where K is not String, int, or a known @HybridEnum.
      // isMap is only set by the extractor for Map<String, V>; a bare Map<K,V>
      // with a non-String key falls through here and needs a specific hint.
      if (func.returnType.name.startsWith('Map<') && !func.returnType.isMap) {
        final keyType = BridgeType.extractMapKeyType(func.returnType.name);
        final rawValueType = func.returnType.name.contains(',')
            ? func.returnType.name.split(',').last.trim().replaceFirst('>', '')
            : 'V';
        // Allow integer key types and enum key types (Gap #3).
        const intKeyTypes = {'int', 'int8', 'int16', 'int32', 'int64', 'uint8', 'uint16', 'uint32', 'uint64'};
        final isAllowedKey = keyType != null &&
            (intKeyTypes.contains(keyType) || enumNames.contains(keyType));
        if (!isAllowedKey) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E001',
              message:
                  '${spec.dartClassName}.${func.dartName}() — return type "${func.returnType.name}" uses a non-String Map key. '
                  'Only Map<String, V>, Map<int, V>, and Map<@HybridEnum, V> are supported.',
              hint: 'Change the key type to String, int, or a @HybridEnum. '
                  'If you need a string key, use Map<String, $rawValueType>.',
            ),
          );
        }
      }

      // E003: Nested Map (Map<String, Map<…>>) is not supported — the binary
      // encoder only handles flat Map<String, scalar/record> values.
      if (func.returnType.isMap && func.returnType.name.contains('Map<String, Map<')) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E003',
            message:
                '${spec.dartClassName}.${func.dartName}() — nested Map return type "${func.returnType.name}" is not supported. '
                'The binary map encoder only handles flat Map<String, V> values.',
            hint: 'Flatten the structure, or annotate a wrapper class with @HybridRecord and return that instead.',
          ),
        );
      }

      // @NitroOwned validation
      if (func.isOwned) {
        if (!func.returnType.isNativeHandle) {
          issues.add(ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_OWNED',
            message: '${spec.dartClassName}.${func.dartName}() — @NitroOwned requires a NativeHandle<T> return type, got "${func.returnType.name}".',
            hint: 'Change the return type to NativeHandle<T>, or remove @NitroOwned.',
          ));
        }
        if (func.returnType.name == 'void') {
          issues.add(ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_OWNED',
            message: '${spec.dartClassName}.${func.dartName}() — @NitroOwned on a void return type has nothing to release.',
            hint: 'Remove @NitroOwned or change the return type to NativeHandle<T>.',
          ));
        }
      }
      for (final p in func.params) {
        if (p.type.isNativeHandle && func.isOwned) {
          issues.add(ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_OWNED',
            message: '${spec.dartClassName}.${func.dartName}() — @NitroOwned applies only to return values, not parameter "${p.name}".',
            hint: 'Remove @NitroOwned from the method. Ownership annotation is not applicable to parameters.',
          ));
        }
      }

      // Return type
      final retName = func.returnType.name.replaceFirst('?', '');
      if (func.returnType.isFunction) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNSUPPORTED_FUNCTION_TYPE',
            message: '${spec.dartClassName}.${func.dartName}() — return type "${func.returnType.name}" is a function type, which is not a supported native ABI type.',
            hint:
                'Use a Stream<T> for native-to-Dart events, @NitroNativeAsync/Future<T> for one-shot async results, '
                'or expose explicit native register and release methods around a stable callback/token handle.',
          ),
        );
      } else if (retName != 'void' &&
          !func.returnType.isRecord && // @HybridRecord types bridge as String
          !func.returnType.isPointer && // raw FFI pointers
          !func.returnType.isNativeHandle && // NativeHandle<T> is always void*
          !_isKnownType(retName, knownTypes) &&
          !_isKnownType(func.returnType.name, knownTypes)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E010',
            message: '${spec.dartClassName}.${func.dartName}() — unknown return type "$retName".',
            hint:
                'If "$retName" is a struct, annotate it with @HybridStruct. '
                'If it is an enum, annotate it with @HybridEnum. '
                'If it is a sealed union, annotate it with @NitroVariant. '
                'If it is a complex/nested type (lists, nested objects), annotate it with @HybridRecord.',
          ),
        );
      }

      if (func.zeroCopyReturn && !func.returnType.isTypedData) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_ZERO_COPY_RETURN',
            message: '${spec.dartClassName}.${func.dartName}() — @zeroCopy returns are only valid for TypedData types.',
            hint: 'Use @zeroCopy only on methods returning Uint8List, Float32List, or another Dart TypedData type.',
          ),
        );
      }

      if (func.zeroCopyReturn && func.isNativeAsync) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_ZERO_COPY_RETURN',
            message: '${spec.dartClassName}.${func.dartName}() — @zeroCopy return is not supported with @NitroNativeAsync.',
            hint: 'Workaround: make a synchronous @zeroCopy method that does the work, '
                'then wrap it in a @nitroAsync method that calls it on a background isolate. '
                'Or switch to @nitroAsync and return a regular Uint8List (one copy, safe).',
          ),
        );
      }

      // Prohibit naked TypedData return unless the method explicitly opts into
      // the native-owned zero-copy return contract.
      if (func.returnType.isTypedData && !func.zeroCopyReturn) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'INVALID_RETURN_TYPE',
            message: '${spec.dartClassName}.${func.dartName}() — naked TypedData return type "${func.returnType.name}" is not supported.',
            hint: 'Either annotate the method with @zeroCopy or wrap TypedData in a @HybridStruct with a sibling length field.',
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

      // E008: Map<String, @HybridStruct> — not supported; struct has no binary map encoding.
      // @HybridEnum is now supported (Gap 2): encoded as tag 1 + int64 rawValue.
      if (func.returnType.isMap) {
        final mapMatch = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(func.returnType.name);
        final valueType = mapMatch?.group(1)?.trim() ?? '';
        final isStructVal = spec.isStructName(valueType);
        if (isStructVal) {
          issues.add(ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E008',
            message: '${spec.dartClassName}.${func.dartName}() — Map<String, @HybridStruct> value type "$valueType" is not supported. '
                'The binary encoder cannot encode struct values in maps.',
            hint: 'Return List<$valueType> instead (struct values as a list), or annotate a wrapper @HybridRecord.',
          ));
        }
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
            hint: 'Change the return type to Future<${func.returnType.name}>, or remove @nitroAsync.',
          ),
        );
      }

      // Parameter types
      for (final param in func.params) {
        if (param.type.isFunction) {
          issues.addAll(_validateCallbackParam(spec, func, param));
          continue;
        }

        // E001: Map<K, V> where K is not String, int, or a known @HybridEnum.
        if (param.type.name.startsWith('Map<') && !param.type.isMap) {
          final keyType = BridgeType.extractMapKeyType(param.type.name);
          const intKeyTypes2 = {'int', 'int8', 'int16', 'int32', 'int64', 'uint8', 'uint16', 'uint32', 'uint64'};
          final isAllowedParamKey = keyType != null &&
              (intKeyTypes2.contains(keyType) || enumNames.contains(keyType));
          if (!isAllowedParamKey) {
            issues.add(
              ValidationIssue(
                severity: ValidationSeverity.error,
                code: 'E001',
                message:
                    '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" type "${param.type.name}" uses a non-String Map key. '
                    'Only Map<String, V>, Map<int, V>, and Map<@HybridEnum, V> are supported.',
                hint: 'Change the key type to String, int, or a @HybridEnum.',
              ),
            );
          }
        }

        // E003: Nested Map parameter.
        if (param.type.isMap && param.type.name.contains('Map<String, Map<')) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E003',
              message:
                  '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" uses nested Map type "${param.type.name}", which is not supported.',
              hint: 'Flatten the structure, or annotate a wrapper class with @HybridRecord and pass that instead.',
            ),
          );
        }

        // E008: Map<String, @HybridStruct> parameter — not supported.
        // @HybridEnum is now supported (Gap 2): decoded from tag 1 + int64 rawValue.
        if (param.type.isMap) {
          final mapMatch = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(param.type.name);
          final valueType = mapMatch?.group(1)?.trim() ?? '';
          final isStructVal = spec.isStructName(valueType);
          if (isStructVal) {
            issues.add(ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E008',
              message: '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" Map<String, @HybridStruct> value type "$valueType" is not supported.',
              hint: 'Use List<$valueType> or a @HybridRecord wrapper instead.',
            ));
          }
        }

        final pName = param.type.name.replaceFirst('?', '');
        if (!param.type.isRecord && // @HybridRecord params bridge as String
            !param.type.isPointer && // raw FFI pointers
            !param.type.isNativeHandle && // NativeHandle<T> → void*
            !_isKnownType(pName, knownTypes) &&
            !_isKnownType(param.type.name, knownTypes)) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E010',
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
        if (param.isNamed && param.isOptional && !paramIsNullable && param.defaultLiteral == null) {
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
            message:
                '${spec.dartClassName}.${prop.dartName} — property type "void" is not valid.',
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
            hint:
                'Use a Stream<T> for event-like values, or expose explicit native register and release methods around a stable callback/token handle.',
          ),
        );
        continue;
      }
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
            hint: 'Wrap TypedData in a @HybridStruct with a sibling length field and mark it as @ZeroCopy.',
          ),
        );
      }
    }

    // ── Streams ────────────────────────────────────────────────────────────
    for (final stream in spec.streams) {
      // E009 removed: nullable stream item types are now fully supported.
      // Native posts Dart_CObject_kNull when the item is null; Dart's unpack
      // lambda checks `message == null` before decoding the value.
      // Supported nullable types: int?, double?, bool?, String?, @HybridEnum?,
      // @HybridStruct?, @HybridRecord?  (TypedData? remains unsupported — E012).

      final iName = stream.itemType.name.replaceFirst('?', '');
      if (!_isKnownType(iName, knownTypes) && !_isKnownType(stream.itemType.name, knownTypes)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E011',
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

      // W004: Stream<T> declared without @NitroStream annotation — backpressure
      // defaults silently to dropLatest which may not be the intended behaviour.
      if (!stream.isAnnotated) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'W004',
            message:
                '${spec.dartClassName}.${stream.dartName} — Stream<T> declared without @NitroStream annotation. '
                'Backpressure defaults to dropLatest silently.',
            hint:
                'Add @NitroStream(backpressure: Backpressure.dropLatest) (or your preferred mode) '
                'to explicitly configure stream backpressure.',
          ),
        );
      }

      // E005: Backpressure.batch supports int, double, bool, String, @HybridEnum,
      // @HybridRecord, and @NitroVariant. @HybridStruct cannot be batched (no encode()).
      if (stream.isBatch) {
        final enumNames = spec.enums.map((e) => e.name).toSet();
        final recordNames = spec.recordTypes.map((r) => r.name).toSet();
        final variantNames = spec.variants.map((v) => v.name).toSet();
        final isBatchSupported = const {'int', 'double', 'bool', 'String', 'uint64'}.contains(iName) ||
            enumNames.contains(iName) ||
            recordNames.contains(iName) ||
            variantNames.contains(iName);
        if (!isBatchSupported) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E005',
              message:
                  '${spec.dartClassName}.${stream.dartName} — Backpressure.batch is not supported for stream item type "$iName". '
                  'Batch mode supports: int, double, bool, String, @HybridEnum, @HybridRecord, and @NitroVariant.',
              hint:
                  'Change the stream item type to int, double, bool, String, @HybridEnum, @HybridRecord, or @NitroVariant, '
                  'or switch to Backpressure.dropLatest / Backpressure.dropOldest.',
            ),
          );
        }

        // E006: batchMaxSize must be a positive integer.
        if (stream.batchMaxSize <= 0) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E006',
              message:
                  '${spec.dartClassName}.${stream.dartName} — batchMaxSize must be > 0, got ${stream.batchMaxSize}.',
              hint: 'Set batchMaxSize to a positive integer (e.g. 64).',
            ),
          );
        }

        // W005: Warn when @HybridRecord appears as a Map value type — Kotlin generates
        // Any? for the map value, so runtime type checks are not enforced on Android.
        // The map works but is not type-safe in the JVM layer.
      }

      // W005: Map<String, @HybridRecord> on Android generates Any? for values.
      // The binary map encoder/decoder is typed only on the Dart side; Kotlin passes Any?.
      if (iName == 'Map' && stream.itemType.isMap) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'W005',
            message:
                '${spec.dartClassName}.${stream.dartName} — Map<String, @HybridRecord> stream item type is not type-safe on Android. '
                'Kotlin generates Any? for the map value.',
            hint: 'This works at runtime but bypasses Kotlin type-checking. Consider using @HybridRecord directly.',
          ),
        );
      }
    }

    // ── E013: @HybridRecord field type references ─────────────────────────
    for (final rt in spec.recordTypes) {
      for (final field in rt.fields) {
        // RecordFieldKind is set by the spec extractor — if kind is known
        // (primitive, enumValue, recordObject, etc.) the type is already resolved.
        // Only report E013 for primitive-kind fields whose dartType base name
        // is not in the known types set, which signals an unresolved reference.
        if (field.kind != RecordFieldKind.primitive) continue;
        final fName = field.dartType.replaceFirst('?', '').split('<').first.trim();
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

    // ── E014: @NitroVariant case count ────────────────────────────────────
    for (final variant in spec.variants) {
      if (variant.cases.isEmpty) {
        issues.add(ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'E014',
          message: '${variant.name} — @NitroVariant has no cases.',
          hint: 'Add at least one concrete subclass of ${variant.name}.',
        ));
      } else if (variant.cases.length > 255) {
        issues.add(ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'E014',
          message: '${variant.name} — @NitroVariant has ${variant.cases.length} cases (max 255).',
          hint: 'Split "${variant.name}" into multiple variant types, each with ≤ 255 cases.',
        ));
      }
    }

    // ── E015: @NitroResult validation ─────────────────────────────────────
    for (final func in spec.functions) {
      if (!func.isResult) continue;
      // @nitroAsync is allowed: bridge dispatches on a background thread and
      // Dart receives Future<NitroResultValue<T>>. @NitroNativeAsync is blocked
      // because Dart_PostCObject_DL only supports primitive CObject types and
      // cannot encode a NitroResultValue buffer.
      if (func.isNativeAsync) {
        issues.add(ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'E015',
          message: '${func.dartName}() — @NitroResult cannot be combined with @NitroNativeAsync.',
          hint: 'Remove @NitroNativeAsync from ${func.dartName}. '
              'For an async @NitroResult method use @nitroAsync instead.',
        ));
      }
      if (func.returnType.name == 'void') {
        issues.add(ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'E015',
          message: '${func.dartName}() — @NitroResult cannot wrap void return type.',
          hint: 'Use a non-void return type or remove @NitroResult if you only need error propagation.',
        ));
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
      adj[st.name] = st.fields.map((f) => f.type.name.replaceFirst('?', '')).where(spec.isStructName).toList();
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

  static List<ValidationIssue> _validateCallbackParam(
    BridgeSpec spec,
    BridgeFunction func,
    BridgeParam param,
  ) {
    final issues = <ValidationIssue>[];
    final callback = param.type;
    final returnName = (callback.functionReturnType ?? 'void').replaceFirst('?', '');
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
          message: '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" is a callback type, '
              'which is not supported on @NitroAsync methods.',
          hint: 'Callback replacement relies on the native registration call being synchronous on the calling '
              'isolate. Remove @NitroAsync from ${func.dartName}() (registering a callback pointer is normally '
              'cheap), or use @NitroNativeAsync if native must register it off the calling thread.',
        ),
      );
    }

    final recordNames = spec.recordTypes.map((r) => r.name).toSet();
    final variantNames = spec.variants.map((v) => v.name).toSet();
    // Supported callback return types: primitives, AnyNativeObject, enums, @HybridRecord, @NitroVariant.
    final supportedReturn = returnName == 'void' || returnName == 'int' || returnName == 'double'
        || returnName == 'bool' || returnName == 'String' || returnName == 'AnyNativeObject' || returnName == 'uint64'
        || enumNames.contains(returnName) || recordNames.contains(returnName) || variantNames.contains(returnName);
    if (!supportedReturn) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.error,
          code: 'UNSUPPORTED_FUNCTION_TYPE',
          message:
              '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" callback return type "$returnName" is not supported.',
          hint: 'Callback returns support void, int, double, bool, String, @HybridEnum, @HybridRecord, and @NitroVariant.',
        ),
      );
    }

    for (final callbackParam in callback.functionParams) {
      final name = callbackParam.name.replaceFirst('?', '');
      final structNames = spec.structs.map((s) => s.name).toSet();
      final recordNames = spec.recordTypes.map((r) => r.name).toSet();
      final variantNames = spec.variants.map((v) => v.name).toSet();
      final supportedParam = callbackParam.isPointer || callbackParam.isAnyNativeObject ||
          name == 'int' || name == 'double' || name == 'bool' || name == 'String' || name == 'AnyNativeObject' || name == 'uint64' ||
          enumNames.contains(name) ||
          structNames.contains(name) ||
          recordNames.contains(name) ||
          variantNames.contains(name);
      if (!supportedParam) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'UNSUPPORTED_FUNCTION_TYPE',
            message:
                '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" callback parameter type "${callbackParam.name}" is not supported.',
            hint: 'Callback parameters support int, double, bool, String, Pointer<T>, @HybridEnum, @HybridStruct, @HybridRecord, and @NitroVariant.',
          ),
        );
      }
    }

    return issues;
  }
}
