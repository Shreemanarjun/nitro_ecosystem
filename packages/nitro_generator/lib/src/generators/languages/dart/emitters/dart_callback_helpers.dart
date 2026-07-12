part of '../dart_ffi_generator.dart';

bool _hasFunctionTypeParams(BridgeSpec spec) {
  return spec.functions.any((f) => f.params.any((p) => p.type.isFunction));
}

void _assertSupportedFunctionTypes(BridgeSpec spec) {
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

void _assertSupportedCallbackType(
  BridgeSpec spec,
  BridgeFunction func,
  BridgeParam param,
) {
  final callback = param.type;
  final returnName = (callback.functionReturnType ?? 'void').replaceFirst('?', '');
  // Nullable primitive returns use sentinel encoding; all types below are supported.
  if (returnName != 'void' &&
      returnName != 'int' &&
      returnName != 'uint64' &&
      returnName != 'double' &&
      returnName != 'bool' &&
      returnName != 'String' &&
      returnName != 'DateTime' &&
      returnName != 'AnyNativeObject' &&
      !spec.isEnumName(returnName) &&
      !spec.isRecordName(returnName) &&
      !spec.isVariantName(returnName)) {
    throw UnsupportedError(
      '${spec.dartClassName}.${func.dartName}() parameter "${param.name}" has callback return type "$returnName", which is not supported. Callback returns currently support void, int, double, bool, String, AnyNativeObject, @HybridEnum, @HybridRecord, and @NitroVariant (and their nullable variants).',
    );
  }
  for (final callbackParam in callback.functionParams) {
    if (!_isSupportedCallbackParam(callbackParam, spec)) {
      throw UnsupportedError(
        '${spec.dartClassName}.${func.dartName}() parameter "${param.name}" has callback parameter type "${callbackParam.name}", which is not supported. Callback parameters currently support int, double, bool, String, Pointer<T>, and @HybridEnum (and their nullable variants).',
      );
    }
  }
}

bool _isSupportedCallbackParam(BridgeType type, BridgeSpec spec) {
  if (type.isPointer) return true;
  if (type.isAnyNativeObject) return true;
  final name = type.name.replaceFirst('?', '');
  if (name == 'int' || name == 'uint64' || name == 'double' || name == 'bool' || name == 'String' || name == 'DateTime' || name == 'AnyNativeObject') return true;
  if (spec.isEnumName(name)) return true;
  if (spec.isStructName(name)) return true;
  if (spec.isRecordName(name)) return true;
  if (spec.isVariantName(name)) return true;
  return false;
}

void _emitCallbackHelpers(CodeWriter writer, BridgeSpec spec) {
  writer.line('  // Each callback-typed parameter has exactly one active NativeCallable');
  writer.line('  // slot, keyed by "methodName.paramName". Re-registering (calling the');
  writer.line('  // setter again with a fresh closure) replaces the slot and schedules');
  writer.line('  // the previous NativeCallable to close on the next microtask, once');
  writer.line('  // native has synchronously switched over to the new function pointer.');
  for (final func in spec.functions) {
    for (final param in func.params.where((p) => p.type.isFunction)) {
      final helperName = _callbackHelperName(func, param);
      final dartType = _callbackDartType(param.type, spec, nullable: false);
      final nativeSig = _callbackNativeSignature(param.type, spec);
      final callbackFactory = _callbackFactory(param.type);
      final exceptionalReturn = _callbackExceptionalReturn(param.type, spec);
      final exceptionalArg = exceptionalReturn == null ? '' : ', exceptionalReturn: $exceptionalReturn';
      writer.line('  NativeCallable<$nativeSig> $helperName($dartType callback) {');
      writer.line("    const key = '${func.dartName}.${param.name}';");
      writer.line('    final nc = NativeCallable<$nativeSig>.$callbackFactory((${_callbackWrapperParams(param.type, spec)}) {');
      final invocationArgs = _callbackInvocationArgs(param.type, spec);
      final callbackInvocation = 'callback($invocationArgs)';
      final returnExpr = _callbackReturnExpression(param.type, spec, callbackInvocation);
      if (returnExpr == null) {
        writer.line('      $callbackInvocation;');
      } else {
        writer.line('      return $returnExpr;');
      }
      writer.line('    }$exceptionalArg);');
      writer.line('    final old = _nativeCallbackCache[key];');
      writer.line('    _nativeCallbackCache[key] = nc;');
      writer.line('    NitroRuntime.deferredClose(old);');
      writer.line('    return nc;');
      writer.line('  }');
      writer.blankLine();
    }
  }
}

String _callbackFactory(BridgeType callbackType) {
  final returnName = (callbackType.functionReturnType ?? 'void').replaceFirst('?', '');
  return returnName == 'void' ? 'listener' : 'isolateLocal';
}

String? _callbackExceptionalReturn(BridgeType callbackType, BridgeSpec spec) {
  final rawRet = callbackType.functionReturnType ?? 'void';
  final isNullableRet = rawRet.endsWith('?');
  final returnName = rawRet.replaceFirst('?', '');
  if (returnName == 'void') return null;
  // Nullable returns use sentinel values for the exceptional return.
  if (returnName == 'double') return isNullableRet ? '0x7FF8000000000000' : '0';
  if (returnName == 'bool') return isNullableRet ? '-1' : '0';
  if (returnName == 'AnyNativeObject') return isNullableRet ? '-1' : '0';
  if (returnName == 'int') return isNullableRet ? '-9223372036854775808' : '0';
  if (returnName == 'uint64') return isNullableRet ? '-9223372036854775808' : '0';
  if (returnName == 'DateTime') return isNullableRet ? '-9223372036854775808' : '0';
  if (spec.isEnumName(returnName)) return isNullableRet ? '-1' : '0';
  // String returns Pointer<Utf8> — isolateLocal doesn't allow exceptionalReturn for Pointer types.
  if (returnName == 'String') return null;
  // @HybridRecord / @NitroVariant return Pointer<Uint8> — nullptr is the default exceptional return.
  if (spec.isRecordName(returnName)) return null;
  if (spec.isVariantName(returnName)) return null;
  return null;
}

String _callbackArgExpr(BridgeFunction func, BridgeParam param) {
  final helper = _callbackHelperName(func, param);
  final nullable = param.type.isNullable || param.type.name.endsWith('?');
  if (nullable) {
    return '${param.name} == null ? nullptr : $helper(${param.name}!).nativeFunction';
  }
  return '$helper(${param.name}).nativeFunction';
}

String _callbackHelperName(BridgeFunction func, BridgeParam param) {
  return '_nativeCallback${_cap(func.dartName)}${_cap(param.name)}';
}

String _callbackNativeSignature(BridgeType callbackType, BridgeSpec spec) {
  final ret = _callbackReturnToFFI(callbackType.functionReturnType ?? 'void', spec);
  // Expandable structs become multiple Int64 params (one per field) for synchronous NativeCallable.
  // Nullable int/double/bool expand to TWO Int64 params: (isNull, valueBits) to avoid sentinels.
  final paramsList = <String>[];
  for (final p in callbackType.functionParams) {
    final base = p.name.replaceFirst('?', '');
    final struct = spec.structs.where((s) => s.name == base).firstOrNull;
    if (struct != null && _isExpandableCallbackStruct(struct)) {
      paramsList.addAll(struct.fields.map((_) => 'Int64'));
    } else if (p.isNullableNitroPrim) {
      paramsList.add('Int64'); // isNull: 0 = has value, non-zero = null
      paramsList.add('Int64'); // value bits (valid when isNull == 0)
    } else {
      paramsList.add(_callbackParamToFFI(p, spec));
    }
  }
  return '$ret Function(${paramsList.join(', ')})';
}

/// Returns true when a struct's fields are all numeric and can be
/// expanded to individual Int64 params for synchronous NativeCallable.listener.
bool _isExpandableCallbackStruct(BridgeStruct st) {
  const numeric = {'int', 'double', 'bool'};
  return st.fields.isNotEmpty && st.fields.every((f) => numeric.contains(f.type.name.replaceFirst('?', '')) && !f.type.isTypedData);
}

String _callbackDartType(BridgeType callbackType, BridgeSpec spec, {required bool nullable}) {
  final ret = callbackType.functionReturnType ?? 'void';
  final params = callbackType.functionParams.map((p) => p.name).join(', ');
  final suffix = nullable ? '?' : '';
  return '$ret Function($params)$suffix';
}

String _callbackReturnToFFI(String dartType, BridgeSpec spec) {
  final name = dartType.replaceFirst('?', '');
  if (name == 'void') return 'Void';
  if (name == 'int') return 'Int64';
  if (name == 'uint64') return 'Int64'; // same GP register width; Dart int holds bits
  if (name == 'DateTime') return 'Int64';
  if (name == 'double') return 'Int64'; // raw bits, same GP-register path as int
  if (name == 'bool') return 'Int64'; // 0/1 via GP register
  if (name == 'String') return 'Pointer<Utf8>'; // strdup'd from native
  if (name == 'AnyNativeObject') return 'Int64'; // raw instanceId, -1 for null
  if (spec.isEnumName(name)) return 'Int64';
  // @HybridRecord / @NitroVariant: Dart encodes to malloc'd [4B len][payload] buffer.
  if (spec.isRecordName(name)) return 'Pointer<Uint8>';
  if (spec.isVariantName(name)) return 'Pointer<Uint8>';
  return 'Void';
}

String _callbackParamToFFI(BridgeType type, BridgeSpec spec) {
  if (type.isPointer) return 'Pointer<${type.pointerInnerType ?? 'Void'}>';
  if (type.isAnyNativeObject) return 'Int64'; // raw instanceId, -1 null sentinel for nullable
  final name = type.name.replaceFirst('?', '');
  if (name == 'AnyNativeObject') return 'Int64';
  if (name == 'int') return 'Int64';
  if (name == 'uint64') return 'Int64'; // same GP register; bits preserved
  if (name == 'DateTime') return 'Int64';
  // bool and double are routed through Int64 on Android to ensure NativeCallable.listener
  // fires synchronously (only Int64/Long has the synchronous fast-path on Android).
  // The C JNI invoker encodes bool as 1L/0L and double as raw IEEE 754 bits.
  if (name == 'double') return 'Int64';
  if (name == 'bool') return 'Int64';
  if (name == 'String') return 'Pointer<Utf8>';
  if (spec.isEnumName(name)) return 'Int64';
  if (spec.isStructName(name)) return 'Pointer<Void>';
  if (spec.isRecordName(name)) return 'Pointer<Uint8>';
  if (spec.isVariantName(name)) return 'Pointer<Uint8>';
  return 'Pointer<Void>';
}

String _callbackWrapperParams(BridgeType callbackType, BridgeSpec spec) {
  final parts = <String>[];
  for (var i = 0; i < callbackType.functionParams.length; i++) {
    final type = callbackType.functionParams[i];
    final base = type.name.replaceFirst('?', '');
    final struct = spec.structs.where((s) => s.name == base).firstOrNull;
    if (struct != null && _isExpandableCallbackStruct(struct)) {
      // Use camelCase names (arg0X not arg0_x) to satisfy Dart lint.
      for (final f in struct.fields) {
        parts.add('int arg$i${_cap(f.name)}');
      }
    } else if (type.isNullableNitroPrim) {
      parts.add('int arg${i}Null'); // 0 = has value, non-zero = null
      parts.add('int arg${i}Val'); // value bits (valid when arg${i}Null == 0)
    } else {
      parts.add('${_callbackParamToDartFFI(type, spec)} arg$i');
    }
  }
  return parts.join(', ');
}

String _callbackParamToDartFFI(BridgeType type, BridgeSpec spec) {
  if (type.isPointer) return 'Pointer<${type.pointerInnerType ?? 'Void'}>';
  final name = type.name.replaceFirst('?', '');
  if (name == 'AnyNativeObject') return 'int'; // instanceId as Int64
  if (name == 'int') return 'int';
  if (name == 'uint64') return 'int'; // same GP register; bits preserved
  if (name == 'DateTime') return 'int';
  if (name == 'double') return 'int'; // received as Int64 (IEEE 754 bits)
  if (name == 'bool') return 'int'; // received as Int64 (1 = true, 0 = false)
  if (name == 'String') return 'Pointer<Utf8>';
  if (spec.isEnumName(name)) return 'int';
  if (spec.isStructName(name)) return 'Pointer<Void>';
  if (spec.isRecordName(name)) return 'Pointer<Uint8>';
  if (spec.isVariantName(name)) return 'Pointer<Uint8>';
  return 'Pointer<Void>';
}

String _callbackInvocationArgs(BridgeType callbackType, BridgeSpec spec) {
  final args = <String>[];
  for (var i = 0; i < callbackType.functionParams.length; i++) {
    final type = callbackType.functionParams[i];
    final isNullable = type.name.endsWith('?');
    final name = type.name.replaceFirst('?', '');
    final struct = spec.structs.where((s) => s.name == name).firstOrNull;
    if (struct != null && _isExpandableCallbackStruct(struct)) {
      // Reconstruct struct from individual Int64 field args (synchronous path).
      final fieldExprs = struct.fields
          .map((f) {
            final fBase = f.type.name.replaceFirst('?', '');
            final argName = 'arg$i${_cap(f.name)}'; // camelCase: arg0X, arg0Y, arg0Z
            if (fBase == 'double') {
              return '${f.name}: Int64List.fromList([$argName]).buffer.asFloat64List()[0]';
            } else if (fBase == 'bool') {
              return '${f.name}: $argName != 0';
            } else {
              return '${f.name}: $argName';
            }
          })
          .join(', ');
      args.add('$name($fieldExprs)');
    } else if (name == 'bool') {
      // Nullable bool: two-param (arg${i}Null, arg${i}Val) → null or bool.
      if (isNullable) {
        args.add('arg${i}Null != 0 ? null : arg${i}Val != 0');
      } else {
        args.add('arg$i != 0');
      }
    } else if (name == 'double') {
      // Nullable double: two-param (arg${i}Null, arg${i}Val bits) → null or double.
      if (isNullable) {
        args.add('arg${i}Null != 0 ? null : Int64List.fromList([arg${i}Val]).buffer.asFloat64List()[0]');
      } else {
        args.add('Int64List.fromList([arg$i]).buffer.asFloat64List()[0]');
      }
    } else if (name == 'String') {
      // Nullable String: nullptr → null.
      if (isNullable) {
        args.add('arg$i == nullptr ? null : arg$i.toDartString()');
      } else {
        args.add('arg$i.toDartString()');
      }
    } else if (spec.isEnumName(name)) {
      // Nullable enum: -1 sentinel → null.
      if (isNullable) {
        args.add('arg$i == -1 ? null : arg$i.to$name()');
      } else {
        args.add('arg$i.to$name()');
      }
    } else if (spec.isStructName(name)) {
      if (isNullable) {
        args.add('arg$i == nullptr ? null : arg$i.cast<${name}Ffi>().ref.toDart()');
      } else {
        args.add('arg$i.cast<${name}Ffi>().ref.toDart()');
      }
    } else if (spec.isRecordName(name)) {
      if (isNullable) {
        args.add('arg$i == nullptr ? null : (() { final _r = $name.fromNative(arg$i); _nitroFree(arg$i); return _r; })()');
      } else {
        args.add('(() { final _r = $name.fromNative(arg$i); _nitroFree(arg$i); return _r; })()');
      }
    } else if (spec.isVariantName(name)) {
      // @NitroVariant callback param: native passes Pointer<Uint8> = [4B len][tag][fields].
      // Dart decodes via VariantExt.fromNative and frees the allocation.
      if (isNullable) {
        args.add('arg$i == nullptr ? null : (() { final _v = ${name}VariantExt.fromNative(arg$i); _nitroFree(arg$i); return _v; })()');
      } else {
        args.add('(() { final _v = ${name}VariantExt.fromNative(arg$i); _nitroFree(arg$i); return _v; })()');
      }
    } else if (type.isAnyNativeObject || name == 'AnyNativeObject') {
      // AnyNativeObject: single Int64 param; -1 is the null sentinel for nullable.
      if (isNullable) {
        args.add('arg$i == -1 ? null : AnyNativeObject(arg$i)');
      } else {
        args.add('AnyNativeObject(arg$i)');
      }
    } else if (name == 'int' && isNullable) {
      // Nullable int: two-param (arg${i}Null, arg${i}Val) → null or int value.
      args.add('arg${i}Null != 0 ? null : arg${i}Val');
    } else if (name == 'uint64') {
      // uint64: Dart int holds raw bits; same GP register path as int.
      // Nullable uint64: two-param (isNull, valueBits).
      if (isNullable) {
        args.add('arg${i}Null != 0 ? null : arg${i}Val');
      } else {
        args.add('arg$i');
      }
    } else if (name == 'DateTime') {
      if (isNullable) {
        args.add('arg${i}Null != 0 ? null : DateTime.fromMillisecondsSinceEpoch(arg${i}Val)');
      } else {
        args.add('DateTime.fromMillisecondsSinceEpoch(arg$i)');
      }
    } else {
      args.add('arg$i');
    }
  }
  return args.join(', ');
}

String? _callbackReturnExpression(BridgeType callbackType, BridgeSpec spec, String invocation) {
  final rawRet = callbackType.functionReturnType ?? 'void';
  final isNullableRet = rawRet.endsWith('?');
  final returnName = rawRet.replaceFirst('?', '');
  if (returnName == 'void') return null;
  // double → raw IEEE 754 bits as Int64 (GP register, NativeCallable sync path)
  // Nullable double: null → NaN bits sentinel (0x7FF8000000000000).
  if (returnName == 'double') {
    if (isNullableRet) {
      return '(() { final _v = $invocation; return _v == null ? 0x7FF8000000000000 : Float64List.fromList([_v]).buffer.asInt64List()[0]; })()';
    }
    return 'Float64List.fromList([$invocation]).buffer.asInt64List()[0]';
  }
  // Nullable bool: null → -1 sentinel.
  if (returnName == 'bool') {
    if (isNullableRet) {
      return '(() { final _v = $invocation; return _v == null ? -1 : (_v ? 1 : 0); })()';
    }
    return '$invocation ? 1 : 0';
  }
  // String return: the native wrapper copies it and releases it with the
  // C-runtime free(), so it must be produced by the module's C-runtime
  // malloc (_nitroNativeAllocator over <lib>_nitro_alloc). package:ffi's
  // default allocator is CoTaskMemAlloc on Windows — freeing that pointer
  // with free() corrupted the heap and froze the app on the first
  // String-returning callback.
  if (returnName == 'String') {
    if (isNullableRet) {
      return '(() { final _value = $invocation; return _value == null ? nullptr : _value.toNativeUtf8(allocator: _nitroNativeAllocator); })()';
    }
    return '$invocation.toNativeUtf8(allocator: _nitroNativeAllocator)';
  }
  // Nullable enum: null → -1 sentinel.
  if (spec.isEnumName(returnName)) {
    if (isNullableRet) {
      return '(() { final _v = $invocation; return _v == null ? -1 : _v.nativeValue; })()';
    }
    return '$invocation.nativeValue';
  }
  // AnyNativeObject: return raw instanceId; nullable uses -1 sentinel.
  if (returnName == 'AnyNativeObject') {
    if (isNullableRet) {
      return '(() { final _v = $invocation; return _v == null ? -1 : _v.instanceId; })()';
    }
    return '$invocation.instanceId';
  }
  // Nullable int: null → Int64.min sentinel.
  if (returnName == 'int' && isNullableRet) {
    return '($invocation) ?? -9223372036854775808';
  }
  // uint64: Dart int holds raw bits; same GP-register path as int.
  // Nullable uint64: null → Int64.min sentinel (same bit pattern as int?).
  if (returnName == 'uint64' && isNullableRet) {
    return '($invocation) ?? -9223372036854775808';
  }
  // DateTime / DateTime?: encode to ms-since-epoch Int64.
  if (returnName == 'DateTime') {
    if (isNullableRet) {
      return '(() { final _v = $invocation; return _v == null ? -9223372036854775808 : _v.millisecondsSinceEpoch; })()';
    }
    return '$invocation.millisecondsSinceEpoch';
  }
  // @HybridRecord return: encoded to a [4B len][payload] block the native
  // wrapper frees with C-runtime free() — allocate with the module's own
  // allocator, never package:ffi's (CoTaskMemAlloc on Windows).
  if (spec.isRecordName(returnName)) {
    if (isNullableRet) {
      return '(() { final _v = $invocation; return _v == null ? nullptr : _v.toNative(_nitroNativeAllocator); })()';
    }
    return '$invocation.toNative(_nitroNativeAllocator)';
  }
  // @NitroVariant return: same wire format and allocator rule as record.
  if (spec.isVariantName(returnName)) {
    if (isNullableRet) {
      return '(() { final _v = $invocation; return _v == null ? nullptr : _v.toNative(_nitroNativeAllocator); })()';
    }
    return '$invocation.toNative(_nitroNativeAllocator)';
  }
  return invocation;
}
