part of '../dart_ffi_generator.dart';

/// Emits `@override` method implementations for all [BridgeFunction]s.
void _emitFunctionImpls(CodeWriter writer, BridgeSpec spec) {
  // ── Method implementations ───────────────────────────────────────────────
  for (final func in spec.functions) {
    // Leaf-struct-create: sync functions whose only arena-requiring params are
    // A parameter needs an Arena when it must be stack-allocated for the FFI
    // call: strings, records, structs, variants, nullable primitives (NitroOpt*
    // structs), TypedData (pointer+length pair), and maps.
    // classifyBridgeItem() is the canonical classifier — adding a new nullable
    // type only requires updating BridgeItemKind, not every needsArena check.
    final needsArena = func.params.any((p) {
      if (p.type.isAnyMap) return true; // maps are not classified by BridgeItemKind
      if (spec.isCustomTypeName(p.type.baseName)) return true; // custom type codec encode needs arena
      final kind = classifyBridgeItem(p.type, spec);
      return kind.isStringKind || kind.isRecordKind || kind.isStructKind || kind.isVariantKind || kind.isNullablePrimitive || p.type.isTypedData;
    });

    final callArgs = func.params
        .expand((p) {
          final t = p.type.name;
          if (p.type.isAnyMap || p.type.isRecord) {
            return [_encodeRecordParam(p.type, p.name, 'arena')];
          }
          // @NitroVariant param: encode as [4B len][1B tag][fields] using toNative(alloc).
          final tBase2 = bareTypeName(t);
          if (spec.isVariantName(tBase2)) {
            return ['${p.name}.toNative(arena)'];
          }
          if (p.type.isFunction) {
            return [_callbackArgExpr(func, p)];
          }
          if (p.type.isPointer) {
            return [p.name];
          }
          if (p.type.isNativeHandle) {
            return [_nativeHandleArgExpr(p)];
          }
          if (p.type.isTypedData) {
            // Nullable list: nullptr + length 0 for null (an empty list still
            // gets a real pointer, so native can tell the two apart).
            if (t.endsWith('?')) return ['${p.name} == null ? nullptr : ${p.name}.toPointer(arena)', '${p.name}?.length ?? 0'];
            return ['${p.name}.toPointer(arena)', '${p.name}.length'];
          }
          if (t == 'String') {
            return ['${p.name}.toNitroUtf8(allocator: arena)'];
          }
          if (t == 'String?') {
            return ['${p.name} != null ? ${p.name}.toNitroUtf8(allocator: arena) : nullptr'];
          }
          if (spec.isStructName(t)) {
            return ['${p.name}.toNative(arena).cast<Void>()'];
          }
          final tBase = bareTypeName(t);
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
          if (t == 'bool') return [p.name]; // Bool FFI type — pass directly, no int conversion
          if (t == 'DateTime') return ['${p.name}.millisecondsSinceEpoch'];
          if (t == 'DateTime?') return ['arena.packInt(${p.name}?.millisecondsSinceEpoch)'];
          // AnyNativeObject: encode as instanceId; nullable uses -1 sentinel.
          if (p.type.isAnyNativeObject) {
            if (t.endsWith('?')) return ['${p.name}?.instanceId ?? -1'];
            return ['${p.name}.instanceId'];
          }
          // @NitroCustomType: encode via user codec.
          final tBaseCustom = bareTypeName(t);
          if (spec.isCustomTypeName(tBaseCustom)) {
            final ct = spec.customTypeByName(tBaseCustom)!;
            return ['const ${ct.codecClass}().encode(${p.name}, arena)'];
          }
          // Optional primitives: NitroOpt* packed struct encoding via Arena.
          if (t == 'int?') return ['arena.packInt(${p.name})'];
          if (t == 'double?') return ['arena.packDouble(${p.name})'];
          if (t == 'bool?') return ['arena.packBool(${p.name})'];
          // uint64? reuses NitroOptInt64 struct (same 9-byte layout; bits preserved as int).
          if (t == 'uint64?') return ['arena.packInt(${p.name})'];
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
    final wrapper = func.returnsFutureOr ? 'FutureOr' : 'Future';
    final returnType = (func.isAsync || func.isNativeAsync || func.inlineFuture) ? '$wrapper<$effectiveDartReturnName>' : effectiveDartReturnName;
    // inlineFuture: the sync body runs inside an `async` function; the future
    // completes inline (no port, no isolate wake). Measured: Future.sync,
    // Future.value and a sync Completer are no cheaper in a Flutter build —
    // the await/microtask is the floor. A `FutureOr<T>` spec skips even that:
    // the inline body returns the value, a dispatched @nitroAsync returns the
    // bridge future as is. The isolate-pool path always awaits.
    final asyncMod = ((func.isAsync && !spec.bridgeAsync(func)) || (!func.returnsFutureOr && (func.isAsync || func.inlineFuture))) ? 'async ' : '';

    writer.line('  @override');
    writer.line(
      '  $returnType ${func.dartMember(_paramList(func.params))} $asyncMod{',
    );
    final isFast = func.isFast;
    writer.line('    checkDisposed();');

    final rt = func.returnType.name;
    // Classify once — avoids repeated spec.structs.any() / spec.enums.any() calls.
    final returnKind = classifyReturn(func.returnType, spec);

    if (spec.bridgeAsync(func)) {
      _emitNativeAsyncBody(writer, func, spec, instancedCallArgs, needsArena);
    } else if (func.isAsync) {
      // plainCallArgs: used when no arena is needed. Apply the same optional-primitive
      // sentinel encoding as callArgs so that int?/bool?/double? are never passed as null.
      // (Structs, TypedData, String all require an arena so they can't appear here.)
      final plainCallArgs = func.params
          .map((p) {
            final t = p.type.name;
            final tBase = p.type.baseName;
            if (t == 'bool') return p.name; // Bool FFI type — pass directly
            if (t == 'DateTime') return '${p.name}.millisecondsSinceEpoch';
            // Nullable enum: TcStatus? → -1 for null, rawValue otherwise
            if (spec.isEnumName(tBase)) {
              return t.endsWith('?') ? '${p.name} == null ? -1 : ${p.name}.nativeValue' : '${p.name}.nativeValue';
            }
            if (p.type.isFunction) return _callbackArgExpr(func, p);
            if (p.type.isNativeHandle) return _nativeHandleArgExpr(p);
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
          _emitReturnDecode(
            writer,
            func.returnType,
            asyncResVar,
            '      ',
            spec,
            zeroCopy: func.zeroCopyReturn,
            dartName: func.dartName,
            isOwned: func.isOwned,
            nativeHandleTypeParam: nativeHandleTypeParam,
            asyncBoolAsInt: false,
          );
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
          _emitReturnDecode(
            writer,
            func.returnType,
            asyncResVar,
            '    ',
            spec,
            zeroCopy: func.zeroCopyReturn,
            dartName: func.dartName,
            isOwned: func.isOwned,
            nativeHandleTypeParam: nativeHandleTypeParam,
            asyncBoolAsInt: false,
          );
        }
      }
    } else if (func.isResult) {
      // ── @NitroResult sync path ────────────────────────────────────────────
      // C function returns Pointer<Uint8>: [1B tag: 0=ok, 1=err][record payload].
      // Errors are communicated through the tag, not the error slot.
      final syncArgs = '$instancedCallArgs, _nitroErr';
      _emitInstrumentedSync(writer, func.dartName, (indent) {
        if (needsArena) {
          writer.line('${indent}return withArena((arena) {');
          writer.line('$indent  final res = _${func.dartName}Ptr($syncArgs);');
          _emitResultDecode(writer, resultReturnType, 'res', '$indent  ', spec);
          writer.line('$indent});');
        } else {
          writer.line('${indent}final res = _${func.dartName}Ptr($syncArgs);');
          _emitResultDecode(writer, resultReturnType, 'res', indent, spec);
        }
      });
    } else {
      // ── Synchronous path — inline body between syncStart/syncEnd (no closure) ──
      // S8: append the pre-allocated error slot as the last argument so the C
      // bridge can write error info directly without a separate get_error() call.
      final syncArgs = '$instancedCallArgs, _nitroErr';
      final checkErr = "NitroRuntime.throwIfOutParamError(_nitroErr, nativeFree: _nitroFree, methodName: '${func.dartName}');";
      void emitCall(String indent) {
        if (rt == 'void') {
          writer.line('${indent}_${func.dartName}Ptr($syncArgs);');
          if (!isFast) writer.line('$indent$checkErr');
          return;
        }
        writer.line('${indent}final res = _${func.dartName}Ptr($syncArgs);');
        if (!isFast) writer.line('$indent$checkErr');
        _emitReturnDecode(
          writer,
          func.returnType,
          'res',
          indent,
          spec,
          zeroCopy: func.zeroCopyReturn,
          dartName: func.dartName,
          isOwned: func.isOwned,
          nativeHandleTypeParam: nativeHandleTypeParam,
          optIsBorrowed: true,
        );
      }
      if (needsArena) {
        // The arena lives inside the instrumented span so timing covers it.
        _emitInstrumentedSync(writer, func.dartName, (indent) {
          writer.line('$indent${rt == 'void' ? '' : 'return '}withArena((arena) {');
          emitCall('$indent  ');
          writer.line('$indent});');
        });
      } else if (isFast) {
        // ── Bare leaf body (#51) ── a `...Fast` method is the developer's
        // contract that this is a hot path: no error-slot check, and no
        // callSync closure either. The closure captured the arguments and
        // escaped into callSync, so AOT allocated it on every call — ~20x the
        // cost of the leaf FFI call it wrapped. checkDisposed() stays: one
        // field read, and it is what keeps a use-after-dispose from reaching
        // the native registry with a stale id. Diagnostics (verbose logging,
        // slow-call detection, timeline) are skipped for Fast methods.
        if (rt == 'void') {
          writer.line('    _${func.dartName}Ptr($syncArgs);');
        } else {
          writer.line('    final res = _${func.dartName}Ptr($syncArgs);');
          _emitReturnDecode(
            writer,
            func.returnType,
            'res',
            '    ',
            spec,
            zeroCopy: func.zeroCopyReturn,
            dartName: func.dartName,
            isOwned: func.isOwned,
            nativeHandleTypeParam: nativeHandleTypeParam,
            optIsBorrowed: true,
          );
        }
      } else {
        _emitInstrumentedSync(writer, func.dartName, emitCall);
      }
    }
    writer.line('  }');
    writer.blankLine();
  }
}

/// `final t0 = NitroRuntime.syncStart(name); try { body } finally { syncEnd }`
/// — the body runs inline (no closure capturing the arguments), and the
/// runtime keeps callSync's logging / timeline / slow-call semantics.
void _emitInstrumentedSync(CodeWriter writer, String name, void Function(String indent) body) {
  writer.line("    final t0 = NitroRuntime.syncStart('$name');");
  writer.line('    try {');
  body('      ');
  writer.line('    } finally {');
  writer.line("      NitroRuntime.syncEnd(t0, '$name');");
  writer.line('    }');
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

/// The FFI argument for a `NativeHandle<T>` parameter: the wrapped pointer,
/// widened to `Pointer<Void>` (the binding's type) when T is not `Void`; a
/// nullable handle passes `nullptr` for null. A plain `.pointer` read keeps
/// the call leaf-safe and allocation-free (GH #52).
String _nativeHandleArgExpr(BridgeParam p) {
  final tp = p.type.nativeHandleTypeParam ?? 'Void';
  final ptr = tp == 'Void' ? 'pointer' : 'pointer.cast<Void>()';
  return p.type.isNullable ? '${p.name}?.$ptr ?? nullptr' : '${p.name}.$ptr';
}
