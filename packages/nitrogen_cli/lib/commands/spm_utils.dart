/// SPM (Swift Package Manager) utilities for nitrogen CLI.
///
/// Provides helpers for detecting, validating, and managing SPM configuration
/// in Flutter plugins. Used by init, link, doctor, and migrate commands.
library;

import 'dart:io';
import 'package:path/path.dart' as p;

/// Result of SPM detection for a plugin.
class SpmStatus {
  final bool hasSpm;
  final bool hasCocoaPods;
  final bool iosHasSpm;
  final bool macosHasSpm;
  final bool iosHasPodspec;
  final bool macosHasPodspec;
  final String? iosPackageSwiftPath;
  final String? macosPackageSwiftPath;
  final List<String> issues;
  final List<String> warnings;

  SpmStatus({
    required this.hasSpm,
    required this.hasCocoaPods,
    required this.iosHasSpm,
    required this.macosHasSpm,
    required this.iosHasPodspec,
    required this.macosHasPodspec,
    this.iosPackageSwiftPath,
    this.macosPackageSwiftPath,
    this.issues = const [],
    this.warnings = const [],
  });

  bool get isModern => hasSpm && !hasCocoaPods;
  bool get isMixed => hasSpm && hasCocoaPods;
  bool get isLegacy => hasCocoaPods && !hasSpm;
}

/// Detects SPM and CocoaPods status for a plugin directory.
///
/// Handles both the flat layout (`ios/Package.swift`) and the Flutter 3.41+
/// nested layout (`ios/<pluginName>/Package.swift`).
SpmStatus detectSpmStatus(String baseDir) {
  final iosDir = Directory(p.join(baseDir, 'ios'));
  final macosDir = Directory(p.join(baseDir, 'macos'));

  final iosPackageSwiftPath = _findPackageSwift(iosDir);
  final macosPackageSwiftPath = _findPackageSwift(macosDir);

  final iosHasSpm = iosPackageSwiftPath != null;
  final macosHasSpm = macosPackageSwiftPath != null;

  final iosPodspecs = iosDir.existsSync() ? iosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList() : <File>[];
  final macosPodspecs = macosDir.existsSync() ? macosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList() : <File>[];

  final issues = <String>[];
  final warnings = <String>[];

  // Validate Package.swift structure if present
  if (iosPackageSwiftPath != null) {
    final validation = validatePackageSwift(iosPackageSwiftPath, 'ios');
    issues.addAll(validation.issues);
    warnings.addAll(validation.warnings);
  }
  if (macosPackageSwiftPath != null) {
    final validation = validatePackageSwift(macosPackageSwiftPath, 'macos');
    issues.addAll(validation.issues);
    warnings.addAll(validation.warnings);
  }

  return SpmStatus(
    hasSpm: iosHasSpm || macosHasSpm,
    hasCocoaPods: iosPodspecs.isNotEmpty || macosPodspecs.isNotEmpty,
    iosHasSpm: iosHasSpm,
    macosHasSpm: macosHasSpm,
    iosHasPodspec: iosPodspecs.isNotEmpty,
    macosHasPodspec: macosPodspecs.isNotEmpty,
    iosPackageSwiftPath: iosPackageSwiftPath,
    macosPackageSwiftPath: macosPackageSwiftPath,
    issues: issues,
    warnings: warnings,
  );
}

/// Finds `Package.swift` inside a platform directory.
///
/// Checks both:
///   - Flat layout: `ios/Package.swift`
///   - Nested layout (Flutter 3.41+): `ios/<name>/Package.swift`
///
/// Returns the path to the first found `Package.swift`, or `null` if none.
String? _findPackageSwift(Directory platformDir) {
  if (!platformDir.existsSync()) return null;

  // 1. Flat layout: ios/Package.swift
  final flat = File(p.join(platformDir.path, 'Package.swift'));
  if (flat.existsSync()) return flat.path;

  // 2. Nested layout: ios/<name>/Package.swift (Flutter 3.41+)
  // Only consider directories whose names match Dart pub package naming
  // (lowercase letters, digits, underscores). This skips Flutter infrastructure
  // dirs like FlutterFramework, Classes, Flutter, etc. which may contain
  // Package.swift files that belong to the Flutter SDK, not the plugin.
  final pubNameRe = RegExp(r'^[a-z][a-z0-9_]*$');
  try {
    final entries = platformDir.listSync();
    for (final entry in entries) {
      if (entry is Directory && pubNameRe.hasMatch(p.basename(entry.path))) {
        final nested = File(p.join(entry.path, 'Package.swift'));
        if (nested.existsSync()) return nested.path;
      }
    }
  } catch (_) {}

  return null;
}

/// Returns true if the given [packageSwiftPath] is in a nested Flutter 3.41+
/// layout (`ios/<name>/Package.swift`) rather than the flat `ios/Package.swift`.
bool isNestedSpmPath(String packageSwiftPath) {
  // Count path segments: flat has parent = ios/, nested has parent = ios/<name>/
  final parent = p.dirname(packageSwiftPath);
  final grandParent = p.dirname(parent);
  return p.basename(grandParent) == 'ios' || p.basename(grandParent) == 'macos';
}

/// Validation result for a Package.swift file.
class PackageSwiftValidation {
  final List<String> issues;
  final List<String> warnings;
  final bool hasSwiftTarget;
  final bool hasCppTarget;
  final bool hasCorrectPlatform;
  final bool hasNitroFlags;
  final bool hasFlutterFramework;

  PackageSwiftValidation({
    this.issues = const [],
    this.warnings = const [],
    this.hasSwiftTarget = false,
    this.hasCppTarget = false,
    this.hasCorrectPlatform = false,
    this.hasNitroFlags = false,
    this.hasFlutterFramework = false,
  });
}

/// Validates a Package.swift file for correct Nitro configuration.
PackageSwiftValidation validatePackageSwift(String path, String platform) {
  final file = File(path);
  if (!file.existsSync()) {
    return PackageSwiftValidation(issues: ['$platform/Package.swift not found']);
  }

  final content = file.readAsStringSync();
  final issues = <String>[];
  final warnings = <String>[];

  // Check swift-tools-version
  if (!content.contains('swift-tools-version:')) {
    issues.add('$platform/Package.swift missing swift-tools-version');
  } else if (!RegExp(r'swift-tools-version:\s*5\.[9]').hasMatch(content) && !RegExp(r'swift-tools-version:\s*[6-9]').hasMatch(content)) {
    warnings.add('$platform/Package.swift should use swift-tools-version: 5.9 or later');
  }

  // Check platform version
  final expectedPlatform = platform == 'ios' ? '.iOS(.v13)' : '.macOS(.v10_15)';
  if (!content.contains('.iOS(') && !content.contains('.macOS(')) {
    issues.add('$platform/Package.swift missing platforms declaration');
  }

  // Check for C++ target (needed for Nitro)
  final hasCppTarget = content.contains('Cpp') && content.contains('.target(');
  if (!hasCppTarget) {
    warnings.add('$platform/Package.swift may be missing C++ target for bridges');
  }

  // Check for nitro include path.
  // Three valid layouts:
  //   1. Direct path:  headerSearchPath("…/nitro/src/native")
  //   2. Symlinks:     headerSearchPath("…/.symlinks/plugins/nitro/…")
  //   3. Nitrogen-managed nested SPM layout: nitrogen link copies nitro.h
  //      into Sources/<PluginCpp>/include/ and declares publicHeadersPath: "include".
  //      No explicit nitro path is needed in Package.swift.
  final hasNitroFlags =
      content.contains('nitro/src/native') || content.contains('.symlinks/plugins/nitro') || (content.contains('publicHeadersPath') && content.contains('Sources/'));
  if (!hasNitroFlags) {
    warnings.add('$platform/Package.swift missing nitro header search path');
  }

  // Check for FlutterFramework dependency — required by Flutter SPM tooling.
  final hasFlutterFramework = content.contains('FlutterFramework');
  if (!hasFlutterFramework) {
    issues.add(
      '$platform/Package.swift is missing a dependency on FlutterFramework. '
      'Add .package(name: "FlutterFramework", path: "../FlutterFramework") to dependencies '
      'and .product(name: "FlutterFramework", package: "FlutterFramework") to the Swift target.',
    );
  }

  // Check for Swift target
  final hasSwiftTarget = content.contains('.target(') && !content.replaceAll(RegExp(r'Cpp[^"]*'), '').contains('.target(');

  return PackageSwiftValidation(
    issues: issues,
    warnings: warnings,
    hasSwiftTarget: hasSwiftTarget,
    hasCppTarget: hasCppTarget,
    hasCorrectPlatform: content.contains(expectedPlatform),
    hasNitroFlags: hasNitroFlags,
    hasFlutterFramework: hasFlutterFramework,
  );
}

/// Checks if a Package.swift uses the Flutter 3.41+ nested layout.
bool isNestedSpmLayout(String packageSwiftPath) {
  final file = File(packageSwiftPath);
  if (!file.existsSync()) return false;

  final content = file.readAsStringSync();
  // Flutter 3.41+ nested layout uses Sources/ directory structure
  return content.contains('Sources/') || content.contains('path: "Sources/');
}

/// Gets the Sources directories from a Package.swift.
List<String> getSpmSourcesDirs(String packageSwiftPath) {
  final file = File(packageSwiftPath);
  if (!file.existsSync()) return [];

  final content = file.readAsStringSync();
  final dirs = <String>[];

  // Match path: "Sources/Xxx" patterns
  final pathPattern = RegExp(r'path:\s*"(Sources/[^"]+)"');
  for (final match in pathPattern.allMatches(content)) {
    dirs.add(match.group(1)!);
  }

  return dirs;
}

/// Verifies SPM Sources directory structure is correct.
class SpmSourcesValidation {
  final bool isValid;
  final List<String> missingDirs;
  final List<String> missingSymlinks;
  final List<String> issues;

  SpmSourcesValidation({
    required this.isValid,
    this.missingDirs = const [],
    this.missingSymlinks = const [],
    this.issues = const [],
  });
}

/// Validates the SPM Sources directory structure for a platform.
SpmSourcesValidation validateSpmSourcesStructure(
  String baseDir,
  String platform,
  String className,
) {
  final platformDir = Directory(p.join(baseDir, platform));
  if (!platformDir.existsSync()) {
    return SpmSourcesValidation(isValid: false, issues: ['$platform/ directory not found']);
  }

  final sourcesDir = Directory(p.join(platformDir.path, 'Sources'));
  if (!sourcesDir.existsSync()) {
    return SpmSourcesValidation(isValid: false, issues: ['$platform/Sources/ directory not found']);
  }

  final swiftDir = Directory(p.join(sourcesDir.path, className));
  final cppDir = Directory(p.join(sourcesDir.path, '${className}Cpp'));

  final missingDirs = <String>[];
  final missingSymlinks = <String>[];
  final issues = <String>[];

  if (!swiftDir.existsSync()) {
    missingDirs.add('$platform/Sources/$className');
  }
  if (!cppDir.existsSync()) {
    missingDirs.add('$platform/Sources/${className}Cpp');
  }

  // Check for include directory in Cpp target
  if (cppDir.existsSync()) {
    final includeDir = Directory(p.join(cppDir.path, 'include'));
    final includeLink = Link(p.join(cppDir.path, 'include'));
    if (!includeDir.existsSync() && !includeLink.existsSync()) {
      missingSymlinks.add('$platform/Sources/${className}Cpp/include');
    }
  }

  return SpmSourcesValidation(
    isValid: missingDirs.isEmpty && issues.isEmpty,
    missingDirs: missingDirs,
    missingSymlinks: missingSymlinks,
    issues: issues,
  );
}

/// Ensures [packageSwiftPath] declares FlutterFramework at both the package
/// level (`dependencies: [...]`) and inside the Swift target's dependencies.
/// Idempotent — does nothing when already present.
///
/// Handles both the 2-space indented format written by [swift_templates.dart]
/// and the 4-space indented format written by [scaffold_templates.dart].
///
/// Returns `true` if the file was modified.
bool ensureFlutterFrameworkDependency(String packageSwiftPath) {
  final file = File(packageSwiftPath);
  if (!file.existsSync()) return false;
  var content = file.readAsStringSync();
  if (content.contains('FlutterFramework')) return false;

  bool modified = false;

  // ── 1. Package-level dependencies block ──────────────────────────────────
  // Anything before the first 'targets:' belongs to the Package(...) struct.
  final targetsIdx = content.indexOf('targets:');
  if (targetsIdx == -1) return false;

  final beforeTargets = content.substring(0, targetsIdx);

  if (beforeTargets.contains('dependencies: [')) {
    // Already has a package-level dependencies array — append into it.
    content = content.replaceFirst(
      'dependencies: [',
      'dependencies: [\n    .package(name: "FlutterFramework", path: "../FlutterFramework"),',
    );
  } else {
    // No package-level dependencies — inject one just before targets:.
    // Detect indent (2-space from swift_templates, 4-space from scaffold_templates).
    final indent = content.contains('  targets:') ? '  ' : '    ';
    content = content.replaceFirst(
      '${indent}targets:',
      '${indent}dependencies: [\n$indent  .package(name: "FlutterFramework", path: "../FlutterFramework"),\n$indent],\n${indent}targets:',
    );
  }
  modified = true;

  // ── 2. Swift target's dependencies ───────────────────────────────────────
  // The Cpp target has no dependencies: entry; the Swift target has one.
  // Handle the inline single-item form: dependencies: ["XxxCpp"]
  final inlineDepRe = RegExp(r'dependencies:\s*\["([^"]+)"\]');
  final m = inlineDepRe.firstMatch(content);
  if (m != null) {
    // Detect the leading whitespace of the matched line to preserve alignment.
    final lineStart = content.lastIndexOf('\n', m.start) + 1;
    final lineIndent = RegExp(r'^ *').firstMatch(content.substring(lineStart))?.group(0) ?? '      ';
    final inner = '$lineIndent  ';
    content = content.replaceFirst(
      m.group(0)!,
      'dependencies: [\n$inner"${m.group(1)!}",\n$inner.product(name: "FlutterFramework", package: "FlutterFramework"),\n$lineIndent]',
    );
  }

  if (modified) file.writeAsStringSync(content);
  return modified;
}

/// Converts a plugin name to PascalCase class name.
String toPascalCase(String name) => name.split(RegExp(r'[_\-]')).map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');

/// Returns `true` when the FlutterFramework path declared in [packageSwiftPath]
/// resolves to an existing directory on disk.
///
/// Flutter 3.22+ places the FlutterFramework SPM package in the example app's
/// ephemeral directory. The plugin Package.swift references it via a relative
/// path (`../FlutterFramework`). This path is resolved at build time by the
/// Flutter toolchain, but is not resolvable when opening the plugin project
/// directly in Xcode without a prior `flutter pub get` in the example app.
bool flutterFrameworkPathExists(String packageSwiftPath) {
  final file = File(packageSwiftPath);
  if (!file.existsSync()) return false;
  final content = file.readAsStringSync();

  // Extract the path string from: .package(name: "FlutterFramework", path: "...")
  final match = RegExp(
    r'\.package\s*\(\s*name\s*:\s*"FlutterFramework"\s*,\s*path\s*:\s*"([^"]+)"\s*\)',
  ).firstMatch(content);
  if (match == null) return false;

  final relativePath = match.group(1)!;
  final packageDir = File(packageSwiftPath).parent.path;
  final resolved = p.normalize(p.join(packageDir, relativePath));
  return Directory(resolved).existsSync();
}

/// Attempts to ensure the FlutterFramework package referenced in [packageSwiftPath]
/// is resolvable by creating a symlink at the expected path.
///
/// Search order (relative to [pluginBaseDir]):
///   1. `example/ios/Flutter/ephemeral/Packages/.packages/FlutterFramework` (iOS)
///   2. `example/macos/Flutter/ephemeral/Packages/.packages/FlutterFramework` (macOS)
///
/// Returns `true` when a symlink was created. Returns `false` when the path
/// already resolves, no FlutterFramework could be located, or the operation
/// fails (e.g. symlinks not supported on this OS).
bool ensureFlutterFrameworkSymlink(String packageSwiftPath, String pluginBaseDir) {
  if (flutterFrameworkPathExists(packageSwiftPath)) return false;

  final file = File(packageSwiftPath);
  if (!file.existsSync()) return false;
  final content = file.readAsStringSync();

  final match = RegExp(
    r'\.package\s*\(\s*name\s*:\s*"FlutterFramework"\s*,\s*path\s*:\s*"([^"]+)"\s*\)',
  ).firstMatch(content);
  if (match == null) return false;

  final relativePath = match.group(1)!;
  final packageDir = file.parent.path;
  final targetPath = p.normalize(p.join(packageDir, relativePath));

  // Candidate FlutterFramework locations (both iOS and macOS variants).
  final candidates = [
    p.join(pluginBaseDir, 'example', 'ios', 'Flutter', 'ephemeral', 'Packages', '.packages', 'FlutterFramework'),
    p.join(pluginBaseDir, 'example', 'macos', 'Flutter', 'ephemeral', 'Packages', '.packages', 'FlutterFramework'),
  ];

  for (final candidate in candidates) {
    if (Directory(candidate).existsSync()) {
      try {
        Directory(p.dirname(targetPath)).createSync(recursive: true);
        final relLink = p.relative(candidate, from: p.dirname(targetPath));
        Link(targetPath).createSync(relLink);
        return true;
      } catch (_) {}
    }
  }
  return false;
}

/// Creates the SPM Sources directory structure for a platform.
///
/// Automatically detects whether to use the Flutter 3.41+ nested layout
/// (`ios/<pluginName>/Sources/`) or the legacy flat layout (`ios/Sources/`).
/// When the nested package directory already exists (created by
/// `_createPackageSwift`), it places Sources inside it; otherwise it falls
/// back to the flat layout.
void createSpmSourcesStructure(
  String baseDir,
  String platform,
  String className,
  String pluginName,
) {
  final platformDir = Directory(p.join(baseDir, platform));
  if (!platformDir.existsSync()) return;

  // Detect layout: nested (Flutter 3.41+) vs flat
  final nestedPackageDir = Directory(p.join(platformDir.path, pluginName));
  final bool useNested = nestedPackageDir.existsSync();

  final packageRoot = useNested ? nestedPackageDir.path : platformDir.path;
  // Symlink depth: nested → 3 levels up (ios/<plugin>/Sources/<Target>/ → ios/Classes/)
  //                flat  → 2 levels up (ios/Sources/<Target>/ → ios/Classes/)
  final String classesRelPath = useNested ? '../../../Classes' : '../../Classes';

  final sourcesDir = Directory(p.join(packageRoot, 'Sources'));
  final swiftDir = Directory(p.join(sourcesDir.path, className));
  final cppDir = Directory(p.join(sourcesDir.path, '${className}Cpp'));

  swiftDir.createSync(recursive: true);
  cppDir.createSync(recursive: true);

  // Create symlinks in Swift target
  final swiftSymlinks = [
    'Swift${className}Plugin.swift',
    '${className}Impl.swift',
    '$pluginName.bridge.g.swift',
  ];
  for (final name in swiftSymlinks) {
    final lnk = Link(p.join(swiftDir.path, name));
    if (!lnk.existsSync()) {
      try {
        lnk.createSync('$classesRelPath/$name');
      } catch (_) {
        // Symlink may fail on Windows, ignore
      }
    }
  }

  // Create symlinks in Cpp target
  final cppSymlinks = ['$pluginName.cpp', 'dart_api_dl.c'];
  for (final name in cppSymlinks) {
    final lnk = Link(p.join(cppDir.path, name));
    if (!lnk.existsSync()) {
      try {
        lnk.createSync('$classesRelPath/$name');
      } catch (_) {}
    }
  }

  // Create include symlink
  final includeLink = Link(p.join(cppDir.path, 'include'));
  if (!includeLink.existsSync()) {
    try {
      includeLink.createSync(classesRelPath);
    } catch (_) {}
  }
}
