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

    if (prop.hasGetter) {
      final isEnumProp = spec.enums.any((en) => en.name == propTypeBase);
      final getRetType = isString
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
      if (isString && isNullableProp) {
        writer.line('    guard let v = ${spec.dartClassName}Registry.impl?.${prop.dartName} else { return nil }');
        writer.line('    return strdup(v)');
      } else if (isString) {
        writer.line('    return strdup(${spec.dartClassName}Registry.impl?.${prop.dartName} ?? "")');
      } else if (isBool && isNullableProp) {
        writer.line('    return NitroNullableBool.fromNullable(${spec.dartClassName}Registry.impl?.${prop.dartName}).toNative()');
      } else if (isBool) {
        writer.line('    return ${spec.dartClassName}Registry.impl?.${prop.dartName} == true ? 1 : 0');
      } else if (isEnumProp && isNullableProp) {
        writer.line('    return ${spec.dartClassName}Registry.impl?.${prop.dartName}?.rawValue ?? -1');
      } else if (isEnumProp) {
        writer.line('    return ${spec.dartClassName}Registry.impl?.${prop.dartName}.rawValue ?? ${mapper.defaultCDeclValue(propTypeName)}');
      } else if (isNullableProp && isDouble) {
        writer.line('    return NitroNullableDouble.fromNullable(${spec.dartClassName}Registry.impl?.${prop.dartName}).toNative()');
      } else if (isNullableProp && isInt) {
        writer.line('    return NitroNullableInt.fromNullable(${spec.dartClassName}Registry.impl?.${prop.dartName}).toNative()');
      } else {
        writer.line('    return ${spec.dartClassName}Registry.impl?.${prop.dartName} ?? ${mapper.defaultCDeclValue(propTypeName)}');
      }
      writer.line('}');
      writer.blankLine();
    }

    if (prop.hasSetter) {
      final isEnumProp  = spec.enums.any((en) => en.name == propTypeBase);
      final isStructProp = spec.structs.any((st) => st.name == propTypeBase);
      final setParamType = isBool && isNullableProp
          ? 'UnsafeMutableRawPointer?'
          : isBool
          ? 'Int8'
          : isString
          ? 'UnsafePointer<CChar>?'
          : isEnumProp
          ? 'Int64'
          : isStructProp
          ? 'UnsafeRawPointer?'
          : (isNullableProp && isDouble)
          ? 'UnsafeMutableRawPointer?'
          : (isNullableProp && isInt)
          ? 'UnsafeMutableRawPointer?'
          : swiftType;
      writer.line('@_cdecl("_${spec.namespace}_call_set_${prop.dartName}")');
      writer.line('public func _${spec.namespace}_call_set_${prop.dartName}(_ value: $setParamType) {');
      if (isBool && isNullableProp) {
        writer.line('    if let v = value { ${spec.dartClassName}Registry.impl?.${prop.dartName} = NitroNullableBool.fromNative(v.assumingMemoryBound(to: UInt8.self)).nullable }');
      } else if (isBool) {
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value != 0');
      } else if (isString && isNullableProp) {
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value != nil ? String(cString: value!) : nil');
      } else if (isString) {
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value != nil ? String(cString: value!) : ""');
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
        writer.line('    if let v = value { ${spec.dartClassName}Registry.impl?.${prop.dartName} = NitroNullableDouble.fromNative(v.assumingMemoryBound(to: UInt8.self)).nullable }');
      } else if (isNullableProp && isInt) {
        writer.line('    if let v = value { ${spec.dartClassName}Registry.impl?.${prop.dartName} = NitroNullableInt.fromNative(v.assumingMemoryBound(to: UInt8.self)).nullable }');
      } else {
        writer.line('    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value');
      }
      writer.line('}');
      writer.blankLine();
    }
  }
}
