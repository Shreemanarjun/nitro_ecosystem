import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'swift_type_mapper.dart';

/// Emits `@_cdecl` getter and setter stubs for a single [BridgeProperty].
class SwiftPropertyEmitter {
  static void emit(
    CodeWriter writer,
    BridgeProperty prop,
    BridgeSpec spec,
    SwiftTypeMapper mapper,
  ) {
    final swiftType = mapper.swiftType(prop.type.name);
    final propTypeName = prop.type.name;
    final propTypeBase = propTypeName.replaceFirst('?', '');
    final isNullableProp = propTypeName.endsWith('?');
    final isBool = propTypeBase == 'bool';
    final isDouble = propTypeBase == 'double';
    final isInt = propTypeBase == 'int';
    final isString = propTypeName == 'String' || propTypeName == 'String?';
    final isVariantProp = spec.isVariantName(propTypeBase);

    if (prop.hasGetter) {
      final isEnumProp = spec.isEnumName(propTypeBase);
      final getRetType = isVariantProp
          ? 'UnsafeMutablePointer<UInt8>?'
          : isString
          ? 'UnsafeMutablePointer<CChar>?'
          : isBool && isNullableProp
          ? 'UnsafeMutablePointer<UInt8>?'
          : isBool
          ? 'Int8'
          : isEnumProp
          ? 'Int64'
          : (isNullableProp && isDouble)
          ? 'UnsafeMutablePointer<UInt8>?'
          : (isNullableProp && isInt)
          ? 'UnsafeMutablePointer<UInt8>?'
          : swiftType;
      writer.line('@_cdecl("_${spec.namespace}_call_get_${prop.dartName}")');
      writer.line('public func _${spec.namespace}_call_get_${prop.dartName}() -> $getRetType {');
      if (isVariantProp) {
        writer.line('    guard let _vImpl = ${spec.dartClassName}Registry.impl else { return nil }');
        writer.line('    let _vw = NitroRecordWriter()');
        writer.line('    _vImpl.${prop.dartName}.writeFields(to: _vw)');
        writer.line('    return _vw.toNative().map { UnsafeMutablePointer(\$0) }');
      } else if (isString && isNullableProp) {
        writer.line('    guard let v = ${spec.dartClassName}Registry.impl?.${prop.dartName} else { return nil }');
        writer.line('    return _nitroStringToCString(v)');
      } else if (isString) {
        writer.line('    return _nitroStringToCString(${spec.dartClassName}Registry.impl?.${prop.dartName} ?? "")');
      } else if (isBool && isNullableProp) {
        writer.line('    let _v_b = ${spec.dartClassName}Registry.impl?.${prop.dartName}');
        writer.line('    let _p_b = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)');
        writer.line('    _p_b[0] = _v_b != nil ? 1 : 0');
        writer.line('    _p_b[1] = _v_b == true ? 1 : 0');
        writer.line('    return _p_b');
      } else if (isBool) {
        writer.line('    return ${spec.dartClassName}Registry.impl?.${prop.dartName} == true ? 1 : 0');
      } else if (isEnumProp && isNullableProp) {
        writer.line('    return ${spec.dartClassName}Registry.impl?.${prop.dartName}?.rawValue ?? -1');
      } else if (isEnumProp) {
        writer.line('    return ${spec.dartClassName}Registry.impl?.${prop.dartName}.rawValue ?? ${mapper.defaultCDeclValue(propTypeName)}');
      } else if (isNullableProp && isDouble) {
        writer.line('    let _v_d = ${spec.dartClassName}Registry.impl?.${prop.dartName}');
        writer.line('    let _p_d = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _p_d[0] = _v_d != nil ? 1 : 0');
        writer.line('    if let _dv = _v_d { Swift.withUnsafeBytes(of: _dv) { UnsafeMutableRawPointer(_p_d + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _p_d');
      } else if (isNullableProp && isInt) {
        writer.line('    let _v_i = ${spec.dartClassName}Registry.impl?.${prop.dartName}');
        writer.line('    let _p_i = UnsafeMutablePointer<UInt8>.allocate(capacity: 9)');
        writer.line('    _p_i[0] = _v_i != nil ? 1 : 0');
        writer.line('    if let _iv = _v_i { Swift.withUnsafeBytes(of: _iv) { UnsafeMutableRawPointer(_p_i + 1).copyMemory(from: \$0.baseAddress!, byteCount: 8) } }');
        writer.line('    return _p_i');
      } else {
        writer.line('    return ${spec.dartClassName}Registry.impl?.${prop.dartName} ?? ${mapper.defaultCDeclValue(propTypeName)}');
      }
      writer.line('}');
      writer.blankLine();
    }

    if (prop.hasSetter) {
      final isEnumProp = spec.isEnumName(propTypeBase);
      final isStructProp = spec.isStructName(propTypeBase);
      final setParamType = isVariantProp
          ? 'UnsafePointer<UInt8>?'
          : isBool && isNullableProp
          ? 'UnsafeMutablePointer<UInt8>?'
          : isBool
          ? 'Int8'
          : isString
          ? 'UnsafePointer<CChar>?'
          : isEnumProp
          ? 'Int64'
          : isStructProp
          ? 'UnsafeRawPointer?'
          : (isNullableProp && isDouble)
          ? 'UnsafeMutablePointer<UInt8>?'
          : (isNullableProp && isInt)
          ? 'UnsafeMutablePointer<UInt8>?'
          : swiftType;
      writer.line('@_cdecl("_${spec.namespace}_call_set_${prop.dartName}")');
      writer.line('public func _${spec.namespace}_call_set_${prop.dartName}(_ value: $setParamType) {');
      if (isVariantProp) {
        writer.line('    guard let v = value else { return }');
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = $propTypeBase.fromReader(NitroRecordReader(ptr: UnsafeMutablePointer(mutating: v)))');
      } else if (isBool && isNullableProp) {
        writer.line('    guard let v = value else { ${spec.dartClassName}Registry.impl?.${prop.dartName} = nil; return }');
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = v[0] != 0 ? v[1] != 0 : nil');
      } else if (isBool) {
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value != 0');
      } else if (isString && isNullableProp) {
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = _nitroStringOptFromCString(value)');
      } else if (isString) {
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = _nitroStringFromCString(value)');
      } else if (isEnumProp && isNullableProp) {
        writer.line('    if value == -1 { ${spec.dartClassName}Registry.impl?.${prop.dartName} = nil; return }');
        writer.line('    if let actualValue = $propTypeBase(rawValue: value) {');
        writer.line('        ${spec.dartClassName}Registry.impl?.${prop.dartName} = actualValue');
        writer.line('    }');
      } else if (isEnumProp) {
        writer.line('    if let actualValue = $propTypeBase(rawValue: value) {');
        writer.line('        ${spec.dartClassName}Registry.impl?.${prop.dartName} = actualValue');
        writer.line('    }');
      } else if (isStructProp) {
        writer.line('    if let v = value {');
        writer.line('        ${spec.dartClassName}Registry.impl?.${prop.dartName} = v.assumingMemoryBound(to: _${propTypeBase}C.self).pointee.toSwift()');
        writer.line('    }');
      } else if (isNullableProp && isDouble) {
        writer.line('    guard let v = value else { ${spec.dartClassName}Registry.impl?.${prop.dartName} = nil; return }');
        writer.line('    if v[0] == 0 { ${spec.dartClassName}Registry.impl?.${prop.dartName} = nil; return }');
        writer.line('    var _vd: Double = 0; Swift.withUnsafeMutableBytes(of: &_vd) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(v + 1), byteCount: 8) }');
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = _vd');
      } else if (isNullableProp && isInt) {
        writer.line('    guard let v = value else { ${spec.dartClassName}Registry.impl?.${prop.dartName} = nil; return }');
        writer.line('    if v[0] == 0 { ${spec.dartClassName}Registry.impl?.${prop.dartName} = nil; return }');
        writer.line('    var _vi: Int64 = 0; Swift.withUnsafeMutableBytes(of: &_vi) { \$0.baseAddress!.copyMemory(from: UnsafeRawPointer(v + 1), byteCount: 8) }');
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = _vi');
      } else {
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value');
      }
      writer.line('}');
      writer.blankLine();
    }
  }
}
