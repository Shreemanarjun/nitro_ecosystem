/// Integration tests for the `nitrogen init`, `generate`, and `link` commands.
///
/// These tests use `test_projects/testing_project` as the canonical fixture —
/// a plugin that was created by `nitrogen init`, had `nitrogen generate` run on
/// it, and then `nitrogen link` applied.  We verify:
///
///   1. Scaffold templates produce the expected content (pure-Dart, no I/O).
///   2. The fixture has the correct file structure (init + generate + link).
///   3. Running the link functions on a temp copy produces the expected output.
///   4. A full scaffold-from-scratch produces a structurally correct plugin.
library;

import 'dart:io';

import 'package:nitrogen_cli/commands/link_command.dart'
    show linkSwiftPlugin, linkMacosSwiftPlugin, linkKotlinPlugin, linkKotlinLoadLibraries, linkPodspec, createSharedHeaders, ModuleInfo;
import 'package:nitrogen_cli/commands/scaffold_templates.dart';
import 'package:nitrogen_cli/templates/native_headers.dart' show bundledDartApiDlContent;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Whether [dir] looks like the monorepo root (has workspace pubspec + fixture).
bool _isRepoRoot(String dir) {
  final pubspec = File(p.join(dir, 'pubspec.yaml'));
  return pubspec.existsSync() &&
      pubspec.readAsStringSync().contains('workspace:') &&
      Directory(p.join(dir, 'test_projects', 'testing_project')).existsSync();
}

/// Walk up from [start] looking for the monorepo root.
String? _walkUpForRepoRoot(String start) {
  var dir = start;
  for (var i = 0; i < 20; i++) {
    if (_isRepoRoot(dir)) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}

/// Try to extract the repo root from a `.dart_tool/package_config.json` file.
String? _repoRootFromPackageConfig(File cfg) {
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
    final candidate = p.normalize(p.join(pkgPath, '..', '..'));
    return _isRepoRoot(candidate) ? candidate : null;
  } catch (_) {
    return null;
  }
}

String _resolveRepoRoot() {
  // Strategy 1 – walk up from the test-file location.
  final fromScript = _walkUpForRepoRoot(p.dirname(p.fromUri(Platform.script)));
  if (fromScript != null) return fromScript;

  // Strategy 2 – walk up from CWD (may be corrupted in combined runs).
  final fromCwd = _walkUpForRepoRoot(Directory.current.path);
  if (fromCwd != null) return fromCwd;

  // Strategy 3 – PACKAGE_CONFIG env var (set by dart/flutter test runner).
  final packageConfigPath = Platform.environment['PACKAGE_CONFIG'];
  if (packageConfigPath != null && packageConfigPath.isNotEmpty) {
    final cfg = File(packageConfigPath);
    if (cfg.existsSync()) {
      final fromPkgCfg = _repoRootFromPackageConfig(cfg);
      if (fromPkgCfg != null) return fromPkgCfg;
    }
  }

  // Strategy 4 – search for .dart_tool/package_config.json walking up from
  // the script directory.
  var dir = p.dirname(p.fromUri(Platform.script));
  for (var i = 0; i < 20; i++) {
    final cfg = File(p.join(dir, '.dart_tool', 'package_config.json'));
    if (cfg.existsSync()) {
      final fromPkgCfg = _repoRootFromPackageConfig(cfg);
      if (fromPkgCfg != null) return fromPkgCfg;
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }

  // Strategy 5 – search from CWD for .dart_tool/package_config.json.
  dir = Directory.current.path;
  for (var i = 0; i < 20; i++) {
    final cfg = File(p.join(dir, '.dart_tool', 'package_config.json'));
    if (cfg.existsSync()) {
      final fromPkgCfg = _repoRootFromPackageConfig(cfg);
      if (fromPkgCfg != null) return fromPkgCfg;
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }

  // Strategy 6 – search from HOME: list first-level subdirectories and
  // walk up from each looking for .dart_tool/package_config.json.
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    // Check HOME itself first.
    var d = home;
    for (var i = 0; i < 20; i++) {
      final cfg = File(p.join(d, '.dart_tool', 'package_config.json'));
      if (cfg.existsSync()) {
        final fromPkgCfg = _repoRootFromPackageConfig(cfg);
        if (fromPkgCfg != null) return fromPkgCfg;
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
            final fromPkgCfg = _repoRootFromPackageConfig(cfg);
            if (fromPkgCfg != null) return fromPkgCfg;
          }
          final parent = p.dirname(d);
          if (parent == d) break;
          d = parent;
        }
      }
    } catch (_) {}
  }

  // Last resort.
  return Directory.current.path;
}

// Eagerly resolve at library load time, before any test can corrupt CWD.
final String _repoRoot = _resolveRepoRoot();

/// The pre-built fixture project under test_projects/.
Directory get _fixture => Directory(p.join(_repoRoot, 'test_projects', 'testing_project'));

/// The local nitro package native sources path (used to seed headers).
String get _nitroNativePath => p.join(_repoRoot, 'packages', 'nitro', 'src', 'native');

/// Copies [src] recursively to [dst], following symlinks for files.
void _copyDir(Directory src, Directory dst) {
  if (!dst.existsSync()) dst.createSync(recursive: true);
  for (final entry in src.listSync(recursive: false, followLinks: false)) {
    final rel = p.relative(entry.path, from: src.path);
    final target = p.join(dst.path, rel);
    if (entry is Link) {
      final linkTarget = entry.targetSync();
      Link(target).createSync(linkTarget);
    } else if (entry is Directory) {
      _copyDir(entry, Directory(target));
    } else if (entry is File) {
      File(target).writeAsBytesSync(entry.readAsBytesSync());
    }
  }
}

/// Creates a minimal plugin scaffold inside [root] that mirrors what
/// `flutter create --template=plugin_ffi` + `nitrogen init` would produce.
/// Does NOT require the Flutter SDK.
void _scaffoldPlugin(Directory root, String name, String org) {
  final className = name.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');

  // pubspec.yaml
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: $name
version: 0.0.1
environment:
  sdk: ^3.0.0
  flutter: '>=3.3.0'
dependencies:
  flutter:
    sdk: flutter
  nitro: ^0.3.3
  plugin_platform_interface: ^2.0.2
dev_dependencies:
  flutter_test:
    sdk: flutter
  nitro_generator: ^0.3.3
flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
      ios:
        ffiPlugin: true
      macos:
        ffiPlugin: true
''');

  // src/
  final srcDir = Directory(p.join(root.path, 'src'))..createSync(recursive: true);
  File(p.join(srcDir.path, '$name.cpp')).writeAsStringSync(pluginCppTemplate(name));
  File(p.join(srcDir.path, 'dart_api_dl.c')).writeAsStringSync(bundledDartApiDlContent);
  File(p.join(srcDir.path, 'CMakeLists.txt')).writeAsStringSync(cmakeListsTemplate(name));

  // ios/Classes/
  final iosClasses = Directory(p.join(root.path, 'ios', 'Classes'))..createSync(recursive: true);
  File(p.join(iosClasses.path, '$name.cpp')).writeAsStringSync('#include "../../src/$name.cpp"\n');
  File(p.join(iosClasses.path, 'dart_api_dl.c')).writeAsStringSync('// Forwarder\n#include "../../src/dart_api_dl.c"\n');
  File(p.join(iosClasses.path, 'Swift${className}Plugin.swift')).writeAsStringSync(iosSwiftPluginTemplate(className));
  File(p.join(iosClasses.path, '${className}Impl.swift')).writeAsStringSync(iosSwiftImplTemplate(className));

  // ios/Classes/<name>.bridge.g.swift symlink (dangling before generate)
  Link(p.join(iosClasses.path, '$name.bridge.g.swift')).createSync('../../lib/src/generated/swift/$name.bridge.g.swift');

  // ios/<name>/Package.swift (nested SPM layout)
  final iosPackageDir = Directory(p.join(root.path, 'ios', name))..createSync(recursive: true);
  final iosSwiftSrc = Directory(p.join(iosPackageDir.path, 'Sources', className))..createSync(recursive: true);
  final iosCppSrc = Directory(p.join(iosPackageDir.path, 'Sources', '${className}Cpp'))..createSync(recursive: true);
  Directory(p.join(iosCppSrc.path, 'include')).createSync(recursive: true);

  // SPM symlinks
  for (final fn in ['Swift${className}Plugin.swift', '${className}Impl.swift', '$name.bridge.g.swift']) {
    try {
      Link(p.join(iosSwiftSrc.path, fn)).createSync('../../../Classes/$fn');
    } catch (_) {}
  }
  File(p.join(iosCppSrc.path, '$name.cpp')).writeAsStringSync('// Generated by nitrogen init\n#include "../../../Classes/$name.cpp"\n');
  File(p.join(iosCppSrc.path, 'dart_api_dl.c')).writeAsStringSync(bundledDartApiDlContent);
  // bridge.g.mm — created by nitrogen init; nitrogen link rewrites with resolved paths.
  File(p.join(iosCppSrc.path, '$name.bridge.g.mm')).writeAsStringSync(
    '// Generated by nitrogen init — do not edit.\n'
    '#import <Foundation/Foundation.h>\n'
    '#include "../../../../lib/src/generated/cpp/$name.bridge.g.cpp"\n',
  );
  File(p.join(iosPackageDir.path, 'Package.swift')).writeAsStringSync(packageSwiftTemplate(name, className, 'iOS(.v13)'));

  // macos/Classes/ + macos/<name>/Package.swift
  final macosClasses = Directory(p.join(root.path, 'macos', 'Classes'))..createSync(recursive: true);
  File(p.join(macosClasses.path, '$name.cpp')).writeAsStringSync('#include "../../src/$name.cpp"\n');
  File(p.join(macosClasses.path, 'dart_api_dl.c')).writeAsStringSync('// Forwarder\n#include "../../src/dart_api_dl.c"\n');
  File(p.join(macosClasses.path, 'Swift${className}Plugin.swift')).writeAsStringSync(macosSwiftPluginTemplate(className));
  File(p.join(macosClasses.path, '${className}Impl.swift')).writeAsStringSync(macosSwiftImplTemplate(className));
  Link(p.join(macosClasses.path, '$name.bridge.g.swift')).createSync('../../lib/src/generated/swift/$name.bridge.g.swift');

  final macosPackageDir = Directory(p.join(root.path, 'macos', name))..createSync(recursive: true);
  final macosSwiftSrc = Directory(p.join(macosPackageDir.path, 'Sources', className))..createSync(recursive: true);
  final macosCppSrc = Directory(p.join(macosPackageDir.path, 'Sources', '${className}Cpp'))..createSync(recursive: true);
  Directory(p.join(macosCppSrc.path, 'include')).createSync(recursive: true);

  for (final fn in ['Swift${className}Plugin.swift', '${className}Impl.swift', '$name.bridge.g.swift']) {
    try {
      Link(p.join(macosSwiftSrc.path, fn)).createSync('../../../Classes/$fn');
    } catch (_) {}
  }
  File(p.join(macosCppSrc.path, '$name.cpp')).writeAsStringSync('// Generated by nitrogen init\n#include "../../../Classes/$name.cpp"\n');
  File(p.join(macosCppSrc.path, 'dart_api_dl.c')).writeAsStringSync(bundledDartApiDlContent);
  // bridge.g.mm — created by nitrogen init; nitrogen link rewrites with resolved paths.
  File(p.join(macosCppSrc.path, '$name.bridge.g.mm')).writeAsStringSync(
    '// Generated by nitrogen init — do not edit.\n'
    '#import <Foundation/Foundation.h>\n'
    '#include "../../../../lib/src/generated/cpp/$name.bridge.g.cpp"\n',
  );
  File(p.join(macosPackageDir.path, 'Package.swift')).writeAsStringSync(packageSwiftTemplate(name, className, 'macOS(.v10_15)', isMacos: true));

  // android/
  final orgPath = org.replaceAll('.', p.separator);
  final kotlinDir = Directory(p.join(root.path, 'android', 'src', 'main', 'kotlin', orgPath, name))..createSync(recursive: true);
  final moduleName = '${name}_module';
  File(p.join(root.path, 'android', 'build.gradle')).writeAsStringSync(androidBuildGradleTemplate(org, name));
  File(p.join(kotlinDir.path, '${className}Plugin.kt')).writeAsStringSync(androidPluginKtTemplate(org, name, className, moduleName));
  File(p.join(kotlinDir.path, '${className}Impl.kt')).writeAsStringSync(androidImplKtTemplate(org, name, className, moduleName));

  // lib/src/<name>.native.dart
  final libSrc = Directory(p.join(root.path, 'lib', 'src'))..createSync(recursive: true);
  const annotation = '@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)';
  File(p.join(libSrc.path, '$name.native.dart')).writeAsStringSync(nativeDartTemplate(name, className, annotation));
  File(p.join(root.path, 'lib', '$name.dart')).writeAsStringSync("export 'src/$name.native.dart';\n");

  // lib/src/generated/swift + cpp + kotlin (stubs — link will populate include/)
  Directory(p.join(libSrc.path, 'generated', 'swift')).createSync(recursive: true);
  Directory(p.join(libSrc.path, 'generated', 'cpp')).createSync(recursive: true);
  Directory(p.join(libSrc.path, 'generated', 'kotlin')).createSync(recursive: true);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  // Eagerly resolve paths before any test can corrupt Directory.current.
  // ignore: unused_local_variable
  final repoRoot = _repoRoot;

  // ── 1. Scaffold template content ─────────────────────────────────────────────

  group('nitrogen init — scaffold template content', () {
    const name = 'my_plugin';
    const className = 'MyPlugin';
    const org = 'com.example';

    test('pluginCppTemplate references correct bridge header', () {
      final out = pluginCppTemplate(name);
      expect(out, contains('#include "nitro.h"'));
      expect(out, contains('"../lib/src/generated/cpp/$name.bridge.g.h"'));
    });

    test('cmakeListsTemplate sets NITRO_NATIVE variable', () {
      final out = cmakeListsTemplate(name);
      expect(out, contains('set(NITRO_NATIVE'));
      expect(out, contains('set(CMAKE_CXX_STANDARD 17)'));
      expect(out, contains('set(CMAKE_CXX_STANDARD_REQUIRED ON)'));
      expect(out, contains('add_library($name SHARED'));
      expect(out, contains('$name.bridge.g.cpp'));
      expect(out, contains('dart_api_dl.c'));
    });

    test('iOS swift plugin template registers implementation', () {
      final out = iosSwiftPluginTemplate(className);
      expect(out, contains('class Swift${className}Plugin'));
      expect(out, contains('FlutterPlugin'));
      expect(out, contains('${className}Registry.register(${className}Impl())'));
    });

    test('iOS swift impl template implements protocol', () {
      final out = iosSwiftImplTemplate(className);
      expect(out, contains('class ${className}Impl'));
      expect(out, contains('Hybrid${className}Protocol'));
      expect(out, contains('func add(a: Double, b: Double) -> Double'));
      expect(out, contains('func getGreeting(name: String) async throws -> String'));
    });

    test('macOS swift plugin template registers implementation', () {
      final out = macosSwiftPluginTemplate(className);
      expect(out, contains('class Swift${className}Plugin'));
      expect(out, contains('FlutterMacOS'));
      expect(out, contains('${className}Registry.register(${className}Impl())'));
    });

    test('packageSwiftTemplate — iOS nested layout', () {
      final out = packageSwiftTemplate(name, className, 'iOS(.v13)');
      expect(out, contains('swift-tools-version: 5.9'));
      expect(out, contains('.iOS(.v13)'));
      expect(out, contains('name: "$name"'));
      expect(out, contains('"${className}Cpp"'));
      // Swift target is named after pluginName (snake_case), path uses className
      expect(out, contains('"$name"'));
      expect(out, contains('Sources/${className}Cpp'));
      expect(out, contains('Sources/$className'));
      expect(out, contains('publicHeadersPath: "include"'));
      expect(out, contains('.unsafeFlags(["-std=c++17"])'));
    });

    test('packageSwiftTemplate — macOS nested layout', () {
      final out = packageSwiftTemplate(name, className, 'macOS(.v10_15)', isMacos: true);
      expect(out, contains('.macOS(.v10_15)'));
      expect(out, isNot(contains('.iOS')));
    });

    test('androidBuildGradleTemplate uses correct package and ndk settings', () {
      final out = androidBuildGradleTemplate(org, name);
      expect(out, contains('namespace = "$org.$name"'));
      expect(out, contains('externalNativeBuild'));
      expect(out, contains('cmake { path = "../src/CMakeLists.txt" }'));
      expect(out, contains('kotlin.srcDirs'));
      // Must NOT use java.srcDirs for kotlin (AGP 8.x bug)
      expect(out, isNot(contains('java.srcDirs = [\'src/main/kotlin\']')));
    });

    test('androidPluginKtTemplate uses JniBridge and registers impl', () {
      const moduleName = 'my_plugin_module';
      final out = androidPluginKtTemplate(org, name, className, moduleName);
      expect(out, contains('package $org.$name'));
      expect(out, contains('${className}JniBridge'));
      expect(out, contains('System.loadLibrary("$name")'));
      // registerFactory is the JniBridge's only registration API since the
      // multi-instance registry - plain register(impl) no longer compiles.
      expect(out, contains('${className}JniBridge.registerFactory('));
    });

    test('androidImplKtTemplate implements the spec interface', () {
      const moduleName = 'my_plugin_module';
      final out = androidImplKtTemplate(org, name, className, moduleName);
      expect(out, contains('package $org.$name'));
      expect(out, contains('class ${className}Impl'));
      expect(out, contains('Hybrid${className}Spec'));
      expect(out, contains('override fun add(a: Double, b: Double): Double'));
    });

    test('nativeDartTemplate generates correct @NitroModule spec', () {
      const annotation = '@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)';
      final out = nativeDartTemplate(name, className, annotation);
      expect(out, contains("import 'package:nitro/nitro.dart'"));
      expect(out, contains("part '$name.g.dart'"));
      expect(out, contains(annotation));
      expect(out, contains('abstract class $className extends HybridObject'));
      expect(out, contains('double add(double a, double b)'));
      expect(out, contains('Future<String> getGreeting(String name)'));
    });
  });

  // ── 2. nitrogen init — fixture file structure ─────────────────────────────────

  group('nitrogen init — testing_project fixture structure', skip: _fixture.existsSync() ? null : 'test_projects/testing_project not found — run from monorepo root', () {
    test('pubspec.yaml declares nitro dependency', () {
      final pubspec = File(p.join(_fixture.path, 'pubspec.yaml'));
      expect(pubspec.existsSync(), isTrue);
      final content = pubspec.readAsStringSync();
      expect(content, contains('name: testing_project'));
      expect(content, contains('nitro'));
    });

    test('src/CMakeLists.txt exists with correct structure', () {
      final cmake = File(p.join(_fixture.path, 'src', 'CMakeLists.txt'));
      expect(cmake.existsSync(), isTrue);
      final content = cmake.readAsStringSync();
      expect(content, contains('set(NITRO_NATIVE'));
      expect(content, contains('add_library(testing_project SHARED'));
      expect(content, contains('testing_project.bridge.g.cpp'));
      expect(content, contains('dart_api_dl.c'));
      expect(content, contains('CMAKE_CXX_STANDARD'));
    });

    test('src/testing_project.cpp is the plugin stub', () {
      final cpp = File(p.join(_fixture.path, 'src', 'testing_project.cpp'));
      expect(cpp.existsSync(), isTrue);
      expect(cpp.readAsStringSync(), contains('nitro.h'));
    });

    test('ios/<name>/Package.swift — nested Flutter 3.41+ SPM layout', () {
      final pkg = File(p.join(_fixture.path, 'ios', 'testing_project', 'Package.swift'));
      expect(pkg.existsSync(), isTrue, reason: 'Nested Package.swift must exist at ios/testing_project/Package.swift');
      final content = pkg.readAsStringSync();
      expect(content, contains('swift-tools-version: 5.9'));
      expect(content, contains('.iOS(.v13)'));
      expect(content, contains('"TestingProjectCpp"'));
      expect(content, contains('"testing_project"'));
      expect(content, contains('Sources/TestingProjectCpp'));
      expect(content, contains('Sources/TestingProject'));
      expect(content, contains('publicHeadersPath: "include"'));
    });

    test('ios/testing_project/Sources/TestingProject/ directory exists', () {
      expect(
        Directory(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProject')).existsSync(),
        isTrue,
      );
    });

    test('ios/testing_project/Sources/TestingProjectCpp/ directory exists', () {
      expect(
        Directory(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp')).existsSync(),
        isTrue,
      );
    });

    test('ios/testing_project/Sources/TestingProjectCpp/include/ has nitro headers', () {
      final incl = Directory(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'include'));
      expect(incl.existsSync(), isTrue);
      expect(File(p.join(incl.path, 'dart_api.h')).existsSync(), isTrue);
      expect(File(p.join(incl.path, 'dart_api_dl.h')).existsSync(), isTrue);
      expect(File(p.join(incl.path, 'nitro.h')).existsSync(), isTrue);
    });

    test('ios/Classes/SwiftTestingProjectPlugin.swift registers impl', () {
      final swift = File(p.join(_fixture.path, 'ios', 'Classes', 'SwiftTestingProjectPlugin.swift'));
      expect(swift.existsSync(), isTrue);
      final content = swift.readAsStringSync();
      expect(content, contains('class SwiftTestingProjectPlugin'));
      expect(content, contains('TestingProjectRegistry.register(TestingProjectImpl())'));
    });

    test('ios/Classes/TestingProjectImpl.swift exists', () {
      expect(
        File(p.join(_fixture.path, 'ios', 'Classes', 'TestingProjectImpl.swift')).existsSync(),
        isTrue,
      );
    });

    test('macos/<name>/Package.swift — nested macOS SPM layout', () {
      final pkg = File(p.join(_fixture.path, 'macos', 'testing_project', 'Package.swift'));
      expect(pkg.existsSync(), isTrue);
      final content = pkg.readAsStringSync();
      expect(content, contains('.macOS(.v10_15)'));
      expect(content, contains('"TestingProjectCpp"'));
    });

    test('android/build.gradle uses kotlin.srcDirs not java.srcDirs', () {
      final gradle = File(p.join(_fixture.path, 'android', 'build.gradle'));
      expect(gradle.existsSync(), isTrue);
      final content = gradle.readAsStringSync();
      expect(content, contains('kotlin.srcDirs'));
      expect(content, isNot(contains("java.srcDirs = ['src/main/kotlin']")));
    });

    test('android Kotlin Plugin.kt uses JniBridge and registers impl', () {
      final kt = File(
        p.join(
          _fixture.path,
          'android',
          'src',
          'main',
          'kotlin',
          'com',
          'example',
          'testing_project',
          'TestingProjectPlugin.kt',
        ),
      );
      expect(kt.existsSync(), isTrue);
      final content = kt.readAsStringSync();
      expect(content, contains('TestingProjectJniBridge'));
      expect(content, contains('System.loadLibrary("testing_project")'));
      // Multi-instance C++ registry pattern: the plugin registers a FACTORY
      // (one impl per Dart-side instance), not a single shared impl.
      expect(content, contains('TestingProjectJniBridge.registerFactory('));
    });

    test('lib/src/testing_project.native.dart has @NitroModule annotation', () {
      final native = File(p.join(_fixture.path, 'lib', 'src', 'testing_project.native.dart'));
      expect(native.existsSync(), isTrue);
      final content = native.readAsStringSync();
      expect(content, contains('@NitroModule'));
      expect(content, contains('NativeImpl.swift'));
      expect(content, contains('NativeImpl.kotlin'));
      expect(content, contains('abstract class TestingProject extends HybridObject'));
    });

    test('.clangd exists for IDE completion support', () {
      expect(File(p.join(_fixture.path, '.clangd')).existsSync(), isTrue);
    });

    test('flat ios/Package.swift does NOT exist (nested layout only)', () {
      expect(
        File(p.join(_fixture.path, 'ios', 'Package.swift')).existsSync(),
        isFalse,
        reason: 'Flat layout is not auto-detected by Flutter 3.41+',
      );
    });
  });

  // ── 3. nitrogen generate — fixture output verification ─────────────────────

  group('nitrogen generate — testing_project generated output', skip: _fixture.existsSync() && File(p.join(_fixture.path, 'lib', 'src', 'testing_project.g.dart')).existsSync() ? null : 'generated output not found — run `nitrogen generate` first', () {
    test('lib/src/testing_project.g.dart — Dart FFI binding exists', () {
      final gen = File(p.join(_fixture.path, 'lib', 'src', 'testing_project.g.dart'));
      expect(gen.existsSync(), isTrue);
      final content = gen.readAsStringSync();
      expect(content, contains('// Generated by Nitrogen Modules'));
      expect(content, contains('class _TestingProjectImpl extends TestingProject'));
      expect(content, contains("'testing_project_init_dart_api_dl'"));
      expect(content, contains("'testing_project_add'"));
    });

    test('lib/src/generated/swift/testing_project.bridge.g.swift — Swift bridge', () {
      final gen = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_project.bridge.g.swift'));
      expect(gen.existsSync(), isTrue);
      final content = gen.readAsStringSync();
      expect(content, contains('// Generated by Nitrogen Modules'));
      expect(content, contains('HybridTestingProjectProtocol'));
      expect(content, contains('TestingProjectRegistry'));
      expect(content, contains('func add(a: Double, b: Double) -> Double'));
      expect(content, contains('func getGreeting(name: String) async throws -> String'));
    });

    test('lib/src/generated/kotlin/testing_project.bridge.g.kt — Kotlin bridge', () {
      final gen = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_project.bridge.g.kt'));
      expect(gen.existsSync(), isTrue);
      final content = gen.readAsStringSync();
      expect(content, contains('// Generated by Nitrogen Modules'));
      expect(content, contains('package nitro.testing_project_module'));
      expect(content, contains('HybridTestingProjectSpec'));
    });

    test('lib/src/generated/cpp/ bridge files exist', () {
      final cppDir = Directory(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp'));
      expect(cppDir.existsSync(), isTrue);
      final files = cppDir.listSync().map((e) => p.basename(e.path)).toList();
      expect(files.any((f) => f.endsWith('.bridge.g.h')), isTrue, reason: 'C++ bridge header must be generated');
      expect(files.any((f) => f.endsWith('.bridge.g.cpp')), isTrue, reason: 'C++ bridge impl must be generated');
    });

    test('generated .g.dart has correct init symbol name', () {
      final gen = File(p.join(_fixture.path, 'lib', 'src', 'testing_project.g.dart'));
      final content = gen.readAsStringSync();
      // Symbol follows pattern: <lib>_init_dart_api_dl
      expect(content, contains('testing_project_init_dart_api_dl'));
    });

    test('Swift bridge has @_cdecl stub with namespace prefix', () {
      final gen = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_project.bridge.g.swift'));
      final content = gen.readAsStringSync();
      // @_cdecl uses _<namespace>_call_<methodName> format.
      // The testing_project spec has no explicit namespace so the generator
      // defaults to the snake_case class name: "testing_project".
      expect(content, contains('@_cdecl("_testing_project_call_add")'));
    });
  });

  // ── 4a. Per-spec generated output — testing_project (Swift/Kotlin) ──────────

  group('nitrogen generate — testing_project spec (Swift iOS / Kotlin Android)',
      skip: _fixture.existsSync() && File(p.join(_fixture.path, 'lib', 'src', 'testing_project.g.dart')).existsSync() ? null : 'generated output not found', () {
    // ── Dart binding ───────────────────────────────────────────────────────────
    test('Dart binding: has add() and getGreeting() lookup symbols', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_project.g.dart')).readAsStringSync();
      expect(content, contains("'testing_project_add'"));
      expect(content, contains("'testing_project_get_greeting'"));
    });

    test('Dart binding: add() is a sync call returning double', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_project.g.dart')).readAsStringSync();
      expect(content, contains('double add('));
      expect(content, isNot(contains('Future<double>')),
          reason: 'add is sync — must not be wrapped in Future');
    });

    test('Dart binding: getGreeting() is async (Future<String>)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_project.g.dart')).readAsStringSync();
      expect(content, contains('Future<String> getGreeting('));
    });

    // ── C++ bridge header ──────────────────────────────────────────────────────
    test('C bridge header: testing_project_add and testing_project_get_greeting declared', () {
      final h = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_project.bridge.g.h'));
      expect(h.existsSync(), isTrue);
      final content = h.readAsStringSync();
      expect(content, contains('testing_project_add'));
      expect(content, contains('testing_project_get_greeting'));
    });

    test('C bridge header: add() uses double params and return', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_project.bridge.g.h')).readAsStringSync();
      expect(content, matches(RegExp(r'double\s+testing_project_add')));
    });

    test('C bridge header: getGreeting() has a dart_port int64 param for async', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_project.bridge.g.h')).readAsStringSync();
      expect(content, contains('dart_port'),
          reason: 'async methods post result via Dart port — int64_t dart_port param required');
    });

    // ── Swift bridge ───────────────────────────────────────────────────────────
    test('Swift bridge: declares HybridTestingProjectProtocol with add + getGreeting', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_project.bridge.g.swift')).readAsStringSync();
      expect(content, contains('protocol HybridTestingProjectProtocol'));
      expect(content, contains('func add(a: Double, b: Double) -> Double'));
      expect(content, contains('func getGreeting(name: String) async throws -> String'));
    });

    test('Swift bridge: @_cdecl stubs present for sync add and async getGreeting', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_project.bridge.g.swift')).readAsStringSync();
      expect(content, contains('@_cdecl("_testing_project_call_add")'));
      expect(content, contains('@_cdecl("_testing_project_call_getGreeting")'));
    });

    test('Swift bridge: TestingProjectRegistry.register() is declared', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_project.bridge.g.swift')).readAsStringSync();
      expect(content, contains('TestingProjectRegistry'));
      expect(content, contains('static func register('));
    });

    // ── Kotlin bridge ──────────────────────────────────────────────────────────
    test('Kotlin bridge: package is nitro.testing_project_module', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_project.bridge.g.kt')).readAsStringSync();
      expect(content, contains('package nitro.testing_project_module'));
    });

    test('Kotlin bridge: HybridTestingProjectSpec interface with add + getGreeting', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_project.bridge.g.kt')).readAsStringSync();
      expect(content, contains('HybridTestingProjectSpec'));
      expect(content, contains('fun add('));
      expect(content, contains('fun getGreeting('));
    });

    test('Kotlin bridge: TestingProjectJniBridge declared', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_project.bridge.g.kt')).readAsStringSync();
      expect(content, contains('TestingProjectJniBridge'));
      expect(content, contains('registerFactory('));
    });
  });

  // ── 4b. Per-spec generated output — testing_cpp (NativeImpl.cpp everywhere) ─

  group('nitrogen generate — testing_cpp spec (NativeImpl.cpp all platforms)',
      skip: _fixture.existsSync() && File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.bridge.g.h')).existsSync() ? null : 'generated output not found', () {
    // ── C++ bridge header ──────────────────────────────────────────────────────
    test('C bridge header: testing_cpp_multiply / _pi / _is_even / _try_divide declared', () {
      final h = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.bridge.g.h'));
      final content = h.readAsStringSync();
      expect(content, contains('testing_cpp_multiply'));
      expect(content, contains('testing_cpp_pi'));
      expect(content, contains('testing_cpp_is_even'));
      expect(content, contains('testing_cpp_try_divide'));
    });

    test('C bridge header: tryDivide uses NitroOptInt64 (nullable int64 return)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.bridge.g.h')).readAsStringSync();
      expect(content, contains('NitroOptInt64'),
          reason: 'int? return must use packed optional struct, not sentinel value');
    });

    test('C bridge header: isEven return is uint8_t / bool-sized', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.bridge.g.h')).readAsStringSync();
      expect(content, matches(RegExp(r'(uint8_t|int8_t|bool)\s+testing_cpp_is_even')),
          reason: 'bool methods should use a byte-sized C type, not int64_t');
    });

    // ── C++ native.g.h ────────────────────────────────────────────────────────
    test('native.g.h: HybridTestingCpp abstract class with all pure-virtual methods', () {
      final h = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.native.g.h'));
      expect(h.existsSync(), isTrue);
      final content = h.readAsStringSync();
      expect(content, contains('class HybridTestingCpp'));
      expect(content, contains('virtual int64_t multiply('));
      expect(content, contains('virtual double pi('));
      expect(content, contains('virtual bool isEven('));
      expect(content, contains('virtual std::optional<int64_t> tryDivide('));
    });

    test('native.g.h: includes testing_cpp.bridge.g.h (C header) and declares register fn', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.native.g.h')).readAsStringSync();
      expect(content, contains('testing_cpp.bridge.g.h'));
      expect(content, contains('testing_cpp_register_impl'));
    });

    // ── C++ impl.g.cpp ────────────────────────────────────────────────────────
    test('impl.g.cpp: one-time editable starter with HybridTestingCpp methods', () {
      final impl = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.impl.g.cpp'));
      expect(impl.existsSync(), isTrue);
      final content = impl.readAsStringSync();
      expect(content, contains('HybridTestingCpp'));
      expect(content, contains('multiply'));
      expect(content, contains('tryDivide'));
      expect(content, isNot(contains('Generated by Nitrogen Modules. Do not edit.')),
          reason: 'impl.g.cpp must NOT say "do not edit" — it is the user-editable starter');
    });

    // ── Swift bridge (cpp module) ──────────────────────────────────────────────
    test('Swift bridge: no @_cdecl stubs (cpp-only path uses C functions directly)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_cpp.bridge.g.swift')).readAsStringSync();
      expect(content, isNot(contains('@_cdecl("')),
          reason: 'NativeImpl.cpp Swift bridge must not emit @_cdecl stubs');
    });

    test('Swift bridge: HybridTestingCppProtocol declared for optional Swift delegation', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_cpp.bridge.g.swift')).readAsStringSync();
      expect(content, contains('HybridTestingCppProtocol'));
      expect(content, contains('func multiply('));
      expect(content, contains('func tryDivide('));
    });

    test('Swift bridge: TestingCppRegistry.register() for optional C++ → Swift delegation', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_cpp.bridge.g.swift')).readAsStringSync();
      expect(content, contains('TestingCppRegistry'));
    });

    // ── Kotlin bridge (cpp module) ─────────────────────────────────────────────
    test('Kotlin bridge: package is nitro.testing_cpp_module', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_cpp.bridge.g.kt')).readAsStringSync();
      expect(content, contains('package nitro.testing_cpp_module'));
    });

    test('Kotlin bridge: HybridTestingCppSpec with all methods', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_cpp.bridge.g.kt')).readAsStringSync();
      expect(content, contains('HybridTestingCppSpec'));
      expect(content, contains('fun multiply('));
      expect(content, contains('fun pi()'));
      expect(content, contains('fun isEven('));
      expect(content, contains('fun tryDivide('));
    });

    test('Kotlin bridge: tryDivide returns Long? (nullable Long)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_cpp.bridge.g.kt')).readAsStringSync();
      expect(content, matches(RegExp(r'fun tryDivide\([^)]*\)\s*:\s*Long\?')),
          reason: 'int? maps to nullable Long in Kotlin');
    });

    // ── Dart binding ───────────────────────────────────────────────────────────
    test('Dart binding: _TestingCppImpl class extends TestingCpp', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_cpp.g.dart')).readAsStringSync();
      expect(content, contains('class _TestingCppImpl extends TestingCpp'));
    });

    test('Dart binding: multiply, pi, isEven use correct FFI symbols', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_cpp.g.dart')).readAsStringSync();
      expect(content, contains("'testing_cpp_multiply'"));
      expect(content, contains("'testing_cpp_pi'"));
      expect(content, contains("'testing_cpp_is_even'"));
    });

    test('Dart binding: tryDivide returns int? (nullable)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_cpp.g.dart')).readAsStringSync();
      expect(content, contains('int? tryDivide('),
          reason: 'tryDivide declared int? in the native spec must stay nullable in Dart');
    });

    // ── SPM files ─────────────────────────────────────────────────────────────
    test('iOS SPM: HybridTestingCpp.cpp forwarder links user src/', () {
      final f = File(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'HybridTestingCpp.cpp'));
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), contains('HybridTestingCpp.cpp'),
          reason: 'forwarder must #include the user src/ file');
    });

    test('macOS SPM: HybridTestingCpp.cpp forwarder exists', () {
      final f = File(p.join(_fixture.path, 'macos', 'testing_project', 'Sources', 'TestingProjectCpp', 'HybridTestingCpp.cpp'));
      expect(f.existsSync(), isTrue);
    });
  });

  // ── 4c. Per-spec generated output — testing_mixed (Swift/Kotlin/C++ per platform) ─

  group('nitrogen generate — testing_mixed spec (Swift iOS / Kotlin Android / C++ macOS)',
      skip: _fixture.existsSync() && File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_mixed.bridge.g.swift')).existsSync() ? null : 'generated output not found', () {
    // ── Swift bridge (iOS = NativeImpl.swift) ──────────────────────────────────
    test('Swift bridge: @_cdecl stubs for iOS (NativeImpl.swift)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_mixed.bridge.g.swift')).readAsStringSync();
      expect(content, contains('@_cdecl("_testing_mixed_call_platform")'));
    });

    test('Swift bridge: HybridTestingMixedProtocol with platform + optionalFlag + optionalValue', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_mixed.bridge.g.swift')).readAsStringSync();
      expect(content, contains('HybridTestingMixedProtocol'));
      expect(content, contains('func platform() -> String'));
      expect(content, contains('func optionalFlag() -> Bool?'));
      expect(content, contains('func optionalValue(key: String) -> Double?'));
    });

    test('Swift bridge: TestingMixedRegistry declared for iOS registration', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_mixed.bridge.g.swift')).readAsStringSync();
      expect(content, contains('TestingMixedRegistry'));
    });

    test('Swift bridge: optionalFlag returns Bool? (nullable Bool)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_mixed.bridge.g.swift')).readAsStringSync();
      expect(content, contains('func optionalFlag() -> Bool?'));
    });

    // ── Kotlin bridge (Android = NativeImpl.kotlin) ───────────────────────────
    test('Kotlin bridge: package is nitro.testing_mixed_module', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_mixed.bridge.g.kt')).readAsStringSync();
      expect(content, contains('package nitro.testing_mixed_module'));
    });

    test('Kotlin bridge: HybridTestingMixedSpec with platform + optionalFlag + optionalValue', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_mixed.bridge.g.kt')).readAsStringSync();
      expect(content, contains('HybridTestingMixedSpec'));
      expect(content, contains('fun platform()'));
      expect(content, contains('fun optionalFlag()'));
      expect(content, contains('fun optionalValue('));
    });

    test('Kotlin bridge: optionalFlag returns Boolean? (nullable Boolean)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_mixed.bridge.g.kt')).readAsStringSync();
      expect(content, matches(RegExp(r'fun optionalFlag\(\)\s*:\s*Boolean\?')));
    });

    test('Kotlin bridge: optionalValue returns Double? (nullable Double)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_mixed.bridge.g.kt')).readAsStringSync();
      expect(content, matches(RegExp(r'fun optionalValue\([^)]*\)\s*:\s*Double\?')));
    });

    test('Kotlin bridge: TestingMixedJniBridge declared with registerFactory', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_mixed.bridge.g.kt')).readAsStringSync();
      expect(content, contains('TestingMixedJniBridge'));
      expect(content, contains('registerFactory('));
    });

    // ── C++ bridge (macOS/desktop = NativeImpl.cpp) ────────────────────────────
    test('C bridge header: testing_mixed_platform / _optional_flag / _optional_value declared', () {
      final h = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_mixed.bridge.g.h'));
      expect(h.existsSync(), isTrue);
      final content = h.readAsStringSync();
      expect(content, contains('testing_mixed_platform'));
      expect(content, contains('testing_mixed_optional_flag'));
      expect(content, contains('testing_mixed_optional_value'));
    });

    test('C bridge header: optionalFlag uses NitroOptBool return', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_mixed.bridge.g.h')).readAsStringSync();
      expect(content, contains('NitroOptBool'),
          reason: 'bool? return must use NitroOptBool packed struct');
    });

    test('C bridge header: optionalValue uses NitroOptFloat64 return', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_mixed.bridge.g.h')).readAsStringSync();
      expect(content, contains('NitroOptFloat64'),
          reason: 'double? return must use NitroOptFloat64 packed struct');
    });

    test('native.g.h: HybridTestingMixed abstract class with optional returns', () {
      final h = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_mixed.native.g.h'));
      expect(h.existsSync(), isTrue);
      final content = h.readAsStringSync();
      expect(content, contains('class HybridTestingMixed'));
      expect(content, contains('virtual std::string platform('));
      expect(content, contains('virtual std::optional<bool> optionalFlag('));
      expect(content, contains('virtual std::optional<double> optionalValue('));
    });

    // ── Dart binding ───────────────────────────────────────────────────────────
    test('Dart binding: _TestingMixedImpl class extends TestingMixed', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_mixed.g.dart')).readAsStringSync();
      expect(content, contains('class _TestingMixedImpl extends TestingMixed'));
    });

    test('Dart binding: platform(), optionalFlag(), optionalValue() symbols', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_mixed.g.dart')).readAsStringSync();
      expect(content, contains("'testing_mixed_platform'"));
      expect(content, contains("'testing_mixed_optional_flag'"));
      expect(content, contains("'testing_mixed_optional_value'"));
    });

    test('Dart binding: optionalFlag returns bool? (nullable)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_mixed.g.dart')).readAsStringSync();
      expect(content, contains('bool? optionalFlag('));
    });

    test('Dart binding: optionalValue returns double? (nullable)', () {
      final content = File(p.join(_fixture.path, 'lib', 'src', 'testing_mixed.g.dart')).readAsStringSync();
      expect(content, contains('double? optionalValue('));
    });

    // ── SPM: iOS Swift target has testing_mixed.bridge.g.swift ────────────────
    test('iOS SPM Swift target: testing_mixed.bridge.g.swift with @_cdecl stubs', () {
      final f = File(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProject', 'testing_mixed.bridge.g.swift'));
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), contains('@_cdecl("'));
    });

    // ── SPM: macOS C++ target has testing_mixed.bridge.g.mm ───────────────────
    test('macOS SPM Cpp target: testing_mixed.bridge.g.mm exists (macOS uses C++)', () {
      final f = File(p.join(_fixture.path, 'macos', 'testing_project', 'Sources', 'TestingProjectCpp', 'testing_mixed.bridge.g.mm'));
      expect(f.existsSync(), isTrue);
    });

    test('macOS SPM Cpp target: HybridTestingMixed.cpp forwarder exists', () {
      final f = File(p.join(_fixture.path, 'macos', 'testing_project', 'Sources', 'TestingProjectCpp', 'HybridTestingMixed.cpp'));
      expect(f.existsSync(), isTrue);
    });
  });

  // ── 4. nitrogen link — integration against temp copy ─────────────────────────

  group('nitrogen link — integration (temp copy of fixture)', skip: _fixture.existsSync() ? null : 'test_projects/testing_project not found', () {
    late Directory tmp;
    String? savedCwd;

    setUp(() {
      try { savedCwd = Directory.current.path; } catch (_) {}
      tmp = Directory.systemTemp.createTempSync('nitro_link_integration_');
      _copyDir(_fixture, tmp);
    });

    tearDown(() {
      if (savedCwd != null) {
        try { Directory.current = savedCwd!; } catch (_) {}
      }
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('linkSwiftPlugin injects TestingProjectRegistry.register into ios Plugin.swift', () {
      // Remove existing registration to force linkSwiftPlugin to re-inject it.
      final pluginFile = File(p.join(tmp.path, 'ios', 'Classes', 'SwiftTestingProjectPlugin.swift'));
      pluginFile.writeAsStringSync('''
import Flutter
import UIKit

public class SwiftTestingProjectPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // TODO: inject by nitrogen link
  }
}
''');

      linkSwiftPlugin(
        'testing_project',
        [
          {'module': 'TestingProject', 'lib': 'testing_project'},
        ],
        baseDir: tmp.path,
      );

      final content = pluginFile.readAsStringSync();
      expect(content, contains('TestingProjectRegistry.register('));
    });

    test('linkMacosSwiftPlugin injects TestingProjectRegistry.register into macos Plugin.swift', () {
      final pluginFile = File(p.join(tmp.path, 'macos', 'Classes', 'SwiftTestingProjectPlugin.swift'));
      pluginFile.writeAsStringSync('''
import FlutterMacOS
import Foundation

public class SwiftTestingProjectPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
  }
}
''');

      linkMacosSwiftPlugin(
        'testing_project',
        [
          {'module': 'TestingProject', 'lib': 'testing_project'},
        ],
        baseDir: tmp.path,
      );

      final content = pluginFile.readAsStringSync();
      expect(content, contains('TestingProjectRegistry.register('));
    });

    test('linkKotlinPlugin injects JniBridge.register into Plugin.kt', () {
      final pluginFile = File(
        p.join(
          tmp.path,
          'android',
          'src',
          'main',
          'kotlin',
          'com',
          'example',
          'testing_project',
          'TestingProjectPlugin.kt',
        ),
      );
      pluginFile.writeAsStringSync('''
package com.example.testing_project

import io.flutter.embedding.engine.plugins.FlutterPlugin

class TestingProjectPlugin : FlutterPlugin {
    companion object {
        init { System.loadLibrary("testing_project") }
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
''');

      linkKotlinPlugin(
        'testing_project',
        [
          {'module': 'TestingProject', 'lib': 'testing_project'},
        ],
        baseDir: tmp.path,
      );

      final content = pluginFile.readAsStringSync();
      expect(content, contains('TestingProjectJniBridge'));
      expect(content, contains('TestingProjectJniBridge.registerFactory('));
    });

    test('linkKotlinLoadLibraries injects System.loadLibrary when missing', () {
      final pluginFile = File(
        p.join(
          tmp.path,
          'android',
          'src',
          'main',
          'kotlin',
          'com',
          'example',
          'testing_project',
          'TestingProjectPlugin.kt',
        ),
      );
      // The fixture should already have it; verify idempotent
      linkKotlinLoadLibraries(['testing_project'], baseDir: tmp.path);
      final after = pluginFile.readAsStringSync();
      // No duplicate loadLibrary calls
      expect(
        RegExp(r'System\.loadLibrary\("testing_project"\)').allMatches(after).length,
        equals(1),
      );
    });

    test('linkPodspec writes <plugin>.bridge.g.mm forwarder into SPM Cpp target', () {
      // The forwarder is what makes testing_project_init_dart_api_dl available
      // at runtime — without it the symbol lookup fails with dlsym not found.
      linkPodspec(
        'testing_project',
        ['testing_project'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'testing_project', module: 'TestingProject', isCpp: false)],
      );

      for (final platform in ['ios', 'macos']) {
        final mm = File(
          p.join(
            tmp.path,
            platform,
            'testing_project',
            'Sources',
            'TestingProjectCpp',
            'testing_project.bridge.g.mm',
          ),
        );
        expect(mm.existsSync(), isTrue, reason: '$platform bridge.g.mm forwarder must exist so the C bridge symbols are compiled under SPM');
        final content = mm.readAsStringSync();
        expect(content, contains('#import <Foundation/Foundation.h>'), reason: 'Foundation import is required for NSException in the @catch blocks');
        expect(content, contains('testing_project.bridge.g.cpp'), reason: 'forwarder must include the generated bridge .cpp');
      }
    });

    test('linkPodspec writes bridge.g.mm even when bridge.g.cpp does not exist yet', () {
      // Regression: previously nitrogen link guarded bridge.g.mm creation behind
      // existsSync() on the generated .bridge.g.cpp.  If the user ran link before
      // generate, the bridge.g.mm was never created and the app crashed with
      // "Failed to lookup symbol '<plugin>_init_dart_api_dl'".
      // Now link must write the forwarder unconditionally.
      final bridgeCpp = File(
        p.join(
          tmp.path,
          'lib',
          'src',
          'generated',
          'cpp',
          'testing_project.bridge.g.cpp',
        ),
      );
      if (bridgeCpp.existsSync()) bridgeCpp.deleteSync();

      linkPodspec(
        'testing_project',
        ['testing_project'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'testing_project', module: 'TestingProject', isCpp: false)],
      );

      for (final platform in ['ios', 'macos']) {
        final mm = File(
          p.join(
            tmp.path,
            platform,
            'testing_project',
            'Sources',
            'TestingProjectCpp',
            'testing_project.bridge.g.mm',
          ),
        );
        expect(mm.existsSync(), isTrue, reason: '$platform bridge.g.mm must be written even before nitrogen generate is run');
        expect(mm.readAsStringSync(), contains('testing_project.bridge.g.cpp'), reason: 'forwarder path must reference the (not-yet-generated) bridge .cpp');
      }
    });

    test('createSharedHeaders populates ios include/ with dart_api.h and nitro.h', () {
      final includeDir = Directory(p.join(tmp.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'include'));
      // Clear existing headers to test that createSharedHeaders re-populates
      if (includeDir.existsSync()) {
        for (final f in includeDir.listSync().whereType<File>()) {
          f.deleteSync();
        }
      } else {
        includeDir.createSync(recursive: true);
      }

      createSharedHeaders(_nitroNativePath, baseDir: tmp.path);

      // Both ios and macos include dirs should now have the headers
      for (final platform in ['ios', 'macos']) {
        final incl = Directory(p.join(tmp.path, platform, 'testing_project', 'Sources', 'TestingProjectCpp', 'include'));
        expect(File(p.join(incl.path, 'dart_api.h')).existsSync(), isTrue, reason: '$platform include/dart_api.h must exist after createSharedHeaders');
        expect(File(p.join(incl.path, 'nitro.h')).existsSync(), isTrue, reason: '$platform include/nitro.h must exist after createSharedHeaders');
      }
    });

    test('linkSwiftPlugin is idempotent — no duplicate registrations', () {
      final modules = [
        {'module': 'TestingProject', 'lib': 'testing_project'},
      ];
      linkSwiftPlugin('testing_project', modules, baseDir: tmp.path);
      linkSwiftPlugin('testing_project', modules, baseDir: tmp.path);

      final pluginFile = File(p.join(tmp.path, 'ios', 'Classes', 'SwiftTestingProjectPlugin.swift'));
      final count = RegExp(r'TestingProjectRegistry\.register').allMatches(pluginFile.readAsStringSync()).length;
      expect(count, equals(1), reason: 'Registration must not be duplicated');
    });

    test('keeps Hybrid*.cpp forwarder for Apple cpp module', () {
      // Simulate a second module (gpu) that uses AppleNativeImpl.cpp.
      // The fixture uses nested SPM layout: ios/testing_project/Package.swift
      // so the SPM C++ target is at ios/testing_project/Sources/TestingProjectCpp/.

      // Bridge generated files
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'gpu.bridge.g.cpp')).writeAsStringSync('// bridge');
      File(p.join(genCpp.path, 'gpu.bridge.g.h')).writeAsStringSync('// header');

      // Native implementation stub
      File(p.join(tmp.path, 'src', 'HybridGpu.cpp')).writeAsStringSync('// impl');

      // Spec marking gpu as AppleNativeImpl.cpp on iOS/macOS
      File(p.join(tmp.path, 'lib', 'src', 'gpu.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'gpu', ios: AppleNativeImpl.cpp, macos: AppleNativeImpl.cpp)\n"
        'abstract class Gpu extends HybridObject {}\n',
      );

      linkPodspec(
        'testing_project',
        ['testing_project', 'gpu'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'gpu', module: 'Gpu', isCpp: true)],
      );

      // Fixture uses nested SPM layout — forwarder goes into the nested Cpp target.
      final forwarder = File(
        p.join(
          tmp.path,
          'ios',
          'testing_project',
          'Sources',
          'TestingProjectCpp',
          'HybridGpu.cpp',
        ),
      );
      expect(
        forwarder.existsSync(),
        isTrue,
        reason: 'Apple C++ module must have a Hybrid*.cpp forwarder in ios/<plugin>/Sources/<PluginCpp>/',
      );
      // Nested layout: 4 levels up from Sources/<PluginCpp>/ to project root.
      expect(
        forwarder.readAsStringSync(),
        contains('#include "../../../../src/HybridGpu.cpp"'),
      );
    });
  });

  // ── 5. Full scaffold simulation — init → verify structure ─────────────────

  group('nitrogen init — full scaffold simulation', () {
    late Directory tmp;
    String? savedCwd;

    setUp(() {
      try { savedCwd = Directory.current.path; } catch (_) {}
      tmp = Directory.systemTemp.createTempSync('nitro_scaffold_test_');
      Directory.current = tmp;
      _scaffoldPlugin(tmp, 'my_plugin', 'com.example');
    });

    tearDown(() {
      if (savedCwd != null) {
        try { Directory.current = savedCwd!; } catch (_) {}
      }
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('src/CMakeLists.txt is created', () {
      expect(File(p.join(tmp.path, 'src', 'CMakeLists.txt')).existsSync(), isTrue);
    });

    test('src/my_plugin.cpp stub is created', () {
      final cpp = File(p.join(tmp.path, 'src', 'my_plugin.cpp'));
      expect(cpp.existsSync(), isTrue);
      expect(cpp.readAsStringSync(), contains('my_plugin.bridge.g.h'));
    });

    test('ios/my_plugin/Package.swift — nested SPM layout', () {
      final pkg = File(p.join(tmp.path, 'ios', 'my_plugin', 'Package.swift'));
      expect(pkg.existsSync(), isTrue, reason: 'Package.swift must be at ios/<name>/Package.swift, not ios/Package.swift');
      expect(pkg.readAsStringSync(), contains('iOS(.v13)'));
      expect(pkg.readAsStringSync(), contains('"MyPluginCpp"'));
    });

    test('ios/my_plugin/Sources/MyPlugin/ Swift source dir exists', () {
      expect(
        Directory(p.join(tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPlugin')).existsSync(),
        isTrue,
      );
    });

    test('ios/my_plugin/Sources/MyPluginCpp/ C++ source dir exists', () {
      expect(
        Directory(p.join(tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPluginCpp')).existsSync(),
        isTrue,
      );
    });

    test('ios/my_plugin/Sources/MyPluginCpp/my_plugin.bridge.g.mm created by init', () {
      // Critical: the bridge.g.mm forwarder must exist immediately after
      // nitrogen init so the symbol <plugin>_init_dart_api_dl is available
      // when the project is compiled, even before nitrogen link is run.
      final mm = File(
        p.join(
          tmp.path,
          'ios',
          'my_plugin',
          'Sources',
          'MyPluginCpp',
          'my_plugin.bridge.g.mm',
        ),
      );
      expect(mm.existsSync(), isTrue, reason: 'nitrogen init must create bridge.g.mm in SPM C++ target');
      final content = mm.readAsStringSync();
      expect(content, contains('#import <Foundation/Foundation.h>'), reason: 'Foundation import required for NSException/Obj-C++ bridge');
      expect(content, contains('my_plugin.bridge.g.cpp'), reason: 'forwarder must reference the generated bridge .cpp');
    });

    test('macos/my_plugin/Sources/MyPluginCpp/my_plugin.bridge.g.mm created by init', () {
      final mm = File(
        p.join(
          tmp.path,
          'macos',
          'my_plugin',
          'Sources',
          'MyPluginCpp',
          'my_plugin.bridge.g.mm',
        ),
      );
      expect(mm.existsSync(), isTrue, reason: 'nitrogen init must create bridge.g.mm in macOS SPM C++ target');
      expect(mm.readAsStringSync(), contains('my_plugin.bridge.g.cpp'));
    });

    test('ios/my_plugin/Sources/MyPluginCpp/dart_api_dl.c uses portable bundled stub', () {
      final f = File(
        p.join(
          tmp.path,
          'ios',
          'my_plugin',
          'Sources',
          'MyPluginCpp',
          'dart_api_dl.c',
        ),
      );
      expect(f.existsSync(), isTrue, reason: 'nitrogen init must create dart_api_dl.c in iOS SPM C++ target');
      final content = f.readAsStringSync();
      expect(content, contains('dart_api_dl.h'), reason: 'bundled stub must include local dart_api_dl.h');
      expect(content, isNot(contains('.symlinks')), reason: 'must not use CocoaPods .symlinks path — breaks on machines without pod install');
      expect(content, isNot(matches(RegExp(r'#include\s*"/'))), reason: 'must not use absolute path — breaks on other machines');
    });

    test('macos/my_plugin/Sources/MyPluginCpp/dart_api_dl.c uses portable bundled stub', () {
      final f = File(
        p.join(
          tmp.path,
          'macos',
          'my_plugin',
          'Sources',
          'MyPluginCpp',
          'dart_api_dl.c',
        ),
      );
      expect(f.existsSync(), isTrue);
      final content = f.readAsStringSync();
      expect(content, contains('dart_api_dl.h'));
      expect(content, isNot(contains('.symlinks')));
      expect(content, isNot(matches(RegExp(r'#include\s*"/'))));
    });

    test('ios/Classes/SwiftMyPluginPlugin.swift registers implementation', () {
      final swift = File(p.join(tmp.path, 'ios', 'Classes', 'SwiftMyPluginPlugin.swift'));
      expect(swift.existsSync(), isTrue);
      expect(swift.readAsStringSync(), contains('MyPluginRegistry.register(MyPluginImpl())'));
    });

    test('ios/Classes/MyPluginImpl.swift is created', () {
      expect(
        File(p.join(tmp.path, 'ios', 'Classes', 'MyPluginImpl.swift')).existsSync(),
        isTrue,
      );
    });

    test('ios/Classes/my_plugin.bridge.g.swift symlink points to generated path', () {
      final link = Link(p.join(tmp.path, 'ios', 'Classes', 'my_plugin.bridge.g.swift'));
      expect(link.existsSync(), isTrue);
      expect(link.targetSync(), contains('generated/swift/my_plugin.bridge.g.swift'));
    });

    test('macos/my_plugin/Package.swift — nested macOS SPM layout', () {
      final pkg = File(p.join(tmp.path, 'macos', 'my_plugin', 'Package.swift'));
      expect(pkg.existsSync(), isTrue);
      expect(pkg.readAsStringSync(), contains('macOS(.v10_15)'));
    });

    test('android/build.gradle is created', () {
      final gradle = File(p.join(tmp.path, 'android', 'build.gradle'));
      expect(gradle.existsSync(), isTrue);
      final content = gradle.readAsStringSync();
      expect(content, contains('namespace = "com.example.my_plugin"'));
      expect(content, contains('"../src/CMakeLists.txt"'));
    });

    test('android Plugin.kt and Impl.kt are created', () {
      final base = p.join(tmp.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'my_plugin');
      expect(File(p.join(base, 'MyPluginPlugin.kt')).existsSync(), isTrue);
      expect(File(p.join(base, 'MyPluginImpl.kt')).existsSync(), isTrue);
    });

    test('android Impl.kt implements HybridMyPluginSpec', () {
      final kt = File(p.join(tmp.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'my_plugin', 'MyPluginImpl.kt'));
      expect(kt.readAsStringSync(), contains('HybridMyPluginSpec'));
    });

    test('lib/src/my_plugin.native.dart has @NitroModule annotation', () {
      final native = File(p.join(tmp.path, 'lib', 'src', 'my_plugin.native.dart'));
      expect(native.existsSync(), isTrue);
      final content = native.readAsStringSync();
      expect(content, contains('@NitroModule'));
      expect(content, contains('abstract class MyPlugin extends HybridObject'));
    });

    test('lib/my_plugin.dart exports the native spec', () {
      final barrel = File(p.join(tmp.path, 'lib', 'my_plugin.dart'));
      expect(barrel.existsSync(), isTrue);
      expect(barrel.readAsStringSync(), contains("export 'src/my_plugin.native.dart'"));
    });

    test('flat ios/Package.swift does NOT exist (Flutter 3.41+ uses nested only)', () {
      expect(
        File(p.join(tmp.path, 'ios', 'Package.swift')).existsSync(),
        isFalse,
        reason: 'Flat layout is not auto-detected by Flutter 3.41+',
      );
    });

    test('CMakeLists NITRO_NATIVE references local src/native path', () {
      final cmake = File(p.join(tmp.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains(r'set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")'));
    });

    test('link functions work on scaffolded project — Swift registration injected', () {
      // Create a minimal generated dir so linkSwiftPlugin has a target
      Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'swift')).createSync(recursive: true);

      linkSwiftPlugin(
        'my_plugin',
        [
          {'module': 'MyPlugin', 'lib': 'my_plugin'},
        ],
        baseDir: tmp.path,
      );

      final swift = File(p.join(tmp.path, 'ios', 'Classes', 'SwiftMyPluginPlugin.swift'));
      expect(swift.readAsStringSync(), contains('MyPluginRegistry.register('));
    });

    test('link functions work on scaffolded project — Kotlin registration injected', () {
      linkKotlinPlugin(
        'my_plugin',
        [
          {'module': 'MyPlugin', 'lib': 'my_plugin'},
        ],
        baseDir: tmp.path,
      );

      final kt = File(p.join(tmp.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'my_plugin', 'MyPluginPlugin.kt'));
      // Paren-less prefix: matches registerFactory( — the current API.
      expect(kt.readAsStringSync(), contains('MyPluginJniBridge.register'));
    });
  });

  // ── 5. Multi-spec fixture: generate output structure ─────────────────────────
  //
  // The testing_project fixture includes three native specs, each with a
  // different NativeImpl annotation combination:
  //
  //   testing_project.native.dart  — ios/macos: NativeImpl.swift, android: NativeImpl.kotlin
  //   testing_cpp.native.dart      — all platforms: NativeImpl.cpp
  //   testing_mixed.native.dart    — ios: NativeImpl.swift, android: NativeImpl.kotlin, macos/others: NativeImpl.cpp
  //
  // These tests verify that nitrogen generate + nitrogen link produce the
  // correct per-spec, per-platform output files.

  String? multiSpecSkip() {
    if (!_fixture.existsSync()) return 'test_projects/testing_project not found';
    final hasCpp = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.bridge.g.h')).existsSync();
    final hasMixed = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_mixed.bridge.g.swift')).existsSync();
    if (!hasCpp || !hasMixed) {
      return 'multi-spec output not found — run scripts/recreate_testing_project.sh first';
    }
    return null;
  }

  group('multi-spec generate — testing_cpp (NativeImpl.cpp all platforms)',
      skip: multiSpecSkip(), () {
    test('testing_cpp.bridge.g.h exists with C bridge functions', () {
      final h = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.bridge.g.h'));
      expect(h.existsSync(), isTrue);
      final content = h.readAsStringSync();
      // C bridge uses snake_case C functions, not C++ class names
      expect(content, contains('testing_cpp_multiply'));
      expect(content, contains('testing_cpp_pi'));
      expect(content, contains('testing_cpp_is_even'));
    });

    test('testing_cpp.bridge.g.cpp exists', () {
      final cpp = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.bridge.g.cpp'));
      expect(cpp.existsSync(), isTrue);
      expect(cpp.readAsStringSync(), contains('testing_cpp_multiply'));
    });

    test('testing_cpp.impl.g.cpp exists (NativeImpl.cpp editable starter)', () {
      final impl = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_cpp.impl.g.cpp'));
      expect(impl.existsSync(), isTrue);
      expect(impl.readAsStringSync(), contains('HybridTestingCpp'));
    });

    test('testing_cpp.bridge.g.swift has no @_cdecl function stubs (cpp-only path)', () {
      final swift = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_cpp.bridge.g.swift'));
      expect(swift.existsSync(), isTrue);
      final content = swift.readAsStringSync();
      // '@_cdecl(' is the actual Swift annotation — just '@_cdecl' may appear in comments
      expect(content, isNot(contains('@_cdecl("')),
          reason: 'NativeImpl.cpp modules do not use Swift @_cdecl function stubs');
    });

    test('testing_cpp.bridge.g.kt declares TestingCppJniBridge and HybridTestingCppSpec', () {
      final kt = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_cpp.bridge.g.kt'));
      expect(kt.existsSync(), isTrue);
      final content = kt.readAsStringSync();
      // The bridge declares the JniBridge object (consistent API for all modules)
      expect(content, contains('TestingCppJniBridge'));
      // It also declares the Kotlin interface that the C++ impl can conform to
      expect(content, contains('HybridTestingCppSpec'));
    });

    test('iOS SPM TestingProjectCpp/ contains testing_cpp.bridge.g.mm', () {
      final mm = File(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'testing_cpp.bridge.g.mm'));
      expect(mm.existsSync(), isTrue);
    });

    test('iOS SPM TestingProjectCpp/ contains HybridTestingCpp.cpp forwarder', () {
      final cpp = File(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'HybridTestingCpp.cpp'));
      expect(cpp.existsSync(), isTrue);
    });

    test('Dart g.dart binding uses testing_cpp_multiply symbol', () {
      final dart = File(p.join(_fixture.path, 'lib', 'src', 'testing_cpp.g.dart'));
      expect(dart.existsSync(), isTrue);
      final content = dart.readAsStringSync();
      expect(content, contains('class _TestingCppImpl extends TestingCpp'));
      // Symbol naming: <spec_file_stem>_<method>
      expect(content, contains("'testing_cpp_multiply'"));
    });
  });

  group('multi-spec generate — testing_mixed (Swift/Kotlin/C++ per platform)',
      skip: multiSpecSkip(), () {
    test('testing_mixed.bridge.g.swift has @_cdecl stubs (iOS is Swift)', () {
      final swift = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_mixed.bridge.g.swift'));
      expect(swift.existsSync(), isTrue);
      expect(swift.readAsStringSync(), contains('@_cdecl("'),
          reason: 'TestingMixed uses NativeImpl.swift on iOS — Swift @_cdecl stubs required');
    });

    test('testing_mixed.bridge.g.kt declares TestingMixedJniBridge (Android is Kotlin)', () {
      final kt = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_mixed.bridge.g.kt'));
      expect(kt.existsSync(), isTrue);
      final content = kt.readAsStringSync();
      expect(content, contains('TestingMixedJniBridge'),
          reason: 'TestingMixed uses NativeImpl.kotlin on Android');
      expect(content, contains('fun platform()'),
          reason: 'Kotlin interface must declare the platform() method');
    });

    test('testing_mixed.bridge.g.h exists (macOS/Windows/Linux are C++)', () {
      final h = File(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp', 'testing_mixed.bridge.g.h'));
      expect(h.existsSync(), isTrue);
      final content = h.readAsStringSync();
      expect(content, contains('testing_mixed_platform'),
          reason: 'C bridge exports testing_mixed_platform for macOS/desktop C++ path');
    });

    test('iOS SPM TestingProject/ contains testing_mixed.bridge.g.swift', () {
      final swift = File(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProject', 'testing_mixed.bridge.g.swift'));
      expect(swift.existsSync(), isTrue);
    });

    test('iOS SPM TestingProjectCpp/ contains testing_mixed.bridge.g.mm', () {
      final mm = File(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'testing_mixed.bridge.g.mm'));
      expect(mm.existsSync(), isTrue);
    });

    test('Dart g.dart binding uses testing_mixed_platform symbol', () {
      final dart = File(p.join(_fixture.path, 'lib', 'src', 'testing_mixed.g.dart'));
      expect(dart.existsSync(), isTrue);
      final content = dart.readAsStringSync();
      expect(content, contains('class _TestingMixedImpl extends TestingMixed'));
      expect(content, contains("'testing_mixed_platform'"));
    });
  });

  group('multi-spec link — all 3 specs wired into plugin entry points',
      skip: multiSpecSkip(), () {
    test('iOS Plugin.swift registers all Swift modules (testing_project + testing_mixed)', () {
      final swift = File(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProject', 'SwiftTestingProjectPlugin.swift'));
      expect(swift.existsSync(), isTrue);
      final content = swift.readAsStringSync();
      expect(content, contains('TestingProjectRegistry.register('),
          reason: 'TestingProject (Swift) must be registered');
      expect(content, contains('TestingMixedRegistry.register('),
          reason: 'TestingMixed (Swift on iOS) must be registered');
      expect(content, isNot(contains('TestingCppRegistry')),
          reason: 'TestingCpp (NativeImpl.cpp) has no Swift registry — no registration needed');
    });

    test('Android Plugin.kt registers all Kotlin modules (testing_project + testing_mixed)', () {
      final kt = File(p.join(_fixture.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'testing_project', 'TestingProjectPlugin.kt'));
      expect(kt.existsSync(), isTrue);
      final content = kt.readAsStringSync();
      expect(content, contains('TestingProjectJniBridge'),
          reason: 'TestingProject (Kotlin) bridge must be imported/used');
      expect(content, contains('TestingMixedJniBridge'),
          reason: 'TestingMixed (Kotlin on Android) bridge must be imported/used');
      expect(content, isNot(contains('TestingCppJniBridge')),
          reason: 'TestingCpp (NativeImpl.cpp) has no JNI bridge — no registration needed');
    });

    test('CMakeLists.txt includes all 3 spec bridge .cpp files', () {
      final cmake = File(p.join(_fixture.path, 'src', 'CMakeLists.txt'));
      expect(cmake.existsSync(), isTrue);
      final content = cmake.readAsStringSync();
      expect(content, contains('testing_project.bridge.g.cpp'));
      expect(content, contains('testing_cpp.bridge.g.cpp'));
      expect(content, contains('testing_mixed.bridge.g.cpp'));
    });

    test('CMakeLists.txt includes HybridTestingCpp.cpp (NativeImpl.cpp starter)', () {
      final cmake = File(p.join(_fixture.path, 'src', 'CMakeLists.txt'));
      expect(cmake.readAsStringSync(), contains('HybridTestingCpp.cpp'));
    });

    test('iOS Package.swift declares both Swift and C++ SPM targets', () {
      final pkg = File(p.join(_fixture.path, 'ios', 'testing_project', 'Package.swift'));
      expect(pkg.existsSync(), isTrue);
      final content = pkg.readAsStringSync();
      // Swift target uses the plugin name (snake_case)
      expect(content, contains('"testing_project"'),
          reason: 'Swift target named by plugin name for Swift modules');
      // C++ target uses PascalCase + "Cpp" suffix
      expect(content, contains('"TestingProjectCpp"'),
          reason: 'C++ target for NativeImpl.cpp modules and C bridge .mm files');
    });

    test('all 3 spec .bridge.g.mm files present in iOS SPM C++ target', () {
      final cppDir = Directory(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp'));
      final mmFiles = cppDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.mm')).map((f) => p.basename(f.path)).toSet();
      expect(mmFiles, containsAll(['testing_project.bridge.g.mm', 'testing_cpp.bridge.g.mm', 'testing_mixed.bridge.g.mm']));
    });
  });
}
