import 'package:nitro_annotations/nitro_annotations.dart' show CppImpl;

import '../../../bridge_item_kind.dart';
import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';
import '../cpp_native/cpp_interface_generator.dart';

part 'cpp_bridge/swift_shim_emitter.dart';
part 'cpp_bridge/cpp_direct_emitter.dart';
part 'cpp_bridge/type_emitter.dart';
part 'cpp_bridge/jni_swift_prologue.dart';
part 'cpp_bridge/jni_method_emitter.dart';

class CppBridgeGenerator {
  static String generate(BridgeSpec spec) {
    // All targeted platforms use C++ — emit the lean direct-call bridge.
    if (spec.isCppImpl) return _generateCppDirect(spec);

    final iosIsCpp = spec.iosIsCpp;
    final macosIsCpp = spec.macosIsCpp;
    // hasApple covers both iOS and macOS (either may use Swift or C++).
    final hasApple = spec.targetsIos || spec.targetsMacos;

    if (hasApple && !spec.targetsAndroid) {
      return _generateJniSwift(spec, includeAndroid: false, iosIsCpp: iosIsCpp, macosIsCpp: macosIsCpp);
    }
    if (!hasApple && spec.targetsAndroid) {
      return _generateJniSwift(spec, includeIos: false, iosIsCpp: iosIsCpp, macosIsCpp: macosIsCpp);
    }
    return _generateJniSwift(spec, iosIsCpp: iosIsCpp, macosIsCpp: macosIsCpp);
  }

  // ── Helpers shared between both paths ────────────────────────────────────

  // ── Legacy JNI+Swift path (NativeImpl.kotlin / NativeImpl.swift) ───────────

  // ignore: avoid_positional_boolean_parameters
  static String _generateJniSwift(
    BridgeSpec spec, {
    bool includeAndroid = true,
    bool includeIos = true,
    bool iosIsCpp = false,
    bool macosIsCpp = false,
  }) {
    final writer = CodeWriter();
    final headerName = '${spec.lib.replaceAll('-', '_')}.bridge.g.h';
    final hasApple = spec.targetsIos || spec.targetsMacos;

    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    writer.line('#include <stdint.h>');
    writer.line('#include <stdbool.h>');
    writer.line('#include <string.h>');
    writer.line('#include <stdlib.h>');
    if (hasApple) {
      writer.line('#if defined(__APPLE__)');
      writer.line('#import <Foundation/Foundation.h>');
      writer.line('#endif');
    }
    // dlfcn.h provides Dl_info/dladdr/dlopen used by enable_native_bindings on Android/Linux.
    writer.line('#if defined(__ANDROID__) || defined(__linux__)');
    writer.line('#include <dlfcn.h>');
    writer.line('#endif');
    // C++ standard headers needed when any Apple platform uses NativeImpl.cpp.
    if (iosIsCpp || macosIsCpp) {
      writer.line('#include <string>');
      writer.line('#include <stdexcept>');
    }
    final hasCallbacks = spec.functions.any((f) => f.params.any((p) => p.type.isFunction));
    if (hasCallbacks) {
      writer.line('#include <mutex>');
      writer.line('#include <unordered_map>');
    }
    writer.line('#include "dart_api_dl.h"');
    writer.line('#include "$headerName"');
    writer.blankLine();
    // MSVC deprecates the POSIX name (warning C4996); _strdup is identical.
    writer.line('#if defined(_MSC_VER) && !defined(strdup)');
    writer.line('#define strdup _strdup');
    writer.line('#endif');
    writer.blankLine();

    final libStem = spec.lib.replaceAll('-', '_');
    final libPkg = 'nitro/${libStem}_module';
    final checksum = bridgeSpecChecksum(spec);
    // Pre-build O(1) lookup sets — avoids O(n×m) .any() scans inside the
    // generation loops (functions × enums, params × structs, etc.).
    final enumNames = spec.enums.map((e) => e.name).toSet();
    final structNames = spec.structs.map((s) => s.name).toSet();
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

    writer.line('static thread_local NitroError g_nitro_error = { 0, nullptr, nullptr, nullptr, nullptr };');
    writer.blankLine();
    writer.line('extern "C" {');
    writer.line('NitroError* ${libStem}_get_error() { return &g_nitro_error; }');
    writer.line('void ${libStem}_clear_error() {');
    writer.line('    g_nitro_error.hasError = 0;');
    writer.line('    if (g_nitro_error.name) { free((void*)g_nitro_error.name); g_nitro_error.name = nullptr; }');
    writer.line('    if (g_nitro_error.message) { free((void*)g_nitro_error.message); g_nitro_error.message = nullptr; }');
    writer.line('    if (g_nitro_error.code) { free((void*)g_nitro_error.code); g_nitro_error.code = nullptr; }');
    writer.line('    if (g_nitro_error.stackTrace) { free((void*)g_nitro_error.stackTrace); g_nitro_error.stackTrace = nullptr; }');
    writer.line('}');
    writer.blankLine();
    writer.line('static void nitro_report_error(const char* name, const char* message, const char* code, const char* stack) {');
    writer.line('    ${libStem}_clear_error();');
    writer.line('    g_nitro_error.hasError = 1;');
    writer.line('    g_nitro_error.name = name ? strdup(name) : strdup("NativeException");');
    writer.line('    g_nitro_error.message = message ? strdup(message) : strdup("An unknown native exception occurred.");');
    writer.line('    g_nitro_error.code = code ? strdup(code) : nullptr;');
    writer.line('    g_nitro_error.stackTrace = stack ? strdup(stack) : nullptr;');
    writer.line('}');
    writer.line('}');
    writer.blankLine();

    // ── @NitroOwned release functions ────────────────────────────────────────────
    // Emitted globally (before platform guards) so the symbol exists on ALL platforms.
    // On Android, the handle is a jlong from Kotlin — Kotlin GC manages lifecycle (no-op).
    // On Apple/Desktop, the handle is from UnsafeMutableRawPointer.allocate (system malloc).
    final ownedFuncs = spec.functions.where((f) => f.isOwned && f.returnType.isNativeHandle).toList();
    if (ownedFuncs.isNotEmpty) {
      writer.line('extern "C" {');
      for (final f in ownedFuncs) {
        // On all platforms the handle is a real malloc'd pointer:
        //   Android: allocated via sun.misc.Unsafe.allocateMemory (ART calls malloc internally).
        //   Apple:   allocated via UnsafeMutableRawPointer.allocate.
        // Both are freed with free().
        writer.line('NITRO_EXPORT void ${f.cSymbol}_release(void* handle) {');
        writer.line('    if (handle) { free(handle); }');
        writer.line('}');
      }
      writer.line('}');
      writer.blankLine();
    }

    // ── Struct release functions (used by NativeFinalizer in Dart proxy classes) ──
    if (spec.structs.isNotEmpty) {
      // Structs that cross as ZERO-COPY stream items are pinned through a JNI
      // global ref on Android (g_zero_copy_refs in the JNI prologue) so the JVM
      // object backing the borrowed buffers stays alive while Dart reads them.
      // Their release function must drop that pin: without it every delivered
      // item leaks one global reference, and ART aborts the process once the
      // global-reference table (51200 slots) fills — ~51k stream items.
      final zeroCopyStreamStructNames = spec.streams
          .where((s) => structNames.contains(s.itemType.name.replaceFirst('?', '')))
          .map((s) => s.itemType.name.replaceFirst('?', ''))
          .where((name) {
            final st = spec.structByName(name);
            return st != null && st.fields.any((f) => f.zeroCopy);
          })
          .toSet();
      writer.line('extern "C" {');
      if (zeroCopyStreamStructNames.isNotEmpty) {
        writer.line('#ifdef __ANDROID__');
        writer.line('// Defined in the JNI section below: erases the g_zero_copy_refs pin for');
        writer.line('// [ptr] and deletes the JNI global ref (see the JNI prologue).');
        writer.line('void ${libStem}_zero_copy_release(void* ptr);');
        writer.line('#endif');
      }
      for (final st in spec.structs) {
        writer.line('void ${libStem}_release_${st.name}(void* ptr) {');
        writer.line('    if (!ptr) { return; }');
        if (zeroCopyStreamStructNames.contains(st.name)) {
          writer.line('#ifdef __ANDROID__');
          writer.line('    ${libStem}_zero_copy_release(ptr);');
          writer.line('#endif');
        }

        final hasStrings = st.fields.any((f) => f.type.name == 'String');
        final hasNestedStructs = st.fields.any((f) => structNames.contains(f.type.name.replaceFirst('?', '')));
        final hasNonZcDataJni = st.fields.any((f) => f.type.isTypedData && !f.zeroCopy);
        if (hasStrings || hasNestedStructs || hasNonZcDataJni) {
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
        writer.line('    free(ptr);');
        writer.line('}');
      }
      writer.line('}');
      writer.blankLine();
    }

    // ── Finding 1: enable_native_bindings (Android/Linux only) ──────────────────
    // Promotes the already-loaded native library to process-wide symbol visibility
    // (RTLD_GLOBAL) so that @Native<F>() Dart bindings can resolve via
    // DynamicLibrary.process() on Android/Linux.
    // On iOS/macOS the library is statically linked — symbols are already visible,
    // so this function is a no-op (the #if guard excludes all code).
    // Emitted whenever the spec has sync functions that may qualify for @Native<F>
    // leaf bindings. Call once from Kotlin plugin init after System.loadLibrary().
    final hasSyncFunctions = spec.functions.any((f) => !f.isAsync && !f.isNativeAsync);
    if (hasSyncFunctions) {
      writer.line('#if defined(__ANDROID__) || defined(__linux__)');
      writer.line('static void* _${libStem}_lib_h = nullptr;');
      writer.line('#endif');
      writer.blankLine();
      writer.line('extern "C" {');
      writer.line('// Finding 1: promotes this native library to process-wide visibility so that');
      writer.line('// @Native<F>() Dart bindings resolve via DynamicLibrary.process() on Android/Linux.');
      writer.line('// On iOS/macOS this is a no-op — symbols are already in the process namespace');
      writer.line('// via static linking.  Call once from the Kotlin/Swift plugin init.');
      writer.line('NITRO_EXPORT void ${libStem}_enable_native_bindings(void) {');
      writer.line('#if defined(__ANDROID__) || defined(__linux__)');
      writer.line('    if (!_${libStem}_lib_h) {');
      writer.line('        Dl_info info;');
      writer.line('        if (dladdr((void*)${libStem}_enable_native_bindings, &info) && info.dli_fname) {');
      writer.line('            // RTLD_GLOBAL | RTLD_NOLOAD promotes already-loaded lib to global namespace');
      writer.line('            // without re-loading it, making symbols available to DynamicLibrary.process().');
      writer.line('            _${libStem}_lib_h = dlopen(info.dli_fname, RTLD_LAZY | RTLD_GLOBAL | RTLD_NOLOAD);');
      writer.line('        }');
      writer.line('    }');
      writer.line('#endif');
      writer.line('}');
      writer.line('}');
      writer.blankLine();
    }

    // ── Callback release infrastructure ─────────────────────────────────────────
    // Global map: callbackPtr → Dart release port. Dart registers via
    // ${libStem}_registerCallbackRelease(); Kotlin calls _release_* JNI methods
    // which post to the port, signalling Dart to close the NativeCallable.
    if (hasCallbacks) {
      writer.line('static std::mutex g_cb_release_mtx;');
      writer.line('static std::unordered_map<int64_t, Dart_Port> g_cb_release_ports;');
      writer.blankLine();
      writer.line('extern "C" {');
      writer.line('NITRO_EXPORT void ${libStem}_registerCallbackRelease(int64_t callbackPtr, int64_t releasePort) {');
      writer.line('    std::lock_guard<std::mutex> _lk(g_cb_release_mtx);');
      writer.line('    g_cb_release_ports[callbackPtr] = (Dart_Port)releasePort;');
      writer.line('}');
      writer.line('}');
      writer.blankLine();
    }

    // Preprocessor branch for Android JNI vs iOS Swift
    if (includeAndroid && includeIos) writer.line('#ifdef __ANDROID__');
    if (includeAndroid) {
      _emitJniSwiftPrologue(writer, spec, libStem, enumNames, structNames);

      _emitJniMethods(writer, spec, libStem, libPkg, enumNames, structNames);
    } // end if (includeAndroid)

    // ── Apple section: NativeImpl.swift / NativeImpl.cpp / mixed ─────────────
    // Determine per-platform Apple strategy.
    final appleBothCpp = iosIsCpp && macosIsCpp;
    final appleMixedMacosCpp = macosIsCpp && !iosIsCpp && spec.targetsMacos;
    final appleMixedIosCpp = iosIsCpp && !macosIsCpp && spec.targetsIos;
    // The Apple section is emitted when iOS is Swift/C++ OR macOS is C++.
    final includeApple = includeIos || (macosIsCpp && spec.targetsMacos);

    if (includeAndroid && includeApple) writer.line('#elif __APPLE__');

    if (includeApple) {
      if (appleBothCpp) {
        // Both iOS and macOS use NativeImpl.cpp — unified C++ dispatch.
        _emitAppleCppDispatch(writer, spec, libStem, enumNames, structNames);
      } else if (appleMixedMacosCpp) {
        // macOS → NativeImpl.cpp, iOS → NativeImpl.swift
        writer.line('#include <TargetConditionals.h>');
        writer.line('#if TARGET_OS_OSX  // macOS: NativeImpl.cpp — direct C++ dispatch');
        _emitAppleCppDispatch(writer, spec, libStem, enumNames, structNames);
        if (includeIos) {
          writer.line('#else  // iOS: NativeImpl.swift — call through Swift bridge');
          _emitSwiftBridgeSection(writer, spec, libStem, enumNames, structNames);
        }
        writer.line('#endif  // TARGET_OS_OSX');
      } else if (appleMixedIosCpp) {
        // iOS → NativeImpl.cpp, macOS → NativeImpl.swift (or absent)
        writer.line('#include <TargetConditionals.h>');
        writer.line('#if TARGET_OS_IOS  // iOS: NativeImpl.cpp — direct C++ dispatch');
        _emitAppleCppDispatch(writer, spec, libStem, enumNames, structNames);
        if (spec.targetsMacos) {
          writer.line('#else  // macOS: NativeImpl.swift — call through Swift bridge');
          _emitSwiftBridgeSection(writer, spec, libStem, enumNames, structNames);
        }
        writer.line('#endif  // TARGET_OS_IOS');
      } else if (includeIos) {
        // Pure Swift on all Apple platforms (legacy / default path).
        _emitSwiftBridgeSection(writer, spec, libStem, enumNames, structNames);
      }
    }
    // ── Desktop C++ section: Windows / Linux ────────────────────────────────
    // When Windows or Linux targets use NativeImpl.cpp in a mixed spec
    // (e.g. android:kotlin + windows:cpp), emit a direct C++ dispatch block
    // guarded by the appropriate preprocessor macro.
    final targetsWindowsCpp = spec.targetsWindows && (spec.windowsImpl is CppImpl);
    final targetsLinuxCpp = spec.targetsLinux && (spec.linuxImpl is CppImpl);
    final hasDesktopCpp = targetsWindowsCpp || targetsLinuxCpp;

    if (hasDesktopCpp) {
      // Build the preprocessor guard for the desktop platforms that use C++.
      final guards = <String>[
        if (targetsWindowsCpp) 'defined(_WIN32)',
        if (targetsLinuxCpp) 'defined(__linux__)',
      ].join(' || ');

      // Only emit the #elif chain if we're already inside an #ifdef block.
      // If neither Android nor Apple was targeted, the desktop section is the
      // only section — no #ifdef wrapper is needed (isCppImpl would have been
      // true and we'd have gone through _generateCppDirect instead).
      final insideIfdef = includeAndroid || includeApple;
      if (insideIfdef) {
        writer.line('#elif $guards  // Windows/Linux: NativeImpl.cpp — direct C++ dispatch');
      }
      _emitAppleCppDispatch(writer, spec, libStem, enumNames, structNames);
    }

    // Close the preprocessor ifdef chain when more than one platform section
    // was opened (android+apple or android+desktop).
    if (includeAndroid && (includeApple || hasDesktopCpp)) writer.line('#endif');
    return writer.toString();
  }

  // ── Apple C++ dispatch section emitter ────────────────────────────────────
  // Emits the virtual-dispatch bridge for an Apple platform using NativeImpl.cpp.
  // Headers and global error state are already emitted before this is called.
  // Struct release functions are emitted globally in the JNI section — not here.
  static void _emitAppleCppDispatch(
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

    for (final stream in spec.streams) {
      writer.line('static int64_t g_port_${stream.dartName} = 0;');
    }
    if (spec.streams.isNotEmpty) writer.blankLine();

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

    if (spec.functions.any((f) => f.isResult)) {
      // @NitroResult wire blob: [1B tag (0=ok, 1=err)][4B len][RecordWriter payload].
      // Dart reads res[0] then RecordReader.fromNative(res + 1), and frees res.
      writer.line('static uint8_t* _nitro_desktop_result_blob(uint8_t _tag, const NitroRecordWriter& _w) {');
      writer.line('    int32_t _len = (int32_t)_w._buf.size();');
      writer.line('    uint8_t* _out = (uint8_t*)malloc((size_t)(1 + 4 + _len));');
      writer.line('    if (!_out) { return nullptr; }');
      writer.line('    _out[0] = _tag;');
      writer.line('    memcpy(_out + 1, &_len, 4);');
      writer.line('    if (_len > 0) { memcpy(_out + 5, _w._buf.data(), (size_t)_len); }');
      writer.line('    return _out;');
      writer.line('}');
      writer.line('static uint8_t* _nitro_desktop_result_err(const char* _msg) {');
      writer.line('    NitroRecordWriter _w;');
      writer.line('    _w.writeString(_msg ? std::string(_msg) : std::string());');
      writer.line('    return _nitro_desktop_result_blob(1, _w);');
      writer.line('}');
      writer.blankLine();
    }
    writer.line('static Hybrid$className* g_impl = nullptr;');
    // For the Apple/C++ single-instance path, create_instance always returns 0 and
    // destroy_instance is a no-op. g_impl is the single shared implementation set
    // by the NativeImpl.cpp constructor via xxx_register_impl().
    writer.line('static int64_t g_next_instance_id = 0;');
    writer.blankLine();
    writer.line('extern "C" {');
    writer.line('void ${libStem}_register_impl(Hybrid$className* impl) { g_impl = impl; }');
    writer.line('Hybrid$className* ${libStem}_get_impl() { return g_impl; }');
    // create_instance: single-instance path — always assigns id 0 for the singleton.
    writer.line('NITRO_EXPORT int64_t ${libStem}_create_instance(const char* key) { (void)key; return g_next_instance_id++; }');
    // destroy_instance: no-op on Apple/C++ path (NativeImpl.cpp manages its own lifetime).
    writer.line('NITRO_EXPORT void ${libStem}_destroy_instance(int64_t instanceId) { (void)instanceId; }');
    if (spec.functions.any((f) => f.zeroCopyReturn && f.returnType.isTypedData)) {
      writer.line('NITRO_EXPORT void ${libStem}_release_typed_data_return(void* ptr) {');
      writer.line('    if (!ptr) { return; }');

      writer.line('    free(ptr);');
      writer.line('}');
    }
    writer.blankLine();

    for (final func in spec.functions) {
      if (func.isNativeAsync) {
        // instanceId is included for API consistency with the JNI path; g_impl ignores it.
        final paramParts = <String>['int64_t instanceId'];
        for (final p in func.params) {
          final isStructParam = structNames.contains(p.type.name.replaceFirst('?', ''));
          final isRecordParam = recordNames.contains(p.type.name.replaceFirst('?', ''));
          final isEnumParam = enumNames.contains(p.type.name.replaceFirst('?', ''));
          // Maps stay on _typeToC (uint8_t*) — matches the bridge.g.h declaration.
          final isMapParam = p.type.name.startsWith('Map<');
          paramParts.add('${(isStructParam || (isRecordParam && !isMapParam)) ? 'void*' : (isEnumParam ? 'int64_t' : _typeToC(p.type.name))} ${p.name}');
          if (p.type.isTypedData) paramParts.add('size_t ${p.name}_length'); // matches Dart FFI Size type
        }
        paramParts.add('int64_t dart_port');
        final paramsDecl = paramParts.join(', ');
        final callArgs = <String>[];
        for (final p in func.params) {
          final base = p.type.name.replaceFirst('?', '');
          final isNullableParam = p.type.isNullable || p.type.name.endsWith('?');
          if (p.type.isAnyNativeObject) {
            if (p.type.isNullable) {
              callArgs.add('${p.name} == -1 ? std::optional<int64_t>(std::nullopt) : std::make_optional<int64_t>(${p.name})');
            } else {
              callArgs.add(p.name);
            }
          } else if (spec.isCustomTypeName(base)) {
            callArgs.add(p.name);
          } else if (p.type.name == 'int?' || p.type.name == 'DateTime?') {
            callArgs.add('(${p.name} == nullptr || ${p.name}[0] == 0) ? std::optional<int64_t>(std::nullopt) : std::make_optional(*reinterpret_cast<const int64_t*>(${p.name} + 1))');
          } else if (p.type.name == 'uint64?') {
            callArgs.add('(${p.name} == nullptr || ${p.name}[0] == 0) ? std::optional<uint64_t>(std::nullopt) : std::make_optional(*reinterpret_cast<const uint64_t*>(${p.name} + 1))');
          } else if (p.type.name == 'double?') {
            callArgs.add('(${p.name} == nullptr || ${p.name}[0] == 0) ? std::optional<double>(std::nullopt) : std::make_optional(*reinterpret_cast<const double*>(${p.name} + 1))');
          } else if (p.type.name == 'bool?') {
            callArgs.add('(${p.name} == nullptr || ${p.name}[0] == 0) ? std::optional<bool>(std::nullopt) : std::make_optional(${p.name}[1] != 0)');
          } else if (base == 'String') {
            if (isNullableParam) {
              callArgs.add('${p.name} == nullptr ? std::optional<std::string>(std::nullopt) : std::make_optional(std::string(${p.name}))');
            } else {
              callArgs.add('std::string(${p.name})');
            }
          } else if (structNames.contains(base)) {
            if (isNullableParam) {
              callArgs.add('${p.name} == nullptr ? std::optional<$base>(std::nullopt) : std::make_optional(*static_cast<const $base*>(${p.name}))');
            } else {
              callArgs.add('*static_cast<const $base*>(${p.name})');
            }
          } else if (recordNames.contains(base) || variantNames.contains(base)) {
            callArgs.add('NitroCppBuffer{ (const uint8_t*)${p.name} + 4, (size_t)*(int32_t*)${p.name} }');
          } else if (p.type.isTypedData) {
            callArgs.add(p.name);
            callArgs.add('static_cast<size_t>(${p.name}_length)');
          } else if (enumNames.contains(base)) {
            if (isNullableParam) {
              callArgs.add('${p.name} == -1 ? std::optional<$base>(std::nullopt) : std::make_optional(static_cast<$base>(${p.name}))');
            } else {
              callArgs.add('static_cast<$base>(${p.name})');
            }
          } else {
            callArgs.add(p.name);
          }
        }
        callArgs.add('dart_port');
        writer.line('void ${func.cSymbol}($paramsDecl) {');
        writer.line('    if (!g_impl) {');
        writer.line('        Dart_CObject _err = { Dart_CObject_kNull };');
        writer.line('        Dart_PostCObject_DL(dart_port, &_err);');
        writer.line('        return;');
        writer.line('    }');
        writer.line('    g_impl->${func.dartName}(${callArgs.join(', ')});');
        writer.line('}');
        writer.blankLine();
        continue;
      }

      final retBase = func.returnType.name.replaceFirst('?', '');
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
          : func.returnType.name == 'int?' ? 'uint8_t*'
          : func.returnType.name == 'double?' ? 'uint8_t*'
          : func.returnType.name == 'bool?' ? 'uint8_t*'
          : func.returnType.name == 'DateTime?' ? 'uint8_t*'
          : func.returnType.name == 'uint64?' ? 'uint8_t*'
          : func.returnType.isTypedData
          ? 'uint8_t*'
          : _typeToC(func.returnType.name);
      // Result methods must never return nullptr — Dart reads res[0] unconditionally.
      final dflt = func.isResult
          ? '_nitro_desktop_result_err("native error")'
          : _defaultValue(cRet);
      // instanceId is included for API consistency with the JNI path; g_impl ignores it.
      final paramParts = <String>['int64_t instanceId'];
      for (final p in func.params) {
        final isStructParam = structNames.contains(p.type.name.replaceFirst('?', ''));
        final isRecordParam = p.type.isRecord;
        final isEnumParam = enumNames.contains(p.type.name.replaceFirst('?', ''));
        if (p.type.isFunction) {
          paramParts.add(_callbackParamToC(p, enumNames, structNames: structNames, recordNames: recordNames, variantNames: variantNames));
        } else {
          // Nullable prims use const uint8_t* (raw byte pointer via NitroOptXxx layout).
          // Maps stay on _typeToC (uint8_t*) — matches the bridge.g.h declaration.
          final isMapParam = p.type.name.startsWith('Map<');
          final cType = isEnumParam
              ? 'int64_t'
              : ((isStructParam || (isRecordParam && !isMapParam)) ? 'void*' : _typeToC(p.type.name));
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
        writer.line('    if (!g_impl) { $funcNotInit; return; }');
      } else {
        writer.line('    if (!g_impl) { $funcNotInit; return $dflt; }');
      }
      writer.line('    try {');
      final callArgs = <String>[];
      for (final p in func.params) {
        final base = p.type.name.replaceFirst('?', '');
        final isNullableParam = p.type.isNullable || p.type.name.endsWith('?');
        if (p.type.isFunction) {
          callArgs.add(_emitDesktopCallbackWrapper(
            writer, spec, p, enumNames, structNames, recordNames, variantNames,
          ));
        } else if (p.type.name == 'int?' || p.type.name == 'DateTime?') {
          writer.line('        std::optional<int64_t> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(*reinterpret_cast<const int64_t*>(${p.name} + 1));');
          callArgs.add('_opt_${p.name}');
        } else if (p.type.name == 'uint64?') {
          writer.line('        std::optional<uint64_t> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(*reinterpret_cast<const uint64_t*>(${p.name} + 1));');
          callArgs.add('_opt_${p.name}');
        } else if (p.type.name == 'double?') {
          writer.line('        std::optional<double> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(*reinterpret_cast<const double*>(${p.name} + 1));');
          callArgs.add('_opt_${p.name}');
        } else if (p.type.name == 'bool?') {
          writer.line('        std::optional<bool> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(${p.name}[1] != 0);');
          callArgs.add('_opt_${p.name}');
        } else if (base == 'String') {
          if (isNullableParam) {
            // Null Dart string arrives as nullptr — never construct std::string from it.
            callArgs.add('${p.name} == nullptr ? std::optional<std::string>(std::nullopt) : std::make_optional(std::string(${p.name}))');
          } else {
            callArgs.add('std::string(${p.name})');
          }
        } else if (structNames.contains(base)) {
          if (isNullableParam) {
            callArgs.add('${p.name} == nullptr ? std::optional<$base>(std::nullopt) : std::make_optional(*static_cast<const $base*>(${p.name}))');
          } else {
            callArgs.add('*static_cast<const $base*>(${p.name})');
          }
        } else if (p.type.isRecord || variantNames.contains(base)) {
          if (isNullableParam) {
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
        } else if (p.type.isAnyNativeObject) {
          // AnyNativeObject: pass raw instanceId; nullable: -1 = null sentinel
          if (p.type.isNullable) {
            callArgs.add('${p.name} == -1 ? std::optional<int64_t>(std::nullopt) : std::make_optional<int64_t>(${p.name})');
          } else {
            callArgs.add(p.name);
          }
        } else if (spec.isCustomTypeName(base)) {
          // @NitroCustomType: pass raw byte buffer pointer (user's native codec decodes)
          callArgs.add(p.name);
        } else if (enumNames.contains(base)) {
          if (isNullableParam) {
            // Nullable enums use the -1 wire sentinel (never a valid nativeValue).
            callArgs.add('${p.name} == -1 ? std::optional<$base>(std::nullopt) : std::make_optional(static_cast<$base>(${p.name}))');
          } else {
            callArgs.add('static_cast<$base>(${p.name})');
          }
        } else {
          callArgs.add(p.name);
        }
      }
      final callArgStr = callArgs.join(', ');

      final isNullableRet = func.returnType.isNullable || func.returnType.name.endsWith('?');
      if (func.isResult) {
        // @NitroResult: impl signals the error case by throwing; the ok value
        // is wrapped in the [1B tag][4B len][payload] blob Dart expects.
        if (retBase == 'double') {
          writer.line('        double _val = g_impl->${func.dartName}($callArgStr);');
          writer.line('        NitroRecordWriter _w;');
          writer.line('        _w.writeDouble(_val);');
        } else if (retBase == 'int') {
          writer.line('        int64_t _val = g_impl->${func.dartName}($callArgStr);');
          writer.line('        NitroRecordWriter _w;');
          writer.line('        _w.writeInt(_val);');
        } else if (retBase == 'bool') {
          writer.line('        bool _val = g_impl->${func.dartName}($callArgStr);');
          writer.line('        NitroRecordWriter _w;');
          writer.line('        _w.writeBool(_val);');
        } else {
          writer.line('        std::string _val = g_impl->${func.dartName}($callArgStr);');
          writer.line('        NitroRecordWriter _w;');
          writer.line('        _w.writeString(_val);');
        }
        writer.line('        return _nitro_desktop_result_blob(0, _w);');
      } else if (func.returnType.name == 'void') {
        writer.line('        g_impl->${func.dartName}($callArgStr);');
      } else if (retBase == 'String' && isNullableRet) {
        writer.line('        std::optional<std::string> _res = g_impl->${func.dartName}($callArgStr);');
        writer.line('        return _res.has_value() ? strdup(_res->c_str()) : nullptr;');
      } else if (func.returnType.name == 'String') {
        writer.line('        std::string _res = g_impl->${func.dartName}($callArgStr);');
        writer.line('        return strdup(_res.c_str());');
      } else if (isEnumRet && isNullableRet) {
        writer.line('        std::optional<$retBase> _res = g_impl->${func.dartName}($callArgStr);');
        writer.line('        return _res.has_value() ? static_cast<int64_t>(*_res) : -1LL;');
      } else if (isEnumRet) {
        writer.line('        return static_cast<int64_t>(g_impl->${func.dartName}($callArgStr));');
      } else if (isStructRet && isNullableRet) {
        writer.line('        std::optional<$retBase> _res = g_impl->${func.dartName}($callArgStr);');
        writer.line('        if (!_res.has_value()) { return nullptr; }');
        writer.line('        $retBase* _ptr = ($retBase*)malloc(sizeof($retBase));');
        writer.line('        *_ptr = *_res;');
        writer.line('        return _ptr;');
      } else if (isStructRet) {
        final stName = func.returnType.name.replaceFirst('?', '');
        writer.line('        $stName _res = g_impl->${func.dartName}($callArgStr);');
        writer.line('        $stName* _ptr = ($stName*)malloc(sizeof($stName));');
        writer.line('        *_ptr = _res;');
        writer.line('        return _ptr;');
      } else if (isVariantRet) {
        // Impl returns a malloc'd [4B len][payload] block (toNativeBuffer / _to_native).
        writer.line('        NitroCppBuffer _res = g_impl->${func.dartName}($callArgStr);');
        writer.line('        return (uint8_t*)_res.data;');
      } else if (func.returnType.name == 'int?' || func.returnType.name == 'DateTime?') {
        writer.line('        std::optional<int64_t> _opt = g_impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = (uint8_t*)malloc(9);');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        if (_opt.has_value()) { *reinterpret_cast<int64_t*>(_res + 1) = _opt.value(); }');
        writer.line('        return _res;');
      } else if (func.returnType.name == 'uint64?') {
        writer.line('        std::optional<uint64_t> _opt = g_impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = (uint8_t*)malloc(9);');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        if (_opt.has_value()) { *reinterpret_cast<uint64_t*>(_res + 1) = _opt.value(); }');
        writer.line('        return _res;');
      } else if (func.returnType.name == 'double?') {
        writer.line('        std::optional<double> _opt = g_impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = (uint8_t*)malloc(9);');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        if (_opt.has_value()) { *reinterpret_cast<double*>(_res + 1) = _opt.value(); }');
        writer.line('        return _res;');
      } else if (func.returnType.name == 'bool?') {
        writer.line('        std::optional<bool> _opt = g_impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = (uint8_t*)malloc(2);');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        _res[1] = (_opt.has_value() && _opt.value()) ? 1 : 0;');
        writer.line('        return _res;');
      } else if (func.returnType.isAnyNativeObject) {
        if (func.returnType.isNullable) {
          writer.line('        std::optional<int64_t> _optId = g_impl->${func.dartName}($callArgStr);');
          writer.line('        return _optId.has_value() ? _optId.value() : -1LL;');
        } else {
          writer.line('        return g_impl->${func.dartName}($callArgStr);');
        }
      } else if (isCustomTypeRet) {
        final ct = spec.customTypeByName(retBase)!;
        if (func.returnType.isNullable) {
          writer.line('        uint8_t* _res = g_impl->${func.dartName}($callArgStr);');
          writer.line('        return _res; // nullptr = null from native');
        } else {
          writer.line('        uint8_t* _res = g_impl->${func.dartName}($callArgStr);');
          writer.line('        if (_res == nullptr) { nitro_report_error("TypeError", "${func.dartName}: ${ct.name} must not return null", nullptr, nullptr); return nullptr; }');
          writer.line('        return _res;');
        }
      } else if (isRecordRet) {
        // Impl returns a malloc'd [4B len][payload] block (toNativeBuffer);
        // cast matches the declared C return type (void* records, uint8_t* maps).
        writer.line('        NitroCppBuffer _res = g_impl->${func.dartName}($callArgStr);');
        writer.line('        return ($cRet)_res.data;');
      } else if (isZeroCopyTypedDataRet) {
        writer.line('        NitroCppBuffer _res = g_impl->${func.dartName}($callArgStr);');
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
        writer.line('        return g_impl->${func.dartName}($callArgStr);');
      }
      if (func.isResult) {
        // @NitroResult: the thrown message becomes the NitroErr payload —
        // Dart reads res[0] unconditionally, so never surface via NitroError.
        writer.line('    } catch (const std::exception& e) {');
        writer.line('        return _nitro_desktop_result_err(e.what());');
        writer.line('    } catch (...) {');
        writer.line('        return _nitro_desktop_result_err("Unknown C++ exception");');
        writer.line('    }');
      } else {
        writer.line('    } catch (const std::exception& e) {');
        writer.line(func.isAsync
            ? '        nitro_report_error("CppException", e.what(), nullptr, nullptr);'
            : '        _nitro_desktop_err(_nitro_err, "CppException", e.what());');
        if (func.returnType.name != 'void') writer.line('        return $dflt;');
        writer.line('    } catch (...) {');
        writer.line(func.isAsync
            ? '        nitro_report_error("CppException", "Unknown C++ exception", nullptr, nullptr);'
            : '        _nitro_desktop_err(_nitro_err, "CppException", "Unknown C++ exception");');
        if (func.returnType.name != 'void') writer.line('        return $dflt;');
        writer.line('    }');
      }
      writer.line('}');
      writer.blankLine();
    }

    for (final prop in spec.properties) {
      final isEnum = enumNames.contains(prop.type.name.replaceFirst('?', ''));
      final isVariantProp = variantNames.contains(prop.type.name.replaceFirst('?', ''));
      // Property getter: nullable prim/variant returns uint8_t* pointer (malloc'd, Dart frees).
      final cType = isEnum ? 'int64_t'
          : prop.type.name == 'int?' ? 'uint8_t*'
          : prop.type.name == 'double?' ? 'uint8_t*'
          : prop.type.name == 'bool?' ? 'uint8_t*'
          : prop.type.name == 'DateTime?' ? 'uint8_t*'
          : isVariantProp ? 'uint8_t*'
          : _typeToC(prop.type.name);
      if (prop.hasGetter) {
        // instanceId is included for API consistency with the JNI path; g_impl ignores it.
        writer.line('$cType ${prop.getSymbol}(int64_t instanceId, NitroError* _nitro_err) {');
        writer.line('    ${libStem}_clear_error();');
        writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }  // S8: clear slot');
        writer.line('    if (!g_impl) { $notInitOut; return ${_defaultValue(cType)}; }');
        final isNullableProp = prop.type.isNullable || prop.type.name.endsWith('?');
        writer.line('    try {');
        if (prop.type.name == 'String') {
          writer.line('        std::string _res = g_impl->get_${prop.dartName}();');
          writer.line('        return strdup(_res.c_str());');
        } else if (prop.type.name == 'String?') {
          writer.line('        std::optional<std::string> _res = g_impl->get_${prop.dartName}();');
          writer.line('        return _res.has_value() ? strdup(_res->c_str()) : nullptr;');
        } else if (isEnum && isNullableProp) {
          final enumName = prop.type.name.replaceFirst('?', '');
          writer.line('        std::optional<$enumName> _res = g_impl->get_${prop.dartName}();');
          writer.line('        return _res.has_value() ? static_cast<int64_t>(*_res) : -1LL;');
        } else if (isEnum) {
          writer.line('        return static_cast<int64_t>(g_impl->get_${prop.dartName}());');
        } else if (prop.type.name == 'int?') {
          writer.line('        std::optional<int64_t> _opt = g_impl->get_${prop.dartName}();');
          writer.line('        uint8_t* _res = (uint8_t*)malloc(9);');
          writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
          writer.line('        if (_opt.has_value()) { *reinterpret_cast<int64_t*>(_res + 1) = _opt.value(); }');
          writer.line('        return _res;');
        } else if (prop.type.name == 'double?') {
          writer.line('        std::optional<double> _opt = g_impl->get_${prop.dartName}();');
          writer.line('        uint8_t* _res = (uint8_t*)malloc(9);');
          writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
          writer.line('        if (_opt.has_value()) { *reinterpret_cast<double*>(_res + 1) = _opt.value(); }');
          writer.line('        return _res;');
        } else if (prop.type.name == 'bool?') {
          writer.line('        std::optional<bool> _opt = g_impl->get_${prop.dartName}();');
          writer.line('        uint8_t* _res = (uint8_t*)malloc(2);');
          writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
          writer.line('        _res[1] = (_opt.has_value() && _opt.value()) ? 1 : 0;');
          writer.line('        return _res;');
        } else if (prop.type.name == 'DateTime?') {
          writer.line('        std::optional<int64_t> _opt = g_impl->get_${prop.dartName}();');
          writer.line('        uint8_t* _res = (uint8_t*)malloc(9);');
          writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
          writer.line('        if (_opt.has_value()) { *reinterpret_cast<int64_t*>(_res + 1) = _opt.value(); }');
          writer.line('        return _res;');
        } else if (isVariantProp) {
          // Impl returns a malloc'd [4B len][payload] block (toNativeBuffer).
          writer.line('        NitroCppBuffer _res = g_impl->get_${prop.dartName}();');
          writer.line('        return (uint8_t*)_res.data;');
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
        writer.line('        _nitro_desktop_err(_nitro_err, "CppException", e.what());');
        writer.line('        return ${_defaultValue(cType)};');
        writer.line('    }');
        writer.line('}');
        writer.blankLine();
      }
      if (prop.hasSetter) {
        final isStructParam = structNames.contains(prop.type.name.replaceFirst('?', ''));
        final isRecordParam = recordNames.contains(prop.type.name.replaceFirst('?', ''));
        final isNullablePropSetter = prop.type.isNullable || prop.type.name.endsWith('?');
        final isNullablePrimSetter = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?' || prop.type.name == 'DateTime?' || prop.type.name == 'uint64?';
        final paramCType = isNullablePrimSetter
            ? 'const uint8_t*'
            : isVariantProp
            ? 'const uint8_t*'
            : (isEnum || isStructParam || isRecordParam) ? (isEnum ? 'int64_t' : 'void*') : _typeToC(prop.type.name);
        // instanceId is included for API consistency with the JNI path; g_impl ignores it.
        writer.line('void ${prop.setSymbol}(int64_t instanceId, $paramCType value, NitroError* _nitro_err) {');
        writer.line('    ${libStem}_clear_error();');
        writer.line('    if (_nitro_err) { _nitro_err->hasError = 0; }  // S8: clear slot');
        writer.line('    if (!g_impl) { $notInitOut; return; }');
        writer.line('    try {');
        if (prop.type.name == 'String') {
          writer.line('        g_impl->set_${prop.dartName}(std::string(value));');
        } else if (prop.type.name == 'String?') {
          writer.line('        g_impl->set_${prop.dartName}(value == nullptr ? std::optional<std::string>(std::nullopt) : std::make_optional(std::string(value)));');
        } else if (isEnum && isNullablePropSetter) {
          final enumName = prop.type.name.replaceFirst('?', '');
          writer.line('        g_impl->set_${prop.dartName}(value == -1 ? std::optional<$enumName>(std::nullopt) : std::make_optional(static_cast<$enumName>(value)));');
        } else if (isEnum) {
          final enumName = prop.type.name.replaceFirst('?', '');
          writer.line('        g_impl->set_${prop.dartName}(static_cast<$enumName>(value));');
        } else if (isVariantProp || isRecordParam) {
          final opt = prop.type.name.endsWith('?');
          if (opt) {
            writer.line('        NitroCppBuffer _buf = { nullptr, 0 };');
            writer.line('        if (value != nullptr) {');
            writer.line('            _buf.data = (const uint8_t*)value + 4;');
            writer.line('            _buf.size = (size_t)*(int32_t*)value;');
            writer.line('        }');
            writer.line('        g_impl->set_${prop.dartName}(_buf);');
          } else {
            writer.line('        NitroCppBuffer _buf = { value + 4, (size_t)*(int32_t*)value };');
            writer.line('        g_impl->set_${prop.dartName}(_buf);');
          }
        } else if (prop.type.name == 'int?' || prop.type.name == 'DateTime?') {
          writer.line('        g_impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(*reinterpret_cast<const int64_t*>(value + 1)));');
        } else if (prop.type.name == 'uint64?') {
          writer.line('        g_impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(*reinterpret_cast<const uint64_t*>(value + 1)));');
        } else if (prop.type.name == 'double?') {
          writer.line('        g_impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(*reinterpret_cast<const double*>(value + 1)));');
        } else if (prop.type.name == 'bool?') {
          writer.line('        g_impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(value[1] != 0));');
        } else if (isStructParam) {
          final stName = prop.type.name.replaceFirst('?', '');
          if (_isNullableStructType(prop.type, structNames)) {
            writer.line('        g_impl->set_${prop.dartName}(value == nullptr ? std::optional<$stName>(std::nullopt) : std::make_optional(*static_cast<const $stName*>(value)));');
          } else {
            writer.line('        g_impl->set_${prop.dartName}(*static_cast<const $stName*>(value));');
          }
        } else {
          writer.line('        g_impl->set_${prop.dartName}(value);');
        }
        writer.line('    } catch (const std::exception& e) {');
        writer.line('        _nitro_desktop_err(_nitro_err, "CppException", e.what());');
        writer.line('    }');
        writer.line('}');
        writer.blankLine();
      }
    }

    for (final stream in spec.streams) {
      // instanceId is included for API consistency with the JNI path; g_port is keyed by dartName.
      writer.line('void ${stream.registerSymbol}(int64_t instanceId, int64_t dart_port) {');
      writer.line('    g_port_${stream.dartName} = dart_port;');
      writer.line('}');
      writer.line('void ${stream.releaseSymbol}(int64_t dart_port) {');
      writer.line('    if (g_port_${stream.dartName} == dart_port) { g_port_${stream.dartName} = 0; }');
      writer.line('}');
      writer.blankLine();
    }

    writer.line('} // extern "C"');
  }

  /// Emits a lambda that adapts a raw Dart NativeCallable function pointer to
  /// the impl-facing `std::function<R(Args...)>` signature declared in
  /// native.g.h, and returns the call-argument expression.
  ///
  /// The DECLARED C parameter type (from [_callbackParamToC]) is a documented
  /// lie shared with the JNI/Swift paths — the true Dart-side ABI routes every
  /// scalar through Int64 GP registers (doubles as raw bits, bools as 0/1,
  /// enums as nativeValue), flattens expandable structs to one Int64 per field,
  /// passes records/variants as malloc'd [4B len][payload] pointers that Dart
  /// frees, and returns strings as malloc'd Utf8 pointers that native frees.
  /// Mirrors `dart_callback_helpers.dart` — keep in sync.
  static String _emitDesktopCallbackWrapper(
    CodeWriter writer,
    BridgeSpec spec,
    BridgeParam p,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> recordNames,
    Set<String> variantNames,
  ) {
    final callback = p.type;
    final retDart = callback.functionReturnType ?? 'void';
    final retBase = retDart.replaceFirst('?', '');

    // ── True ABI signature ──────────────────────────────────────────────────
    String trueRet;
    if (retBase == 'void') {
      trueRet = 'void';
    } else if (retBase == 'String') {
      trueRet = 'const char*';
    } else {
      trueRet = 'int64_t'; // int, double (bits), bool, enum (nativeValue), DateTime, uint64
    }

    final trueParams = <String>[];
    final implParams = <String>[];
    final argConversions = <String>[];
    final rawArgs = <String>[];
    var supported = true;

    for (var i = 0; i < callback.functionParams.length; i++) {
      final cp = callback.functionParams[i];
      final base = cp.name.replaceFirst('?', '');
      final isNullableCp = cp.name.endsWith('?');
      final implType = CppInterfaceGenerator.cppCallbackParamType(
        cp.name, enumNames, structNames, recordNames.union(variantNames),
        bridgeType: cp,
      );
      implParams.add('$implType _a$i');

      if (isNullableCp && (base == 'int' || base == 'double' || base == 'bool')) {
        // Nullable prims expand to (isNull, valueBits) — not yet mapped to the
        // single-param impl signature. Fall back to the raw pointer.
        supported = false;
        break;
      }
      if (structNames.contains(base)) {
        final st = spec.structs.firstWhere((s) => s.name == base);
        final numericOnly = st.fields.every((f) {
          final fb = f.type.name.replaceFirst('?', '');
          return fb == 'int' || fb == 'double' || fb == 'bool';
        });
        if (!numericOnly) {
          supported = false;
          break;
        }
        for (final f in st.fields) {
          final fb = f.type.name.replaceFirst('?', '');
          trueParams.add('int64_t');
          if (fb == 'double') {
            argConversions.add('int64_t _b${i}_${f.name}; { double _d = _a$i.${f.name}; memcpy(&_b${i}_${f.name}, &_d, 8); }');
            rawArgs.add('_b${i}_${f.name}');
          } else if (fb == 'bool') {
            rawArgs.add('(_a$i.${f.name} ? (int64_t)1 : (int64_t)0)');
          } else {
            rawArgs.add('(int64_t)_a$i.${f.name}');
          }
        }
      } else if (recordNames.contains(base) || variantNames.contains(base) || cp.isRecord) {
        trueParams.add('const uint8_t*');
        // Malloc'd [4B len][payload]; ownership passes to Dart (frees after decode).
        argConversions.add('uint8_t* _blob$i = (uint8_t*)malloc(4 + _a$i.size);');
        argConversions.add('int32_t _bl$i = (int32_t)_a$i.size;');
        argConversions.add('memcpy(_blob$i, &_bl$i, 4);');
        argConversions.add('if (_a$i.size > 0) { memcpy(_blob$i + 4, _a$i.data, _a$i.size); }');
        rawArgs.add('_blob$i');
      } else if (base == 'double') {
        trueParams.add('int64_t');
        argConversions.add('int64_t _b$i; { double _d = _a$i; memcpy(&_b$i, &_d, 8); }');
        rawArgs.add('_b$i');
      } else if (base == 'bool') {
        trueParams.add('int64_t');
        rawArgs.add('(_a$i ? (int64_t)1 : (int64_t)0)');
      } else if (enumNames.contains(base)) {
        trueParams.add('int64_t');
        rawArgs.add('static_cast<int64_t>(_a$i)');
      } else if (base == 'int' || base == 'DateTime' || base == 'uint64') {
        trueParams.add('int64_t');
        rawArgs.add('(int64_t)_a$i');
      } else {
        supported = false;
        break;
      }
    }

    if (!supported) {
      // Unmapped shape — pass the raw pointer through; std::function conversion
      // will surface a compile error at the exact site if the shapes disagree.
      return p.name;
    }

    final implRet = CppInterfaceGenerator.cppCallbackReturnType(retDart, enumNames);
    final trueSig = '$trueRet (*)(${trueParams.isEmpty ? 'void' : trueParams.join(', ')})';
    final rawName = '_rawfn_${p.name}';
    final fnName = '_fn_${p.name}';

    writer.line('        auto $rawName = reinterpret_cast<$trueSig>(${p.name});');
    writer.line('        std::function<$implRet(${implParams.map((s) => s.substring(0, s.lastIndexOf(' '))).join(', ')})> $fnName =');
    writer.line('            [$rawName](${implParams.join(', ')}) -> $implRet {');
    for (final c in argConversions) {
      writer.line('            $c');
    }
    final callExpr = '$rawName(${rawArgs.join(', ')})';
    if (retBase == 'void') {
      writer.line('            $callExpr;');
    } else if (retBase == 'String') {
      writer.line('            const char* _rp = $callExpr;');
      writer.line('            std::string _rs = _rp ? std::string(_rp) : std::string();');
      writer.line('            if (_rp) { free((void*)_rp); }');
      writer.line('            return _rs;');
    } else if (retBase == 'double') {
      writer.line('            int64_t _rb = $callExpr;');
      writer.line('            double _rd; memcpy(&_rd, &_rb, 8);');
      writer.line('            return _rd;');
    } else if (retBase == 'bool') {
      writer.line('            return $callExpr != 0;');
    } else if (enumNames.contains(retBase)) {
      writer.line('            return static_cast<$retBase>($callExpr);');
    } else {
      writer.line('            return $callExpr;');
    }
    writer.line('            };');
    return fnName;
  }

  /// Emits the `Hybrid<Class>::emit_*` stream definitions shared by the
  /// mixed-platform desktop dispatch AND the all-platforms-C++ direct path
  /// (cpp_direct_emitter.dart). Signatures come from CppInterfaceGenerator
  /// so the definitions always match the declarations in *.native.g.h.
  static void _emitCppStreamEmitters(
    CodeWriter writer,
    BridgeSpec spec,
    String className,
    Set<String> enumNames,
    Set<String> structNames,
    Set<String> variantNames,
  ) {
    // Shared batch-post helper (kArray of kInt64: [count, items...]) — same
    // wire shape the JNI path uses; Dart's asyncExpand unpacks batch[0]=count.
    final hasBatchStreams = spec.streams.any(
      (st) =>
          st.isBatch &&
          const {'int', 'double', 'bool'}.contains(st.itemType.name.replaceFirst('?', '')),
    );
    if (hasBatchStreams) {
      writer.line('static bool _nitro_desktop_post_batch(int64_t port, const int64_t* items, int32_t count) {');
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
      writer.line('    bool ok = Dart_PostCObject_DL(port, &arr);');
      writer.line('    free(objs); free(ptrs);');
      writer.line('    return ok;');
      writer.line('}');
      writer.blankLine();
    }

    for (final stream in spec.streams) {
      final base = stream.itemType.name.replaceFirst('?', '');
      final isNullable = stream.itemType.isNullable || stream.itemType.name.endsWith('?');
      final isStruct = structNames.contains(base);
      final isVariantStream = variantNames.contains(base);
      final isRecord = stream.itemType.isRecord || isVariantStream;
      final isEnum = enumNames.contains(base);
      // Signature must match the declaration in native.g.h exactly.
      final itemCpp = CppInterfaceGenerator.cppReturnTypeFor(
        stream.itemType,
        enumNames,
        structNames,
        {...spec.recordTypes.map((r) => r.name), ...variantNames},
      );
      // Dart's batch unpack ([count, items...]) only exists for numeric items;
      // batch-annotated String streams fall back to plain per-item posting.
      final isBatchNumeric = stream.isBatch && const {'int', 'double', 'bool'}.contains(base);

      writer.line('void Hybrid$className::emit_${stream.dartName}($itemCpp item) {');
      writer.line('    int64_t port = g_port_${stream.dartName};');
      writer.line('    if (port == 0) { return; }');

      // Nullable items: post kNull for std::nullopt, else unwrap and fall through.
      // (Nullable records/variants stay NitroCppBuffer — empty buffer means null.)
      if (isNullable && !isRecord) {
        writer.line('    if (!item.has_value()) {');
        writer.line('        Dart_CObject _null_obj;');
        writer.line('        _null_obj.type = Dart_CObject_kNull;');
        writer.line('        if (!Dart_PostCObject_DL(port, &_null_obj)) { g_port_${stream.dartName} = 0; }');
        writer.line('        return;');
        writer.line('    }');
      }
      final v = (isNullable && !isRecord) ? '(*item)' : 'item';

      if (isBatchNumeric) {
        // Single-item batch — semantically identical; native-side accumulation
        // is an optimization the desktop path does not need.
        final bits = base == 'double'
            ? 'int64_t _bits; { double _d = $v; memcpy(&_bits, &_d, 8); }'
            : base == 'bool'
                ? 'int64_t _bits = $v ? 1 : 0;'
                : 'int64_t _bits = $v;';
        writer.line('    $bits');
        writer.line('    if (!_nitro_desktop_post_batch(port, &_bits, 1)) { g_port_${stream.dartName} = 0; }');
        writer.line('}');
        writer.blankLine();
        continue;
      }

      if (isStruct) {
        writer.line('    $base* st_ptr = nullptr;');
      }
      writer.line('    Dart_CObject obj;');
      if (base == 'double') {
        writer.line('    obj.type = Dart_CObject_kDouble;');
        writer.line('    obj.value.as_double = $v;');
      } else if (base == 'int' || base == 'DateTime') {
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = $v;');
      } else if (base == 'uint64') {
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = (int64_t)$v;');
      } else if (base == 'bool') {
        // Use kInt64 (0/1) — kBool is unreliable on some Android versions.
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = $v ? 1 : 0;');
      } else if (base == 'String') {
        writer.line('    obj.type = Dart_CObject_kString;');
        writer.line('    obj.value.as_string = (char*)$v.c_str();');
      } else if (isEnum) {
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = static_cast<int64_t>($v);');
      } else if (isStruct) {
        writer.line('    st_ptr = ($base*)malloc(sizeof($base));');
        writer.line('    if (!st_ptr) { return; }');
        writer.line('    *st_ptr = $v;');
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = (intptr_t)st_ptr;');
      } else if (isRecord) {
        // Record/variant: item is a non-owning payload view (no length prefix).
        // Copy into a malloc'd [4B len][payload] block; Dart frees after decode.
        writer.line('    uint8_t* _blob = (uint8_t*)malloc(4 + item.size);');
        writer.line('    if (!_blob) { return; }');
        writer.line('    int32_t _len = (int32_t)item.size;');
        writer.line('    memcpy(_blob, &_len, 4);');
        writer.line('    if (item.size > 0) { memcpy(_blob + 4, item.data, item.size); }');
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = (intptr_t)_blob;');
      } else {
        writer.line('    obj.type = Dart_CObject_kNull;');
      }
      writer.line('    if (!Dart_PostCObject_DL(port, &obj)) {');
      writer.line('        g_port_${stream.dartName} = 0;');
      if (isStruct) {
        writer.line('        free(st_ptr);');
      } else if (isRecord) {
        writer.line('        free(_blob);');
      }
      writer.line('        return;');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }

  }

  static String _typeToC(String dartType, {bool isNativeHandle = false}) {
    if (isNativeHandle) return 'void*'; // NativeHandle<T> is always void*
    if (dartType == 'AnyNativeObject' || dartType == 'AnyNativeObject?') return 'int64_t';
    // Nullable primitives → raw byte pointers (matches Dart Pointer<NitroOptXxx> ABI).
    if (dartType == 'int?') return 'const uint8_t*';
    if (dartType == 'uint64?') return 'const uint8_t*';
    if (dartType == 'double?') return 'const uint8_t*';
    if (dartType == 'bool?') return 'const uint8_t*';
    if (dartType == 'DateTime?') return 'const uint8_t*';
    switch (dartType.replaceFirst('?', '')) {
      case 'int':
        return 'int64_t';
      case 'uint64':
        return 'uint64_t';
      case 'DateTime':
        return 'int64_t';
      case 'double':
        return 'double';
      case 'bool':
        return 'int8_t';
      case 'String':
        return 'const char*';
      case 'Uint8List':
        return 'uint8_t*';
      case 'Int8List':
        return 'int8_t*';
      case 'Int16List':
        return 'int16_t*';
      case 'Int32List':
        return 'int32_t*';
      case 'Uint16List':
        return 'uint16_t*';
      case 'Uint32List':
        return 'uint32_t*';
      case 'Float32List':
        return 'float*';
      case 'Float64List':
        return 'double*';
      case 'Int64List':
        return 'int64_t*';
      case 'Uint64List':
        return 'uint64_t*';
      case 'void':
        return 'void';
      default:
        // Map<String, T> now bridges as binary uint8_t* (same as @HybridRecord)
        if (dartType.startsWith('Map<')) return 'uint8_t*';
        return 'void*';
    }
  }

  static String _callbackParamToC(BridgeParam param, Set<String> enumNames, {Set<String>? structNames, Set<String>? recordNames, Set<String>? variantNames}) {
    final callback = param.type;
    final ret = _callbackTypeToC(callback.functionReturnType ?? 'void', enumNames, structNames: structNames, recordNames: recordNames);
    // Nullable int/double/bool expand to two int64_t params (isNull + value) to avoid sentinels.
    final paramParts = <String>[];
    for (final p in callback.functionParams) {
      final base = p.name.replaceFirst('?', '');
      final isNullable = p.name.endsWith('?');
      if (isNullable && (base == 'int' || base == 'double' || base == 'bool')) {
        paramParts.add('int64_t'); // isNull flag
        paramParts.add('int64_t'); // value bits
      } else {
        paramParts.add(_callbackTypeToC(p.name, enumNames, bridgeType: p, structNames: structNames, recordNames: recordNames));
      }
    }
    final paramStr = paramParts.isEmpty ? 'void' : paramParts.join(', ');
    return '$ret (*${param.name})($paramStr)';
  }

  static String _callbackTypeToC(String dartType, Set<String> enumNames, {BridgeType? bridgeType, Set<String>? structNames, Set<String>? recordNames}) {
    if (bridgeType?.isPointer == true) {
      return _pointerInnerToC(bridgeType!.pointerInnerType);
    }
    final base = dartType.replaceFirst('?', '');
    if (enumNames.contains(base)) return 'int64_t';
    // @HybridStruct callback params use void* — uniform across JNI and Swift paths.
    if (structNames?.contains(base) == true) return 'void*';
    if (recordNames?.contains(base) == true) return 'const uint8_t*'; // length-prefixed buffer
    // @NitroVariant callback params: void* at the public C API level; the JNI body
    // typedef-casts to (const uint8_t*) and Swift uses @convention(c) (UnsafeMutablePointer<UInt8>?).
    // Both are ABI-compatible with void* on all Nitro target platforms.
    return _typeToC(base);
  }

  static String _pointerInnerToC(String? innerType) {
    switch (innerType) {
      case 'Uint8':
        return 'uint8_t*';
      case 'Int8':
        return 'int8_t*';
      case 'Int16':
        return 'int16_t*';
      case 'Int32':
        return 'int32_t*';
      case 'Uint16':
        return 'uint16_t*';
      case 'Uint32':
        return 'uint32_t*';
      case 'Float':
        return 'float*';
      case 'Double':
        return 'double*';
      case 'Int64':
        return 'int64_t*';
      case 'Uint64':
        return 'uint64_t*';
      case 'Utf8':
      case 'Char':
        return 'char*';
      default:
        return 'void*';
    }
  }

  /// Like _typeToC but for function parameters (struct params pass as void*)
  static String _paramTypeToC(String dartType, Set<String> structNames) {
    if (structNames.contains(dartType.replaceFirst('?', ''))) {
      return 'void*';
    }
    return _typeToC(dartType);
  }

  static bool _isNullableStructType(
    BridgeType type,
    Set<String> structNames,
  ) {
    return (type.isNullable || type.name.endsWith('?')) && structNames.contains(type.name.replaceFirst('?', ''));
  }

  static void _emitNullableStructParamGuards(
    CodeWriter writer,
    List<BridgeParam> params,
    Set<String> structNames,
    String functionName,
    String returnStatement,
  ) {
    for (final p in params) {
      if (!_isNullableStructType(p.type, structNames)) continue;
      _emitNullableStructPointerGuard(
        writer,
        paramName: p.name,
        ownerName: functionName,
        returnStatement: returnStatement,
        indent: '    ',
      );
    }
  }

  static void _emitNullableStructPointerGuard(
    CodeWriter writer, {
    required String paramName,
    required String ownerName,
    required String returnStatement,
    required String indent,
  }) {
    final blockIndent = indent;
    final bodyIndent = '$indent    ';
    writer.line('${blockIndent}if ($paramName == nullptr) {');
    writer.line('${bodyIndent}nitro_report_error("NullPointerException", "Parameter $paramName for $ownerName cannot be null.", nullptr, nullptr);');
    writer.line('$bodyIndent$returnStatement');
    writer.line('$blockIndent}');
  }

  static bool _isZeroCopy(BridgeStruct st, String fieldName) {
    return st.fields.any((f) => f.name == fieldName && f.zeroCopy);
  }

  /// Returns the field name used as the element count for a zero-copy field.
  ///
  /// Checks field-specific names first (e.g. pcmLength, pcmSize), then
  /// generic length names (stride, size, length, etc.). If nothing is found,
  /// returns the synthesized name '${zeroCopyField}Length' — this matches the
  /// companion field that [generateCStructs] / [generateDartExtensions] auto-inject
  /// when no explicit companion is declared.
  static String _zeroCopyLenField(BridgeStruct st, String zeroCopyField) {
    final fieldSpecific = ['${zeroCopyField}Length', '${zeroCopyField}Size'];
    for (final c in fieldSpecific) {
      if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return c;
    }
    const generic = ['stride', 'size', 'length', 'len', 'byteLength', 'byteLen'];
    for (final c in generic) {
      if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return c;
    }
    return '${zeroCopyField}Length'; // synthesized — must be auto-injected in struct
  }

  /// Returns true when [zeroCopyField] has no explicit companion length field
  /// in [st]. In that case, the generators inject a synthetic '${field}Length'
  /// field into the C struct and populate it from GetDirectBufferCapacity.
  static bool _zeroCopyNeedsSynthetic(BridgeStruct st, String zeroCopyField) {
    final fieldSpecific = ['${zeroCopyField}Length', '${zeroCopyField}Size'];
    for (final c in fieldSpecific) {
      if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return false;
    }
    const generic = ['stride', 'size', 'length', 'len', 'byteLength', 'byteLen'];
    for (final c in generic) {
      if (st.fields.any((f) => f.name == c && f.type.name == 'int')) return false;
    }
    return true;
  }

  /// Element-count divisor when storing capacity from GetDirectBufferCapacity
  /// (byte count) into a synthetic length field (element count).
  static String _elementSizeDivisorExpr(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'Uint8List':
      case 'Int8List':
        return ''; // 1 byte each — no division
      case 'Int16List':
      case 'Uint16List':
        return ' / (jlong)sizeof(int16_t)';
      case 'Int32List':
      case 'Uint32List':
        return ' / (jlong)sizeof(int32_t)';
      case 'Float32List':
        return ' / (jlong)sizeof(float)';
      case 'Float64List':
        return ' / (jlong)sizeof(double)';
      case 'Int64List':
      case 'Uint64List':
        return ' / (jlong)sizeof(int64_t)';
      default:
        return '';
    }
  }

  static String _jniGetter(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int':
        return 'GetLongField';
      case 'double':
        return 'GetDoubleField';
      case 'bool':
        return 'GetBooleanField';
      default:
        return 'GetObjectField';
    }
  }

  static String _defaultValue(String cType) {
    switch (cType) {
      case 'int64_t':
        return '0';
      case 'uint64_t':
        return '0';
      case 'double':
        return '0.0';
      case 'int8_t':
        return 'false'; // used by both bool (explicitly) and int8 (0 == false in C)
      case 'int16_t':
      case 'int32_t':
      case 'uint8_t':
      case 'uint16_t':
      case 'uint32_t':
        return '0';
      case 'intptr_t':
      case 'size_t':
        return '0';
      case 'float':
        return '0.0f';
      case 'const char*':
        return 'nullptr';
      // NitroOpt* value types: zero-initialized struct (hasValue=0 means null).
      case 'NitroOptInt64':
        return 'NitroOptInt64{}';
      case 'NitroOptFloat64':
        return 'NitroOptFloat64{}';
      case 'NitroOptBool':
        return 'NitroOptBool{}';
      default:
        return 'nullptr';
    }
  }

  static String _jniSigType(String t) {
    final base = t.replaceFirst('?', '');
    if (base.startsWith('NativeHandle<')) return 'J';
    switch (base) {
      case 'int':
      case 'uint64':
      case 'DateTime':
        return 'J';
      case 'double':
        return 'D';
      case 'bool':
        return 'Z';
      case 'String':
        return 'Ljava/lang/String;';
      case 'void':
        return 'V';
      // Non-@ZeroCopy TypedData → Kotlin array types
      // (@ZeroCopy variants are intercepted in _jniSig before this is called)
      case 'Uint8List':
      case 'Int8List':
        return '[B'; // ByteArray
      case 'Int16List':
      case 'Uint16List':
        return '[S'; // ShortArray
      case 'Int32List':
      case 'Uint32List':
        return '[I'; // IntArray
      case 'Float32List':
        return '[F'; // FloatArray
      case 'Float64List':
        return '[D'; // DoubleArray
      case 'Int64List':
      case 'Uint64List':
        return '[J'; // LongArray
      case 'int8':
      case 'uint8': return 'B';   // jbyte
      case 'int16':
      case 'uint16': return 'S';  // jshort
      case 'int32':
      case 'uint32': return 'I';  // jint
      case 'float': return 'F';   // jfloat
      case 'intptr':
      case 'size': return 'J';    // jlong (64-bit for both)
      default:
        throw StateError(
          'Unknown JNI signature type "$t". Add @HybridStruct/@HybridEnum metadata or a typed-data mapping before generating the C bridge.',
        );
    }
  }

  static String _jniSigTypeC(String t) {
    final base = t.replaceFirst('?', '');
    if (base.startsWith('NativeHandle<')) return 'jlong';
    switch (base) {
      case 'int':
      case 'uint64':
        return 'jlong';
      case 'double':
        return 'jdouble';
      case 'bool':
        return 'jboolean';
      case 'String':
        return 'jstring';
      case 'void':
        return 'void';
      case 'Uint8List':
        return 'jobject';
      case 'int8':
      case 'uint8': return 'jbyte';
      case 'int16':
      case 'uint16': return 'jshort';
      case 'int32':
      case 'uint32': return 'jint';
      case 'float': return 'jfloat';
      case 'intptr':
      case 'size': return 'jlong';
      default:
        return 'jobject';
    }
  }

  static String _jniCast(String t) {
    switch (t.replaceFirst('?', '')) {
      case 'int':
      case 'uint64':
        return 'jlong';
      case 'double':
        return 'jdouble';
      case 'bool':
        return 'jboolean';
      case 'int8':
      case 'uint8': return 'jbyte';
      case 'int16':
      case 'uint16': return 'jshort';
      case 'int32':
      case 'uint32': return 'jint';
      case 'float': return 'jfloat';
      case 'intptr':
      case 'size': return 'jlong';
      default:
        return 'jobject';
    }
  }

  /// Returns the C cast type for a zero-copy TypedData struct field.
  ///
  /// `GetDirectBufferAddress` returns `void*`. The struct field type is the
  /// element pointer (e.g. `float*` for Float32List).  An explicit cast avoids
  /// the implicit `void* → typed pointer` conversion warning in C++.
  static String _zeroCopyCElementCast(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'Uint8List':
        return 'uint8_t*';
      case 'Int8List':
        return 'int8_t*';
      case 'Int16List':
        return 'int16_t*';
      case 'Uint16List':
        return 'uint16_t*';
      case 'Int32List':
        return 'int32_t*';
      case 'Uint32List':
        return 'uint32_t*';
      case 'Float32List':
        return 'float*';
      case 'Float64List':
        return 'double*';
      case 'Int64List':
        return 'int64_t*';
      case 'Uint64List':
        return 'uint64_t*';
      default:
        return 'uint8_t*';
    }
  }

  /// Returns a C expression suffix to multiply the element count by element
  /// byte-size when calling `NewDirectByteBuffer` (which expects byte count).
  ///
  /// Returns `''` for byte-sized elements (no-op multiply) or
  /// ` * N` for multi-byte elements (e.g. ` * sizeof(float)`).
  static String _zeroCopyElementSizeExpr(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'Uint8List':
      case 'Int8List':
        return ''; // 1 byte — no multiplication needed
      case 'Int16List':
      case 'Uint16List':
        return ' * sizeof(int16_t)';
      case 'Int32List':
      case 'Uint32List':
        return ' * sizeof(int32_t)';
      case 'Float32List':
        return ' * sizeof(float)';
      case 'Float64List':
        return ' * sizeof(double)';
      case 'Int64List':
      case 'Uint64List':
        return ' * sizeof(int64_t)';
      default:
        return '';
    }
  }

  /// Escapes a single JNI identifier component: replaces '_' with '_1'.
  /// JNI spec §2.4: each '.' separator becomes '_', and each '_' within
  /// an identifier becomes '_1'. This function handles the latter.
  static String _jniMangle(String s) => s.replaceAll('_', '_1');

  /// Builds a fully-qualified JNI C function name from logical components.
  ///
  /// Kotlin package: "nitro.{lib}_module"
  /// Examples:
  ///   lib='my_camera', class='MyCamera', method='emit_frames'
  ///     → 'Java_nitro_my_1camera_1module_MyCameraJniBridge_emit_1frames'
  ///   lib='sensor_hub', class='SensorHub', method='emit_sensor_data'
  ///     → 'Java_nitro_sensor_1hub_1module_SensorHubJniBridge_emit_1sensor_1data'
  static String _jniMethodName(
    String lib,
    String className,
    String methodName,
  ) {
    return [
      'Java',
      _jniMangle('nitro'), // 'nitro' (no underscores)
      _jniMangle(
        '${lib.replaceAll('-', '_')}_module',
      ), // e.g. 'my_1camera_1module'
      _jniMangle('${className}JniBridge'), // usually CamelCase — no underscores
      _jniMangle(methodName), // e.g. 'emit_1frames'
    ].join('_');
  }

  /// Returns [jniArrayType, newFn, setRegionFn, elemCast, getRegionFn] for a non-zero-copy TypedData param/return.
  static List<String> _typedDataJniOps(String dartType) {
    switch (dartType) {
      case 'Uint8List':
      case 'Int8List':
        return ['jbyteArray', 'NewByteArray', 'SetByteArrayRegion', 'jbyte', 'GetByteArrayRegion'];
      case 'Int16List':
      case 'Uint16List':
        return ['jshortArray', 'NewShortArray', 'SetShortArrayRegion', 'jshort', 'GetShortArrayRegion'];
      case 'Int32List':
      case 'Uint32List':
        return ['jintArray', 'NewIntArray', 'SetIntArrayRegion', 'jint', 'GetIntArrayRegion'];
      case 'Float32List':
        return ['jfloatArray', 'NewFloatArray', 'SetFloatArrayRegion', 'jfloat', 'GetFloatArrayRegion'];
      case 'Float64List':
        return ['jdoubleArray', 'NewDoubleArray', 'SetDoubleArrayRegion', 'jdouble', 'GetDoubleArrayRegion'];
      case 'Int64List':
      case 'Uint64List':
        return ['jlongArray', 'NewLongArray', 'SetLongArrayRegion', 'jlong', 'GetLongArrayRegion'];
      default:
        return ['jbyteArray', 'NewByteArray', 'SetByteArrayRegion', 'jbyte', 'GetByteArrayRegion'];
    }
  }

  static void _emitZeroCopyTypedDataParam(
    CodeWriter writer,
    BridgeParam param, {
    required String? returnExpr,
  }) {
    final name = param.name;
    final elemSize = _typedDataElementSizeExpr(param.type.name);
    final returnStmt = returnExpr == null ? 'return;' : 'return $returnExpr;';
    final allowsNull = param.type.name.endsWith('?');
    final nullPointerCondition = allowsNull ? '$name == nullptr && ${name}_length > 0' : '$name == nullptr';
    final nullBufferCondition = allowsNull ? 'j_$name == nullptr && ${name}_byte_length > 0' : 'j_$name == nullptr';

    writer.line('    if (${name}_length < 0) {');
    writer.line('        nitro_report_error("ArgumentError", "$name: TypedData length cannot be negative", nullptr, nullptr);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        $returnStmt');
    writer.line('    }');
    writer.line('    if ($nullPointerCondition) {');
    writer.line('        nitro_report_error("ArgumentError", "$name: TypedData pointer is null for non-empty buffer", nullptr, nullptr);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        $returnStmt');
    writer.line('    }');
    writer.line('    if (${name}_length > INT64_MAX / (int64_t)$elemSize) {');
    writer.line('        nitro_report_error("ArgumentError", "$name: TypedData byte length overflow", nullptr, nullptr);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        $returnStmt');
    writer.line('    }');
    writer.line('    int64_t ${name}_byte_length = ${name}_length * (int64_t)$elemSize;');
    writer.line('    jobject j_$name = env->NewDirectByteBuffer($name, ${name}_byte_length);');
    writer.line('    if ($nullBufferCondition) {');
    writer.line('        nitro_report_error("ArgumentError", "$name: failed to create direct ByteBuffer", nullptr, nullptr);');
    writer.line('        env->PopLocalFrame(nullptr);');
    writer.line('        $returnStmt');
    writer.line('    }');
  }

  static String _typedDataElementSizeExpr(String dartType) {
    switch (dartType.replaceFirst('?', '')) {
      case 'Uint8List':
      case 'Int8List':
        return 'sizeof(uint8_t)';
      case 'Int16List':
      case 'Uint16List':
        return 'sizeof(int16_t)';
      case 'Int32List':
      case 'Uint32List':
        return 'sizeof(int32_t)';
      case 'Float32List':
        return 'sizeof(float)';
      case 'Float64List':
        return 'sizeof(double)';
      case 'Int64List':
      case 'Uint64List':
        return 'sizeof(int64_t)';
      default:
        return 'sizeof(uint8_t)';
    }
  }

  static String _jniSig(
    List<BridgeParam> params,
    BridgeType returnType,
    Set<String> enumNames,
    Set<String> structNames,
    String libPkg, {
    bool zeroCopyReturn = false,
    bool isResult = false,
    Set<String> variantNames = const {},
    Set<String> customTypeNames = const {},
  }) {
    // 'J' prefix for instanceId (Point 13 per-instance dispatch).
    final paramSig = 'J${params.map((p) => _jniParamSig(p, enumNames, structNames, libPkg, variantNames: variantNames, customTypeNames: customTypeNames)).join()}';
    // @NitroResult: Kotlin returns ByteArray [1B tag][payload] → '[B'
    if (isResult) return '($paramSig)[B';
    // Enum return type: bridge returns Long.
    // Nullable bool?: bridge returns Int (I) with -1=null/0=false/1=true.
    final baseRetType = returnType.name.replaceFirst('?', '');
    // @NitroVariant: Kotlin returns ByteArray [4B len][1B tag][fields] → '[B'
    final isVariantRet = variantNames.contains(baseRetType);
    final returnSig = switch (baseRetType) {
      _ when isVariantRet => '[B', // @NitroVariant ByteArray
      _ when returnType.isNullableNitroPrim => '[B', // nullable prim ByteArray
      _ when returnType.isAnyNativeObject => 'J', // AnyNativeObject → Long
      final base when customTypeNames.contains(base) => '[B', // @NitroCustomType → ByteArray
      final base when enumNames.contains(base) => 'J',
      final base when structNames.contains(base) => 'L$libPkg/$base;',
      _ when zeroCopyReturn && returnType.isTypedData => 'Ljava/nio/ByteBuffer;',
      _ when returnType.isRecord && !returnType.isMap => '[B', // binary record
      _ when returnType.isAnyMap => '[B', // NitroAnyMap: type-tagged binary
      _ when returnType.isMap => '[B', // binary map (replaces JSON)
      _ when returnType.isFunction => 'J',
      _ => _jniSigType(returnType.name),
    };
    return '($paramSig)$returnSig';
  }

  static String _jniNativeAsyncSig(
    List<BridgeParam> params,
    Set<String> enumNames,
    Set<String> structNames,
    String libPkg,
  ) {
    final paramSig = params
        .map(
          (p) => _jniParamSig(
            p,
            enumNames,
            structNames,
            libPkg,
          ),
        )
        .join();
    // 'J' prefix for instanceId, then params, then 'J' for dartPort (Point 13).
    return '(J${paramSig}J)V';
  }

  static String _jniParamSig(
    BridgeParam param,
    Set<String> enumNames,
    Set<String> structNames,
    String libPkg, {
    Set<String> variantNames = const {},
    Set<String> customTypeNames = const {},
  }) {
    final baseParamType = param.type.name.replaceFirst('?', '');
    if (structNames.contains(baseParamType)) {
      // Struct params are passed as the Kotlin data class object.
      return 'L$libPkg/$baseParamType;';
    }
    if (param.zeroCopy && param.type.isTypedData) {
      // Zero-copy TypedData params bridge as java.nio.ByteBuffer.
      return 'Ljava/nio/ByteBuffer;';
    }
    if (enumNames.contains(baseParamType)) return 'J';
    if (param.type.isAnyNativeObject) return 'J'; // AnyNativeObject → Long
    if (customTypeNames.contains(baseParamType)) return '[B'; // @NitroCustomType → ByteArray
    if (param.type.isRecord && !param.type.isMap) return '[B'; // binary record
    if (param.type.isAnyMap) return '[B'; // NitroAnyMap: type-tagged binary
    if (param.type.isMap) return '[B'; // binary map (replaces JSON)
    // @NitroVariant params: encoded as ByteArray [4B len][1B tag][fields]
    if (variantNames.contains(baseParamType)) return '[B';
    // Callback / function-typed params are passed as a long (function pointer).
    if (param.type.isFunction) return 'J';
    // Nullable primitives use NitroNullable ByteArray encoding ([B).
    if (param.type.isNullableNitroPrim) return '[B';
    return _jniSigType(param.type.name);
  }
}
