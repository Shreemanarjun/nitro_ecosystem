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
import '../templates/build_versions.dart';
import 'spm_utils.dart' as spm;

// ── Package-level helpers (also used in tests) ─────────────────────────────

/// Resolves the absolute path to the installed `nitro` package's `src/native`
/// directory by reading `.dart_tool/package_config.json` inside [pluginDir].
String resolveNitroNativePath(String pluginDir) {
  // Walk up from pluginDir looking for .dart_tool/package_config.json.
  // In Dart workspaces the config lives at the workspace root, not in each
  // member's own directory.
  var searchDir = Directory(pluginDir);
  while (true) {
    final configFile = File(p.join(searchDir.path, '.dart_tool', 'package_config.json'));
    if (configFile.existsSync()) {
      try {
        final config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
        final packages = (config['packages'] as List<dynamic>?) ?? [];
        for (final pkg in packages) {
          final pkgMap = pkg as Map<String, dynamic>;
          if (pkgMap['name'] == 'nitro') {
            final rootUri = pkgMap['rootUri'] as String;
            final uri = Uri.parse(rootUri);
            if (uri.scheme == 'file') {
              return p.join(uri.toFilePath(), 'src', 'native');
            } else {
              final dartToolDir = p.join(searchDir.path, '.dart_tool');
              final resolved = p.normalize(p.join(dartToolDir, rootUri));
              return p.join(resolved, 'src', 'native');
            }
          }
        }
      } on FormatException catch (e) {
        throw StateError('Failed to parse ${configFile.path} while resolving the nitro native path: ${e.message}');
      } on FileSystemException catch (e) {
        throw StateError('Failed to read ${configFile.path} while resolving the nitro native path: ${e.message}');
      }
    }
    final parent = searchDir.parent;
    if (parent.path == searchDir.path) break;
    searchDir = parent;
  }
  return p.normalize(
    p.absolute(p.join(pluginDir, '..', 'packages', 'nitro', 'src', 'native')),
  );
}

const String _srcLocalNitroNativeCmakePath = ct.localNitroNativeCmakePath;
const String _desktopLocalNitroNativeCmakePath = r'${CMAKE_CURRENT_SOURCE_DIR}/../src/native';
const String _linkSpecChecksumPrefix = '# NITRO_LINK_SPEC_CHECKSUM ';

String? extractLibNameFromSpec(File specFile) {
  final content = specFile.readAsStringSync();
  final match = RegExp(
    r'''@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]''',
  ).firstMatch(content);
  return match?.group(1);
}

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
  factory PlatformTargetAnalyzer.fromContent(String content) {
    final match = RegExp(
      r'@NitroModule\s*\(([^)]+)\)',
      dotAll: true,
    ).firstMatch(content);
    final annotation = match == null ? '' : match.group(1)!.replaceAll('\n', ' ');
    return PlatformTargetAnalyzer._(annotation);
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

  /// True when Android or Linux use direct C++ (src/CMakeLists.txt NDK/GCC path).
  bool get isNativeCpp => RegExp(
    r'\b(?:android|linux)\s*:\s*'
    r'(?:NativeImpl|AndroidNativeImpl|LinuxNativeImpl)\.cpp\b',
  ).hasMatch(_annotation);
}

/// Returns true when the spec file declares at least one platform as a
/// direct C++ implementation (no JNI/Swift bridge). Recognises both:
///   - Legacy shorthand:   `NativeImpl.cpp`
///   - Per-platform types: `AppleNativeImpl.cpp`, `AndroidNativeImpl.cpp`,
///                         `WindowsNativeImpl.cpp`, `LinuxNativeImpl.cpp`
///
/// **Broad check** — true if ANY platform uses C++. Use for deciding whether
/// to create a HybridXxx.cpp stub file or load the library on Android.
bool isCppModule(File specFile) => PlatformTargetAnalyzer.fromSpec(specFile).requiresCpp;

/// Returns true when the spec file uses direct C++ for **Apple platforms** (ios or macos).
/// Only Apple C++ modules need a `HybridXxx.cpp` forwarder in `ios/Classes/` or
/// `macos/Classes/` so CocoaPods compiles the implementation into the pod target.
bool isAppleCppModule(File specFile) => PlatformTargetAnalyzer.fromSpec(specFile).supportsApple;

/// Returns true when the spec file uses direct C++ specifically for **iOS**.
/// Use this instead of [isAppleCppModule] when deciding whether the iOS Swift
/// Plugin.swift needs a `Registry.register()` call — a mixed module with
/// `ios: swift, macos: cpp` still needs the iOS Swift registration.
bool isIosCppModule(File specFile) => PlatformTargetAnalyzer.fromSpec(specFile).supportsIosCpp;

/// Returns true when the spec file uses direct C++ specifically for **macOS**.
/// Use this instead of [isAppleCppModule] when deciding whether the macOS Swift
/// Plugin.swift needs a `Registry.register()` call — a mixed module with
/// `ios: cpp, macos: swift` still needs the macOS Swift registration.
bool isMacosCppModule(File specFile) => PlatformTargetAnalyzer.fromSpec(specFile).supportsMacosCpp;

/// Returns true when the spec file uses direct C++ for **Windows** only.
/// Windows C++ modules use `windows/CMakeLists.txt` (not the shared `src/`)
/// and need their own impl stub created in `windows/src/`.
bool isWindowsCppModule(File specFile) => PlatformTargetAnalyzer.fromSpec(specFile).supportsWindows;

/// Returns true when the spec file uses direct C++ for **Android or Linux** —
/// the platforms that share `src/CMakeLists.txt` (Android NDK / Linux GCC).
///
/// **Narrow check** — use for:
/// - Deciding whether `HybridXxx.cpp` belongs in `src/CMakeLists.txt`
/// - Doctor's "impl file linked" check for the shared cmake target
/// - Skipping the "unlinked source" warning for Windows-only C++ modules
bool isNativeCppModule(File specFile) => PlatformTargetAnalyzer.fromSpec(specFile).isNativeCpp;

/// Returns true ONLY when the spec declares `android: NativeImpl.cpp` (or AndroidNativeImpl.cpp).
/// Unlike [isNativeCppModule] this does NOT match linux-only C++ modules.
///
/// Use this when deciding whether a module needs a Kotlin JniBridge.register() call:
/// a module with `android: NativeImpl.kotlin, linux: NativeImpl.cpp` uses the JNI
/// bridge on Android and should NOT be excluded from Kotlin linking.
bool isAndroidCppModule(File specFile) => PlatformTargetAnalyzer.fromSpec(specFile).supportsAndroid;

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
  const ModuleInfo({
    required this.lib,
    required this.module,
    required this.isCpp,
    this.isNativeCpp = false,
    this.isAndroidCpp = false,
    this.iosIsCpp = false,
    this.macosIsCpp = false,
  });
  Map<String, String> toMap() => {'lib': lib, 'module': module};
}

List<ModuleInfo> discoverModuleInfos(
  String pluginName, {
  String baseDir = '.',
}) {
  final libDir = Directory(p.join(baseDir, 'lib'));
  if (!libDir.existsSync()) {
    return [ModuleInfo(lib: pluginName, module: pluginName, isCpp: false)];
  }
  final specs = libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList();
  if (specs.isEmpty) {
    return [ModuleInfo(lib: pluginName, module: pluginName, isCpp: false)];
  }

  final modules = <ModuleInfo>[];
  for (final spec in specs) {
    final content = spec.readAsStringSync();
    final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
    final libName = extractLibNameFromSpec(spec) ?? stem.replaceAll('-', '_');
    final moduleMatch = RegExp(
      r'abstract class (\w+) extends HybridObject',
    ).firstMatch(content);
    final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
    // Parse annotation once; avoids two extra file reads vs calling isCppModule + isNativeCppModule.
    final analyzer = PlatformTargetAnalyzer.fromContent(content);

    if (!modules.any((m) => m.module == moduleName)) {
      modules.add(
        ModuleInfo(
          lib: libName,
          module: moduleName,
          isCpp: analyzer.requiresCpp,
          isNativeCpp: analyzer.isNativeCpp,
          isAndroidCpp: analyzer.supportsAndroid,
          iosIsCpp: analyzer.supportsIosCpp,
          macosIsCpp: analyzer.supportsMacosCpp,
        ),
      );
    }
  }
  return modules;
}

String computeLinkSpecChecksum({String baseDir = '.'}) {
  final libDir = Directory(p.join(baseDir, 'lib'));
  if (!libDir.existsSync()) return _fnv64Hex('no-lib');

  final specs = libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList()
    ..sort((a, b) => p.relative(a.path, from: baseDir).compareTo(p.relative(b.path, from: baseDir)));

  if (specs.isEmpty) return _fnv64Hex('no-specs');

  final parts = <String>[];
  for (final spec in specs) {
    parts
      ..add(p.relative(spec.path, from: baseDir))
      ..add(spec.readAsStringSync());
  }
  return _fnv64Hex(parts.join('\n--- nitro spec ---\n'));
}

String _fnv64Hex(String input) {
  final mask = BigInt.parse('ffffffffffffffff', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  for (final unit in input.codeUnits) {
    hash = hash ^ BigInt.from(unit);
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

({String content, bool modified}) _stampLinkSpecChecksum(String content, String checksum) {
  final line = '$_linkSpecChecksumPrefix$checksum';
  final regex = RegExp(r'^# NITRO_LINK_SPEC_CHECKSUM .*$', multiLine: true);
  final match = regex.firstMatch(content);
  if (match != null) {
    if (match.group(0) == line) return (content: content, modified: false);
    return (content: content.replaceFirst(regex, line), modified: true);
  }

  final nitroNativeLine = RegExp(r'^set\(NITRO_NATIVE "[^"]+"\)$', multiLine: true);
  if (nitroNativeLine.hasMatch(content)) {
    return (
      content: content.replaceFirstMapped(nitroNativeLine, (m) => '${m.group(0)}\n$line'),
      modified: true,
    );
  }
  return (content: '$line\n$content', modified: true);
}

// Keep legacy signature for external callers
List<Map<String, String>> discoverModules(
  String pluginName, {
  String baseDir = '.',
}) {
  return discoverModuleInfos(
    pluginName,
    baseDir: baseDir,
  ).map((m) => m.toMap()).toList();
}

/// Returns directories containing a Podfile, searching common locations:
/// `<root>/ios/`, `<root>/macos/`, `<root>/example/ios/`, `<root>/example/macos/`,
/// and any direct child `*/ios/` or `*/macos/`.
List<String> findPodfileDirs(String projectRoot) {
  final candidates = [
    p.join(projectRoot, 'ios'),
    p.join(projectRoot, 'macos'),
    p.join(projectRoot, 'example', 'ios'),
    p.join(projectRoot, 'example', 'macos'),
  ];
  try {
    for (final entity in Directory(projectRoot).listSync()) {
      if (entity is Directory) {
        candidates.add(p.join(entity.path, 'ios'));
        candidates.add(p.join(entity.path, 'macos'));
      }
    }
  } catch (_) {}
  return candidates.where((dir) => File(p.join(dir, 'Podfile')).existsSync()).toList();
}

// ── Progress model ──────────────────────────────

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

      await _setRunning(9);
      linkClangd(
        pluginName,
        moduleInfos: moduleInfos,
        baseDir: Directory.current.path,
      );
      await _setDone(9);

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
    } catch (e) {
      setState(() {
        _failed = true;
        _errorMessage = e.toString();
      });
    }
    component.result.success = !_failed;
    setState(() => _finished = true);
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
  for (final headerName in ['dart_api_dl.h', 'dart_api.h', 'dart_native_api.h', 'dart_version.h']) {
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
      for (final targetDir in sourcesDir.listSync().whereType<Directory>()) {
        if (!p.basename(targetDir.path).endsWith('Cpp')) continue;
        final includeDir = Directory(p.join(targetDir.path, 'include'));
        if (!includeDir.existsSync()) continue;
        // Write nitro.h with the correct guard-protected content.
        File(p.join(includeDir.path, 'nitro.h')).writeAsStringSync(nitroHContent);
        // Copy dart API headers from the nitro native source.
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
  if (modified) cmakeFile.writeAsStringSync(content);
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
  final bridgeFiles = swiftGenDir
      .listSync()
      .whereType<File>()
      .where((f) => p.basename(f.path).endsWith('.bridge.g.swift'))
      .toList()
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
  final allBridges = swiftGenDir
      .listSync()
      .whereType<File>()
      .where((f) => p.basename(f.path).endsWith('.bridge.g.swift'))
      .toList()
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
    return content.contains('\npublic protocol NitroEncodable') ||
        content.contains('\npublic class NitroRecordWriter') ||
        content.contains('\npublic class NitroRecordReader');
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
/// Windows-only C++ modules get their own stub in `windows/src/` (see
/// [linkWindowsCppImplStubs]) and are excluded here.
///
/// The generated stub includes a per-platform `#if` guard on the auto-register
/// call so it fires only on the platforms where the C++ bridge is actually used.
void linkCppImplStubs(List<ModuleInfo> moduleInfos, {String baseDir = '.'}) {
  // Ensure src/ exists before writing stubs (createSync is idempotent).
  Directory(p.join(baseDir, 'src')).createSync(recursive: true);

  // Only create stubs for modules whose src/ file is actually compiled:
  // android/linux (isNativeCpp), iOS (iosIsCpp), or macOS (macosIsCpp).
  // Windows-only modules use windows/src/ instead.
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
  if (!content.contains('HEADER_SEARCH_PATHS')) {
    content = content.replaceFirst(
      's.pod_target_xcconfig = {',
      "s.pod_target_xcconfig = {\n    'HEADER_SEARCH_PATHS' => '\$(inherited) \"\${PODS_ROOT}/../.symlinks/plugins/nitro/src/native\" \"\${PODS_TARGET_SRCROOT}/../src\" \"\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp\"',",
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
  if (moduleInfos != null) {
    // Discover specs for iOS-cpp filtering (per-platform, not broad Apple check).
    final libDir = Directory(p.join(baseDir, 'lib'));
    final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
    final appleCppLibs = specFiles.where(isIosCppModule).map((f) {
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
  if (!content.contains('HEADER_SEARCH_PATHS')) {
    content = content.replaceFirst(
      's.pod_target_xcconfig = {',
      "s.pod_target_xcconfig = {\n    'HEADER_SEARCH_PATHS' => '\$(inherited) \"\${PODS_ROOT}/../Flutter/ephemeral/.symlinks/plugins/nitro/src/native\" \"\${PODS_TARGET_SRCROOT}/../src\" \"\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp\"',",
    );
    modified = true;
  } else {
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
  if (moduleInfos != null) {
    final libDir = Directory(p.join(baseDir, 'lib'));
    final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
    final appleCppLibs = specFiles.where(isMacosCppModule).map((f) {
      final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      return extractLibNameFromSpec(f) ?? stem;
    }).toSet();

    for (final m in moduleInfos.where((m) => m.isCpp)) {
      final className = _toPascalCase(m.lib);
      final forwarderFile = File(
        p.join(classesDir.path, 'Hybrid$className.cpp'),
      );
      if (appleCppLibs.contains(m.lib)) {
        final implSrc = File(p.join(baseDir, 'src', 'Hybrid$className.cpp'));
        if (implSrc.existsSync()) {
          forwarderFile.writeAsStringSync(
            managedCppForwarder('../../src/Hybrid$className.cpp'),
          );
        }
      } else {
        if (forwarderFile.existsSync()) forwarderFile.deleteSync();
      }
    }
  }
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

    final nitroNativePath = resolveNitroNativePath(baseDir);
    final includeDir = Directory(p.join(cppTargetDir.path, 'include'))..createSync(recursive: true);

    // Copy nitro API headers and dart_api_dl.c into the SPM C++ target.
    // Always write the canonical nitroHContent (with NITRO_ERROR_DEFINED guard)
    // directly rather than copying from the installed nitro package, which may
    // lack the guard. Using different copies with inconsistent guards causes a
    // "Typedef redefinition" error when both are included in the same TU.
    File(p.join(includeDir.path, 'nitro.h')).writeAsStringSync(nitroHContent);
    for (final headerName in ['dart_api_dl.h', 'dart_api.h', 'dart_native_api.h', 'dart_version.h']) {
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

    // 2a. Additional Swift-backed module bridges.
    //     Every spec generates a ${lib}.bridge.g.cpp that defines C symbols like
    //     ${lib}_init_dart_api_dl. SPM only compiles files in Sources/<ClassName>Cpp/,
    //     so each module needs a .mm wrapper that #includes the generated .cpp so that
    //     SPM links those symbols into the binary.
    //     Without this, a multi-spec Swift plugin crashes at runtime:
    //       "Failed to lookup symbol 'nitro_ui_init_dart_api_dl': symbol not found"
    //     Written unconditionally (same as the main bridge above) so the forwarder
    //     exists even when `nitrogen link` runs before `nitrogen generate`.
    if (moduleInfos != null) {
      // Only skip modules that use a C++ native implementation on THIS Apple
      // platform (ios/macos). Modules that are C++ on Windows/Linux but Swift
      // on ios/macos still need the .bridge.g.mm forwarder so SPM links the
      // $lib_init_dart_api_dl symbol into the binary.
      final appleCppLibs = (platform == 'ios'
              ? moduleInfos.where((m) => m.iosIsCpp)
              : moduleInfos.where((m) => m.macosIsCpp))
          .map((m) => m.lib)
          .toSet();
      for (final m in moduleInfos) {
        final lib = m.lib;
        if (lib == pluginName) continue; // main bridge already written above
        if (appleCppLibs.contains(lib)) continue; // Apple C++ modules handle their own bridge
        final bridgeCppPath = p.join(
          baseDir,
          'lib',
          'src',
          'generated',
          'cpp',
          '$lib.bridge.g.cpp',
        );
        final relBridge = p.relative(bridgeCppPath, from: cppTargetDir.path).replaceAll(r'\', '/');
        File(p.join(cppTargetDir.path, '$lib.bridge.g.mm')).writeAsStringSync(
          managedBridgeMmForwarder(relBridge),
        );
      }
    }

    // Skip module-specific C++ bridge linking when no C++ modules exist.
    if (allCppModules.isEmpty) continue;

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

    for (final m in allCppModules) {
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

/// Ensures `System.loadLibrary("lib")` is present in the Kotlin plugin's
/// companion object init block for each cpp module lib.
/// cpp modules use `__attribute__((constructor))` for auto-registration, so
/// no JniBridge.register call is needed — just loading the .so is enough.
void linkKotlinLoadLibraries(List<String> libs, {String baseDir = '.'}) {
  final kotlinDir = Directory(
    p.join(baseDir, 'android', 'src', 'main', 'kotlin'),
  );
  if (!kotlinDir.existsSync()) return;
  final pluginFiles = kotlinDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.kt'))
      .toList();
  if (pluginFiles.isEmpty) return;
  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;
  for (final lib in libs) {
    if (!content.contains('loadLibrary("$lib")')) {
      // Insert after the last existing System.loadLibrary call in the init block
      final match = RegExp(
        r'System\.loadLibrary\("[^"]+"\)',
      ).allMatches(content);
      if (match.isNotEmpty) {
        content = content.replaceFirst(
          match.last.group(0)!,
          '${match.last.group(0)!}\n            System.loadLibrary("$lib")',
        );
      } else {
        // Fallback: inject into existing companion object, or insert a new one.
        final className = p.basenameWithoutExtension(pluginFile.path);
        final classPattern = RegExp('class\\s+$className[^{]*\\{');
        final classMatch = classPattern.firstMatch(content);
        if (classMatch == null) {
          throw Exception(
            'nitrogen link failed: Cannot find opening "{" for class $className in ${p.basename(pluginFile.path)} '
            'to inject System.loadLibrary("$lib"). Please add it manually.',
          );
        }
        // Check if there's already a companion object in the class body
        final classBody = classMatch.group(0)!;
        final companionPattern = RegExp(r'companion\s+object');
        if (companionPattern.hasMatch(content)) {
          // Inject into existing companion object before its closing brace
          final companionMatch = RegExp(
            r'companion\s+object[^{]*\{([^}]*)\}',
          ).firstMatch(content);
          if (companionMatch != null) {
            content = content.replaceFirst(
              companionMatch.group(0)!,
              companionMatch
                  .group(0)!
                  .replaceFirst(
                    '}',
                    '    System.loadLibrary("$lib")\n        }',
                  ),
            );
          } else {
            throw Exception(
              'nitrogen link failed: Found companion object in $className (${p.basename(pluginFile.path)}) '
              'but could not locate its closing brace to inject System.loadLibrary("$lib"). Please add it manually.',
            );
          }
        } else {
          content = content.replaceFirst(
            classBody,
            '$classBody\n    companion object {\n        init { System.loadLibrary("$lib") }\n    }\n',
          );
        }
      }
      modified = true;
    }
  }
  if (modified) pluginFile.writeAsStringSync(content);
}

void linkKotlinPlugin(
  String pluginName,
  List<Map<String, String>> modules, {
  String baseDir = '.',
}) {
  final kotlinDir = Directory(
    p.join(baseDir, 'android', 'src', 'main', 'kotlin'),
  );
  if (!kotlinDir.existsSync()) return;
  final pluginFiles = kotlinDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.kt'))
      .toList();
  if (pluginFiles.isEmpty) return;
  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;
  for (final m in modules) {
    final name = m['module']!;
    final lib = (m['lib'] ?? name.toLowerCase()).replaceAll('-', '_');
    final reg = '${name}JniBridge';
    final impl = '${name}Impl';
    // The Kotlin generator emits: package nitro.${lib}_module
    // so the fully-qualified import is: import nitro.${lib}_module.${Module}JniBridge
    final importLine = 'import nitro.${lib}_module.$reg';

    // ── 1. Ensure import is present ─────────────────────────────────────────
    if (!content.contains(importLine)) {
      // Insert after the last 'import …' line in the file for clean ordering.
      final importMatches = RegExp(
        r'^import .+$',
        multiLine: true,
      ).allMatches(content);
      if (importMatches.isNotEmpty) {
        final lastImport = importMatches.last;
        content = content.replaceRange(
          lastImport.end,
          lastImport.end,
          '\n$importLine',
        );
      } else {
        // No imports yet — add one blank line after the package declaration.
        content = content.replaceFirstMapped(
          RegExp(r'^package .+$', multiLine: true),
          (m) => '${m.group(0)!}\n\n$importLine',
        );
      }
      modified = true;
    }

    // ── 2. Ensure register() call is present ────────────────────────────────
    // Detect whether XxxImpl needs a Context argument by scanning the impl file.
    // Nitro Kotlin impls commonly take Context in their primary constructor.
    // If we inject XxxImpl() when XxxImpl(context: Context) is required, the
    // call compiles but crashes at runtime — pass binding.applicationContext.
    final implArg = _detectKotlinImplArg(impl, baseDir: baseDir);
    final registerCall = '$reg.register($impl($implArg))';
    if (!content.contains('$reg.register')) {
      final match = RegExp(
        r'\w+JniBridge\.register\(.*?\)\)',
      ).allMatches(content);
      if (match.isNotEmpty) {
        // Append after the last existing JniBridge.register() call.
        content = content.replaceFirst(
          match.last.group(0)!,
          '${match.last.group(0)!}\n        $registerCall',
        );
      } else {
        content = content.replaceFirst(
          'override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {',
          'override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n        $registerCall',
        );
      }
      modified = true;
    }
  }
  if (modified) pluginFile.writeAsStringSync(content);
}

/// Inspects the impl Kotlin file for [implClass] to decide what argument to
/// pass when calling [implClass](...) inside `onAttachedToEngine`.
///
/// Returns `'binding.applicationContext'` if the primary constructor has a
/// `Context` parameter, or `''` (empty — no-arg call) otherwise.
String _detectKotlinImplArg(String implClass, {String baseDir = '.'}) {
  final ktDir = Directory(p.join(baseDir, 'android', 'src', 'main', 'kotlin'));
  if (!ktDir.existsSync()) return '';
  final candidates = ktDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('$implClass.kt')).toList();
  if (candidates.isEmpty) return '';
  final src = candidates.first.readAsStringSync();
  // Match e.g. `class FooImpl(private val context: Context)` or
  //             `class FooImpl(val ctx: Context, ...)`
  if (RegExp(
    r'class\s+' + RegExp.escape(implClass) + r'\s*\([^)]*:\s*Context',
  ).hasMatch(src)) {
    return 'binding.applicationContext';
  }
  return '';
}

/// Removes stale `<Module>JniBridge.register(...)` calls from Plugin.kt for
/// modules that have been converted to NativeImpl.cpp.
///
/// When a user switches `android: NativeImpl.kotlin` → `AndroidNativeImpl.cpp`
/// (or any C++ variant), the old registration call is left as dead code that
/// causes a Kotlin "Unresolved reference" compile error. This function finds
/// and removes those stale calls automatically on every `nitrogen link` run.
void purgeStaleCppKotlinRegistrations(
  List<ModuleInfo> cppModules, {
  String baseDir = '.',
}) {
  if (cppModules.isEmpty) return;
  final kotlinDir = Directory(
    p.join(baseDir, 'android', 'src', 'main', 'kotlin'),
  );
  if (!kotlinDir.existsSync()) return;
  final pluginFiles = kotlinDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.kt'))
      .toList();
  if (pluginFiles.isEmpty) return;
  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;

  for (final m in cppModules) {
    // Match: <Module>JniBridge.register(<anything>)
    // The line may have leading whitespace and optional trailing comment.
    final stalePattern = RegExp(
      r'[ \t]*' + RegExp.escape('${m.module}JniBridge') + r'\.register\(.*\)[ \t]*\r?\n?',
    );
    if (stalePattern.hasMatch(content)) {
      content = content.replaceAll(stalePattern, '');
      modified = true;
    }
  }

  // Clean up orphaned imports for the removed JniBridge class.
  for (final m in cppModules) {
    final importPattern = RegExp(
      r'import [^\n]+?' + RegExp.escape('${m.module}JniBridge') + r'[^\n]*\n?',
    );
    if (importPattern.hasMatch(content)) {
      content = content.replaceAll(importPattern, '');
      modified = true;
    }
  }

  if (modified) pluginFile.writeAsStringSync(content);
}

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

/// Configures `android/build.gradle` (or `.kts`) so the generated Kotlin bridge
/// files in `lib/src/generated/kotlin/` are compiled as part of the Android build.
///
/// Without the `kotlin.srcDirs` entry, all `.bridge.g.kt` files are generated but
/// never compiled — causing "Unresolved reference: XxxJniBridge" errors at build time.
void linkAndroid(
  String pluginName,
  List<String> moduleLibs, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  File? buildGradle;
  for (final candidate in [
    File(p.join(baseDir, 'android', 'build.gradle')),
    File(p.join(baseDir, 'android', 'build.gradle.kts')),
  ]) {
    if (candidate.existsSync()) {
      buildGradle = candidate;
      break;
    }
  }
  if (buildGradle == null) return;

  var content = buildGradle.readAsStringSync();
  bool modified = false;
  final isKts = buildGradle.path.endsWith('.kts');

  // 0. Upgrade old-style `apply plugin: "kotlin-android"` to modern plugins{} DSL.
  //    The legacy `buildscript {}` + `apply plugin` approach fails in modern AGP
  //    because `kotlin-android` alias is not resolvable without the classpath in
  //    the consuming app's settings.gradle. Modern Flutter apps use `plugins {}`.
  if (content.contains('apply plugin: "kotlin-android"') || content.contains("apply plugin: 'kotlin-android'")) {
    // Remove the entire buildscript block if present.
    content = content.replaceAll(
      RegExp(r'\bbuildscript\s*\{[^}]*\{[^}]*\}[^}]*\}\s*\n?', dotAll: true),
      '',
    );
    // Remove rootProject.allprojects block.
    content = content.replaceAll(
      RegExp(r'\brootProject\.allprojects\s*\{[^}]*\}\s*\n?', dotAll: true),
      '',
    );
    // Replace apply plugin lines with plugins{} block.
    content = content.replaceAll(
      RegExp(r"apply plugin:\s*'com\.android\.library'\s*\n?"),
      '',
    );
    content = content.replaceAll(
      RegExp(r'apply plugin:\s*"com\.android\.library"\s*\n?'),
      '',
    );
    content = content.replaceAll(
      RegExp(r"apply plugin:\s*'kotlin-android'\s*\n?"),
      '',
    );
    content = content.replaceAll(
      RegExp(r'apply plugin:\s*"kotlin-android"\s*\n?'),
      '',
    );
    // Insert plugins{} block at the very TOP of the file (Gradle requires it
    // before any other statements including group/version assignments).
    if (!content.contains('plugins {') && !content.contains('plugins{')) {
      // Remove group/version from their current position (they'll move after plugins{}).
      final groupVersionMatch = RegExp(
        r'^group\s*=.+\nversion\s*=.+\n',
        multiLine: true,
      ).firstMatch(content);
      String groupVersionBlock = '';
      if (groupVersionMatch != null) {
        groupVersionBlock = groupVersionMatch.group(0)!;
        content = content.replaceFirst(groupVersionBlock, '');
      }
      content =
          'plugins {\n    id "com.android.library"\n    id "org.jetbrains.kotlin.android"\n}\n\n${groupVersionBlock.trim().isEmpty ? "" : "${groupVersionBlock.trim()}\n\n"}${content.trimLeft()}';
    }
    // Fix ndkVersion = android.ndkVersion → hardcoded version for standalone builds.
    content = content.replaceAll(
      'ndkVersion = android.ndkVersion',
      'ndkVersion = "${BuildVersions.androidNdk}"',
    );
    // Collapse sequences of 3+ blank lines to a single blank line (cosmetic cleanup).
    content = content.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    modified = true;
  }

  final srcDirsLine = isKts
      ? r'            kotlin.srcDirs += setOf("${project.projectDir}/../lib/src/generated/kotlin")'
      : r'            kotlin.srcDirs += "${project.projectDir}/../lib/src/generated/kotlin"';

  // 1. Ensure kotlin.srcDirs for generated Kotlin bridges.
  //    .bridge.g.kt files live in lib/src/generated/kotlin/ — Gradle must see
  //    that directory as a Kotlin source root or the JNI bridge classes won't compile.
  //    Note: add to kotlin.srcDirs ONLY, NOT java.srcDirs — in AGP 8.x, routing
  //    .kt through the Java compiler path causes "Unresolved reference: XxxJniBridge".
  if (!content.contains('generated/kotlin')) {
    final sourceSetsMatch = RegExp(r'\bsourceSets\s*\{').firstMatch(content);
    if (sourceSetsMatch != null) {
      // sourceSets block exists — look for main {} inside it.
      final afterSourceSets = content.substring(sourceSetsMatch.end);
      final mainInBlock = RegExp(r'\bmain\s*\{').firstMatch(afterSourceSets);
      if (mainInBlock != null) {
        final mainAbsStart = sourceSetsMatch.end + mainInBlock.start;
        // Find the { of main {} and then its matching }
        final openBrace = content.indexOf(
          '{',
          mainAbsStart + mainInBlock.group(0)!.length - 1,
        );
        if (openBrace >= 0) {
          final mainClose = _findBlockEnd(content, openBrace);
          if (mainClose > 0) {
            content = content.replaceRange(
              mainClose,
              mainClose,
              '\n$srcDirsLine\n        ',
            );
            modified = true;
          }
        }
      } else {
        // sourceSets exists but no main {} — add main {} before sourceSets closing brace
        final sourceSetsClose = _findBlockEnd(content, sourceSetsMatch.end - 1);
        if (sourceSetsClose > 0) {
          content = content.replaceRange(
            sourceSetsClose,
            sourceSetsClose,
            '    main {\n$srcDirsLine\n        }\n    ',
          );
          modified = true;
        }
      }
    } else {
      // No sourceSets block — inject one inside android {}
      final androidMatch = RegExp(r'\bandroid\s*\{').firstMatch(content);
      if (androidMatch != null) {
        content = content.replaceRange(
          androidMatch.end,
          androidMatch.end,
          '\n    sourceSets {\n        main {\n$srcDirsLine\n        }\n    }',
        );
      } else {
        content += '\nandroid {\n    sourceSets {\n        main {\n$srcDirsLine\n        }\n    }\n}\n';
      }
      modified = true;
    }
  }

  // 2. Ensure kotlinOptions has the expected JVM target for correct bytecode.
  if (!content.contains('kotlinOptions')) {
    final androidMatch = RegExp(r'\bandroid\s*\{').firstMatch(content);
    if (androidMatch != null) {
      content = content.replaceRange(
        androidMatch.end,
        androidMatch.end,
        '\n    kotlinOptions { jvmTarget = "${BuildVersions.androidJvmTarget}" }',
      );
      modified = true;
    }
  }

  // 3. Ensure kotlinx-coroutines (required for generated Kotlin suspend bridge functions).
  if (!content.contains('kotlinx-coroutines')) {
    final depsMatch = RegExp(r'\bdependencies\s*\{').firstMatch(content);
    if (depsMatch != null) {
      content = content.replaceRange(
        depsMatch.end,
        depsMatch.end,
        '\n    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3"\n    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3"',
      );
    } else {
      content +=
          '\ndependencies {\n    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3"\n    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3"\n}\n';
    }
    modified = true;
  }

  if (modified) buildGradle.writeAsStringSync(content);
}

/// Returns the index of the `}` that closes the block whose opening `{` is at [openBrace].
int _findBlockEnd(String content, int openBrace) {
  int depth = 0;
  for (int i = openBrace; i < content.length; i++) {
    if (content[i] == '{') {
      depth++;
    } else if (content[i] == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// Creates Windows-specific C++ impl stub files for modules that target
/// `windows: WindowsNativeImpl.cpp`. These stubs live in `windows/src/` so
/// `windows/CMakeLists.txt` can reference them via a relative path.
void linkWindowsCppImplStubs(
  List<ModuleInfo> moduleInfos, {
  String baseDir = '.',
}) {
  final libDir = Directory(p.join(baseDir, 'lib'));
  final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
  final windowsCppLibs = specFiles.where(isWindowsCppModule).map((f) {
    final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
    return extractLibNameFromSpec(f) ?? stem;
  }).toSet();

  for (final m in moduleInfos.where(
    (m) => m.isCpp && windowsCppLibs.contains(m.lib),
  )) {
    final className = _toPascalCase(m.lib);
    final winSrcDir = Directory(p.join(baseDir, 'windows', 'src'))..createSync(recursive: true);
    final stubFile = File(p.join(winSrcDir.path, 'Hybrid$className.cpp'));
    if (stubFile.existsSync()) continue;
    stubFile.writeAsStringSync(
      t.windowsCppStubContent(lib: m.lib, className: className),
    );
  }
}

void linkWindows(
  String pluginName,
  List<String> moduleLibs,
  String nitroNativePath, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  _linkDesktopCMake(
    pluginName,
    moduleLibs,
    nitroNativePath,
    platform: 'windows',
    baseDir: baseDir,
    moduleInfos: moduleInfos,
  );
  if (moduleInfos != null) {
    linkWindowsCppImplStubs(moduleInfos, baseDir: baseDir);
  }
}

void linkLinux(
  String pluginName,
  List<String> moduleLibs,
  String nitroNativePath, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  _linkDesktopCMake(
    pluginName,
    moduleLibs,
    nitroNativePath,
    platform: 'linux',
    baseDir: baseDir,
    moduleInfos: moduleInfos,
  );
}

void linkClangd(
  String pluginName, {
  List<ModuleInfo>? moduleInfos,
  String baseDir = '.',
}) {
  final sb = StringBuffer()
    ..writeln('CompileFlags:')
    ..writeln('  Add:')
    ..writeln('    - -I\${PWD}/src')
    ..writeln('    - -I\${PWD}/src/native')
    ..writeln('    - -I\${PWD}/lib/src/generated/cpp')
    ..writeln('    - -I\${PWD}/src/native/internal');

  // For C++ modules also expose the test/ directory so IDEs resolve mock headers
  if (moduleInfos != null && moduleInfos.any((m) => m.isCpp)) {
    sb.writeln('    - -I\${PWD}/lib/src/generated/cpp/test');
  }
  File(p.join(baseDir, '.clangd')).writeAsStringSync(sb.toString());
}

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
        final registerCall = '${moduleName}JniBridge.register(';
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
              description: 'Missing registration: ${moduleName}JniBridge.register(${moduleName}Impl(...))',
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

    if (Directory(p.join(baseDir, 'ios')).existsSync()) {
      log('patching iOS podspec...');
      linkPodspec(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: baseDir, moduleInfos: moduleInfos);
      ensureIosPackageSwift(pluginName, baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('ios/ not present');
    }

    if (Directory(p.join(baseDir, 'macos')).existsSync()) {
      log('patching macOS podspec...');
      linkMacosPodspec(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: baseDir, moduleInfos: moduleInfos);
      ensureMacosPackageSwift(pluginName, baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('macos/ not present');
    }

    final libDir = Directory(p.join(baseDir, 'lib'));
    final specFiles = libDir.existsSync() ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList() : <File>[];
    String libFrom(File f) {
      final stem = p.basename(f.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      return extractLibNameFromSpec(f) ?? stem;
    }

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

    if (Directory(p.join(baseDir, 'android')).existsSync()) {
      log('wiring Android Kotlin plugin...');
      final androidCppLibs = specFiles.where(isAndroidCppModule).map(libFrom).toSet();
      final kotlinModules = moduleInfos.where((m) => !androidCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
      final androidCppModuleInfos = moduleInfos.where((m) => androidCppLibs.contains(m.lib)).toList();
      if (kotlinModules.isNotEmpty) linkKotlinPlugin(pluginName, kotlinModules, baseDir: baseDir);
      if (hasCpp) linkKotlinLoadLibraries(moduleInfos.where((m) => m.isCpp).map((m) => m.lib).toList(), baseDir: baseDir);
      purgeStaleCppKotlinRegistrations(androidCppModuleInfos, baseDir: baseDir);
      linkAndroid(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('android/ not present');
    }

    if (Directory(p.join(baseDir, 'windows')).existsSync()) {
      log('wiring Windows CMake...');
      linkWindows(pluginName, moduleInfos.map((m) => m.lib).toList(), nitroNativePath, baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('windows/ not present');
    }

    if (Directory(p.join(baseDir, 'linux')).existsSync()) {
      log('wiring Linux CMake...');
      linkLinux(pluginName, moduleInfos.map((m) => m.lib).toList(), nitroNativePath, baseDir: baseDir, moduleInfos: moduleInfos);
    } else {
      logSkip('linux/ not present');
    }

    log('updating .clangd...');
    linkClangd(pluginName, moduleInfos: moduleInfos, baseDir: baseDir);

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

    log('$pluginName linked');
  }
}
