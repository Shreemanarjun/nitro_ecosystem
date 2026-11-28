part of '../swift_function_emitter.dart';

// The `@_cdecl` stub body of a `@nitroAsync` method: run the `async throws`
// implementation on a detached task, wait for it, raise what it threw.

/// Surfaces `_thrownError`, caught inside the Task, to Dart: the Obj-C++
/// shim around this stub catches the NSException and reports it.
void _emitRethrow(CodeWriter writer) {
  writer.line('    if let _e = _thrownError {');
  writer.line('        NSException(name: NSExceptionName((_e as NSError).domain),');
  writer.line('                    reason: (_e as NSError).localizedDescription,');
  writer.line('                    userInfo: nil).raise()');
  writer.line('    }');
}

// Timeout for @NitroAsync(timeout: N) is enforced on the Dart side via
// Future.timeout() — NOT here. NSException.raise() cannot safely escape a
// @_cdecl frame called from C/Dart-FFI (the exception hits a C frame with no
// ObjC handler and the runtime calls abort()). Dart-side timeout is clean and
// platform-agnostic; the background Task still runs to completion (acceptable).
void _emitSemaWait(CodeWriter writer, BridgeFunction func) {
  writer.line('    sema.wait()');
}

/// Runs the impl on a detached task and waits for it. [assign] receives the
/// value (`result = `), or is empty for void. A thrown error is raised after
/// the wait, never dropped: `try?` here once turned a throw into a zero, an
/// empty string or a null struct pointer that crashed Dart (issue #66).
void _emitTask(CodeWriter writer, BridgeFunction func, String callArgs, String assign) {
  writer.line('    var _thrownError: Error? = nil');
  writer.line('    Task.detached {');
  writer.line('        do { ${assign}try await impl.${func.dartName}($callArgs) }');
  writer.line('        catch { _thrownError = error }');
  writer.line('        sema.signal()');
  writer.line('    }');
  _emitSemaWait(writer, func);
  _emitRethrow(writer);
}

void _emitAsync(
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
  required bool isAnyMap,
}) {
  // @NitroOwned async: allocate on a background thread, return the raw ptr.
  if (func.returnType.isNativeHandle) {
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return nil }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var _ownedPtr: UnsafeMutableRawPointer? = nil');
    _emitTask(writer, func, callArgs, '_ownedPtr = ');
    writer.line('    return _ownedPtr');
    return;
  }

  // @NitroResult async: call the throwing impl on a background thread then
  // encode the outcome into the [1B tag][payload] wire format.
  if (func.isResult) {
    // The impl's own return type, nullability included: a nil VALUE must
    // not be mistaken for "no result".
    final swiftRetType = mapper.swiftType(func.returnType.name, bridgeType: func.returnType);
    // Dart reads the tag byte before anything else: every exit is a result
    // blob, never nil.
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return _nitroEncodeResultError("${spec.dartClassName} is not registered") }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var _nitroOk: Optional<$swiftRetType> = nil');
    writer.line('    var _nitroErr: Error? = nil');
    writer.line('    Task.detached {');
    writer.line('        do { _nitroOk = try await impl.${func.dartName}($callArgs) }');
    writer.line('        catch { _nitroErr = error }');
    writer.line('        sema.signal()');
    writer.line('    }');
    _emitSemaWait(writer, func);
    writer.line('    if let _e = _nitroErr { return _nitroEncodeResultError(_e) }');
    writer.line('    guard let _ok = _nitroOk else { return _nitroEncodeResultError("${func.dartName} produced no result") }');
    _emitResultOk(writer, func, spec, '_ok', '    ');
    return;
  }

  // A map or any-map: run the impl on a background thread, encode the result.
  if (isMap || isAnyMap) {
    final swiftRetType = mapper.swiftType(func.returnType.name, bridgeType: func.returnType);
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return nil }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var _mapResult: Optional<$swiftRetType> = nil');
    _emitTask(writer, func, callArgs, '_mapResult = ');
    writer.line('    guard let _map = _mapResult else { return nil }');
    writer.line('    return ${_mapBlock(func, spec, '_map')}');
    return;
  }

  // @NitroVariant async: dispatch on background thread, encode the result.
  final isVariantRet = spec.isVariantName(bareTypeName(func.returnType.name));
  if (isVariantRet) {
    final variantName = bareTypeName(func.returnType.name);
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return nil }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var _vResult: $variantName? = nil');
    _emitTask(writer, func, callArgs, '_vResult = ');
    writer.line('    guard let _vr = _vResult else { return nil }');
    writer.line('    let _vw = NitroRecordWriter()');
    writer.line('    _vr.writeFields(to: _vw)');
    writer.line('    return _vw.toNative().map { UnsafeMutablePointer(\$0) }');
    return;
  }

  if (isStruct) {
    final retStructName = bareTypeName(func.returnType.name);
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return nil }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    // The bare type: a nullable return assigns into the same optional, and
    // nil then means "null". `Point??` did not compile.
    writer.line('    var result: $retStructName? = nil');
    _emitTask(writer, func, callArgs, 'result = ');
    writer.line('    guard let r = result else { return nil }');
    writer.line('    let ptr = UnsafeMutablePointer<_${retStructName}C>.allocate(capacity: 1)');
    writer.line('    ptr.initialize(to: _${retStructName}C.fromSwift(r))');
    writer.line('    return UnsafeMutableRawPointer(ptr)');
  } else if (isVoid) {
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    _emitTask(writer, func, callArgs, '');
  } else if (isString) {
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return _nitroStringToCString("") }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var result: String? = nil');
    _emitTask(writer, func, callArgs, 'result = ');
    writer.line('    return _nitroStringToCString(result ?? "")');
  } else if (isRecord) {
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return nil }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var result: ${bareTypeName(func.returnType.name)}? = nil');
    _emitTask(writer, func, callArgs, 'result = ');
    writer.line('    return result?.toNative().map { UnsafeMutableRawPointer(\$0) }');
  } else if (isRecordList) {
    final swiftRetType = mapper.swiftType(func.returnType.name);
    final resultType = swiftRetType.endsWith('?') ? swiftRetType : '$swiftRetType?';
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return nil }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var result: $resultType = nil');
    _emitTask(writer, func, callArgs, 'result = ');
    writer.line('    guard let r = result else { return nil }');
    _emitRecordListEncode(writer, func.returnType);
  } else if (isTypedDataReturn) {
    // The bare type: a nullable return assigns into the same optional, and
    // nil then means "null" (or an error, which is raised below).
    final swiftRetType = mapper.swiftType(bareTypeName(func.returnType.name));
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return nil }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var result: $swiftRetType? = nil');
    _emitTask(writer, func, callArgs, 'result = ');
    writer.line('    guard let r = result else { return nil }');
    _emitTypedDataReturn(writer, func);
  } else if (isBool) {
    final boolGuardDefault = func.returnType.isNullable ? '-1' : '0';
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return $boolGuardDefault }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    writer.line('    var result: Bool? = nil');
    _emitTask(writer, func, callArgs, 'result = ');
    if (func.returnType.isNullable) {
      writer.line('    guard let b = result else { return -1 }');
      writer.line('    return b ? 1 : 0');
    } else {
      writer.line('    return Int8((result ?? false) ? 1 : 0)');
    }
  } else {
    final swiftRetType = mapper.swiftType(func.returnType.name);
    final defaultVal = mapper.defaultCDeclValue(func.returnType.name);
    writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { ${spec.dartClassName}Registry.raiseNotRegistered(); return $defaultVal }');
    writer.line('    let sema = DispatchSemaphore(value: 0)');
    final resultType = switch (func.returnType.name) {
      'int?' => 'Int64?',
      'uint64?' => 'UInt64?',
      'double?' => 'Double?',
      'bool?' => 'Bool?',
      _ => swiftRetType.endsWith('?') ? swiftRetType : '$swiftRetType?',
    };
    writer.line('    var result: $resultType = nil');
    _emitTask(writer, func, callArgs, 'result = ');
    switch (func.returnType.name) {
      case 'DateTime':
        writer.line('    return result.map { Int64((\$0.timeIntervalSince1970 * 1000).rounded()) } ?? 0');
      case 'DateTime?':
        writer.line('    let _out_ndt = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _out_ndt[0] = result != nil ? 1 : 0');
        writer.line('    if let _v = result ?? nil { Swift.withUnsafeBytes(of: Int64((_v.timeIntervalSince1970 * 1000).rounded())) { UnsafeMutableRawPointer(_out_ndt + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _out_ndt');
      case _ when isEnumRet:
        writer.line('    return result?.rawValue ?? $defaultVal');
      case 'int?':
        // Byte-safe encode: byte[0]=hasValue, bytes[1..8]=Int64 via copyMemory (avoids alignment crash).
        writer.line('    let _out_i = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _out_i[0] = result != nil ? 1 : 0');
        writer.line('    if let _v = result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_i + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _out_i');
      case 'double?':
        writer.line('    let _out_d = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _out_d[0] = result != nil ? 1 : 0');
        writer.line('    if let _v = result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_d + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _out_d');
      case 'bool?':
        writer.line('    let _out_b = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)');
        writer.line('    _out_b[0] = result != nil ? 1 : 0');
        writer.line('    _out_b[1] = result == true ? 1 : 0');
        writer.line('    return _out_b');
      case 'uint64?':
        writer.line('    let _out_nu = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _out_nu[0] = result != nil ? 1 : 0');
        writer.line('    if let _v = result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nu + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _out_nu');
      case _ when func.returnType.isNullable:
        final base = bareTypeName(func.returnType.name);
        final nullSentinel = base == 'int'
            ? 'Int64.min'
            : base == 'double'
            ? 'Double.nan'
            : defaultVal;
        writer.line('    return result ?? $nullSentinel');
      default:
        writer.line('    return result ?? $defaultVal');
    }
  }
}
