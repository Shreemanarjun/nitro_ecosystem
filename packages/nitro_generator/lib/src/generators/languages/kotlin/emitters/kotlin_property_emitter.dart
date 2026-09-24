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
    if (!prop.getMainThread && !prop.setMainThread) return _emit(writer, prop, dartClassName, mapper);
    // @mainThread accessors: each getter branch reads `impl.x`, each setter
    // branch is one `impl.x = …` line, so the hop wraps exactly that access.
    final raw = CodeWriter();
    _emit(raw, prop, dartClassName, mapper);
    const main = 'kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.Main.immediate)';
    final access = 'impl.${prop.dartName}';
    var inGetter = false;
    for (final line in raw.toString().trimRight().split('\n')) {
      if (line.contains('fun ${prop.getSymbol}_call(')) inGetter = true;
      if (line.contains('fun ${prop.setSymbol}_call(')) inGetter = false;
      if (inGetter && prop.getMainThread) {
        if (line.trimLeft().startsWith('val impl = ')) {
          writer.line(line);
          writer.line('        val _mainValue = $main { $access }');
          continue;
        }
        writer.line(line.replaceAll(RegExp('${RegExp.escape(access)}\\b'), '_mainValue'));
      } else if (!inGetter && prop.setMainThread && line.trimLeft().startsWith('$access = ')) {
        final indent = line.substring(0, line.indexOf(access));
        writer.line('$indent$main { ${line.trimLeft()} }');
      } else {
        writer.line(line);
      }
    }
  }

  static void _emit(
    CodeWriter writer,
    BridgeProperty prop,
    String dartClassName,
    KotlinTypeMapper mapper,
  ) {
    final propTypeName = prop.type.name;
    final propBaseName = bareTypeName(propTypeName);
    final isNullableProp = propTypeName.endsWith('?');
    final isEnum = mapper.enumNames.contains(propBaseName);
    final isNullableEnum = isEnum && isNullableProp;
    final isNullableInt = propBaseName == 'int' && isNullableProp;
    final isNullableDouble = propBaseName == 'double' && isNullableProp;
    final isNullableBool = propBaseName == 'bool' && isNullableProp;
    // DateTime? uses the same NitroOptInt64 ByteArray wire as int?.
    final isNullableDateTime = propBaseName == 'DateTime' && isNullableProp;
    final isVariant = mapper.variantNames.contains(propBaseName);

    // _call bridge type must match the JVM descriptor expected by C++ GetStaticMethodID.
    final String bridgeKt;
    if (isEnum) {
      bridgeKt = 'Long';
    } else if (isNullableInt || isNullableDateTime) {
      bridgeKt = 'ByteArray';
    } else if (isNullableDouble) {
      bridgeKt = 'ByteArray';
    } else if (isNullableBool) {
      bridgeKt = 'ByteArray';
    } else if (isVariant) {
      bridgeKt = 'ByteArray'; // [4B len][1B tag][fields]
    } else {
      bridgeKt = mapper.propertyType(propTypeName);
    }

    if (prop.hasGetter) {
      writer.line('    @JvmStatic fun ${prop.getSymbol}_call(instanceId: Long): $bridgeKt {');
      writer.line('        val impl = _implementations[instanceId] ?: throw IllegalStateException("$dartClassName instance \$instanceId not registered")');
      if (isNullableEnum) {
        writer.line('        val _propVal = impl.${prop.dartName}');
        writer.line('        return if (_propVal == null) -1L else _propVal.nativeValue');
      } else if (isEnum) {
        writer.line('        return impl.${prop.dartName}.nativeValue');
      } else if (isNullableInt || isNullableDateTime) {
        writer.line('        return NitroOptInt64(impl.${prop.dartName}).encode()');
      } else if (isNullableDouble) {
        writer.line('        return NitroOptFloat64(impl.${prop.dartName}).encode()');
      } else if (isNullableBool) {
        writer.line('        return NitroOptBool(impl.${prop.dartName}).encode()');
      } else if (isVariant) {
        writer.line('        val _vResult = impl.${prop.dartName}');
        writer.line('        val _vw = RecordWriter()');
        writer.line('        _vResult.writeFields(_vw)');
        writer.line('        val _vPayload = _vw.toByteArray()');
        writer.line('        val _vBuf = java.nio.ByteBuffer.allocate(4 + _vPayload.size).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        _vBuf.putInt(_vPayload.size)');
        writer.line('        _vBuf.put(_vPayload)');
        writer.line('        return _vBuf.array()');
      } else {
        writer.line('        return impl.${prop.dartName}');
      }
      writer.line('    }');
    }

    if (prop.hasSetter) {
      writer.line('    @JvmStatic fun ${prop.setSymbol}_call(instanceId: Long, value: $bridgeKt) {');
      writer.line('        val impl = _implementations[instanceId] ?: throw IllegalStateException("$dartClassName instance \$instanceId not registered")');
      if (isNullableEnum) {
        writer.line('        impl.${prop.dartName} = if (value < 0L) null else $propBaseName.fromNative(value)');
      } else if (isEnum) {
        writer.line('        impl.${prop.dartName} = $propBaseName.fromNative(value)');
      } else if (isNullableInt || isNullableDateTime) {
        writer.line('        impl.${prop.dartName} = NitroOptInt64.decode(value).nullable');
      } else if (isNullableDouble) {
        writer.line('        impl.${prop.dartName} = NitroOptFloat64.decode(value).nullable');
      } else if (isNullableBool) {
        writer.line('        impl.${prop.dartName} = NitroOptBool.decode(value).nullable');
      } else if (isVariant) {
        writer.line('        val valueBuf = java.nio.ByteBuffer.wrap(value).order(java.nio.ByteOrder.LITTLE_ENDIAN)');
        writer.line('        valueBuf.getInt() // skip 4-byte length prefix');
        writer.line('        val valueDecoded = $propBaseName.fromReader(RecordReader(valueBuf))');
        writer.line('        impl.${prop.dartName} = valueDecoded');
      } else {
        writer.line('        impl.${prop.dartName} = value');
      }
      writer.line('    }');
    }
  }
}
