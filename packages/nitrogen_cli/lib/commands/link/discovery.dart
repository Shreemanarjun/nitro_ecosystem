part of '../link_command.dart';

// Package-level helpers: path/spec/module discovery + platform predicates
// (also used in tests). Part of the link_command library.

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

const String _linkSpecChecksumPrefix = '# NITRO_LINK_SPEC_CHECKSUM ';

String? extractLibNameFromSpec(File specFile) {
  final content = specFile.readAsStringSync();
  final match = RegExp(
    r'''@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]''',
  ).firstMatch(content);
  return match?.group(1);
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

/// Returns true when the spec file uses direct C++ for **Linux**. A Linux-C++
/// module always gets a `linux/src/HybridXxx.cpp` starter stub created (see
/// [linkLinuxCppImplStubs]) — whether it's actually USED instead of the
/// shared `src/HybridXxx.cpp` is a separate, opt-in decision driven by file
/// content (see [hasCustomPlatformImpl]), independent of Windows.
bool isLinuxCppModule(File specFile) => PlatformTargetAnalyzer.fromSpec(specFile).supportsLinux;

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

/// Marker left in a fresh, never-touched `Hybrid$className.cpp` stub — see
/// [cppImplStubContent] / [windowsCppStubContent] / [linuxCppStubContent] in
/// templates/cpp_stubs.dart. Its presence means nobody has started writing
/// real code in that file yet.
const String _implStubTodoMarker = 'TODO: implement all pure-virtual methods declared in Hybrid';

/// Whether Windows or Linux should get its OWN impl file instead of sharing
/// `src/Hybrid$className.cpp` — driven entirely by what's actually on disk,
/// not by annotation config, so both "keep everything in one shared file"
/// and "diverge Windows and Linux" stay available as a plugin-author choice
/// (some plugins want one file for easier maintenance when the logic really
/// is identical; others want Windows and Linux to genuinely diverge — e.g.
/// different threading primitives, platform intrinsics).
///
/// True only when `$baseDir/$platform/src/Hybrid$className.cpp` exists AND
/// contains actual code — i.e. the plugin author genuinely started writing
/// platform-specific implementation there. An untouched stub, a file that
/// still carries the starter's [_implStubTodoMarker], or a comments-only
/// file (someone deleting the stub body and leaving notes) all mean "keep
/// sharing" — nitrogen never forces a plugin onto the separated shape.
/// (Keying off marker ABSENCE alone misread a hand-authored comment-only
/// file as an opt-in — issue #12's detection note.)
bool hasCustomPlatformImpl(String baseDir, String platform, String className) {
  final f = File(p.join(baseDir, platform, 'src', 'Hybrid$className.cpp'));
  if (!f.existsSync()) return false;
  final content = f.readAsStringSync();
  if (content.contains(_implStubTodoMarker)) return false;
  // Strip // and /* */ comments plus preprocessor-free blank lines; anything
  // left is real code (class definitions, method bodies, registration).
  final withoutBlock = content.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final codeLines = withoutBlock
      .split('\n')
      .map((l) {
        final idx = l.indexOf('//');
        return (idx >= 0 ? l.substring(0, idx) : l).trim();
      })
      .where((l) => l.isNotEmpty);
  return codeLines.isNotEmpty;
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
          windowsIsCpp: analyzer.supportsWindows,
          linuxIsCpp: analyzer.supportsLinux,
          windowsRequestsSeparateImpl: analyzer.requestsSeparateWindowsImpl,
          linuxRequestsSeparateImpl: analyzer.requestsSeparateLinuxImpl,
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
