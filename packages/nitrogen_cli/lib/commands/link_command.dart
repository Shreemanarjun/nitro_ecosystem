import 'dart:convert';
import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import '../ui.dart';
import '../utils.dart';
import '../templates/native_headers.dart';
import '../templates/cpp_stubs.dart' as t;
import '../templates/forwarder_templates.dart';
import '../templates/swift_templates.dart' as st;
import '../templates/cmake_templates.dart' as ct;
import '../templates/scaffold_templates.dart' as sft;
import '../templates/build_versions.dart';
import 'spm_utils.dart' as spm;

part 'link/discovery.dart';
part 'link/cmake.dart';
part 'link/apple.dart';
part 'link/android.dart';
part 'link/desktop.dart';

// ── Package-level helpers (also used in tests) ─────────────────────────────

/// Parses the `@NitroModule(...)` annotation from a spec file **once** and
/// exposes typed query methods for each platform target.
///
/// Replaces five independent regex passes with a single parse so callers that
/// need multiple platform attributes (e.g. [discoverModuleInfos]) avoid
/// re-reading and re-matching the annotation for every query.
///
/// ```dart
/// final analyzer = PlatformTargetAnalyzer.fromSpec(specFile);
/// if (analyzer.requiresCpp) { /* at least one platform is C++ */ }
/// if (analyzer.supportsApple) { /* ios or macos is C++ */ }
/// ```
class PlatformTargetAnalyzer {
  final String _annotation;

  PlatformTargetAnalyzer._(this._annotation);

  /// Parses the annotation from [specFile] (one file read, one regex match).
  factory PlatformTargetAnalyzer.fromSpec(File specFile) {
    return PlatformTargetAnalyzer.fromContent(specFile.readAsStringSync());
  }

  /// Parses the annotation from already-loaded [content] (zero file reads).
  ///
  /// Uses balanced-paren scanning (not a `[^)]+` regex) to find the matching
  /// close paren — a plain `[^)]+` stops at the FIRST `)` regardless of
  /// nesting, silently truncating the captured annotation (and every
  /// getter's regex along with it) the moment any `)` appears before the
  /// real end — including inside an ordinary parenthesized comment like
  /// `// (see the docs)` sitting between two annotation params. Found via a
  /// real, self-inflicted repro: adding exactly such a comment to
  /// nitro_type_coverage's @NitroModule made every getter on this class
  /// silently return false.
  factory PlatformTargetAnalyzer.fromContent(String content) {
    final startMatch = RegExp(r'@NitroModule\s*\(').firstMatch(content);
    if (startMatch == null) return PlatformTargetAnalyzer._('');
    final body = _scanBalancedParens(content, startMatch.end);
    return PlatformTargetAnalyzer._(body.replaceAll('\n', ' '));
  }

  /// Returns the text between [openParenIndex] (the index right after the
  /// opening `(` that started this scan — i.e. depth is already 1 there) and
  /// its matching close paren, tracking nesting depth so an inner balanced
  /// `(...)` — e.g. inside a comment — doesn't end the scan early. Returns
  /// everything to the end of [content] if no matching close paren is found
  /// (malformed source — callers get whatever text is available rather than
  /// an empty string, matching the old regex's graceful-degradation shape).
  static String _scanBalancedParens(String content, int openParenIndex) {
    var depth = 1;
    for (var i = openParenIndex; i < content.length; i++) {
      final ch = content.codeUnitAt(i);
      if (ch == 0x28) {
        depth++; // (
      } else if (ch == 0x29) {
        // )
        depth--;
        if (depth == 0) return content.substring(openParenIndex, i);
      }
    }
    return content.substring(openParenIndex);
  }

  /// True when at least one platform uses direct C++ (broad check).
  /// Matches ios, android, macos, windows, and linux C++ declarations.
  bool get requiresCpp => RegExp(
    r'\b(?:ios|android|macos|windows|linux)\s*:\s*'
    r'(?:NativeImpl|AppleNativeImpl|AndroidNativeImpl|WindowsNativeImpl|LinuxNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);

  /// True when iOS or macOS use direct C++ (Apple platforms only).
  bool get supportsApple => RegExp(
    r'\b(?:ios|macos)\s*:\s*(?:NativeImpl|AppleNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);

  /// True when **only iOS** uses direct C++ (not macOS).
  bool get supportsIosCpp => RegExp(
    r'\bios\s*:\s*(?:NativeImpl|AppleNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);

  /// True when **only macOS** uses direct C++ (not iOS).
  bool get supportsMacosCpp => RegExp(
    r'\bmacos\s*:\s*(?:NativeImpl|AppleNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);

  /// True when Android uses direct C++ (bypasses JNI bridge).
  bool get supportsAndroid => RegExp(
    r'\bandroid\s*:\s*(?:NativeImpl|AndroidNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);

  /// True when Windows uses direct C++ (windows/CMakeLists.txt path).
  bool get supportsWindows => RegExp(
    r'\bwindows\s*:\s*(?:NativeImpl|WindowsNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);

  /// True when Linux uses direct C++ — distinct from isNativeCpp, which is
  /// true for android OR linux and can't tell them apart.
  bool get supportsLinux => RegExp(
    r'\blinux\s*:\s*(?:NativeImpl|LinuxNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);

  /// True when the annotation spells Windows's implementation using the
  /// SPECIFIC `WindowsNativeImpl.cpp` marker rather than the generic
  /// `NativeImpl.cpp` shorthand. Both resolve to the identical `CppImpl`
  /// singleton at the type level (see nitro_annotations/lib/src/annotations.dart) —
  /// this distinction only exists in the SOURCE TEXT, which is exactly what
  /// this (link-time, regex-based) analyzer reads.
  ///
  /// Used as an explicit, opt-in request for Windows to get its own
  /// `windows/src/Hybrid<Class>.cpp` instead of sharing `src/Hybrid<Class>.cpp`
  /// with Linux/Android — see hasCustomPlatformImpl for the other (implicit,
  /// file-content-driven) way to reach the same outcome. Writing the
  /// per-platform type name is already nitro_annotations' "recommended"
  /// style for clarity; this makes choosing it also mean "this platform may
  /// diverge," which a plugin author reads for immediately rather than
  /// having to have already written platform-specific code for it to apply.
  bool get requestsSeparateWindowsImpl => RegExp(
    r'\bwindows\s*:\s*WindowsNativeImpl\.cpp\b',
  ).hasMatch(_annotation);

  /// True when the annotation spells Linux's implementation using the
  /// SPECIFIC `LinuxNativeImpl.cpp` marker rather than the generic
  /// `NativeImpl.cpp` shorthand. See [requestsSeparateWindowsImpl] — same
  /// mechanism, independent per platform.
  bool get requestsSeparateLinuxImpl => RegExp(
    r'\blinux\s*:\s*LinuxNativeImpl\.cpp\b',
  ).hasMatch(_annotation);

  /// True when Android or Linux use direct C++ (src/CMakeLists.txt NDK/GCC path).
  bool get isNativeCpp => RegExp(
    r'\b(?:android|linux)\s*:\s*'
    r'(?:NativeImpl|AndroidNativeImpl|LinuxNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);
}

/// Module descriptor.
/// - `isCpp` — at least one platform uses direct C++ (broad; used for
///   System.loadLibrary, Swift-bridge skipping, stub file creation).
/// - `isNativeCpp` — android or linux uses direct C++ (narrow; used for
///   src/CMakeLists.txt HybridXxx.cpp inclusion).
/// - `iosIsCpp` / `macosIsCpp` — per-Apple-platform C++ flags (used for
///   per-platform forwarder decisions and auto-register platform guards).
class ModuleInfo {
  final String lib;
  final String module;
  final bool isCpp;
  final bool isNativeCpp;

  /// True only when `android: NativeImpl.cpp` — distinct from isNativeCpp
  /// which is true for android OR linux. Used to generate the correct
  /// auto-register platform guard: Linux-only C++ must exclude __ANDROID__.
  final bool isAndroidCpp;
  final bool iosIsCpp;
  final bool macosIsCpp;

  /// True when `windows: NativeImpl.cpp` — the shared src/ stub is compiled on
  /// Windows too (windows/CMakeLists.txt delegates to ../src), so the
  /// auto-register guard must include _WIN32.
  final bool windowsIsCpp;

  /// True when `linux: NativeImpl.cpp` — distinct from isNativeCpp (android
  /// OR linux).
  final bool linuxIsCpp;

  /// True when the annotation used `windows: WindowsNativeImpl.cpp` (the
  /// specific marker) rather than `windows: NativeImpl.cpp` (the generic
  /// shorthand) — see PlatformTargetAnalyzer.requestsSeparateWindowsImpl.
  /// An explicit, immediate request for Windows to get its own impl file.
  final bool windowsRequestsSeparateImpl;

  /// Same as [windowsRequestsSeparateImpl], for `linux: LinuxNativeImpl.cpp`.
  final bool linuxRequestsSeparateImpl;
  const ModuleInfo({
    required this.lib,
    required this.module,
    required this.isCpp,
    this.isNativeCpp = false,
    this.isAndroidCpp = false,
    this.iosIsCpp = false,
    this.macosIsCpp = false,
    this.windowsIsCpp = false,
    this.linuxIsCpp = false,
    this.windowsRequestsSeparateImpl = false,
    this.linuxRequestsSeparateImpl = false,
  });

  Map<String, String> toMap() => {'lib': lib, 'module': module};
}

enum LinkStepState { pending, running, done, failed, skipped }

class LinkStep {
  final String label;
  LinkStepState state;
  String? detail;
  LinkStep(this.label) : state = LinkStepState.pending;
}

class LinkStepRow extends StatelessComponent {
  const LinkStepRow(this.step, {super.key});
  final LinkStep step;

  @override
  Component build(BuildContext context) {
    final String icon;
    final Color color;
    switch (step.state) {
      case LinkStepState.pending:
        icon = '○';
        color = Colors.gray;
      case LinkStepState.running:
        icon = '◉';
        color = Colors.cyan;
      case LinkStepState.done:
        icon = '✔';
        color = Colors.green;
      case LinkStepState.failed:
        icon = '✘';
        color = Colors.red;
      case LinkStepState.skipped:
        icon = '–';
        color = Colors.gray;
    }
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                icon,
                style: TextStyle(color: color, fontWeight: FontWeight.bold),
              ),
              const Text(' '),
              Expanded(
                child: Text(
                  step.label,
                  style: TextStyle(
                    color: step.state == LinkStepState.running ? Colors.cyan : null,
                    fontWeight: step.state == LinkStepState.running ? FontWeight.bold : null,
                  ),
                ),
              ),
            ],
          ),
          if (step.detail != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                step.detail!,
                style: const TextStyle(
                  color: Colors.gray,
                  fontWeight: FontWeight.dim,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class LinkResult {
  bool success = false;
}

class LinkView extends StatefulComponent {
  const LinkView({
    required this.pluginName,
    required this.result,
    this.onExit,
    super.key,
  });
  final String pluginName;
  final LinkResult result;
  final VoidCallback? onExit;

  @override
  State<LinkView> createState() => _LinkViewState();
}

class _LinkViewState extends State<LinkView> {
  late final List<LinkStep> _steps = [
    LinkStep('Discovering modules'),
    LinkStep('Updating src/CMakeLists.txt'),
    LinkStep('Updating iOS podspec'),
    LinkStep('Updating macOS podspec'),
    LinkStep('Updating Swift Plugin.swift (Kotlin/Swift modules)'),
    LinkStep('Updating Kotlin Plugin.kt (Kotlin/Swift modules)'),
    LinkStep('Updating android/build.gradle (kotlin.srcDirs)'),
    LinkStep('Updating windows/CMakeLists.txt'),
    LinkStep('Updating linux/CMakeLists.txt'),
    LinkStep('Updating .clangd'),
    LinkStep('Finalizing build system (SPM / CocoaPods)'),
  ];

  bool _finished = false;
  bool _failed = false;
  String? _errorMessage;
  final List<String> _nextSteps = [];

  String _stepsAsText() {
    final buf = StringBuffer();
    buf.writeln('nitrogen link — ${component.pluginName}');
    buf.writeln('');
    for (final step in _steps) {
      final icon = switch (step.state) {
        LinkStepState.done => '✔',
        LinkStepState.skipped => '–',
        LinkStepState.running => '⚙',
        LinkStepState.failed => '✘',
        LinkStepState.pending => '○',
      };
      buf.write('  $icon ${step.label}');
      if (step.detail != null) buf.write('  (${step.detail})');
      buf.writeln();
    }
    buf.writeln();
    if (_errorMessage != null) {
      buf.writeln('ERROR: $_errorMessage');
    } else if (_finished && !_failed) {
      buf.writeln('✨ Linked!');
      for (final s in _nextSteps) {
        buf.writeln('  • $s');
      }
    }
    return buf.toString();
  }

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration.zero, _run);
  }

  Future<void> _setRunning(int i) async {
    setState(() => _steps[i].state = LinkStepState.running);
  }

  Future<void> _setDone(int i, {String? detail}) async {
    setState(() {
      _steps[i].state = LinkStepState.done;
      _steps[i].detail = detail;
    });
  }

  Future<void> _setSkipped(int i, {String? detail}) async {
    setState(() {
      _steps[i].state = LinkStepState.skipped;
      _steps[i].detail = detail;
    });
  }

  Future<void> _run() async {
    final pluginName = component.pluginName;
    try {
      await _setRunning(0);
      final moduleInfos = discoverModuleInfos(
        pluginName,
        baseDir: Directory.current.path,
      );
      final allCpp = moduleInfos.every((m) => m.isCpp);
      final hasCpp = moduleInfos.any((m) => m.isCpp);
      final cppLabel = hasCpp ? ' (${moduleInfos.where((m) => m.isCpp).map((m) => m.module).join(', ')} → C++)' : '';
      await _setDone(
        0,
        detail: '${moduleInfos.length} module(s): ${moduleInfos.map((m) => m.module).join(', ')}$cppLabel',
      );

      await _setRunning(1);
      final nitroNativePath = resolveNitroNativePath(Directory.current.path);
      await _runCmakeStep(pluginName, moduleInfos, nitroNativePath);

      await _runIosStep(pluginName, moduleInfos);
      await _runMacosStep(pluginName, moduleInfos);

      await _runSwiftStep(pluginName, moduleInfos);

      await _runKotlinStep(pluginName, moduleInfos, hasCpp);
      await _runAndroidStep(pluginName, moduleInfos);

      await _runWindowsStep(pluginName, moduleInfos, nitroNativePath);
      await _runLinuxStep(pluginName, moduleInfos, nitroNativePath);
      await _runClangdStep(pluginName, moduleInfos);

      await _runFinalizeBuildStep();
      _appendNextSteps(allCpp, hasCpp);
    } catch (e) {
      setState(() {
        _failed = true;
        _errorMessage = e.toString();
      });
    }
    component.result.success = !_failed;
    setState(() => _finished = true);
  }

  Future<void> _runCmakeStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String nitroNativePath,
  ) async {
    // Create impl stubs first so linkCMake finds them and wires them in on the first run.
    linkCppImplStubs(moduleInfos, baseDir: Directory.current.path);
    linkCMake(
      pluginName,
      moduleInfos.map((m) => m.lib).toList(),
      nitroNativePath,
      baseDir: Directory.current.path,
      moduleInfos: moduleInfos,
    );
    await _setDone(1);
  }

  Future<void> _runIosStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
  ) async {
    await _setRunning(2);
    if (Directory(p.join(Directory.current.path, 'ios')).existsSync()) {
      linkPodspec(
        pluginName,
        moduleInfos.map((m) => m.lib).toList(),
        baseDir: Directory.current.path,
        moduleInfos: moduleInfos,
      );
      // Ensure SPM Package.swift exists even when no podspec is present
      // (e.g. SPM-first projects, or after podspec was removed).
      ensureIosPackageSwift(pluginName, baseDir: Directory.current.path, moduleInfos: moduleInfos);
      await _setDone(2);
    } else {
      await _setSkipped(2, detail: 'ios/ not present');
    }
  }

  Future<void> _runMacosStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
  ) async {
    await _setRunning(3);
    if (Directory(p.join(Directory.current.path, 'macos')).existsSync()) {
      linkMacosPodspec(
        pluginName,
        moduleInfos.map((m) => m.lib).toList(),
        baseDir: Directory.current.path,
        moduleInfos: moduleInfos,
      );
      ensureMacosPackageSwift(pluginName, baseDir: Directory.current.path, moduleInfos: moduleInfos);
      await _setDone(3);
    } else {
      await _setSkipped(3, detail: 'macos/ not present');
    }
  }

  Future<void> _runSwiftStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
  ) async {
    await _setRunning(4);
    final libDir = Directory(p.join(Directory.current.path, 'lib'));
    final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
    String libFrom(File f) {
      final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      return extractLibNameFromSpec(f) ?? stem;
    }

    // Per-platform cpp sets: a module may be cpp on one Apple platform but
    // Swift on the other (e.g. ios:swift, macos:cpp). Track them separately
    // so each platform gets the correct Swift or C++ treatment.
    final iosCppLibs = specFiles.where(isIosCppModule).map(libFrom).toSet();
    final macosCppLibs = specFiles.where(isMacosCppModule).map(libFrom).toSet();

    // iOS Swift modules = NOT ios-cpp.
    final iosSwiftModules = moduleInfos.where((m) => !iosCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
    // macOS Swift modules = NOT macos-cpp.
    final macosSwiftModules = moduleInfos.where((m) => !macosCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
    // Modules whose iOS Swift registration should be REMOVED (now ios-cpp).
    final iosCppModuleInfos = moduleInfos.where((m) => iosCppLibs.contains(m.lib)).toList();
    // Modules whose macOS Swift registration should be REMOVED (now macos-cpp).
    final macosCppModuleInfos = moduleInfos.where((m) => macosCppLibs.contains(m.lib)).toList();

    final noIosSwift = iosSwiftModules.isEmpty;
    final noMacosSwift = macosSwiftModules.isEmpty;

    if (noIosSwift && noMacosSwift) {
      await _setSkipped(
        4,
        detail: 'all modules use AppleNativeImpl.cpp on Apple platforms — no Swift bridge needed',
      );
    } else {
      bool linkedSwift = false;
      if (Directory(p.join(Directory.current.path, 'ios')).existsSync()) {
        if (!noIosSwift) {
          linkSwiftPlugin(
            pluginName,
            iosSwiftModules,
            baseDir: Directory.current.path,
          );
        }
        purgeStaleCppSwiftRegistrations(
          iosCppModuleInfos,
          platform: 'ios',
          baseDir: Directory.current.path,
        );
        linkedSwift = true;
      }
      if (Directory(p.join(Directory.current.path, 'macos')).existsSync()) {
        if (!noMacosSwift) {
          linkMacosSwiftPlugin(
            pluginName,
            macosSwiftModules,
            baseDir: Directory.current.path,
          );
        }
        purgeStaleCppSwiftRegistrations(
          macosCppModuleInfos,
          platform: 'macos',
          baseDir: Directory.current.path,
        );
        linkedSwift = true;
      }
      if (linkedSwift) {
        await _setDone(4);
      } else {
        await _setSkipped(4, detail: 'neither ios/ nor macos/ present');
      }
    }
  }

  Future<void> _runKotlinStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    bool hasCpp,
  ) async {
    await _setRunning(5);
    if (Directory(p.join(Directory.current.path, 'android')).existsSync()) {
      // For Android/Kotlin steps: split by whether the module uses AndroidNativeImpl.cpp
      // (android/linux cpp). A module with windows:cpp but android:kotlin still needs
      // JniBridge registration — isNativeCppModule checks android/linux only.
      final libDir = Directory(p.join(Directory.current.path, 'lib'));
      final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
      final androidCppLibs = specFiles.where(isAndroidCppModule).map((f) {
        final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        return extractLibNameFromSpec(f) ?? stem;
      }).toSet();

      // Modules that need JniBridge.register = NOT android/linux C++ modules.
      final kotlinModules = moduleInfos.where((m) => !androidCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
      // Modules that should have JniBridge.register REMOVED = android/linux C++ modules.
      final androidCppModuleInfos = moduleInfos.where((m) => androidCppLibs.contains(m.lib)).toList();

      if (kotlinModules.isNotEmpty) {
        linkKotlinPlugin(
          pluginName,
          kotlinModules,
          baseDir: Directory.current.path,
        );
      }
      // cpp modules still need System.loadLibrary to trigger __attribute__((constructor))
      if (hasCpp) {
        linkKotlinLoadLibraries(
          moduleInfos.where((m) => m.isCpp).map((m) => m.lib).toList(),
          baseDir: Directory.current.path,
        );
      }
      // Purge stale JniBridge.register() only for modules that are actually
      // Android/Linux C++ — not for mixed modules like android:kotlin + windows:cpp.
      purgeStaleCppKotlinRegistrations(
        androidCppModuleInfos,
        baseDir: Directory.current.path,
      );
      await _setDone(
        5,
        detail: kotlinModules.isNotEmpty ? null : 'cpp: loadLibrary only (no JniBridge)',
      );
    } else {
      await _setSkipped(5, detail: 'android/ not present');
    }
  }

  Future<void> _runAndroidStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
  ) async {
    await _setRunning(6);
    if (Directory(p.join(Directory.current.path, 'android')).existsSync()) {
      linkAndroid(
        pluginName,
        moduleInfos.map((m) => m.lib).toList(),
        baseDir: Directory.current.path,
        moduleInfos: moduleInfos,
      );
      await _setDone(6);
    } else {
      await _setSkipped(6, detail: 'android/ not present');
    }
  }

  Future<void> _runWindowsStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String nitroNativePath,
  ) async {
    await _setRunning(7);
    if (Directory(p.join(Directory.current.path, 'windows')).existsSync()) {
      linkWindows(
        pluginName,
        moduleInfos.map((m) => m.lib).toList(),
        nitroNativePath,
        baseDir: Directory.current.path,
        moduleInfos: moduleInfos,
      );
      await _setDone(7);
    } else {
      await _setSkipped(7, detail: 'windows/ not present');
    }
  }

  Future<void> _runLinuxStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String nitroNativePath,
  ) async {
    await _setRunning(8);
    if (Directory(p.join(Directory.current.path, 'linux')).existsSync()) {
      linkLinux(
        pluginName,
        moduleInfos.map((m) => m.lib).toList(),
        nitroNativePath,
        baseDir: Directory.current.path,
        moduleInfos: moduleInfos,
      );
      await _setDone(8);
    } else {
      await _setSkipped(8, detail: 'linux/ not present');
    }
  }

  Future<void> _runClangdStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
  ) async {
    await _setRunning(9);
    linkClangd(
      pluginName,
      moduleInfos: moduleInfos,
      baseDir: Directory.current.path,
    );
    await _setDone(9);
  }

  Future<void> _runFinalizeBuildStep() async {
    await _setRunning(10);
    // ── SPM-first strategy ─────────────────────────────────────────────────
    // When the plugin has a Package.swift in ios/ or macos/ (either flat or
    // Flutter 3.41+ nested layout), Flutter uses Swift Package Manager directly.
    // Running `pod install` in that case conflicts and is unnecessary.
    // CocoaPods is only used as a fallback when NO Package.swift is present.
    final spmDetected = spm.detectSpmStatus(Directory.current.path);
    final hasSpm = spmDetected.hasSpm;

    if (hasSpm) {
      // Sync generated Swift bridges into the SPM Sources/ target directories
      // so they are compiled by SPM instead of CocoaPods.
      _syncSwiftBridgesToSpmSources(Directory.current.path);

      // Ensure the FlutterFramework symlink resolves for each Package.swift.
      // Flutter places FlutterFramework in the example app's ephemeral dir;
      // the symlink lets Xcode open the plugin project independently.
      for (final pkgPath in [
        spmDetected.iosPackageSwiftPath,
        spmDetected.macosPackageSwiftPath,
      ].whereType<String>()) {
        spm.ensureFlutterFrameworkSymlink(pkgPath, Directory.current.path);
      }

      await _setDone(10, detail: 'SPM (Package.swift) — CocoaPods skipped');
    } else {
      final podfileDirs = findPodfileDirs(Directory.current.path);
      if (podfileDirs.isEmpty) {
        await _setSkipped(10, detail: 'no Podfile found');
      } else {
        final failures = <String>[];
        for (final dir in podfileDirs) {
          // 1. pod deintegrate
          await Process.run('pod', ['deintegrate'], workingDirectory: dir);

          // 2. pod install
          final installResult = await Process.run('pod', ['install'], workingDirectory: dir);
          if (installResult.exitCode != 0) {
            failures.add(p.relative(dir, from: Directory.current.path));
            continue;
          }

          // 3. pod update
          final updateResult = await Process.run('pod', ['update'], workingDirectory: dir);
          if (updateResult.exitCode != 0) {
            failures.add(p.relative(dir, from: Directory.current.path));
          }
        }
        if (failures.isEmpty) {
          await _setDone(
            10,
            detail: podfileDirs.map((d) => p.relative(d, from: Directory.current.path)).join(', '),
          );
        } else {
          await _setDone(10, detail: 'warning: pod routine failed in: ${failures.join(', ')}');
        }
      }
    }
  }

  void _appendNextSteps(bool allCpp, bool hasCpp) {
    if (allCpp) {
      _nextSteps.addAll([
        'nitrogen generate',
        'Subclass Hybrid<Module> in C++ (constructor auto-registers via __attribute__((constructor)))',
        'Build and test with ctest (auto-generated test target)',
      ]);
    } else if (hasCpp) {
      _nextSteps.addAll([
        'nitrogen generate',
        'C++ modules: subclass Hybrid<Module> (constructor auto-registers)',
        'Kotlin/Swift modules: implement Hybrid<Module>Spec / HybridProtocol',
      ]);
    } else {
      _nextSteps.addAll([
        'flutter pub get',
        'flutter pub run build_runner build --delete-conflicting-outputs',
        'nitrogen generate',
        'Implement Specs in Kotlin/Swift',
      ]);
    }
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (e) {
        if (e.logicalKey == LogicalKey.escape) {
          if (component.onExit != null) {
            component.onExit!();
            return true;
          }
          shutdownApp(_failed ? 1 : 0);
          return true;
        }
        if (e.character == 'c' || e.character == 'C') {
          copyToClipboard(_stepsAsText());
          return true;
        }
        return false;
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, left: 1, right: 1),
            child: Container(
              decoration: BoxDecoration(
                border: BoxBorder.all(color: Colors.cyan),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  ' nitrogen link — ${component.pluginName} ',
                  style: const TextStyle(
                    color: Colors.cyan,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: _errorMessage != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              border: BoxBorder.all(color: Colors.red),
                            ),
                            child: const Text(
                              ' ✘ ERROR ',
                              style: TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(_errorMessage!),
                        ],
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        border: BoxBorder.all(color: Colors.brightBlack),
                      ),
                      child: ListView(
                        children: _steps.map(LinkStepRow.new).toList(),
                      ),
                    ),
            ),
          ),
          if (_finished)
            Padding(
              padding: const EdgeInsets.all(1),
              child: Column(
                children: [
                  if (!_failed) ...[
                    const Text(
                      '✨ Linked! Next steps:',
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    ..._nextSteps.asMap().entries.map(
                      (e) => Text(
                        '  ${e.key + 1}. ${e.value}',
                        style: const TextStyle(color: Colors.gray),
                      ),
                    ),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (component.onExit != null) ...[
                        HoverButton(
                          label: '‹ Back',
                          onTap: component.onExit!,
                          color: Colors.cyan,
                        ),
                        const Text(
                          '  •  ',
                          style: TextStyle(color: Colors.brightBlack),
                        ),
                      ],
                      CopyButton(getData: _stepsAsText),
                      const Text(
                        '  •  ',
                        style: TextStyle(color: Colors.brightBlack),
                      ),
                      Text(
                        'c copy   ${component.onExit != null ? 'ESC back' : 'ESC exit'}',
                        style: const TextStyle(
                          color: Colors.gray,
                          fontWeight: FontWeight.dim,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────
// nitroHContent is imported from '../templates/native_headers.dart'.

/// A single piece of managed content that is missing from a native plugin file.
class ManagedContentIssue {
  final String file;
  final String description;
  const ManagedContentIssue({required this.file, required this.description});
}

/// Scans Plugin.kt and Plugin.swift for managed sections (JniBridge import,
/// register() call, Registry.register) that are expected for non-cpp modules
/// but are currently missing. Returns each gap as a [ManagedContentIssue].
///
/// Called before the link TUI starts so the user can confirm re-injection.
List<ManagedContentIssue> detectManagedContentIssues({String baseDir = '.'}) {
  final issues = <ManagedContentIssue>[];

  final libDir = Directory(p.join(baseDir, 'lib'));
  if (!libDir.existsSync()) return issues;
  final allSpecFiles = libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList();
  if (allSpecFiles.isEmpty) return issues;

  // For Android Plugin.kt: a module needs JniBridge registration when it does NOT
  // use a native C++ impl on android/linux (isNativeCppModule). A module like
  // `benchmark` (android: kotlin, windows: cpp) is correctly included here because
  // isNativeCppModule checks android/linux only — isCppModule (broad) would
  // falsely exclude it due to the windows: cpp entry.
  final androidSpecFiles = allSpecFiles.where((f) => !isNativeCppModule(f)).toList();

  // For iOS Plugin.swift: a module needs Registry.register when it does NOT use
  // NativeImpl.cpp specifically on iOS (mixed ios:swift/macos:cpp still needs iOS registration).
  final iosSpecFiles = allSpecFiles.where((f) => !isIosCppModule(f)).toList();

  // ── Android: Plugin.kt ────────────────────────────────────────────────────
  final ktDir = Directory(p.join(baseDir, 'android', 'src', 'main', 'kotlin'));
  if (ktDir.existsSync()) {
    final pluginFiles = ktDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('Plugin.kt')).toList();
    if (pluginFiles.isNotEmpty) {
      final kt = pluginFiles.first.readAsStringSync();
      final ktPath = p.relative(pluginFiles.first.path, from: baseDir);
      for (final specFile in androidSpecFiles) {
        final stem = p.basename(specFile.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = (extractLibNameFromSpec(specFile) ?? stem).replaceAll(
          '-',
          '_',
        );
        final moduleMatch = RegExp(
          r'abstract class (\w+) extends HybridObject',
        ).firstMatch(specFile.readAsStringSync());
        final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
        final importLine = 'import nitro.${lib}_module.${moduleName}JniBridge';
        // Accept both the current registerFactory({...}, ctx) API and the
        // legacy register(impl) form (paren-less prefix matches both).
        final registerCall = '${moduleName}JniBridge.register';
        if (!kt.contains(importLine)) {
          issues.add(
            ManagedContentIssue(
              file: ktPath,
              description: 'Missing import: $importLine',
            ),
          );
        }
        if (!kt.contains(registerCall)) {
          issues.add(
            ManagedContentIssue(
              file: ktPath,
              description: 'Missing registration: ${moduleName}JniBridge.registerFactory({ ${moduleName}Impl(...) }, context)',
            ),
          );
        }
      }
    }
  }

  // ── iOS: Plugin.swift ─────────────────────────────────────────────────────
  final iosDir = Directory(p.join(baseDir, 'ios'));
  if (iosDir.existsSync()) {
    final swiftFiles = iosDir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where(
          (f) => !f.path.contains('.symlinks') && f.path.endsWith('Plugin.swift'),
        )
        .toList();
    if (swiftFiles.isNotEmpty) {
      final swift = swiftFiles.first.readAsStringSync();
      final swiftPath = p.relative(swiftFiles.first.path, from: baseDir);
      for (final specFile in iosSpecFiles) {
        final stem = p.basename(specFile.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final moduleMatch = RegExp(
          r'abstract class (\w+) extends HybridObject',
        ).firstMatch(specFile.readAsStringSync());
        final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
        if (!swift.contains('${moduleName}Registry.register(')) {
          issues.add(
            ManagedContentIssue(
              file: swiftPath,
              description: 'Missing registration: ${moduleName}Registry.register(${moduleName}ModuleImpl())',
            ),
          );
        }
      }
    }
  }

  return issues;
}

class LinkCommand extends Command {
  LinkCommand() {
    argParser
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Skip confirmation prompts (useful for CI).',
      )
      ..addFlag(
        'no-ui',
        negatable: false,
        help: 'Plain-text headless output (no ANSI). Auto-enabled when stdout is not a TTY. Implies --yes.',
      );
  }

  @override
  final String name = 'link';
  @override
  final String description = 'Wires all Nitrogen-generated native bridges into the build system.';
  bool get _headless => !stdout.hasTerminal || (argResults!['no-ui'] as bool);

  @override
  Future<void> run() async {
    final headless = _headless;
    // --no-ui implies --yes (no interactive prompt in headless mode)
    final yesFlag = (argResults!['yes'] as bool) || headless;

    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      stderr.writeln(headless ? '[nitro:error] No Nitro project found.' : '❌ No Nitro project found.');
      exit(1);
    }
    final pubspec = File(p.join(projectDir.path, 'pubspec.yaml'));
    String pluginName = 'unknown';
    for (final line in pubspec.readAsLinesSync()) {
      if (line.startsWith('name: ')) {
        pluginName = line.replaceFirst('name: ', '').trim();
        break;
      }
    }
    Directory.current = projectDir;

    // ── Preflight: detect managed content removed by manual edits ─────────────
    final issues = detectManagedContentIssues(baseDir: projectDir.path);
    if (issues.isNotEmpty) {
      stderr.writeln('');
      if (headless) {
        stderr.writeln('[nitro:warn] managed content missing from plugin files:');
        for (final issue in issues) {
          stderr.writeln('[nitro:warn]   ${issue.file}: ${issue.description}');
        }
        stderr.writeln('[nitro:info] proceeding with re-injection (--no-ui implies --yes)');
      } else {
        stderr.writeln('  \x1B[1;33m⚠  nitrogen link detected managed content missing from plugin files:\x1B[0m');
        stderr.writeln('');
        final byFile = <String, List<String>>{};
        for (final issue in issues) {
          byFile.putIfAbsent(issue.file, () => []).add(issue.description);
        }
        for (final entry in byFile.entries) {
          stderr.writeln('  \x1B[1;37m${entry.key}\x1B[0m');
          for (final desc in entry.value) {
            stderr.writeln('    \x1B[33m• $desc\x1B[0m');
          }
        }
        stderr.writeln('');
        stderr.writeln('  These sections are managed by nitrogen link.');
        stderr.writeln('  Re-running link will restore them automatically.');

        if (!yesFlag) {
          stderr.write('\n  Re-inject missing sections? [Y/n] ');
          final answer = (stdin.readLineSync() ?? '').trim().toLowerCase();
          if (answer == 'n' || answer == 'no') {
            stderr.writeln('\n  Skipped. Run `nitrogen link --yes` to suppress this prompt.');
            return;
          }
        } else {
          stderr.writeln('  (--yes flag set — proceeding without confirmation)');
        }
        stderr.writeln('');
      }
    }

    if (headless) {
      await _runHeadless(pluginName, projectDir.path);
    } else {
      final result = LinkResult();
      await runApp(LinkView(pluginName: pluginName, result: result));
      if (result.success) {
        stdout.writeln('\n  \x1B[1;32m✨ $pluginName linked\x1B[0m');
      }
    }
  }

  Future<void> _runHeadless(String pluginName, String baseDir) async {
    void log(String msg) => stdout.writeln('[nitro] $msg');
    void logSkip(String msg) => stdout.writeln('[nitro:skip] $msg');

    log('nitrogen link $pluginName');

    log('discovering modules...');
    final moduleInfos = discoverModuleInfos(pluginName, baseDir: baseDir);
    final hasCpp = moduleInfos.any((m) => m.isCpp);
    log('${moduleInfos.length} module(s): ${moduleInfos.map((m) => m.module).join(', ')}');

    log('patching CMake...');
    final nitroNativePath = resolveNitroNativePath(baseDir);
    linkCppImplStubs(moduleInfos, baseDir: baseDir);
    linkCMake(pluginName, moduleInfos.map((m) => m.lib).toList(), nitroNativePath, baseDir: baseDir, moduleInfos: moduleInfos);

    _headlessIosStep(pluginName, moduleInfos, baseDir, log, logSkip);
    _headlessMacosStep(pluginName, moduleInfos, baseDir, log, logSkip);

    final libDir = Directory(p.join(baseDir, 'lib'));
    final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
    String libFrom(File f) {
      final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      return extractLibNameFromSpec(f) ?? stem;
    }

    _headlessSwiftStep(pluginName, moduleInfos, baseDir, specFiles, libFrom, log, logSkip);
    _headlessAndroidStep(pluginName, moduleInfos, baseDir, hasCpp, specFiles, libFrom, log, logSkip);
    _headlessWindowsStep(pluginName, moduleInfos, nitroNativePath, baseDir, log, logSkip);
    _headlessLinuxStep(pluginName, moduleInfos, nitroNativePath, baseDir, log, logSkip);

    // FFI-only desktop platforms must not declare pluginClass (issue #10) —
    // repairs pubspecs generated by older nitrogen versions.
    linkDesktopPubspecFfiOnly(moduleInfos, baseDir: baseDir);

    // Guard direct build_runner runs against the example symlink-cycle hang (issue #20).
    linkBuildYamlSourcesExcludes(baseDir: baseDir);

    log('updating .clangd...');
    linkClangd(pluginName, moduleInfos: moduleInfos, baseDir: baseDir);

    await _headlessFinalizeBuildStep(baseDir, log, logSkip);

    log('$pluginName linked');
  }

  void _headlessIosStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String baseDir,
    void Function(String) log,
    void Function(String) logSkip,
  ) {
    if (Directory(p.join(baseDir, 'ios')).existsSync()) {
      log('patching iOS podspec...');
      linkPodspec(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: baseDir, moduleInfos: moduleInfos);
      ensureIosPackageSwift(pluginName, baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('ios/ not present');
    }
  }

  void _headlessMacosStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String baseDir,
    void Function(String) log,
    void Function(String) logSkip,
  ) {
    if (Directory(p.join(baseDir, 'macos')).existsSync()) {
      log('patching macOS podspec...');
      linkMacosPodspec(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: baseDir, moduleInfos: moduleInfos);
      ensureMacosPackageSwift(pluginName, baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('macos/ not present');
    }
  }

  void _headlessSwiftStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String baseDir,
    List<File> specFiles,
    String Function(File) libFrom,
    void Function(String) log,
    void Function(String) logSkip,
  ) {
    final iosCppLibs = specFiles.where(isIosCppModule).map(libFrom).toSet();
    final macosCppLibs = specFiles.where(isMacosCppModule).map(libFrom).toSet();
    final iosSwiftModules = moduleInfos.where((m) => !iosCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
    final macosSwiftModules = moduleInfos.where((m) => !macosCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
    final iosCppModuleInfos = moduleInfos.where((m) => iosCppLibs.contains(m.lib)).toList();
    final macosCppModuleInfos = moduleInfos.where((m) => macosCppLibs.contains(m.lib)).toList();

    if (iosSwiftModules.isEmpty && macosSwiftModules.isEmpty) {
      logSkip('all modules use AppleNativeImpl.cpp — no Swift bridge needed');
    } else {
      if (Directory(p.join(baseDir, 'ios')).existsSync()) {
        if (iosSwiftModules.isNotEmpty) {
          log('wiring iOS Swift plugin...');
          linkSwiftPlugin(pluginName, iosSwiftModules, baseDir: baseDir);
        }
        purgeStaleCppSwiftRegistrations(iosCppModuleInfos, platform: 'ios', baseDir: baseDir);
      }
      if (Directory(p.join(baseDir, 'macos')).existsSync()) {
        if (macosSwiftModules.isNotEmpty) {
          log('wiring macOS Swift plugin...');
          linkMacosSwiftPlugin(pluginName, macosSwiftModules, baseDir: baseDir);
        }
        purgeStaleCppSwiftRegistrations(macosCppModuleInfos, platform: 'macos', baseDir: baseDir);
      }
    }
  }

  void _headlessAndroidStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String baseDir,
    bool hasCpp,
    List<File> specFiles,
    String Function(File) libFrom,
    void Function(String) log,
    void Function(String) logSkip,
  ) {
    if (Directory(p.join(baseDir, 'android')).existsSync()) {
      log('wiring Android Kotlin plugin...');
      final androidCppLibs = specFiles.where(isAndroidCppModule).map(libFrom).toSet();
      final kotlinModules = moduleInfos.where((m) => !androidCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
      final androidCppModuleInfos = moduleInfos.where((m) => androidCppLibs.contains(m.lib)).toList();
      if (kotlinModules.isNotEmpty) linkKotlinPlugin(pluginName, kotlinModules, baseDir: baseDir);
      if (hasCpp) linkKotlinLoadLibraries(moduleInfos.where((m) => m.isCpp).map((m) => m.lib).toList(), baseDir: baseDir);
      purgeStaleCppKotlinRegistrations(androidCppModuleInfos, baseDir: baseDir);
      linkAndroid(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: baseDir, moduleInfos: moduleInfos);
      linkAndroidConsumerRules(kotlinModules, baseDir: baseDir);
    } else {
      logSkip('android/ not present');
    }
  }

  void _headlessWindowsStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String nitroNativePath,
    String baseDir,
    void Function(String) log,
    void Function(String) logSkip,
  ) {
    if (Directory(p.join(baseDir, 'windows')).existsSync()) {
      log('wiring Windows CMake...');
      linkWindows(pluginName, moduleInfos.map((m) => m.lib).toList(), nitroNativePath, baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('windows/ not present');
    }
  }

  void _headlessLinuxStep(
    String pluginName,
    List<ModuleInfo> moduleInfos,
    String nitroNativePath,
    String baseDir,
    void Function(String) log,
    void Function(String) logSkip,
  ) {
    if (Directory(p.join(baseDir, 'linux')).existsSync()) {
      log('wiring Linux CMake...');
      linkLinux(pluginName, moduleInfos.map((m) => m.lib).toList(), nitroNativePath, baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('linux/ not present');
    }
  }

  Future<void> _headlessFinalizeBuildStep(
    String baseDir,
    void Function(String) log,
    void Function(String) logSkip,
  ) async {
    final spmDetected = spm.detectSpmStatus(baseDir);
    if (spmDetected.hasSpm) {
      log('SPM detected — syncing Swift bridges to SPM Sources/...');
      _syncSwiftBridgesToSpmSources(baseDir);
      for (final pkgPath in [spmDetected.iosPackageSwiftPath, spmDetected.macosPackageSwiftPath].whereType<String>()) {
        spm.ensureFlutterFrameworkSymlink(pkgPath, baseDir);
      }
    } else {
      final podfileDirs = findPodfileDirs(baseDir);
      if (podfileDirs.isEmpty) {
        logSkip('no Podfile found — skipping pod install');
      } else {
        for (final dir in podfileDirs) {
          log('pod install (${p.relative(dir, from: baseDir)})...');
          await Process.run('pod', ['deintegrate'], workingDirectory: dir);
          final r = await Process.run('pod', ['install'], workingDirectory: dir);
          if (r.exitCode != 0) {
            stderr.writeln('[nitro:warn] pod install failed in $dir');
          } else {
            await Process.run('pod', ['update'], workingDirectory: dir);
          }
        }
      }
    }
  }
}
