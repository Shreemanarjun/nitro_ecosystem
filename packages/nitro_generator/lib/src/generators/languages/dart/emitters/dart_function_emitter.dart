part of '../dart_ffi_generator.dart';

/// Emits `@override` method implementations for all [BridgeFunction]s.
void _emitFunctionImpls(CodeWriter writer, BridgeSpec spec) {
  // ── Method implementations ───────────────────────────────────────────────
  for (final func in spec.functions) {
    // A parameter needs an Arena when it must be stack-allocated for the FFI
    // call: strings, records, structs, variants, nullable primitives (NitroOpt*
    // structs), TypedData (pointer+length pair), and maps.
    // classifyBridgeItem() is the canonical classifier — adding a new nullable
    // type only requires updating BridgeItemKind, not every needsArena check.
    final needsArena = func.params.any((p) {
      if (p.type.isAnyMap) return true; // maps are not classified by BridgeItemKind
      final kind = classifyBridgeItem(p.type, spec);
      return kind.isStringKind ||
          kind.isRecordKind ||
          kind.isStructKind ||
          kind.isVariantKind ||
          kind.isNullablePrimitive ||
          p.type.isTypedData;
    });

    final callArgs = func.params
        .expand((p) {
          final t = p.type.name;
          if (p.type.isAnyMap || p.type.isRecord) {
            return [_encodeRecordParam(p.type, p.name, 'arena')];
          }
          // @NitroVariant param: encode as [4B len][1B tag][fields] using toNative(alloc).
          final tBase2 = t.replaceFirst('?', '');
          if (spec.isVariantName(tBase2)) {
            return ['${p.name}.toNative(arena)'];
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
          if (spec.isStructName(t)) {
            return ['${p.name}.toNative(arena).cast<Void>()'];
          }
          final tBase = t.replaceFirst('?', '');
          if (t.endsWith('?') && spec.isStructName(tBase)) {
            return ['${p.name} != null ? ${p.name}.toNative(arena).cast<Void>() : nullptr'];
          }
          // Enum (including nullable enum: TcStatus? uses -1 as null sentinel)
          if (spec.isEnumName(tBase)) {
            if (t.endsWith('?')) {
              return ['${p.name} == null ? -1 : ${p.name}.nativeValue'];
            }
            return ['${p.name}.nativeValue'];
          }
          if (t == 'bool') return ['${p.name} ? 1 : 0'];
          if (t == 'DateTime') return ['${p.name}.millisecondsSinceEpoch'];
          if (t == 'DateTime?') return ['arena.packInt(${p.name}?.millisecondsSinceEpoch)'];
          // Optional primitives: NitroOpt* packed struct encoding via Arena.
          if (t == 'int?') return ['arena.packInt(${p.name})'];
          if (t == 'double?') return ['arena.packDouble(${p.name})'];
          if (t == 'bool?') return ['arena.packBool(${p.name})'];
          return [p.name];
        })
        .join(', ');
    final instancedCallArgs = callArgs.isEmpty ? '_instanceId' : '_instanceId, $callArgs';

    // For NativeAsync, the return type annotation is Future<T> but asyncMod is
    // left empty (no `async` keyword) — the method returns an already-Future.
    // NativeHandle<T>: the declared Dart return type is NativeHandle<T>
    // but the FFI function pointer returns Pointer<Void>.
    final nativeHandleTypeParam = func.returnType.nativeHandleTypeParam ?? 'Void';
    final resultReturnType = _nitroResultInnerType(func.returnType);
    final effectiveDartReturnName = func.isResult
        ? 'NitroResultValue<${resultReturnType.name}>'
        : func.returnType.isNativeHandle
        ? 'NativeHandle<$nativeHandleTypeParam>'
        : func.returnType.name;
    final returnType = (func.isAsync || func.isNativeAsync) ? 'Future<$effectiveDartReturnName>' : effectiveDartReturnName;
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
      _emitNativeAsyncBody(writer, func, spec, instancedCallArgs, needsArena);
    } else if (func.isAsync) {
      // plainCallArgs: used when no arena is needed. Apply the same optional-primitive
      // sentinel encoding as callArgs so that int?/bool?/double? are never passed as null.
      // (Structs, TypedData, String all require an arena so they can't appear here.)
      final plainCallArgs = func.params
          .map((p) {
            final t = p.type.name;
            final tBase = p.type.baseName;
            if (t == 'bool') return '${p.name} ? 1 : 0';
            if (t == 'DateTime') return '${p.name}.millisecondsSinceEpoch';
            // Nullable enum: TcStatus? → -1 for null, rawValue otherwise
            if (spec.isEnumName(tBase)) {
              return t.endsWith('?') ? '${p.name} == null ? -1 : ${p.name}.nativeValue' : '${p.name}.nativeValue';
            }
            if (p.type.isFunction) return _callbackArgExpr(func, p);
            return p.name;
          })
          .join(', ');
      final instancedPlainCallArgs = plainCallArgs.isEmpty ? '_instanceId' : '_instanceId, $plainCallArgs';

      final callAsyncType = callAsyncTransportType(func.returnType, spec);

      final errArgs = "getError: _getErrorNativePtr, clearError: _clearErrorNativePtr, methodName: '${func.dartName}'";

      // @NitroAsync(timeout: N) — Dart-side Future.timeout() is the safe cross-
      // platform mechanism. Swift NSException.raise() in a @_cdecl frame is unsafe
      // (escapes into C frames → abort()); Kotlin withTimeout is kept for Android.
      final tox = func.asyncTimeout == null
          ? ''
          : ".timeout(const Duration(milliseconds: ${func.asyncTimeout!}), onTimeout: () => throw HybridException(name: 'NitroAsyncTimeout', message: '${func.dartName} timed out after ${func.asyncTimeout!}ms'))";

      // ── @NitroResult async: C returns Pointer<Uint8> tagged buffer ────────
      // The bridge always returns [1B tag: 0=ok, 1=err][payload]. We receive
      // it via callAsync<Pointer<Uint8>> then decode exactly like the sync path.
      if (func.isResult) {
        if (needsArena) {
          writer.line('    final arena = Arena();');
          writer.line('    try {');
          writer.line('      final res = await NitroRuntime.callAsync<Pointer<Uint8>>(_${func.dartName}Ptr, [$instancedCallArgs], $errArgs)$tox;');
          _emitResultDecode(writer, resultReturnType, 'res', '      ', spec);
          writer.line('    } finally {');
          writer.line('      arena.releaseAll();');
          writer.line('    }');
        } else {
          writer.line('    final res = await NitroRuntime.callAsync<Pointer<Uint8>>(_${func.dartName}Ptr, [$instancedPlainCallArgs], $errArgs)$tox;');
          _emitResultDecode(writer, resultReturnType, 'res', '    ', spec);
        }
      } else if (needsArena) {
        // needsArena path: wrap in try/finally to release arena allocations.
        final asyncResVar = _asyncResVarName(returnKind);
        writer.line('    final arena = Arena();');
        writer.line('    try {');
        if (returnKind == ReturnKind.voidType) {
          // void return: don't assign to a variable — it's unused and warns.
          writer.line('      await NitroRuntime.callAsync<$callAsyncType>(_${func.dartName}Ptr, [$instancedCallArgs], $errArgs)$tox;');
        } else {
          writer.line('      final $asyncResVar = await NitroRuntime.callAsync<$callAsyncType>(_${func.dartName}Ptr, [$instancedCallArgs], $errArgs)$tox;');
          _emitReturnDecode(writer, func.returnType, asyncResVar, '      ', spec, zeroCopy: func.zeroCopyReturn, dartName: func.dartName, isOwned: func.isOwned, nativeHandleTypeParam: nativeHandleTypeParam);
        }
        writer.line('    } finally {');
        writer.line('      arena.releaseAll();');
        writer.line('    }');
      } else {
        if (returnKind == ReturnKind.voidType) {
          writer.line('    await NitroRuntime.callAsync<$callAsyncType>(_${func.dartName}Ptr, [$instancedPlainCallArgs], $errArgs)$tox;');
        } else {
          final asyncResVar = _asyncResVarName(returnKind);
          writer.line('    final $asyncResVar = await NitroRuntime.callAsync<$callAsyncType>(_${func.dartName}Ptr, [$instancedPlainCallArgs], $errArgs)$tox;');
          _emitReturnDecode(writer, func.returnType, asyncResVar, '    ', spec, zeroCopy: func.zeroCopyReturn, dartName: func.dartName, isOwned: func.isOwned, nativeHandleTypeParam: nativeHandleTypeParam);
        }
      }
    } else if (func.isResult) {
      // ── @NitroResult sync path ────────────────────────────────────────────
      // C function returns Pointer<Uint8>: [1B tag: 0=ok, 1=err][record payload].
      // Errors are communicated through the tag, not the error slot.
      final mnArg = ", methodName: '${func.dartName}'";
      final syncArgs = '$instancedCallArgs, _nitroErr';
      if (needsArena) {
        writer.line('    return NitroRuntime.callSync(() => withArena((arena) {');
        writer.line('      final res = _${func.dartName}Ptr($syncArgs);');
        _emitResultDecode(writer, resultReturnType, 'res', '      ', spec);
        writer.line('    })$mnArg);');
      } else {
        writer.line('    return NitroRuntime.callSync(() {');
        writer.line('      final res = _${func.dartName}Ptr($syncArgs);');
        _emitResultDecode(writer, resultReturnType, 'res', '      ', spec);
        writer.line('    }$mnArg);');
      }
    } else {
      // ── Synchronous path — wrapped in callSync for logging + slow-call detection ──
      final mnArg = ", methodName: '${func.dartName}'";
      // S8: append the pre-allocated error slot as the last argument so the C
      // bridge can write error info directly without a separate get_error() call.
      final syncArgs = '$instancedCallArgs, _nitroErr';
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
          _emitReturnDecode(writer, func.returnType, 'res', '      ', spec, zeroCopy: func.zeroCopyReturn, dartName: func.dartName, isOwned: func.isOwned, nativeHandleTypeParam: nativeHandleTypeParam);
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
          _emitReturnDecode(writer, func.returnType, 'res', '      ', spec, zeroCopy: func.zeroCopyReturn, dartName: func.dartName, isOwned: func.isOwned, nativeHandleTypeParam: nativeHandleTypeParam);
          writer.line('    }$mnArg);');
        }
      }
    }
    writer.line('  }');
    writer.blankLine();
  }
}

BridgeType _nitroResultInnerType(BridgeType returnType) {
  final match = RegExp(r'^NitroResultValue<(.+)>$').firstMatch(returnType.name.trim());
  if (match == null) return returnType;

  final innerName = match.group(1)!.trim();
  return BridgeType(
    name: innerName,
    isNullable: innerName.endsWith('?'),
    isRecord: returnType.isRecord,
    isPointer: returnType.isPointer,
    pointerInnerType: returnType.pointerInnerType,
    recordListItemType: returnType.recordListItemType,
    recordListItemIsPrimitive: returnType.recordListItemIsPrimitive,
    isEnumList: returnType.isEnumList,
    isVariantList: returnType.isVariantList,
    isMap: returnType.isMap,
    isAnyMap: returnType.isAnyMap,
    isFunction: returnType.isFunction,
    functionReturnType: returnType.functionReturnType,
    functionParams: returnType.functionParams,
    isNativeHandle: returnType.isNativeHandle,
    nativeHandleTypeParam: returnType.nativeHandleTypeParam,
  );
}
