part of '../link_command.dart';

// Apple linking: podspec / SPM / Swift plugin (iOS + macOS).
// Part of the link_command library.

/// Copies `*.bridge.g.swift` files from `lib/src/generated/swift/` into [classesDir].
/// Putting the bridge in Classes/ ensures Xcode compiles it in the **same module
/// scope** as the plugin's other Swift files, resolving "Cannot find X in scope" errors
/// that occur when the bridge is only referenced via a podspec outer-glob path.
void _copySwiftBridgesToClasses(
  Directory classesDir,
  String baseDir, {
  String platform = 'ios',
}) {
  classesDir.createSync(recursive: true);
  final swiftGenDir = Directory(
    p.join(baseDir, 'lib', 'src', 'generated', 'swift'),
  );
  if (!swiftGenDir.existsSync()) return;
  final bridgeFiles = swiftGenDir.listSync().whereType<File>().where((f) => p.basename(f.path).endsWith('.bridge.g.swift')).toList()
    ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  // Cumulative dedup: the shared preamble is emitted piecewise per spec (a
  // record-only spec has NitroRecordWriter/Reader but no NitroEncodable), so
  // track which declarations the module has already seen instead of assuming
  // the first file carries the full preamble.
  final definedDecls = <String>{};
  for (final file in bridgeFiles) {
    final dest = p.join(classesDir.path, p.basename(file.path));
    File(dest).writeAsStringSync(
      dedupeSharedSwiftDecls(file.readAsStringSync(), definedDecls),
    );
  }
}

/// Syncs generated `.bridge.g.swift` files into the SPM Swift target directories.
///
/// Handles both flat (`ios/Package.swift`) and Flutter 3.41+ nested
/// (`ios/<name>/Package.swift`) SPM layouts.  For each detected platform
/// package, the function walks every `Sources/<Target>/` directory (excluding
/// C++ targets ending in `Cpp`) and copies generated bridge files there so SPM
/// compiles the latest bridges without needing CocoaPods.
void _syncSwiftBridgesToSpmSources(String baseDir) {
  final swiftGenDir = Directory(p.join(baseDir, 'lib', 'src', 'generated', 'swift'));
  if (!swiftGenDir.existsSync()) return;
  final allBridges = swiftGenDir.listSync().whereType<File>().where((f) => p.basename(f.path).endsWith('.bridge.g.swift')).toList()
    ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  if (allBridges.isEmpty) return;

  // NativeImpl.cpp bridge files omit the shared preamble (NitroEncodable,
  // NitroRecordWriter, etc.) — they rely on another bridge in the module to
  // provide it.  Sort bridges that DEFINE shared declarations first so the
  // first file processed contains the preamble. The preamble is emitted
  // piecewise per spec (a record-only spec has NitroRecordWriter/Reader but
  // no NitroEncodable), so check for any shared marker, not just the protocol.
  bool hasPreamble(File f) {
    final content = f.readAsStringSync();
    return content.contains('\npublic protocol NitroEncodable') || content.contains('\npublic class NitroRecordWriter') || content.contains('\npublic class NitroRecordReader');
  }

  final generatedBridges = [
    ...allBridges.where(hasPreamble),
    ...allBridges.where((f) => !hasPreamble(f)),
  ];

  final spmStatus = spm.detectSpmStatus(baseDir);

  for (final platform in ['ios', 'macos']) {
    final packageSwiftPath = platform == 'ios' ? spmStatus.iosPackageSwiftPath : spmStatus.macosPackageSwiftPath;
    if (packageSwiftPath == null) continue;

    // Sources/ is always a sibling of Package.swift (whether flat or nested).
    final packageRoot = File(packageSwiftPath).parent.path;
    final sourcesDir = Directory(p.join(packageRoot, 'Sources'));
    if (!sourcesDir.existsSync()) continue;

    // Walk all immediate subdirs of Sources/ — each is an SPM target
    for (final entry in sourcesDir.listSync().whereType<Directory>()) {
      // Only copy into Swift targets (skip C/C++ targets whose names end in Cpp)
      if (entry.path.endsWith('Cpp')) continue;
      // One dedup set per SPM target — each target is its own Swift module,
      // so shared declarations must appear exactly once per target.
      final definedDecls = <String>{};
      for (final bridge in generatedBridges) {
        final dest = p.join(entry.path, p.basename(bridge.path));
        File(dest).writeAsStringSync(
          dedupeSharedSwiftDecls(bridge.readAsStringSync(), definedDecls),
        );
      }
    }
  }
}

/// Removes the `'../lib/src/generated/swift/**/*.swift'` glob from [podspecFile]'s
/// `s.source_files` line. This must be called after [_copySwiftBridgesToClasses] to
/// prevent the same file from being compiled twice (duplicate-symbol errors).
void _removeSwiftGlobFromPodspec(File podspecFile) {
  if (!podspecFile.existsSync()) return;
  var spec = podspecFile.readAsStringSync();
  final fixed = spec
      .replaceAll(", '../lib/src/generated/swift/**/*.swift'", '')
      .replaceAll("'../lib/src/generated/swift/**/*.swift', ", '')
      .replaceAll("'../lib/src/generated/swift/**/*.swift'", "'Classes/**/*'");
  if (fixed != spec) podspecFile.writeAsStringSync(fixed);
}

/// Builds the `#if` guard condition that determines on which platforms the
/// auto-register call should fire inside a `src/HybridXxx.cpp` stub.
/// For each NativeImpl.cpp module that targets Android, Linux, iOS, or macOS,
/// creates a starter `src/Hybrid${Module}.cpp` stub if one doesn't already exist.
///
/// Always created for Android/Linux/iOS/macOS-C++ modules — this is the
/// shared, single-file default every plugin starts from, kept regardless of
/// whether Windows and/or Linux later diverge into their own
/// `windows/src/` / `linux/src/` file (see [hasCustomPlatformImpl] —
/// separation is opt-in per platform by actually writing code in that
/// file, not automatic just because a module targets NativeImpl.cpp on
/// both desktop platforms). A plugin that never diverges keeps this ONE
/// file as its only impl, on purpose — sharing genuinely-identical logic
/// across platforms is often the better choice, not a fallback.
void linkCppImplStubs(List<ModuleInfo> moduleInfos, {String baseDir = '.'}) {
  // Ensure src/ exists before writing stubs (createSync is idempotent).
  Directory(p.join(baseDir, 'src')).createSync(recursive: true);

  // Only create stubs for modules whose src/ file is actually compiled:
  // android/linux (isNativeCpp), iOS (iosIsCpp), or macOS (macosIsCpp).
  // Windows-only modules use windows/src/ instead (see linkWindowsCppImplStubs).
  for (final m in moduleInfos.where(
    (m) => m.isNativeCpp || m.iosIsCpp || m.macosIsCpp,
  )) {
    final className = _toPascalCase(m.lib);
    final stubFile = File(p.join(baseDir, 'src', 'Hybrid$className.cpp'));
    if (stubFile.existsSync()) continue; // never overwrite user code
    stubFile.writeAsStringSync(
      t.cppImplStubContent(
        lib: m.lib,
        className: className,
        isNativeCpp: m.isNativeCpp,
        isAndroidCpp: m.isAndroidCpp,
        iosIsCpp: m.iosIsCpp,
        macosIsCpp: m.macosIsCpp,
        windowsIsCpp: m.windowsIsCpp,
      ),
    );
  }
}

void linkPodspec(
  String pluginName,
  List<String> moduleLibs, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  final nitroNativePath = resolveNitroNativePath(baseDir);
  final podspecFile = File(p.join(baseDir, 'ios', '$pluginName.podspec'));
  if (!podspecFile.existsSync()) return;
  var content = podspecFile.readAsStringSync();
  bool modified = false;
  // Normalize source_files to 'Classes/**/*'.
  // Flutter's SPM-first template generates paths like '<plugin>/Sources/<plugin>/**/*'
  // which point to non-existent directories when CocoaPods is the build system,
  // causing "No files found matching ..." warnings and empty pod targets.
  final sourceFilesMatch = RegExp(r"s\.source_files\s*=\s*'([^']+)'").firstMatch(content);
  if (sourceFilesMatch != null && sourceFilesMatch.group(1) != 'Classes/**/*') {
    final badPath = sourceFilesMatch.group(1)!;
    // Fix any non-Classes path. Flutter's SPM-first template generates paths like
    // '<plugin>/Sources/<plugin>/**/*'; for SPM-layout plugins the first directory
    // segment exists on disk even though the glob matches nothing, so we cannot
    // rely on existsSync() to detect the bad path — always normalize.
    final firstSegment = badPath.split('/').first;
    if (firstSegment != 'Classes') {
      content = content.replaceFirst(
        sourceFilesMatch.group(0)!,
        "s.source_files = 'Classes/**/*'",
      );
      modified = true;
    }
  }
  if (!content.contains("s.swift_version = '${BuildVersions.podSwiftVersion}'")) {
    content = content.replaceFirst(
      RegExp(r"s\.swift_version\s*=\s*'.+?'"),
      "s.swift_version = '${BuildVersions.podSwiftVersion}'",
    );
    modified = true;
  }
  if (!content.contains("s.platform = :ios, '${BuildVersions.iosDeployment}.0'")) {
    content = content.replaceFirst(
      RegExp(r"s\.platform\s*=\s*:ios,\s*'.+?'"),
      "s.platform = :ios, '${BuildVersions.iosDeployment}.0'",
    );
    modified = true;
  }
  final xcResult = _patchApplePodspecXcconfig(content, isMacos: false);
  content = xcResult.content;
  if (xcResult.modified) modified = true;
  // Sync generated Swift bridges into ios/Classes/ so Xcode can compile them
  // in the same module scope as the plugin's other Swift files.
  // Using a podspec source_files glob to ../lib/src/generated/swift/ does NOT
  // reliably work — types defined there are not always in scope for Classes/ files.
  if (modified) podspecFile.writeAsStringSync(content);
  createSharedHeaders(nitroNativePath, baseDir: baseDir);
  final classesDir = Directory(p.join(baseDir, 'ios', 'Classes'))..createSync(recursive: true);
  File(
    p.join(classesDir.path, 'dart_api_dl.c'),
  ).writeAsStringSync(classesDartApiDlForwarder);
  syncBridgeFiles(baseDir);
  _copySwiftBridgesToClasses(classesDir, baseDir);
  // Remove the outer lib/src/generated/swift glob from the podspec if present,
  // since the bridge is now copied directly into Classes/ (avoids duplicate symbols).
  _removeSwiftGlobFromPodspec(podspecFile);

  // Link the main project source files.
  final cppInSrc = File(p.join(baseDir, 'src', '$pluginName.cpp'));
  if (cppInSrc.existsSync()) {
    cleanRedundantIncludes(cppInSrc);
    File(p.join(classesDir.path, '$pluginName.cpp')).writeAsStringSync(
      managedCppForwarder('../../src/$pluginName.cpp'),
    );
  }
  final cInSrc = File(p.join(baseDir, 'src', '$pluginName.c'));
  if (cInSrc.existsSync()) {
    cleanRedundantIncludes(cInSrc);
    File(
      p.join(classesDir.path, '$pluginName.c'),
    ).writeAsStringSync(classesCForwarder(pluginName));
  }

  // Link C++ module implementation files for iOS.
  // On Android each module is a separate .so via CMake. On iOS everything is
  // compiled into one pod binary, so only ios:NativeImpl.cpp modules need
  // a Hybrid*.cpp forwarder in ios/Classes/.
  // Windows-only or macos-only C++ modules must NOT get a forwarder here.
  _writeAppleModuleForwarders(moduleInfos, classesDir, baseDir, isIosCppModule);

  ensureIosPackageSwift(pluginName, baseDir: baseDir, moduleInfos: moduleInfos);

  // Re-affirm the correct ../../src/ relative paths AFTER ensureIosPackageSwift,
  // which may write forwarders into Sources/NitroPubTestCpp/ with ../../../src/.
  // These are two different files, but belt-and-suspenders: always end with the
  // definitive Classes/ versions so a stale copy can never win.
  File(
    p.join(classesDir.path, 'dart_api_dl.c'),
  ).writeAsStringSync(classesDartApiDlForwarder);
  if (cppInSrc.existsSync()) {
    File(p.join(classesDir.path, '$pluginName.cpp')).writeAsStringSync(
      managedCppForwarder('../../src/$pluginName.cpp'),
    );
  }
  if (cInSrc.existsSync()) {
    File(
      p.join(classesDir.path, '$pluginName.c'),
    ).writeAsStringSync(classesCForwarder(pluginName));
  }
}

void linkMacosPodspec(
  String pluginName,
  List<String> moduleLibs, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  final nitroNativePath = resolveNitroNativePath(baseDir);
  final podspecFile = File(p.join(baseDir, 'macos', '$pluginName.podspec'));
  if (!podspecFile.existsSync()) return;
  var content = podspecFile.readAsStringSync();
  bool modified = false;
  // Normalize source_files to 'Classes/**/*' (same fix as linkIosPodspec).
  final sourceFilesMatchMacos = RegExp(r"s\.source_files\s*=\s*'([^']+)'").firstMatch(content);
  if (sourceFilesMatchMacos != null && sourceFilesMatchMacos.group(1) != 'Classes/**/*') {
    final badPath = sourceFilesMatchMacos.group(1)!;
    // Fix any non-Classes path regardless of whether the first directory exists —
    // for SPM-layout plugins the directory exists but the glob still matches nothing.
    final firstSegment = badPath.split('/').first;
    if (firstSegment != 'Classes') {
      content = content.replaceFirst(
        sourceFilesMatchMacos.group(0)!,
        "s.source_files = 'Classes/**/*'",
      );
      modified = true;
    }
  }
  if (!content.contains("s.swift_version = '${BuildVersions.podSwiftVersion}'")) {
    content = content.replaceFirst(
      RegExp(r"s\.swift_version\s*=\s*'.+?'"),
      "s.swift_version = '${BuildVersions.podSwiftVersion}'",
    );
    modified = true;
  }
  final macosDeployment = BuildVersions.macosDeployment.replaceAll('_', '.');
  if (!content.contains("s.platform = :osx, '$macosDeployment'")) {
    if (RegExp(r"s\.platform\s*=\s*:osx").hasMatch(content)) {
      content = content.replaceFirst(
        RegExp(r"s\.platform\s*=\s*:osx,\s*'.+?'"),
        "s.platform = :osx, '$macosDeployment'",
      );
    } else {
      // Insert platform line after the spec name line
      content = content.replaceFirst(
        RegExp(r"(s\.name\s*=.+\n)"),
        "\$1  s.platform = :osx, '$macosDeployment'\n",
      );
    }
    modified = true;
  }
  final xcResult = _patchApplePodspecXcconfig(content, isMacos: true);
  content = xcResult.content;
  if (xcResult.modified) modified = true;
  // Sync generated Swift bridges into macos/Classes/ so Xcode compiles them
  // in the same module scope as the plugin's other Swift files.
  if (modified) podspecFile.writeAsStringSync(content);
  createSharedHeaders(nitroNativePath, baseDir: baseDir);
  final classesDir = Directory(p.join(baseDir, 'macos', 'Classes'))..createSync(recursive: true);
  File(
    p.join(classesDir.path, 'dart_api_dl.c'),
  ).writeAsStringSync(classesDartApiDlForwarder);
  syncBridgeFiles(baseDir, platform: 'macos');
  _copySwiftBridgesToClasses(classesDir, baseDir, platform: 'macos');
  _removeSwiftGlobFromPodspec(podspecFile);

  // Link the main project source files.
  final cppInSrc = File(p.join(baseDir, 'src', '$pluginName.cpp'));
  if (cppInSrc.existsSync()) {
    cleanRedundantIncludes(cppInSrc);
    File(p.join(classesDir.path, '$pluginName.cpp')).writeAsStringSync(
      managedCppForwarder('../../src/$pluginName.cpp'),
    );
  }
  final cInSrc = File(p.join(baseDir, 'src', '$pluginName.c'));
  if (cInSrc.existsSync()) {
    cleanRedundantIncludes(cInSrc);
    File(
      p.join(classesDir.path, '$pluginName.c'),
    ).writeAsStringSync(classesCForwarder(pluginName));
  }

  // Link C++ module implementation files for macOS — same logic as iOS above.
  // Only macos:NativeImpl.cpp modules get a Hybrid*.cpp forwarder in macos/Classes/.
  _writeAppleModuleForwarders(moduleInfos, classesDir, baseDir, isMacosCppModule);
}

/// Wires non-cpp module registrations into the macOS Swift plugin file.
///
/// Mirrors [linkSwiftPlugin] but targets `macos/` instead of `ios/`. Searches
/// `macos/` recursively for `*Plugin.swift` and injects `Registry.register(...)`
/// calls for each non-cpp module that doesn't already have one.
void linkMacosSwiftPlugin(
  String pluginName,
  List<Map<String, String>> modules, {
  String baseDir = '.',
}) {
  final macosDir = Directory(p.join(baseDir, 'macos'));
  if (!macosDir.existsSync()) return;
  final pluginFiles = macosDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.swift'))
      .toList();

  if (pluginFiles.isEmpty) {
    // Create default macOS plugin if missing
    final className = _toPascalCase(pluginName);
    final fileName = '${className}Plugin.swift';
    final targetPath = p.join(macosDir.path, 'Classes', fileName);
    Directory(p.dirname(targetPath)).createSync(recursive: true);
    final stub = st.macosPluginSwiftStub(className);
    File(targetPath).writeAsStringSync(stub);
    pluginFiles.add(File(targetPath));
  }

  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;
  for (final m in modules) {
    final name = m['module']!;
    final lib = (m['lib'] ?? name.toLowerCase()).replaceAll('-', '_');
    final reg = '${name}Registry';
    // Standard implementation naming: BenchmarkImpl or BenchmarkModuleImpl
    final impl = name.endsWith('Module') ? '${name}Impl' : '${name}ModuleImpl';

    // ── 1. No module import needed — bridge .swift files are compiled into
    //        the same CocoaPods pod target. Remove any stale module import.
    final staleImportPattern = RegExp(
      r'#if canImport\(nitro_' + RegExp.escape(lib) + r'_module\)\s*\nimport nitro_' + RegExp.escape(lib) + r'_module\s*\n#endif\s*\n?',
    );
    if (staleImportPattern.hasMatch(content)) {
      content = content.replaceAll(staleImportPattern, '');
      modified = true;
    }
    final bareImport = RegExp(
      r'import nitro_' + RegExp.escape(lib) + r'_module[ \t]*\r?\n?',
    );
    if (bareImport.hasMatch(content)) {
      content = content.replaceAll(bareImport, '');
      modified = true;
    }

    // ── 2. Ensure register() call is present ────────────────────────────────
    if (!content.contains('$reg.register')) {
      content = content.replaceFirst(
        'public static func register(with registrar: FlutterPluginRegistrar) {',
        'public static func register(with registrar: FlutterPluginRegistrar) {\n    $reg.register($impl())',
      );
      modified = true;
    }
  }
  if (modified) pluginFile.writeAsStringSync(content);
}

/// Removes stale `<Module>Registry.register(...)` calls from *Plugin.swift for
/// modules that have been converted to NativeImpl.cpp (AppleNativeImpl.cpp).
///
/// C++ modules auto-register via `__attribute__((constructor))` when the .dylib
/// loads. No Swift `Registry.register()` call is needed or valid — the Registry
/// class is not generated for CppImpl modules, so the call causes:
///   "Cannot find `<Module>Registry` in scope"
///
/// This mirrors [purgeStaleCppKotlinRegistrations] on the Swift side.
void purgeStaleCppSwiftRegistrations(
  List<ModuleInfo> cppModules, {
  String platform = 'ios',
  String baseDir = '.',
}) {
  if (cppModules.isEmpty) return;
  final platformDir = Directory(p.join(baseDir, platform));
  if (!platformDir.existsSync()) return;
  final pluginFiles = platformDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.swift'))
      .toList();
  if (pluginFiles.isEmpty) return;
  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;

  for (final m in cppModules) {
    // Match lines like:
    //   BenchmarkCppRegistry.register(BenchmarkCppModuleImpl())
    //   BenchmarkCppRegistry.register(BenchmarkCppImpl())
    // with optional leading whitespace.
    final stalePattern = RegExp(
      r'[ \t]*' + RegExp.escape('${m.module}Registry') + r'\.register\(.*\)[ \t]*\r?\n?',
    );
    if (stalePattern.hasMatch(content)) {
      content = content.replaceAll(stalePattern, '');
      modified = true;
    }
  }

  if (modified) pluginFile.writeAsStringSync(content);
}

void cleanRedundantIncludes(File file) {
  if (!file.existsSync()) return;
  var content = file.readAsStringSync();
  final regex = RegExp(
    '#include\\s+["\'].*?\\.bridge\\.g\\.(cpp|c|mm)["\']',
    multiLine: true,
  );
  if (regex.hasMatch(content)) {
    content = content.replaceAll(regex, '');
    file.writeAsStringSync(content);
  }
}

void linkSwiftPlugin(
  String pluginName,
  List<Map<String, String>> modules, {
  String baseDir = '.',
}) {
  final iosDir = Directory(p.join(baseDir, 'ios'));
  if (!iosDir.existsSync()) return;
  final pluginFiles = iosDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.swift'))
      .toList();

  if (pluginFiles.isEmpty) {
    // Create default iOS plugin stub if missing (mirrors macOS behaviour).
    final className = _toPascalCase(pluginName);
    final fileName = '${className}Plugin.swift';
    final targetPath = p.join(iosDir.path, 'Classes', fileName);
    Directory(p.dirname(targetPath)).createSync(recursive: true);
    final stub = st.iosPluginSwiftStub(className);
    File(targetPath).writeAsStringSync(stub);
    pluginFiles.add(File(targetPath));
  }
  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;
  for (final m in modules) {
    final name = m['module']!;
    final lib = (m['lib'] ?? name.toLowerCase()).replaceAll('-', '_');
    final reg = '${name}Registry';
    final impl = name.endsWith('Module') ? '${name}Impl' : '${name}ModuleImpl';

    // ── 1. No module import needed — bridge .swift files are compiled into
    //        the same CocoaPods pod target. Remove any stale module import.
    final staleImportPattern = RegExp(
      r'#if canImport\(nitro_' + RegExp.escape(lib) + r'_module\)\s*\nimport nitro_' + RegExp.escape(lib) + r'_module\s*\n#endif\s*\n?',
    );
    if (staleImportPattern.hasMatch(content)) {
      content = content.replaceAll(staleImportPattern, '');
      modified = true;
    }
    final bareImport = RegExp(
      r'import nitro_' + RegExp.escape(lib) + r'_module[ \t]*\r?\n?',
    );
    if (bareImport.hasMatch(content)) {
      content = content.replaceAll(bareImport, '');
      modified = true;
    }

    // ── 2. Ensure register() call is present ────────────────────────────────
    if (!content.contains('$reg.register')) {
      final match = RegExp(
        r'\w+Registry\.register\(.*?\)\)',
      ).allMatches(content);
      if (match.isNotEmpty) {
        content = content.replaceFirst(
          match.last.group(0)!,
          '${match.last.group(0)!}\n        $reg.register($impl())',
        );
        modified = true;
      } else {
        content = content.replaceFirst(
          'public static func register(with registrar: FlutterPluginRegistrar) {',
          'public static func register(with registrar: FlutterPluginRegistrar) {\n        $reg.register($impl())',
        );
        modified = true;
      }
    }
  }
  if (modified) pluginFile.writeAsStringSync(content);
}

void ensureIosPackageSwift(
  String pluginName, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  // Check nested layout first (Flutter 3.41+: ios/<pluginName>/Package.swift),
  // then fall back to flat layout (ios/Package.swift).
  final spmStatus = spm.detectSpmStatus(baseDir);
  if (spmStatus.iosHasSpm) {
    // Package.swift already exists — patch missing FlutterFramework dep (old plugins)
    // then sync C/C++ module sources into Sources/<MainCpp>/.
    if (spmStatus.iosPackageSwiftPath != null) {
      spm.ensureFlutterFrameworkDependency(spmStatus.iosPackageSwiftPath!);
    }
    _syncCppModuleSourcesToSpm(
      pluginName,
      moduleInfos: moduleInfos,
      baseDir: baseDir,
    );
    return;
  }

  final className = pluginName.split('_').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');

  // Create nested Flutter 3.41+ layout: ios/<pluginName>/Sources/
  final packageRoot = p.join(baseDir, 'ios', pluginName);
  Directory(p.join(packageRoot, 'Sources', className)).createSync(recursive: true);
  Directory(p.join(packageRoot, 'Sources', '${className}Cpp')).createSync(recursive: true);

  final packageSwift = File(p.join(packageRoot, 'Package.swift'));
  packageSwift.writeAsStringSync(
    st.iosPackageSwiftContent(pluginName, className),
  );
  _syncCppModuleSourcesToSpm(
    pluginName,
    moduleInfos: moduleInfos,
    baseDir: baseDir,
  );
}

/// Mirrors [ensureIosPackageSwift] for `macos/`. Creates the Flutter 3.41+
/// nested SPM layout (`macos/<pluginName>/Package.swift`) if not present,
/// then syncs C/C++ module sources into SPM Sources directories.
void ensureMacosPackageSwift(
  String pluginName, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  final spmStatus = spm.detectSpmStatus(baseDir);
  if (spmStatus.macosHasSpm) {
    // Patch missing FlutterFramework dep (old plugins) then sync sources.
    if (spmStatus.macosPackageSwiftPath != null) {
      spm.ensureFlutterFrameworkDependency(spmStatus.macosPackageSwiftPath!);
    }
    _syncCppModuleSourcesToSpm(pluginName, moduleInfos: moduleInfos, baseDir: baseDir);
    return;
  }

  final className = pluginName.split('_').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');

  final packageRoot = p.join(baseDir, 'macos', pluginName);
  Directory(p.join(packageRoot, 'Sources', className)).createSync(recursive: true);
  Directory(p.join(packageRoot, 'Sources', '${className}Cpp')).createSync(recursive: true);

  File(p.join(packageRoot, 'Package.swift')).writeAsStringSync(
    st.macosPackageSwiftContent(pluginName, className),
  );
  _syncCppModuleSourcesToSpm(pluginName, moduleInfos: moduleInfos, baseDir: baseDir);
}

/// Writes forwarder files for C++ module bridges and impl into the SPM target
/// that owns the shared C++ layer (Sources/`<MainCpp>`/). Bridge headers are also
/// copied into its include/ directory so SPM can find them.
///
/// Handles both flat (`ios/Sources/`) and Flutter 3.41+ nested
/// (`ios/<pluginName>/Sources/`) SPM layouts automatically.
///
/// Only modules using `AppleNativeImpl.cpp` (or legacy `NativeImpl.cpp`) on
/// ios or macos are synced here. Windows-only C++ modules must NOT appear in
/// `ios/Sources/` — Xcode would reference the forwarder file and then fail with
/// "Build input file cannot be found" when the abstract class has no iOS impl.
void _syncCppModuleSourcesToSpm(
  String pluginName, {
  List<ModuleInfo>? moduleInfos,
  String baseDir = '.',
}) {
  final className = pluginName.split('_').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');

  final spmStatus = spm.detectSpmStatus(baseDir);

  for (final platform in ['ios', 'macos']) {
    final packageSwiftPath = platform == 'ios' ? spmStatus.iosPackageSwiftPath : spmStatus.macosPackageSwiftPath;

    // Determine package root (sibling of Package.swift).
    final packageRoot = packageSwiftPath != null ? File(packageSwiftPath).parent.path : null;

    // Nested layout: ios/<pluginName>/Sources/<className>Cpp
    // Flat layout:   ios/Sources/<className>Cpp
    final cppTargetDir = packageRoot != null ? Directory(p.join(packageRoot, 'Sources', '${className}Cpp')) : Directory(p.join(baseDir, platform, 'Sources', '${className}Cpp'));

    // All modules that *have* isCpp true (broad), so we can clean up stale
    // forwarders for any that are no longer Apple C++.
    final allCppModules = moduleInfos?.where((m) => m.isCpp).toList() ?? [];

    // Determine whether there is any C/C++ content that needs to be compiled
    // in this SPM C++ target. If there is none (pure Swift plugin with no C++
    // modules and no main plugin .cpp/.c file) we skip writing any source
    // files so the target directory stays empty — matching the no-op contract.
    final mainCppFile = File(p.join(baseDir, 'src', '$pluginName.cpp'));
    final mainCFile = File(p.join(baseDir, 'src', '$pluginName.c'));
    final hasCContent = mainCppFile.existsSync() || mainCFile.existsSync() || allCppModules.isNotEmpty;

    if (!hasCContent) {
      // No C/C++ content — still sync Swift plugin files so SPM can compile them.
      _syncSwiftPluginToSpm(
        pluginName,
        baseDir: baseDir,
        platform: platform,
        packageRoot: packageRoot,
        className: className,
      );
      continue;
    }

    // Create the SPM C++ target directory if it doesn't exist yet. This handles
    // the case where Package.swift already exists (spmHasSpm=true) but the
    // Sources/<PluginCpp>/ directory was never created — e.g. first run of
    // `nitrogen link` on a plugin whose Package.swift was set up manually, or
    // where a previous partial run left the directory missing. Without this,
    // the symbol `<plugin>_init_dart_api_dl` would be missing at runtime under SPM.
    if (!cppTargetDir.existsSync()) {
      cppTargetDir.createSync(recursive: true);
    }

    final includeDir = _spmScaffoldSharedCppTarget(
      cppTargetDir,
      baseDir,
      pluginName,
      mainCppFile,
      mainCFile,
    );

    // 2a. Per-module SPM C++ targets (issue #15) — see
    //     _spmSyncPerModuleCppTargets.
    if (moduleInfos != null) {
      _spmSyncPerModuleCppTargets(
        pluginName,
        className,
        platform,
        baseDir,
        moduleInfos,
        packageSwiftPath,
        packageRoot,
        cppTargetDir,
        includeDir,
      );
    }

    // Skip module-specific C++ bridge linking when no C++ modules exist.
    if (allCppModules.isEmpty) continue;

    _spmSyncMainModuleCppForwarders(
      pluginName,
      platform,
      baseDir,
      cppTargetDir,
      includeDir,
      allCppModules,
    );

    // ── Sync Swift plugin registration and impl to SPM target ────────────────
    // SPM can't see files in ios/Classes/ — copy them to Sources/<className>/
    // so the Swift target can compile them.
    _syncSwiftPluginToSpm(
      pluginName,
      baseDir: baseDir,
      platform: platform,
      packageRoot: packageRoot,
      className: className,
    );
  }
}

/// Scaffolds the shared plugin-level SPM C++ target (`Sources/<Class>Cpp/`):
/// copies the nitro API headers into `include/`, writes the portable
/// `dart_api_dl.c`, and emits the main plugin stub + bridge `.mm` forwarders.
/// Returns the created `include/` directory so callers can populate it with
/// the per-module and main-module bridge headers.
Directory _spmScaffoldSharedCppTarget(
  Directory cppTargetDir,
  String baseDir,
  String pluginName,
  File mainCppFile,
  File mainCFile,
) {
  final nitroNativePath = resolveNitroNativePath(baseDir);
  final includeDir = Directory(p.join(cppTargetDir.path, 'include'))..createSync(recursive: true);

  // Copy nitro API headers and dart_api_dl.c into the SPM C++ target.
  // Always write the canonical nitroHContent (with NITRO_ERROR_DEFINED guard)
  // directly rather than copying from the installed nitro package, which may
  // lack the guard. Using different copies with inconsistent guards causes a
  // "Typedef redefinition" error when both are included in the same TU.
  File(p.join(includeDir.path, 'nitro.h')).writeAsStringSync(nitroHContent);
  for (final headerName in ['dart_api_dl.h', 'dart_api.h', 'dart_native_api.h', 'dart_version.h', 'nitro_wasm_compat.h']) {
    final src = File(p.join(nitroNativePath, headerName));
    if (src.existsSync()) src.copySync(p.join(includeDir.path, headerName));
  }
  final internalSrc = Directory(p.join(nitroNativePath, 'internal'));
  if (internalSrc.existsSync()) {
    final internalDst = Directory(p.join(includeDir.path, 'internal'))..createSync(recursive: true);
    for (final f in internalSrc.listSync().whereType<File>()) {
      f.copySync(p.join(internalDst.path, p.basename(f.path)));
    }
  }

  // dart_api_dl.c — write a portable self-contained stub that includes only
  // the local header copies in include/. The old forwarder embedded an
  // absolute machine-specific path which broke on other machines / CI.
  File(p.join(cppTargetDir.path, 'dart_api_dl.c')).writeAsStringSync(bundledDartApiDlContent);

  // 1. Link the main plugin stub file.
  if (mainCppFile.existsSync()) {
    final relMainCpp = p.relative(mainCppFile.path, from: cppTargetDir.path).replaceAll(r'\', '/');
    File(p.join(cppTargetDir.path, '$pluginName.cpp')).writeAsStringSync(
      managedCppForwarder(relMainCpp),
    );
  } else if (mainCFile.existsSync()) {
    final relMainC = p.relative(mainCFile.path, from: cppTargetDir.path).replaceAll(r'\', '/');
    File(p.join(cppTargetDir.path, '$pluginName.c')).writeAsStringSync(
      managedCppForwarder(relMainC),
    );
  }

  // 2. Main plugin bridge — compiled as .mm so SPM treats it as Obj-C++ and
  //    links the C bridge symbols (<plugin>_init_dart_api_dl, etc.)
  //    that are defined in the generated .bridge.g.cpp.
  //    Without this file the symbol is missing at runtime under SPM and the
  //    app crashes with: Failed to lookup symbol '<plugin>_init_dart_api_dl'.
  //    Foundation must be imported before the .cpp because the bridge uses
  //    #ifdef __OBJC__ blocks with NSException / @try-@catch.
  //
  //    IMPORTANT: we write this unconditionally — NOT guarded by existsSync().
  //    If nitrogen link is run before nitrogen generate (common first-run
  //    workflow) the bridge.g.cpp does not exist yet, but the .mm forwarder
  //    must still be created so it is present when the app is compiled after
  //    generate has been run. The relative #include is resolved at compile
  //    time, not at nitrogen link time.
  {
    final mainBridgeCppPath = p.join(
      baseDir,
      'lib',
      'src',
      'generated',
      'cpp',
      '$pluginName.bridge.g.cpp',
    );
    final relBridge = p.relative(mainBridgeCppPath, from: cppTargetDir.path).replaceAll(r'\', '/');
    File(p.join(cppTargetDir.path, '$pluginName.bridge.g.mm')).writeAsStringSync(
      managedBridgeMmForwarder(relBridge),
    );
  }
  return includeDir;
}

/// True when the `<moduleClass>Cpp` target block in [packageSwiftContent]
/// declares a dependency on the plugin-level `<className>Cpp` target (so the
/// dart DL headers resolve through that dependency). Hand-authored targets
/// that instead carry their own dart header copies return false.
bool _spmModuleDependsOnPluginCpp(
  String packageSwiftContent,
  String moduleClass,
  String className,
) {
  final idx = packageSwiftContent.indexOf('name: "${moduleClass}Cpp"');
  if (idx == -1) return false;
  var end = packageSwiftContent.indexOf('name: "', idx + 1);
  if (end == -1) end = packageSwiftContent.length;
  return packageSwiftContent.substring(idx, end).contains('"${className}Cpp"');
}

/// Emits and repairs the per-module SPM C++ targets (`Sources/<Module>Cpp/`)
/// for every non-main module (issue #15): declares the module targets in
/// Package.swift, then syncs each module's forwarders via
/// [_spmSyncOneModuleCppTarget].
void _spmSyncPerModuleCppTargets(
  String pluginName,
  String className,
  String platform,
  String baseDir,
  List<ModuleInfo> moduleInfos,
  String? packageSwiftPath,
  String? packageRoot,
  Directory cppTargetDir,
  Directory includeDir,
) {
  final sourcesRoot = packageRoot != null ? p.join(packageRoot, 'Sources') : p.join(baseDir, platform, 'Sources');
  final specLibDir = Directory(p.join(baseDir, 'lib'));
  final moduleSpecFiles = specLibDir.existsSync() ? specLibDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
  final modulePlatformFilter = platform == 'ios' ? isIosCppModule : isMacosCppModule;
  String libOf(File f) {
    final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
    return extractLibNameFromSpec(f) ?? stem;
  }

  final modulePlatformCppLibs = moduleSpecFiles.where(modulePlatformFilter).map(libOf).toSet();
  final moduleKnownLibs = moduleSpecFiles.map(libOf).toSet();

  final nonMainModules = moduleInfos.where((m) => m.lib != pluginName).toList();

  // Declare the module targets in Package.swift FIRST (idempotent;
  // skipped with a paste-block warning when the manifest is
  // hand-authored) — the per-module repair below reads the resulting
  // manifest to decide what is safe to remove.
  if (packageSwiftPath != null && nonMainModules.isNotEmpty) {
    spm.ensureModuleCppTargets(
      packageSwiftPath,
      pluginName: pluginName,
      pluginClass: className,
      moduleClasses: nonMainModules.map((m) => m.module).toList(),
    );
  }
  final packageSwiftContent = packageSwiftPath != null && File(packageSwiftPath).existsSync() ? File(packageSwiftPath).readAsStringSync() : '';
  for (final m in nonMainModules) {
    _spmSyncOneModuleCppTarget(
      m,
      sourcesRoot: sourcesRoot,
      cppTargetDir: cppTargetDir,
      includeDir: includeDir,
      baseDir: baseDir,
      className: className,
      packageSwiftContent: packageSwiftContent,
      moduleKnownLibs: moduleKnownLibs,
      modulePlatformCppLibs: modulePlatformCppLibs,
    );
  }

  // (ensureModuleCppTargets already ran before the loop — the repair
  // logic above depends on the resulting manifest.)
}

/// Emits/repairs one module's `Sources/<Module>Cpp/` target: bridge `.mm`
/// forwarder, exports header, issue-#21 header-layout repairs, and (for
/// Apple-C++ modules) the impl forwarder + bridge header. Also removes the
/// module's stale sources from the plugin-level target (issue #15 dedupe).
void _spmSyncOneModuleCppTarget(
  ModuleInfo m, {
  required String sourcesRoot,
  required Directory cppTargetDir,
  required Directory includeDir,
  required String baseDir,
  required String className,
  required String packageSwiftContent,
  required Set<String> moduleKnownLibs,
  required Set<String> modulePlatformCppLibs,
}) {
  final moduleTargetDir = Directory(p.join(sourcesRoot, '${m.module}Cpp'))..createSync(recursive: true);
  final moduleIncludeDir = Directory(p.join(moduleTargetDir.path, 'include'))..createSync(recursive: true);

  // Bridge forwarder — .mm so SPM compiles the C bridge as Obj-C++.
  final bridgeCppPath = p.join(baseDir, 'lib', 'src', 'generated', 'cpp', '${m.lib}.bridge.g.cpp');
  final relBridge = p.relative(bridgeCppPath, from: moduleTargetDir.path).replaceAll(r'\', '/');
  File(p.join(moduleTargetDir.path, '${m.lib}.bridge.g.mm')).writeAsStringSync(
    managedBridgeMmForwarder(relBridge),
  );

  // Exports header: makes `import <ModuleClass>Cpp` expose the Dart DL
  // API (Dart_CObject etc.) in Swift, re-exported from the plugin-level
  // Cpp target (a target dependency — the dart headers are deliberately
  // NEVER copied here: two copies of dart_api_dl.h inside one package
  // cause a clang "ambiguous module" error).
  //
  // The file must NOT be named `<TargetName>.h` — SwiftPM promotes a
  // public header with exactly the target's name to THE umbrella
  // header, and that layout forbids sibling directories inside the
  // public headers dir (e.g. a hand-added include/internal/), failing
  // package resolution with "invalid header layout" (issue #21). Any
  // other name falls back to SPM's permissive umbrella-DIRECTORY module
  // map, where subdirectories are fine.
  File(p.join(moduleIncludeDir.path, '${m.module}CppExports.h')).writeAsStringSync(
    '// Generated by nitrogen — public exports for the ${m.module}Cpp SPM target.\n'
    '// Re-exports the Dart DL API from the ${className}Cpp dependency.\n'
    '// Deliberately NOT named ${m.module}Cpp.h: SwiftPM would treat that as the\n'
    '// umbrella header and reject any subdirectory next to it (issue #21).\n'
    '#include "dart_api_dl.h"\n',
  );

  // REPAIR (issue #21), part 1 — unconditional: the 0.5.13
  // target-named umbrella header makes SPM reject the whole package
  // ("invalid header layout") whenever include/ has a subdirectory.
  final staleUmbrella = File(p.join(moduleIncludeDir.path, '${m.module}Cpp.h'));
  if (staleUmbrella.existsSync()) staleUmbrella.deleteSync();

  // REPAIR (issue #21), part 2 — gated: dart DL header copies (and
  // their internal/ directory) duplicate the plugin target's modular
  // headers and cause clang module ambiguity — but they are only safe
  // to remove when this module target actually resolves the headers
  // through its ${className}Cpp dependency. A hand-authored target
  // without that dependency (nitro_webgpu's pre-0.5.13 layout) NEEDS
  // its own copies — leave them alone.
  if (_spmModuleDependsOnPluginCpp(packageSwiftContent, m.module, className)) {
    for (final stale in [
      File(p.join(moduleIncludeDir.path, 'dart_api_dl.h')),
      File(p.join(moduleIncludeDir.path, 'dart_api.h')),
      File(p.join(moduleIncludeDir.path, 'dart_native_api.h')),
      File(p.join(moduleIncludeDir.path, 'dart_version.h')),
      File(p.join(moduleIncludeDir.path, 'nitro.h')),
    ]) {
      if (stale.existsSync()) stale.deleteSync();
    }
    final staleInternal = Directory(p.join(moduleIncludeDir.path, 'internal'));
    if (staleInternal.existsSync()) staleInternal.deleteSync(recursive: true);
  }

  // Apple-C++ modules also carry their impl forwarder + bridge header.
  final hybridClass = _toPascalCase(m.lib);
  final implForwarder = File(p.join(moduleTargetDir.path, 'Hybrid$hybridClass.cpp'));
  final isAppleCppHere = m.isCpp && (!moduleKnownLibs.contains(m.lib) || modulePlatformCppLibs.contains(m.lib));
  if (isAppleCppHere) {
    final implSrc = File(p.join(baseDir, 'src', 'Hybrid$hybridClass.cpp'));
    if (implSrc.existsSync()) {
      final relPath = p.relative(implSrc.path, from: moduleTargetDir.path).replaceAll(r'\', '/');
      implForwarder.writeAsStringSync(managedCppForwarder(relPath));
    }
    final hSrc = File(p.join(baseDir, 'lib', 'src', 'generated', 'cpp', '${m.lib}.bridge.g.h'));
    if (hSrc.existsSync()) hSrc.copySync(p.join(moduleIncludeDir.path, '${m.lib}.bridge.g.h'));
  } else {
    if (implForwarder.existsSync()) implForwarder.deleteSync();
  }

  // REPAIR: this module's sources used to be synced into the
  // plugin-level target — remove them there so both targets never
  // compile the same bridge (duplicate ${m.lib}_* symbols at link).
  for (final stale in [
    File(p.join(cppTargetDir.path, '${m.lib}.bridge.g.mm')),
    File(p.join(cppTargetDir.path, 'Hybrid$hybridClass.cpp')),
    File(p.join(includeDir.path, '${m.lib}.bridge.g.h')),
  ]) {
    if (stale.existsSync()) stale.deleteSync();
  }
}

/// Links the MAIN module's C++ bridge + impl forwarders into the plugin-level
/// SPM target. Every non-main module was routed to its own `<Module>Cpp`
/// target in [_spmSyncPerModuleCppTargets]; only `lib == pluginName` remains.
void _spmSyncMainModuleCppForwarders(
  String pluginName,
  String platform,
  String baseDir,
  Directory cppTargetDir,
  Directory includeDir,
  List<ModuleInfo> allCppModules,
) {
  // Discover which modules use NativeImpl.cpp specifically on THIS platform.
  // A mixed module (ios:swift, macos:cpp) must only get HybridXxx.cpp on macOS.
  final libDir = Directory(p.join(baseDir, 'lib'));
  final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
  final platformCppFilter = platform == 'ios' ? isIosCppModule : isMacosCppModule;
  final platformCppLibs = specFiles.where(platformCppFilter).map((f) {
    final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
    return extractLibNameFromSpec(f) ?? stem;
  }).toSet();
  // All lib names that have any spec file (used to detect "spec exists but not Apple").
  final knownLibs = specFiles.map((f) {
    final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
    return extractLibNameFromSpec(f) ?? stem;
  }).toSet();

  // Only the MAIN module's C++ sources still live in the plugin-level
  // target — every other module was routed to its own <ModuleClass>Cpp
  // target in section 2a above (issue #15).
  for (final m in allCppModules.where((m) => m.lib == pluginName)) {
    final lib = m.lib;
    final hybridClass = _toPascalCase(lib);
    // Safe default: if no spec file was found for this lib, assume Apple (keep forwarder).
    // Only remove the forwarder when a spec explicitly confirms it is NOT Apple C++.
    final isApple = !knownLibs.contains(lib) || platformCppLibs.contains(lib);

    final bridgeMm = File(p.join(cppTargetDir.path, '$lib.bridge.g.mm'));
    final implForwarder = File(
      p.join(cppTargetDir.path, 'Hybrid$hybridClass.cpp'),
    );

    if (isApple) {
      // ── Write / update forwarders for Apple C++ modules ──────────────────

      // Forwarder: bridge .cpp → .mm so SPM compiles it as Obj-C++.
      // Written unconditionally (NOT guarded by existsSync) using a relative
      // path so it is portable across machines and works even when
      // `nitrogen link` is run before `nitrogen generate`.
      // Skip when lib == pluginName — the main plugin bridge at line 2052
      // already covers that file unconditionally; writing it again here would
      // duplicate work but is harmless. We skip to keep intent clear.
      if (lib != pluginName) {
        final bridgeCppPath = p.join(
          baseDir,
          'lib',
          'src',
          'generated',
          'cpp',
          '$lib.bridge.g.cpp',
        );
        final relBridge = p.relative(bridgeCppPath, from: cppTargetDir.path).replaceAll(r'\', '/');
        bridgeMm.writeAsStringSync(managedBridgeMmForwarder(relBridge));
      }

      // Forwarder: C++ impl — use a relative #include so the path is
      // portable across machines (absolute pub-cache paths break on CI).
      final implSrc = File(p.join(baseDir, 'src', 'Hybrid$hybridClass.cpp'));
      if (implSrc.existsSync()) {
        final relPath = p.relative(implSrc.path, from: cppTargetDir.path).replaceAll(r'\', '/');
        implForwarder.writeAsStringSync(managedCppForwarder(relPath));
      }

      // Copy only the C-compatible bridge header into include/. The .native.g.h
      // uses C++ types (std::string, classes) and must NOT be a public module
      // header — CocoaPods would include it in the umbrella and break Swift/ObjC
      // module compilation. It is reachable via HEADER_SEARCH_PATHS instead.
      final bridgeHeader = '$lib.bridge.g.h';
      final hSrc = File(
        p.join(baseDir, 'lib', 'src', 'generated', 'cpp', bridgeHeader),
      );
      if (hSrc.existsSync()) {
        hSrc.copySync(p.join(includeDir.path, bridgeHeader));
      }
    } else {
      // ── Remove stale impl forwarder for non-Apple-C++ modules ─────────────
      // e.g. a module with `windows: WindowsNativeImpl.cpp, ios: NativeImpl.swift`
      // should NOT get a HybridXxx.cpp forwarder on Apple — only the bridge mm.
      // NEVER delete the bridge.g.mm: every module's bridge.g.cpp defines
      // ${lib}_init_dart_api_dl, which must be compiled into the SPM binary
      // even for Swift-backed modules. Deleting it causes a symbol-not-found
      // crash at runtime on any second/third spec in a multi-spec plugin.
      if (implForwarder.existsSync()) implForwarder.deleteSync();
    }
  }
}

/// Copies Swift plugin registration and impl files from the target platform's
/// Classes/ directory to the SPM Sources/ directory. This is required because
/// SPM packages are isolated — they cannot access files outside their source path.
/// Without these copies, the Flutter plugin registrant cannot find the Swift
/// plugin class.
void _syncSwiftPluginToSpm(
  String pluginName, {
  required String baseDir,
  required String platform,
  String? packageRoot,
  required String className,
}) {
  // Determine the SPM Swift source directory.
  final swiftTargetDir = packageRoot != null ? Directory(p.join(packageRoot, 'Sources', className)) : Directory(p.join(baseDir, platform, 'Sources', className));

  // Determine the source Classes directory.
  final classesDir = Directory(p.join(baseDir, platform, 'Classes'));
  if (!classesDir.existsSync()) return;

  // Skip if the SPM Swift target directory doesn't exist — no SPM layout for this platform.
  if (!swiftTargetDir.existsSync()) return;

  // Find Swift files in Classes: *Plugin.swift and *Impl.swift
  final swiftFiles = classesDir.listSync(followLinks: false).whereType<File>().where((f) => f.path.endsWith('.swift')).toList();

  for (final srcFile in swiftFiles) {
    final dstFile = File(p.join(swiftTargetDir.path, p.basename(srcFile.path)));
    if (!dstFile.existsSync()) {
      srcFile.copySync(dstFile.path);
    }
  }
}

/// Applies the shared `pod_target_xcconfig` patches to an Apple podspec
/// [content]: HEADER_SEARCH_PATHS (inserted when absent — the macOS symlink
/// path when [isMacos], else the iOS one — otherwise extended with the src/ +
/// generated/cpp/ paths), DEFINES_MODULE, CLANG_CXX_LANGUAGE_STANDARD, and the
/// `nitro` dependency. Returns the patched content and whether it changed.
/// Shared by [linkPodspec] and [linkMacosPodspec].
({String content, bool modified}) _patchApplePodspecXcconfig(
  String content, {
  required bool isMacos,
}) {
  var modified = false;
  if (!content.contains('HEADER_SEARCH_PATHS')) {
    content = content.replaceFirst(
      's.pod_target_xcconfig = {',
      isMacos
          ? "s.pod_target_xcconfig = {\n    'HEADER_SEARCH_PATHS' => '\$(inherited) \"\${PODS_ROOT}/../Flutter/ephemeral/.symlinks/plugins/nitro/src/native\" \"\${PODS_TARGET_SRCROOT}/../src\" \"\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp\"',"
          : "s.pod_target_xcconfig = {\n    'HEADER_SEARCH_PATHS' => '\$(inherited) \"\${PODS_ROOT}/../.symlinks/plugins/nitro/src/native\" \"\${PODS_TARGET_SRCROOT}/../src\" \"\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp\"',",
    );
    modified = true;
  } else {
    // If it exists, ensure it has the src/ and generated/cpp/ paths.
    if (!content.contains('PODS_TARGET_SRCROOT}/../src') || !content.contains('lib/src/generated/cpp')) {
      final match = RegExp(
        r"'HEADER_SEARCH_PATHS'\s*=>\s*'([^']+)'",
      ).firstMatch(content);
      if (match != null) {
        var paths = match.group(1)!;
        if (!paths.contains('PODS_TARGET_SRCROOT}/../src')) {
          paths += ' "\${PODS_TARGET_SRCROOT}/../src"';
        }
        if (!paths.contains('lib/src/generated/cpp')) {
          paths += ' "\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp"';
        }
        content = content.replaceFirst(
          match.group(0)!,
          "'HEADER_SEARCH_PATHS' => '$paths'",
        );
        modified = true;
      }
    }
  }
  if (!content.contains("'DEFINES_MODULE' => 'YES'")) {
    content = content.replaceFirst(
      's.pod_target_xcconfig = {',
      "s.pod_target_xcconfig = {\n    'DEFINES_MODULE' => 'YES',",
    );
    modified = true;
  }
  if (!content.contains("'CLANG_CXX_LANGUAGE_STANDARD'") && !content.contains(BuildVersions.podCxxStandard)) {
    content = content.replaceFirst(
      's.pod_target_xcconfig = {',
      "s.pod_target_xcconfig = {\n    'CLANG_CXX_LANGUAGE_STANDARD' => '${BuildVersions.podCxxStandard}',",
    );
    modified = true;
  }
  if (!content.contains("s.dependency 'nitro'")) {
    content = content.replaceFirst(
      's.pod_target_xcconfig = {',
      "s.dependency 'nitro'\n  s.pod_target_xcconfig = {",
    );
    modified = true;
  }
  return (content: content, modified: modified);
}

/// Writes/removes the per-module `HybridXxx.cpp` forwarders in an Apple
/// `Classes/` dir: Apple-C++ modules (matched by [platformFilter]) get an
/// up-to-date forwarder; non-Apple-C++ modules (e.g. Windows-only) have any
/// stale forwarder removed. Shared by [linkPodspec] and [linkMacosPodspec].
void _writeAppleModuleForwarders(
  List<ModuleInfo>? moduleInfos,
  Directory classesDir,
  String baseDir,
  bool Function(File) platformFilter,
) {
  if (moduleInfos != null) {
    // Discover specs for iOS-cpp filtering (per-platform, not broad Apple check).
    final libDir = Directory(p.join(baseDir, 'lib'));
    final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
    final appleCppLibs = specFiles.where(platformFilter).map((f) {
      final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      return extractLibNameFromSpec(f) ?? stem;
    }).toSet();

    // Write forwarders only for Apple cpp modules.
    for (final m in moduleInfos.where((m) => m.isCpp)) {
      final className = _toPascalCase(m.lib);
      final forwarderFile = File(
        p.join(classesDir.path, 'Hybrid$className.cpp'),
      );
      if (appleCppLibs.contains(m.lib)) {
        // Apple C++ module — ensure forwarder is present/up-to-date.
        final implSrc = File(p.join(baseDir, 'src', 'Hybrid$className.cpp'));
        if (implSrc.existsSync()) {
          forwarderFile.writeAsStringSync(
            managedCppForwarder('../../src/Hybrid$className.cpp'),
          );
        }
      } else {
        // Non-Apple C++ module (e.g. Windows-only) — remove any stale forwarder.
        if (forwarderFile.existsSync()) forwarderFile.deleteSync();
      }
    }
  }
}
