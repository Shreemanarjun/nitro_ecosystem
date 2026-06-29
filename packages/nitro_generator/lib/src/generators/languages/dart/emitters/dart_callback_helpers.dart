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
  if (returnName != 'void' && returnName != 'int' && returnName != 'double' && returnName != 'bool' && returnName != 'String' && !spec.isEnumName(returnName)) {
    throw UnsupportedError(
      '${spec.dartClassName}.${func.dartName}() parameter "${param.name}" has callback return type "$returnName", which is not supported. Callback returns currently support void, int, double, bool, String, and @HybridEnum (and their nullable variants).',
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
  final name = type.name.replaceFirst('?', '');
  if (name == 'int' || name == 'double' || name == 'bool' || name == 'String') return true;
  if (spec.isEnumName(name)) return true;
  if (spec.isStructName(name)) return true;
  if (spec.isRecordName(name)) return true;
  if (spec.isVariantName(name)) return true;
  return false;
}

void _emitCallbackHelpers(CodeWriter writer, BridgeSpec spec) {
  writer.line('  // Native callback handles are cached so native code can retain');
  writer.line('  // callback pointers safely until this HybridObject is disposed.');
  writer.line('  // _callbackReleasePort receives callbackPtr int64 values when Kotlin');
  writer.line('  // calls _release_*, which closes the corresponding NativeCallable.');
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
      writer.line('    if (_nativeCallbackCache.containsKey(key)) {');
      writer.line('      return _nativeCallbackCache[key]! as NativeCallable<$nativeSig>;');
      writer.line('    }');
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
      writer.line('    _nativeCallbackCache[key] = nc;');
      writer.line('    final ptr = nc.nativeFunction.address;');
      writer.line('    _callbackPtrToKey[ptr] = key;');
      writer.line('    _registerCallbackReleasePtr(ptr, _callbackReleasePort.sendPort.nativePort);');
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
  if (returnName == 'int') return isNullableRet ? '-9223372036854775808' : '0';
  if (spec.isEnumName(returnName)) return isNullableRet ? '-1' : '0';
  // String returns Pointer<Utf8> — isolateLocal doesn't allow exceptionalReturn for Pointer types.
  if (returnName == 'String') return null;
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
  final paramsList = <String>[];
  for (final p in callbackType.functionParams) {
    final base = p.name.replaceFirst('?', '');
    final struct = spec.structs.where((s) => s.name == base).firstOrNull;
    if (struct != null && _isExpandableCallbackStruct(struct)) {
      paramsList.addAll(struct.fields.map((_) => 'Int64'));
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
  if (name == 'double') return 'Int64'; // raw bits, same GP-register path as int
  if (name == 'bool') return 'Int64'; // 0/1 via GP register
  if (name == 'String') return 'Pointer<Utf8>'; // strdup'd from native
  if (spec.isEnumName(name)) return 'Int64';
  return 'Void';
}

String _callbackParamToFFI(BridgeType type, BridgeSpec spec) {
  if (type.isPointer) return 'Pointer<${type.pointerInnerType ?? 'Void'}>';
  final name = type.name.replaceFirst('?', '');
  if (name == 'int') return 'Int64';
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
    } else {
      parts.add('${_callbackParamToDartFFI(type, spec)} arg$i');
    }
  }
  return parts.join(', ');
}

String _callbackParamToDartFFI(BridgeType type, BridgeSpec spec) {
  if (type.isPointer) return 'Pointer<${type.pointerInnerType ?? 'Void'}>';
  final name = type.name.replaceFirst('?', '');
  if (name == 'int') return 'int';
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
      // Nullable bool: -1 sentinel → null; 0/1 → bool.
      if (isNullable) {
        args.add('arg$i == -1 ? null : arg$i != 0');
      } else {
        args.add('arg$i != 0');
      }
    } else if (name == 'double') {
      // Nullable double: NaN bits sentinel (0x7FF8000000000000) → null.
      if (isNullable) {
        args.add('arg$i == 0x7FF8000000000000 ? null : Int64List.fromList([arg$i]).buffer.asFloat64List()[0]');
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
      args.add('arg$i.cast<${name}Ffi>().ref.toDart()');
    } else if (spec.isRecordName(name)) {
      args.add('(() { final _r = $name.fromNative(arg$i); malloc.free(arg$i); return _r; })()');
    } else if (spec.isVariantName(name)) {
      // @NitroVariant callback param: native passes Pointer<Uint8> = [4B len][tag][fields].
      // Dart decodes via VariantExt.fromNative and frees the allocation.
      if (isNullable) {
        args.add('arg$i == nullptr ? null : (() { final _v = ${name}VariantExt.fromNative(arg$i); malloc.free(arg$i); return _v; })()');
      } else {
        args.add('(() { final _v = ${name}VariantExt.fromNative(arg$i); malloc.free(arg$i); return _v; })()');
      }
    } else if (name == 'int' && isNullable) {
      // Nullable int: Int64.min sentinel → null.
      args.add('arg$i == -9223372036854775808 ? null : arg$i');
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
  // String → strdup'd pointer; native will call free() on it
  if (returnName == 'String') {
    if (isNullableRet) {
      return '(() { final _value = $invocation; return _value == null ? nullptr : _value.toNativeUtf8(); })()';
    }
    return '$invocation.toNativeUtf8()';
  }
  // Nullable enum: null → -1 sentinel.
  if (spec.isEnumName(returnName)) {
    if (isNullableRet) {
      return '(() { final _v = $invocation; return _v == null ? -1 : _v.nativeValue; })()';
    }
    return '$invocation.nativeValue';
  }
  // Nullable int: null → Int64.min sentinel.
  if (returnName == 'int' && isNullableRet) {
    return '($invocation) ?? -9223372036854775808';
  }
  return invocation;
}
