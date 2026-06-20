part of '../cpp_bridge_generator.dart';

String _cppScalarType(String dartType, Set<String> enumNames, Set<String> structNames) => CppBridgeGenerator._cppScalarType(dartType, enumNames, structNames);

String _typeToC(String dartType) => CppBridgeGenerator._typeToC(dartType);

String _callbackParamToC(BridgeParam param, Set<String> enumNames) => CppBridgeGenerator._callbackParamToC(param, enumNames);

String _defaultValue(String cType) => CppBridgeGenerator._defaultValue(cType);

bool _isNullableStructType(BridgeType type, Set<String> structNames) => CppBridgeGenerator._isNullableStructType(type, structNames);

void _emitNullableStructParamGuards(
  CodeWriter writer,
  List<BridgeParam> params,
  Set<String> structNames,
  String functionName,
  String returnStatement,
) => CppBridgeGenerator._emitNullableStructParamGuards(writer, params, structNames, functionName, returnStatement);

void _emitNullableStructPointerGuard(
  CodeWriter writer, {
  required String paramName,
  required String ownerName,
  required String returnStatement,
  required String indent,
}) => CppBridgeGenerator._emitNullableStructPointerGuard(
  writer,
  paramName: paramName,
  ownerName: ownerName,
  returnStatement: returnStatement,
  indent: indent,
);

// ── Direct C++ path (NativeImpl.cpp on all targeted platforms) ─────────────

String _generateCppDirect(BridgeSpec spec) {
  final writer = CodeWriter();
  final libStem = spec.lib.replaceAll('-', '_');
  final className = spec.dartClassName;
  final headerName = '$libStem.bridge.g.h';
  final ifaceHeader = '$libStem.native.g.h';

  final recordNames = spec.recordTypes.map((r) => r.name).toSet();
  final enumNames = spec.enums.map((e) => e.name).toSet();
  final structNames = spec.structs.map((st) => st.name).toSet();

  // Platform guard: scope compilation to only the targeted platforms.
  //   __APPLE__   — covers both iOS and macOS (clang always defines this on Apple targets)
  //   __ANDROID__ — Android NDK
  // When Apple + Android are both targeted, the C++ file is compiled on all
  // platforms and no guard is needed — the same source tree is shared.
  final targetsApple = spec.targetsIos || spec.targetsMacos;
  final cppAppleOnly = targetsApple && !spec.targetsAndroid;
  final cppAndroidOnly = spec.targetsAndroid && !targetsApple;

  writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
  writer.line('// NativeImpl: cpp — shared C++ virtual-dispatch bridge (no JNI / Swift).');
  if (cppAppleOnly) writer.line('#ifdef __APPLE__    // iOS + macOS');
  if (cppAndroidOnly) writer.line('#ifdef __ANDROID__');
  writer.line('#include <stdint.h>');
  writer.line('#include <stdbool.h>');
  writer.line('#include <string.h>');
  writer.line('#include <stdlib.h>');
  writer.line('#include <string>');
  writer.line('#include <stdexcept>');
  writer.line('#include "dart_api_dl.h"');
  writer.line('#include "$headerName"');
  writer.line('#include "$ifaceHeader"');
  writer.blankLine();

  // Dart API DL init
  writer.line('extern "C" {');
  writer.line('NITRO_EXPORT intptr_t ${libStem}_init_dart_api_dl(void* data) {');
  writer.line('    return Dart_InitializeApiDL(data);');
  writer.line('}');
  writer.line('}');
  writer.blankLine();

  // Error state
  writer.line('static thread_local NitroError g_nitro_error = { 0, nullptr, nullptr, nullptr, nullptr };');
  writer.blankLine();
  writer.line('extern "C" {');
  writer.line('NitroError* ${libStem}_get_error() { return &g_nitro_error; }');
  writer.line('void ${libStem}_clear_error() {');
  writer.line('    if (!g_nitro_error.hasError) return;');
  writer.line('    g_nitro_error.hasError = 0;');
  writer.line('    if (g_nitro_error.name)       { free((void*)g_nitro_error.name);       g_nitro_error.name       = nullptr; }');
  writer.line('    if (g_nitro_error.message)    { free((void*)g_nitro_error.message);    g_nitro_error.message    = nullptr; }');
  writer.line('    if (g_nitro_error.code)       { free((void*)g_nitro_error.code);       g_nitro_error.code       = nullptr; }');
  writer.line('    if (g_nitro_error.stackTrace) { free((void*)g_nitro_error.stackTrace); g_nitro_error.stackTrace = nullptr; }');
  writer.line('}');
  writer.line('static void nitro_report_error(const char* name, const char* message, const char* code, const char* stack) {');
  writer.line('    ${libStem}_clear_error();');
  writer.line('    g_nitro_error.hasError = 1;');
  writer.line('    g_nitro_error.name       = name    ? strdup(name)    : strdup("NativeException");');
  writer.line('    g_nitro_error.message    = message ? strdup(message) : strdup("An unknown C++ exception occurred.");');
  writer.line('    g_nitro_error.code       = code    ? strdup(code)    : nullptr;');
  writer.line('    g_nitro_error.stackTrace = stack   ? strdup(stack)   : nullptr;');
  writer.line('}');
  writer.line('}');
  writer.blankLine();

  // Implementation registry.
  // Thread-safety contract: register_impl() MUST be called (and complete)
  // before any concurrent native call can reach get_impl().  In practice this
  // is guaranteed because registration always happens in an
  // __attribute__((constructor)) which runs synchronously at DSO load —
  // before Dart's isolate threads can invoke any bridge function.
  // We intentionally do NOT use std::atomic here: the pointer is written
  // exactly once at startup and never mutated during concurrent use, so a
  // plain load is safe and avoids seq_cst memory barriers on every hot call.
  writer.line('// g_impl is written once during DSO load (see __attribute__((constructor)))');
  writer.line('// and is read-only during concurrent bridge calls — no std::atomic needed.');
  writer.line('static Hybrid$className* g_impl = nullptr;');
  writer.blankLine();
  writer.line('extern "C" {');
  writer.line('void ${libStem}_register_impl(Hybrid$className* impl) { g_impl = impl; }');
  writer.line('Hybrid$className* ${libStem}_get_impl() { return g_impl; }');
  writer.line('}');
  writer.blankLine();

  // Stream state: one Dart port per stream (simplest model)
  for (final stream in spec.streams) {
    writer.line('static int64_t g_port_${stream.dartName} = 0;');
  }
  if (spec.streams.isNotEmpty) writer.blankLine();

  // Stream emit helpers (called by user's C++ implementation)
  for (final stream in spec.streams) {
    final isStruct = structNames.contains(stream.itemType.name.replaceFirst('?', ''));
    final isRecord = stream.itemType.isRecord;
    final isEnum = enumNames.contains(stream.itemType.name.replaceFirst('?', ''));
    final itemCpp = _cppScalarType(stream.itemType.name, enumNames, structNames);
    writer.line('void Hybrid$className::emit_${stream.dartName}($itemCpp item) {');
    writer.line('    int64_t port = g_port_${stream.dartName};');
    writer.line('    if (port == 0) return;');
    writer.line('    Dart_CObject obj;');
    if (stream.itemType.name == 'double') {
      writer.line('    obj.type = Dart_CObject_kDouble;');
      writer.line('    obj.value.as_double = item;');
    } else if (stream.itemType.name == 'int') {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = item;');
    } else if (stream.itemType.name == 'bool') {
      writer.line('    obj.type = Dart_CObject_kBool;');
      writer.line('    obj.value.as_bool = item;');
    } else if (isEnum) {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = static_cast<int64_t>(item);');
    } else if (isStruct) {
      final stName = stream.itemType.name.replaceFirst('?', '');
      writer.line('    $stName* st_ptr = ($stName*)malloc(sizeof($stName));');
      writer.line('    *st_ptr = item;');
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (intptr_t)st_ptr;');
    } else if (isRecord) {
      // item is void* pointing to malloc'd encoded record bytes
      // (wire format: [4-byte payload_len][payload]).
      // Dart reads it via RecordReader.fromNative and frees with malloc.free.
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = (intptr_t)item;');
    } else {
      writer.line('    obj.type = Dart_CObject_kNull;');
    }
    writer.line('    Dart_PostCObject_DL(port, &obj);');
    writer.line('}');
    writer.blankLine();
  }

  // Guard snippet used in every exported function
  final notInit =
      'nitro_report_error("NotInitialized", '
      '"No C++ implementation registered. Call ${libStem}_register_impl() first.", '
      'nullptr, nullptr)';

  writer.line('extern "C" {');
  writer.blankLine();

  // ── Methods ──────────────────────────────────────────────────────────────
  for (final func in spec.functions) {
    if (func.isNativeAsync) {
      // ── @NitroNativeAsync — void wrapper with dart_port param ────────────
      // The C function returns void and delegates to the impl, passing the
      // Dart port so the impl can post the result via Dart_PostCObject_DL.
      // No error slot is used — implementations must post errors via the port.
      final paramParts = <String>[];
      for (final p in func.params) {
        if (p.type.isFunction) {
          paramParts.add(_callbackParamToC(p, enumNames));
          continue;
        }
        final isStructParam = structNames.contains(p.type.name.replaceFirst('?', ''));
        final isRecordParam = recordNames.contains(p.type.name.replaceFirst('?', ''));
        paramParts.add('${(isStructParam || isRecordParam) ? 'void*' : _typeToC(p.type.name)} ${p.name}');
        if (p.type.isTypedData) paramParts.add('int64_t ${p.name}_length');
      }
      paramParts.add('int64_t dart_port');
      final paramsDecl = paramParts.join(', ');

      // Build C++ call args (same conversion logic as regular methods)
      final callArgs = <String>[];
      for (final p in func.params) {
        final base = p.type.name.replaceFirst('?', '');
        if (p.type.isFunction) {
          callArgs.add(p.name);
        } else if (base == 'String') {
          callArgs.add('std::string(${p.name})');
        } else if (structNames.contains(base)) {
          callArgs.add('*static_cast<const $base*>(${p.name})');
        } else if (recordNames.contains(base)) {
          callArgs.add('NitroCppBuffer{ (const uint8_t*)${p.name} + 4, (size_t)*(int32_t*)${p.name} }');
        } else if (p.type.isTypedData) {
          callArgs.add(p.name);
          callArgs.add('static_cast<size_t>(${p.name}_length)');
        } else if (enumNames.contains(base)) {
          callArgs.add('static_cast<$base>(${p.name})');
        } else {
          callArgs.add(p.name);
        }
      }
      callArgs.add('dart_port');
      final callArgStr = callArgs.join(', ');

      writer.line('void ${func.cSymbol}($paramsDecl) {');
      writer.line('    if (!g_impl) {');
      writer.line('        Dart_CObject _err = { Dart_CObject_kNull };');
      writer.line('        Dart_PostCObject_DL(dart_port, &_err);');
      writer.line('        return;');
      writer.line('    }');
      _emitNullableStructParamGuards(
        writer,
        func.params,
        structNames,
        func.dartName,
        'return;',
      );
      writer.line('    g_impl->${func.dartName}($callArgStr);');
      writer.line('}');
      writer.blankLine();
      continue;
    }

    // ── Regular (sync or @nitroAsync) method ─────────────────────────────
    final isEnumRet = enumNames.contains(func.returnType.name.replaceFirst('?', ''));
    final isStructRet = structNames.contains(func.returnType.name.replaceFirst('?', ''));
    // Use func.returnType.isRecord so that List<@HybridStruct T>, List<@HybridRecord T>,
    // and bare @HybridRecord all map to NitroCppBuffer (binary-encoded buffer return).
    final isRecordRet = func.returnType.isRecord;
    final cRet = isEnumRet ? 'int64_t' : _typeToC(func.returnType.name);
    final dflt = _defaultValue(cRet);

    final paramParts = <String>[];
    for (final p in func.params) {
      if (p.type.isFunction) {
        paramParts.add(_callbackParamToC(p, enumNames));
        continue;
      }
      final isStructParam = structNames.contains(p.type.name.replaceFirst('?', ''));
      final isRecordParam = p.type.isRecord;
      paramParts.add('${(isStructParam || isRecordParam) ? 'void*' : _typeToC(p.type.name)} ${p.name}');
      if (p.type.isTypedData) paramParts.add('int64_t ${p.name}_length');
    }
    final paramsDecl = paramParts.isEmpty ? 'void' : paramParts.join(', ');

    writer.line('$cRet ${func.cSymbol}($paramsDecl) {');
    writer.line('    ${libStem}_clear_error();');
    if (func.returnType.name == 'void') {
      writer.line('    if (!g_impl) { $notInit; return; }');
    } else {
      writer.line('    if (!g_impl) { $notInit; return $dflt; }');
    }
    _emitNullableStructParamGuards(
      writer,
      func.params,
      structNames,
      func.dartName,
      func.returnType.name == 'void' ? 'return;' : 'return $dflt;',
    );
    writer.line('    try {');

    // Build call args (C → C++ types)
    final callArgs = <String>[];
    for (final p in func.params) {
      final base = p.type.name.replaceFirst('?', '');
      if (p.type.isFunction) {
        callArgs.add(p.name);
      } else if (base == 'String') {
        callArgs.add('std::string(${p.name})');
      } else if (structNames.contains(base)) {
        callArgs.add('*static_cast<const $base*>(${p.name})');
      } else if (p.type.isRecord) {
        if (p.type.isNullable) {
          writer.line('        NitroCppBuffer _buf_${p.name} = { nullptr, 0 };');
          writer.line('        if (${p.name} != nullptr) {');
          writer.line('            _buf_${p.name}.data = (const uint8_t*)${p.name} + 4;');
          writer.line('            _buf_${p.name}.size = (size_t)*(int32_t*)${p.name};');
          writer.line('        }');
          callArgs.add('_buf_${p.name}');
        } else {
          writer.line('        NitroCppBuffer _buf_${p.name} = { (const uint8_t*)${p.name} + 4, (size_t)*(int32_t*)${p.name} };');
          callArgs.add('_buf_${p.name}');
        }
      } else if (p.type.isTypedData) {
        callArgs.add(p.name);
        callArgs.add('static_cast<size_t>(${p.name}_length)');
      } else if (enumNames.contains(base)) {
        callArgs.add('static_cast<$base>(${p.name})');
      } else {
        callArgs.add(p.name);
      }
    }
    final callArgStr = callArgs.join(', ');

    if (func.returnType.name == 'void') {
      writer.line('        g_impl->${func.dartName}($callArgStr);');
    } else if (func.returnType.name == 'String') {
      writer.line('        std::string _res = g_impl->${func.dartName}($callArgStr);');
      writer.line('        return strdup(_res.c_str());');
    } else if (isEnumRet) {
      writer.line('        return static_cast<int64_t>(g_impl->${func.dartName}($callArgStr));');
    } else if (isStructRet) {
      final stName = func.returnType.name.replaceFirst('?', '');
      writer.line('        $stName _res = g_impl->${func.dartName}($callArgStr);');
      writer.line('        $stName* _ptr = ($stName*)malloc(sizeof($stName));');
      writer.line('        *_ptr = _res;');
      writer.line('        return _ptr;');
    } else if (isRecordRet) {
      writer.line('        NitroCppBuffer _res = g_impl->${func.dartName}($callArgStr);');
      writer.line('        return (void*)_res.data;');
    } else {
      writer.line('        return g_impl->${func.dartName}($callArgStr);');
    }

    writer.line('    } catch (const std::exception& e) {');
    writer.line('        nitro_report_error("CppException", e.what(), nullptr, nullptr);');
    if (func.returnType.name != 'void') {
      writer.line('        return $dflt;');
    }
    writer.line('    } catch (...) {');
    writer.line('        nitro_report_error("CppException", "Unknown C++ exception", nullptr, nullptr);');
    if (func.returnType.name != 'void') {
      writer.line('        return $dflt;');
    }
    writer.line('    }');
    writer.line('}');
    writer.blankLine();
  }

  // ── Properties ───────────────────────────────────────────────────────────
  for (final prop in spec.properties) {
    final isEnum = enumNames.contains(prop.type.name.replaceFirst('?', ''));
    final cType = isEnum ? 'int64_t' : _typeToC(prop.type.name);

    if (prop.hasGetter) {
      writer.line('$cType ${prop.getSymbol}(void) {');
      writer.line('    ${libStem}_clear_error();');
      writer.line('    if (!g_impl) { $notInit; return ${_defaultValue(cType)}; }');
      writer.line('    try {');
      if (prop.type.name == 'String') {
        writer.line('        std::string _res = g_impl->get_${prop.dartName}();');
        writer.line('        return strdup(_res.c_str());');
      } else if (isEnum) {
        writer.line('        return static_cast<int64_t>(g_impl->get_${prop.dartName}());');
      } else if (recordNames.contains(prop.type.name.replaceFirst('?', ''))) {
        writer.line('        NitroCppBuffer _res = g_impl->get_${prop.dartName}();');
        writer.line('        return (void*)_res.data;');
      } else if (structNames.contains(prop.type.name.replaceFirst('?', ''))) {
        final stName = prop.type.name.replaceFirst('?', '');
        writer.line('        $stName _res = g_impl->get_${prop.dartName}();');
        writer.line('        $stName* _ptr = ($stName*)malloc(sizeof($stName));');
        writer.line('        *_ptr = _res;');
        writer.line('        return _ptr;');
      } else {
        writer.line('        return g_impl->get_${prop.dartName}();');
      }
      writer.line('    } catch (const std::exception& e) {');
      writer.line('        nitro_report_error("CppException", e.what(), nullptr, nullptr);');
      writer.line('        return ${_defaultValue(cType)};');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }

    if (prop.hasSetter) {
      final isStructParam = structNames.contains(prop.type.name.replaceFirst('?', ''));
      final isRecordParam = recordNames.contains(prop.type.name.replaceFirst('?', ''));
      final paramCType = (isEnum || isStructParam || isRecordParam) ? (isEnum ? 'int64_t' : 'void*') : _typeToC(prop.type.name);
      writer.line('void ${prop.setSymbol}($paramCType value) {');
      writer.line('    ${libStem}_clear_error();');
      writer.line('    if (!g_impl) { $notInit; return; }');
      writer.line('    try {');
      if (prop.type.name == 'String') {
        writer.line('        g_impl->set_${prop.dartName}(std::string(value));');
      } else if (isEnum) {
        final enumName = prop.type.name.replaceFirst('?', '');
        writer.line('        g_impl->set_${prop.dartName}(static_cast<$enumName>(value));');
      } else if (isRecordParam) {
        final opt = prop.type.name.endsWith('?');
        if (opt) {
          writer.line('        NitroCppBuffer _buf = { nullptr, 0 };');
          writer.line('        if (value != nullptr) {');
          writer.line('            _buf.data = (const uint8_t*)value + 4;');
          writer.line('            _buf.size = (size_t)*(int32_t*)value;');
          writer.line('        }');
          writer.line('        g_impl->set_${prop.dartName}(_buf);');
        } else {
          writer.line('        NitroCppBuffer _buf = { (const uint8_t*)value + 4, (size_t)*(int32_t*)value };');
          writer.line('        g_impl->set_${prop.dartName}(_buf);');
        }
      } else if (isStructParam) {
        final stName = prop.type.name.replaceFirst('?', '');
        if (_isNullableStructType(prop.type, structNames)) {
          _emitNullableStructPointerGuard(
            writer,
            paramName: 'value',
            ownerName: 'set_${prop.dartName}',
            returnStatement: 'return;',
            indent: '        ',
          );
        }
        writer.line('        g_impl->set_${prop.dartName}(*static_cast<const $stName*>(value));');
      } else {
        writer.line('        g_impl->set_${prop.dartName}(value);');
      }
      writer.line('    } catch (const std::exception& e) {');
      writer.line('        nitro_report_error("CppException", e.what(), nullptr, nullptr);');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }
  }

  // ── Streams ──────────────────────────────────────────────────────────────
  for (final stream in spec.streams) {
    writer.line('void ${stream.registerSymbol}(int64_t dart_port) {');
    writer.line('    g_port_${stream.dartName} = dart_port;');
    writer.line('}');
    writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
    writer.line('    if (g_port_${stream.dartName} == dart_port) g_port_${stream.dartName} = 0;');
    writer.line('}');
    writer.blankLine();
  }

  // ── Struct release functions (used by NativeFinalizer in Dart proxy classes) ─
  for (final st in spec.structs) {
    writer.line('// Frees a malloc\'d [${st.name}] wrapper allocated by the stream emitter.');
    writer.line('// Called automatically by NativeFinalizer when the Dart proxy is GC\'d.');
    writer.line('void ${libStem}_release_${st.name}(void* ptr) {');
    writer.line('    if (!ptr) return;');
    final hasStrings = st.fields.any((f) => f.type.name == 'String');
    final hasNestedStructs = st.fields.any((f) => structNames.contains(f.type.name.replaceFirst('?', '')));
    final hasNonZcData = st.fields.any((f) => f.type.isTypedData && !f.zeroCopy);
    final hasZeroCopy = st.fields.any((f) => f.zeroCopy);
    if (hasStrings || hasNestedStructs || hasNonZcData) {
      writer.line('    ${st.name}* st_ptr = (${st.name}*)ptr;');
      for (final f in st.fields) {
        if (f.type.name == 'String') {
          writer.line('    if (st_ptr->${f.name}) free((void*)st_ptr->${f.name});');
        } else if (structNames.contains(f.type.name.replaceFirst('?', ''))) {
          writer.line('    if (st_ptr->${f.name}) { free(st_ptr->${f.name}); st_ptr->${f.name} = nullptr; }');
        } else if (f.type.isTypedData && !f.zeroCopy) {
          writer.line('    if (st_ptr->${f.name}) { free(st_ptr->${f.name}); st_ptr->${f.name} = nullptr; }');
        }
      }
    }
    if (hasZeroCopy) {
      writer.line('#ifdef __ANDROID__');
      writer.line('    {');
      writer.line('        std::lock_guard<std::mutex> _lk(g_zero_copy_refs_mtx);');
      writer.line('        auto it = g_zero_copy_refs.find(ptr);');
      writer.line('        if (it != g_zero_copy_refs.end()) {');
      writer.line('            JNIEnv* _env = GetEnv();');
      writer.line('            if (_env != nullptr) _env->DeleteGlobalRef(it->second);');
      writer.line('            g_zero_copy_refs.erase(it);');
      writer.line('        }');
      writer.line('    }');
      writer.line('#endif // __ANDROID__');
    }
    writer.line('    free(ptr);');
    writer.line('}');
    writer.blankLine();
  }

  writer.line('} // extern "C"');
  if (cppAppleOnly) writer.line('#endif // __APPLE__  // iOS + macOS');
  if (cppAndroidOnly) writer.line('#endif // __ANDROID__');
  return writer.toString();
}
