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

  if (spec.functions.any((f) => f.zeroCopyReturn && f.returnType.isTypedData)) {
    writer.line('NITRO_EXPORT void ${libStem}_release_typed_data_return(void* ptr) {');
    writer.line('    if (!ptr) return;');
    writer.line('    free(ptr);');
    writer.line('}');
    writer.blankLine();
  }

  for (final func in spec.functions) {
    final isEnum = enumNames.contains(func.returnType.name.replaceFirst('?', ''));
    final paramParts = <String>[];
    final callParamParts = <String>[];
    for (final p in func.params) {
      if (p.type.isFunction) {
        paramParts.add(CppBridgeGenerator._callbackParamToC(p, enumNames));
      } else {
        final isEnumParam = enumNames.contains(p.type.name.replaceFirst('?', ''));
        // Nullable primitives (int?/double?/bool?) use NitroNullable binary → void*.
        final pBase = p.type.name.replaceFirst('?', '');
        final isNullablePrim = (p.type.isNullable || p.type.name.endsWith('?')) &&
            (pBase == 'int' || pBase == 'double' || pBase == 'bool');
        final cType = isNullablePrim
            ? 'void*'
            : (isEnumParam ? 'int64_t' : CppBridgeGenerator._paramTypeToC(p.type.name, structNames));
        paramParts.add('$cType ${p.name}');
      }
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

    // Nullable primitives (int?/double?/bool?) use NitroNullable binary → uint8_t*.
    final retBase = func.returnType.name.replaceFirst('?', '');
    final isNullablePrimRet = (func.returnType.isNullable || func.returnType.name.endsWith('?')) &&
        (retBase == 'int' || retBase == 'double' || retBase == 'bool');
    final cReturnType = func.isResult
        ? 'uint8_t*'
        : isNullablePrimRet
        ? 'uint8_t*'
        : isEnum
        ? 'int64_t'
        : func.returnType.isTypedData
        ? 'uint8_t*'
        : CppBridgeGenerator._typeToC(func.returnType.name);
    // S8: add NitroError* out-param; the Swift @_cdecl stub does not use it,
    // but the C wrapper must accept and propagate it.
    final paramsWithErr = func.isAsync
        ? paramParts.join(', ')
        : [...paramParts, 'NitroError* _nitro_err'].join(', ');
    final params = paramParts.join(', ');
    final callParams = callParamParts.join(', ');
    writer.line('extern $cReturnType _${spec.namespace}_call_${func.dartName}(${params.isEmpty ? 'void' : params});');
    writer.line('$cReturnType ${func.cSymbol}($paramsWithErr) {');
    if (func.isAsync) {
      // @nitroAsync uses old TLS get_error/clear_error — declare _nitro_err as null
      // local so error handling code compiles (errors go to TLS instead).
      writer.line('    NitroError* _nitro_err = nullptr; // async: errors use TLS not out-param');
    } else {
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
    }
    writer.line('#ifdef __OBJC__');
    writer.line('    @try {');
    if (func.returnType.name != 'void') {
      writer.line('        return _${spec.namespace}_call_${func.dartName}($callParams);');
    } else {
      writer.line('        _${spec.namespace}_call_${func.dartName}($callParams);');
    }
    writer.line('    } @catch (NSException* e) {');
    writer.line('        if (_nitro_err) {');
    writer.line('            // sync: write exception to out-param error slot.');
    writer.line('            _nitro_err->hasError = 1;');
    writer.line('            _nitro_err->name    = strdup([e.name UTF8String]);');
    writer.line('            _nitro_err->message = strdup([e.reason UTF8String]);');
    writer.line('            _nitro_err->code = nullptr;');
    writer.line('            _nitro_err->stackTrace = nullptr;');
    writer.line('        } else {');
    writer.line('            // async: _nitro_err is null — route exception to TLS slot.');
    writer.line('            nitro_report_error([e.name UTF8String], [e.reason UTF8String], nullptr, nullptr);');
    writer.line('        }');
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
    final propPrimBase = prop.type.name.replaceFirst('?', '');
    final isNullablePrimProp = (prop.type.isNullable || prop.type.name.endsWith('?')) &&
        (propPrimBase == 'int' || propPrimBase == 'double' || propPrimBase == 'bool');
    // Nullable primitives use NitroNullable binary: getter→uint8_t*, setter→void*.
    final cType = isNullablePrimProp ? 'uint8_t*' : (isEnum ? 'int64_t' : CppBridgeGenerator._typeToC(prop.type.name));
    final setterCType = isNullablePrimProp ? 'void*' : (isEnum ? 'int64_t' : CppBridgeGenerator._typeToC(prop.type.name));
    if (prop.hasGetter) {
      writer.line('extern $cType _${spec.namespace}_call_get_${prop.dartName}(void);');
      // S8: getter receives NitroError* out-param.
      writer.line('$cType ${prop.getSymbol}(NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    return _${spec.namespace}_call_get_${prop.dartName}();');
      writer.line('}');
      writer.blankLine();
    }
    if (prop.hasSetter) {
      writer.line('extern void _${spec.namespace}_call_set_${prop.dartName}($setterCType value);');
      // S8: setter receives NitroError* out-param.
      writer.line('void ${prop.setSymbol}($setterCType value, NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
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

    if (stream.isBatch) {
      // Batch streams use an array emit: Swift accumulates items into a buffer,
      // then calls emitBatch(dartPort, items, count) which posts a Dart_CObject_kArray
      // so Dart receives a List<int> containing [count, item0, item1, ...].
      writer.line('bool _emit_${stream.dartName}_batch_to_dart(int64_t dartPort, const int64_t* items, int32_t count) {');
      writer.line('    const int32_t total = count + 1;');
      writer.line('    Dart_CObject* objs = (Dart_CObject*)malloc((size_t)total * sizeof(Dart_CObject));');
      writer.line('    Dart_CObject** ptrs = (Dart_CObject**)malloc((size_t)total * sizeof(Dart_CObject*));');
      writer.line('    if (!objs || !ptrs) { free(objs); free(ptrs); return false; }');
      writer.line('    objs[0].type = Dart_CObject_kInt64; objs[0].value.as_int64 = (int64_t)count; ptrs[0] = &objs[0];');
      writer.line('    for (int32_t i = 0; i < count; i++) {');
      writer.line('        objs[i+1].type = Dart_CObject_kInt64; objs[i+1].value.as_int64 = items[i]; ptrs[i+1] = &objs[i+1];');
      writer.line('    }');
      writer.line('    Dart_CObject arr; arr.type = Dart_CObject_kArray;');
      writer.line('    arr.value.as_array.length = (intptr_t)total; arr.value.as_array.values = ptrs;');
      writer.line('    bool result = Dart_PostCObject_DL(dartPort, &arr);');
      writer.line('    free(objs); free(ptrs);');
      writer.line('    return result;');
      writer.line('}');
      writer.blankLine();
      writer.line('extern void _${spec.namespace}_register_${stream.dartName}_stream(int64_t dartPort, bool (*emitBatch)(int64_t, const int64_t*, int32_t));');
      writer.line('void ${stream.registerSymbol}(int64_t dart_port) {');
      writer.line('    _${spec.namespace}_register_${stream.dartName}_stream(dart_port, _emit_${stream.dartName}_batch_to_dart);');
      writer.line('}');
      writer.line('extern void _${spec.namespace}_release_${stream.dartName}_stream(int64_t dart_port);');
      writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
      writer.line('    _${spec.namespace}_release_${stream.dartName}_stream(dart_port);');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    writer.line('bool _emit_${stream.dartName}_to_dart(int64_t dartPort, $itemCType item) {');
    writer.line('    Dart_CObject obj;');
    if (stream.itemType.name == 'double') {
      writer.line('    obj.type = Dart_CObject_kDouble;');
      writer.line('    obj.value.as_double = item;');
    } else if (stream.itemType.name == 'int') {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (int64_t)item;');
    } else if (stream.itemType.name == 'bool') {
      // Use kInt64 (0/1) — kBool is unreliable on some Android versions.
      // Dart stream unpack decodes: (message as int) != 0
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = item ? 1 : 0;');
    } else if (isEnum) {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (int64_t)item;');
    } else if (isStruct || isRecord) {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (intptr_t)item;');
    } else if (stream.itemType.name == 'String') {
      // String items: post kString when non-null, kNull for nullptr.
      // Dart_PostCObject_DL copies the string, so item (const char*) need not outlive the call.
      writer.line('    if (item != nullptr) {');
      writer.line('        obj.type = Dart_CObject_kString;');
      writer.line('        obj.value.as_string = const_cast<char*>(item);');
      writer.line('    } else {');
      writer.line('        obj.type = Dart_CObject_kNull;');
      writer.line('    }');
    } else {
      writer.line('    obj.type = Dart_CObject_kNull;');
    }
    writer.line('    return Dart_PostCObject_DL(dartPort, &obj);');
    writer.line('}');
    writer.blankLine();
    writer.line('extern void _${spec.namespace}_register_${stream.dartName}_stream(int64_t dartPort, bool (*emitCb)(int64_t, $itemCType));');
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
