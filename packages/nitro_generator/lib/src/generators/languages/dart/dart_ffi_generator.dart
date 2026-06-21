import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../enum_generator.dart';
import '../../generator_metadata.dart';
import '../../struct_generator.dart';
import '../../record_generator.dart';
import 'dart_ffi_return_helpers.dart';

class DartFfiGenerator {
  static String generate(BridgeSpec spec) {
    _assertSupportedFunctionTypes(spec);

    final writer = CodeWriter();
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    writer.line("part of '${spec.sourceUri.split('/').last}';");
    writer.blankLine();

    // Enum & struct extensions (class bodies live in .native.dart)
    final enumExt = EnumGenerator.generateDartExtensions(spec);
    if (enumExt.isNotEmpty) writer.raw(enumExt);
    final structExt = StructGenerator.generateDartExtensions(spec);
    if (structExt.isNotEmpty) writer.raw(structExt);

    // Zero-copy native proxies for @HybridStruct (used by streams)
    final proxyExt = StructGenerator.generateDartProxies(spec);
    if (proxyExt.isNotEmpty) writer.raw(proxyExt);

    // @HybridRecord fromJson / toJson extensions
    final recordExt = RecordGenerator.generateDartExtensions(spec);
    if (recordExt.isNotEmpty) writer.raw(recordExt);

    // Type-only files have no bridge implementation — only type declarations.
    if (spec.isTypeOnly) return writer.toString();

    // ── Impl class ──────────────────────────────────────────────────────────
    final libStem = spec.lib.replaceAll('-', '_');
    final checksum = bridgeSpecChecksum(spec);
    writer.line(
      'class _${spec.dartClassName}Impl extends ${spec.dartClassName} {',
    );
    writer.line('  final DynamicLibrary _dylib;');
    // S8: pre-allocated error slot — shared across all sync calls on this instance.
    // One allocation per module, zero allocation per call.
    writer.line('  final Pointer<NitroErrorFfi> _nitroErr = calloc<NitroErrorFfi>();');
    final hasCallbacks = _hasFunctionTypeParams(spec);
    if (hasCallbacks) {
      writer.line('  final Map<Object, NativeCallable<dynamic>> _nativeCallbackCache = {};');
    }
    final hasZeroCopyTypedDataReturn = spec.functions.any((f) => f.zeroCopyReturn && f.returnType.isTypedData);
    if (hasZeroCopyTypedDataReturn) {
      writer.line(
        // NativeFinalizerFunction is typedef NativeFunction<Void Function(Pointer<Void>)>,
        // so lookup<NativeFinalizerFunction> is correct — NOT NativeFunction<NativeFinalizerFunction>.
        "  late final Pointer<NativeFinalizerFunction> _typedDataReturnFinalizer = _dylib.lookup<NativeFinalizerFunction>('${libStem}_release_typed_data_return').cast();",
      );
    }
    writer.blankLine();
    writer.line('  static DynamicLibrary _loadSupportedLibrary() {');
    // PX19: Guard against dart:ffi usage on web at runtime.
    // dart:ffi types (DynamicLibrary, Pointer, calloc, etc.) are not available
    // on web — nitro.dart exports ffi_stub.dart instead. This assertion helps
    // catch misconfiguration where the FFI impl is instantiated on web instead
    // of the web bridge from *.web.bridge.g.dart.
    if (spec.targetsWeb) {
      writer.line('    assert(');
      writer.line("      !const bool.fromEnvironment('dart.library.js_interop'),");
      writer.line("      '${spec.lib}: dart:ffi is unavailable on web. "
          "Instantiate the web bridge via create${spec.dartClassName}WebInstance() "
          "from the generated *.web.bridge.g.dart file instead.',");
      writer.line('    );');
    }
    writer.line("    return NitroRuntime.loadLibForTargets('${spec.lib}',");
    writer.line('      ios: ${spec.targetsIos},');
    writer.line('      android: ${spec.targetsAndroid},');
    writer.line('      macos: ${spec.targetsMacos},');
    writer.line('      windows: ${spec.targetsWindows},');
    writer.line('      linux: ${spec.targetsLinux},');
    writer.line('      web: ${spec.targetsWeb},');
    writer.line('    );');
    writer.line('  }');
    writer.blankLine();
    writer.line(
      '  _${spec.dartClassName}Impl() : _dylib = _loadSupportedLibrary() {',
    );
    writer.line("    final initSw = Stopwatch()..start();");
    writer.line(
      "    final initFunc = _dylib.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('${libStem}_init_dart_api_dl');",
    );
    writer.line('    final initCode = initFunc(NativeApi.initializeApiDLData);');
    writer.line('    if (initCode != 0) {');
    writer.line("      throw StateError('${spec.lib}: Dart API DL initialization failed with code \$initCode.');");
    writer.line('    }');
    writer.line(
      "    NitroRuntime.checkAbiVersion('${spec.lib}', () => _dylib.lookupFunction<Uint32 Function(), int Function()>('${libStem}_nitro_abi_version')());",
    );
    writer.line(
      "    NitroRuntime.checkLinkChecksum('${spec.lib}', '$checksum', () => _dylib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('${libStem}_nitro_bridge_checksum')().toDartString());",
    );
    // Initialise NativeFinalizer for every struct proxy.
    // Each proxy looks up its generated release C-symbol from _dylib.
    for (final st in spec.structs) {
      writer.line('    ${st.name}Proxy._init(_dylib);');
    }
    writer.line('    initSw.stop();');
    writer.line("    NitroRuntime.logLifecycle('init(${spec.lib})', 'initialized in \${initSw.elapsedMicroseconds} µs');");
    writer.line('  }');
    writer.blankLine();

    // ── Method pointers ─────────────────────────────────────────────────────
    for (final func in spec.functions) {
      final nativeType = _toNativeType(func, spec);
      final dartType = _toDartType(func, spec);
      // isLeaf: true skips the Dart VM safepoint transition on every call —
      // valid for any sync bridge function whose C++ body never calls back into
      // Dart.  Candidates: explicitly "Fast"-suffixed methods AND any sync
      // method whose params/return are plain FFI scalars (no arena allocation).
      final isLeaf = _isLeafCandidate(func, spec);
      if (isLeaf) {
        writer.line(
          "  late final $dartType _${func.dartName}Ptr = _dylib.lookup<NativeFunction<$nativeType>>('${func.cSymbol}').asFunction<$dartType>(isLeaf: true);",
        );
      } else {
        writer.line(
          "  late final $dartType _${func.dartName}Ptr = _dylib.lookupFunction<$nativeType, $dartType>('${func.cSymbol}');",
        );
      }
      // @NitroOwned: emit a release function pointer and a NativeFinalizer.
      if (func.isOwned && func.returnType.isNativeHandle) {
        writer.line(
          "  late final void Function(Pointer<Void>) _${func.dartName}ReleaseFn = _dylib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('${func.cSymbol}_release');",
        );
        writer.line(
          "  late final NativeFinalizer _${func.dartName}Finalizer = NativeFinalizer(_dylib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('${func.cSymbol}_release').cast());",
        );
      }
    }

    // ── Property pointers ───────────────────────────────────────────────────
    for (final prop in spec.properties) {
      final ffiType = _typeToFFI(prop.type, spec);
      final dartType = _typeToDartFFI(prop.type, spec);
      final cap = _cap(prop.dartName);
      // Property accessors are always synchronous and their C++ bodies never
      // call back into Dart, so primitive-typed accessors qualify for isLeaf.
      final isLeafProp = _isPrimitiveType(prop.type, spec);
      // S8: property accessors also receive the NitroError* out-param.
      if (prop.hasGetter) {
        if (isLeafProp) {
          writer.line(
            "  late final $dartType Function(Pointer<NitroErrorFfi>) _get${cap}Ptr = _dylib.lookup<NativeFunction<$ffiType Function(Pointer<NitroErrorFfi>)>>('${prop.getSymbol}').asFunction<$dartType Function(Pointer<NitroErrorFfi>)>(isLeaf: true);",
          );
        } else {
          writer.line(
            "  late final $dartType Function(Pointer<NitroErrorFfi>) _get${cap}Ptr = _dylib.lookupFunction<$ffiType Function(Pointer<NitroErrorFfi>), $dartType Function(Pointer<NitroErrorFfi>)>('${prop.getSymbol}');",
          );
        }
      }
      if (prop.hasSetter) {
        if (isLeafProp) {
          writer.line(
            "  late final void Function($dartType, Pointer<NitroErrorFfi>) _set${cap}Ptr = _dylib.lookup<NativeFunction<Void Function($ffiType, Pointer<NitroErrorFfi>)>>('${prop.setSymbol}').asFunction<void Function($dartType, Pointer<NitroErrorFfi>)>(isLeaf: true);",
          );
        } else {
          writer.line(
            "  late final void Function($dartType, Pointer<NitroErrorFfi>) _set${cap}Ptr = _dylib.lookupFunction<Void Function($ffiType, Pointer<NitroErrorFfi>), void Function($dartType, Pointer<NitroErrorFfi>)>('${prop.setSymbol}');",
          );
        }
      }
    }

    // ── Stream register/release pointers ────────────────────────────────────
    for (final stream in spec.streams) {
      final cap = _cap(stream.dartName);
      writer.line(
        "  late final void Function(int) _register${cap}Ptr = _dylib.lookupFunction<Void Function(Int64), void Function(int)>('${stream.registerSymbol}');",
      );
      writer.line(
        "  late final void Function(int) _release${cap}Ptr = _dylib.lookupFunction<Void Function(Int64), void Function(int)>('${stream.releaseSymbol}');",
      );
    }

    // ── Error handling pointers (Cached to avoid dlsym on every check) ──────
    writer.line('  // ignore: unused_field');
    writer.line(
      "  late final Pointer<NitroErrorFfi> Function() _getErrorPtr = _dylib.lookupFunction<Pointer<NitroErrorFfi> Function(), Pointer<NitroErrorFfi> Function()>('${libStem}_get_error');",
    );
    writer.line('  // ignore: unused_field');
    writer.line(
      "  late final void Function() _clearErrorPtr = _dylib.lookupFunction<Void Function(), void Function()>('${libStem}_clear_error');",
    );
    // Only emit the native-pointer variants when there are regular callAsync
    // functions that need them. isNativeAsync functions use openNativeAsync
    // which doesn't require these pointers.
    final hasCallAsync = spec.functions.any((f) => f.isAsync && !f.isNativeAsync);
    if (hasCallAsync) {
      writer.line('  // ignore: unused_field');
      writer.line(
        "  late final Pointer<NativeFunction<Pointer<NitroErrorFfi> Function()>> _getErrorNativePtr = _dylib.lookup('${libStem}_get_error');",
      );
      writer.line('  // ignore: unused_field');
      writer.line(
        "  late final Pointer<NativeFunction<Void Function()>> _clearErrorNativePtr = _dylib.lookup('${libStem}_clear_error');",
      );
    }
    writer.blankLine();

    // ── dispose() override ───────────────────────────────────────────────────
    writer.line('  @override');
    writer.line('  void dispose() {');
    writer.line("    NitroRuntime.logLifecycle('dispose(${spec.lib})', 'disposing');");
    if (hasCallbacks) {
      writer.line('    for (final callback in _nativeCallbackCache.values) {');
      writer.line('      callback.close();');
      writer.line('    }');
      writer.line('    _nativeCallbackCache.clear();');
    }
    writer.line('    calloc.free(_nitroErr); // S8: free pre-allocated error slot');
    writer.line(
      '    super.dispose(); // sets isDisposed = true, calls onDestroy()',
    );
    writer.line("    NitroRuntime.logLifecycle('dispose(${spec.lib})', 'disposed');");
    writer.line('  }');
    writer.blankLine();

    if (hasCallbacks) {
      _emitCallbackHelpers(writer, spec);
    }

    // ── Method implementations ───────────────────────────────────────────────
    for (final func in spec.functions) {
      final needsArena = func.params.any(
        (p) {
          final baseName = p.type.name.replaceFirst('?', '');
          return p.type.isTypedData || p.type.name == 'String' || p.type.name == 'String?' || p.type.isRecord || spec.structs.any((st) => st.name == baseName);
        },
      );

      final callArgs = func.params
          .expand((p) {
            final t = p.type.name;
            if (p.type.isRecord) {
              return [_encodeRecordParam(p.type, p.name, 'arena')];
            }
            if (p.type.isFunction) {
              return [_callbackArgExpr(func, p)];
            }
            if (p.type.isPointer) {
              return [p.name];
            }
            if (p.type.isTypedData) {
              return ['${p.name}.toPointer(arena)', '${p.name}.length'];
            }
            if (t == 'String') {
              return ['${p.name}.toNativeUtf8(allocator: arena)'];
            }
            if (t == 'String?') {
              return ['${p.name} != null ? ${p.name}.toNativeUtf8(allocator: arena) : nullptr'];
            }
            if (spec.structs.any((st) => st.name == t)) {
              return ['${p.name}.toNative(arena).cast<Void>()'];
            }
            final tBase = t.replaceFirst('?', '');
            if (t.endsWith('?') && spec.structs.any((st) => st.name == tBase)) {
              return ['${p.name} != null ? ${p.name}.toNative(arena).cast<Void>() : nullptr'];
            }
            // Enum (including nullable enum: TcStatus? uses -1 as null sentinel)
            if (spec.enums.any((en) => en.name == tBase)) {
              if (t.endsWith('?')) {
                return ['${p.name} == null ? -1 : ${p.name}.nativeValue'];
              }
              return ['${p.name}.nativeValue'];
            }
            if (t == 'bool') return ['${p.name} ? 1 : 0'];
            // Optional primitives: C function expects a concrete primitive type
            // (int64_t / double / int8_t). Pass a sentinel value when the Dart
            // caller provides null so the args list always holds a non-null value.
            // The Kotlin _call bridge receives the sentinel and converts it back
            // to null before forwarding to the implementation interface.
            // Sentinels: int?→-1, double?→double.nan, bool?→-1, enum?→-1
            if (t == 'int?') return ['${p.name} ?? -1'];
            if (t == 'double?') return ['${p.name} ?? double.nan'];
            if (t == 'bool?') return ['${p.name} == null ? -1 : (${p.name} ? 1 : 0)'];
            return [p.name];
          })
          .join(', ');

      // For NativeAsync, the return type annotation is Future<T> but asyncMod is
      // left empty (no `async` keyword) — the method returns an already-Future.
      // NativeHandle<T>: the declared Dart return type is NativeHandle<T>
      // but the FFI function pointer returns Pointer<Void>.
      final nativeHandleTypeParam = func.returnType.nativeHandleTypeParam ?? 'Void';
      final effectiveDartReturnName = func.returnType.isNativeHandle
          ? 'NativeHandle<$nativeHandleTypeParam>'
          : func.returnType.name;
      final returnType = (func.isAsync || func.isNativeAsync)
          ? 'Future<$effectiveDartReturnName>'
          : effectiveDartReturnName;
      final asyncMod = func.isAsync ? 'async ' : '';

      writer.line('  @override');
      writer.line(
        '  $returnType ${func.dartName}(${_paramList(func.params)}) $asyncMod{',
      );
      final isFast = func.dartName.endsWith('Fast');
      writer.line('    checkDisposed();');

      final rt = func.returnType.name;
      // Classify once — avoids repeated spec.structs.any() / spec.enums.any() calls.
      final returnKind = classifyReturn(func.returnType, spec);

      if (func.isNativeAsync) {
        _emitNativeAsyncBody(writer, func, spec, callArgs, needsArena);
      } else if (func.isAsync) {
        // plainCallArgs: used when no arena is needed. Apply the same optional-primitive
        // sentinel encoding as callArgs so that int?/bool?/double? are never passed as null.
        // (Structs, TypedData, String all require an arena so they can't appear here.)
        final plainCallArgs = func.params
            .map((p) {
              final t = p.type.name;
              final tBase = p.type.baseName;
              if (t == 'int?') return '${p.name} ?? -1';
              if (t == 'double?') return '${p.name} ?? double.nan';
              if (t == 'bool?') return '${p.name} == null ? -1 : (${p.name} ? 1 : 0)';
              if (t == 'bool') return '${p.name} ? 1 : 0';
              // Nullable enum: TcStatus? → -1 for null, rawValue otherwise
              if (spec.enums.any((en) => en.name == tBase)) {
                return t.endsWith('?')
                    ? '${p.name} == null ? -1 : ${p.name}.nativeValue'
                    : '${p.name}.nativeValue';
              }
              if (p.type.isFunction) return _callbackArgExpr(func, p);
              return p.name;
            })
            .join(', ');

        final callAsyncType = callAsyncTransportType(func.returnType, spec);

        final errArgs = "getError: _getErrorNativePtr, clearError: _clearErrorNativePtr, methodName: '${func.dartName}'";

        if (needsArena) {
          // needsArena path: wrap in try/finally to release arena allocations.
          final asyncResVar = _asyncResVarName(returnKind);
          writer.line('    final arena = Arena();');
          writer.line('    try {');
          if (returnKind == ReturnKind.voidType) {
            // void return: don't assign to a variable — it's unused and warns.
            writer.line('      await NitroRuntime.callAsync<$callAsyncType>(_${func.dartName}Ptr, [$callArgs], $errArgs);');
          } else {
            writer.line('      final $asyncResVar = await NitroRuntime.callAsync<$callAsyncType>(_${func.dartName}Ptr, [$callArgs], $errArgs);');
            _emitReturnDecode(writer, func.returnType, asyncResVar, '      ', spec,
                zeroCopy: func.zeroCopyReturn, dartName: func.dartName,
                isOwned: func.isOwned,
                nativeHandleTypeParam: nativeHandleTypeParam);
          }
          writer.line('    } finally {');
          writer.line('      arena.releaseAll();');
          writer.line('    }');
        } else {
          if (returnKind == ReturnKind.voidType) {
            writer.line('    await NitroRuntime.callAsync<$callAsyncType>(_${func.dartName}Ptr, [$plainCallArgs], $errArgs);');
          } else {
            final asyncResVar = _asyncResVarName(returnKind);
            writer.line('    final $asyncResVar = await NitroRuntime.callAsync<$callAsyncType>(_${func.dartName}Ptr, [$plainCallArgs], $errArgs);');
            _emitReturnDecode(writer, func.returnType, asyncResVar, '    ', spec,
                zeroCopy: func.zeroCopyReturn, dartName: func.dartName,
                isOwned: func.isOwned,
                nativeHandleTypeParam: nativeHandleTypeParam);
          }
        }
      } else {
        // ── Synchronous path — wrapped in callSync for logging + slow-call detection ──
        final mnArg = ", methodName: '${func.dartName}'";
        // S8: append the pre-allocated error slot as the last argument so the C
        // bridge can write error info directly without a separate get_error() call.
        final syncArgs = callArgs.isEmpty ? '_nitroErr' : '$callArgs, _nitroErr';
        if (needsArena) {
          // callSync wraps withArena so timing covers arena allocation + native call.
          writer.line('    return NitroRuntime.callSync(() => withArena((arena) {');
          if (rt == 'void') {
            writer.line('      _${func.dartName}Ptr($syncArgs);');
            if (!isFast) writer.line(_assertCheckError('      '));
            writer.line('      return;');
          } else {
            writer.line('      final res = _${func.dartName}Ptr($syncArgs);');
            if (!isFast) writer.line(_assertCheckError('      '));
            _emitReturnDecode(writer, func.returnType, 'res', '      ', spec,
                zeroCopy: func.zeroCopyReturn, dartName: func.dartName,
                isOwned: func.isOwned,
                nativeHandleTypeParam: nativeHandleTypeParam);
          }
          writer.line('    })$mnArg);');
        } else {
          if (rt == 'void') {
            writer.line('    NitroRuntime.callSync<void>(() {');
            writer.line('      _${func.dartName}Ptr($syncArgs);');
            if (!isFast) writer.line(_assertCheckError('      '));
            writer.line('    }$mnArg);');
          } else {
            writer.line('    return NitroRuntime.callSync(() {');
            writer.line('      final res = _${func.dartName}Ptr($syncArgs);');
            if (!isFast) writer.line(_assertCheckError('      '));
            _emitReturnDecode(writer, func.returnType, 'res', '      ', spec,
                zeroCopy: func.zeroCopyReturn, dartName: func.dartName,
                isOwned: func.isOwned,
                nativeHandleTypeParam: nativeHandleTypeParam);
            writer.line('    }$mnArg);');
          }
        }
      }
      writer.line('  }');
      writer.blankLine();
    }

    // ── Property implementations ─────────────────────────────────────────────
    for (final prop in spec.properties) {
      final cap = _cap(prop.dartName);
      final rt = prop.type.name;
      final isRecordProp = prop.type.isRecord;

      if (prop.hasGetter) {
        writer.line('  @override');
        writer.line('  $rt get ${prop.dartName} {');
        writer.line('    checkDisposed();');
        writer.line("    return NitroRuntime.callSync(() {");
        writer.line('      final res = _get${cap}Ptr(_nitroErr);');
        writer.line(_assertCheckError('      '));
        _emitReturnDecode(writer, prop.type, 'res', '      ', spec);
        writer.line("    }, methodName: 'get ${prop.dartName}');");
        writer.line('  }');
      }

      if (prop.hasSetter) {
        writer.line('  @override');
        if (isRecordProp) {
          // @HybridRecord properties use _encodeRecordParam for full Map/List fidelity.
          final encodeExpr = _encodeRecordParam(prop.type, 'value', 'arena');
          writer.line('  set ${prop.dartName}($rt value) {');
          writer.line('    checkDisposed();');
          writer.line("    NitroRuntime.callSync<void>(() => withArena((arena) { _set${cap}Ptr($encodeExpr, _nitroErr); ${_inlineCheckError()} }), methodName: 'set ${prop.dartName}');");
          writer.line('  }');
        } else {
          // All other types: encodePropertyValue covers String, bool, int?, double?,
          // enum, TypedData, struct — each with correct sentinel and arena handling.
          final encoded = encodePropertyValue(prop.type, spec, 'value', 'arena');
          if (encoded.needsArena) {
            writer.line(
              "  set ${prop.dartName}($rt value) { checkDisposed(); NitroRuntime.callSync<void>(() => withArena((arena) { _set${cap}Ptr(${encoded.expr}, _nitroErr); ${_inlineCheckError()} }), methodName: 'set ${prop.dartName}'); }",
            );
          } else {
            writer.line(
              "  set ${prop.dartName}($rt value) { checkDisposed(); NitroRuntime.callSync<void>(() { _set${cap}Ptr(${encoded.expr}, _nitroErr); ${_inlineCheckError()} }, methodName: 'set ${prop.dartName}'); }",
            );
          }
        }
      }
      writer.blankLine();
    }

    // ── Stream implementations ───────────────────────────────────────────────
    for (final stream in spec.streams) {
      final cap = _cap(stream.dartName);
      final itemType = stream.itemType.name;
      final isRecord = stream.itemType.isRecord;
      final isStruct = spec.structs.any((st) => st.name == itemType);

      final String unpackExpr;
      final String streamItemType;

      if (isRecord) {
        final decodeExpr = _decodeRecordExpr(stream.itemType, 'rawPtr');
        final nullAction = stream.itemType.isNullable ? 'return null' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}')";
        unpackExpr = '(message) { if (message == null) { $nullAction; } final rawPtr = Pointer<Uint8>.fromAddress(message as int); try { return $decodeExpr; } finally { malloc.free(rawPtr); } }';
        streamItemType = itemType;
      } else if (isStruct) {
        // Zero-copy path: ${itemType}Proxy extends ${itemType} and overrides every
        // getter to read lazily from native memory.  Because the proxy IS-A value
        // type, Stream<${itemType}Proxy> satisfies Stream<${itemType}> via Dart's
        // covariant generics — no .map() or eager field copy required.
        final nullAction = stream.itemType.isNullable ? 'return null' : "throw StateError('Received null event on non-nullable stream ${stream.dartName}')";
        unpackExpr = '(message) { if (message == null) { $nullAction; } return ${itemType}Proxy(Pointer<${itemType}Ffi>.fromAddress(message as int)); }';
        streamItemType = itemType;
      } else if (spec.enums.any((e) => e.name == itemType)) {
        // Enum stream: convert int to enum via generated extension
        unpackExpr = '(message) => (message as int).to$itemType()';
        streamItemType = itemType;
      } else {
        unpackExpr = '(message) => message as $itemType';
        streamItemType = itemType;
      }

      writer.line('  @override');
      final streamSig = stream.isMethodStyle
          ? 'Stream<$streamItemType${stream.itemType.isNullable ? '?' : ''}> ${stream.dartName}()'
          : 'Stream<$streamItemType${stream.itemType.isNullable ? '?' : ''}> get ${stream.dartName}';
      writer.line('  $streamSig {');
      writer.line('    checkDisposed();');
      // For struct streams, openStream is typed to the Proxy so the NativeFinalizer
      // is attached correctly, but the return is implicitly upcast to Stream<value>.
      final openType = isStruct ? '${itemType}Proxy${stream.itemType.isNullable ? '?' : ''}' : '$streamItemType${stream.itemType.isNullable ? '?' : ''}';
      writer.line('    return NitroRuntime.openStream<$openType>(');
      writer.line('      register: (port) => _register${cap}Ptr(port),');
      writer.line('      unpack: $unpackExpr,');
      writer.line('      release: (port) => _release${cap}Ptr(port),');
      writer.line(
        '      backpressure: Backpressure.${stream.backpressure.name},',
      );
      writer.line('    );');
      writer.line('  }');
      writer.blankLine();
    }

    writer.line('}');
    writer.blankLine();

    // PX19: Platform-conditional factory used by web-targeting specs.
    // When `web: NativeImpl.wasm` is targeted, the spec can route via:
    //
    //   import 'generated/web/xxx.web.bridge.g.dart'
    //       if (dart.library.ffi) 'xxx.g.dart';
    //
    //   static final T instance = _T_createPlatformInstance();
    //
    // This factory creates the native (dart:ffi) instance. The web bridge
    // exports a matching `create${ClassName}WebInstance()` factory.
    if (spec.targetsWeb) {
      writer.line(
        '/// PX19: Creates the native (dart:ffi) implementation of [${spec.dartClassName}].',
      );
      writer.line(
        '/// On web, import `*.web.bridge.g.dart` conditionally and call',
      );
      writer.line(
        '/// `create${spec.dartClassName}WebInstance()` instead.',
      );
      // Build a safe Dart identifier: lowercase the first alphabetic character.
      // Handles edge cases: single-char names ('A' → 'a'), underscore-prefixed
      // names ('_X' → '_x'), digits-first (rare; kept as-is for safety).
      final firstAlpha = spec.dartClassName.split('').indexWhere((c) => RegExp(r'[A-Za-z]').hasMatch(c));
      final camelName = firstAlpha >= 0
          ? spec.dartClassName.substring(0, firstAlpha) +
            spec.dartClassName[firstAlpha].toLowerCase() +
            spec.dartClassName.substring(firstAlpha + 1)
          : spec.dartClassName;
      writer.line(
        '${spec.dartClassName} ${camelName}_createNativeInstance() => _${spec.dartClassName}Impl();',
      );
      writer.blankLine();
    }

    return writer.toString();
  }

  static String _paramList(List<BridgeParam> params) {
    final positional = params.where((p) => !p.isNamed).map((p) => '${p.type.name} ${p.name}').join(', ');
    final named = params.where((p) => p.isNamed).toList();
    if (named.isEmpty) return positional;
    final namedStr = named
        .map((p) {
          if (p.defaultLiteral != null) return '${p.type.name} ${p.name} = ${p.defaultLiteral}';
          return '${p.type.name} ${p.name}';
        })
        .join(', ');
    final sep = positional.isEmpty ? '' : ', ';
    return '$positional$sep{$namedStr}';
  }

  static String _cap(String name) => name[0].toUpperCase() + name.substring(1);

  static String _toNativeType(BridgeFunction func, BridgeSpec spec) {
    // NativeAsync: C function returns void and takes an extra Int64 dart_port.
    final ret = func.isNativeAsync ? 'Void' : _typeToFFI(func.returnType, spec);
    final effectiveRet = func.returnType.isTypedData ? 'Pointer<Uint8>' : ret;
    final params = [
      ...func.params.expand((p) {
        if (p.type.isTypedData) return [_typeToFFI(p.type, spec), 'Int64'];
        return [_typeToFFI(p.type, spec)];
      }),
      if (func.isNativeAsync) 'Int64', // dart_port
      // S8: sync functions receive a NitroError* out-param instead of using
      // the two-call get_error()/clear_error() pattern.
      if (!func.isAsync && !func.isNativeAsync) 'Pointer<NitroErrorFfi>',
    ].join(', ');
    return '$effectiveRet Function($params)';
  }

  static String _toDartType(BridgeFunction func, BridgeSpec spec) {
    // NativeAsync: Dart callable returns void and takes an extra int dart_port.
    final ret = func.isNativeAsync ? 'void' : _typeToDartFFI(func.returnType, spec);
    final effectiveRet = func.returnType.isTypedData ? 'Pointer<Uint8>' : ret;
    final params = [
      ...func.params.expand((p) {
        if (p.type.isTypedData) return [_typeToDartFFI(p.type, spec), 'int'];
        return [_typeToDartFFI(p.type, spec)];
      }),
      if (func.isNativeAsync) 'int', // dart_port
      // S8: sync functions receive a Pointer<NitroErrorFfi> out-param.
      if (!func.isAsync && !func.isNativeAsync) 'Pointer<NitroErrorFfi>',
    ].join(', ');
    return '$effectiveRet Function($params)';
  }

  static String _typeToFFI(BridgeType bt, BridgeSpec spec) {
    if (bt.isFunction) {
      return 'Pointer<NativeFunction<${_callbackNativeSignature(bt, spec)}>>';
    }
    if (bt.isRecord) {
      return bt.isMap ? 'Pointer<Utf8>' : 'Pointer<Uint8>';
    }
    if (bt.isPointer) {
      return 'Pointer<${bt.pointerInnerType}>';
    }
    if (bt.isNativeHandle) return 'Pointer<Void>';
    final name = bt.name.replaceFirst('?', '');
    switch (name) {
      case 'int':
        return 'Int64';
      case 'double':
        return 'Double';
      case 'bool':
        return 'Int8';
      case 'String':
        return 'Pointer<Utf8>';
      case 'Uint8List':
        return 'Pointer<Uint8>';
      case 'Int8List':
        return 'Pointer<Int8>';
      case 'Int16List':
        return 'Pointer<Int16>';
      case 'Int32List':
        return 'Pointer<Int32>';
      case 'Uint16List':
        return 'Pointer<Uint16>';
      case 'Uint32List':
        return 'Pointer<Uint32>';
      case 'Float32List':
        return 'Pointer<Float>';
      case 'Float64List':
        return 'Pointer<Double>';
      case 'Int64List':
        return 'Pointer<Int64>';
      case 'Uint64List':
        return 'Pointer<Uint64>';
      case 'void':
        return 'Void';
    }
    if (spec.enums.any((en) => en.name == name)) return 'Int64';
    return 'Pointer<Void>';
  }

  static String _typeToDartFFI(BridgeType bt, BridgeSpec spec) {
    if (bt.isFunction) {
      return 'Pointer<NativeFunction<${_callbackNativeSignature(bt, spec)}>>';
    }
    if (bt.isRecord) {
      return bt.isMap ? 'Pointer<Utf8>' : 'Pointer<Uint8>';
    }
    if (bt.isPointer) {
      return 'Pointer<${bt.pointerInnerType}>';
    }
    if (bt.isNativeHandle) return 'Pointer<Void>';
    final name = bt.name.replaceFirst('?', '');
    switch (name) {
      case 'int':
        return 'int';
      case 'double':
        return 'double';
      case 'bool':
        return 'int';
      case 'String':
        return 'Pointer<Utf8>';
      case 'Uint8List':
        return 'Pointer<Uint8>';
      case 'Int8List':
        return 'Pointer<Int8>';
      case 'Int16List':
        return 'Pointer<Int16>';
      case 'Int32List':
        return 'Pointer<Int32>';
      case 'Uint16List':
        return 'Pointer<Uint16>';
      case 'Uint32List':
        return 'Pointer<Uint32>';
      case 'Float32List':
        return 'Pointer<Float>';
      case 'Float64List':
        return 'Pointer<Double>';
      case 'Int64List':
        return 'Pointer<Int64>';
      case 'Uint64List':
        return 'Pointer<Uint64>';
      case 'void':
        return 'void';
    }
    if (spec.enums.any((en) => en.name == name)) return 'int';
    return 'Pointer<Void>';
  }

  static String _decodeRecordExpr(BridgeType type, String ptrVar) {
    if (type.isMap) {
      return 'jsonDecode(($ptrVar as Pointer<Utf8>).toDartStringWithFree()) as Map<String, dynamic>';
    }
    final item = type.recordListItemType;
    if (item != null) {
      if (type.recordListItemIsPrimitive) {
        // Primitive lists are small scalars — eager decode is fast enough.
        final readCall = _primitiveReaderCall(item);
        return 'RecordReader.decodePrimitiveList($ptrVar, (r) => r.$readCall())';
      }
      // Object lists: decode lazily — items are only deserialized when accessed.
      // Requires the native buffer to have been written by encodeIndexedList.
      return 'LazyRecordList.decode($ptrVar, (r) => ${item}RecordExt.fromReader(r))';
    }
    final rt = type.name;
    return '${rt}RecordExt.fromNative($ptrVar)';
  }

  static void _emitTypedDataDecodeReturn(
    CodeWriter writer,
    BridgeType type,
    String ptrVar,
    String indent, {
    bool zeroCopy = false,
  }) {
    final rt = type.name.replaceFirst('?', '');
    final ffiElem = _typedDataFfiElement(rt);
    final lengthExpr = _typedDataElementSize(rt) == 1 ? 'byteLength' : 'byteLength ~/ ${_typedDataElementSize(rt)}';
    writer.line('${indent}if ($ptrVar == nullptr) {');
    writer.line("$indent  throw StateError('Native $rt return was null');");
    writer.line('$indent}');
    if (zeroCopy) {
      writer.line('$indent final byteLength = $ptrVar.cast<Int64>().value;');
      writer.line('$indent final dataAddress = Pointer<Int64>.fromAddress($ptrVar.address + 8).value;');
      writer.line('$indent final payloadPtr = Pointer<$ffiElem>.fromAddress(dataAddress);');
      writer.line('$indent return payloadPtr.asTypedList($lengthExpr, finalizer: _typedDataReturnFinalizer, token: $ptrVar.cast<Void>());');
      return;
    }
    writer.line('${indent}try {');
    writer.line('$indent  final byteLength = $ptrVar.cast<Int64>().value;');
    writer.line('$indent  final payloadPtr = Pointer<$ffiElem>.fromAddress($ptrVar.address + 8);');
    writer.line('$indent  return $rt.fromList(payloadPtr.asTypedList($lengthExpr));');
    writer.line('$indent} finally {');
    writer.line('$indent  malloc.free($ptrVar);');
    writer.line('$indent}');
  }

  static String _typedDataFfiElement(String dartType) {
    switch (dartType) {
      case 'Uint8List':
        return 'Uint8';
      case 'Int8List':
        return 'Int8';
      case 'Int16List':
        return 'Int16';
      case 'Int32List':
        return 'Int32';
      case 'Uint16List':
        return 'Uint16';
      case 'Uint32List':
        return 'Uint32';
      case 'Float32List':
        return 'Float';
      case 'Float64List':
        return 'Double';
      case 'Int64List':
        return 'Int64';
      case 'Uint64List':
        return 'Uint64';
      default:
        throw StateError('Unknown typed-data return type "$dartType".');
    }
  }

  static int _typedDataElementSize(String dartType) {
    switch (dartType) {
      case 'Uint8List':
      case 'Int8List':
        return 1;
      case 'Int16List':
      case 'Uint16List':
        return 2;
      case 'Int32List':
      case 'Uint32List':
      case 'Float32List':
        return 4;
      case 'Float64List':
      case 'Int64List':
      case 'Uint64List':
        return 8;
      default:
        throw StateError('Unknown typed-data return type "$dartType".');
    }
  }

  static String _primitiveReaderCall(String item) {
    switch (item) {
      case 'int':
        return 'readInt';
      case 'double':
        return 'readDouble';
      case 'bool':
        return 'readBool';
      default:
        return 'readString';
    }
  }

  static String _primitiveWriterCall(String item) {
    switch (item) {
      case 'int':
        return 'writeInt';
      case 'double':
        return 'writeDouble';
      case 'bool':
        return 'writeBool';
      default:
        return 'writeString';
    }
  }

  static String _encodeRecordParam(BridgeType type, String varName, String allocator) {
    if (type.isMap) {
      return 'jsonEncode($varName).toNativeUtf8(allocator: $allocator)';
    }
    final item = type.recordListItemType;
    if (item != null) {
      if (type.recordListItemIsPrimitive) {
        final writeCall = _primitiveWriterCall(item);
        return 'RecordWriter.encodeIndexedPrimitiveList($varName, (w, e) => w.$writeCall(e), $allocator)';
      }
      // Use indexed encoding so the receiving side can use LazyRecordList.
      return 'RecordWriter.encodeIndexedList($varName, (w, e) => e.writeFields(w), $allocator)';
    }
    return '$varName.toNative($allocator)';
  }

  // ── NativeAsync helpers ───────────────────────────────────────────────────

  /// Emits the body of a @NitroNativeAsync method.
  ///
  /// The generated code:
  ///  1. Opens a ReceivePort and passes its native port to the C bridge.
  ///  2. Awaits exactly one message (the native result).
  ///  3. Unpacks the raw message to the Dart return type.
  ///
  /// Arena params (String, TypedData, Record) are allocated, passed to the
  /// bridge call, then immediately freed — the native side must copy them.
  static void _emitNativeAsyncBody(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    String callArgs,
    bool needsArena,
  ) {
    final unpack = _nativeAsyncUnpack(func, spec);
    final openType = _nativeAsyncOpenType(func, spec);

    if (needsArena) {
      writer.line('    final arena = Arena();');
      writer.line('    try {');
      writer.line('      return NitroRuntime.openNativeAsync<$openType>(');
      writer.line('        call: (port) => _${func.dartName}Ptr($callArgs, port),');
      writer.line('        unpack: $unpack,');
      writer.line("        methodName: '${func.dartName}',");
      writer.line('      );');
      writer.line('    } finally {');
      writer.line('      arena.releaseAll();');
      writer.line('    }');
    } else {
      final plainCallArgs = func.params
          .map((p) {
            final t = p.type.name;
            if (spec.enums.any((en) => en.name == t)) return '${p.name}.nativeValue';
            if (t == 'bool') return '${p.name} ? 1 : 0';
            if (p.type.isFunction) return _callbackArgExpr(func, p);
            // Optional primitives: same sentinel encoding as the arena path.
            if (t == 'int?') return '${p.name} ?? -1';
            if (t == 'double?') return '${p.name} ?? double.nan';
            if (t == 'bool?') return '${p.name} == null ? -1 : (${p.name} ? 1 : 0)';
            return p.name;
          })
          .join(', ');

      final portSep = plainCallArgs.isEmpty ? '' : ', ';
      writer.line('    return NitroRuntime.openNativeAsync<$openType>(');
      writer.line('      call: (port) => _${func.dartName}Ptr($plainCallArgs${portSep}port),');
      writer.line('      unpack: $unpack,');
      writer.line("      methodName: '${func.dartName}',");
      writer.line('    );');
    }
  }

  /// The Dart type parameter for openNativeAsync`<T>` for this function.
  static String _nativeAsyncOpenType(BridgeFunction func, BridgeSpec spec) {
    final rt = func.returnType.name;
    // For the openNativeAsync<T> type param, strip the nullable suffix — the
    // native post mechanism uses sentinel values (−1 / NaN / nullptr) for null,
    // not Dart null, so the transport type is always non-nullable.
    final rtBase = rt.replaceFirst('?', '');
    if (rt == 'void') return 'void';
    if (rtBase == 'bool') return 'bool';
    if (rtBase == 'String') return 'Pointer<Utf8>';
    if (func.returnType.isRecord) return 'Pointer<Uint8>';
    if (spec.structs.any((st) => st.name == rtBase)) return 'Pointer<Void>';
    if (spec.enums.any((en) => en.name == rtBase)) return 'int';
    if (rtBase == 'int') return 'int';
    if (rtBase == 'double') return 'double';
    return rtBase;
  }

  /// Returns the unpack lambda expression for a @NitroNativeAsync method.
  ///
  /// The native side posts via Dart_PostCObject_DL:
  ///  • primitives (int/double) → kInt64/kDouble → received as int/double
  ///  • bool                   → kBool          → received as bool
  ///  • void                   → kNull           → received as null
  ///  • String                 → kString         → received as Dart String
  ///  • record/struct/list     → kInt64 (ptr)    → decode from Pointer`<Uint8>`
  ///  • enum                   → kInt64          → call .toEnumType()
  static String _nativeAsyncUnpack(BridgeFunction func, BridgeSpec spec) {
    final rt = func.returnType.name;
    final rtBase = rt.replaceFirst('?', '');
    final isNullable = rt.endsWith('?');

    if (rt == 'void') return '(_) {}';

    // bool / bool?
    if (rtBase == 'bool') {
      return isNullable
          ? '(raw) => (raw as bool?) == null ? null : raw as bool'
          : '(raw) => raw as bool';
    }

    // String / String?  — native posts kString or kNull
    if (rtBase == 'String') {
      return isNullable
          ? '(raw) { final p = Pointer<Utf8>.fromAddress(raw as int); return p == nullptr ? null : p.toDartStringWithFree(); }'
          : '(raw) => raw as String';
    }

    // @HybridRecord  — native posts kInt64 (pointer to binary buffer)
    if (func.returnType.isRecord) {
      final decodeExpr = _decodeRecordExpr(func.returnType, 'rawPtr');
      final isLazy = func.returnType.recordListItemType != null && !func.returnType.recordListItemIsPrimitive;
      if (isNullable) {
        if (isLazy) {
          return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); if (rawPtr == nullptr) return null; return $decodeExpr; }';
        }
        return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); if (rawPtr == nullptr) return null; try { return $decodeExpr; } finally { malloc.free(rawPtr); } }';
      }
      if (isLazy) {
        return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); return $decodeExpr; }';
      }
      return '(raw) { final rawPtr = Pointer<Uint8>.fromAddress(raw as int); try { return $decodeExpr; } finally { malloc.free(rawPtr); } }';
    }

    // @HybridStruct  — native posts kInt64 (pointer to heap struct)
    if (spec.structs.any((st) => st.name == rtBase)) {
      if (isNullable) {
        return '(raw) { final ptr = Pointer<${rtBase}Ffi>.fromAddress(raw as int); if (ptr == nullptr) return null; try { return ptr.ref.toDart(); } finally { ptr.ref.freeFields(); malloc.free(ptr); } }';
      }
      return '(raw) { final ptr = Pointer<${rtBase}Ffi>.fromAddress(raw as int); try { return ptr.ref.toDart(); } finally { ptr.ref.freeFields(); malloc.free(ptr); } }';
    }

    // @HybridEnum  — native posts kInt64 rawValue
    if (spec.enums.any((en) => en.name == rtBase)) {
      return isNullable
          ? '(raw) { final v = raw as int; return v == -1 ? null : v.to$rtBase(); }'
          : '(raw) => (raw as int).to$rtBase()';
    }

    // int / int?  — native posts kInt64; sentinel −1 = null
    if (rtBase == 'int') {
      return isNullable
          ? '(raw) { final v = raw as int; return v == -1 ? null : v; }'
          : '(raw) => raw as int';
    }

    // double / double?  — native posts kDouble; sentinel NaN = null
    if (rtBase == 'double') {
      return isNullable
          ? '(raw) { final v = raw as double; return v.isNaN ? null : v; }'
          : '(raw) => raw as double';
    }

    // Fallthrough: unknown type — cast directly (should not normally occur).
    return '(raw) => raw as $rt';
  }

  // S8: always-on error check via the pre-allocated out-param slot.
  // This replaces the old assert-gated get_error()/clear_error() pattern.
  // Errors are now detected in BOTH debug AND release builds.
  static String _inlineCheckError() {
    return 'NitroRuntime.throwIfOutParamError(_nitroErr);';
  }

  // ── Unified return decode helper ──────────────────────────────────────────
  // Single source of truth for decoding raw FFI results into Dart values.
  // Replaces four duplicated if/else chains (sync-arena, sync-no-arena,
  // async-arena, async-no-arena). Calls existing _decodeRecordExpr /
  // _emitTypedDataDecodeReturn so emitted code is byte-for-byte identical.
  static void _emitReturnDecode(
    CodeWriter writer,
    BridgeType returnType,
    String resVar,
    String indent,
    BridgeSpec spec, {
    bool zeroCopy = false,
    bool isOwned = false,
    String? dartName,
    String nativeHandleTypeParam = 'Void',
  }) {
    final rt = returnType.name;
    final kind = classifyReturn(returnType, spec);
    final base = returnType.baseName;

    switch (kind) {
      case ReturnKind.voidType:
        return;
      case ReturnKind.record:
        final decodeExpr = _decodeRecordExpr(returnType, resVar);
        final isLazy = returnType.recordListItemType != null && !returnType.recordListItemIsPrimitive;
        if (isLazy) {
          writer.line('${indent}return $decodeExpr;');
        } else {
          writer.line('${indent}final $rt decoded;');
          writer.line('${indent}try {');
          writer.line('$indent  decoded = $decodeExpr;');
          writer.line('$indent} finally {');
          writer.line('$indent  malloc.free($resVar);');
          writer.line('$indent}');
          writer.line('${indent}return decoded;');
        }
      case ReturnKind.typedData:
        _emitTypedDataDecodeReturn(writer, returnType, resVar, indent, zeroCopy: zeroCopy);
      case ReturnKind.struct:
        writer.line('${indent}if ($resVar == nullptr) {');
        writer.line('$indent  throw StateError(\'${dartName ?? rt} returned null\');');
        writer.line('$indent}');
        writer.line('${indent}final structPtr = Pointer<${base}Ffi>.fromAddress($resVar.address);');
        writer.line('${indent}final $base decoded;');
        writer.line('${indent}try {');
        writer.line('$indent  decoded = structPtr.ref.toDart();');
        writer.line('$indent} finally {');
        writer.line('$indent  structPtr.ref.freeFields();');
        writer.line('$indent  malloc.free(structPtr);');
        writer.line('$indent}');
        writer.line('${indent}return decoded;');
      case ReturnKind.nativeHandle:
        if (isOwned && dartName != null) {
          writer.line('${indent}final handle = NativeHandle<$nativeHandleTypeParam>.fromAddress($resVar.address);');
          writer.line('${indent}_${dartName}Finalizer.attach(handle, $resVar.cast(), detach: handle);');
          writer.line("${indent}handle._releaseCallback = (addr) { _${dartName}ReleaseFn(Pointer<Void>.fromAddress(addr)); _${dartName}Finalizer.detach(handle); };");
          writer.line('${indent}return handle;');
        } else {
          writer.line('${indent}return NativeHandle<$nativeHandleTypeParam>.fromAddress($resVar.address);');
        }
      case ReturnKind.enumType:
        // Nullable enum: -1 sentinel = null; otherwise decode rawValue.
        final isNullableEnum = returnType.isNullable || returnType.name.endsWith('?');
        if (isNullableEnum) {
          writer.line('${indent}return $resVar == -1 ? null : $resVar.to$base();');
        } else {
          writer.line('${indent}return $resVar.to$base();');
        }
      case ReturnKind.boolNonNull:
        writer.line('${indent}return $resVar != 0;');
      case ReturnKind.boolNullable:
        writer.line('${indent}return $resVar == -1 ? null : $resVar != 0;');
      case ReturnKind.stringNonNull:
        writer.line('${indent}return $resVar.toDartStringWithFree();');
      case ReturnKind.stringNullable:
        writer.line('${indent}return $resVar == nullptr ? null : $resVar.toDartStringWithFree();');
      case ReturnKind.intNullable:
        writer.line('${indent}return $resVar == -1 ? null : $resVar;');
      case ReturnKind.doubleNullable:
        writer.line('${indent}return $resVar.isNaN ? null : $resVar;');
      case ReturnKind.primitive:
        writer.line('${indent}return $resVar;');
    }
  }

  /// Variable name used for the raw async result based on return kind.
  /// Keeps emitted code readable: `rawPtr` for pointer types, `res` for scalars.
  static String _asyncResVarName(ReturnKind kind) => switch (kind) {
    ReturnKind.record    => 'rawPtr',
    ReturnKind.typedData => 'rawPtr',
    ReturnKind.struct    => 'rawPtr',
    _                    => 'res',
  };

  // Kept for callers that already pass an indent; delegates to the S8 form.
  static String _assertCheckError(String indent) => '$indent${_inlineCheckError()}';

  // ── Leaf / isLeaf helpers ─────────────────────────────────────────────────

  /// Returns true when [bt] maps to a plain FFI scalar (int, double, bool, or
  /// a known enum) — types that require no arena allocation and no Dart heap
  /// object creation on the call boundary.
  static bool _isPrimitiveType(BridgeType bt, BridgeSpec spec) {
    if (bt.isRecord || bt.isTypedData || bt.isPointer || bt.isFunction || bt.isNativeHandle) return false;
    final name = bt.name.replaceFirst('?', '');
    if (name == 'String' || name == 'void') return false;
    if (spec.structs.any((st) => st.name == name)) return false;
    // int, double, bool, and known enums are all FFI scalars.
    return true;
  }

  /// Returns true when the function pointer should be bound with `isLeaf: true`.
  ///
  /// `isLeaf: true` skips the Dart VM safepoint transition, shaving ~50–200 ns
  /// per call.  It is safe when the C++ body never calls back into Dart and the
  /// call is expected to be short-lived (no blocking I/O).
  ///
  /// Conditions:
  ///  • Not async (async calls dispatch to isolates, irrelevant here).
  ///  • Explicitly named "Fast" — a developer contract that the method is hot.
  ///  • OR all params and the return type are plain scalars (no arena needed).
  static bool _isLeafCandidate(BridgeFunction func, BridgeSpec spec) {
    if (func.isAsync || func.isNativeAsync) return false;
    if (func.dartName.endsWith('Fast')) return true;
    final rt = func.returnType;
    if (!_isPrimitiveType(rt, spec) && rt.name != 'void') return false;
    return func.params.every((p) => _isPrimitiveType(p.type, spec));
  }

  static bool _hasFunctionTypeParams(BridgeSpec spec) {
    return spec.functions.any((f) => f.params.any((p) => p.type.isFunction));
  }

  static void _assertSupportedFunctionTypes(BridgeSpec spec) {
    for (final func in spec.functions) {
      if (func.returnType.isFunction) {
        throw UnsupportedError(
          '${spec.dartClassName}.${func.dartName}() returns function type "${func.returnType.name}", which is not a supported native ABI type.',
        );
      }
      for (final param in func.params) {
        if (param.type.isFunction) {
          _assertSupportedCallbackType(spec, func, param);
        }
      }
    }
    for (final prop in spec.properties) {
      if (prop.type.isFunction) {
        throw UnsupportedError(
          '${spec.dartClassName}.${prop.dartName} uses function type "${prop.type.name}", which is not a supported native ABI type.',
        );
      }
    }
  }

  static void _assertSupportedCallbackType(
    BridgeSpec spec,
    BridgeFunction func,
    BridgeParam param,
  ) {
    final callback = param.type;
    final returnName = (callback.functionReturnType ?? 'void').replaceFirst('?', '');
    if (returnName != 'void' && returnName != 'int' && returnName != 'double' && returnName != 'bool' && !spec.enums.any((e) => e.name == returnName)) {
      throw UnsupportedError(
        '${spec.dartClassName}.${func.dartName}() parameter "${param.name}" has callback return type "$returnName", which is not supported. Callback returns currently support void, int, double, bool, and @HybridEnum.',
      );
    }
    for (final callbackParam in callback.functionParams) {
      if (!_isSupportedCallbackParam(callbackParam, spec)) {
        throw UnsupportedError(
          '${spec.dartClassName}.${func.dartName}() parameter "${param.name}" has callback parameter type "${callbackParam.name}", which is not supported. Callback parameters currently support int, double, bool, String, Pointer<T>, and @HybridEnum.',
        );
      }
    }
  }

  static bool _isSupportedCallbackParam(BridgeType type, BridgeSpec spec) {
    if (type.isPointer) return true;
    final name = type.name.replaceFirst('?', '');
    if (name == 'int' || name == 'double' || name == 'bool' || name == 'String') return true;
    if (spec.enums.any((e) => e.name == name)) return true;
    if (spec.structs.any((s) => s.name == name)) return true;
    if (spec.recordTypes.any((r) => r.name == name)) return true;
    return false;
  }

  static void _emitCallbackHelpers(CodeWriter writer, BridgeSpec spec) {
    writer.line('  // Native callback handles are cached so native code can retain');
    writer.line('  // callback pointers safely until this HybridObject is disposed.');
    for (final func in spec.functions) {
      for (final param in func.params.where((p) => p.type.isFunction)) {
        final helperName = _callbackHelperName(func, param);
        final dartType = _callbackDartType(param.type, spec, nullable: false);
        final nativeSig = _callbackNativeSignature(param.type, spec);
        final callbackFactory = _callbackFactory(param.type);
        final exceptionalReturn = _callbackExceptionalReturn(param.type, spec);
        final exceptionalArg = exceptionalReturn == null ? '' : ', exceptionalReturn: $exceptionalReturn';
        writer.line('  NativeCallable<$nativeSig> $helperName($dartType callback) {');
        writer.line("    final key = ('${func.dartName}.${param.name}', callback);");
        writer.line('    return _nativeCallbackCache.putIfAbsent(key, () {');
        writer.line('      return NativeCallable<$nativeSig>.$callbackFactory((${_callbackWrapperParams(param.type, spec)}) {');
        final invocationArgs = _callbackInvocationArgs(param.type, spec);
        final callbackInvocation = 'callback($invocationArgs)';
        final returnExpr = _callbackReturnExpression(param.type, spec, callbackInvocation);
        if (returnExpr == null) {
          writer.line('        $callbackInvocation;');
        } else {
          writer.line('        return $returnExpr;');
        }
        writer.line('      }$exceptionalArg);');
        writer.line('    }) as NativeCallable<$nativeSig>;');
        writer.line('  }');
        writer.blankLine();
      }
    }
  }

  static String _callbackFactory(BridgeType callbackType) {
    final returnName = (callbackType.functionReturnType ?? 'void').replaceFirst('?', '');
    return returnName == 'void' ? 'listener' : 'isolateLocal';
  }

  static String? _callbackExceptionalReturn(BridgeType callbackType, BridgeSpec spec) {
    final returnName = (callbackType.functionReturnType ?? 'void').replaceFirst('?', '');
    if (returnName == 'void') return null;
    if (returnName == 'double') return '0.0';
    if (returnName == 'bool') return '0';
    if (returnName == 'int' || spec.enums.any((e) => e.name == returnName)) return '0';
    return null;
  }

  static String _callbackArgExpr(BridgeFunction func, BridgeParam param) {
    final helper = _callbackHelperName(func, param);
    final nullable = param.type.isNullable || param.type.name.endsWith('?');
    if (nullable) {
      return '${param.name} == null ? nullptr : $helper(${param.name}!).nativeFunction';
    }
    return '$helper(${param.name}).nativeFunction';
  }

  static String _callbackHelperName(BridgeFunction func, BridgeParam param) {
    return '_nativeCallback${_cap(func.dartName)}${_cap(param.name)}';
  }

  static String _callbackNativeSignature(BridgeType callbackType, BridgeSpec spec) {
    final ret = _callbackReturnToFFI(callbackType.functionReturnType ?? 'void', spec);
    final params = callbackType.functionParams.map((p) => _callbackParamToFFI(p, spec)).join(', ');
    return '$ret Function($params)';
  }

  static String _callbackDartType(BridgeType callbackType, BridgeSpec spec, {required bool nullable}) {
    final ret = callbackType.functionReturnType ?? 'void';
    final params = callbackType.functionParams.map((p) => p.name).join(', ');
    final suffix = nullable ? '?' : '';
    return '$ret Function($params)$suffix';
  }

  static String _callbackReturnToFFI(String dartType, BridgeSpec spec) {
    final name = dartType.replaceFirst('?', '');
    if (name == 'void') return 'Void';
    if (name == 'int') return 'Int64';
    if (name == 'double') return 'Double';
    if (name == 'bool') return 'Int8';
    if (spec.enums.any((e) => e.name == name)) return 'Int64';
    return 'Void';
  }

  static String _callbackParamToFFI(BridgeType type, BridgeSpec spec) {
    if (type.isPointer) return 'Pointer<${type.pointerInnerType ?? 'Void'}>';
    final name = type.name.replaceFirst('?', '');
    if (name == 'int') return 'Int64';
    if (name == 'double') return 'Double';
    if (name == 'bool') return 'Int8';
    if (name == 'String') return 'Pointer<Utf8>';
    if (spec.enums.any((e) => e.name == name)) return 'Int64';
    if (spec.structs.any((s) => s.name == name)) return 'Pointer<Void>';
    if (spec.recordTypes.any((r) => r.name == name)) return 'Pointer<Uint8>';
    return 'Pointer<Void>';
  }

  static String _callbackWrapperParams(BridgeType callbackType, BridgeSpec spec) {
    return callbackType.functionParams
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key;
          final type = entry.value;
          return '${_callbackParamToDartFFI(type, spec)} arg$index';
        })
        .join(', ');
  }

  static String _callbackParamToDartFFI(BridgeType type, BridgeSpec spec) {
    if (type.isPointer) return 'Pointer<${type.pointerInnerType ?? 'Void'}>';
    final name = type.name.replaceFirst('?', '');
    if (name == 'int') return 'int';
    if (name == 'double') return 'double';
    if (name == 'bool') return 'int';
    if (name == 'String') return 'Pointer<Utf8>';
    if (spec.enums.any((e) => e.name == name)) return 'int';
    if (spec.structs.any((s) => s.name == name)) return 'Pointer<Void>';
    if (spec.recordTypes.any((r) => r.name == name)) return 'Pointer<Uint8>';
    return 'Pointer<Void>';
  }

  static String _callbackInvocationArgs(BridgeType callbackType, BridgeSpec spec) {
    return callbackType.functionParams
        .asMap()
        .entries
        .map((entry) {
          final index = entry.key;
          final type = entry.value;
          final name = type.name.replaceFirst('?', '');
          if (name == 'bool') return 'arg$index != 0';
          if (name == 'String') return 'arg$index.toDartString()';
          if (spec.enums.any((e) => e.name == name)) return 'arg$index.to$name()';
          if (spec.structs.any((s) => s.name == name)) {
            // C passes a pointer to the stack-allocated struct. Cast and dereference.
            return 'arg$index.cast<${name}Ffi>().ref.toDart()';
          }
          if (spec.recordTypes.any((r) => r.name == name)) {
            // C passes a malloc'd length-prefixed buffer. Eagerly read then free
            // so the buffer is released before the user callback runs.
            return '(() { final _r = $name.fromNative(arg$index); malloc.free(arg$index); return _r; })()';
          }
          return 'arg$index';
        })
        .join(', ');
  }

  static String? _callbackReturnExpression(BridgeType callbackType, BridgeSpec spec, String invocation) {
    final returnName = (callbackType.functionReturnType ?? 'void').replaceFirst('?', '');
    if (returnName == 'void') return null;
    if (returnName == 'bool') return '$invocation ? 1 : 0';
    if (spec.enums.any((e) => e.name == returnName)) return '$invocation.nativeValue';
    return invocation;
  }
}
