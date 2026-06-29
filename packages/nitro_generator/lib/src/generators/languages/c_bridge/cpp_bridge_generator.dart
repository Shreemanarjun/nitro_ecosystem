import 'package:nitro_annotations/nitro_annotations.dart' show CppImpl;

import '../../../bridge_item_kind.dart';
import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';

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

  static String _cppScalarType(String dartType, Set<String> enumNames, Set<String> structNames) {
    final base = dartType.replaceFirst('?', '');
    if (base == 'String') return 'std::string';
    if (enumNames.contains(base)) return base;
    if (structNames.contains(base)) return base;
    return _typeToC(base);
  }

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
      writer.line('extern "C" {');
      for (final st in spec.structs) {
        writer.line('void ${libStem}_release_${st.name}(void* ptr) {');
        writer.line('    if (!ptr) { return; }');

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

    for (final stream in spec.streams) {
      final isStruct = structNames.contains(stream.itemType.name.replaceFirst('?', ''));
      final isRecord = stream.itemType.isRecord;
      final isEnum = enumNames.contains(stream.itemType.name.replaceFirst('?', ''));
      final isVariantStream = variantNames.contains(stream.itemType.name.replaceFirst('?', ''));
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
      } else if (isRecord || isVariantStream) {
        // Record/variant: item is a pointer to serialized bytes; post address as kInt64.
        // Dart frees after decode via malloc.free.
        writer.line('    obj.type = Dart_CObject_kInt64;');
        writer.line('    obj.value.as_int64 = (intptr_t)item;');
      } else {
        writer.line('    obj.type = Dart_CObject_kNull;');
      }
      writer.line('    if (!Dart_PostCObject_DL(port, &obj)) {');
      writer.line('        g_port_${stream.dartName} = 0;');
      if (isStruct) {
        writer.line('        free(st_ptr);');
      } else if (isRecord || isVariantStream) {
        writer.line('        free(item);');
      }
      writer.line('        return;');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }

    final notInit =
        'nitro_report_error("NotInitialized", '
        '"No C++ implementation registered. Call ${libStem}_register_impl() first.", '
        'nullptr, nullptr)';

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
          paramParts.add('${(isStructParam || isRecordParam) ? 'void*' : (isEnumParam ? 'int64_t' : _typeToC(p.type.name))} ${p.name}');
          if (p.type.isTypedData) paramParts.add('int64_t ${p.name}_length');
        }
        paramParts.add('int64_t dart_port');
        final paramsDecl = paramParts.join(', ');
        final callArgs = <String>[];
        for (final p in func.params) {
          final base = p.type.name.replaceFirst('?', '');
          if (p.type.isAnyNativeObject) {
            if (p.type.isNullable) {
              callArgs.add('${p.name} == -1 ? std::optional<int64_t>(std::nullopt) : std::make_optional<int64_t>(${p.name})');
            } else {
              callArgs.add(p.name);
            }
          } else if (spec.isCustomTypeName(base)) {
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
        writer.line('    g_impl->${func.dartName}(${callArgs.join(', ')});');
        writer.line('}');
        writer.blankLine();
        continue;
      }

      final isEnumRet = enumNames.contains(func.returnType.name.replaceFirst('?', ''));
      final isStructRet = structNames.contains(func.returnType.name.replaceFirst('?', ''));
      final isRecordRet = func.returnType.isRecord;
      final isZeroCopyTypedDataRet = func.zeroCopyReturn && func.returnType.isTypedData;
      final retBase = func.returnType.name.replaceFirst('?', '');
      final isCustomTypeRet = spec.isCustomTypeName(retBase);
      // Nullable prim returns: malloc'd uint8_t* pointer (Dart casts to Pointer<NitroOptXxx> and frees).
      final cRet = func.returnType.isAnyNativeObject
          ? 'int64_t'
          : isCustomTypeRet
          ? 'uint8_t*'
          : isEnumRet
          ? 'int64_t'
          : func.returnType.name == 'int?' ? 'uint8_t*'
          : func.returnType.name == 'double?' ? 'uint8_t*'
          : func.returnType.name == 'bool?' ? 'uint8_t*'
          : func.returnType.name == 'DateTime?' ? 'uint8_t*'
          : func.returnType.isTypedData
          ? 'uint8_t*'
          : _typeToC(func.returnType.name);
      final dflt = _defaultValue(cRet);
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
          final cType = isEnumParam
              ? 'int64_t'
              : ((isStructParam || isRecordParam) ? 'void*' : _typeToC(p.type.name));
          paramParts.add('$cType ${p.name}');
        }
        if (p.type.isTypedData) paramParts.add('int64_t ${p.name}_length');
      }
      // S8: sync functions also receive NitroError* out-param for consistency with the JNI path.
      if (!func.isAsync) {
        paramParts.add('NitroError* _nitro_err');
      }
      final paramsDecl = paramParts.join(', ');

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
      final callArgs = <String>[];
      for (final p in func.params) {
        final base = p.type.name.replaceFirst('?', '');
        if (p.type.name == 'int?') {
          writer.line('        std::optional<int64_t> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(*reinterpret_cast<const int64_t*>(${p.name} + 1));');
          callArgs.add('_opt_${p.name}');
        } else if (p.type.name == 'double?') {
          writer.line('        std::optional<double> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(*reinterpret_cast<const double*>(${p.name} + 1));');
          callArgs.add('_opt_${p.name}');
        } else if (p.type.name == 'bool?') {
          writer.line('        std::optional<bool> _opt_${p.name} = (${p.name} == nullptr || ${p.name}[0] == 0) ? std::nullopt : std::make_optional(${p.name}[1] != 0);');
          callArgs.add('_opt_${p.name}');
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
      } else if (func.returnType.name == 'int?') {
        writer.line('        std::optional<int64_t> _opt = g_impl->${func.dartName}($callArgStr);');
        writer.line('        uint8_t* _res = (uint8_t*)malloc(9);');
        writer.line('        _res[0] = _opt.has_value() ? 1 : 0;');
        writer.line('        if (_opt.has_value()) { *reinterpret_cast<int64_t*>(_res + 1) = _opt.value(); }');
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
        writer.line('        NitroCppBuffer _res = g_impl->${func.dartName}($callArgStr);');
        writer.line('        return (void*)_res.data;');
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
      writer.line('    } catch (const std::exception& e) {');
      writer.line('        nitro_report_error("CppException", e.what(), nullptr, nullptr);');
      if (func.returnType.name != 'void') writer.line('        return $dflt;');
      writer.line('    } catch (...) {');
      writer.line('        nitro_report_error("CppException", "Unknown C++ exception", nullptr, nullptr);');
      if (func.returnType.name != 'void') writer.line('        return $dflt;');
      writer.line('    }');
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
        writer.line('    if (!g_impl) { $notInit; return ${_defaultValue(cType)}; }');
        writer.line('    try {');
        if (prop.type.name == 'String') {
          writer.line('        std::string _res = g_impl->get_${prop.dartName}();');
          writer.line('        return strdup(_res.c_str());');
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
          writer.line('        NitroCppBuffer _res = g_impl->get_${prop.dartName}();');
          writer.line('        return _res.data;');
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
        final isNullablePrimSetter = prop.type.name == 'int?' || prop.type.name == 'double?' || prop.type.name == 'bool?' || prop.type.name == 'DateTime?';
        final paramCType = isNullablePrimSetter
            ? 'const uint8_t*'
            : isVariantProp
            ? 'const uint8_t*'
            : (isEnum || isStructParam || isRecordParam) ? (isEnum ? 'int64_t' : 'void*') : _typeToC(prop.type.name);
        // instanceId is included for API consistency with the JNI path; g_impl ignores it.
        writer.line('void ${prop.setSymbol}(int64_t instanceId, $paramCType value, NitroError* _nitro_err) {');
        writer.line('    ${libStem}_clear_error();');
        writer.line('    if (!g_impl) { $notInit; return; }');
        writer.line('    try {');
        if (prop.type.name == 'String') {
          writer.line('        g_impl->set_${prop.dartName}(std::string(value));');
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
        } else if (prop.type.name == 'int?') {
          writer.line('        g_impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(*reinterpret_cast<const int64_t*>(value + 1)));');
        } else if (prop.type.name == 'double?') {
          writer.line('        g_impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(*reinterpret_cast<const double*>(value + 1)));');
        } else if (prop.type.name == 'bool?') {
          writer.line('        g_impl->set_${prop.dartName}(value == nullptr || value[0] == 0 ? std::nullopt : std::make_optional(value[1] != 0));');
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
    // Nullable bool uses int32_t (jint) to preserve the -1 sentinel for null.
    if (dartType.endsWith('?') && dartType.replaceFirst('?', '') == 'bool') {
      return 'int32_t';
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
      case 'double':
        return '0.0';
      case 'int8_t':
        return 'false';
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
    final isNullableBoolRet = baseRetType == 'bool' && returnType.name.endsWith('?');
    // Nullable primitives now return ByteArray (NitroNullable binary encoding).
    final isNullableIntRet = (baseRetType == 'int' || baseRetType == 'DateTime') && returnType.name.endsWith('?');
    final isNullableDoubleRet = baseRetType == 'double' && returnType.name.endsWith('?');
    // @NitroVariant: Kotlin returns ByteArray [4B len][1B tag][fields] → '[B'
    final isVariantRet = variantNames.contains(baseRetType);
    final returnSig = switch (baseRetType) {
      _ when isVariantRet => '[B', // @NitroVariant ByteArray
      _ when isNullableIntRet => '[B', // NitroNullableInt ByteArray
      _ when isNullableDoubleRet => '[B', // NitroNullableDouble ByteArray
      _ when isNullableBoolRet => '[B', // NitroNullableBool ByteArray
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
    if (param.type.isNullable && baseParamType == 'int') return '[B';
    if (param.type.isNullable && baseParamType == 'double') return '[B';
    if (param.type.isNullable && baseParamType == 'bool') return '[B';
    if (param.type.isNullable && baseParamType == 'DateTime') return '[B';
    // Also handle '?' suffix in type name
    if (param.type.name.endsWith('?') && (baseParamType == 'int' || baseParamType == 'double' || baseParamType == 'bool' || baseParamType == 'DateTime')) return '[B';
    return _jniSigType(param.type.name);
  }
}
