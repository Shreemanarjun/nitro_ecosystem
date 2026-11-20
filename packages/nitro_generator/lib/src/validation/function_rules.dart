part of '../spec_validator.dart';

// Rules for methods: return types, parameter types, annotations that do not
// combine, duplicate symbols.

extension _FunctionRules on _Rules {
  void functions() {
    // ── Functions ──────────────────────────────────────────────────────────
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
        final rawValueType = func.returnType.name.contains(',') ? func.returnType.name.split(',').last.trim().replaceFirst('>', '') : 'V';
        // Allow integer key types and enum key types (Gap #3).
        const intKeyTypes = {'int', 'int8', 'int16', 'int32', 'int64', 'uint8', 'uint16', 'uint32', 'uint64'};
        final isAllowedKey = keyType != null && (intKeyTypes.contains(keyType) || enumNames.contains(keyType));
        if (!isAllowedKey) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'E001',
              message:
                  '${spec.dartClassName}.${func.dartName}() — return type "${func.returnType.name}" uses a non-String Map key. '
                  'Only Map<String, V>, Map<int, V>, and Map<@HybridEnum, V> are supported.',
              hint:
                  'Change the key type to String, int, or a @HybridEnum. '
                  'If you need a string key, use Map<String, $rawValueType>.',
            ),
          );
        }
      }

      final retNullableMap = _nullableMapValueIssue(func.returnType, '${spec.dartClassName}.${func.dartName}() return type');
      if (retNullableMap != null) issues.add(retNullableMap);

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
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'INVALID_OWNED',
              message: '${spec.dartClassName}.${func.dartName}() — @NitroOwned requires a NativeHandle<T> return type, got "${func.returnType.name}".',
              hint: 'Change the return type to NativeHandle<T>, or remove @NitroOwned.',
            ),
          );
        }
        if (func.returnType.name == 'void') {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'INVALID_OWNED',
              message: '${spec.dartClassName}.${func.dartName}() — @NitroOwned on a void return type has nothing to release.',
              hint: 'Remove @NitroOwned or change the return type to NativeHandle<T>.',
            ),
          );
        }
        // The release symbol is emitted verbatim into the generated C bridge —
        // reject anything that is not a plain C identifier.
        final release = func.releaseSymbol;
        if (release != null && !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(release)) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'INVALID_OWNED',
              message: '${spec.dartClassName}.${func.dartName}() — @NitroOwned(release: \'$release\') is not a valid C function name.',
              hint: "Pass the bare extern \"C\" symbol, e.g. @NitroOwned(release: 'wgpuBufferRelease').",
            ),
          );
        }
      }
      // @mainThread validation (issue #19): the dispatch hop is generated for
      // Kotlin and Swift impls only — a C++ impl (desktop, or apple/android
      // NativeImpl.cpp) receives the call on whatever thread invoked it.
      if (func.mainThread) {
        final cppPlatforms = <String>[
          if (spec.iosImpl == NativeImpl.cpp) 'ios',
          if (spec.macosImpl == NativeImpl.cpp) 'macos',
          if (spec.androidImpl == NativeImpl.cpp) 'android',
          if (spec.windowsImpl != null) 'windows',
          if (spec.linuxImpl != null) 'linux',
        ];
        if (cppPlatforms.isNotEmpty) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.warning,
              code: 'MAIN_THREAD_NO_EFFECT',
              message: '${spec.dartClassName}.${func.dartName}() — @mainThread has no effect on C++ implementations (${cppPlatforms.join(', ')}); the impl runs on the calling thread there.',
              hint: 'Marshal onto the UI/main loop inside the C++ implementation on those platforms, or ignore this if only the Kotlin/Swift paths need the main thread.',
            ),
          );
        }
      }

      // @nitroFast is a synchronous hot-path contract: leaf binding, bare body,
      // no error-slot check. On a Future / @nitroAsync / @nitroNativeAsync
      // method none of that applies (the call is dispatched or posts back).
      if (func.isFast && !func.inlineFuture && (func.isAsync || func.isNativeAsync || func.returnType.isFuture)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'FAST_NOT_SYNC',
            message: '${spec.dartClassName}.${func.dartName}() — @nitroFast (or the Fast suffix) only applies to synchronous methods, or to @nitroNativeAsync methods (inline completion).',
            hint: 'Remove @nitroFast, or make the method synchronous. Async and native-async methods are never leaf calls.',
          ),
        );
      }

      for (final p in func.params) {
        if (p.type.isNativeHandle && func.isOwned) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              code: 'INVALID_OWNED',
              message: '${spec.dartClassName}.${func.dartName}() — @NitroOwned applies only to return values, not parameter "${p.name}".',
              hint: 'Remove @NitroOwned from the method. Ownership annotation is not applicable to parameters.',
            ),
          );
        }
      }

      // Return type
      final retName = bareTypeName(func.returnType.name);
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
          !func.returnType.isAnyMap && // NitroAnyMap — isAnyMap is a separate flag from isRecord
          !func.returnType.isPointer && // raw FFI pointers
          !func.returnType.isNativeHandle && // NativeHandle<T> is always void*
          !_isKnownType(retName, knownTypes) &&
          !_isKnownType(func.returnType.name, knownTypes)) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'E010',
            message: '${spec.dartClassName}.${func.dartName}${func.isGetter ? '' : '()'} — unknown return type "$retName".',
            hint: retName.startsWith('Future<') || retName.startsWith('FutureOr<')
                ? 'Annotate it @nitroAsync (native runs off the Dart thread) or @nitroNativeAsync (native completes the future itself).'
                : 'If "$retName" is a struct, annotate it with @HybridStruct. '
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
            hint:
                'Drop @zeroCopy: a plain typed-data return is copied by the bridge and works with @NitroNativeAsync. '
                'Or make the method synchronous and keep @zeroCopy (the list stays native-owned).',
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

      // Warn: @HybridRecord returned synchronously — decoding blocks the caller.
      // @NitroNativeAsync is NOT synchronous: it returns a Future and posts the
      // result from the native side, so it must not be flagged here.
      if (!func.isAsync && !func.isNativeAsync && func.returnType.isRecord) {
        issues.add(
          ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'SYNC_RECORD_RETURN',
            message: '${spec.dartClassName}.${func.dartName}() returns a @HybridRecord type synchronously.',
            hint: 'Add @nitroAsync (background isolate) or @NitroNativeAsync (native posts the result); decoding blocks the calling thread.',
          ),
        );
      }

      // E008: Map<String, @HybridStruct> — not supported; struct has no binary map encoding.
      // @HybridEnum is now supported (Gap 2): encoded as tag 1 + int64 rawValue.
      if (func.returnType.isMap) {
        final e008 = _structMapValueIssue(spec, func.returnType, '${spec.dartClassName}.${func.dartName}()');
        if (e008 != null) issues.add(e008);
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
          final isAllowedParamKey = keyType != null && (intKeyTypes2.contains(keyType) || enumNames.contains(keyType));
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
              message: '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}" uses nested Map type "${param.type.name}", which is not supported.',
              hint: 'Flatten the structure, or annotate a wrapper class with @HybridRecord and pass that instead.',
            ),
          );
        }

        // E008: Map<String, @HybridStruct> parameter — not supported.
        // @HybridEnum is now supported (Gap 2): decoded from tag 1 + int64 rawValue.
        if (param.type.isMap) {
          final paramNullableMap = _nullableMapValueIssue(param.type, '${spec.dartClassName}.${func.dartName}() parameter "${param.name}"');
          if (paramNullableMap != null) issues.add(paramNullableMap);
          final e008 = _structMapValueIssue(spec, param.type, '${spec.dartClassName}.${func.dartName}() — parameter "${param.name}"');
          if (e008 != null) issues.add(e008);
        }

        final pName = bareTypeName(param.type.name);
        if (!param.type.isRecord && // @HybridRecord params bridge as String
            !param.type.isAnyMap && // NitroAnyMap — isAnyMap is a separate flag from isRecord
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
          final bareParamType = bareTypeName(param.type.name);
          if (enumNames.contains(bareParamType)) {
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
          } else if (structNames.contains(bareParamType)) {
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
  }
}
