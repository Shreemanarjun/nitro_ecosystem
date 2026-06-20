import 'dart:io';

import 'package:nitrogen_cli/commands/scaffold_templates.dart' as legacy_scaffold;
import 'package:nitrogen_cli/templates/build_versions.dart';
import 'package:nitrogen_cli/templates/cmake_templates.dart' as cmake;
import 'package:nitrogen_cli/templates/podspec_templates.dart' as podspec;
import 'package:nitrogen_cli/templates/scaffold_templates.dart' as scaffold;
import 'package:nitrogen_cli/templates/swift_templates.dart' as swift;
import 'package:test/test.dart';

Directory _packageLibDir() {
  final packageDir = Directory('lib');
  if (File('${packageDir.path}/templates/build_versions.dart').existsSync()) {
    return packageDir;
  }
  return Directory('packages/nitrogen_cli/lib');
}

void main() {
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
      final root = _packageLibDir();
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
