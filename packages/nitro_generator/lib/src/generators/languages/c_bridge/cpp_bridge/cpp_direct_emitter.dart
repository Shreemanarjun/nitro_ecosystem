part of '../cpp_bridge_generator.dart';

String _cppScalarType(String dartType, Set<String> enumNames, Set<String> structNames) => CppBridgeGenerator._cppScalarType(dartType, enumNames, structNames);

String _typeToC(String dartType) => CppBridgeGenerator._typeToC(dartType);

String _callbackParamToC(BridgeParam param, Set<String> enumNames, {Set<String>? structNames, Set<String>? recordNames}) => CppBridgeGenerator._callbackParamToC(param, enumNames, structNames: structNames, recordNames: recordNames);

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
  final checksum = bridgeSpecChecksum(spec);
  final className = spec.dartClassName;
  final headerName = '$libStem.bridge.g.h';
  final ifaceHeader = '$libStem.native.g.h';

  final recordNames = spec.recordTypes.map((r) => r.name).toSet();
  final enumNames = spec.enums.map((e) => e.name).toSet();
  final structNames = spec.structs.map((st) => st.name).toSet();
  final variantNames = spec.variants.map((v) => v.name).toSet();

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
  writer.line('NITRO_EXPORT uint32_t ${libStem}_nitro_abi_version(void) {');
  writer.line('    return 1;');
  writer.line('}');
  writer.line('NITRO_EXPORT const char* ${libStem}_nitro_bridge_checksum(void) {');
  writer.line('    return "$checksum";');
  writer.line('}');
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
  writer.line('    if (!g_nitro_error.hasError) { return; }');

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

  // ── Multi-instance registry (mirrors RN Nitro's HybridObjectRegistry) ────
  // g_instances maps instanceId → shared_ptr<Hybrid$className>.
  // Factory mode (recommended): register_factory() → create_instance() calls it.
  // Legacy mode: register_impl() wraps raw ptr with no-op deleter at slot 0.
  writer.line('#include <atomic>');
  writer.line('#include <memory>');
  writer.line('#include <mutex>');
  writer.line('#include <unordered_map>');
  writer.blankLine();
  // Meyers' Singleton for the registry — guarantees thread-safe init before
  // first use even when __attribute__((constructor)) fires early.
  writer.line('using Hybrid${className}Factory = std::function<std::shared_ptr<Hybrid$className>(const std::string&)>;');
  writer.line('static std::unordered_map<int64_t, std::shared_ptr<Hybrid$className>>& _g_instances() {');
  writer.line('    static std::unordered_map<int64_t, std::shared_ptr<Hybrid$className>> m;');
  writer.line('    return m;');
  writer.line('}');
  writer.line('static std::mutex& _g_instances_mtx() {');
  writer.line('    static std::mutex m;');
  writer.line('    return m;');
  writer.line('}');
  writer.line('static std::atomic<int64_t>& _g_next_instance_id() {');
  writer.line('    static std::atomic<int64_t> id{1};');
  writer.line('    return id;');
  writer.line('}');
  writer.line('static Hybrid${className}Factory& _g_factory() {');
  writer.line('    static Hybrid${className}Factory f;');
  writer.line('    return f;');
  writer.line('}');
  writer.blankLine();
  writer.line('static std::shared_ptr<Hybrid$className> _nitro_get_instance(int64_t id) {');
  writer.line('    std::lock_guard<std::mutex> _lk(_g_instances_mtx());');
  writer.line('    auto it = _g_instances().find(id);');
  writer.line('    return it != _g_instances().end() ? it->second : nullptr;');
  writer.line('}');
  writer.blankLine();
  writer.line('extern "C" {');
  writer.line('void ${libStem}_register_factory(void* fn) {');
  writer.line('    _g_factory() = *static_cast<Hybrid${className}Factory*>(fn);');
  writer.line('}');
  writer.line('void ${libStem}_register_impl(Hybrid$className* impl) {');
  writer.line('    std::lock_guard<std::mutex> _lk(_g_instances_mtx());');
  writer.line('    if (impl) _g_instances()[0] = std::shared_ptr<Hybrid$className>(impl, [](Hybrid$className*){});');
  writer.line('    else _g_instances().erase(0);');
  writer.line('}');
  writer.line('Hybrid$className* ${libStem}_get_impl() {');
  writer.line('    auto ptr = _nitro_get_instance(0);');
  writer.line('    return ptr ? ptr.get() : nullptr;');
  writer.line('}');
  writer.line('NITRO_EXPORT int64_t ${libStem}_create_instance(const char* key) {');
  writer.line('    if (_g_factory()) {');
  writer.line('        auto inst = _g_factory()(key ? key : "");');
  writer.line('        if (!inst) return -1;');
  writer.line('        std::lock_guard<std::mutex> _lk(_g_instances_mtx());');
  writer.line('        int64_t id = ++_g_next_instance_id();');
  writer.line('        _g_instances()[id] = std::move(inst);');
  writer.line('        return id;');
  writer.line('    }');
  writer.line('    // Legacy: no factory registered — return 0 (single global impl slot)');
  writer.line('    return 0;');
  writer.line('}');
  writer.line('NITRO_EXPORT void ${libStem}_destroy_instance(int64_t instanceId) {');
  writer.line('    std::lock_guard<std::mutex> _lk(_g_instances_mtx());');
  writer.line('    _g_instances().erase(instanceId);');
  writer.line('}');
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
    writer.line('    if (port == 0) { return; }');

    if (isStruct) {
      final stName = stream.itemType.name.replaceFirst('?', '');
      writer.line('    $stName* st_ptr = nullptr;');
    }
    writer.line('    Dart_CObject obj;');
    if (stream.itemType.name == 'double') {
      writer.line('    obj.type = Dart_CObject_kDouble;');
      writer.line('    obj.value.as_double = item;');
    } else if (stream.itemType.name == 'int') {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = item;');
    } else if (stream.itemType.name == 'bool') {
      // Use kInt64 (0/1) — kBool is unreliable on some Android versions.
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = item ? 1 : 0;');
    } else if (isEnum) {
      writer.line('    obj.type = Dart_CObject_kInt64;');
      writer.line('    obj.value.as_int64 = static_cast<int64_t>(item);');
    } else if (isStruct) {
      final stName = stream.itemType.name.replaceFirst('?', '');
      writer.line('    st_ptr = ($stName*)malloc(sizeof($stName));');
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
    writer.line('    if (!Dart_PostCObject_DL(port, &obj)) {');
    writer.line('        g_port_${stream.dartName} = 0;');
    if (isStruct) {
      writer.line('        free(st_ptr);');
    } else if (isRecord) {
      writer.line('        free(item);');
    }
    writer.line('        return;');
    writer.line('    }');
    writer.line('}');
    writer.blankLine();
  }

  // S8: helper that writes to the out-param error slot.
  // Keeps the generated catch blocks compact and consistent.
  // Emitted once per bridge file; used in every method and property.
  writer.line('// S8 helper — writes error info to the out-param slot.');
  writer.line('static void _nitro_out_err(NitroError* e, const char* name, const char* msg) {');
  writer.line('    if (!e) return;');
  writer.line('    e->hasError = 1;');
  writer.line('    e->name       = name ? strdup(name) : nullptr;');
  writer.line('    e->message    = msg  ? strdup(msg)  : nullptr;');
  writer.line('    e->code       = nullptr;');
  writer.line('    e->stackTrace = nullptr;');
  writer.line('}');
  writer.blankLine();

  // Guard snippet + instance lookup emitted in every exported function.
  // S8: writes to _nitro_err out-param instead of the TLS slot.
  // g_impl guard is replaced by per-function instance lookup from g_instances.
  final notInit =
      '_nitro_out_err(_nitro_err, "NotInitialized", '
      '"No C++ implementation registered. Call ${libStem}_register_factory() or ${libStem}_register_impl().")';

  writer.line('extern "C" {');
  writer.blankLine();

  // ── Methods ──────────────────────────────────────────────────────────────
  for (final func in spec.functions) {
    if (func.isNativeAsync) {
      // ── @NitroNativeAsync — void wrapper with dart_port param ────────────
      // The C function returns void and delegates to the impl, passing the
      // Dart port so the impl can post the result via Dart_PostCObject_DL.
      // No error slot is used — implementations must post errors via the port.
      // instanceId is included for API consistency with the JNI path; g_impl ignores it.
      final paramParts = <String>['int64_t instanceId'];
      for (final p in func.params) {
        if (p.type.isFunction) {
          paramParts.add(_callbackParamToC(p, enumNames, structNames: structNames, recordNames: recordNames));
          continue;
        }
        final isStructParam = structNames.contains(p.type.name.replaceFirst('?', ''));
        final isRecordParam = recordNames.contains(p.type.name.replaceFirst('?', ''));
        final isEnumParam = enumNames.contains(p.type.name.replaceFirst('?', ''));
        paramParts.add('${(isStructParam || isRecordParam || p.type.isNativeHandle) ? 'void*' : (isEnumParam ? 'int64_t' : _typeToC(p.type.name))} ${p.name}');
        if (p.type.isTypedData) paramParts.add('size_t ${p.name}_length');
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
      writer.line('    auto _impl = _nitro_get_instance(instanceId);');
      writer.line('    if (!_impl) {');
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
      writer.line('    _impl->${func.dartName}($callArgStr);');
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
    final isVariantRet = variantNames.contains(func.returnType.name.replaceFirst('?', ''));
    final isNativeHandleRet = func.returnType.isNativeHandle;
    final isZeroCopyTypedDataRet = func.zeroCopyReturn && func.returnType.isTypedData;
    // Nullable primitives (int?/double?/bool?) use NitroNullable binary → uint8_t*.
    final retBase = func.returnType.name.replaceFirst('?', '');
    final isNullablePrimRet = (func.returnType.isNullable || func.returnType.name.endsWith('?')) &&
        (retBase == 'int' || retBase == 'double' || retBase == 'bool');
    final cRet = isNullablePrimRet
        ? 'uint8_t*'
        : isVariantRet
        ? 'uint8_t*'
        : isEnumRet
        ? 'int64_t'
        : func.returnType.isTypedData
        ? 'uint8_t*'
        : isNativeHandleRet
        ? 'void*'
        : _typeToC(func.returnType.name);
    final dflt = _defaultValue(cRet);

    // instanceId is included for API consistency with the JNI path; g_impl ignores it.
    final paramParts = <String>['int64_t instanceId'];
    for (final p in func.params) {
      if (p.type.isFunction) {
        paramParts.add(_callbackParamToC(p, enumNames, structNames: structNames, recordNames: recordNames));
        continue;
      }
      final isStructParam = structNames.contains(p.type.name.replaceFirst('?', ''));
      final isRecordParam = p.type.isRecord;
      final isVariantParam = variantNames.contains(p.type.name.replaceFirst('?', ''));
      final isEnumParam = enumNames.contains(p.type.name.replaceFirst('?', ''));
      // Nullable primitives (int?/double?/bool?) use NitroNullable binary → void*.
      final paramPrimBase = p.type.name.replaceFirst('?', '');
      final isNullablePrimParam = (p.type.isNullable || p.type.name.endsWith('?')) &&
          (paramPrimBase == 'int' || paramPrimBase == 'double' || paramPrimBase == 'bool');
      final cType = isNullablePrimParam
          ? 'void*'
          : isEnumParam
              ? 'int64_t'
              : ((isStructParam || isRecordParam || isVariantParam || p.type.isNativeHandle) ? 'void*' : _typeToC(p.type.name));
      paramParts.add('$cType ${p.name}');
      if (p.type.isTypedData) paramParts.add('size_t ${p.name}_length');
    }
    // S8: only SYNC functions take NitroError* out-param.
    // @nitroAsync functions use TLS get_error/clear_error — no NitroError* in signature.
    if (!func.isAsync) {
      paramParts.add('NitroError* _nitro_err');
    }
    final paramsDecl = paramParts.join(', ');

    writer.line('$cRet ${func.cSymbol}($paramsDecl) {');
    if (func.isAsync) {
      writer.line('    NitroError* _nitro_err = nullptr; // async: errors use TLS not out-param');
    } else {
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }  // S8: clear slot');
    }
    // Instance lookup (multi-instance support — mirrors RN Nitro's HybridObjectRegistry)
    writer.line('    auto _impl = _nitro_get_instance(instanceId);');
    if (func.returnType.name == 'void') {
      writer.line('    if (!_impl) { $notInit; return; }');
    } else {
      writer.line('    if (!_impl) { $notInit; return $dflt; }');
    }
    _emitNullableStructParamGuards(
      writer,
      func.params,
      structNames,
      func.dartName,
      func.returnType.name == 'void' ? 'return;' : 'return $dflt;',
    );
    writer.line('    try {');

    // Build call args (C → C++ types).
    // Nullable primitives are marshalled from NitroOptXxx binary to std::optional<T>.
    // Callbacks are wrapped from raw C fn ptr to std::function<>.
    final callArgs = <String>[];
    for (final p in func.params) {
      final isNullableParam = p.type.isNullable || p.type.name.endsWith('?');
      final base = p.type.name.replaceFirst('?', '');
      if (p.type.isFunction) {
        // std::function<R(Args...)> in the abstract class accepts raw C fn ptrs implicitly.
        // C++ constructs the std::function from the raw pointer at the call site.
        callArgs.add(p.name);
      } else if (isNullableParam && (base == 'int' || base == 'double' || base == 'bool')) {
        // Unmarshal NitroOpt binary → std::optional<T>
        final nitroType = base == 'int' ? 'NitroOptInt64' : base == 'double' ? 'NitroOptFloat64' : 'NitroOptBool';
        final cppType = base == 'int' ? 'int64_t' : base == 'double' ? 'double' : 'bool';
        writer.line('        std::optional<$cppType> _opt_${p.name};');
        writer.line('        if (${p.name} != nullptr) {');
        writer.line('            auto* _s = static_cast<const $nitroType*>(${p.name});');
        if (base == 'bool') {
          writer.line('            if (_s->hasValue) _opt_${p.name} = _s->value != 0;');
        } else {
          writer.line('            if (_s->hasValue) _opt_${p.name} = _s->value;');
        }
        writer.line('        }');
        callArgs.add('_opt_${p.name}');
      } else if (isNullableParam && base == 'String') {
        writer.line('        std::optional<std::string> _opt_${p.name} = ${p.name} ? std::optional<std::string>(std::string(${p.name})) : std::nullopt;');
        callArgs.add('_opt_${p.name}');
      } else if (base == 'String') {
        callArgs.add('std::string(${p.name})');
      } else if (structNames.contains(base)) {
        callArgs.add('*static_cast<const $base*>(${p.name})');
      } else if (p.type.isRecord || variantNames.contains(base)) {
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
      } else if (p.type.isPointer) {
        // The C signature declares raw pointer params as void*, but the C++
        // abstract interface types them (Pointer<Uint8> → uint8_t*). Cast so
        // the generated call site compiles against the generated interface.
        final innerBase = p.type.pointerInnerType?.replaceFirst('?', '');
        const primPointerMap = {
          'Uint8': 'uint8_t',
          'Int8': 'int8_t',
          'Uint16': 'uint16_t',
          'Int16': 'int16_t',
          'Uint32': 'uint32_t',
          'Int32': 'int32_t',
          'Uint64': 'uint64_t',
          'Int64': 'int64_t',
          'Float': 'float',
          'Double': 'double',
        };
        final prim = innerBase == null ? null : primPointerMap[innerBase];
        if (prim != null) {
          callArgs.add('static_cast<$prim*>(${p.name})');
        } else if (innerBase != null &&
            (enumNames.contains(innerBase) || structNames.contains(innerBase))) {
          callArgs.add('static_cast<$innerBase*>(${p.name})');
        } else {
          callArgs.add(p.name); // Pointer<Void> / opaque — void* matches
        }
      } else {
        callArgs.add(p.name);
      }
    }
    final callArgStr = callArgs.join(', ');

    if (func.returnType.name == 'void') {
      writer.line('        _impl->${func.dartName}($callArgStr);');
    } else if (isNativeHandleRet) {
      writer.line('        return _impl->${func.dartName}($callArgStr);');
    } else if (isNullablePrimRet) {
      // Marshal std::optional<T> → NitroOptXxx binary (heap-allocated, freed by Dart).
      final nitroType = retBase == 'int' ? 'NitroOptInt64' : retBase == 'double' ? 'NitroOptFloat64' : 'NitroOptBool';
      writer.line('        auto _opt = _impl->${func.dartName}($callArgStr);');
      writer.line('        auto* _out = ($nitroType*)malloc(sizeof($nitroType));');
      writer.line('        if (!_out) return nullptr;');
      if (retBase == 'bool') {
        writer.line('        _out->hasValue = _opt.has_value() ? 1 : 0;');
        writer.line('        _out->value    = _opt.has_value() ? (_opt.value() ? 1 : 0) : 0;');
      } else {
        writer.line('        _out->hasValue = _opt.has_value() ? 1 : 0;');
        writer.line('        _out->value    = _opt.value_or(0);');
      }
      writer.line('        return (uint8_t*)_out;');
    } else if (func.returnType.name == 'String') {
      writer.line('        std::string _res = _impl->${func.dartName}($callArgStr);');
      writer.line('        return strdup(_res.c_str());');
    } else if (isEnumRet) {
      writer.line('        return static_cast<int64_t>(_impl->${func.dartName}($callArgStr));');
    } else if (isStructRet) {
      final stName = func.returnType.name.replaceFirst('?', '');
      writer.line('        $stName _res = _impl->${func.dartName}($callArgStr);');
      writer.line('        $stName* _ptr = ($stName*)malloc(sizeof($stName));');
      writer.line('        *_ptr = _res;');
      writer.line('        return _ptr;');
    } else if (isRecordRet || isVariantRet) {
      writer.line('        NitroCppBuffer _res = _impl->${func.dartName}($callArgStr);');
      writer.line('        return (uint8_t*)_res.data;');
    } else if (isZeroCopyTypedDataRet) {
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
    } else {
      writer.line('        return _impl->${func.dartName}($callArgStr);');
    }

    writer.line('    } catch (const std::exception& e) {');
    writer.line('        _nitro_out_err(_nitro_err, "CppException", e.what());');
    if (func.returnType.name != 'void') {
      writer.line('        return $dflt;');
    }
    writer.line('    } catch (...) {');
    writer.line('        _nitro_out_err(_nitro_err, "CppException", "Unknown C++ exception");');
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
    final propPrimBase = prop.type.name.replaceFirst('?', '');
    final isNullablePrimProp = (prop.type.isNullable || prop.type.name.endsWith('?')) &&
        (propPrimBase == 'int' || propPrimBase == 'double' || propPrimBase == 'bool');
    // Nullable primitives use NitroNullable binary → uint8_t* getter, void* setter.
    final cType = isNullablePrimProp ? 'uint8_t*' : (isEnum ? 'int64_t' : _typeToC(prop.type.name));

    if (prop.hasGetter) {
      writer.line('$cType ${prop.getSymbol}(int64_t instanceId, NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }  // S8: clear slot');
      writer.line('    auto _impl = _nitro_get_instance(instanceId);');
      writer.line('    if (!_impl) { $notInit; return ${_defaultValue(cType)}; }');
      writer.line('    try {');
      if (prop.type.name == 'String') {
        writer.line('        std::string _res = _impl->get_${prop.dartName}();');
        writer.line('        return strdup(_res.c_str());');
      } else if (isEnum) {
        writer.line('        return static_cast<int64_t>(_impl->get_${prop.dartName}());');
      } else if (isNullablePrimProp) {
        // Marshal std::optional<T> → NitroOptXxx binary
        final nitroType = propPrimBase == 'int' ? 'NitroOptInt64' : propPrimBase == 'double' ? 'NitroOptFloat64' : 'NitroOptBool';
        writer.line('        auto _opt = _impl->get_${prop.dartName}();');
        writer.line('        auto* _out = ($nitroType*)malloc(sizeof($nitroType));');
        writer.line('        if (!_out) return nullptr;');
        if (propPrimBase == 'bool') {
          writer.line('        _out->hasValue = _opt.has_value() ? 1 : 0;');
          writer.line('        _out->value    = _opt.has_value() ? (_opt.value() ? 1 : 0) : 0;');
        } else {
          writer.line('        _out->hasValue = _opt.has_value() ? 1 : 0;');
          writer.line('        _out->value    = _opt.value_or(0);');
        }
        writer.line('        return (uint8_t*)_out;');
      } else if (recordNames.contains(prop.type.name.replaceFirst('?', ''))) {
        writer.line('        NitroCppBuffer _res = _impl->get_${prop.dartName}();');
        writer.line('        return (void*)_res.data;');
      } else if (structNames.contains(prop.type.name.replaceFirst('?', ''))) {
        final stName = prop.type.name.replaceFirst('?', '');
        writer.line('        $stName _res = _impl->get_${prop.dartName}();');
        writer.line('        $stName* _ptr = ($stName*)malloc(sizeof($stName));');
        writer.line('        *_ptr = _res;');
        writer.line('        return _ptr;');
      } else {
        writer.line('        return _impl->get_${prop.dartName}();');
      }
      writer.line('    } catch (const std::exception& e) {');
      writer.line('        _nitro_out_err(_nitro_err, "CppException", e.what());');
      writer.line('        return ${_defaultValue(cType)};');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }

    if (prop.hasSetter) {
      final isStructParam = structNames.contains(prop.type.name.replaceFirst('?', ''));
      final isRecordParam = recordNames.contains(prop.type.name.replaceFirst('?', ''));
      final paramCType = isNullablePrimProp
          ? 'void*'
          : (isEnum || isStructParam || isRecordParam) ? (isEnum ? 'int64_t' : 'void*') : _typeToC(prop.type.name);
      writer.line('void ${prop.setSymbol}(int64_t instanceId, $paramCType value, NitroError* _nitro_err) {');
      writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }');
      writer.line('    auto _impl = _nitro_get_instance(instanceId);');
      writer.line('    if (!_impl) { $notInit; return; }');
      writer.line('    try {');
      if (isNullablePrimProp) {
        // Unmarshal void* NitroOpt binary → std::optional<T>
        final nitroType = propPrimBase == 'int' ? 'NitroOptInt64' : propPrimBase == 'double' ? 'NitroOptFloat64' : 'NitroOptBool';
        final cppType = propPrimBase == 'int' ? 'int64_t' : propPrimBase == 'double' ? 'double' : 'bool';
        writer.line('        std::optional<$cppType> _opt;');
        writer.line('        if (value) { auto* _s = static_cast<const $nitroType*>(value); if (_s->hasValue) _opt = ${propPrimBase == 'bool' ? '_s->value != 0' : '_s->value'}; }');
        writer.line('        _impl->set_${prop.dartName}(_opt);');
      } else if (prop.type.name == 'String') {
        writer.line('        _impl->set_${prop.dartName}(std::string(value));');
      } else if (isEnum) {
        final enumName = prop.type.name.replaceFirst('?', '');
        writer.line('        _impl->set_${prop.dartName}(static_cast<$enumName>(value));');
      } else if (isRecordParam) {
        final opt = prop.type.name.endsWith('?');
        if (opt) {
          writer.line('        NitroCppBuffer _buf = { nullptr, 0 };');
          writer.line('        if (value != nullptr) {');
          writer.line('            _buf.data = (const uint8_t*)value + 4;');
          writer.line('            _buf.size = (size_t)*(int32_t*)value;');
          writer.line('        }');
          writer.line('        _impl->set_${prop.dartName}(_buf);');
        } else {
          writer.line('        NitroCppBuffer _buf = { (const uint8_t*)value + 4, (size_t)*(int32_t*)value };');
          writer.line('        _impl->set_${prop.dartName}(_buf);');
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
        writer.line('        _impl->set_${prop.dartName}(*static_cast<const $stName*>(value));');
      } else {
        writer.line('        _impl->set_${prop.dartName}(value);');
      }
      writer.line('    } catch (const std::exception& e) {');
      writer.line('        _nitro_out_err(_nitro_err, "CppException", e.what());');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }
  }

  // ── Streams ──────────────────────────────────────────────────────────────
  for (final stream in spec.streams) {
    writer.line('void ${stream.registerSymbol}(int64_t instanceId, int64_t dart_port) {');
    writer.line('    g_port_${stream.dartName} = dart_port;');
    writer.line('}');
    writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
    writer.line('    if (g_port_${stream.dartName} == dart_port) { g_port_${stream.dartName} = 0; }');
    writer.line('}');
    writer.blankLine();
  }

  // ── Struct release functions (used by NativeFinalizer in Dart proxy classes) ─
  for (final st in spec.structs) {
    writer.line('// Frees a malloc\'d [${st.name}] wrapper allocated by the stream emitter.');
    writer.line('// Called automatically by NativeFinalizer when the Dart proxy is GC\'d.');
    writer.line('void ${libStem}_release_${st.name}(void* ptr) {');
    writer.line('    if (!ptr) { return; }');

    final hasStrings = st.fields.any((f) => f.type.name == 'String');
    final hasNestedStructs = st.fields.any((f) => structNames.contains(f.type.name.replaceFirst('?', '')));
    final hasNonZcData = st.fields.any((f) => f.type.isTypedData && !f.zeroCopy);
    final hasZeroCopy = st.fields.any((f) => f.zeroCopy);
    if (hasStrings || hasNestedStructs || hasNonZcData) {
      writer.line('    ${st.name}* st_ptr = (${st.name}*)ptr;');
      for (final f in st.fields) {
        if (f.type.name == 'String') {
          writer.line('    if (st_ptr->${f.name}) { free((void*)st_ptr->${f.name}); }');
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
      writer.line('            if (_env != nullptr) { _env->DeleteGlobalRef(it->second); }');

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
