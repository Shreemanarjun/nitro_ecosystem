part of '../swift_function_emitter.dart';

// The `@_cdecl` stub body of a synchronous method: call the implementation,
// hand the value back in its C shape.

void _emitSync(
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
  bool isVariantRet = false,
}) {
  switch (func.returnType.name) {
    case _ when func.isResult:
      // @NitroResult: call impl, encode success/error into [1B tag][record payload].
      // The Swift helper _nitroEncodeResult<T> wraps the return/throw.
      writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return _nitroEncodeResultError("${spec.dartClassName} is not registered") }');
      writer.line('    do {');
      writer.line('        let result = try impl.${func.dartName}($callArgs)');
      _emitResultOk(writer, func, spec, 'result', '        ');
      writer.line('    } catch {');
      writer.line('        return _nitroEncodeResultError(error)');
      writer.line('    }');
    case _ when func.returnType.isNativeHandle:
      // @NitroOwned: impl returns UnsafeMutableRawPointer? directly.
      writer.line(_implGuard(spec, 'nil'));
      writer.line('    return impl.${func.dartName}($callArgs)');
    case _ when isVariantRet:
      // @NitroVariant return: encode as [4B len][1B tag][fields] using NitroRecordWriter.
      writer.line(_implGuard(spec, 'nil'));
      writer.line('    let _vResult = impl.${func.dartName}($callArgs)');
      writer.line('    let _vw = NitroRecordWriter()');
      writer.line('    _vResult.writeFields(to: _vw)');
      writer.line('    return _vw.toNative().map { UnsafeMutablePointer(\$0) }');
    case _ when isVoid:
      writer.line(_implGuard(spec, ''));
      writer.line('    impl.${func.dartName}($callArgs)');
    case _ when isBool:
      if (func.returnType.isNullable) {
        writer.line(_implGuard(spec, '-1'));
        writer.line('    guard let result = impl.${func.dartName}($callArgs) else { return -1 }');
        writer.line('    return result ? 1 : 0');
      } else {
        writer.line(_implGuard(spec, '0'));
        writer.line('    return impl.${func.dartName}($callArgs) ? 1 : 0');
      }
    case _ when isStruct:
      final sn = bareTypeName(func.returnType.name);
      if (func.returnType.isNullable) {
        writer.line(_implGuard(spec, 'nil'));
        writer.line('    guard let result = impl.${func.dartName}($callArgs) else { return nil }');
      } else {
        writer.line(_implGuard(spec, 'nil'));
        writer.line('    let result = impl.${func.dartName}($callArgs)');
      }
      writer.line('    let ptr = UnsafeMutablePointer<_${sn}C>.allocate(capacity: 1)');
      writer.line('    ptr.initialize(to: _${sn}C.fromSwift(result))');
      writer.line('    return UnsafeMutableRawPointer(ptr)');
    case _ when isString:
      if (func.returnType.isNullable) {
        // String?: nil → return nullptr so Dart sees null, not empty string.
        writer.line(_implGuard(spec, 'nil'));
        writer.line('    guard let _s = impl.${func.dartName}($callArgs) else { return nil }');
        writer.line('    return _nitroStringToCString(_s)');
      } else {
        writer.line(_implGuard(spec, '_nitroStringToCString("")'));
        writer.line('    return _nitroStringToCString(impl.${func.dartName}($callArgs))');
      }
    // A map or any-map return. Every parameter, maps included, was decoded
    // at the top of the stub, so any parameter list works.
    case _ when isAnyMap || isMap:
      writer.line(_implGuard(spec, 'nil'));
      writer.line('    let result = impl.${func.dartName}($callArgs)');
      writer.line('    return ${_mapBlock(func, spec, 'result')}');
    case _ when isRecord:
      writer.line(_implGuard(spec, 'nil'));
      if (func.returnType.isNullable) {
        writer.line('    return impl.${func.dartName}($callArgs)?.toNative().map { UnsafeMutableRawPointer(\$0) }');
      } else {
        writer.line('    return impl.${func.dartName}($callArgs).toNative().map { UnsafeMutableRawPointer(\$0) }');
      }
    case _ when isRecordList:
      writer.line(_implGuard(spec, 'nil'));
      _emitUnwrapResult(writer, func, callArgs);
      _emitRecordListEncode(writer, func.returnType);
    case _ when isTypedDataReturn:
      writer.line(_implGuard(spec, 'nil'));
      _emitUnwrapResult(writer, func, callArgs);
      _emitTypedDataReturn(writer, func);
    case _ when func.returnType.isAnyNativeObject:
      // AnyNativeObject: impl returns Int64 instanceId; nullable: -1 = null
      if (func.returnType.isNullable) {
        writer.line(_implGuard(spec, '-1'));
        writer.line('    let _id = impl.${func.dartName}($callArgs); return _id ?? -1');
      } else {
        writer.line(_implGuard(spec, '0'));
        writer.line('    return impl.${func.dartName}($callArgs)');
      }
    case _ when spec.isCustomTypeName(func.returnType.baseName):
      // @NitroCustomType: impl returns [UInt8]? (encoded bytes); bridge copies to malloc'd buffer
      final ct = spec.customTypeByName(func.returnType.baseName)!;
      if (func.returnType.isNullable) {
        writer.line(_implGuard(spec, 'nil'));
        writer.line('    guard let _bytes = impl.${func.dartName}($callArgs) else { return nil }');
      } else {
        writer.line(_implGuard(spec, 'nil'));
        writer.line('    let _bytes = impl.${func.dartName}($callArgs)');
      }
      writer.line('    let _ct_ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: ${ct.encodedSize})');
      writer.line('    _bytes.withUnsafeBytes { UnsafeMutableRawPointer(_ct_ptr).copyMemory(from: \$0.baseAddress!, byteCount: ${ct.encodedSize}) }');
      writer.line('    return _ct_ptr');
    case 'DateTime':
      writer.line(_implGuard(spec, '0'));
      writer.line('    return Int64((impl.${func.dartName}($callArgs).timeIntervalSince1970 * 1000).rounded())');
    case 'DateTime?':
      writer.line(_implGuard(spec, 'nil'));
      writer.line('    let _ndt_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_ndt = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
      writer.line('    _out_ndt[0] = _ndt_result != nil ? 1 : 0');
      writer.line('    if let _v = _ndt_result { Swift.withUnsafeBytes(of: Int64((_v.timeIntervalSince1970 * 1000).rounded())) { UnsafeMutableRawPointer(_out_ndt + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
      writer.line('    return _out_ndt');
    case 'int?':
      // Byte-safe encode: byte[0]=hasValue, bytes[1..8]=Int64 via copyMemory (avoids alignment crash).
      writer.line(_implGuard(spec, 'nil'));
      writer.line('    let _ni_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_ni = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
      writer.line('    _out_ni[0] = _ni_result != nil ? 1 : 0');
      writer.line('    if let _v = _ni_result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_ni + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
      writer.line('    return _out_ni');
    case 'double?':
      writer.line(_implGuard(spec, 'nil'));
      writer.line('    let _nd_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_nd = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
      writer.line('    _out_nd[0] = _nd_result != nil ? 1 : 0');
      writer.line('    if let _v = _nd_result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nd + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
      writer.line('    return _out_nd');
    case 'bool?':
      writer.line(_implGuard(spec, 'nil'));
      writer.line('    let _nb_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_nb = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)');
      writer.line('    _out_nb[0] = _nb_result != nil ? 1 : 0');
      writer.line('    _out_nb[1] = _nb_result == true ? 1 : 0');
      writer.line('    return _out_nb');
    case 'uint64?':
      writer.line(_implGuard(spec, 'nil'));
      writer.line('    let _nu_result = impl.${func.dartName}($callArgs)');
      writer.line('    let _out_nu = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
      writer.line('    _out_nu[0] = _nu_result != nil ? 1 : 0');
      writer.line('    if let _v = _nu_result { Swift.withUnsafeBytes(of: _v) { UnsafeMutableRawPointer(_out_nu + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
      writer.line('    return _out_nu');
    default:
      final defaultVal = mapper.defaultCDeclValue(func.returnType.name);
      writer.line(_implGuard(spec, defaultVal));
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

/// `r` = the impl's result; a nullable return of nil is null.
void _emitUnwrapResult(CodeWriter writer, BridgeFunction func, String callArgs) {
  writer.line(func.returnType.isNullable
      ? '    guard let r = impl.${func.dartName}($callArgs) else { return nil }'
      : '    let r = impl.${func.dartName}($callArgs)');
}
