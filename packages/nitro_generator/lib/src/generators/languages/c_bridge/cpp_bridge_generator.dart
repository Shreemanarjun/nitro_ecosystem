import 'package:nitro_annotations/nitro_annotations.dart' show CppImpl, KotlinImpl, SwiftImpl;

import '../../../bridge_item_kind.dart';
import '../../../apple_system_names.dart';
import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';
import '../cpp_native/cpp_interface_generator.dart';
import 'cpp_header_generator.dart';
import '../../struct_generator.dart';

part 'cpp_bridge/swift_shim_emitter.dart';
part 'cpp_bridge/cpp_direct_emitter.dart';
part 'cpp_bridge/cpp_background_emitter.dart';
part 'cpp_bridge/type_emitter.dart';
part 'cpp_bridge/jni_swift_prologue.dart';
part 'cpp_bridge/jni_method_emitter.dart';
part 'cpp_bridge/jni_function_emitter.dart';
part 'cpp_bridge/jni_property_emitter.dart';
part 'cpp_bridge/jni_stream_emitter.dart';
part 'cpp_bridge/jni_callback_invokers.dart';
part 'cpp_bridge/jni_initialize_emitter.dart';
part 'cpp_bridge/c_types.dart';
part 'cpp_bridge/struct_helpers.dart';
part 'cpp_bridge/worker_dispatch.dart';
part 'cpp_bridge/cpp_dispatch_emitter.dart';
part 'cpp_bridge/cpp_callback_adapter.dart';
part 'cpp_bridge/cpp_instance_registry.dart';
part 'cpp_bridge/cpp_result_emitter.dart';

/// Generates `<lib>.bridge.g.cpp`: the C exports Dart binds, and behind them
/// the JNI glue (Kotlin), the Swift shim (Swift) or the C++ dispatch.
///
/// This file only decides which path a spec takes. The emitters live in
/// `cpp_bridge/`, one concern per file:
///
/// | file                         | emits                                              |
/// |------------------------------|----------------------------------------------------|
/// | `c_types.dart`               | Dart type → C / JNI type and signature tables      |
/// | `jni_swift_prologue.dart`    | includes, error slot, JNI class cache              |
/// | `jni_method_emitter.dart`    | JNI glue for methods, properties, streams          |
/// | `swift_shim_emitter.dart`    | the `@_cdecl` shim calls for Swift                 |
/// | `cpp_dispatch_emitter.dart`  | C++ dispatch of a mixed module (Apple / desktop)   |
/// | `cpp_direct_emitter.dart`    | the whole bridge of an all-C++ module              |
/// | `cpp_callback_adapter.dart`  | raw Dart callback pointer → `std::function`        |
/// | `cpp_result_emitter.dart`    | `@NitroResult` blobs and typed-data copies         |
/// | `cpp_instance_registry.dart` | C++ instance registry, stream ports and emitters   |
/// | `struct_helpers.dart`        | `@HybridStruct` copies, guards, `@zeroCopy` fields |
/// | `type_emitter.dart`          | struct pack / unpack between C and JNI             |
/// | `worker_dispatch.dart`       | async completion: batch, `_dispatch`, `_fnf`       |
/// | `cpp_background_emitter.dart`| `@NitroEntryPoint` background exports              |
class CppBridgeGenerator {
  static String generate(BridgeSpec spec) {
    _jniTypeLibs = spec.importedTypeLibs;
    final core = spec.renderGetterCalls(_generateCore(spec));
    final String full;
    if (spec.entryPoints.isEmpty) {
      full = core;
    } else {
      // Appended after every prologue so GetEnv/g_bridgeClass are in scope, and
      // regardless of which bridge path the spec took above.
      final w = CodeWriter();
      emitBackgroundExports(w, spec, spec.lib.replaceAll('-', '_'));
      full = core + w.toString();
    }
    return full + _appleKeepExports(spec, full);
  }

  static String _appleKeepExports(BridgeSpec spec, String cpp) {
    if (!(spec.targetsIos || spec.targetsMacos)) return '';
    final libStem = spec.lib.replaceAll('-', '_');
    final nameRe = RegExp('\\b${RegExp.escape(libStem)}_\\w+(?=\\s*\\()');
    final syms = <String>{};
    // The header is read as well: it declares every export `NITRO_EXPORT`, and a method's definition here does not repeat it.
    for (final line in '$cpp\n${CppHeaderGenerator.generate(spec)}'.split('\n')) {
      if (!line.contains('NITRO_EXPORT')) continue;
      final m = nameRe.firstMatch(line);
      if (m != null) syms.add(m.group(0)!);
    }
    if (syms.isEmpty) return '';
    final b = StringBuffer()
      ..writeln()
      ..writeln('#if defined(__APPLE__)')
      ..writeln('__asm__(');
    for (final s in syms) {
      b.writeln('    ".desc _$s, 0x10\\n"');
    }
    b
      ..writeln(');')
      ..writeln('#endif');
    return b.toString();
  }

  static String _generateCore(BridgeSpec spec) {
    // All targeted platforms use C++ — emit the lean direct-call bridge.
    if (spec.isCppImpl) return _generateCppDirect(spec);
    // Web-only spec (web: NativeImpl.wasm with no native platforms): the
    // bridge is the direct C++ dispatch compiled by emcc alone.
    if (spec.webIsWasm && !spec.targetsAnyNative) return _generateCppDirect(spec);

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

  /// `Dart_TypedData_k*` element type for a typed-data Dart type name.
  static String typedDataKind(String base) => switch (base) {
    'Int8List' => 'Dart_TypedData_kInt8',
    'Int16List' => 'Dart_TypedData_kInt16',
    'Uint16List' => 'Dart_TypedData_kUint16',
    'Int32List' => 'Dart_TypedData_kInt32',
    'Uint32List' => 'Dart_TypedData_kUint32',
    'Int64List' => 'Dart_TypedData_kInt64',
    'Uint64List' => 'Dart_TypedData_kUint64',
    'Float32List' => 'Dart_TypedData_kFloat32',
    'Float64List' => 'Dart_TypedData_kFloat64',
    _ => 'Dart_TypedData_kUint8',
  };

  /// `<sym>_dispatch`: the `@nitroAsync` twin that copies its arguments, runs
  /// the unchanged sync export on the worker pool and posts the result (the
  /// thread-local error becomes the per-call slot; a kNull post tells Dart to
  /// read it). Emitted by both C++ dispatch paths after the sync functions.
  static void emitCppWorkerDispatch(CodeWriter w, BridgeSpec spec, String libStem) {
    final funcs = spec.functions.where(spec.dispatchesAsync).toList();
    final fnf = spec.functions.where(spec.fireAndForget).toList();
    if (funcs.isEmpty && fnf.isEmpty) return;
    if (spec.targetsWeb) w.line('#ifndef __EMSCRIPTEN__');
    for (final st in spec.structs) {
      w.line('void ${libStem}_release_${st.name}(void* ptr);');
    }
    for (final func in funcs) {
      _emitDispatchFunction(w, spec, libStem, func);
    }
    for (final func in fnf) {
      _emitFnfFunction(w, spec, libStem, func);
    }
    if (spec.targetsWeb) w.line('#endif');
  }

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

    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri, sourceHash: spec.sourceHash));
    writer.line('#include <stdint.h>');
    writer.line('#include <stdbool.h>');
    writer.line('#include <string.h>');
    writer.line('#include <stdlib.h>');
    writer.line('#include <string>'); // _g_str_ret
    if (hasApple) {
      // Foundation already defines some of the names a spec may give its structs and enums (`Point`, `Size`, `Duration`).
      // The bridge header declares those under their Dart names, so Foundation's are renamed while it is imported here.
      final renamed = [
        for (final name in [...spec.structs.map((s) => s.name), ...spec.enums.map((e) => e.name)])
          if (isRenamableFoundationName(name)) name,
      ];
      writer.line('#if defined(__APPLE__)');
      for (final name in renamed) {
        writer.line('#define $name NitroSystem_$name');
      }
      writer.line('#import <Foundation/Foundation.h>');
      for (final name in renamed) {
        writer.line('#undef $name');
      }
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
    if (spec.webIsWasm) {
      writer.line('#ifdef __EMSCRIPTEN__');
      writer.line('#include <emscripten/emscripten.h>');
      writer.line('#include "nitro_wasm_compat.h"');
      writer.line('#else');
      writer.line('#include "dart_api_dl.h"');
      writer.line('#endif');
    } else {
      writer.line('#include "dart_api_dl.h"');
    }
    writer.line('#include "$headerName"');
    _emitCompletionBatch(writer, spec);
    writer.blankLine();
    // MSVC deprecates the POSIX name (warning C4996); _strdup is identical.
    writer.line('#if defined(_MSC_VER) && !defined(strdup)');
    writer.line('#define strdup _strdup');
    writer.line('#endif');
    writer.blankLine();

    final libStem = spec.lib.replaceAll('-', '_');
    emitBackgroundTable(writer, spec, libStem);
    final libPkg = 'nitro/${libStem}_module';
    final androidIsCpp = spec.androidImpl is CppImpl;
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
    if (spec.webIsWasm) {
      writer.line('#ifdef __EMSCRIPTEN__');
      writer.line('// Web replacement for Dart_PostCObject: Dart registers a function-table');
      writer.line('// callback here at module load (see nitro_wasm_compat.h for the envelope).');
      writer.line('NITRO_EXPORT __attribute__((weak)) void ${libStem}_nitro_set_post_fn(NitroPostFn fn) {');
      writer.line('    g_nitro_post_fn = fn;');
      writer.line('}');
      writer.line('// Hot restart rebuilds the module but keeps globalThis, so JS helpers a');
      writer.line('// previous instance parked there still close over its dead heap: calls');
      writer.line('// land out of bounds and posts reach the old instance. Returns 1 the');
      writer.line('// first time THIS instance asks, so plugin bootstraps rebuild their');
      writer.line('// globals exactly once per instance. JS-callable from any EM_JS body.');
      writer.line('EM_JS(int, nitro_web_instance_changed, (), {');
      writer.line('    var reg = globalThis.__nitroInstances || (globalThis.__nitroInstances = {});');
      writer.line('    if (reg["$libStem"] === wasmExports) return 0;');
      writer.line('    reg["$libStem"] = wasmExports;');
      writer.line('    return 1;');
      writer.line('});');
      writer.line('EM_JS(void, nitro_web_own_globals, (const char* key), {');
      writer.line('    var o = globalThis[UTF8ToString(key)];');
      writer.line('    if (o) o.__nitroExports = wasmExports;');
      writer.line('});');
      writer.line('#endif');
    }
    writer.line('}');

    writer.line('static thread_local NitroError g_nitro_error = { 0, nullptr, nullptr, nullptr, nullptr };');
    // Scratch for SYNC nullable-primitive returns, shared by the JNI and
    // Swift-shim dispatch. Sync only — see cpp_direct_emitter for the rule.
    writer.line('alignas(8) static thread_local uint8_t _g_opt_ret[16];');
    writer.line('static thread_local std::string _g_str_ret;');
    _emitStructCloneHelpers(writer, spec);
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

    _emitOwnedReleaseExports(writer, spec);

    // ── Struct release functions (used by NativeFinalizer in Dart proxy classes) ──
    if (spec.structs.isNotEmpty) {
      // Structs that cross as ZERO-COPY stream items are pinned through a JNI
      // global ref on Android (g_zero_copy_refs in the JNI prologue) so the JVM
      // object backing the borrowed buffers stays alive while Dart reads them.
      // Their release function must drop that pin: without it every delivered
      // item leaks one global reference, and ART aborts the process once the
      // global-reference table (51200 slots) fills — ~51k stream items.
      final zeroCopyStreamStructNames = androidIsCpp
          ? const <String>{}
          : spec.streams.where((s) => structNames.contains(bareTypeName(s.itemType.name))).map((s) => bareTypeName(s.itemType.name)).where((name) {
              final st = spec.structByName(name);
              return st != null && st.fields.any((f) => f.zeroCopy);
            }).toSet();
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

        _emitStructFieldReleases(writer, st, structNames);
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

    // Preprocessor branch for Android JNI vs iOS Swift. The Android section is guarded even when it is the only one:
    // `nitrogen link` compiles every module's bridge into the plugin's iOS and macOS targets, where there is no <jni.h>.
    if (includeAndroid) writer.line('#ifdef __ANDROID__');
    if (includeAndroid && androidIsCpp) {
      // android: NativeImpl.cpp in a mixed spec — direct C++ dispatch, no JNI.
      _emitAppleCppDispatch(writer, spec, libStem, enumNames, structNames);
    } else if (includeAndroid) {
      _emitJniSwiftPrologue(writer, spec, libStem, enumNames, structNames);

      _emitJniMethods(writer, spec, libStem, libPkg, enumNames, structNames);
      // `<sym>_dispatch` twins live inside each platform section, next to the
      // sync exports they call: a platform this module does not implement
      // must not reference them (unresolved externals in a Windows DLL).
      emitCppWorkerDispatch(writer, spec, libStem);
    } // end if (includeAndroid)

    // ── Apple section: NativeImpl.swift / NativeImpl.cpp / mixed ─────────────
    // Determine per-platform Apple strategy.
    final appleBothCpp = iosIsCpp && macosIsCpp;
    final appleMixedMacosCpp = macosIsCpp && !iosIsCpp && spec.targetsMacos;
    final appleMixedIosCpp = iosIsCpp && !macosIsCpp && spec.targetsIos;
    // The Apple section is emitted when iOS is Swift/C++ OR macOS is C++.
    final includeApple = includeIos || (macosIsCpp && spec.targetsMacos);

    if (includeAndroid && includeApple) {
      writer.line('#elif __APPLE__');
    } else if (includeApple) {
      // Apple is the first section. It is guarded for the same reason as the Android one: this file is also compiled
      // into the plugin's Android and desktop libraries, where the Swift stubs it calls do not exist.
      writer.line('#if defined(__APPLE__)');
    }

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
          emitCppWorkerDispatch(writer, spec, libStem);
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
          emitCppWorkerDispatch(writer, spec, libStem);
        }
        writer.line('#endif  // TARGET_OS_IOS');
      } else if (includeIos) {
        // Pure Swift on all Apple platforms (legacy / default path).
        _emitSwiftBridgeSection(writer, spec, libStem, enumNames, structNames);
        emitCppWorkerDispatch(writer, spec, libStem);
      }
    }
    // ── Desktop C++ section: Windows / Linux ────────────────────────────────
    // When Windows or Linux targets use NativeImpl.cpp in a mixed spec
    // (e.g. android:kotlin + windows:cpp), emit a direct C++ dispatch block
    // guarded by the appropriate preprocessor macro.
    final targetsWindowsCpp = spec.targetsWindows && (spec.windowsImpl is CppImpl);
    final targetsLinuxCpp = spec.targetsLinux && (spec.linuxImpl is CppImpl);
    // Web (WasmImpl) reuses the same direct C++ dispatch, compiled with emcc.
    final hasStandaloneCpp = targetsWindowsCpp || targetsLinuxCpp || spec.webIsWasm;

    if (hasStandaloneCpp) {
      // Build the preprocessor guard for the platforms that use direct C++.
      final guards = <String>[
        if (targetsWindowsCpp) 'defined(_WIN32)',
        if (targetsLinuxCpp) 'defined(__linux__)',
        if (spec.webIsWasm) 'defined(__EMSCRIPTEN__)',
      ].join(' || ');

      // Only emit the #elif chain if we're already inside an #ifdef block.
      // If neither Android nor Apple was targeted, this section is the only
      // section — no #ifdef wrapper is needed (isCppImpl would have been
      // true and we'd have gone through _generateCppDirect instead).
      final insideIfdef = includeAndroid || includeApple;
      if (insideIfdef) {
        // Keep the historical comment for non-web specs (byte-identical output).
        final label = spec.webIsWasm ? 'Windows/Linux/Web: NativeImpl.cpp/wasm' : 'Windows/Linux: NativeImpl.cpp';
        writer.line('#elif $guards  // $label — direct C++ dispatch');
      }
      _emitAppleCppDispatch(writer, spec, libStem, enumNames, structNames);
    }

    // Close the preprocessor ifdef chain the first section opened.
    if (includeAndroid || includeApple) writer.line('#endif');
    return writer.toString();
  }

}
