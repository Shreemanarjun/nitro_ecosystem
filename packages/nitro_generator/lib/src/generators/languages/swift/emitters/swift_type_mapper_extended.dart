import '../../../../bridge_spec.dart';
import 'swift_type_mapper.dart';

// Narrow-width scalar types not in the base SwiftTypeMapper.
// Overrides handle them before calling super so swift_type_mapper.dart
// needs no changes.
const _narrowIntTypes = {
  'int8',
  'int16',
  'int32',
  'uint8',
  'uint16',
  'uint32',
  'intptr',
  'size',
};
const _narrowAllTypes = {
  'int8',
  'int16',
  'int32',
  'uint8',
  'uint16',
  'uint32',
  'float',
  'intptr',
  'size',
};

String? _narrowSwiftType(String base) => switch (base) {
  'int8' => 'Int8',
  'int16' => 'Int16',
  'int32' => 'Int32',
  'uint8' => 'UInt8',
  'uint16' => 'UInt16',
  'uint32' => 'UInt32',
  'float' => 'Float',
  'intptr' => 'Int',
  'size' => 'Int',
  _ => null,
};

class SwiftTypeMapperExtended extends SwiftTypeMapper {
  SwiftTypeMapperExtended(super.spec);

  @override
  String swiftType(String t, {BridgeType? bridgeType}) {
    final isNullable = t.endsWith('?') || (bridgeType?.isNullable ?? false);
    final base = t.replaceFirst('?', '');
    final mapped = _narrowSwiftType(base);
    if (mapped != null) return isNullable ? '$mapped?' : mapped;
    return super.swiftType(t, bridgeType: bridgeType);
  }

  @override
  String swiftCType(String t, {bool isZeroCopy = false}) {
    final base = t.replaceFirst('?', '');
    final mapped = _narrowSwiftType(base);
    if (mapped != null) return mapped;
    return super.swiftCType(t, isZeroCopy: isZeroCopy);
  }

  @override
  String cdeclReturnType(BridgeFunction func) {
    final name = func.returnType.name.replaceFirst('?', '');
    final isNullable = func.returnType.isNullable || func.returnType.name.endsWith('?');
    if (_narrowAllTypes.contains(name)) {
      // Nullable narrow types: UnsafeMutablePointer<UInt8>? (NitroOptXxx raw bytes).
      if (isNullable) return 'UnsafeMutablePointer<UInt8>?';
      return _narrowSwiftType(name)!;
    }
    return super.cdeclReturnType(func);
  }

  @override
  String cdeclParamType(String typeName, {BridgeType? bridgeType}) {
    final base = typeName.replaceFirst('?', '');
    final isNullable = typeName.endsWith('?') || (bridgeType?.isNullable ?? false);
    if (_narrowAllTypes.contains(base)) {
      if (isNullable) return 'UnsafeMutablePointer<UInt8>?';
      return _narrowSwiftType(base)!;
    }
    return super.cdeclParamType(typeName, bridgeType: bridgeType);
  }

  @override
  String defaultCDeclValue(String t) {
    final base = t.replaceFirst('?', '');
    final isNullable = t.endsWith('?');
    if (_narrowIntTypes.contains(base)) return isNullable ? 'nil' : '0';
    if (base == 'float') return isNullable ? 'nil' : '0.0';
    return super.defaultCDeclValue(t);
  }
}
