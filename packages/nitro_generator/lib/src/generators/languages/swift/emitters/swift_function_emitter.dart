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
    final isVariantRet = spec.isVariantName(func.returnType.name.replaceFirst('?', ''));
    final isCustomTypeReturn = spec.isCustomTypeName(func.returnType.baseName);

    if (func.isNativeAsync) {
      _emitNativeAsync(
        writer,
        func,
        spec,
        mapper,
        params,
        stringParams,
        typedListParams,
        isVoid: func.returnType.name == 'void',
        isRecord: isRecord,
        isRecordList: isRecordList,
        isStruct: isStruct,
        isMap: isMap,
        isTypedDataReturn: isTypedDataReturn,
        isVariantRet: isVariantRet,
        isCustomTypeReturn: isCustomTypeReturn,
      );
      return;
    }

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
          // Byte-safe decode: byte[0]=hasValue; bytes[1..8]=value via copyMemory (avoids withMemoryRebound alignment crash).
          if (p.type.name == 'int?') {
            return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()';
          }
          if (p.type.name == 'uint64?') {
            return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: UInt64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()';
          }
          if (p.type.name == 'double?') {
            return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Double = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()';
          }
          if (p.type.name == 'bool?') return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; return _p[1] != 0 }()';
          if (p.type.name == 'DateTime') return '${p.name}: Date(timeIntervalSince1970: Double(${p.name})/1000.0)';
          if (p.type.name == 'DateTime?') {
            return '${p.name}: { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return Date(timeIntervalSince1970: Double(_rv)/1000.0) }()';
          }
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
            return '${p.name}: $vn.fromReader(NitroRecordReader(ptr: ${p.name}!.assumingMemoryBound(to: UInt8.self)))';
          }
          if (p.type.isAnyNativeObject) {
            // AnyNativeObject: raw Int64 instanceId; nullable: -1 = null
            final opt = p.type.isNullable || p.type.name.endsWith('?');
            return opt ? '${p.name}: ${p.name} == -1 ? nil : ${p.name}' : '${p.name}: ${p.name}';
          }
          final customBase = p.type.name.replaceFirst('?', '');
          if (spec.isCustomTypeName(customBase)) {
            // @NitroCustomType: pass raw UnsafeMutablePointer<UInt8>? to impl
            return '${p.name}: ${p.name}';
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
      if (p.type.name == 'String?') {
        writer.line('    let ${p.name}Str: String? = _nitroStringOptFromCString(${p.name})');
      } else {
        writer.line('    let ${p.name}Str = _nitroStringFromCString(${p.name})');
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
    for (final p in recordListParams) {
      writer.line('    let ${p.name}Ptr = ${p.name}?.assumingMemoryBound(to: UInt8.self)');
      // List<@HybridEnum> / List<@HybridEnum?>
      if (p.type.isEnumList) {
        final itemType = p.type.recordListItemType!;
        if (p.type.recordListItemIsNullable) {
          writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeNullableList(\$0) { r in $itemType(rawValue: r.readInt())! } } ?? []');
        } else {
          writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeList(\$0) { r in $itemType(rawValue: r.readInt())! } } ?? []');
        }
        continue;
      }
      // List<@NitroVariant> / List<@NitroVariant?>
      if (p.type.isVariantList) {
        final itemType = p.type.recordListItemType!;
        if (p.type.recordListItemIsNullable) {
          writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeNullableList(\$0) { r in $itemType.fromReader(r) } } ?? []');
        } else {
          writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeList(\$0) { r in $itemType.fromReader(r) } } ?? []');
        }
        continue;
      }
      final itemType = p.type.name.substring(5, p.type.name.length - 1);
      final isPrim = ['int', 'double', 'bool', 'String'].contains(itemType.replaceAll('?', ''));
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
    SwiftTypeMapper mapper,
    String params,
    List<BridgeParam> stringParams,
    List<BridgeParam> typedListParams, {
    required bool isVoid,
    required bool isRecord,
    required bool isRecordList,
    required bool isStruct,
    required bool isMap,
    required bool isTypedDataReturn,
    required bool isVariantRet,
    required bool isCustomTypeReturn,
  }) {
    writer.line('@_cdecl("_${spec.namespace}_call_${func.dartName}")');
    writer.line('public func _${spec.namespace}_call_${func.dartName}($params${params.isNotEmpty ? ", " : ""}_ dartPort: Int64) {');
    for (final p in stringParams) {
      if (p.type.name == 'String?') {
        writer.line('    let ${p.name}Str: String? = _nitroStringOptFromCString(${p.name})');
      } else {
        writer.line('    let ${p.name}Str = _nitroStringFromCString(${p.name})');
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
    // Build call args for native async. Nullable prim/DateTime pointer params
    // and record/tuple/variant/struct/list-of-those params all use pre-decoded
    // locals (${p.name}_dec / ${p.name}Decoded, emitted before Task.detached)
    // so the Arena pointer is read synchronously before Task.detached — the
    // Dart Arena is freed immediately after the C function returns, before
    // the Swift Task runs.
    final recordListParams = func.params.where((p) => p.type.isRecord && p.type.name.startsWith('List<')).toList();
    final callArgs = func.params
        .map((p) {
          final isStr = p.type.name == 'String' || p.type.name == 'String?';
          final isBool = p.type.name == 'bool' || p.type.name == 'bool?';
          final isEnum = spec.isEnumName(p.type.name.replaceFirst('?', ''));
          if (isStr) return '${p.name}: ${p.name}Str';
          // Use pre-decoded locals (emitted before Task.detached) for pointer params.
          if (p.type.name == 'int?') return '${p.name}: ${p.name}_dec';
          if (p.type.name == 'uint64?') return '${p.name}: ${p.name}_dec';
          if (p.type.name == 'double?') return '${p.name}: ${p.name}_dec';
          if (p.type.name == 'bool?') return '${p.name}: ${p.name}_dec';
          if (p.type.name == 'DateTime') return '${p.name}: Date(timeIntervalSince1970: Double(${p.name})/1000.0)';
          if (p.type.name == 'DateTime?') return '${p.name}: ${p.name}_dec';
          if (isBool) return '${p.name}: ${p.name} != 0';
          if (p.type.isTypedData) return '${p.name}: ${p.name}Arr';
          if (p.type.isRecord && p.type.name.startsWith('List<')) return '${p.name}: ${p.name}Decoded';
          if (p.type.isFunction) return '${p.name}: ${mapper.callbackWrapper(p)}';
          if (spec.isStructName(p.type.name.replaceFirst('?', ''))) return '${p.name}: ${p.name}_dec';
          if (spec.isRecordName(p.type.name.replaceFirst('?', ''))) return '${p.name}: ${p.name}_dec';
          if (spec.isVariantName(p.type.name.replaceFirst('?', ''))) return '${p.name}: ${p.name}_dec';
          if (p.type.isAnyNativeObject) {
            final opt = p.type.isNullable || p.type.name.endsWith('?');
            return opt ? '${p.name}: ${p.name} == -1 ? nil : ${p.name}' : '${p.name}: ${p.name}';
          }
          final customBaseA = p.type.name.replaceFirst('?', '');
          if (spec.isCustomTypeName(customBaseA)) return '${p.name}: ${p.name}';
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
    // Pre-decode nullable prim/DateTime pointer params BEFORE Task.detached.
    // The Dart Arena holding these pointers is freed synchronously after the C fn returns,
    // before Task.detached runs. Copying to Swift typed locals here keeps values alive.
    for (final p in func.params) {
      if (p.type.name == 'int?') {
        writer.line(
          '    let ${p.name}_dec: Int64? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()',
        );
      } else if (p.type.name == 'uint64?') {
        writer.line(
          '    let ${p.name}_dec: UInt64? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: UInt64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()',
        );
      } else if (p.type.name == 'double?') {
        writer.line(
          '    let ${p.name}_dec: Double? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Double = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()',
        );
      } else if (p.type.name == 'bool?') {
        writer.line('    let ${p.name}_dec: Bool? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; return _p[1] != 0 }()');
      } else if (p.type.name == 'DateTime?') {
        writer.line(
          '    let ${p.name}_dec: Date? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return Date(timeIntervalSince1970: Double(_rv)/1000.0) }()',
        );
      } else if (p.type.isRecord && p.type.name.startsWith('List<')) {
        // Handled below via _emitParamConversions (List<record/enum/variant/primitive>).
      } else if (spec.isStructName(p.type.name.replaceFirst('?', ''))) {
        // .pointee.toSwift() copies the struct's fields out of the pointer
        // into an owned Swift value the moment this runs — safe to capture.
        final sn = p.type.name.replaceFirst('?', '');
        final opt = p.type.name.endsWith('?');
        final rhs = opt
            ? '${p.name}.map { \$0.assumingMemoryBound(to: _${sn}C.self).pointee.toSwift() }'
            : '${p.name}!.assumingMemoryBound(to: _${sn}C.self).pointee.toSwift()';
        writer.line('    let ${p.name}_dec = $rhs');
      } else if (spec.isRecordName(p.type.name.replaceFirst('?', ''))) {
        // fromNative(...) copies field values out of the pointer into an
        // owned Swift record the moment this runs — safe to capture.
        final rn = p.type.name.replaceFirst('?', '');
        final opt = p.type.name.endsWith('?') || p.type.isNullable;
        final rhs = opt
            ? '${p.name}.map { $rn.fromNative(\$0.assumingMemoryBound(to: UInt8.self)) }'
            : '$rn.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self))';
        writer.line('    let ${p.name}_dec = $rhs');
      } else if (spec.isVariantName(p.type.name.replaceFirst('?', ''))) {
        // fromReader(...) copies field values out of the pointer into an
        // owned Swift variant the moment this runs — safe to capture.
        final vn = p.type.name.replaceFirst('?', '');
        writer.line('    let ${p.name}_dec = $vn.fromReader(NitroRecordReader(ptr: ${p.name}!.assumingMemoryBound(to: UInt8.self)))');
      }
    }
    // List<@HybridRecord/@HybridEnum/@NitroVariant/primitive> params: decode
    // into owned Swift Arrays before Task.detached (same arena-lifetime
    // reasoning as the pre-decode locals above). Reuses the sync path's
    // decode logic verbatim — stringParams/typedListParams are passed empty
    // since native-async already emits their equivalent loops itself, above.
    _emitParamConversions(writer, [], [], recordListParams, func);
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
      // Pointer approach: malloc NitroOptBool (2B), post address as kInt64. Dart frees.
      writer.line('        let _result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        let _out_nb = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)');
      writer.line('        _out_nb[0] = (_result ?? nil) != nil ? 1 : 0');
      writer.line('        _out_nb[1] = (_result ?? nil) == true ? 1 : 0');
      writer.line('        var _obj = Dart_CObject()');
      writer.line('        _obj.type = Dart_CObject_kInt64');
      writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_nb)))');
      writer.line('        Dart_PostCObject_DL(dartPort, &_obj)');
    } else {
      final isDouble = retName == 'double';
      final isNullDbl = retName == 'double?';
      final isNullInt = retName == 'int?';
      final isNullUint64 = retName == 'uint64?';
      final isAnyNativeObjectReturn = func.returnType.isAnyNativeObject;
      final isEnum = spec.isEnumName(retBaseName);
      if (isDouble) {
        writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? 0.0');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kDouble');
        writer.line('        _obj.value.as_double = _result');
      } else if (isNullDbl) {
        // Pointer approach: malloc NitroOptFloat64 (9B), post address as kInt64. Dart frees.
        writer.line('        let _result = ((try? await impl.${func.dartName}($callArgs)) ?? nil)');
        writer.line('        let _out_nf = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('        _out_nf[0] = _result != nil ? 1 : 0');
        writer.line('        if let _v = _result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nf + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_nf)))');
      } else if (isNullInt) {
        // Pointer approach: malloc NitroOptInt64 (9B), post address as kInt64. Dart frees.
        writer.line('        let _result = ((try? await impl.${func.dartName}($callArgs)) ?? nil)');
        writer.line('        let _out_ni = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('        _out_ni[0] = _result != nil ? 1 : 0');
        writer.line('        if let _v = _result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_ni + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_ni)))');
      } else if (isNullUint64) {
        // uint64? NativeAsync: previously fell to the generic else, which
        // collapses a thrown/nil result to 0 via `?? 0` — silently wrong
        // (0 is a valid uint64 value), not a compile failure, since it
        // compiles fine either way. Pointer approach matches int?/double?
        // above so nil is distinguishable from an actual 0.
        writer.line('        let _result = ((try? await impl.${func.dartName}($callArgs)) ?? nil)');
        writer.line('        let _out_nu = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('        _out_nu[0] = _result != nil ? 1 : 0');
        writer.line('        if let _v = _result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nu + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_nu)))');
      } else if (isAnyNativeObjectReturn && isNullableRet) {
        // Nullable AnyNativeObject NativeAsync: previously fell to the
        // generic else, using 0 instead of -1 as the "no value" sentinel —
        // silently wrong (0 is a valid instanceId), not a compile failure.
        // -1 matches the sentinel convention AnyNativeObject params and the
        // sync-path return already use.
        writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? nil');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _result ?? -1');
      } else if (retName == 'DateTime') {
        writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? Date(timeIntervalSince1970: 0)');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = Int64(_result.timeIntervalSince1970 * 1000)');
      } else if (retName == 'DateTime?') {
        writer.line('        let _result = ((try? await impl.${func.dartName}($callArgs)) ?? nil)');
        writer.line('        let _out_ndt = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('        _out_ndt[0] = _result != nil ? 1 : 0');
        writer.line('        if let _v = _result { Swift.withUnsafeBytes(of: Int64(_v.timeIntervalSince1970 * 1000)) { UnsafeMutableRawPointer(_out_ndt + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_ndt)))');
      } else if (isEnum) {
        if (isNullableRet) {
          writer.line('        let _result = (try? await impl.${func.dartName}($callArgs))?.rawValue ?? -1');
        } else {
          writer.line('        let _result = (try? await impl.${func.dartName}($callArgs))?.rawValue ?? 0');
        }
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = Int64(_result)');
      } else if (isVariantRet) {
        // Bare @NitroVariant NativeAsync: previously fell to the generic else
        // (`(try? await ...) ?? 0`), which doesn't type-check against an enum —
        // compile failure. Mirrors the sync path's NitroRecordWriter encoding,
        // then posts the pointer as kInt64 (a thrown/absent result posts
        // address 0, matching the isRecord convention above).
        writer.line('        let _vResult = try? await impl.${func.dartName}($callArgs)');
        writer.line('        let _recPtr: UnsafeMutablePointer<UInt8>? = (_vResult ?? nil).flatMap { _vr -> UnsafeMutablePointer<UInt8>? in');
        writer.line('            let _vw = NitroRecordWriter()');
        writer.line('            _vr.writeFields(to: _vw)');
        writer.line('            return _vw.toNative()');
        writer.line('        }');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
      } else if (isStruct) {
        // Bare @HybridStruct NativeAsync: previously fell to the generic else
        // — compile failure (a struct doesn't coerce to Int64). Mirrors the
        // sync path's _${sn}C.fromSwift(...) malloc'd-copy encoding.
        final sn = func.returnType.name.replaceFirst('?', '');
        writer.line('        let _result = try? await impl.${func.dartName}($callArgs)');
        writer.line('        let _recPtr: UnsafeMutableRawPointer? = (_result ?? nil).map { r -> UnsafeMutableRawPointer in');
        writer.line('            let ptr = UnsafeMutablePointer<_${sn}C>.allocate(capacity: 1)');
        writer.line('            ptr.initialize(to: _${sn}C.fromSwift(r))');
        writer.line('            return UnsafeMutableRawPointer(ptr)');
        writer.line('        }');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
      } else if (isMap) {
        // Map<String,V> NativeAsync: previously fell to the generic else —
        // compile failure (protocol return type is `Any`, not Int64-
        // convertible). Mirrors the sync path's _nitroEncodeMapBinary
        // encoding — return-only, does not decode a map *parameter* (see the
        // Kotlin isMapReturn dispatch branch's identical scope note).
        //
        // NitroAnyMap return is deliberately NOT handled here: it has no
        // working encode path anywhere in this file (sync or @nitroAsync
        // either) — a pre-existing, broader bug, not something specific to
        // native-async, so it's out of scope for this fix.
        writer.line('        let _result = try? await impl.${func.dartName}($callArgs)');
        _emitNativeAsyncMapEncode(writer, func, spec);
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
      } else if (isTypedDataReturn) {
        // TypedData NativeAsync (Uint8List/Float32List/etc.): previously fell
        // to the generic else — compile failure (Data/[Int16]/etc. aren't
        // Int64-convertible). Mirrors the sync path's _nitroCopyTypedData*
        // helpers, which already return UnsafeMutablePointer<UInt8>?.
        writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? nil');
        if (SwiftTypeMapper.isDataBackedTypedData(func.returnType.name)) {
          final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataReturn' : '_nitroCopyTypedDataReturn';
          writer.line('        let _recPtr = _result?.withUnsafeBytes { $helper(\$0) } ?? nil');
        } else {
          final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataArrayReturn' : '_nitroCopyTypedDataArrayReturn';
          writer.line('        let _recPtr = _result.map { $helper(\$0) } ?? nil');
        }
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
      } else if (isCustomTypeReturn) {
        // @NitroCustomType NativeAsync: previously fell to the generic else
        // — compile failure ([UInt8] isn't Int64-convertible). Mirrors the
        // sync path's fixed-size malloc'd-copy encoding (custom types have a
        // known, agreed encodedSize — no length prefix, unlike records).
        final ct = spec.customTypeByName(func.returnType.baseName)!;
        writer.line('        let _result = try? await impl.${func.dartName}($callArgs)');
        writer.line('        let _recPtr: UnsafeMutablePointer<UInt8>? = (_result ?? nil).map { _bytes -> UnsafeMutablePointer<UInt8> in');
        writer.line('            let _ct_ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: ${ct.encodedSize})');
        writer.line('            _bytes.withUnsafeBytes { UnsafeMutableRawPointer(_ct_ptr).copyMemory(from: \$0.baseAddress!, byteCount: ${ct.encodedSize}) }');
        writer.line('            return _ct_ptr');
        writer.line('        }');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
      } else if (isRecord) {
        // @HybridRecord NativeAsync: encode via the same .toNative() every other
        // record-returning path uses, then post the pointer as kInt64. A nil
        // result (nullable record with no value, or a thrown impl call) posts
        // address 0 (nullptr) — NOT Dart_CObject_kNull — matching how the Dart
        // unpack for nullable records always expects a pointer-typed kInt64.
        writer.line('        let _result = try? await impl.${func.dartName}($callArgs)');
        writer.line('        let _recPtr = (_result ?? nil)?.toNative()');
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
      } else if (isRecordList) {
        // List<T> NativeAsync (record / enum / variant / primitive items): encode
        // via the same NitroRecordWriter helpers the sync/@nitroAsync path uses,
        // then post the pointer as kInt64 (empty/absent list posts address 0).
        writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? []');
        _emitNativeAsyncRecordListEncode(writer, func.returnType);
        writer.line('        var _obj = Dart_CObject()');
        writer.line('        _obj.type = Dart_CObject_kInt64');
        writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
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

  // Timeout for @NitroAsync(timeout: N) is enforced on the Dart side via
  // Future.timeout() — NOT here. NSException.raise() cannot safely escape a
  // @_cdecl frame called from C/Dart-FFI (the exception hits a C frame with no
  // ObjC handler and the runtime calls abort()). Dart-side timeout is clean and
  // platform-agnostic; the background Task still runs to completion (acceptable).
  static void _emitSemaWait(CodeWriter writer, BridgeFunction func) {
    writer.line('    sema.wait()');
  }

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
    // @NitroOwned async: allocate on a background thread, return the raw ptr.
    if (func.returnType.isNativeHandle) {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var _ownedPtr: UnsafeMutableRawPointer? = nil');
      writer.line('    Task.detached {');
      writer.line('        _ownedPtr = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      _emitSemaWait(writer, func);
      writer.line('    return _ownedPtr');
      return;
    }

    // @NitroResult async: call the throwing impl on a background thread then
    // encode the outcome into the [1B tag][payload] wire format.
    if (func.isResult) {
      final retName = func.returnType.name.replaceFirst('?', '');
      final swiftRetType = mapper.swiftType(retName);
      final encodeHelper = _nitroResultEncodeHelper(retName, spec);
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var _nitroOk: $swiftRetType? = nil');
      writer.line('    var _nitroErr: Error? = nil');
      writer.line('    Task.detached {');
      writer.line('        do { _nitroOk = try await impl.${func.dartName}($callArgs) }');
      writer.line('        catch { _nitroErr = error }');
      writer.line('        sema.signal()');
      writer.line('    }');
      _emitSemaWait(writer, func);
      writer.line('    if let _e = _nitroErr { return _nitroEncodeResultError(_e) }');
      writer.line('    guard let _ok = _nitroOk else { return nil }');
      writer.line('    return $encodeHelper(_ok)');
      return;
    }

    // @NitroVariant async: dispatch on background thread, encode the result.
    final isVariantRet = spec.isVariantName(func.returnType.name.replaceFirst('?', ''));
    if (isVariantRet) {
      final variantName = func.returnType.name.replaceFirst('?', '');
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var _vResult: $variantName? = nil');
      writer.line('    Task.detached {');
      writer.line('        _vResult = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      _emitSemaWait(writer, func);
      writer.line('    guard let _vr = _vResult else { return nil }');
      writer.line('    let _vw = NitroRecordWriter()');
      writer.line('    _vr.writeFields(to: _vw)');
      writer.line('    return _vw.toNative().map { UnsafeMutablePointer(\$0) }');
      return;
    }

    if (isStruct) {
      final retStructName = func.returnType.name.replaceFirst('?', '');
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result: ${func.returnType.name}? = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      _emitSemaWait(writer, func);
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
      _emitSemaWait(writer, func);
      writer.line('    if let _e = _thrownError {');
      writer.line('        NSException(name: NSExceptionName((_e as NSError).domain),');
      writer.line('                    reason: (_e as NSError).localizedDescription,');
      writer.line('                    userInfo: nil).raise()');
      writer.line('    }');
    } else if (isString) {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return _nitroStringToCString("") }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result = ""');
      writer.line('    Task.detached {');
      writer.line('        result = (try? await impl.${func.dartName}($callArgs)) ?? ""');
      writer.line('        sema.signal()');
      writer.line('    }');
      _emitSemaWait(writer, func);
      writer.line('    return _nitroStringToCString(result)');
    } else if (isRecord) {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result: ${func.returnType.name}? = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      _emitSemaWait(writer, func);
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
      _emitSemaWait(writer, func);
      writer.line('    guard let r = result else { return nil }');
      _emitRecordListEncode(writer, func.returnType);
    } else if (isTypedDataReturn) {
      final swiftRetType = mapper.swiftType(func.returnType.name);
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let sema = DispatchSemaphore(value: 0)');
      writer.line('    var result: $swiftRetType? = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      _emitSemaWait(writer, func);
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
      _emitSemaWait(writer, func);
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
        'uint64?' => 'UInt64?',
        'double?' => 'Double?',
        'bool?' => 'Bool?',
        _ => swiftRetType.endsWith('?') ? swiftRetType : '$swiftRetType?',
      };
      writer.line('    var result: $resultType = nil');
      writer.line('    Task.detached {');
      writer.line('        result = try? await impl.${func.dartName}($callArgs)');
      writer.line('        sema.signal()');
      writer.line('    }');
      _emitSemaWait(writer, func);
      if (func.returnType.name == 'DateTime') {
        writer.line('    return result.map { Int64(\$0.timeIntervalSince1970 * 1000) } ?? 0');
      } else if (func.returnType.name == 'DateTime?') {
        writer.line('    let _out_ndt = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _out_ndt[0] = result != nil ? 1 : 0');
        writer.line('    if let _v = result ?? nil { Swift.withUnsafeBytes(of: Int64(_v.timeIntervalSince1970 * 1000)) { UnsafeMutableRawPointer(_out_ndt + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _out_ndt');
      } else if (isEnumRet) {
        writer.line('    return result?.rawValue ?? $defaultVal');
      } else if (func.returnType.name == 'int?') {
        // Byte-safe encode: byte[0]=hasValue, bytes[1..8]=Int64 via copyMemory (avoids alignment crash).
        writer.line('    let _out_i = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _out_i[0] = result != nil ? 1 : 0');
        writer.line('    if let _v = result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_i + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _out_i');
      } else if (func.returnType.name == 'double?') {
        writer.line('    let _out_d = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _out_d[0] = result != nil ? 1 : 0');
        writer.line('    if let _v = result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_d + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _out_d');
      } else if (func.returnType.name == 'bool?') {
        writer.line('    let _out_b = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)');
        writer.line('    _out_b[0] = result != nil ? 1 : 0');
        writer.line('    _out_b[1] = result == true ? 1 : 0');
        writer.line('    return _out_b');
      } else if (func.returnType.name == 'uint64?') {
        writer.line('    let _out_nu = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _out_nu[0] = result != nil ? 1 : 0');
        writer.line('    if let _v = result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nu + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _out_nu');
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
      if (func.returnType.isNullable) {
        // String?: nil → return nullptr so Dart sees null, not empty string.
        writer.line('    guard let _s = ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) else { return nil }');
        writer.line('    return _nitroStringToCString(_s)');
      } else {
        writer.line('    return _nitroStringToCString(${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) ?? "")');
      }
    } else if (isMap) {
      final mapParam = func.params.firstOrNull?.name ?? 'value';
      // Determine map value type from the function's return type.
      final mapRetMatch = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(func.returnType.name);
      final mapValType = mapRetMatch?.group(1)?.trim() ?? '';
      final isEnumMapVal = spec.isEnumName(mapValType);
      final isRecordMapVal = spec.recordTypes.any((r) => r.name == mapValType);
      final isVariantMapVal = spec.isVariantName(mapValType);
      // Determine input map value type (may differ from return type for transform functions).
      final mapInMatch = func.params.isNotEmpty && func.params.first.type.isMap ? RegExp(r'^Map<String,\s*(.+)>$').firstMatch(func.params.first.type.name) : null;
      final mapInValType = mapInMatch?.group(1)?.trim() ?? mapValType;
      final isEnumMapIn = spec.isEnumName(mapInValType);
      final isRecordMapIn = spec.recordTypes.any((r) => r.name == mapInValType);
      final isVariantMapIn = spec.isVariantName(mapInValType);
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    guard let _rawPtr = $mapParam else { return nil }');
      writer.line('    let _rawMap = _nitroDecodeMapBinary(_rawPtr.assumingMemoryBound(to: UInt8.self))');
      if (isEnumMapIn) {
        // Decode Int64 rawValues from [String: Any] → typed [String: EnumName]
        writer.line('    let inputMap: [String: $mapInValType] = _rawMap.compactMapValues { $mapInValType(rawValue: \$0 as! Int64) }');
      } else if (isRecordMapIn) {
        // Decode Data blobs → typed [String: RecordType] via fromNative
        writer.line('    let inputMap: [String: $mapInValType] = _rawMap.compactMapValues { raw in');
        writer.line('        guard let blob = raw as? Data else { return nil }');
        writer.line('        return blob.withUnsafeBytes { buf in');
        writer.line('            guard let base = buf.baseAddress else { return nil }');
        writer.line('            return $mapInValType.fromNative(UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self)))');
        writer.line('        }');
        writer.line('    }');
      } else if (isVariantMapIn) {
        // Decode Data blobs → typed [String: VariantType] via fromReader (no fromNative for variants)
        writer.line('    let inputMap: [String: $mapInValType] = _rawMap.compactMapValues { raw in');
        writer.line('        guard let blob = raw as? Data else { return nil }');
        writer.line('        return blob.withUnsafeBytes { buf in');
        writer.line('            guard let base = buf.baseAddress else { return nil }');
        writer.line('            return $mapInValType.fromReader(NitroRecordReader(ptr: UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self))))');
        writer.line('        }');
        writer.line('    }');
      } else {
        writer.line('    let inputMap = _rawMap');
      }
      writer.line('    let result = impl.${func.dartName}(value: inputMap)');
      if (isEnumMapVal) {
        // Encode typed [String: EnumName] → [String: Any] with rawValue Int64 for _nitroEncodeMapBinary
        writer.line('    let resultMap: [String: Any] = (result as? [String: $mapValType] ?? [:]).mapValues { \$0.rawValue as Any }');
      } else if (isRecordMapVal || isVariantMapVal) {
        // Encode typed [String: RecordType/VariantType] → [String: Any] with Data blobs (tag 5)
        writer.line('    guard let typedResult = result as? [String: $mapValType] else { return nil }');
        writer.line('    let resultMap: [String: Any] = typedResult.compactMapValues { v in');
        writer.line('        guard let ptr = v.toNative() else { return nil }');
        writer.line('        let len = Int(UnsafeRawPointer(ptr).loadUnaligned(as: UInt32.self).littleEndian) + 4');
        writer.line('        let blob = Data(bytes: ptr, count: len); free(ptr); return blob as Any');
        writer.line('    }');
      } else {
        writer.line('    guard let resultMap = result as? [String: Any] else { return nil }');
      }
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
      _emitRecordListEncode(writer, func.returnType);
    } else if (isTypedDataReturn) {
      writer.line('    guard let r = ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) else { return nil }');
      _emitTypedDataReturn(writer, func);
    } else if (func.returnType.isAnyNativeObject) {
      // AnyNativeObject: impl returns Int64 instanceId; nullable: -1 = null
      if (func.returnType.isNullable) {
        writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return -1 }');
        writer.line('    let _id = impl.${func.dartName}($callArgs); return _id ?? -1');
      } else {
        writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return 0 }');
        writer.line('    return impl.${func.dartName}($callArgs)');
      }
    } else if (spec.isCustomTypeName(func.returnType.baseName)) {
      // @NitroCustomType: impl returns [UInt8]? (encoded bytes); bridge copies to malloc'd buffer
      final ct = spec.customTypeByName(func.returnType.baseName)!;
      if (func.returnType.isNullable) {
        writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
        writer.line('    guard let _bytes = impl.${func.dartName}($callArgs) else { return nil }');
      } else {
        writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
        writer.line('    let _bytes = impl.${func.dartName}($callArgs)');
      }
      writer.line('    let _ct_ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: ${ct.encodedSize})');
      writer.line('    _bytes.withUnsafeBytes { UnsafeMutableRawPointer(_ct_ptr).copyMemory(from: \$0.baseAddress!, byteCount: ${ct.encodedSize}) }');
      writer.line('    return _ct_ptr');
    } else if (func.returnType.name == 'DateTime') {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return 0 }');
      writer.line('    return Int64(impl.${func.dartName}($callArgs).timeIntervalSince1970 * 1000)');
    } else if (func.returnType.name == 'DateTime?') {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _ndt_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_ndt = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
      writer.line('    _out_ndt[0] = _ndt_result != nil ? 1 : 0');
      writer.line('    if let _v = _ndt_result { Swift.withUnsafeBytes(of: Int64(_v.timeIntervalSince1970 * 1000)) { UnsafeMutableRawPointer(_out_ndt + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
      writer.line('    return _out_ndt');
    } else if (func.returnType.name == 'int?') {
      // Byte-safe encode: byte[0]=hasValue, bytes[1..8]=Int64 via copyMemory (avoids alignment crash).
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _ni_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_ni = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
      writer.line('    _out_ni[0] = _ni_result != nil ? 1 : 0');
      writer.line('    if let _v = _ni_result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_ni + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
      writer.line('    return _out_ni');
    } else if (func.returnType.name == 'double?') {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _nd_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_nd = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
      writer.line('    _out_nd[0] = _nd_result != nil ? 1 : 0');
      writer.line('    if let _v = _nd_result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nd + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
      writer.line('    return _out_nd');
    } else if (func.returnType.name == 'bool?') {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _nb_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_nb = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)');
      writer.line('    _out_nb[0] = _nb_result != nil ? 1 : 0');
      writer.line('    _out_nb[1] = _nb_result == true ? 1 : 0');
      writer.line('    return _out_nb');
    } else if (func.returnType.name == 'uint64?') {
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
      writer.line('    let _nu_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_nu = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
      writer.line('    _out_nu[0] = _nu_result != nil ? 1 : 0');
      writer.line('    if let _v = _nu_result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nu + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
      writer.line('    return _out_nu');
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
      case 'int':
        return '_nitroEncodeResultInt64';
      case 'double':
        return '_nitroEncodeResultFloat64';
      case 'bool':
        return '_nitroEncodeResultBool';
      case 'String':
        return '_nitroEncodeResultString';
      default:
        if (spec.isEnumName(retName)) return '_nitroEncodeResultInt64';
        // @HybridRecord or @HybridStruct or @NitroVariant: encode via record codec
        return '_nitroEncodeResultRecord';
    }
  }

  // ── shared return helpers ─────────────────────────────────────────────────

  static void _emitRecordListEncode(CodeWriter writer, BridgeType returnType) {
    // List<@HybridEnum> / List<@HybridEnum?>
    if (returnType.isEnumList) {
      if (returnType.recordListItemIsNullable) {
        writer.line('    return NitroRecordWriter.encodeNullableList(r) { w, e in w.writeInt(Int64(e.rawValue)) }.map { UnsafeMutableRawPointer(\$0) }');
      } else {
        writer.line('    return NitroRecordWriter.encodeList(r) { w, e in w.writeInt(Int64(e.rawValue)) }.map { UnsafeMutableRawPointer(\$0) }');
      }
      return;
    }
    // List<@NitroVariant> / List<@NitroVariant?>
    if (returnType.isVariantList) {
      if (returnType.recordListItemIsNullable) {
        writer.line('    return NitroRecordWriter.encodeNullableList(r) { w, e in e.writeFields(to: w) }.map { UnsafeMutableRawPointer(\$0) }');
      } else {
        writer.line('    return NitroRecordWriter.encodeList(r) { w, e in e.writeFields(to: w) }.map { UnsafeMutableRawPointer(\$0) }');
      }
      return;
    }
    final returnTypeName = returnType.name;
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

  /// `@NitroNativeAsync` twin of [_emitRecordListEncode] — same encoding, but
  /// assigns the resulting pointer to `_recPtr` (posted via Dart_PostCObject_DL
  /// by the caller) instead of `return`ing it from a `@_cdecl` function.
  /// Reads the in-scope `_result` array (already unwrapped to non-optional by
  /// the caller) rather than `r`.
  static void _emitNativeAsyncRecordListEncode(CodeWriter writer, BridgeType returnType) {
    if (returnType.isEnumList) {
      final call = returnType.recordListItemIsNullable ? 'encodeNullableList' : 'encodeList';
      writer.line('        let _recPtr = NitroRecordWriter.$call(_result) { w, e in w.writeInt(Int64(e.rawValue)) }.map { UnsafeMutableRawPointer(\$0) }');
      return;
    }
    if (returnType.isVariantList) {
      final call = returnType.recordListItemIsNullable ? 'encodeNullableList' : 'encodeList';
      writer.line('        let _recPtr = NitroRecordWriter.$call(_result) { w, e in e.writeFields(to: w) }.map { UnsafeMutableRawPointer(\$0) }');
      return;
    }
    final returnTypeName = returnType.name;
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
      writer.line('        let _recPtr = NitroRecordWriter.encodeList(_result) { w, e in w.$writeCall }.map { UnsafeMutableRawPointer(\$0) }');
    } else {
      writer.line('        let _recPtr = NitroRecordWriter.encodeIndexedList(_result) { w, e in e.writeFields(w) }.map { UnsafeMutableRawPointer(\$0) }');
    }
  }

  /// Encodes the in-scope `_result` (an `Any?` from `try? await impl.method()`,
  /// the declared return type for a `Map` method) into `let _recPtr`,
  /// mirroring the value-type-specific encoding
  /// `_emitSync`'s `isMap` branch uses via `_nitroEncodeMapBinary` (which
  /// already mallocs its own buffer — no arena-lifetime concern here, unlike
  /// the pre-`Task.detached` decode locals elsewhere in this file). Return
  /// side only — see the `isMap` dispatch branch's scope note.
  static void _emitNativeAsyncMapEncode(CodeWriter writer, BridgeFunction func, BridgeSpec spec) {
    final mapRetMatch = RegExp(r'^Map<String,\s*(.+)>$').firstMatch(func.returnType.name);
    final mapValType = mapRetMatch?.group(1)?.trim() ?? '';
    final isEnumMapVal = spec.isEnumName(mapValType);
    final isRecordMapVal = spec.recordTypes.any((r) => r.name == mapValType);
    final isVariantMapVal = spec.isVariantName(mapValType);
    if (isEnumMapVal) {
      writer.line('        let _resultMap: [String: Any] = (((_result ?? nil) as? [String: $mapValType]) ?? [:]).mapValues { \$0.rawValue as Any }');
    } else if (isRecordMapVal || isVariantMapVal) {
      writer.line('        let _typedResultMap = ((_result ?? nil) as? [String: $mapValType]) ?? [:]');
      writer.line('        let _resultMap: [String: Any] = _typedResultMap.compactMapValues { v in');
      writer.line('            guard let ptr = v.toNative() else { return nil }');
      writer.line('            let len = Int(UnsafeRawPointer(ptr).loadUnaligned(as: UInt32.self).littleEndian) + 4');
      writer.line('            let blob = Data(bytes: ptr, count: len); free(ptr); return blob as Any');
      writer.line('        }');
    } else {
      writer.line('        let _resultMap = (((_result ?? nil) as? [String: Any])) ?? [:]');
    }
    writer.line('        let _recPtr = _nitroEncodeMapBinary(_resultMap)');
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
