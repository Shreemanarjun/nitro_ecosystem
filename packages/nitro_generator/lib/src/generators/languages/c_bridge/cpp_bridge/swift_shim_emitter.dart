part of '../cpp_bridge_generator.dart';

// Emits the extern "C" block that calls into Swift via _namespace_call_* symbols.
void _emitSwiftBridgeSection(
  CodeWriter writer,
  BridgeSpec spec,
  String libStem,
  Set<String> enumNames,
  Set<String> structNames,
) {
  writer.line('extern "C" {');

  for (final func in spec.functions) {
    final isEnum = enumNames.contains(func.returnType.name);
    final paramParts = <String>[];
    final callParamParts = <String>[];
    for (final p in func.params) {
      paramParts.add('${CppBridgeGenerator._paramTypeToC(p.type.name, structNames)} ${p.name}');
      callParamParts.add(p.name);
      if (p.type.isTypedData) {
        paramParts.add('int64_t ${p.name}_length');
        callParamParts.add('${p.name}_length');
      }
    }

    if (func.isNativeAsync) {
      paramParts.add('int64_t dart_port');
      callParamParts.add('dart_port');
      final params = paramParts.join(', ');
      final callParams = callParamParts.join(', ');
      writer.line('extern void _${spec.namespace}_call_${func.dartName}(${params.isEmpty ? 'void' : params});');
      writer.line('void ${func.cSymbol}($params) {');
      writer.line('    ${libStem}_clear_error();');
      writer.line('    _${spec.namespace}_call_${func.dartName}($callParams);');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    final cReturnType = isEnum
        ? 'int64_t'
        : func.returnType.isTypedData
        ? 'uint8_t*'
        : CppBridgeGenerator._typeToC(func.returnType.name);
    final params = paramParts.join(', ');
    final callParams = callParamParts.join(', ');
    writer.line('extern $cReturnType _${spec.namespace}_call_${func.dartName}(${params.isEmpty ? 'void' : params});');
    writer.line('$cReturnType ${func.cSymbol}(${params.isEmpty ? 'void' : params}) {');
    writer.line('    ${libStem}_clear_error();');
    writer.line('#ifdef __OBJC__');
    writer.line('    @try {');
    if (func.returnType.name != 'void') {
      writer.line('        return _${spec.namespace}_call_${func.dartName}($callParams);');
    } else {
      writer.line('        _${spec.namespace}_call_${func.dartName}($callParams);');
    }
    writer.line('    } @catch (NSException* e) {');
    writer.line('        nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);');
    if (func.returnType.name != 'void') {
      writer.line('        return ${CppBridgeGenerator._defaultValue(cReturnType)};');
    }
    writer.line('    }');
    writer.line('#else');
    if (func.returnType.name != 'void') {
      writer.line('    return _${spec.namespace}_call_${func.dartName}($callParams);');
    } else {
      writer.line('    _${spec.namespace}_call_${func.dartName}($callParams);');
    }
    writer.line('#endif');
    writer.line('}');
    writer.blankLine();
  }

  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(prop.type.name);
    final cType = isEnum ? 'int64_t' : CppBridgeGenerator._typeToC(prop.type.name);
    if (prop.hasGetter) {
      writer.line('extern $cType _${spec.namespace}_call_get_${prop.dartName}(void);');
      writer.line('$cType ${prop.getSymbol}(void) {');
      writer.line('    return _${spec.namespace}_call_get_${prop.dartName}();');
      writer.line('}');
      writer.blankLine();
    }
    if (prop.hasSetter) {
      final paramCType = isEnum ? 'int64_t' : CppBridgeGenerator._typeToC(prop.type.name);
      writer.line('extern void _${spec.namespace}_call_set_${prop.dartName}($paramCType value);');
      writer.line('void ${prop.setSymbol}($paramCType value) {');
      writer.line('    _${spec.namespace}_call_set_${prop.dartName}(value);');
      writer.line('}');
      writer.blankLine();
    }
  }

  for (final stream in spec.streams) {
    final isStruct = structNames.contains(stream.itemType.name);
    final isRecord = stream.itemType.isRecord;
    final isEnum = enumNames.contains(stream.itemType.name);
    final itemCType = (isStruct || isRecord) ? 'void*' : CppBridgeGenerator._typeToC(stream.itemType.name);
    writer.line('void _emit_${stream.dartName}_to_dart(int64_t dartPort, $itemCType item) {');
    writer.line('    Dart_CObject obj;');
    if (stream.itemType.name == 'double') {
      writer.line('    obj.type = Dart_CObject_kDouble;');
      writer.line('    obj.value.as_double = item;');
    } else if (stream.itemType.name == 'int') {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (int64_t)item;');
    } else if (stream.itemType.name == 'bool') {
      writer.line('    obj.type = Dart_CObject_kBool;');
      writer.line('    obj.value.as_bool = item;');
    } else if (isEnum) {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (int64_t)item;');
    } else if (isStruct || isRecord) {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (intptr_t)item;');
    } else {
      writer.line('    obj.type = Dart_CObject_kNull;');
    }
    writer.line('    Dart_PostCObject_DL(dartPort, &obj);');
    writer.line('}');
    writer.blankLine();
    writer.line('extern void _${spec.namespace}_register_${stream.dartName}_stream(int64_t dartPort, void (*emitCb)(int64_t, $itemCType));');
    writer.line('void ${stream.registerSymbol}(int64_t dart_port) {');
    writer.line('    _${spec.namespace}_register_${stream.dartName}_stream(dart_port, _emit_${stream.dartName}_to_dart);');
    writer.line('}');
    writer.line('extern void _${spec.namespace}_release_${stream.dartName}_stream(int64_t dart_port);');
    writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
    writer.line('    _${spec.namespace}_release_${stream.dartName}_stream(dart_port);');
    writer.line('}');
    writer.blankLine();
  }

  writer.line('} // extern "C"');
}
