import 'dart:convert';
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
    final decoded = jsonDecode(cfg.readAsStringSync());
    if (decoded is! Map<String, Object?>) return null;
    final packages = decoded['packages'];
    if (packages is! List) return null;
    Map<String, Object?>? packageEntry;
    for (final entry in packages.cast<Object?>().whereType<Map<String, Object?>>()) {
      if (entry['name'] == 'nitrogen_cli') {
        packageEntry = entry;
        break;
      }
    }
    if (packageEntry == null) return null;
    final rootUriValue = packageEntry['rootUri'];
    if (rootUriValue is! String || rootUriValue.isEmpty) return null;
    final uri = cfg.uri.resolve(rootUriValue);
    final pkgPath = uri.toFilePath();
    final libDir = Directory(p.join(pkgPath, 'lib'));
    if (libDir.existsSync()) return libDir;
  } catch (_) {}
  return null;
}

Directory _resolvePackageLibDir() {
  // Strategy 1 – Platform.packageConfig (set by Dart VM, independent of CWD).
  final pkgCfgUri = Platform.packageConfig;
  if (pkgCfgUri != null) {
    final cfg = File(p.fromUri(pkgCfgUri));
    if (cfg.existsSync()) {
      final fromPkg = _libDirFromPackageConfig(cfg);
      if (fromPkg != null) return fromPkg;
    }
  }

  // Strategy 2 – PACKAGE_CONFIG env var.
  final packageConfigPath = Platform.environment['PACKAGE_CONFIG'];
  if (packageConfigPath != null && packageConfigPath.isNotEmpty) {
    final cfg = File(packageConfigPath);
    if (cfg.existsSync()) {
      final fromPkg = _libDirFromPackageConfig(cfg);
      if (fromPkg != null) return fromPkg;
    }
  }

  // Strategy 3 – walk up from Platform.script.
  var dir = p.dirname(p.fromUri(Platform.script));
  for (var i = 0; i < 20; i++) {
    if (File(p.join(dir, 'lib', 'templates', 'build_versions.dart')).existsSync()) {
      return Directory(p.join(dir, 'lib'));
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }

  // Strategy 4 – walk up from CWD.
  dir = Directory.current.path;
  for (var i = 0; i < 20; i++) {
    if (File(p.join(dir, 'lib', 'templates', 'build_versions.dart')).existsSync()) {
      return Directory(p.join(dir, 'lib'));
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }

  // Strategy 5 – walk up from CWD looking for .dart_tool/package_config.json.
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

  // Strategy 6 – BFS from HOME: search downward through the directory tree.
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    try {
      final queue = <String>[home];
      for (var depth = 0; depth < 5 && queue.isNotEmpty; depth++) {
        final nextQueue = <String>[];
        for (final d in queue) {
          final cfg = File(p.join(d, '.dart_tool', 'package_config.json'));
          if (cfg.existsSync()) {
            final fromPkg = _libDirFromPackageConfig(cfg);
            if (fromPkg != null) return fromPkg;
          }
          try {
            for (final entity in Directory(d).listSync(followLinks: false)) {
              if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
                nextQueue.add(entity.path);
              }
            }
          } catch (_) {}
        }
        queue.addAll(nextQueue);
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
  _resolvedLibDirPath = _packageLibDir.path;

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

    test('Android scaffold builds under Flutter and under a host with a trimmed embedding (DartNative)', () {
      final gradle = scaffold.androidBuildGradleTemplate('com.example', 'camera');
      // Kotlin is applied only where the host gave the project none.
      expect(gradle, contains('if (extensions.findByName("kotlin") == null) {\n    pluginManager.apply("org.jetbrains.kotlin.android")\n}'));
      // Flutter reads the file for these two shapes; a match makes it leave
      // Kotlin to the plugin and warn that the plugin applies KGP. (The
      // patterns are kgpRegexGroovy in Flutter's FlutterPluginUtils.kt.)
      final applyLine = RegExp(r'''^[ \t]*apply[ \t]+plugin[ \t]*:[ \t]*(['"])(?:kotlin-android|org\.jetbrains\.kotlin\.android)\1''', multiLine: true);
      final pluginsBlockId = RegExp(r'''^[ \t]*plugins[ \t]*\{[^{}]*?(?<=[\n{])[ \t]*(?:id|alias)(?:[ \t]*\(\s*|[ \t]+)['"](?:kotlin-android|org\.jetbrains\.kotlin\.android)['"]''', multiLine: true);
      expect(applyLine.hasMatch(gradle), isFalse);
      expect(pluginsBlockId.hasMatch(gradle), isFalse);
      // The same patterns do catch the shapes Flutter warns about.
      expect(applyLine.hasMatch('apply plugin: "kotlin-android"\n'), isTrue);
      expect(pluginsBlockId.hasMatch('plugins {\n    id "org.jetbrains.kotlin.android"\n}\n'), isTrue);

      final plugin = scaffold.androidPluginKtTemplate('com.example', 'camera', 'Camera', 'camera_module');
      // DartNative's embedding has FlutterPlugin but no plugins.activity package.
      expect(plugin, contains('class CameraPlugin : FlutterPlugin {'));
      expect(plugin, isNot(contains('plugins.activity')));
      expect(plugin, isNot(contains('ActivityPluginBinding')));
      // The Activity still reaches the bridge, once per Activity.
      expect(plugin, contains('app.registerActivityLifecycleCallbacks(this)'));
      expect(plugin, contains('CameraJniBridge.onActivityAttached(activity)'));
      expect(plugin, contains('CameraJniBridge.onActivityDetached()'));
      expect(plugin, contains('CameraJniBridge.registerFactory({ CameraImpl() }, binding.applicationContext)'));
    });

    test('Swift plugin class registers the implementation with or without register(with:)', () {
      for (final plugin in [scaffold.iosSwiftPluginTemplate('Camera'), scaffold.macosSwiftPluginTemplate('Camera')]) {
        // The generated registry looks for a class that adopts the provider
        // when nothing registered an implementation (DartNative never calls
        // the plugin registrant).
        expect(plugin, contains('public class SwiftCameraPlugin: NSObject, FlutterPlugin, CameraImplementationProvider {'));
        expect(plugin, contains('    public static func registerCameraImplementation() {\n        CameraRegistry.register(CameraImpl())\n    }'));
        // Flutter's path goes through the same method: one place creates the impl.
        expect(plugin, contains('    public static func register(with registrar: FlutterPluginRegistrar) {\n        registerCameraImplementation()\n    }'));
        expect('CameraRegistry.register('.allMatches(plugin), hasLength(1));
      }
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
