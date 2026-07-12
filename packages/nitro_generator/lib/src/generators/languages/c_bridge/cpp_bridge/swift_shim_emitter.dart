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
    final retBase = func.returnType.name.replaceFirst('?', '');
    final isEnum = enumNames.contains(retBase);
    final isVariantRet = spec.isVariantName(retBase);
    // instanceId is the first param for API consistency with the JNI path; Swift ignores it.
    final paramParts = <String>['int64_t instanceId'];
    // externParamParts: typed params for the Swift @_cdecl extern declaration (no instanceId).
    final externParamParts = <String>[];
    // callParamParts: just names for calling the Swift extern.
    final callParamParts = <String>[];
    for (final p in func.params) {
      if (p.type.isFunction) {
        final cbType = CppBridgeGenerator._callbackParamToC(p, enumNames);
        paramParts.add(cbType);
        externParamParts.add(cbType);
      } else {
        final isEnumParam = enumNames.contains(p.type.name.replaceFirst('?', ''));
        // Nullable primitives: raw byte pointer (matches Swift UnsafeMutablePointer<UInt8>? @_cdecl param).
        String cType;
        if (p.type.isNullableNitroPrim) {
          cType = 'const uint8_t*';
        } else {
          cType = isEnumParam ? 'int64_t' : CppBridgeGenerator._paramTypeToC(p.type.name, structNames);
        }
        paramParts.add('$cType ${p.name}');
        externParamParts.add('$cType ${p.name}');
      }
      callParamParts.add(p.name);
      if (p.type.isTypedData) {
        paramParts.add('size_t ${p.name}_length');
        externParamParts.add('size_t ${p.name}_length');
        callParamParts.add('${p.name}_length');
      }
    }

    if (func.isNativeAsync) {
      // NitroError* is a fresh-per-call slot Dart allocated (see
      // NitroRuntime.throwIfOutParamErrorAndFree) — pure passthrough here,
      // no @try/@catch: this wrapper returns before Swift's Task.detached
      // body runs, so it structurally can't catch anything the impl throws
      // asynchronously. Swift's own do/catch (in the @_cdecl function this
      // calls) writes into the struct directly via its address.
      paramParts.add('NitroError* _nitro_err');
      paramParts.add('int64_t dart_port');
      externParamParts.add('int64_t err_ptr');
      externParamParts.add('int64_t dart_port');
      callParamParts.add('(int64_t)(uintptr_t)_nitro_err');
      callParamParts.add('dart_port');
      final params = paramParts.join(', ');
      final externParams = externParamParts.join(', ');
      final callParams = callParamParts.join(', ');
      writer.line('extern void _${spec.namespace}_call_${func.dartName}(${externParams.isEmpty ? 'void' : externParams});');
      writer.line('void ${func.cSymbol}($params) {');
      writer.line('    ${libStem}_clear_error();');
      writer.line('    _${spec.namespace}_call_${func.dartName}($callParams);');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    // Nullable prim returns: raw byte pointer (matches Swift UnsafeMutablePointer<UInt8>? @_cdecl return).
    final cReturnType = func.isResult
        ? 'uint8_t*'
        : isVariantRet
        ? 'uint8_t*'
        : func.returnType.name == 'int?'
        ? 'uint8_t*'
        : func.returnType.name == 'uint64?'
        ? 'uint8_t*'
        : func.returnType.name == 'double?'
        ? 'uint8_t*'
        : func.returnType.name == 'bool?'
        ? 'uint8_t*'
        : func.returnType.name == 'DateTime?'
        ? 'uint8_t*'
        : isEnum
        ? 'int64_t'
        : func.returnType.isTypedData
        ? 'uint8_t*'
        : CppBridgeGenerator._typeToC(func.returnType.name);
    // S8: add NitroError* out-param; the Swift @_cdecl stub does not use it,
    // but the C wrapper must accept and propagate it.
    final paramsWithErr = func.isAsync ? paramParts.join(', ') : [...paramParts, 'NitroError* _nitro_err'].join(', ');
    final externParams = externParamParts.join(', ');
    final callParams = callParamParts.join(', ');
    writer.line('extern $cReturnType _${spec.namespace}_call_${func.dartName}(${externParams.isEmpty ? 'void' : externParams});');
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
    final propBase = prop.type.name.replaceFirst('?', '');
    final isEnum = enumNames.contains(propBase);
    final isVariantProp = spec.isVariantName(propBase);
    // Property getter: nullable prim/variant returns pointer; setter receives typed pointer.
    String cType;
    String setterCType;
    if (isEnum) {
      cType = 'int64_t';
      setterCType = 'int64_t';
    } else if (isVariantProp) {
      cType = 'uint8_t*';
      setterCType = 'const uint8_t*';
    } else {
      switch (prop.type.name) {
        case 'int?':
          cType = 'uint8_t*';
          setterCType = 'const uint8_t*';
          break;
        case 'uint64?':
          cType = 'uint8_t*';
          setterCType = 'const uint8_t*';
          break;
        case 'double?':
          cType = 'uint8_t*';
          setterCType = 'const uint8_t*';
          break;
        case 'bool?':
          cType = 'uint8_t*';
          setterCType = 'const uint8_t*';
          break;
        default:
          cType = CppBridgeGenerator._typeToC(prop.type.name);
          setterCType = cType;
      }
    }
    if (prop.hasGetter) {
      writer.line('extern $cType _${spec.namespace}_call_get_${prop.dartName}(void);');
      // S8: getter receives NitroError* out-param; instanceId for API consistency (Point 13).
      writer.line('$cType ${prop.getSymbol}(int64_t instanceId, NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    return _${spec.namespace}_call_get_${prop.dartName}();');
      writer.line('}');
      writer.blankLine();
    }
    if (prop.hasSetter) {
      writer.line('extern void _${spec.namespace}_call_set_${prop.dartName}($setterCType value);');
      // S8: setter receives NitroError* out-param; instanceId for API consistency (Point 13).
      writer.line('void ${prop.setSymbol}(int64_t instanceId, $setterCType value, NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    _${spec.namespace}_call_set_${prop.dartName}(value);');
      writer.line('}');
      writer.blankLine();
    }
  }

  for (final stream in spec.streams) {
    final isNullable = stream.itemType.isNullable;
    final itemName = stream.itemType.name.replaceFirst('?', '');
    final isStruct = structNames.contains(itemName);
    final isRecord = stream.itemType.isRecord;
    final isEnum = enumNames.contains(itemName);
    final isVariant = spec.isVariantName(itemName);

    // For nullable scalar types (int?, double?, bool?, enum?), use pointer types so
    // Swift can pass nil for null items. The C emit function checks nullptr → kNull.
    // String? already uses const char* (nullable by design).
    final String itemCType;
    if (isNullable && itemName == 'int') {
      itemCType = 'const int64_t*';
    } else if (isNullable && itemName == 'uint64') {
      itemCType = 'const uint64_t*';
    } else if (isNullable && itemName == 'double') {
      itemCType = 'const double*';
    } else if (isNullable && itemName == 'bool') {
      itemCType = 'const int8_t*';
    } else if (isNullable && isEnum) {
      itemCType = 'const int64_t*';
    } else if (isStruct || isRecord || isVariant) {
      itemCType = 'void*';
    } else {
      itemCType = CppBridgeGenerator._typeToC(stream.itemType.name);
    }

    if (stream.isBatch) {
      if (isRecord || isVariant) {
        // Record/variant batches: Swift emits [4B outer_len][4B count][item bytes...] as kTypedData/kUint8.
        // Dart receives Uint8List and decodes with RecordReader.decodeList.
        writer.line('bool _emit_${stream.dartName}_bytes_batch_to_dart(int64_t dartPort, const uint8_t* bytes, int32_t len) {');
        writer.line('    Dart_CObject obj;');
        writer.line('    obj.type = Dart_CObject_kTypedData;');
        writer.line('    obj.value.as_typed_data.type = Dart_TypedData_kUint8;');
        writer.line('    obj.value.as_typed_data.length = (intptr_t)len;');
        writer.line('    obj.value.as_typed_data.values = (uint8_t*)bytes;');
        writer.line('    return Dart_PostCObject_DL(dartPort, &obj);');
        writer.line('}');
        writer.blankLine();
        writer.line('extern void _${spec.namespace}_register_${stream.dartName}_stream(int64_t dartPort, bool (*emitBatch)(int64_t, const uint8_t*, int32_t));');
        writer.line('void ${stream.registerSymbol}(int64_t instanceId, int64_t dart_port) {');
        writer.line('    _${spec.namespace}_register_${stream.dartName}_stream(dart_port, _emit_${stream.dartName}_bytes_batch_to_dart);');
        writer.line('}');
      } else {
        // Numeric batches: [count, item0, item1, ...] as Dart_CObject_kArray of kInt64.
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
        writer.line('void ${stream.registerSymbol}(int64_t instanceId, int64_t dart_port) {');
        writer.line('    _${spec.namespace}_register_${stream.dartName}_stream(dart_port, _emit_${stream.dartName}_batch_to_dart);');
        writer.line('}');
      }
      writer.line('extern void _${spec.namespace}_release_${stream.dartName}_stream(int64_t dart_port);');
      writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
      writer.line('    _${spec.namespace}_release_${stream.dartName}_stream(dart_port);');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    writer.line('bool _emit_${stream.dartName}_to_dart(int64_t dartPort, $itemCType item) {');
    writer.line('    Dart_CObject obj;');
    if (isNullable && (itemName == 'int' || isEnum)) {
      // Nullable int/enum: pointer to int64_t, nullptr = null.
      writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
      writer.line('    else { obj.type = Dart_CObject_kInt64; obj.value.as_int64 = *item; }');
    } else if (isNullable && itemName == 'uint64') {
      // Nullable uint64: pointer to uint64_t, nullptr = null; post as kInt64 (same bits).
      writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
      writer.line('    else { obj.type = Dart_CObject_kInt64; obj.value.as_int64 = (int64_t)*item; }');
    } else if (isNullable && itemName == 'double') {
      writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
      writer.line('    else { obj.type = Dart_CObject_kDouble; obj.value.as_double = *item; }');
    } else if (isNullable && itemName == 'bool') {
      writer.line('    if (item == nullptr) { obj.type = Dart_CObject_kNull; }');
      writer.line('    else { obj.type = Dart_CObject_kInt64; obj.value.as_int64 = *item ? 1 : 0; }');
    } else if (stream.itemType.name == 'double') {
      writer.line('    obj.type = Dart_CObject_kDouble;');
      writer.line('    obj.value.as_double = item;');
    } else if (stream.itemType.name == 'int' || stream.itemType.name == 'uint64') {
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
    } else if (isStruct || isRecord || isVariant) {
      // Pointer (struct/record/variant bytes) — post address as kInt64; Dart frees after decode.
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (intptr_t)item;');
    } else if (stream.itemType.name == 'String' || stream.itemType.name == 'String?') {
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
    writer.line('void ${stream.registerSymbol}(int64_t instanceId, int64_t dart_port) {');
    writer.line('    _${spec.namespace}_register_${stream.dartName}_stream(dart_port, _emit_${stream.dartName}_to_dart);');
    writer.line('}');
    writer.line('extern void _${spec.namespace}_release_${stream.dartName}_stream(int64_t dart_port);');
    writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
    writer.line('    _${spec.namespace}_release_${stream.dartName}_stream(dart_port);');
    writer.line('}');
    writer.blankLine();
  }

  // Swift/iOS single-instance path: create_instance returns a monotonic id (instanceId
  // is unused by Swift, but must be consistent with what Dart stored). destroy_instance
  // is a no-op — Swift manages its own lifetime via ARC.
  writer.line('static int64_t ${libStem}_g_next_instance_id = 0;');
  writer.line('NITRO_EXPORT int64_t ${libStem}_create_instance(const char* key) { (void)key; return ${libStem}_g_next_instance_id++; }');
  writer.line('NITRO_EXPORT void ${libStem}_destroy_instance(int64_t instanceId) { (void)instanceId; }');
  // Universal free for native-owned memory handed to Dart. Dart must not use
  // package:ffi's malloc.free on these pointers (CoTaskMemFree on Windows).
  writer.line('NITRO_EXPORT void ${libStem}_nitro_free(void* ptr) { if (ptr) { free(ptr); } }');
  // Matching allocator for Dart-produced values that native code frees
  // (String/record/variant callback returns) — same rule in reverse.
  writer.line('NITRO_EXPORT void* ${libStem}_nitro_alloc(size_t size) { return malloc(size); }');
  writer.blankLine();

  writer.line('} // extern "C"');
}
