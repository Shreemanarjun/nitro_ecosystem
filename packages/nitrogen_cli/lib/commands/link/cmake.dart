part of '../link_command.dart';

// CMake generation + shared headers (src + desktop). Part of the link_command library.

const String _srcLocalNitroNativeCmakePath = ct.localNitroNativeCmakePath;
const String _desktopLocalNitroNativeCmakePath = r'${CMAKE_CURRENT_SOURCE_DIR}/../src/native';
void createSharedHeaders(String nitroNativePath, {String baseDir = '.'}) {
  Directory(p.join(baseDir, 'src')).createSync(recursive: true);
  final localNativeDir = Directory(p.join(baseDir, 'src', 'native'));
  localNativeDir.createSync(recursive: true);
  Directory(p.join(localNativeDir.path, 'internal')).createSync(recursive: true);
  final srcFile = File(p.join(nitroNativePath, 'nitro.h'));

  // If the source nitro.h is missing the required macros, update it first.
  if (srcFile.existsSync()) {
    final current = srcFile.readAsStringSync();
    if (!current.contains('NITRO_EXPORT')) {
      srcFile.writeAsStringSync(nitroHContent);
    }
  } else {
    // If it doesn't exist in the nitro package at all, create it.
    try {
      srcFile.createSync(recursive: true);
      srcFile.writeAsStringSync(nitroHContent);
    } catch (_) {
      // Might not have write access to the installed package; that's fine,
      // we'll write to the local project.
    }
  }

  // Always write the correct content to the local project directories.
  File(p.join(baseDir, 'src', 'nitro.h')).writeAsStringSync(nitroHContent);
  File(p.join(localNativeDir.path, 'nitro.h')).writeAsStringSync(nitroHContent);
  for (final headerName in ['dart_api_dl.h', 'dart_api.h', 'dart_native_api.h', 'dart_version.h', 'nitro_wasm_compat.h']) {
    final src = File(p.join(nitroNativePath, headerName));
    if (src.existsSync()) src.copySync(p.join(localNativeDir.path, headerName));
  }
  final implHeader = File(p.join(nitroNativePath, 'internal', 'dart_api_dl_impl.h'));
  if (implHeader.existsSync()) {
    implHeader.copySync(p.join(localNativeDir.path, 'internal', 'dart_api_dl_impl.h'));
  }
  if (Directory(p.join(baseDir, 'ios', 'Classes')).existsSync()) {
    File(
      p.join(baseDir, 'ios', 'Classes', 'nitro.h'),
    ).writeAsStringSync(nitroHContent);
  }
  if (Directory(p.join(baseDir, 'macos', 'Classes')).existsSync()) {
    File(
      p.join(baseDir, 'macos', 'Classes', 'nitro.h'),
    ).writeAsStringSync(nitroHContent);
  }
  File(
    p.join(baseDir, 'src', 'dart_api_dl.c'),
  ).writeAsStringSync(bundledDartApiDlContent);

  // Also populate any existing SPM C++ target include/ dirs (nested layout:
  // {platform}/<pluginName>/Sources/<ClassName>Cpp/include/).
  for (final platform in ['ios', 'macos']) {
    final platformDir = Directory(p.join(baseDir, platform));
    if (!platformDir.existsSync()) continue;
    for (final entry in platformDir.listSync().whereType<Directory>()) {
      final sourcesDir = Directory(p.join(entry.path, 'Sources'));
      if (!sourcesDir.existsSync()) continue;
      final packageSwift = File(p.join(entry.path, 'Package.swift'));
      final packageSwiftContent = packageSwift.existsSync() ? packageSwift.readAsStringSync() : '';
      final pluginClass = _toPascalCase(p.basename(entry.path));
      for (final targetDir in sourcesDir.listSync().whereType<Directory>()) {
        final targetName = p.basename(targetDir.path);
        if (!targetName.endsWith('Cpp')) continue;
        // A per-module target that depends on the plugin-level `<Class>Cpp`
        // target resolves these headers through it, and link/apple.dart deletes
        // any copies there — planting them here flipped the same five files on
        // every generate/link pair. Same predicate as the deletion.
        final moduleClass = targetName.substring(0, targetName.length - 3);
        if (targetName != '${pluginClass}Cpp' && _spmModuleDependsOnPluginCpp(packageSwiftContent, moduleClass, pluginClass)) continue;
        final includeDir = Directory(p.join(targetDir.path, 'include'));
        if (!includeDir.existsSync()) continue;
        // Write nitro.h with the correct guard-protected content.
        File(p.join(includeDir.path, 'nitro.h')).writeAsStringSync(nitroHContent);
        // Copy dart API headers from the nitro native source. NOT
        // nitro_wasm_compat.h: SwiftPM compiles every header in include/, and
        // that one #errors outside Emscripten. link/apple.dart deletes stale
        // copies; copying it here re-planted it on every generate.
        for (final headerName in ['dart_api_dl.h', 'dart_api.h', 'dart_native_api.h', 'dart_version.h']) {
          final src = File(p.join(nitroNativePath, headerName));
          if (src.existsSync()) src.copySync(p.join(includeDir.path, headerName));
        }
      }
    }
  }
}

void linkCMake(
  String pluginName,
  List<String> moduleLibs,
  String nitroNativePath, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  createSharedHeaders(nitroNativePath, baseDir: baseDir);
  final cmakeFile = File(p.join(baseDir, 'src', 'CMakeLists.txt'));
  if (!cmakeFile.existsSync()) {
    generateCMake(
      pluginName,
      moduleLibs,
      nitroNativePath,
      baseDir: baseDir,
      moduleInfos: moduleInfos,
    );
    return;
  }
  var content = cmakeFile.readAsStringSync();
  bool modified = false;
  final stamp = _stampLinkSpecChecksum(content, computeLinkSpecChecksum(baseDir: baseDir));
  content = stamp.content;
  modified = modified || stamp.modified;

  final optGuard = _cmakeInsertOptimizationGuard(content);
  content = optGuard.content;
  modified = modified || optGuard.modified;
  const desiredNitroValue = _srcLocalNitroNativeCmakePath;
  final nitroNativeSetLine = 'set(NITRO_NATIVE "$desiredNitroValue")';
  if (!content.contains('NITRO_NATIVE')) {
    content = '$nitroNativeSetLine\n\n$content';
    modified = true;
  } else {
    final staleMatch = RegExp(
      r'set\(NITRO_NATIVE\s+"([^"]+)"\)',
    ).firstMatch(content);
    if (staleMatch != null && staleMatch.group(1) != desiredNitroValue) {
      content = content.replaceFirst(staleMatch.group(0)!, nitroNativeSetLine);
      modified = true;
    }
  }
  if (!content.contains('CMAKE_CXX_STANDARD')) {
    // Inject C++17 standard after the project() declaration.
    content = content.replaceFirstMapped(
      RegExp(r'project\([^)]+\)\s*\n'),
      (m) => '${m.group(0)!}\nset(CMAKE_CXX_STANDARD ${BuildVersions.cmakeCxxStandard})\nset(CMAKE_CXX_STANDARD_REQUIRED ON)\n',
    );
    modified = true;
  }
  if (!content.contains(r'${NITRO_NATIVE}')) {
    content = content.replaceFirst(
      'target_include_directories($pluginName PRIVATE',
      'target_include_directories($pluginName PRIVATE\n  "\${NITRO_NATIVE}"',
    );
    modified = true;
  }
  if (!content.contains('dart_api_dl.c')) {
    content = content.replaceFirst(
      'add_library($pluginName SHARED',
      'add_library($pluginName SHARED\n  "dart_api_dl.c"',
    );
    modified = true;
  }
  final bridgeRel = '../lib/src/generated/cpp/$pluginName.bridge.g.cpp';
  if (!content.contains(bridgeRel)) {
    content = content.replaceFirst(
      'add_library($pluginName SHARED',
      'add_library($pluginName SHARED\n  "\${CMAKE_CURRENT_SOURCE_DIR}/$bridgeRel"',
    );
    modified = true;
  }

  final mainImpl = _cmakeAddMainPluginImpl(
    content,
    moduleInfos,
    pluginName,
    baseDir,
  );
  content = mainImpl.content;
  modified = modified || mainImpl.modified;

  for (final lib in moduleLibs) {
    if (lib != pluginName && !content.contains('add_library($lib ')) {
      final info = moduleInfos?.firstWhere(
        (m) => m.lib == lib,
        orElse: () => ModuleInfo(lib: lib, module: lib, isCpp: false),
      );
      // Use isNativeCpp (android/linux) — only those platforms put
      // HybridXxx.cpp into src/CMakeLists.txt. Windows-only cpp uses
      // windows/CMakeLists.txt instead.
      content += ct.cmakeModuleTarget(
        lib,
        isCpp: info?.isNativeCpp ?? false,
        isAndroidCpp: info?.isAndroidCpp ?? false,
      );
      modified = true;
    }
  }

  final retrofit = _cmakeRetrofitImplSrcGuard(content, moduleInfos, baseDir);
  content = retrofit.content;
  modified = modified || retrofit.modified;
  if (modified) cmakeFile.writeAsStringSync(content);
}

/// Inserts the CMake optimization guard (after the `project()` line, else at
/// the top) so non-standard `CMAKE_BUILD_TYPE`s (e.g. AGP's "profile") get
/// Release-grade flags instead of silently compiling at -O0. `_NITRO_CFG`
/// doubles as the idempotence marker. Returns the patched content + changed.
({String content, bool modified}) _cmakeInsertOptimizationGuard(String content) {
  var modified = false;
  // ── Optimization guard for non-standard CMAKE_BUILD_TYPEs ───────────────
  // AGP passes the Android VARIANT name ("profile") as CMAKE_BUILD_TYPE;
  // CMake has no per-config flags for unknown configs, so the whole native
  // library silently compiled at -O0 in Flutter's profile mode (release maps
  // to RELEASE and was unaffected). Insert once into existing plugins; the
  // scaffold template already carries it. `_NITRO_CFG` doubles as the
  // idempotence marker.
  if (!content.contains('_NITRO_CFG')) {
    const guard =
        '# ── Optimization guard ───────────────────────────────────────────────────────\n'
        '# The Android Gradle Plugin passes the VARIANT name (e.g. "profile") as\n'
        '# CMAKE_BUILD_TYPE. CMake only defines per-config flags for\n'
        '# Debug/Release/RelWithDebInfo/MinSizeRel — an unknown config has EMPTY flag\n'
        '# sets, so every native source silently compiles at -O0. Flutter\'s release\n'
        '# variant maps to RELEASE and is unaffected, but profile builds shipped\n'
        '# unoptimized native code. Give any non-standard config Release-grade flags.\n'
        // ignore: unnecessary_string_escapes
        'string(TOUPPER "\${CMAKE_BUILD_TYPE}" _NITRO_CFG)\n'
        'if(NOT "\${_NITRO_CFG}" MATCHES "^(DEBUG|RELEASE|RELWITHDEBINFO|MINSIZEREL|)\$")\n'
        '  set(CMAKE_C_FLAGS_\${_NITRO_CFG} "-O2 -DNDEBUG")\n'
        '  set(CMAKE_CXX_FLAGS_\${_NITRO_CFG} "-O2 -DNDEBUG")\n'
        'endif()\n';
    final projMatch = RegExp(r'^project\([^\n]*\)[ \t]*\r?\n', multiLine: true).firstMatch(content);
    if (projMatch != null) {
      content = '${content.substring(0, projMatch.end)}\n$guard${content.substring(projMatch.end)}';
    } else {
      content = '$guard\n$content';
    }
    modified = true;
    stdout.writeln('  src/CMakeLists.txt: added optimization guard (profile-mode Android builds compiled at -O0)');
  }
  return (content: content, modified: modified);
}

/// Adds the main plugin's `HybridXxx.cpp` impl to `src/CMakeLists.txt` when
/// the main module uses android/linux C++ (`isNativeCpp`) and the file
/// exists: inline in `add_library` for android-cpp, else inside a
/// `if(NOT ANDROID)` guard for linux-only. Returns the patched content +
/// changed.
({String content, bool modified}) _cmakeAddMainPluginImpl(
  String content,
  List<ModuleInfo>? moduleInfos,
  String pluginName,
  String baseDir,
) {
  var modified = false;
  // Add the main plugin's HybridXxx.cpp impl file when:
  //   • the module uses NativeImpl.cpp on android/linux (isNativeCpp) — the
  //     src/ CMakeLists is for Android/Linux only; macOS/iOS are handled by SPM/CocoaPods.
  //   • the file exists in src/, and
  //   • it is not already listed in the cmake (either inline or in a NOT ANDROID guard).
  //
  // When android uses Kotlin (isAndroidCpp=false) but linux uses C++, wrap in
  // `if(NOT ANDROID)` so the NDK build skips the C++ impl stub.
  if (moduleInfos != null) {
    final mainInfo = moduleInfos.firstWhere(
      (m) => m.lib == pluginName,
      orElse: () => ModuleInfo(lib: pluginName, module: pluginName, isCpp: false),
    );
    if (mainInfo.isNativeCpp) {
      final className = _toPascalCase(
        mainInfo.module.isNotEmpty ? mainInfo.module : pluginName,
      );
      final implName = 'Hybrid$className.cpp';
      final implFile = File(p.join(baseDir, 'src', implName));
      if (implFile.existsSync() && !content.contains('"$implName"')) {
        if (mainInfo.isAndroidCpp) {
          // Android uses C++ directly — embed impl in add_library.
          content = content.replaceFirst(
            'add_library($pluginName SHARED',
            'add_library($pluginName SHARED\n  "$implName"',
          );
        } else {
          // Linux-only C++ — exclude from Android NDK builds.
          content = content.replaceFirst(
            'target_include_directories($pluginName PRIVATE',
            'if(NOT ANDROID)\n  target_sources($pluginName PRIVATE "$implName")\nendif()\ntarget_include_directories($pluginName PRIVATE',
          );
        }
        modified = true;
      }
    }
  }
  return (content: content, modified: modified);
}

/// Retrofits the `NITRO_IMPL_SRC` guard onto a pre-separation
/// `src/CMakeLists.txt` once a module opts into per-platform desktop impls
/// (issue #12): rewrites a hardcoded/inline `HybridXxx.cpp` source into the
/// variable-driven `implSourcesBlock`. Only fires where separation is
/// actually requested/active, so never-opted-in projects stay byte-identical.
({String content, bool modified}) _cmakeRetrofitImplSrcGuard(
  String content,
  List<ModuleInfo>? moduleInfos,
  String baseDir,
) {
  var modified = false;
  // Retrofit the NITRO_IMPL_SRC guard onto a pre-separation src/CMakeLists
  // once a module opts into per-platform desktop impls (issue #12): the
  // platform CMakeLists set NITRO_IMPL_SRC_<lib>, but an existing file that
  // hardcodes `target_sources(<lib> PRIVATE "HybridXxx.cpp")` (or compiles
  // the impl inline in add_library) silently ignores them — the build keeps
  // compiling the shared impl while the per-platform files sit unused.
  // Only fires for modules where separation is actually requested/active,
  // so never-opted-in projects keep byte-identical CMakeLists. The guard's
  // else-branch preserves the old behavior exactly when the variable is
  // unset (e.g. Android builds of the same file).
  if (moduleInfos != null) {
    for (final m in moduleInfos.where((m) => m.isCpp)) {
      final varName = ct.nitroImplSrcVar(m.lib);
      if (content.contains(varName)) continue; // already guarded
      final cls = _toPascalCase(m.lib);
      final separationActive =
          (m.windowsIsCpp && (m.windowsRequestsSeparateImpl || hasCustomPlatformImpl(baseDir, 'windows', cls))) ||
          (m.linuxIsCpp && (m.linuxRequestsSeparateImpl || hasCustomPlatformImpl(baseDir, 'linux', cls)));
      if (!separationActive) continue;
      // Both className conventions appear in the wild (older links derived it
      // from `module`, stubs derive it from `lib`).
      for (final className in {cls, _toPascalCase(m.module)}) {
        final implName = 'Hybrid$className.cpp';
        final wrapped = RegExp(
          'if\\(NOT ANDROID\\)\\s*\\n\\s*target_sources\\(${RegExp.escape(m.lib)} PRIVATE "${RegExp.escape(implName)}"\\)\\s*\\nendif\\(\\)\\n?',
        );
        final bare = RegExp(
          'target_sources\\(${RegExp.escape(m.lib)} PRIVATE "${RegExp.escape(implName)}"\\)\\n?',
        );
        final inline = '\n  "$implName"';
        if (wrapped.hasMatch(content)) {
          content = content.replaceFirst(wrapped, ct.implSourcesBlock(m.lib, className, unguarded: false));
          modified = true;
          break;
        } else if (bare.hasMatch(content)) {
          content = content.replaceFirst(bare, ct.implSourcesBlock(m.lib, className, unguarded: m.isAndroidCpp));
          modified = true;
          break;
        } else if (content.contains('add_library(${m.lib} SHARED') && content.contains(inline)) {
          // Impl listed inline inside add_library (android-cpp layout):
          // move it out into the guarded block, same unconditional semantics.
          content = content.replaceFirst(inline, '');
          final addLib = RegExp('add_library\\(${RegExp.escape(m.lib)} SHARED[^)]*\\)\\n');
          final match = addLib.firstMatch(content);
          if (match != null) {
            content = content.replaceFirst(match.group(0)!, '${match.group(0)!}${ct.implSourcesBlock(m.lib, className, unguarded: true)}');
          } else {
            content += ct.implSourcesBlock(m.lib, className, unguarded: true);
          }
          modified = true;
          break;
        }
      }
    }
  }
  return (content: content, modified: modified);
}

void generateCMake(
  String pluginName,
  List<String> moduleLibs,
  String nitroNativePath, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  final infos = moduleInfos?.map((m) => (lib: m.lib, module: m.module, isNativeCpp: m.isNativeCpp, isAndroidCpp: m.isAndroidCpp)).toList();
  final linkChecksum = computeLinkSpecChecksum(baseDir: baseDir);

  File(p.join(baseDir, 'src', 'CMakeLists.txt')).writeAsStringSync(
    ct.generateCMakeContent(
      pluginName,
      moduleLibs,
      _srcLocalNitroNativeCmakePath,
      moduleInfos: infos,
      linkChecksum: linkChecksum,
    ),
  );
}

// _cmakeModuleTarget is provided by '../templates/cmake_templates.dart' as ct.cmakeModuleTarget.

String _toPascalCase(String lib) => lib.split(RegExp(r'[_\-]')).map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');

/// Patches a desktop platform CMakeLists.txt (windows/ or linux/) to include
/// the Nitro bridge sources and headers required for dart:ffi C++ plugins.
/// Desktop templates use `${PLUGIN_NAME}` as the CMake target name.
void _linkDesktopCMake(
  String pluginName,
  List<String> moduleLibs,
  String nitroNativePath, {
  required String platform,
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  final cmakeFile = File(p.join(baseDir, platform, 'CMakeLists.txt'));
  if (!cmakeFile.existsSync()) return;
  var content = cmakeFile.readAsStringSync();
  bool modified = false;

  // Flutter app-runner CMakeLists (an example app's windows/ or linux/ dir) —
  // strip any nitro-injected block and stop; `${PLUGIN_NAME}` is undefined
  // there so an include block on it breaks configure (issue #11).
  if (_desktopCMakeStripIfAppRunner(cmakeFile, content, platform)) return;

  const desiredNitroValue = _desktopLocalNitroNativeCmakePath;
  if (!content.contains('NITRO_NATIVE')) {
    content = 'set(NITRO_NATIVE "$desiredNitroValue")\n\n$content';
    modified = true;
  } else {
    final staleMatch = RegExp(
      r'set\(NITRO_NATIVE\s+"([^"]+)"\)',
    ).firstMatch(content);
    if (staleMatch != null && staleMatch.group(1) != desiredNitroValue) {
      content = content.replaceFirst(
        staleMatch.group(0)!,
        'set(NITRO_NATIVE "$desiredNitroValue")',
      );
      modified = true;
    }
  }

  // Desktop CMake templates use `${PLUGIN_NAME}` (a CMake variable) as the
  // target name. Use literal string matching to avoid regex backreference issues.
  // The pattern covers the common "add_library(${PLUGIN_NAME} SHARED\n" line.
  const addLibLine = 'add_library(\${PLUGIN_NAME} SHARED\n';

  // If the platform CMakeLists delegates compilation to the shared src/ directory
  // via add_subdirectory("../src"), then dart_api_dl.c and bridge.g.cpp are
  // already compiled through src/CMakeLists.txt. Skip adding them here to avoid
  // duplicate-symbol linker errors and confusing doctor warnings.
  final usesSharedSrc = content.contains('add_subdirectory') && (content.contains('"../src"') || content.contains(r'"${CMAKE_CURRENT_SOURCE_DIR}/../src"'));

  if (!usesSharedSrc) {
    if (!content.contains('dart_api_dl.c')) {
      content = content.replaceFirst(
        addLibLine,
        '$addLibLine  "\${CMAKE_CURRENT_SOURCE_DIR}/../src/dart_api_dl.c"\n',
      );
      modified = true;
    }

    final bridgeRel = '../lib/src/generated/cpp/$pluginName.bridge.g.cpp';
    if (!content.contains(bridgeRel)) {
      content = content.replaceFirst(
        addLibLine,
        '$addLibLine  "\${CMAKE_CURRENT_SOURCE_DIR}/$bridgeRel"\n',
      );
      modified = true;
    }
  }

  if (usesSharedSrc) {
    _desktopCMakeHandleSharedSrc(
      cmakeFile,
      content,
      modified,
      platform: platform,
      baseDir: baseDir,
      moduleInfos: moduleInfos,
    );
    return;
  }

  if (!content.contains(r'${NITRO_NATIVE}')) {
    final addBlock =
        '\ntarget_include_directories(\${PLUGIN_NAME} PRIVATE\n'
        '  "\${NITRO_NATIVE}"\n'
        '  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"\n'
        '  "\${CMAKE_CURRENT_SOURCE_DIR}/../src"\n'
        ')\n';
    final inclMatch = RegExp(
      r'target_include_directories\(\s*\$\{PLUGIN_NAME\}[^)]+\)',
    ).firstMatch(content);
    if (inclMatch != null) {
      content = content.replaceFirst(
        inclMatch.group(0)!,
        '${inclMatch.group(0)!}$addBlock',
      );
    } else {
      content += addBlock;
    }
    modified = true;
  } else if (!content.contains(r'/../src"')) {
    // NITRO_NATIVE already present but ../src missing — append to existing Nitro include block.
    content = content.replaceFirstMapped(
      RegExp(
        r'("\$\{CMAKE_CURRENT_SOURCE_DIR\}/../lib/src/generated/cpp"\s*\n)',
      ),
      (m) => '${m.group(0)!}  "\${CMAKE_CURRENT_SOURCE_DIR}/../src"\n',
    );
    modified = true;
  }

  if (modified) cmakeFile.writeAsStringSync(content);
}

/// Detects a Flutter app-runner CMakeLists (windows/ or linux/ of an example
/// app that is itself a Nitro module — has BINARY_NAME / add_executable) and,
/// when found, strips any nitro-injected `${PLUGIN_NAME}` include block +
/// NITRO_NATIVE set() line (they break configure — `${PLUGIN_NAME}` is
/// undefined there, issue #11). Returns true when it was an app runner so the
/// caller stops.
bool _desktopCMakeStripIfAppRunner(
  File cmakeFile,
  String content,
  String platform,
) {
  final isAppRunner = content.contains('BINARY_NAME') || content.contains('add_executable(');
  if (isAppRunner) {
    var cleaned = content.replaceAll(
      RegExp(r'\n?target_include_directories\(\s*\$\{PLUGIN_NAME\}[^)]+\)\n?'),
      '\n',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'^set\(NITRO_NATIVE "[^"]*"\)\n\n?', multiLine: true),
      '',
    );
    if (cleaned != content) {
      cmakeFile.writeAsStringSync(cleaned);
      stdout.writeln('  $platform/CMakeLists.txt: removed nitro-injected block from app-runner CMakeLists (it broke configure with an undefined \${PLUGIN_NAME})');
    }
    return true;
  }
  return false;
}

/// Handles the `add_subdirectory("../src")` shared-src desktop layout: wires
/// the per-platform NITRO_IMPL_SRC vars before the subdirectory include, then
/// either strips a stale `${PLUGIN_NAME}` include block (pure shared-src, no
/// own target) or exposes the registrant target's public include/ dir
/// (multi-spec plugins). Owns the final write; the caller returns afterward.
void _desktopCMakeHandleSharedSrc(
  File cmakeFile,
  String content,
  bool modified, {
  required String platform,
  required String baseDir,
  List<ModuleInfo>? moduleInfos,
}) {
  // Point src/CMakeLists.txt at THIS platform's own impl file instead of
  // the file it'd otherwise share with the other desktop platform.
  // Two independent, either-is-sufficient ways to opt in:
  //   1. Implicit / gradual: the plugin author has actually started
  //      writing code in $platform/src/Hybrid<Class>.cpp (see
  //      hasCustomPlatformImpl) — an untouched stub doesn't count.
  //   2. Explicit / immediate: the annotation spells this platform's impl
  //      using its specific marker type (`WindowsNativeImpl.cpp` /
  //      `LinuxNativeImpl.cpp`) rather than the generic `NativeImpl.cpp`
  //      shorthand (see requestsSeparateWindowsImpl/requestsSeparateLinuxImpl)
  //      — linkWindowsCppImplStubs/linkLinuxCppImplStubs migrate the
  //      shared file's content into the new location the first time this
  //      fires, so activating is a location change, not a behavior change.
  // Neither path applies just because a module targets NativeImpl.cpp on
  // both desktop platforms — some plugins want one shared file because the
  // logic really is identical across them; others want Windows and Linux
  // to diverge. Both are valid, ongoing choices. Must run before
  // add_subdirectory("../src") so the variable is visible when
  // src/CMakeLists.txt's target_sources(... $NITRO_IMPL_SRC_<lib> ...)
  // call reads it.
  final needsOwnImpl =
      moduleInfos
          ?.where(
            (m) =>
                (platform == 'windows' ? m.windowsIsCpp : m.linuxIsCpp) &&
                ((platform == 'windows' ? m.windowsRequestsSeparateImpl : m.linuxRequestsSeparateImpl) || hasCustomPlatformImpl(baseDir, platform, _toPascalCase(m.lib))),
          )
          .toList() ??
      const <ModuleInfo>[];
  if (needsOwnImpl.isNotEmpty) {
    final addSubdirMatch = RegExp(r'add_subdirectory\([^)]+\)').firstMatch(content);
    if (addSubdirMatch != null) {
      final setLines = StringBuffer();
      for (final m in needsOwnImpl) {
        final varName = ct.nitroImplSrcVar(m.lib);
        if (content.contains('set($varName ')) continue; // already wired, idempotent
        // Matches linkWindowsCppImplStubs/linkLinuxCppImplStubs's filename
        // convention exactly (Hybrid$className.cpp, className from m.lib).
        final className = _toPascalCase(m.lib);
        setLines.writeln('set($varName "\${CMAKE_CURRENT_SOURCE_DIR}/src/Hybrid$className.cpp")');
      }
      if (setLines.isNotEmpty) {
        content = content.replaceFirst(addSubdirMatch.group(0)!, '$setLines${addSubdirMatch.group(0)!}');
        modified = true;
      }
    }
  }

  // Two distinct shapes share the "add_subdirectory(../src)" marker:
  //   1. Pure shared-src (single-spec FFI plugins, e.g. nitro_torch): the
  //      Nitro module library IS the only target; `${PLUGIN_NAME}` is
  //      undefined. Appending target_include_directories on it is a hard
  //      CMake configure error — strip any such block and stop.
  //   2. Multi-spec plugins (e.g. benchmark: benchmark/benchmark_cpp/nitro_ar
  //      sharing src/, PLUS their own `benchmark_plugin.cc` registrant
  //      target): `${PLUGIN_NAME}` IS a real target here, separate from the
  //      shared Nitro module libraries. Its public `include/` dir must stay
  //      exposed via INTERFACE so the example app's
  //      generated_plugin_registrant.cc can find `<pkg>/<pkg>_plugin.h`.
  final hasOwnPluginTarget = RegExp(r'add_library\(\s*\$\{PLUGIN_NAME\}').hasMatch(content);

  if (!hasOwnPluginTarget) {
    final staleIncl = RegExp(
      r'\n?target_include_directories\(\s*\$\{PLUGIN_NAME\}[^)]+\)\n?',
    ).firstMatch(content);
    if (staleIncl != null) {
      content = content.replaceFirst(staleIncl.group(0)!, '\n');
      modified = true;
    }
    if (modified) cmakeFile.writeAsStringSync(content);
    return;
  }

  // hasOwnPluginTarget: ensure the registrant's public include/ dir is
  // exposed, without disturbing any other target_include_directories call
  // (e.g. a PRIVATE block for internal Nitro headers) that may already exist.
  final includeDirLiteral = r'${CMAKE_CURRENT_SOURCE_DIR}/include';
  final hasIncludeDirExposed = RegExp(
    r'target_include_directories\(\s*\$\{PLUGIN_NAME\}\s+INTERFACE[^)]*\/include',
  ).hasMatch(content);
  if (!hasIncludeDirExposed && Directory(p.join(baseDir, platform, 'include')).existsSync()) {
    final addLibMatch = RegExp(r'add_library\(\s*\$\{PLUGIN_NAME\}[^)]*\)').firstMatch(content);
    final block = '\ntarget_include_directories(\${PLUGIN_NAME} INTERFACE\n  "$includeDirLiteral")\n';
    if (addLibMatch != null) {
      content = content.replaceFirst(addLibMatch.group(0)!, '${addLibMatch.group(0)!}\n$block');
    } else {
      content += block;
    }
    modified = true;
  }
  if (modified) cmakeFile.writeAsStringSync(content);
  return;
}

/// Removes the first block matching [opener] (a pattern ending at the block's
/// opening `{`) together with its ENTIRE brace-balanced body and a trailing
/// newline. Returns [content] unchanged when no match is found or the braces
/// never balance (malformed input is left alone rather than half-deleted).
String _removeBraceBalancedBlock(String content, RegExp opener) {
  final match = opener.firstMatch(content);
  if (match == null) return content;
  var depth = 0;
  for (var i = match.end - 1; i < content.length; i++) {
    final ch = content.codeUnitAt(i);
    if (ch == 0x7B) depth++; // {
    if (ch == 0x7D) depth--; // }
    if (depth == 0) {
      var end = i + 1;
      // Swallow trailing whitespace up to and including one newline.
      while (end < content.length && (content.codeUnitAt(end) == 0x20 || content.codeUnitAt(end) == 0x09)) {
        end++;
      }
      if (end < content.length && content.codeUnitAt(end) == 0x0A) end++;
      return content.replaceRange(match.start, end, '');
    }
  }
  return content; // unbalanced — do not touch
}
