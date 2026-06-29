import '../../../../bridge_spec.dart';
import '../../../code_writer.dart';
import 'kotlin_type_mapper.dart';

/// Emits getter/setter `_call` bridge methods for a single [BridgeProperty].
class KotlinPropertyEmitter {
  static void emit(
    CodeWriter writer,
    BridgeProperty prop,
    String dartClassName,
    KotlinTypeMapper mapper,
  ) {
    final propTypeName = prop.type.name;
    final propBaseName = propTypeName.replaceFirst('?', '');
    final isNullableProp = propTypeName.endsWith('?');
    final isEnum = mapper.enumNames.contains(propBaseName);
    final isNullableEnum = isEnum && isNullableProp;
    final isNullableInt = propBaseName == 'int' && isNullableProp;
    final isNullableDouble = propBaseName == 'double' && isNullableProp;
    final isNullableBool = propBaseName == 'bool' && isNullableProp;

    // _call bridge type must match the JVM descriptor expected by C++ GetStaticMethodID.
    final String bridgeKt;
    if (isEnum) {
      bridgeKt = 'Long';
    } else if (isNullableInt) {
      bridgeKt = 'ByteArray';
    } else if (isNullableDouble) {
      bridgeKt = 'ByteArray';
    } else if (isNullableBool) {
      bridgeKt = 'ByteArray';
    } else {
      bridgeKt = mapper.propertyType(propTypeName);
    }

    if (prop.hasGetter) {
      writer.line('    @JvmStatic fun ${prop.getSymbol}_call(instanceId: Long): $bridgeKt {');
      writer.line(
          '        val impl = _implementations[instanceId] ?: throw IllegalStateException("$dartClassName instance \$instanceId not registered")');
      if (isNullableEnum) {
        writer.line('        val _propVal = impl.${prop.dartName}');
        writer.line('        return if (_propVal == null) -1L else _propVal.nativeValue');
      } else if (isEnum) {
        writer.line('        return impl.${prop.dartName}.nativeValue');
      } else if (isNullableInt) {
        writer.line('        return NitroOptInt64(impl.${prop.dartName}).encode()');
      } else if (isNullableDouble) {
        writer.line('        return NitroOptFloat64(impl.${prop.dartName}).encode()');
      } else if (isNullableBool) {
        writer.line('        return NitroOptBool(impl.${prop.dartName}).encode()');
      } else {
        writer.line('        return impl.${prop.dartName}');
      }
      writer.line('    }');
    }

    if (prop.hasSetter) {
      writer.line('    @JvmStatic fun ${prop.setSymbol}_call(instanceId: Long, value: $bridgeKt) {');
      writer.line(
          '        val impl = _implementations[instanceId] ?: throw IllegalStateException("$dartClassName instance \$instanceId not registered")');
      if (isNullableEnum) {
        writer.line(
            '        impl.${prop.dartName} = if (value < 0L) null else $propBaseName.fromNative(value)');
      } else if (isEnum) {
        writer.line('        impl.${prop.dartName} = $propBaseName.fromNative(value)');
      } else if (isNullableInt) {
        writer.line('        impl.${prop.dartName} = NitroOptInt64.decode(value).nullable');
      } else if (isNullableDouble) {
        writer.line('        impl.${prop.dartName} = NitroOptFloat64.decode(value).nullable');
      } else if (isNullableBool) {
        writer.line('        impl.${prop.dartName} = NitroOptBool.decode(value).nullable');
      } else {
        writer.line('        impl.${prop.dartName} = value');
      }
      writer.line('    }');
    }
  }
}
