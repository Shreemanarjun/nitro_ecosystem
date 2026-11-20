part of '../cpp_bridge_generator.dart';

// The C++ dispatch block of a MIXED module: the exports that call a C++
// implementation on Apple (iOS / macOS = NativeImpl.cpp) and on desktop
// (Windows / Linux), next to the JNI and Swift-shim blocks of the same file.
// An all-C++ module is emitted by cpp_direct_emitter.dart instead.

// ── Apple C++ dispatch section emitter ────────────────────────────────────
// Emits the virtual-dispatch bridge for an Apple platform using NativeImpl.cpp.
// Headers and global error state are already emitted before this is called.
// Struct release functions are emitted globally in the JNI section — not here.
void _emitAppleCppDispatch(
  CodeWriter writer,
  BridgeSpec spec,
  String libStem,
  Set<String> enumNames,
  Set<String> structNames,
) {
  final className = spec.dartClassName;
  final ifaceHeader = '$libStem.native.g.h';
  final recordNames = spec.recordTypes.map((r) => r.name).toSet();
  final variantNames = spec.variants.map((v) => v.name).toSet();

  writer.line('#include "$ifaceHeader"');
  writer.blankLine();

  _emitStreamPortRegistry(writer, spec);

  _emitCppStreamEmitters(writer, spec, className, enumNames, structNames, variantNames);

  final notInit =
      'nitro_report_error("NotInitialized", '
      '"No C++ implementation registered. Call ${libStem}_register_impl() first.", '
      'nullptr, nullptr)';
  // S8: sync functions report through the NitroError* out-param — that is
  // the ONLY slot the generated Dart reads (throwIfOutParamError). The TLS
  // slot is kept in sync for the legacy get_error() accessor. Fields are
  // strdup'd; Dart frees them after copying (see throwIfOutParamError).
  final notInitOut =
      '_nitro_desktop_err(_nitro_err, "NotInitialized", '
      '"No C++ implementation registered. Call ${libStem}_register_impl() first.")';

  writer.line('static void _nitro_desktop_err(NitroError* _out, const char* _name, const char* _message) {');
  writer.line('    nitro_report_error(_name, _message, nullptr, nullptr);');
  writer.line('    if (_out) {');
  writer.line('        _out->hasError = 1;');
  writer.line('        _out->name = _name ? strdup(_name) : nullptr;');
  writer.line('        _out->message = _message ? strdup(_message) : nullptr;');
  writer.line('        _out->code = nullptr;');
  writer.line('        _out->stackTrace = nullptr;');
  writer.line('    }');
  writer.line('}');
  writer.blankLine();

  if (spec.functions.any((f) => f.isResult)) _emitCppResultHelpers(writer);
  // One Hybrid<Class> per instance, exactly as the JNI path does — a plugin
  // that targets native AND web/desktop used to collapse every instance onto
  // a single global impl here, so two instances shared all state.
  // register_impl() still works: it parks a raw pointer at slot 0.
  _emitInstanceRegistry(writer, libStem, className);
  // Universal free for native-owned memory handed to Dart. Dart must not use
  // package:ffi's malloc.free on these pointers (CoTaskMemFree on Windows).
  writer.line('NITRO_EXPORT void ${libStem}_nitro_free(void* ptr) { if (ptr) { free(ptr); } }');
  _emitNitroAdopt(writer, spec, libStem);
  // Matching allocator for Dart-produced values that native code frees
  // (String/record/variant callback returns) — same rule in reverse.
  writer.line('NITRO_EXPORT void* ${libStem}_nitro_alloc(size_t size) { return malloc(size); }');
  if (spec.hasZeroCopyTypedDataReturn) {
    writer.line('NITRO_EXPORT void ${libStem}_release_typed_data_return(void* ptr) {');
    writer.line('    if (!ptr) { return; }');
    // Envelope layout: [0]=byte length, [1]=payload pointer, [2]=owner
    // (always 0 on this path — the JNI variant stores a global ref there
    // instead). The impl's malloc'd payload transfers to Dart at return;
    // this call is Dart's NativeFinalizer saying it is done with the view,
    // so BOTH the payload and the envelope are released here. Freeing only
    // the envelope leaked the payload on every @zeroCopy return — found by
    // the ASan/LSan harness (2000 iterations x 4096B = exactly the
    // 8,192,000B it reported).
    writer.line('    int64_t* words = (int64_t*)ptr;');
    writer.line('    void* payload = (void*)(intptr_t)words[1];');
    // Empty buffers use the envelope's own address as a non-null data
    // sentinel — never double-free it.
    writer.line('    if (payload && payload != ptr) { free(payload); }');
    writer.line('    free(ptr);');
    writer.line('}');
  }
  writer.blankLine();

  for (final func in spec.functions) {
    if (func.isNativeAsync) {
      // instanceId selects the Hybrid<Class> for this instance, as on JNI.
      final paramParts = <String>['int64_t instanceId'];
      for (final p in func.params) {
        final isStructParam = structNames.contains(bareTypeName(p.type.name));
        final isRecordParam = recordNames.contains(bareTypeName(p.type.name));
        final isEnumParam = enumNames.contains(bareTypeName(p.type.name));
        // Maps stay on _typeToC (uint8_t*) — matches the bridge.g.h declaration.
        final isMapParam = p.type.name.startsWith('Map<');
        if (p.type.isFunction) {
          // Must match the sync path's declared C type exactly (_callbackParamToC) —
          // the .h forward-declares this symbol once, unconditionally, so a
          // mismatched definition here is an illegal extern "C" redeclaration.
          paramParts.add(_callbackParamToC(p, enumNames, structNames: structNames, recordNames: recordNames, variantNames: variantNames));
        } else if (spec.isCustomTypeName(bareTypeName(p.type.name))) {
          // Must match cpp_header_generator.dart's declaration exactly
          // (const uint8_t*, not the void* _typeToC's default would give a
          // user-defined type name) — same "conflicting types" risk as the
          // callback case just above.
          paramParts.add('const uint8_t* ${p.name}');
        } else {
          paramParts.add('${(isStructParam || (isRecordParam && !isMapParam)) ? 'void*' : (isEnumParam ? 'int64_t' : _typeToC(p.type.name))} ${p.name}');
        }
        if (p.type.isTypedData) paramParts.add('size_t ${p.name}_length'); // matches Dart FFI Size type
      }
      paramParts.add('NitroError* _nitro_err');
      paramParts.add('int64_t dart_port');
      final paramsDecl = paramParts.join(', ');

      writer.line('void ${func.cSymbol}($paramsDecl) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    auto _impl = _nitro_get_instance(instanceId);');
      writer.line('    if (!_impl) {');
      writer.line('        _nitro_desktop_err(_nitro_err, "NotInitialized", "No C++ implementation registered.");');
      writer.line('        Dart_CObject _err = { Dart_CObject_kNull };');
      writer.line('        Dart_PostCObject_DL(dart_port, &_err);');
      writer.line('        return;');
      writer.line('    }');
      writer.line('    try {');

      // Built inside the try block (not before it, unlike the simpler params
      // above) because callback params need writer.line-emitted setup code
      // (an adapter lambda) ahead of the call expression — mirrors the sync
      // path's ordering just below.
      final callArgs = <String>[];
      for (final p in func.params) {
        final base = bareTypeName(p.type.name);
        final isNullableParam = p.type.isNullable || p.type.name.endsWith('?');
        switch (p.type.name) {
          case _ when p.type.isFunction:
            callArgs.add(
              _emitDesktopCallbackWrapper(
                writer,
                spec,
                p,
                enumNames,
                structNames,
                recordNames,
                variantNames,
              ),
            );
          case _ when p.type.isAnyNativeObject:
            if (p.type.isNullable) {
              callArgs.add('${p.name} == -1 ? std::optional<int64_t>(std::nullopt) : std::make_optional<int64_t>(${p.name})');
            } else {
              callArgs.add(p.name);
            }
          case _ when spec.isCustomTypeName(base):
            callArgs.add(p.name);
          case 'int?' || 'DateTime?':
            callArgs.add('(${p.name} == nullptr || ${p.name}[0] == 0) ? std::optional<int64_t>(std::nullopt) : std::make_optional(*reinterpret_cast<const int64_t*>(${p.name} + 1))');
          case 'uint64?':
            callArgs.add('(${p.name} == nullptr || ${p.name}[0] == 0) ? std::optional<uint64_t>(std::nullopt) : std::make_optional(*reinterpret_cast<const uint64_t*>(${p.name} + 1))');
          case 'double?':
            callArgs.add('(${p.name} == nullptr || ${p.name}[0] == 0) ? std::optional<double>(std::nullopt) : std::make_optional(*reinterpret_cast<const double*>(${p.name} + 1))');
          case 'bool?':
            callArgs.add('(${p.name} == nullptr || ${p.name}[0] == 0) ? std::optional<bool>(std::nullopt) : std::make_optional(${p.name}[1] != 0)');
          case _ when base == 'String':
            if (isNullableParam) {
              callArgs.add('${p.name} == nullptr ? std::optional<std::string>(std::nullopt) : std::make_optional(std::string(${p.name}))');
            } else {
              callArgs.add('std::string(${p.name})');
            }
          case _ when structNames.contains(base):
            if (isNullableParam) {
              callArgs.add('${p.name} == nullptr ? std::optional<$base>(std::nullopt) : std::make_optional(*static_cast<const $base*>(${p.name}))');
            } else {
              callArgs.add('*static_cast<const $base*>(${p.name})');
            }
          case _ when p.type.isRecord || variantNames.contains(base):
            // Covers bare records/variants AND List<T>/Map<K,V> (any item/value
            // type — record, enum, variant, or primitive), which all share the
            // same generic [4B len][payload] wire format. A nullable single
            // record/variant param arrives as nullptr when the Dart caller
            // omits it — the length-prefix deref below would segfault
            // unguarded. Mirrors the already-correct sync-path guard elsewhere
            // in this file (this is the SAME condition it uses).
            if (isNullableParam) {
              callArgs.add('${p.name} == nullptr ? NitroCppBuffer{ nullptr, 0 } : NitroCppBuffer{ (const uint8_t*)${p.name} + 4, (size_t)*(int32_t*)${p.name} }');
            } else {
              callArgs.add('NitroCppBuffer{ (const uint8_t*)${p.name} + 4, (size_t)*(int32_t*)${p.name} }');
            }
          case _ when p.type.isTypedData:
            callArgs.add(p.name);
            callArgs.add('static_cast<size_t>(${p.name}_length)');
          case _ when enumNames.contains(base):
            if (isNullableParam) {
              callArgs.add('${p.name} == -1 ? std::optional<$base>(std::nullopt) : std::make_optional(static_cast<$base>(${p.name}))');
            } else {
              callArgs.add('static_cast<$base>(${p.name})');
            }
          default:
            callArgs.add(p.name);
        }
      }
      // Fire-and-forget (void @nitroNativeAsync, issue #58): the impl is a
      // plain `void method(params)` — no NitroError*/dart_port. The <sym> keeps
      // its posting signature (so <sym>_fnf's ABI is unchanged) but hands the
      // impl only its real params; any error/no-impl post targets dart_port=0
      // (a harmless no-op, since _fnf always passes 0).
      if (!spec.fireAndForget(func)) {
        callArgs.add('_nitro_err');
        callArgs.add('dart_port');
      }
      writer.line('        _impl->${func.dartName}(${callArgs.join(', ')});');
      writer.line('    } catch (const std::exception& e) {');
      writer.line('        _nitro_desktop_err(_nitro_err, "CppException", e.what());');
      writer.line('        Dart_CObject _err = { Dart_CObject_kNull };');
      writer.line('        Dart_PostCObject_DL(dart_port, &_err);');
      writer.line('    } catch (...) {');
      writer.line('        _nitro_desktop_err(_nitro_err, "CppException", "Unknown C++ exception");');
      writer.line('        Dart_CObject _err = { Dart_CObject_kNull };');
      writer.line('        Dart_PostCObject_DL(dart_port, &_err);');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    final retBase = bareTypeName(func.returnType.name);
    final isEnumRet = enumNames.contains(retBase);
    final isStructRet = structNames.contains(retBase);
    final isVariantRet = variantNames.contains(retBase);
    final isRecordRet = func.returnType.isRecord && !isVariantRet;
    final isZeroCopyTypedDataRet = func.zeroCopyReturn && func.returnType.isTypedData;
    final isCustomTypeRet = spec.isCustomTypeName(retBase);
    // Nullable prim returns: malloc'd uint8_t* pointer (Dart casts to Pointer<NitroOptXxx> and frees).
    // @NitroResult returns: malloc'd [1B tag][4B len][payload] blob.
    final cRet = func.isResult
        ? 'uint8_t*'
        : func.returnType.isAnyNativeObject
        ? 'int64_t'
        : isCustomTypeRet
        ? 'uint8_t*'
        : isVariantRet
        ? 'uint8_t*'
        : isEnumRet
        ? 'int64_t'
        : func.returnType.name == 'int?'
        ? 'uint8_t*'
        : func.returnType.name == 'double?'
        ? 'uint8_t*'
        : func.returnType.name == 'bool?'
        ? 'uint8_t*'
        : func.returnType.name == 'DateTime?'
        ? 'uint8_t*'
        : func.returnType.name == 'uint64?'
        ? 'uint8_t*'
        : func.returnType.isTypedData
        ? 'uint8_t*'
        : _typeToC(func.returnType.name);
    // Result methods must never return nullptr — Dart reads res[0] unconditionally.
    final dflt = func.isResult ? '_nitro_desktop_result_err("native error")' : _defaultValue(cRet);
    // instanceId selects the Hybrid<Class> for this instance, as on JNI.
    final paramParts = <String>['int64_t instanceId'];
    for (final p in func.params) {
      final isStructParam = structNames.contains(bareTypeName(p.type.name));
      final isRecordParam = p.type.isRecord;
      final isEnumParam = enumNames.contains(bareTypeName(p.type.name));
      if (p.type.isFunction) {
        paramParts.add(_callbackParamToC(p, enumNames, structNames: structNames, recordNames: recordNames, variantNames: variantNames));
      } else if (spec.isCustomTypeName(bareTypeName(p.type.name))) {
        // Must match cpp_header_generator.dart's declaration exactly
        // (const uint8_t*, not the void* _typeToC's default would give a
        // user-defined type name).
        paramParts.add('const uint8_t* ${p.name}');
      } else {
        // Nullable prims use const uint8_t* (raw byte pointer via NitroOptXxx layout).
        // Maps stay on _typeToC (uint8_t*) — matches the bridge.g.h declaration.
        final isMapParam = p.type.name.startsWith('Map<');
        final cType = isEnumParam ? 'int64_t' : ((isStructParam || (isRecordParam && !isMapParam)) ? 'void*' : _typeToC(p.type.name));
        paramParts.add('$cType ${p.name}');
      }
      if (p.type.isTypedData) paramParts.add('size_t ${p.name}_length'); // matches Dart FFI Size type
    }
    // S8: sync functions also receive NitroError* out-param for consistency with the JNI path.
    if (!func.isAsync) {
      paramParts.add('NitroError* _nitro_err');
    }
    final paramsDecl = paramParts.join(', ');

    writer.line('$cRet ${func.cSymbol}($paramsDecl) {');
    writer.line('    ${libStem}_clear_error();');
    if (!func.isAsync) {
      // S8: the Dart-side slot is what throwIfOutParamError reads — clear
      // it on entry (the slot is calloc'd, but never rely on that alone).
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }  // S8: clear slot');
    }
    final funcNotInit = func.isAsync ? notInit : notInitOut;
    if (func.returnType.name == 'void') {
      writer.line('    auto _impl = _nitro_get_instance(instanceId);');
      writer.line('    if (!_impl) { $funcNotInit; return; }');
    } else {
      writer.line('    auto _impl = _nitro_get_instance(instanceId);');
      writer.line('    if (!_impl) { $funcNotInit; return $dflt; }');
    }
    writer.line('    try {');
    final callArgs = <String>[];
    for (final p in func.params) {
      final base = bareTypeName(p.type.name);
      final isNullableParam = p.type.isNullable || p.type.name.endsWith('?');
      switch (p.type.name) {
        case _ when p.type.isFunction:
          callArgs.add(
            _emitDesktopCallbackWrapper(
              writer,
              spec,
              p,
              enumNames,
              structNames,
              recordNames,
              variantNames,
            ),
          );
        case 'int?' || 'DateTime?':
          writer.line('        std::optional<int64_t> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(*reinterpret_cast<const int64_t*>(${p.name} + 1));');
          callArgs.add('_opt_${p.name}');
        case 'uint64?':
          writer.line('        std::optional<uint64_t> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(*reinterpret_cast<const uint64_t*>(${p.name} + 1));');
          callArgs.add('_opt_${p.name}');
        case 'double?':
          writer.line('        std::optional<double> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(*reinterpret_cast<const double*>(${p.name} + 1));');
          callArgs.add('_opt_${p.name}');
        case 'bool?':
          writer.line('        std::optional<bool> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(${p.name}[1] != 0);');
          callArgs.add('_opt_${p.name}');
        case _ when base == 'String':
          if (isNullableParam) {
            // Null Dart string arrives as nullptr — never construct std::string from it.
            callArgs.add('${p.name} == nullptr ? std::optional<std::string>(std::nullopt) : std::make_optional(std::string(${p.name}))');
          } else {
            callArgs.add('std::string(${p.name})');
          }
        case _ when structNames.contains(base):
          if (isNullableParam) {
            callArgs.add('${p.name} == nullptr ? std::optional<$base>(std::nullopt) : std::make_optional(*static_cast<const $base*>(${p.name}))');
          } else {
            callArgs.add('*static_cast<const $base*>(${p.name})');
          }
        case _ when p.type.isRecord || variantNames.contains(base):
          callArgs.add(_emitRecordParamUnpack(writer, p, isNullable: isNullableParam));
        case _ when p.type.isTypedData:
          callArgs.add(p.name);
          callArgs.add('static_cast<size_t>(${p.name}_length)');
        case _ when p.type.isAnyNativeObject:
          // AnyNativeObject: pass raw instanceId; nullable: -1 = null sentinel
          if (p.type.isNullable) {
            callArgs.add('${p.name} == -1 ? std::optional<int64_t>(std::nullopt) : std::make_optional<int64_t>(${p.name})');
          } else {
            callArgs.add(p.name);
          }
        case _ when spec.isCustomTypeName(base):
          // @NitroCustomType: pass raw byte buffer pointer (user's native codec decodes)
          callArgs.add(p.name);
        case _ when enumNames.contains(base):
          if (isNullableParam) {
            // Nullable enums use the -1 wire sentinel (never a valid nativeValue).
            callArgs.add('${p.name} == -1 ? std::optional<$base>(std::nullopt) : std::make_optional(static_cast<$base>(${p.name}))');
          } else {
            callArgs.add('static_cast<$base>(${p.name})');
          }
        default:
          callArgs.add(p.name);
      }
    }
    final callArgStr = callArgs.join(', ');

    final isNullableRet = func.returnType.isNullable || func.returnType.name.endsWith('?');
    switch (func.returnType.name) {
      case _ when func.isResult:
        _emitCppResultOk(writer, spec, func, callArgStr);
      case 'void':
        writer.line('        _impl->${func.dartName}($callArgStr);');
      case _ when retBase == 'String' && isNullableRet:
        writer.line('        std::optional<std::string> _res = _impl->${func.dartName}($callArgStr);');
        writer.line('        return _res.has_value() ? strdup(_res->c_str()) : nullptr;');
      case 'String':
        writer.line('        std::string _res = _impl->${func.dartName}($callArgStr);');
        writer.line(func.isAsync ? '        return strdup(_res.c_str());' : '        _g_str_ret = _res; return const_cast<char*>(_g_str_ret.c_str());');
      case _ when isEnumRet && isNullableRet:
        writer.line('        std::optional<$retBase> _res = _impl->${func.dartName}($callArgStr);');
        writer.line('        return _res.has_value() ? static_cast<int64_t>(*_res) : -1LL;');
      case _ when isEnumRet:
        writer.line('        return static_cast<int64_t>(_impl->${func.dartName}($callArgStr));');
      case _ when isStructRet && isNullableRet:
        writer.line('        std::optional<$retBase> _res = _impl->${func.dartName}($callArgStr);');
        writer.line('        if (!_res.has_value()) { return nullptr; }');
        writer.line('        $retBase* _ptr = ($retBase*)malloc(sizeof($retBase));');
        writer.line('        *_ptr = *_res;');
        writer.line('        return _ptr;');
      case _ when isStructRet:
        final stName = bareTypeName(func.returnType.name);
        writer.line('        $stName _res = _impl->${func.dartName}($callArgStr);');
        if (func.isAsync) {
          writer.line('        $stName* _ptr = ($stName*)malloc(sizeof($stName));');
        } else {
          writer.line('        static thread_local $stName _g_ret_st;');
          writer.line('        $stName* _ptr = &_g_ret_st;');
        }
        writer.line('        *_ptr = _nitro_clone_$stName(_res);');
        writer.line('        return _ptr;');
      case _ when isVariantRet:
        // Impl returns a malloc'd [4B len][payload] block (toNativeBuffer / _to_native).
        writer.line('        NitroCppBuffer _res = _impl->${func.dartName}($callArgStr);');
        writer.line('        return (uint8_t*)_res.data;');
      case 'int?' || 'DateTime?':
        writer.line('        std::optional<int64_t> _opt = _impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = ${func.isAsync ? "(uint8_t*)malloc(9)" : "_g_opt_ret"};');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        if (_opt.has_value()) { *reinterpret_cast<int64_t*>(_res + 1) = _opt.value(); }');
        writer.line('        return _res;');
      case 'uint64?':
        writer.line('        std::optional<uint64_t> _opt = _impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = ${func.isAsync ? "(uint8_t*)malloc(9)" : "_g_opt_ret"};');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        if (_opt.has_value()) { *reinterpret_cast<uint64_t*>(_res + 1) = _opt.value(); }');
        writer.line('        return _res;');
      case 'double?':
        writer.line('        std::optional<double> _opt = _impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = ${func.isAsync ? "(uint8_t*)malloc(9)" : "_g_opt_ret"};');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        if (_opt.has_value()) { *reinterpret_cast<double*>(_res + 1) = _opt.value(); }');
        writer.line('        return _res;');
      case 'bool?':
        writer.line('        std::optional<bool> _opt = _impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = ${func.isAsync ? "(uint8_t*)malloc(2)" : "_g_opt_ret"};');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        _res[1] = (_opt.has_value() && _opt.value()) ? 1 : 0;');
        writer.line('        return _res;');
      case _ when func.returnType.isAnyNativeObject:
        if (func.returnType.isNullable) {
          writer.line('        std::optional<int64_t> _optId = _impl->${func.dartName}($callArgStr);');
          writer.line('        return _optId.has_value() ? _optId.value() : -1LL;');
        } else {
          writer.line('        return _impl->${func.dartName}($callArgStr);');
        }
      case _ when isCustomTypeRet:
        final ct = spec.customTypeByName(retBase)!;
        if (func.returnType.isNullable) {
          writer.line('        uint8_t* _res = _impl->${func.dartName}($callArgStr);');
          writer.line('        return _res; // nullptr = null from native');
        } else {
          writer.line('        uint8_t* _res = _impl->${func.dartName}($callArgStr);');
          writer.line('        if (_res == nullptr) { nitro_report_error("TypeError", "${func.dartName}: ${ct.name} must not return null", nullptr, nullptr); return nullptr; }');
          writer.line('        return _res;');
        }
      case _ when isRecordRet:
        // Impl returns a malloc'd [4B len][payload] block (toNativeBuffer);
        // cast matches the declared C return type (void* records, uint8_t* maps).
        writer.line('        NitroCppBuffer _res = _impl->${func.dartName}($callArgStr);');
        writer.line('        return ($cRet)_res.data;');
      case _ when isZeroCopyTypedDataRet:
        writer.line('        NitroCppBuffer _res = _impl->${func.dartName}($callArgStr);');
        writer.line('        if (_res.size > (size_t)INT64_MAX || (_res.size > 0 && _res.data == nullptr)) {');
        writer.line('            nitro_report_error("ArgumentError", "${func.dartName}: @zeroCopy return buffer has invalid data/size", nullptr, nullptr);');
        writer.line('            return nullptr;');
        writer.line('        }');
        writer.line('        int64_t* _env = (int64_t*)malloc(sizeof(int64_t) * 3);');
        writer.line('        if (_env == nullptr) {');
        writer.line('            nitro_report_error("OutOfMemoryError", "${func.dartName}: failed to allocate zero-copy return envelope", nullptr, nullptr);');
        writer.line('            return nullptr;');
        writer.line('        }');
        writer.line('        _env[0] = (int64_t)_res.size;');
        writer.line('        _env[1] = (int64_t)(intptr_t)(_res.data != nullptr ? _res.data : (const uint8_t*)_env);');
        writer.line('        _env[2] = 0;');
        writer.line('        return (uint8_t*)_env;');
      case _ when func.returnType.isTypedData:
        _emitCppTypedDataCopy(writer, func, callArgStr);
      case _ when func.returnType.isAnyMap:
        // The interface hands the block back as void*.
        writer.line('        return (uint8_t*)_impl->${func.dartName}($callArgStr);');
      default:
        writer.line('        return _impl->${func.dartName}($callArgStr);');
    }
    if (func.isResult) {
      _emitCppResultCatch(writer);
    } else {
      writer.line('    } catch (const std::exception& e) {');
      writer.line(func.isAsync ? '        nitro_report_error("CppException", e.what(), nullptr, nullptr);' : '        _nitro_desktop_err(_nitro_err, "CppException", e.what());');
      if (func.returnType.name != 'void') writer.line('        return $dflt;');
      writer.line('    } catch (...) {');
      writer.line(func.isAsync ? '        nitro_report_error("CppException", "Unknown C++ exception", nullptr, nullptr);' : '        _nitro_desktop_err(_nitro_err, "CppException", "Unknown C++ exception");');
      if (func.returnType.name != 'void') writer.line('        return $dflt;');
      writer.line('    }');
    }
    writer.line('}');
    writer.blankLine();
  }

  CppBridgeGenerator.emitCppWorkerDispatch(writer, spec, libStem);
  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(bareTypeName(prop.type.name));
    final isVariantProp = variantNames.contains(bareTypeName(prop.type.name));
    // Property getter: nullable prim/variant returns uint8_t* pointer (malloc'd, Dart frees).
    final cType = isEnum
        ? 'int64_t'
        : prop.type.name == 'int?'
        ? 'uint8_t*'
        : prop.type.name == 'double?'
        ? 'uint8_t*'
        : prop.type.name == 'bool?'
        ? 'uint8_t*'
        : prop.type.name == 'DateTime?'
        ? 'uint8_t*'
        : isVariantProp
        ? 'uint8_t*'
        : _typeToC(prop.type.name);
    if (prop.hasGetter) {
      // instanceId selects the Hybrid<Class> for this instance, as on JNI.
      writer.line('$cType ${prop.getSymbol}(int64_t instanceId, NitroError* _nitro_err) {');
      writer.line('    ${libStem}_clear_error();');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }  // S8: clear slot');
      writer.line('    auto _impl = _nitro_get_instance(instanceId);');
      writer.line('    if (!_impl) { $notInitOut; return ${_defaultValue(cType)}; }');
      final isNullableProp = prop.type.isNullable || prop.type.name.endsWith('?');
      writer.line('    try {');
      switch (prop.type.name) {
        case 'String':
          writer.line('        std::string _res = _impl->get_${prop.dartName}();');
          writer.line('        _g_str_ret = _res; return const_cast<char*>(_g_str_ret.c_str());');
        case 'String?':
          writer.line('        std::optional<std::string> _res = _impl->get_${prop.dartName}();');
          writer.line('        return _res.has_value() ? strdup(_res->c_str()) : nullptr;');
        case _ when isEnum && isNullableProp:
          final enumName = bareTypeName(prop.type.name);
          writer.line('        std::optional<$enumName> _res = _impl->get_${prop.dartName}();');
          writer.line('        return _res.has_value() ? static_cast<int64_t>(*_res) : -1LL;');
        case _ when isEnum:
          writer.line('        return static_cast<int64_t>(_impl->get_${prop.dartName}());');
        case 'int?':
          writer.line('        std::optional<int64_t> _opt = _impl->get_${prop.dartName}();');
          writer.line('        uint8_t* _res = _g_opt_ret;');
          writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
          writer.line('        if (_opt.has_value()) { *reinterpret_cast<int64_t*>(_res + 1) = _opt.value(); }');
          writer.line('        return _res;');
        case 'double?':
          writer.line('        std::optional<double> _opt = _impl->get_${prop.dartName}();');
          writer.line('        uint8_t* _res = _g_opt_ret;');
          writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
          writer.line('        if (_opt.has_value()) { *reinterpret_cast<double*>(_res + 1) = _opt.value(); }');
          writer.line('        return _res;');
        case 'bool?':
          writer.line('        std::optional<bool> _opt = _impl->get_${prop.dartName}();');
          writer.line('        uint8_t* _res = _g_opt_ret;');
          writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
          writer.line('        _res[1] = (_opt.has_value() && _opt.value()) ? 1 : 0;');
          writer.line('        return _res;');
        case 'DateTime?':
          writer.line('        std::optional<int64_t> _opt = _impl->get_${prop.dartName}();');
          writer.line('        uint8_t* _res = _g_opt_ret;');
          writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
          writer.line('        if (_opt.has_value()) { *reinterpret_cast<int64_t*>(_res + 1) = _opt.value(); }');
          writer.line('        return _res;');
        case _ when isVariantProp:
          // Impl returns a malloc'd [4B len][payload] block (toNativeBuffer).
          writer.line('        NitroCppBuffer _res = _impl->get_${prop.dartName}();');
          writer.line('        return (uint8_t*)_res.data;');
        case _ when recordNames.contains(bareTypeName(prop.type.name)):
          writer.line('        NitroCppBuffer _res = _impl->get_${prop.dartName}();');
          writer.line('        return (void*)_res.data;');
        case _ when structNames.contains(bareTypeName(prop.type.name)):
          final stName = bareTypeName(prop.type.name);
          writer.line('        $stName _res = _impl->get_${prop.dartName}();');
          writer.line('        static thread_local $stName _g_ret_st;');
          writer.line('        $stName* _ptr = &_g_ret_st;');
          writer.line('        *_ptr = _nitro_clone_$stName(_res);');
          writer.line('        return _ptr;');
        default:
          writer.line('        return _impl->get_${prop.dartName}();');
      }
      writer.line('    } catch (const std::exception& e) {');
      writer.line('        _nitro_desktop_err(_nitro_err, "CppException", e.what());');
      writer.line('        return ${_defaultValue(cType)};');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }
    if (prop.hasSetter) {
      final isStructParam = structNames.contains(bareTypeName(prop.type.name));
      final isRecordParam = recordNames.contains(bareTypeName(prop.type.name));
      final isNullablePropSetter = prop.type.isNullable || prop.type.name.endsWith('?');
      final isNullablePrimSetter = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?' || prop.type.name == 'DateTime?' || prop.type.name == 'uint64?';
      final paramCType = isNullablePrimSetter
          ? 'const uint8_t*'
          : isVariantProp
          ? 'const uint8_t*'
          : (isEnum || isStructParam || isRecordParam)
          ? (isEnum ? 'int64_t' : 'void*')
          : _typeToC(prop.type.name);
      // instanceId selects the Hybrid<Class> for this instance, as on JNI.
      writer.line('void ${prop.setSymbol}(int64_t instanceId, $paramCType value, NitroError* _nitro_err) {');
      writer.line('    ${libStem}_clear_error();');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }  // S8: clear slot');
      writer.line('    auto _impl = _nitro_get_instance(instanceId);');
      writer.line('    if (!_impl) { $notInitOut; return; }');
      writer.line('    try {');
      switch (prop.type.name) {
        case 'String':
          writer.line('        _impl->set_${prop.dartName}(std::string(value));');
        case 'String?':
          writer.line('        _impl->set_${prop.dartName}(value == nullptr ? std::optional<std::string>(std::nullopt) : std::make_optional(std::string(value)));');
        case _ when isEnum && isNullablePropSetter:
          final enumName = bareTypeName(prop.type.name);
          writer.line('        _impl->set_${prop.dartName}(value == -1 ? std::optional<$enumName>(std::nullopt) : std::make_optional(static_cast<$enumName>(value)));');
        case _ when isEnum:
          final enumName = bareTypeName(prop.type.name);
          writer.line('        _impl->set_${prop.dartName}(static_cast<$enumName>(value));');
        case _ when isVariantProp || isRecordParam:
          final opt = prop.type.name.endsWith('?');
          if (opt) {
            writer.line('        NitroCppBuffer _buf = { nullptr, 0 };');
            writer.line('        if (value != nullptr) {');
            writer.line('            _buf.data = (const uint8_t*)value + 4;');
            writer.line('            _buf.size = (size_t)*(int32_t*)value;');
            writer.line('        }');
            writer.line('        _impl->set_${prop.dartName}(_buf);');
          } else {
            writer.line('        NitroCppBuffer _buf = { value + 4, (size_t)*(int32_t*)value };');
            writer.line('        _impl->set_${prop.dartName}(_buf);');
          }
        case 'int?' || 'DateTime?':
          writer.line('        _impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(*reinterpret_cast<const int64_t*>(value + 1)));');
        case 'uint64?':
          writer.line('        _impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(*reinterpret_cast<const uint64_t*>(value + 1)));');
        case 'double?':
          writer.line('        _impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(*reinterpret_cast<const double*>(value + 1)));');
        case 'bool?':
          writer.line('        _impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(value[1] != 0));');
        case _ when isStructParam:
          final stName = bareTypeName(prop.type.name);
          if (_isNullableStructType(prop.type, structNames)) {
            writer.line('        _impl->set_${prop.dartName}(value == nullptr ? std::optional<$stName>(std::nullopt) : std::make_optional(*static_cast<const $stName*>(value)));');
          } else {
            writer.line('        _impl->set_${prop.dartName}(*static_cast<const $stName*>(value));');
          }
        default:
          writer.line('        _impl->set_${prop.dartName}(value);');
      }
      writer.line('    } catch (const std::exception& e) {');
      writer.line('        _nitro_desktop_err(_nitro_err, "CppException", e.what());');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }
  }

  for (final stream in spec.streams) {
    // instanceId is included for API consistency with the JNI path; the
    // port registry is keyed by dartName. Multiple simultaneous subscribers
    // each register their own port (matching Kotlin/Swift semantics) — a
    // single int64 slot here previously let a second subscriber overwrite
    // the first, which then received nothing.
    writer.line('void ${stream.registerSymbol}(int64_t instanceId, int64_t dart_port) {');
    _emitStreamCoalesce(writer, spec, 'coalesce', stream);
    writer.line('    g_ports_${stream.dartName}.add(_nitro_get_instance(instanceId), dart_port);');
    writer.line('}');
    writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
    writer.line('    g_ports_${stream.dartName}.remove(dart_port);');
    _emitStreamCoalesce(writer, spec, 'uncoalesce');
    writer.line('}');
    writer.blankLine();
  }

  writer.line('} // extern "C"');
}
