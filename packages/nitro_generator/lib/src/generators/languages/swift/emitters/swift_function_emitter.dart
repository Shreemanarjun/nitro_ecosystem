import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'swift_type_mapper.dart';

/// Emits a `@_cdecl` stub for a single [BridgeFunction].
///
/// Handles all dispatch paths:
///   - `@NitroNativeAsync` — Task + Dart_PostCObject_DL
///   - `@nitroAsync` — DispatchSemaphore + Task.detached
///   - sync — direct `Registry.impl?.method(…)` call
class SwiftFunctionEmitter {
  static void emit(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    SwiftTypeMapper mapper,
  ) {
    if (func.lineNumber != null) {
      writer.line('// source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
    }

    final cRetType = mapper.cdeclReturnType(func);

    final params = func.params
        .expand((p) {
          if (p.type.isFunction) {
            return ['_ ${p.name}: ${mapper.cdeclCallbackType(p.type)}'];
          }
          final t = mapper.cdeclParamType(p.type.name, bridgeType: p.type);
          if (p.type.isTypedData) {
            return ['_ ${p.name}: $t', '_ ${p.name}_length: Int64'];
          }
          return ['_ ${p.name}: $t'];
        })
        .join(', ');

    final stringParams = func.params.where((p) => p.type.name == 'String' || p.type.name == 'String?').toList();
    final typedListParams = func.params.where((p) => p.type.isTypedData).toList();
    final recordListParams = func.params.where((p) => p.type.isRecord && p.type.name.startsWith('List<')).toList();

    final callArgs = _buildCallArgs(func, spec, mapper);

    final isStruct = spec.isStructName(func.returnType.name.replaceFirst('?', ''));
    final isRecord = spec.isRecordName(func.returnType.name.replaceFirst('?', ''));
    final isMap = func.returnType.isMap;
    final isRecordList = func.returnType.name.startsWith('List<');
    final isBool = mapper.cdeclReturnType(func) == 'Int8';
    final isVoid = func.returnType.name == 'void';
    final isString = func.returnType.name.replaceFirst('?', '') == 'String';
    final isTypedDataReturn = func.returnType.isTypedData;
    final isEnumRet = spec.isEnumName(func.returnType.name.replaceFirst('?', ''));

    if (func.isNativeAsync) {
      _emitNativeAsync(writer, func, spec, params, stringParams, typedListParams, isVoid: func.returnType.name == 'void');
      return;
    }

    final isVariantRet = spec.isVariantName(func.returnType.name.replaceFirst('?', ''));

    writer.line('@_cdecl("_${spec.namespace}_call_${func.dartName}")');
    writer.line('public func _${spec.namespace}_call_${func.dartName}($params) -> $cRetType {');

    _emitParamConversions(writer, stringParams, typedListParams, recordListParams, func);

    if (func.isAsync) {
      _emitAsync(
        writer,
        func,
        spec,
        callArgs,
        mapper,
        isStruct: isStruct,
        isRecord: isRecord,
        isRecordList: isRecordList,
        isBool: isBool,
        isVoid: isVoid,
        isString: isString,
        isTypedDataReturn: isTypedDataReturn,
        isEnumRet: isEnumRet,
        isMap: isMap,
      );
    } else {
      _emitSync(
        writer,
        func,
        spec,
        callArgs,
        mapper,
        isStruct: isStruct,
        isRecord: isRecord,
        isRecordList: isRecordList,
        isBool: isBool,
        isVoid: isVoid,
        isString: isString,
        isTypedDataReturn: isTypedDataReturn,
        isEnumRet: isEnumRet,
        isMap: isMap,
        isVariantRet: isVariantRet,
      );
    }

    writer.line('}');
    writer.blankLine();
  }

  // ── param call-arg mapping ─────────────────────────────────────────────────

  static String _buildCallArgs(BridgeFunction func, BridgeSpec spec, SwiftTypeMapper mapper) {
    return func.params
        .map((p) {
          final isStr = p.type.name == 'String' || p.type.name == 'String?';
          final isBool = p.type.name == 'bool' || p.type.name == 'bool?';
          if (isStr) return '${p.name}: ${p.name}Str';
          if (p.type.name == 'int?') return '${p.name}: NitroNullableInt.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self)).nullable';
          if (p.type.name == 'double?') return '${p.name}: NitroNullableDouble.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self)).nullable';
          if (p.type.name == 'bool?') return '${p.name}: NitroNullableBool.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self)).nullable';
          if (isBool) return '${p.name}: ${p.name} != 0';
          if (p.type.isTypedData) return '${p.name}: ${p.name}Arr';
          if (p.type.isRecord && p.type.name.startsWith('List<')) return '${p.name}: ${p.name}Decoded';
          if (p.type.isFunction) return '${p.name}: ${mapper.callbackWrapper(p)}';
          if (spec.isStructName(p.type.name.replaceFirst('?', ''))) {
            final sn = p.type.name.replaceFirst('?', '');
            final opt = p.type.name.endsWith('?');
            return opt ? '${p.name}: ${p.name}.map { \$0.assumingMemoryBound(to: _${sn}C.self).pointee.toSwift() }' : '${p.name}: ${p.name}!.assumingMemoryBound(to: _${sn}C.self).pointee.toSwift()';
          }
          if (spec.isRecordName(p.type.name.replaceFirst('?', ''))) {
            final rn = p.type.name.replaceFirst('?', '');
            final opt = p.type.name.endsWith('?') || p.type.isNullable;
            return opt ? '${p.name}: ${p.name}.map { $rn.fromNative(\$0.assumingMemoryBound(to: UInt8.self)) }' : '${p.name}: $rn.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self))';
          }
          if (spec.isVariantName(p.type.name.replaceFirst('?', ''))) {
            // @NitroVariant param: decode from [4B len][1B tag][fields] buffer.
            // NitroRecordReader skips the 4-byte prefix internally.
            final vn = p.type.name.replaceFirst('?', '');
            return '${p.name}: ${vn}.fromReader(NitroRecordReader(ptr: ${p.name}!.assumingMemoryBound(to: UInt8.self)))';
          }
          final isEnum = spec.isEnumName(p.type.name.replaceFirst('?', ''));
          if (isEnum) {
            final en = p.type.name.replaceFirst('?', '');
            final opt = p.type.name.endsWith('?');
            return opt ? '${p.name}: $en(rawValue: ${p.name})' : '${p.name}: $en(rawValue: ${p.name})!';
          }
          return '${p.name}: ${p.name}';
        })
        .join(', ');
  }

  // ── param conversions (top of func body) ─────────────────────────────────

  static void _emitParamConversions(
    CodeWriter writer,
    List<BridgeParam> stringParams,
    List<BridgeParam> typedListParams,
    List<BridgeParam> recordListParams,
    BridgeFunction func,
  ) {
    for (final p in stringParams) {
      writer.line('    let ${p.name}Str = ${p.name} != nil ? String(cString: ${p.name}!) : ""');
    }
    for (final p in typedListParams) {
      final isData = p.type.name.startsWith('Uint8List') || p.type.name.startsWith('Int8List');
      if (isData) {
        writer.line('    let ${p.name}Arr = ${p.name}.map { Data(bytes: \$0, count: Int(${p.name}_length)) } ?? Data()');
      } else {
        writer.line('    let ${p.name}Arr = ${p.name}.map { Array(UnsafeBufferPointer(start: \$0, count: Int(${p.name}_length))) } ?? []');
      }
    }
    for (final p in recordListParams) {
      final itemType = p.type.name.substring(5, p.type.name.length - 1);
      final isPrim = ['int', 'double', 'bool', 'String'].contains(itemType.replaceAll('?', ''));
      writer.line('    let ${p.name}Ptr = ${p.name}?.assumingMemoryBound(to: UInt8.self)');
      if (isPrim) {
        final base = itemType.replaceAll('?', '');
        final readCall = switch (base) {
          'double' => 'r.readDouble()',
          'bool' => 'r.readBool()',
          'String' => 'r.readString()',
          _ => 'r.readInt()',
        };
        writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeIndexedList(\$0) { r in $readCall } } ?? []');
      } else {
        writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeIndexedList(\$0) { r in $itemType.fromReader(r) } } ?? []');
      }
    }
  }

  // ── @NitroNativeAsync ─────────────────────────────────────────────────────

  static void _emitNativeAsync(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    String params,
    List<BridgeParam> stringParams,
    List<BridgeParam> typedListParams, {
    required bool isVoid,
  }) {
    writer.line('@_cdecl("_${spec.namespace}_call_${func.dartName}")');
    writer.line('public func _${spec.namespace}_call_${func.dartName}($params${params.isNotEmpty ? ", " : ""}_ dartPort: Int64) {');
    for (final p in stringParams) {
      if (p.type.name == 'String?') {
        writer.line('    let ${p.name}Str = ${p.name}.map { String(cString: \$0) }');
      } else {
        writer.line('    let ${p.name}Str = ${p.name} != nil ? String(cString: ${p.name}!) : ""');
      }
    }
    for (final p in typedListParams) {
      final isData = p.type.name.startsWith('Uint8List') || p.type.name.startsWith('Int8List');
      if (isData) {
        writer.line('    let ${p.name}Arr = ${p.name}.map { Data(bytes: \$0, count: Int(${p.name}_length)) } ?? Data()');
      } else {
        writer.line('    let ${p.name}Arr = ${p.name}.map { Array(UnsafeBufferPointer(start: \$0, count: Int(${p.name}_length))) } ?? []');
      }
    }
    // Build call args for native async (no struct/record conversions — not supported)
    final callArgs = func.params
        .map((p) {
          final isStr = p.type.name == 'String' || p.type.name == 'String?';
          final isBool = p.type.name == 'bool' || p.type.name == 'bool?';
          final isEnum = spec.isEnumName(p.type.name.replaceFirst('?', ''));
          if (isStr) return '${p.name}: ${p.name}Str';
          if (p.type.name == 'int?') return '${p.name}: NitroNullableInt.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self)).nullable';
          if (p.type.name == 'double?') return '${p.name}: NitroNullableDouble.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self)).nullable';
          if (p.type.name == 'bool?') return '${p.name}: NitroNullableBool.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self)).nullable';
          if (isBool) return '${p.name}: ${p.name} != 0';
          if (isEnum) {
            final en = p.type.name.replaceFirst('?', '');
            final opt = p.type.name.endsWith('?');
            return opt ? '${p.name}: $en(rawValue: ${p.name})' : '${p.name}: $en(rawValue: ${p.name})!';
          }
          return '${p.name}: ${p.name}';
        })
        .join(', ');

    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else {');
    writer.line('        var _null = Dart_CObject()');
    writer.line('        _null.type = Dart_CObject_kNull');
    writer.line('        Dart_PostCObject_DL(dartPort, &_null)');
    writer.line('        return');
    writer.line('    }');
    writer.line('    Task.detached {');

    final retName = func.returnType.name;
    final retBaseName = retName.replaceFirst('?', '');
    final isNullableRet = func.returnType.isNullable || retName.endsWith('?');
    if (isVoid) {
      writer.line('        try? await impl.${func.dartName}($callArgs)');
      writer.line('        var _null = Dart_CObject()');
      writer.line('        _null.type = Dart_CObject_kNull');
      writer.line('        Dart_PostCObject_DL(dartPort, &_null)');
    } else if (retName == 'String') {
      writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? ""');
      writer.line('        _result.withCString { cStr in');
      writer.line('            var _obj = Dart_CObject()');
      writer.line('            _obj.type = Dart_CObject_kString');
      writer.line('            _obj.value.as_string = cStr');
      writer.line('            Dart_PostCObject_DL(dartPort, &_obj)');
      writer.line('        }');
    } else if (retName == 'String?') {
      writer.line('        let _result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        guard let _value = _result ?? nil else {');
      writer.line('            var _null = Dart_CObject()');
      writer.line('            _null.type = Dart_CObject_kNull');
      writer.line('            Dart_PostCObject_DL(dartPort, &_null)');
      writer.line('            return');
      writer.line('        }');
      writer.line('        _value.withCString { cStr in');
      writer.line('            var _obj = Dart_CObject()');
      writer.line('            _obj.type = Dart_CObject_kString');
      writer.line('            _obj.value.as_string = cStr');
      writer.line('            Dart_PostCObject_DL(dartPort, &_obj)');
      writer.line('        }');
    } else if (retName == 'bool') {
      writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? false');
      writer.line('        var _obj = Dart_CObject()');
      writer.line('        _obj.type = Dart_CObject_kBool');
      writer.line('        _obj.value.as_bool = _result');
      writer.line('        Dart_PostCObject_DL(dartPort, &_obj)');
    } else if (retName == 'bool?') {
      writer.line('        let _result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        guard let _value = _result ?? nil else {');
      writer.line('            var _null = Dart_CObject()');
      writer.line('            _null.type = Dart_CObject_kNull');
      writer.line('            Dart_PostCObject_DL(dartPort, &_null)');
      writer.line('            return');
      writer.line('        }');
      writer.line('        var _obj = Dart_CObject()');
      writer.line('        _obj.type = Dart_CObject_kBool');
      writer.line('        _obj.value.as_bool = _value');
      writer.line('        Dart_PostCObject_DL(dartPort, &_obj)');
    } else {
      final isDouble = retName == 'double';
      final isNullDbl = retName == 'double?';
      final isNullInt = retName == 'int?';
      final isEnum = spec.isEnumName(retBaseName);
      if (isDouble) {
        writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? 0.0');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kDouble');
        writer.line('        _obj.value.as_double = _result');
      } else if (isNullDbl) {
        writer.line('        let _result = ((try? await impl.${func.dartName}($callArgs)) ?? nil) ?? Double.nan');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kDouble');
        writer.line('        _obj.value.as_double = _result');
      } else if (isNullInt) {
        writer.line('        let _result = ((try? await impl.${func.dartName}($callArgs)) ?? nil) ?? Int64.min');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _result');
      } else if (isEnum) {
        if (isNullableRet) {
          writer.line('        let _result = (try? await impl.${func.dartName}($callArgs))?.rawValue ?? -1');
        } else {
          writer.line('        let _result = (try? await impl.${func.dartName}($callArgs))?.rawValue ?? 0');
        }
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = Int64(_result)');
      } else {
        writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? 0');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = Int64(_result)');
      }
      writer.line('        Dart_PostCObject_DL(dartPort, &_obj)');
    }

    writer.line('    }');
    writer.line('}');
    writer.blankLine();
  }

  // ── async (DispatchSemaphore) ─────────────────────────────────────────────

  static void _emitAsync(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    String callArgs,
    SwiftTypeMapper mapper, {
    required bool isStruct,
    required bool isRecord,
    required bool isRecordList,
    required bool isBool,
    required bool isVoid,
    required bool isString,
    required bool isTypedDataReturn,
    required bool isEnumRet,
    required bool isMap,
  }) {
    if (isStruct) {
      final retStructName = func.returnType.name.replaceFirst('?', '');
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result: ${func.returnType.name}? = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      writer.line('    sema.wait()');
      writer.line('    guard let r = result else { return nil }');
      writer.line('    let ptr = UnsafeMutablePointer<_${retStructName}C>.allocate(capacity: 1)');
      writer.line('    ptr.initialize(to: _${retStructName}C.fromSwift(r))');
      writer.line('    return UnsafeMutableRawPointer(ptr)');
    } else if (isVoid) {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var _thrownError: Error? = nil');
      writer.line('    Task.detached {');
      writer.line('        do { try await impl.${func.dartName}($callArgs) }');
      writer.line('        catch { _thrownError = error }');
      writer.line('        sema.signal()');
      writer.line('    }');
      writer.line('    sema.wait()');
      writer.line('    if let _e = _thrownError {');
      writer.line('        NSException(name: NSExceptionName((_e as NSError).domain),');
      writer.line('                    reason: (_e as NSError).localizedDescription,');
      writer.line('                    userInfo: nil).raise()');
      writer.line('    }');
    } else if (isString) {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return strdup("") }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result = ""');
      writer.line('    Task.detached {');
      writer.line('        result = (try? await impl.${func.dartName}($callArgs)) ?? ""');
      writer.line('        sema.signal()');
      writer.line('    }');
      writer.line('    sema.wait()');
      writer.line('    return strdup(result)');
    } else if (isRecord) {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result: ${func.returnType.name}? = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      writer.line('    sema.wait()');
      writer.line('    return result?.toNative().map { UnsafeMutableRawPointer(\$0) }');
    } else if (isRecordList) {
      final swiftRetType = mapper.swiftType(func.returnType.name);
      final resultType = swiftRetType.endsWith('?') ? swiftRetType : '$swiftRetType?';
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result: $resultType = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      writer.line('    sema.wait()');
      writer.line('    guard let r = result else { return nil }');
      _emitRecordListEncode(writer, func.returnType.name);
    } else if (isTypedDataReturn) {
      final swiftRetType = mapper.swiftType(func.returnType.name);
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result: $swiftRetType? = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      writer.line('    sema.wait()');
      writer.line('    guard let r = result else { return nil }');
      _emitTypedDataReturn(writer, func);
    } else if (isBool) {
      final boolGuardDefault = func.returnType.isNullable ? '-1' : '0';
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return $boolGuardDefault }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result: Bool? = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      writer.line('    sema.wait()');
      if (func.returnType.isNullable) {
        writer.line('    guard let b = result else { return -1 }');
        writer.line('    return b ? 1 : 0');
      } else {
        writer.line('    return Int8((result ?? false) ? 1 : 0)');
      }
    } else {
      final swiftRetType = mapper.swiftType(func.returnType.name);
      final defaultVal = mapper.defaultCDeclValue(func.returnType.name);
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return $defaultVal }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      final resultType = switch (func.returnType.name) {
        'int?' => 'Int64?',
        'double?' => 'Double?',
        'bool?' => 'Bool?',
        _ => swiftRetType.endsWith('?') ? swiftRetType : '$swiftRetType?',
      };
      writer.line('    var result: $resultType = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      writer.line('    sema.wait()');
      if (isEnumRet) {
        writer.line('    return result?.rawValue ?? $defaultVal');
      } else if (func.returnType.name == 'int?') {
        writer.line('    return NitroNullableInt.fromNullable(result).toNative()');
      } else if (func.returnType.name == 'double?') {
        writer.line('    return NitroNullableDouble.fromNullable(result).toNative()');
      } else if (func.returnType.name == 'bool?') {
        writer.line('    return NitroNullableBool.fromNullable(result).toNative()');
      } else if (func.returnType.isNullable) {
        final base = func.returnType.name.replaceFirst('?', '');
        final nullSentinel = base == 'int'
            ? 'Int64.min'
            : base == 'double'
            ? 'Double.nan'
            : defaultVal;
        writer.line('    return result ?? $nullSentinel');
      } else {
        writer.line('    return result ?? $defaultVal');
      }
    }
  }

  // ── sync ─────────────────────────────────────────────────────────────────

  static void _emitSync(
    CodeWriter writer,
    BridgeFunction func,
    BridgeSpec spec,
    String callArgs,
    SwiftTypeMapper mapper, {
    required bool isStruct,
    required bool isRecord,
    required bool isRecordList,
    required bool isBool,
    required bool isVoid,
    required bool isString,
    required bool isTypedDataReturn,
    required bool isEnumRet,
    required bool isMap,
    bool isVariantRet = false,
  }) {
    if (func.isResult) {
      // @NitroResult: call impl, encode success/error into [1B tag][record payload].
      // The Swift helper _nitroEncodeResult<T> wraps the return/throw.
      final retName = func.returnType.name.replaceFirst('?', '');
      final encodeHelper = _nitroResultEncodeHelper(retName, spec);
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    do {');
      writer.line('        let result = try impl.${func.dartName}($callArgs)');
      writer.line('        return $encodeHelper(result)');
      writer.line('    } catch {');
      writer.line('        return _nitroEncodeResultError(error)');
      writer.line('    }');
    } else if (func.returnType.isNativeHandle) {
      // @NitroOwned: impl returns UnsafeMutableRawPointer? directly.
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    return impl.${func.dartName}($callArgs)');
    } else if (isVariantRet) {
      // @NitroVariant return: encode as [4B len][1B tag][fields] using NitroRecordWriter.
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _vResult = impl.${func.dartName}($callArgs)');
      writer.line('    let _vw = NitroRecordWriter()');
      writer.line('    _vResult.writeFields(to: _vw)');
      writer.line('    return _vw.toNative().map { UnsafeMutablePointer(\$0) }');
    } else if (isVoid) {
      writer.line('    ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs)');
    } else if (isBool) {
      if (func.returnType.isNullable) {
        writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return -1 }');
        writer.line('    guard let result = impl.${func.dartName}($callArgs) else { return -1 }');
        writer.line('    return result ? 1 : 0');
      } else {
        writer.line('    return Int8((${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) ?? false) ? 1 : 0)');
      }
    } else if (isStruct) {
      final sn = func.returnType.name.replaceFirst('?', '');
      if (func.returnType.isNullable) {
        writer.line('    guard let impl = ${spec.dartClassName}Registry.impl, let result = impl.${func.dartName}($callArgs) else { return nil }');
      } else {
        writer.line('    guard let result = ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) else { return nil }');
      }
      writer.line('    let ptr = UnsafeMutablePointer<_${sn}C>.allocate(capacity: 1)');
      writer.line('    ptr.initialize(to: _${sn}C.fromSwift(result))');
      writer.line('    return UnsafeMutableRawPointer(ptr)');
    } else if (isString) {
      writer.line('    return strdup(${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) ?? "")');
    } else if (isMap) {
      final mapParam = func.params.firstOrNull?.name ?? 'value';
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    guard let _rawPtr = $mapParam else { return nil }');
      writer.line('    let inputMap = _nitroDecodeMapBinary(_rawPtr.assumingMemoryBound(to: UInt8.self))');
      writer.line('    let result = impl.${func.dartName}(value: inputMap)');
      writer.line('    guard let resultMap = result as? [String: Any] else { return nil }');
      writer.line('    return _nitroEncodeMapBinary(resultMap)');
    } else if (isRecord) {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      if (func.returnType.isNullable) {
        writer.line('    return impl.${func.dartName}($callArgs)?.toNative().map { UnsafeMutableRawPointer(\$0) }');
      } else {
        writer.line('    return impl.${func.dartName}($callArgs).toNative().map { UnsafeMutableRawPointer(\$0) }');
      }
    } else if (isRecordList) {
      writer.line('    guard let r = ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) else { return nil }');
      _emitRecordListEncode(writer, func.returnType.name);
    } else if (isTypedDataReturn) {
      writer.line('    guard let r = ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) else { return nil }');
      _emitTypedDataReturn(writer, func);
    } else if (func.returnType.name == 'int?') {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _ni_result = impl.${func.dartName}($callArgs)');
      writer.line('    return NitroNullableInt.fromNullable(_ni_result).toNative()');
    } else if (func.returnType.name == 'double?') {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _nd_result = impl.${func.dartName}($callArgs)');
      writer.line('    return NitroNullableDouble.fromNullable(_nd_result).toNative()');
    } else if (func.returnType.name == 'bool?') {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _nb_result = impl.${func.dartName}($callArgs)');
      writer.line('    return NitroNullableBool.fromNullable(_nb_result).toNative()');
    } else {
      final defaultVal = mapper.defaultCDeclValue(func.returnType.name);
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return $defaultVal }');
      if (isEnumRet && func.returnType.isNullable) {
        writer.line('    return impl.${func.dartName}($callArgs)?.rawValue ?? $defaultVal');
      } else if (isEnumRet) {
        writer.line('    return impl.${func.dartName}($callArgs).rawValue');
      } else if (func.returnType.isNullable) {
        writer.line('    return impl.${func.dartName}($callArgs) ?? $defaultVal');
      } else {
        writer.line('    return impl.${func.dartName}($callArgs)');
      }
    }
  }

  // ── @NitroResult encode helper selector ──────────────────────────────────────

  /// Returns the name of the Swift helper function that encodes a success value
  /// of the given [retName] type into the @NitroResult byte buffer.
  static String _nitroResultEncodeHelper(String retName, BridgeSpec spec) {
    switch (retName) {
      case 'int':    return '_nitroEncodeResultInt64';
      case 'double': return '_nitroEncodeResultFloat64';
      case 'bool':   return '_nitroEncodeResultBool';
      case 'String': return '_nitroEncodeResultString';
      default:
        if (spec.isEnumName(retName)) return '_nitroEncodeResultInt64';
        // @HybridRecord or @HybridStruct or @NitroVariant: encode via record codec
        return '_nitroEncodeResultRecord';
    }
  }

  // ── shared return helpers ─────────────────────────────────────────────────

  static void _emitRecordListEncode(CodeWriter writer, String returnTypeName) {
    final itemType = returnTypeName.substring(5, returnTypeName.length - 1);
    final isPrim = ['int', 'double', 'bool', 'String'].contains(itemType.replaceAll('?', ''));
    if (isPrim) {
      final base = itemType.replaceAll('?', '');
      final writeCall = switch (base) {
        'double' => 'writeDouble(e)',
        'bool' => 'writeBool(e)',
        'String' => 'writeString(e)',
        _ => 'writeInt(e)',
      };
      writer.line('    return NitroRecordWriter.encodeList(r) { w, e in w.$writeCall }.map { UnsafeMutableRawPointer(\$0) }');
    } else {
      writer.line('    return NitroRecordWriter.encodeIndexedList(r) { w, e in e.writeFields(w) }.map { UnsafeMutableRawPointer(\$0) }');
    }
  }

  static void _emitTypedDataReturn(CodeWriter writer, BridgeFunction func) {
    if (SwiftTypeMapper.isDataBackedTypedData(func.returnType.name)) {
      final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataReturn' : '_nitroCopyTypedDataReturn';
      writer.line('    return r.withUnsafeBytes { $helper(\$0) }');
    } else {
      final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataArrayReturn' : '_nitroCopyTypedDataArrayReturn';
      writer.line('    return $helper(r)');
    }
  }
}
