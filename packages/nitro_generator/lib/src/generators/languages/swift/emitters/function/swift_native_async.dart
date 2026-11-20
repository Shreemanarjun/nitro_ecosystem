part of '../swift_function_emitter.dart';

// The `@_cdecl` stub body of a `@nitroNativeAsync` method: start a detached
// task and post its result (or an error) to the Dart port.

void _emitNativeAsync(
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
  required bool isAnyMap,
  required bool isTypedDataReturn,
  required bool isVariantRet,
  required bool isCustomTypeReturn,
}) {
  writer.line('@_cdecl("_${spec.namespace}_call_${func.dartName}")');
  writer.line('public func _${spec.namespace}_call_${func.dartName}($params${params.isNotEmpty ? ", " : ""}_ errPtr: Int64, _ dartPort: Int64) {');
  // Fresh-per-call NitroError* whose address Dart passed as errPtr (see
  // NitroRuntime.throwIfOutParamErrorAndFree) — unlike sync's one
  // instance-owned slot, native-async calls aren't serialized so each call
  // gets its own struct.
  // UnsafeMutablePointer<T>.init?(bitPattern:) is already failable — it
  // returns UnsafeMutablePointer<T>? on its own; adding a `?` after the
  // type name here would instead try (and fail) to resolve a nonexistent
  // Optional(bitPattern:) initializer.
  writer.line('    let _errPtr = UnsafeMutablePointer<NitroError>(bitPattern: UInt(bitPattern: Int(errPtr)))');
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
      writer.line('    let ${p.name}Arr = ${p.name}.map { Data(bytes: \$0, count: Int(${p.name}_length)) }${p.type.name.endsWith('?') ? '' : ' ?? Data()'}');
    } else {
      writer.line('    let ${p.name}Arr = ${p.name}.map { Array(UnsafeBufferPointer(start: \$0, count: Int(${p.name}_length))) }${p.type.name.endsWith('?') ? '' : ' ?? []'}');
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
        final isEnum = spec.isEnumName(bareTypeName(p.type.name));
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
        if (spec.isStructName(bareTypeName(p.type.name))) return '${p.name}: ${p.name}_dec';
        if (spec.isRecordName(bareTypeName(p.type.name))) return '${p.name}: ${p.name}_dec';
        if (spec.isVariantName(bareTypeName(p.type.name))) return '${p.name}: ${p.name}_dec';
        if (p.type.isMap || p.type.isAnyMap) return '${p.name}: ${SwiftMapEmitter.argName(p)}';
        if (p.type.isAnyNativeObject) {
          final opt = p.type.isNullable || p.type.name.endsWith('?');
          return opt ? '${p.name}: ${p.name} == -1 ? nil : ${p.name}' : '${p.name}: ${p.name}';
        }
        final customBaseA = bareTypeName(p.type.name);
        if (spec.isCustomTypeName(customBaseA)) return '${p.name}: ${p.name}';
        if (isEnum) {
          final en = bareTypeName(p.type.name);
          final opt = p.type.name.endsWith('?');
          return opt ? '${p.name}: $en(rawValue: ${p.name})' : '${p.name}: $en(rawValue: ${p.name})!';
        }
        return '${p.name}: ${p.name}';
      })
      .join(', ');

  writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else {');
  writer.line('        var _null = Dart_CObject()');
  writer.line('        _null.type = Dart_CObject_kNull');
  writer.line('        _ = ${_libStem(spec)}_nitro_post(dartPort, &_null)');
  writer.line('        return');
  writer.line('    }');
  // Pre-decode nullable prim/DateTime pointer params BEFORE Task.detached.
  // The Dart Arena holding these pointers is freed synchronously after the C fn returns,
  // before Task.detached runs. Copying to Swift typed locals here keeps values alive.
  for (final p in func.params) {
    switch (p.type.name) {
      case 'int?':
        writer.line(
          '    let ${p.name}_dec: Int64? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()',
        );
      case 'uint64?':
        writer.line(
          '    let ${p.name}_dec: UInt64? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: UInt64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()',
        );
      case 'double?':
        writer.line(
          '    let ${p.name}_dec: Double? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Double = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return _rv }()',
        );
      case 'bool?':
        writer.line('    let ${p.name}_dec: Bool? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; return _p[1] != 0 }()');
      case 'DateTime?':
        writer.line(
          '    let ${p.name}_dec: Date? = { guard let _p = ${p.name}, _p[0] != 0 else { return nil }; var _rv: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_rv) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(_p + 1), byteCount: 8) }; return Date(timeIntervalSince1970: Double(_rv)/1000.0) }()',
        );
      case _ when p.type.isRecord && p.type.name.startsWith('List<'):
        // Handled below via _emitParamConversions (List<record/enum/variant/primitive>).
        break;
      case _ when spec.isStructName(bareTypeName(p.type.name)):
        // .pointee.toSwift() copies the struct's fields out of the pointer
        // into an owned Swift value the moment this runs — safe to capture.
        final sn = bareTypeName(p.type.name);
        final opt = p.type.name.endsWith('?');
        final rhs = opt ? '${p.name}.map { \$0.assumingMemoryBound(to: _${sn}C.self).pointee.toSwift() }' : '${p.name}!.assumingMemoryBound(to: _${sn}C.self).pointee.toSwift()';
        writer.line('    let ${p.name}_dec = $rhs');
      case _ when spec.isRecordName(bareTypeName(p.type.name)):
        // fromNative(...) copies field values out of the pointer into an
        // owned Swift record the moment this runs — safe to capture.
        final rn = bareTypeName(p.type.name);
        final opt = p.type.name.endsWith('?') || p.type.isNullable;
        final rhs = opt ? '${p.name}.map { $rn.fromNative(\$0.assumingMemoryBound(to: UInt8.self)) }' : '$rn.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self))';
        writer.line('    let ${p.name}_dec = $rhs');
      case _ when spec.isVariantName(bareTypeName(p.type.name)):
        // fromReader(...) copies field values out of the pointer into an
        // owned Swift variant the moment this runs — safe to capture.
        final vn = bareTypeName(p.type.name);
        writer.line('    let ${p.name}_dec = $vn.fromReader(NitroRecordReader(ptr: ${p.name}!.assumingMemoryBound(to: UInt8.self)))');
    }
  }
  // List<@HybridRecord/@HybridEnum/@NitroVariant/primitive> params: decode
  // into owned Swift Arrays before Task.detached (same arena-lifetime
  // reasoning as the pre-decode locals above). Reuses the sync path's
  // decode logic verbatim — stringParams/typedListParams are passed empty
  // since native-async already emits their equivalent loops itself, above.
  _emitParamConversions(writer, [], [], recordListParams, func);
  // Maps are decoded into owned dictionaries here, before the Task.
  SwiftMapEmitter.emitParamDecodes(writer, func, spec);
  writer.line('    Task.detached {');
  writer.line('        do {');

  final retName = func.returnType.name;
  final retBaseName = bareTypeName(retName);
  final isNullableRet = func.returnType.isNullable || retName.endsWith('?');
  switch (retName) {
    case _ when isVoid:
      writer.line('        try await impl.${func.dartName}($callArgs)');
      writer.line('        var _null = Dart_CObject()');
      writer.line('        _null.type = Dart_CObject_kNull');
      writer.line('        _ = ${_libStem(spec)}_nitro_post(dartPort, &_null)');
    case 'String':
      writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
      writer.line('        _result.withCString { cStr in');
      writer.line('            var _obj = Dart_CObject()');
      writer.line('            _obj.type = Dart_CObject_kString');
      writer.line('            _obj.value.as_string = cStr');
      writer.line('            _ = ${_libStem(spec)}_nitro_post(dartPort, &_obj)');
      writer.line('        }');
    case 'String?':
      writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
      writer.line('        guard let _value = _result ?? nil else {');
      writer.line('            var _null = Dart_CObject()');
      writer.line('            _null.type = Dart_CObject_kNull');
      writer.line('            _ = ${_libStem(spec)}_nitro_post(dartPort, &_null)');
      writer.line('            return');
      writer.line('        }');
      writer.line('        _value.withCString { cStr in');
      writer.line('            var _obj = Dart_CObject()');
      writer.line('            _obj.type = Dart_CObject_kString');
      writer.line('            _obj.value.as_string = cStr');
      writer.line('            _ = ${_libStem(spec)}_nitro_post(dartPort, &_obj)');
      writer.line('        }');
    case 'bool':
      writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
      writer.line('        var _obj = Dart_CObject()');
      writer.line('        _obj.type = Dart_CObject_kBool');
      writer.line('        _obj.value.as_bool = _result');
      writer.line('        _ = ${_libStem(spec)}_nitro_post(dartPort, &_obj)');
    case 'bool?':
      // Pointer approach: malloc NitroOptBool (2B), post address as kInt64. Dart frees.
      writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
      writer.line('        let _out_nb = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)');
      writer.line('        _out_nb[0] = (_result ?? nil) != nil ? 1 : 0');
      writer.line('        _out_nb[1] = (_result ?? nil) == true ? 1 : 0');
      writer.line('        var _obj = Dart_CObject()');
      writer.line('        _obj.type = Dart_CObject_kInt64');
      writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_nb)))');
      writer.line('        _ = ${_libStem(spec)}_nitro_post(dartPort, &_obj)');
    default:
      final isDouble = retName == 'double';
      final isNullDbl = retName == 'double?';
      final isNullInt = retName == 'int?';
      final isNullUint64 = retName == 'uint64?';
      final isAnyNativeObjectReturn = func.returnType.isAnyNativeObject;
      final isEnum = spec.isEnumName(retBaseName);
      switch (retName) {
        case _ when isDouble:
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kDouble');
          writer.line('        _obj.value.as_double = _result');
        case _ when isNullDbl:
          // Pointer approach: malloc NitroOptFloat64 (9B), post address as kInt64. Dart frees.
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _out_nf = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
          writer.line('        _out_nf[0] = _result != nil ? 1 : 0');
          writer.line('        if let _v = _result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nf + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_nf)))');
        case _ when isNullInt:
          // Pointer approach: malloc NitroOptInt64 (9B), post address as kInt64. Dart frees.
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _out_ni = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
          writer.line('        _out_ni[0] = _result != nil ? 1 : 0');
          writer.line('        if let _v = _result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_ni + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_ni)))');
        case _ when isNullUint64:
          // uint64? NativeAsync: needs its own branch, which
          // collapses a thrown/nil result to 0 via `?? 0` — silently wrong
          // (0 is a valid uint64 value), not a compile failure, since it
          // compiles fine either way. Pointer approach matches int?/double?
          // above so nil is distinguishable from an actual 0.
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _out_nu = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
          writer.line('        _out_nu[0] = _result != nil ? 1 : 0');
          writer.line('        if let _v = _result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nu + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_nu)))');
        case _ when isAnyNativeObjectReturn && isNullableRet:
          // Nullable AnyNativeObject NativeAsync: needs its own branch, not the
          // generic else, using 0 instead of -1 as the "no value" sentinel —
          // silently wrong (0 is a valid instanceId), not a compile failure.
          // -1 matches the sentinel convention AnyNativeObject params and the
          // sync-path return already use.
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = _result ?? -1');
        case 'DateTime':
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = Int64((_result.timeIntervalSince1970 * 1000).rounded())');
        case 'DateTime?':
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _out_ndt = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
          writer.line('        _out_ndt[0] = _result != nil ? 1 : 0');
          writer.line('        if let _v = _result { Swift.withUnsafeBytes(of: Int64((_v.timeIntervalSince1970 * 1000).rounded())) { UnsafeMutableRawPointer(_out_ndt + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = Int64(bitPattern: UInt64(UInt(bitPattern: _out_ndt)))');
        case _ when isEnum:
          writer.line('        let _resultEnum = try await impl.${func.dartName}($callArgs)');
          if (isNullableRet) {
            writer.line('        let _result = _resultEnum?.rawValue ?? -1');
          } else {
            writer.line('        let _result = _resultEnum.rawValue');
          }
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = Int64(_result)');
        case _ when func.returnType.isNativeHandle:
          // NativeHandle NativeAsync (issue #18): the impl returns
          // UnsafeMutableRawPointer? (same protocol type as the sync path) —
          // post the pointer bits as kInt64. nil posts address 0, which the
          // Dart unpack maps to null for a nullable handle (and to a
          // descriptive StateError for a non-nullable one). This
          // fell to the generic else (`Int64(_result)`) — compile failure.
          writer.line('        let _result: UnsafeMutableRawPointer? = try await impl.${func.dartName}($callArgs)');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = _result != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _result!))) : 0');
        case _ when isVariantRet:
          // Bare @NitroVariant NativeAsync: needs its own branch
          // (`(try? await ...) ?? 0`), which doesn't type-check against an enum —
          // compile failure. Mirrors the sync path's NitroRecordWriter encoding,
          // then posts the pointer as kInt64 (a thrown/absent result posts
          // address 0, matching the isRecord convention above).
          writer.line('        let _vResult: $retBaseName? = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _recPtr: UnsafeMutablePointer<UInt8>? = (_vResult ?? nil).flatMap { _vr -> UnsafeMutablePointer<UInt8>? in');
          writer.line('            let _vw = NitroRecordWriter()');
          writer.line('            _vr.writeFields(to: _vw)');
          writer.line('            return _vw.toNative()');
          writer.line('        }');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
        case _ when isStruct:
          // Bare @HybridStruct NativeAsync: needs its own branch
          // — compile failure (a struct doesn't coerce to Int64). Mirrors the
          // sync path's _${sn}C.fromSwift(...) malloc'd-copy encoding.
          final sn = bareTypeName(func.returnType.name);
          writer.line('        let _result: $sn? = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _recPtr: UnsafeMutableRawPointer? = (_result ?? nil).map { r -> UnsafeMutableRawPointer in');
          writer.line('            let ptr = UnsafeMutablePointer<_${sn}C>.allocate(capacity: 1)');
          writer.line('            ptr.initialize(to: _${sn}C.fromSwift(r))');
          writer.line('            return UnsafeMutableRawPointer(ptr)');
          writer.line('        }');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
        case _ when isAnyMap || isMap:
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _recPtr = ${_mapBlock(func, spec, '_result')}');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
        case _ when isTypedDataReturn:
          // TypedData NativeAsync (Uint8List/Float32List/etc.): is not covered by the generic path
          // to the generic else — compile failure (Data/[Int16]/etc. aren't
          // Int64-convertible). Mirrors the sync path's _nitroCopyTypedData*
          // helpers, which already return UnsafeMutablePointer<UInt8>?.
          writer.line('        let _result: ${mapper.swiftType('$retBaseName?')} = try await impl.${func.dartName}($callArgs)');
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
        case _ when isCustomTypeReturn:
          // @NitroCustomType NativeAsync: needs its own branch
          // — compile failure ([UInt8] isn't Int64-convertible). Mirrors the
          // sync path's fixed-size malloc'd-copy encoding (custom types have a
          // known, agreed encodedSize — no length prefix, unlike records).
          final ct = spec.customTypeByName(func.returnType.baseName)!;
          writer.line('        let _result: [UInt8]? = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _recPtr: UnsafeMutablePointer<UInt8>? = (_result ?? nil).map { _bytes -> UnsafeMutablePointer<UInt8> in');
          writer.line('            let _ct_ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: ${ct.encodedSize})');
          writer.line('            _bytes.withUnsafeBytes { UnsafeMutableRawPointer(_ct_ptr).copyMemory(from: \$0.baseAddress!, byteCount: ${ct.encodedSize}) }');
          writer.line('            return _ct_ptr');
          writer.line('        }');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
        case _ when isRecord:
          // @HybridRecord NativeAsync: encode via the same .toNative() every other
          // record-returning path uses, then post the pointer as kInt64. A nil
          // result (nullable record with no value, or a thrown impl call) posts
          // address 0 (nullptr) — NOT Dart_CObject_kNull — matching how the Dart
          // unpack for nullable records always expects a pointer-typed kInt64.
          writer.line('        let _result: $retBaseName? = try await impl.${func.dartName}($callArgs)');
          writer.line('        let _recPtr = (_result ?? nil)?.toNative()');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
        case _ when isRecordList:
          // List<T> NativeAsync (record / enum / variant / primitive items): encode
          // via the same NitroRecordWriter helpers the sync/@nitroAsync path uses,
          // then post the pointer as kInt64 (empty/absent list posts address 0).
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          _emitNativeAsyncRecordListEncode(writer, func.returnType);
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = _recPtr != nil ? Int64(bitPattern: UInt64(UInt(bitPattern: _recPtr!))) : 0');
        default:
          writer.line('        let _result = try await impl.${func.dartName}($callArgs)');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kInt64');
          writer.line('        _obj.value.as_int64 = Int64(_result)');
      }
      writer.line('        _ = ${_libStem(spec)}_nitro_post(dartPort, &_obj)');
  }

  writer.line('        } catch {');
  writer.line('            if let _errPtr = _errPtr {');
  writer.line('                let _nsErr = error as NSError');
  writer.line('                _errPtr.pointee.hasError = 1');
  // NitroError.name/.message are `const char*` in C, bridged to Swift as
  // UnsafePointer<CChar>? (immutable) — strdup returns UnsafeMutablePointer<CChar>?,
  // which needs the explicit failable UnsafePointer(_:) conversion (Swift
  // does not implicitly convert mutable->immutable pointers on assignment).
  writer.line('                _errPtr.pointee.name = UnsafePointer(strdup(_nsErr.domain))');
  writer.line('                _errPtr.pointee.message = UnsafePointer(strdup(_nsErr.localizedDescription))');
  writer.line('            }');
  writer.line('            var _null = Dart_CObject()');
  writer.line('            _null.type = Dart_CObject_kNull');
  writer.line('            _ = ${_libStem(spec)}_nitro_post(dartPort, &_null)');
  writer.line('        }');
  writer.line('    }');
  writer.line('}');
  writer.blankLine();
}

/// `@NitroNativeAsync` twin of [_emitRecordListEncode] — same encoding, but
/// assigns the resulting pointer to `_recPtr` (posted via Dart_PostCObject_DL
/// by the caller) instead of `return`ing it from a `@_cdecl` function.
/// Reads the in-scope `_result` array (already unwrapped to non-optional by
/// the caller) rather than `r`.
void _emitNativeAsyncRecordListEncode(CodeWriter writer, BridgeType returnType) {
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
