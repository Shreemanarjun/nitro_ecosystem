import 'dart:io';

import 'package:nitrogen_cli/commands/scaffold_templates.dart' as legacy_scaffold;
import 'package:nitrogen_cli/templates/build_versions.dart';
import 'package:nitrogen_cli/templates/cmake_templates.dart' as cmake;
import 'package:nitrogen_cli/templates/podspec_templates.dart' as podspec;
import 'package:nitrogen_cli/templates/scaffold_templates.dart' as scaffold;
import 'package:nitrogen_cli/templates/swift_templates.dart' as swift;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Try to extract the nitrogen_cli lib dir from a `package_config.json`.
Directory? _libDirFromPackageConfig(File cfg) {
  try {
    final json = cfg.readAsStringSync();
    final idx = json.indexOf('"nitrogen_cli"');
    if (idx == -1) return null;
    final rootIdx = json.lastIndexOf('"rootUri"', idx);
    if (rootIdx == -1) return null;
    final start = json.indexOf('"', rootIdx + 9) + 1;
    final end = json.indexOf('"', start);
    final uri = Uri.parse(json.substring(start, end));
    final pkgPath = uri.toFilePath();
    final libDir = Directory(p.join(pkgPath, 'lib'));
    if (libDir.existsSync()) return libDir;
  } catch (_) {}
  return null;
}

Directory _resolvePackageLibDir() {
  // Strategy 1 – walk up from CWD.
  var dir = Directory.current.path;
  for (var i = 0; i < 20; i++) {
    if (File(p.join(dir, 'lib', 'templates', 'build_versions.dart')).existsSync()) {
      return Directory(p.join(dir, 'lib'));
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }

  // Strategy 2 – walk up from Platform.script.
  dir = p.dirname(p.fromUri(Platform.script));
  for (var i = 0; i < 20; i++) {
    if (File(p.join(dir, 'lib', 'templates', 'build_versions.dart')).existsSync()) {
      return Directory(p.join(dir, 'lib'));
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }

  // Strategy 3 – PACKAGE_CONFIG env var.
  final packageConfigPath = Platform.environment['PACKAGE_CONFIG'];
  if (packageConfigPath != null && packageConfigPath.isNotEmpty) {
    final cfg = File(packageConfigPath);
    if (cfg.existsSync()) {
      final fromPkg = _libDirFromPackageConfig(cfg);
      if (fromPkg != null) return fromPkg;
    }
  }

  // Strategy 4 – walk up from CWD looking for .dart_tool/package_config.json.
  dir = Directory.current.path;
  for (var i = 0; i < 20; i++) {
    final cfg = File(p.join(dir, '.dart_tool', 'package_config.json'));
    if (cfg.existsSync()) {
      final fromPkg = _libDirFromPackageConfig(cfg);
      if (fromPkg != null) return fromPkg;
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }

  // Strategy 5 – search from HOME: list first-level subdirectories and
  // walk up from each looking for .dart_tool/package_config.json.
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    // Check HOME itself first.
    var d = home;
    for (var i = 0; i < 20; i++) {
      final cfg = File(p.join(d, '.dart_tool', 'package_config.json'));
      if (cfg.existsSync()) {
        final fromPkg = _libDirFromPackageConfig(cfg);
        if (fromPkg != null) return fromPkg;
      }
      final parent = p.dirname(d);
      if (parent == d) break;
      d = parent;
    }
    // Also search first-level subdirectories of HOME.
    try {
      for (final entity in Directory(home).listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        d = entity.path;
        for (var i = 0; i < 10; i++) {
          final cfg = File(p.join(d, '.dart_tool', 'package_config.json'));
          if (cfg.existsSync()) {
            final fromPkg = _libDirFromPackageConfig(cfg);
            if (fromPkg != null) return fromPkg;
          }
          final parent = p.dirname(d);
          if (parent == d) break;
          d = parent;
        }
      }
    } catch (_) {}
  }

  return Directory('lib');
}

// Eagerly resolve at library load time, before any test can corrupt CWD.
final Directory _packageLibDir = _resolvePackageLibDir();

// Must be resolved eagerly before any test can corrupt Directory.current.
String? _resolvedLibDirPath;

void main() {
  _resolvedLibDirPath = _resolvePackageLibDir().path;

  group('BuildVersions', () {
    test('scaffold templates use centralized build versions', () {
      final cmakeOut = scaffold.cmakeListsTemplate('camera');
      expect(cmakeOut, contains('cmake_minimum_required(VERSION ${BuildVersions.cmakeMinimum})'));
      expect(cmakeOut, contains('set(CMAKE_CXX_STANDARD ${BuildVersions.cmakeCxxStandard})'));

      final packageOut = scaffold.packageSwiftTemplate(
        'camera',
        'Camera',
        BuildVersions.iosPlatformSpec,
      );
      expect(packageOut, contains('// swift-tools-version: ${BuildVersions.swiftTools}'));
      expect(packageOut, contains('platforms: [.${BuildVersions.iosPlatformSpec}]'));
      expect(packageOut, contains('.unsafeFlags(["${BuildVersions.spmCxxFlag}"])'));

      final gradleOut = scaffold.androidBuildGradleTemplate('com.example', 'camera');
      expect(gradleOut, contains('compileSdk = ${BuildVersions.androidCompileSdk}'));
      expect(gradleOut, contains('ndkVersion = "${BuildVersions.androidNdk}"'));
      expect(gradleOut, contains('JavaVersion.${BuildVersions.androidJavaVersion}'));
      expect(gradleOut, contains('jvmTarget = "${BuildVersions.androidJvmTarget}"'));
      expect(gradleOut, contains('minSdk = ${BuildVersions.androidMinSdk}'));
      expect(gradleOut, contains('kotlinx-coroutines-core:${BuildVersions.kotlinCoroutines}'));
    });

    test('legacy command scaffold template mirrors centralized values', () {
      final cmakeOut = legacy_scaffold.cmakeListsTemplate('camera');
      expect(cmakeOut, contains('cmake_minimum_required(VERSION ${BuildVersions.cmakeMinimum})'));
      expect(cmakeOut, contains('set(CMAKE_CXX_STANDARD ${BuildVersions.cmakeCxxStandard})'));

      final gradleOut = legacy_scaffold.androidBuildGradleTemplate('com.example', 'camera');
      expect(gradleOut, contains('ndkVersion = "${BuildVersions.androidNdk}"'));
      expect(gradleOut, contains('jvmTarget = "${BuildVersions.androidJvmTarget}"'));
    });

    test('link templates use centralized CMake, Swift, and podspec versions', () {
      final linkCmake = cmake.generateCMakeContent('camera', ['camera'], '/nitro/native');
      expect(linkCmake, contains('cmake_minimum_required(VERSION ${BuildVersions.cmakeMinimum})'));
      expect(linkCmake, contains('set(CMAKE_CXX_STANDARD ${BuildVersions.cmakeCxxStandard})'));

      final iosPackage = swift.iosPackageSwiftContent('camera', 'Camera');
      expect(iosPackage, contains('// swift-tools-version: ${BuildVersions.swiftTools}'));
      expect(iosPackage, contains('platforms: [.${BuildVersions.iosPlatformSpec}]'));
      expect(iosPackage, contains('.unsafeFlags(["${BuildVersions.spmCxxFlag}"])'));

      final macosPackage = swift.macosPackageSwiftContent('camera', 'Camera');
      expect(macosPackage, contains('platforms: [.${BuildVersions.macosPlatformSpec}]'));

      expect(podspec.iosPodTargetXcconfig, contains("'CLANG_CXX_LANGUAGE_STANDARD' => '${BuildVersions.podCxxStandard}'"));
      expect(podspec.macosPodTargetXcconfig, contains("'CLANG_CXX_LANGUAGE_STANDARD' => '${BuildVersions.podCxxStandard}'"));
    });

    test('nitrogen_cli lib does not hardcode centralized build versions outside constants', () {
      final root = Directory(_resolvedLibDirPath!);
      final offenders = <String>[];
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        if (file.path.endsWith('build_versions.dart')) continue;
        final source = file.readAsStringSync();
        for (final literal in const [
          'swift-tools-version: 5.9',
          'iOS(.v13)',
          'macOS(.v10_15)',
          'CMAKE_CXX_STANDARD 17',
          'ndkVersion = "27.0.12077973"',
          'JavaVersion.VERSION_17',
          'jvmTarget = "17"',
          '-std=c++17',
          "s.swift_version = '5.9'",
        ]) {
          if (source.contains(literal)) {
            offenders.add('${file.path}: $literal');
          }
        }
      }

      expect(offenders, isEmpty);
    });
  });
}
