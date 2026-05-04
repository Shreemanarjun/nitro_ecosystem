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
    show
        linkSwiftPlugin,
        linkMacosSwiftPlugin,
        linkKotlinPlugin,
        linkKotlinLoadLibraries,
        linkPodspec,
        createSharedHeaders,
        ModuleInfo;
import 'package:nitrogen_cli/commands/scaffold_templates.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Absolute path to the monorepo root (two levels above packages/nitrogen_cli).
String get _repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

/// The pre-built fixture project under test_projects/.
Directory get _fixture =>
    Directory(p.join(_repoRoot, 'test_projects', 'testing_project'));

/// The local nitro package native sources path (used to seed headers).
String get _nitroNativePath =>
    p.join(_repoRoot, 'packages', 'nitro', 'src', 'native');

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
  final className =
      name.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');

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
  File(p.join(srcDir.path, 'dart_api_dl.c'))
      .writeAsStringSync('// placeholder\n#include "../../packages/nitro/src/native/dart_api_dl.c"\n');
  File(p.join(srcDir.path, 'CMakeLists.txt')).writeAsStringSync(cmakeListsTemplate(name));

  // ios/Classes/
  final iosClasses = Directory(p.join(root.path, 'ios', 'Classes'))..createSync(recursive: true);
  File(p.join(iosClasses.path, '$name.cpp')).writeAsStringSync('#include "../../src/$name.cpp"\n');
  File(p.join(iosClasses.path, 'dart_api_dl.c'))
      .writeAsStringSync('// Forwarder\n#include "../../src/dart_api_dl.c"\n');
  File(p.join(iosClasses.path, 'Swift${className}Plugin.swift'))
      .writeAsStringSync(iosSwiftPluginTemplate(className));
  File(p.join(iosClasses.path, '${className}Impl.swift'))
      .writeAsStringSync(iosSwiftImplTemplate(className));

  // ios/Classes/<name>.bridge.g.swift symlink (dangling before generate)
  Link(p.join(iosClasses.path, '$name.bridge.g.swift'))
      .createSync('../../lib/src/generated/swift/$name.bridge.g.swift');

  // ios/<name>/Package.swift (nested SPM layout)
  final iosPackageDir =
      Directory(p.join(root.path, 'ios', name))..createSync(recursive: true);
  final iosSwiftSrc =
      Directory(p.join(iosPackageDir.path, 'Sources', className))..createSync(recursive: true);
  final iosCppSrc =
      Directory(p.join(iosPackageDir.path, 'Sources', '${className}Cpp'))
        ..createSync(recursive: true);
  Directory(p.join(iosCppSrc.path, 'include')).createSync(recursive: true);

  // SPM symlinks
  for (final fn in ['Swift${className}Plugin.swift', '${className}Impl.swift', '$name.bridge.g.swift']) {
    try { Link(p.join(iosSwiftSrc.path, fn)).createSync('../../../Classes/$fn'); } catch (_) {}
  }
  File(p.join(iosCppSrc.path, '$name.cpp'))
      .writeAsStringSync('// Generated by nitrogen init\n#include "../../../Classes/$name.cpp"\n');
  File(p.join(iosCppSrc.path, 'dart_api_dl.c'))
      .writeAsStringSync('// Dart DL API\n#include "../../../.symlinks/plugins/nitro/src/native/dart_api_dl.c"\n');
  // bridge.g.mm — created by nitrogen init; nitrogen link rewrites with resolved paths.
  File(p.join(iosCppSrc.path, '$name.bridge.g.mm'))
      .writeAsStringSync('// Generated by nitrogen init — do not edit.\n'
          '#import <Foundation/Foundation.h>\n'
          '#include "../../../../lib/src/generated/cpp/$name.bridge.g.cpp"\n');
  File(p.join(iosPackageDir.path, 'Package.swift'))
      .writeAsStringSync(packageSwiftTemplate(name, className, 'iOS(.v13)'));

  // macos/Classes/ + macos/<name>/Package.swift
  final macosClasses =
      Directory(p.join(root.path, 'macos', 'Classes'))..createSync(recursive: true);
  File(p.join(macosClasses.path, '$name.cpp')).writeAsStringSync('#include "../../src/$name.cpp"\n');
  File(p.join(macosClasses.path, 'dart_api_dl.c'))
      .writeAsStringSync('// Forwarder\n#include "../../src/dart_api_dl.c"\n');
  File(p.join(macosClasses.path, 'Swift${className}Plugin.swift'))
      .writeAsStringSync(macosSwiftPluginTemplate(className));
  File(p.join(macosClasses.path, '${className}Impl.swift'))
      .writeAsStringSync(macosSwiftImplTemplate(className));
  Link(p.join(macosClasses.path, '$name.bridge.g.swift'))
      .createSync('../../lib/src/generated/swift/$name.bridge.g.swift');

  final macosPackageDir =
      Directory(p.join(root.path, 'macos', name))..createSync(recursive: true);
  final macosSwiftSrc =
      Directory(p.join(macosPackageDir.path, 'Sources', className))..createSync(recursive: true);
  final macosCppSrc =
      Directory(p.join(macosPackageDir.path, 'Sources', '${className}Cpp'))
        ..createSync(recursive: true);
  Directory(p.join(macosCppSrc.path, 'include')).createSync(recursive: true);

  for (final fn in ['Swift${className}Plugin.swift', '${className}Impl.swift', '$name.bridge.g.swift']) {
    try { Link(p.join(macosSwiftSrc.path, fn)).createSync('../../../Classes/$fn'); } catch (_) {}
  }
  File(p.join(macosCppSrc.path, '$name.cpp'))
      .writeAsStringSync('// Generated by nitrogen init\n#include "../../../Classes/$name.cpp"\n');
  File(p.join(macosCppSrc.path, 'dart_api_dl.c'))
      .writeAsStringSync('// Dart DL API\n#include "../../../Flutter/ephemeral/.symlinks/plugins/nitro/src/native/dart_api_dl.c"\n');
  // bridge.g.mm — created by nitrogen init; nitrogen link rewrites with resolved paths.
  File(p.join(macosCppSrc.path, '$name.bridge.g.mm'))
      .writeAsStringSync('// Generated by nitrogen init — do not edit.\n'
          '#import <Foundation/Foundation.h>\n'
          '#include "../../../../lib/src/generated/cpp/$name.bridge.g.cpp"\n');
  File(p.join(macosPackageDir.path, 'Package.swift'))
      .writeAsStringSync(packageSwiftTemplate(name, className, 'macOS(.v10_15)', isMacos: true));

  // android/
  final orgPath = org.replaceAll('.', p.separator);
  final kotlinDir = Directory(p.join(root.path, 'android', 'src', 'main', 'kotlin', orgPath, name))
    ..createSync(recursive: true);
  final moduleName = '${name}_module';
  File(p.join(root.path, 'android', 'build.gradle'))
      .writeAsStringSync(androidBuildGradleTemplate(org, name));
  File(p.join(kotlinDir.path, '${className}Plugin.kt'))
      .writeAsStringSync(androidPluginKtTemplate(org, name, className, moduleName));
  File(p.join(kotlinDir.path, '${className}Impl.kt'))
      .writeAsStringSync(androidImplKtTemplate(org, name, className, moduleName));

  // lib/src/<name>.native.dart
  final libSrc = Directory(p.join(root.path, 'lib', 'src'))..createSync(recursive: true);
  const annotation = '@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)';
  File(p.join(libSrc.path, '$name.native.dart'))
      .writeAsStringSync(nativeDartTemplate(name, className, annotation));
  File(p.join(root.path, 'lib', '$name.dart'))
      .writeAsStringSync("export 'src/$name.native.dart';\n");

  // lib/src/generated/swift + cpp + kotlin (stubs — link will populate include/)
  Directory(p.join(libSrc.path, 'generated', 'swift')).createSync(recursive: true);
  Directory(p.join(libSrc.path, 'generated', 'cpp')).createSync(recursive: true);
  Directory(p.join(libSrc.path, 'generated', 'kotlin')).createSync(recursive: true);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
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
      expect(out, contains('${className}JniBridge.register('));
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

  group(
    'nitrogen init — testing_project fixture structure',
    skip: _fixture.existsSync() ? null : 'test_projects/testing_project not found — run from monorepo root',
    () {

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
      expect(pkg.existsSync(), isTrue,
          reason: 'Nested Package.swift must exist at ios/testing_project/Package.swift');
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
        Directory(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProject'))
            .existsSync(),
        isTrue,
      );
    });

    test('ios/testing_project/Sources/TestingProjectCpp/ directory exists', () {
      expect(
        Directory(p.join(_fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp'))
            .existsSync(),
        isTrue,
      );
    });

    test('ios/testing_project/Sources/TestingProjectCpp/include/ has nitro headers', () {
      final incl = Directory(p.join(
          _fixture.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'include'));
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
      final kt = File(p.join(
        _fixture.path,
        'android', 'src', 'main', 'kotlin',
        'com', 'example', 'testing_project',
        'TestingProjectPlugin.kt',
      ));
      expect(kt.existsSync(), isTrue);
      final content = kt.readAsStringSync();
      expect(content, contains('TestingProjectJniBridge'));
      expect(content, contains('System.loadLibrary("testing_project")'));
      expect(content, contains('TestingProjectJniBridge.register('));
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

  group(
    'nitrogen generate — testing_project generated output',
    skip: _fixture.existsSync() ? null : 'test_projects/testing_project not found',
    () {

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
      final gen = File(p.join(
          _fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_project.bridge.g.swift'));
      expect(gen.existsSync(), isTrue);
      final content = gen.readAsStringSync();
      expect(content, contains('// Generated by Nitrogen Modules'));
      expect(content, contains('HybridTestingProjectProtocol'));
      expect(content, contains('TestingProjectRegistry'));
      expect(content, contains('func add(a: Double, b: Double) -> Double'));
      expect(content, contains('func getGreeting(name: String) async throws -> String'));
    });

    test('lib/src/generated/kotlin/testing_project.bridge.g.kt — Kotlin bridge', () {
      final gen = File(p.join(
          _fixture.path, 'lib', 'src', 'generated', 'kotlin', 'testing_project.bridge.g.kt'));
      expect(gen.existsSync(), isTrue);
      final content = gen.readAsStringSync();
      expect(content, contains('// Generated by Nitrogen Modules'));
      expect(content, contains('package nitro.testing_project_module'));
      expect(content, contains('HybridTestingProjectSpec'));
    });

    test('lib/src/generated/cpp/ bridge files exist', () {
      final cppDir =
          Directory(p.join(_fixture.path, 'lib', 'src', 'generated', 'cpp'));
      expect(cppDir.existsSync(), isTrue);
      final files = cppDir.listSync().map((e) => p.basename(e.path)).toList();
      expect(files.any((f) => f.endsWith('.bridge.g.h')), isTrue,
          reason: 'C++ bridge header must be generated');
      expect(files.any((f) => f.endsWith('.bridge.g.cpp')), isTrue,
          reason: 'C++ bridge impl must be generated');
    });

    test('generated .g.dart has correct init symbol name', () {
      final gen = File(p.join(_fixture.path, 'lib', 'src', 'testing_project.g.dart'));
      final content = gen.readAsStringSync();
      // Symbol follows pattern: <lib>_init_dart_api_dl
      expect(content, contains('testing_project_init_dart_api_dl'));
    });

    test('Swift bridge has @_cdecl stub with namespace prefix', () {
      final gen = File(p.join(
          _fixture.path, 'lib', 'src', 'generated', 'swift', 'testing_project.bridge.g.swift'));
      final content = gen.readAsStringSync();
      // @_cdecl uses _<namespace>_call_<methodName> format.
      // The testing_project spec has no explicit namespace so the generator
      // defaults to the snake_case class name: "testing_project".
      expect(content, contains('@_cdecl("_testing_project_call_add")'));
    });
  });

  // ── 4. nitrogen link — integration against temp copy ─────────────────────────

  group(
    'nitrogen link — integration (temp copy of fixture)',
    skip: _fixture.existsSync() ? null : 'test_projects/testing_project not found',
    () {
    late Directory tmp;
    late Directory originalDir;

    setUp(() {
      originalDir = Directory.current;
      tmp = Directory.systemTemp.createTempSync('nitro_link_integration_');
      _copyDir(_fixture, tmp);
    });

    tearDown(() {
      Directory.current = originalDir;
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
        [{'module': 'TestingProject', 'lib': 'testing_project'}],
        baseDir: tmp.path,
      );

      final content = pluginFile.readAsStringSync();
      expect(content, contains('TestingProjectRegistry.register('));
    });

    test('linkMacosSwiftPlugin injects TestingProjectRegistry.register into macos Plugin.swift', () {
      final pluginFile = File(
          p.join(tmp.path, 'macos', 'Classes', 'SwiftTestingProjectPlugin.swift'));
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
        [{'module': 'TestingProject', 'lib': 'testing_project'}],
        baseDir: tmp.path,
      );

      final content = pluginFile.readAsStringSync();
      expect(content, contains('TestingProjectRegistry.register('));
    });

    test('linkKotlinPlugin injects JniBridge.register into Plugin.kt', () {
      final pluginFile = File(p.join(
        tmp.path,
        'android', 'src', 'main', 'kotlin',
        'com', 'example', 'testing_project',
        'TestingProjectPlugin.kt',
      ));
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
        [{'module': 'TestingProject', 'lib': 'testing_project'}],
        baseDir: tmp.path,
      );

      final content = pluginFile.readAsStringSync();
      expect(content, contains('TestingProjectJniBridge'));
      expect(content, contains('TestingProjectJniBridge.register('));
    });

    test('linkKotlinLoadLibraries injects System.loadLibrary when missing', () {
      final pluginFile = File(p.join(
        tmp.path,
        'android', 'src', 'main', 'kotlin',
        'com', 'example', 'testing_project',
        'TestingProjectPlugin.kt',
      ));
      final content = pluginFile.readAsStringSync();
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
        final mm = File(p.join(
          tmp.path, platform, 'testing_project', 'Sources',
          'TestingProjectCpp', 'testing_project.bridge.g.mm',
        ));
        expect(mm.existsSync(), isTrue,
            reason: '$platform bridge.g.mm forwarder must exist so the C bridge symbols are compiled under SPM');
        final content = mm.readAsStringSync();
        expect(content, contains('#import <Foundation/Foundation.h>'),
            reason: 'Foundation import is required for NSException in the @catch blocks');
        expect(content, contains('testing_project.bridge.g.cpp'),
            reason: 'forwarder must include the generated bridge .cpp');
      }
    });

    test('linkPodspec writes bridge.g.mm even when bridge.g.cpp does not exist yet', () {
      // Regression: previously nitrogen link guarded bridge.g.mm creation behind
      // existsSync() on the generated .bridge.g.cpp.  If the user ran link before
      // generate, the bridge.g.mm was never created and the app crashed with
      // "Failed to lookup symbol '<plugin>_init_dart_api_dl'".
      // Now link must write the forwarder unconditionally.
      final bridgeCpp = File(p.join(
        tmp.path, 'lib', 'src', 'generated', 'cpp', 'testing_project.bridge.g.cpp',
      ));
      if (bridgeCpp.existsSync()) bridgeCpp.deleteSync();

      linkPodspec(
        'testing_project',
        ['testing_project'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'testing_project', module: 'TestingProject', isCpp: false)],
      );

      for (final platform in ['ios', 'macos']) {
        final mm = File(p.join(
          tmp.path, platform, 'testing_project', 'Sources',
          'TestingProjectCpp', 'testing_project.bridge.g.mm',
        ));
        expect(mm.existsSync(), isTrue,
            reason: '$platform bridge.g.mm must be written even before nitrogen generate is run');
        expect(mm.readAsStringSync(), contains('testing_project.bridge.g.cpp'),
            reason: 'forwarder path must reference the (not-yet-generated) bridge .cpp');
      }
    });

    test('createSharedHeaders populates ios include/ with dart_api.h and nitro.h', () {
      final includeDir = Directory(p.join(
          tmp.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'include'));
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
        final incl = Directory(p.join(
            tmp.path, platform, 'testing_project', 'Sources', 'TestingProjectCpp', 'include'));
        expect(File(p.join(incl.path, 'dart_api.h')).existsSync(), isTrue,
            reason: '$platform include/dart_api.h must exist after createSharedHeaders');
        expect(File(p.join(incl.path, 'nitro.h')).existsSync(), isTrue,
            reason: '$platform include/nitro.h must exist after createSharedHeaders');
      }
    });

    test('linkSwiftPlugin is idempotent — no duplicate registrations', () {
      final modules = [{'module': 'TestingProject', 'lib': 'testing_project'}];
      linkSwiftPlugin('testing_project', modules, baseDir: tmp.path);
      linkSwiftPlugin('testing_project', modules, baseDir: tmp.path);

      final pluginFile = File(
          p.join(tmp.path, 'ios', 'Classes', 'SwiftTestingProjectPlugin.swift'));
      final count = RegExp(r'TestingProjectRegistry\.register')
          .allMatches(pluginFile.readAsStringSync())
          .length;
      expect(count, equals(1), reason: 'Registration must not be duplicated');
    });

    test('keeps Hybrid*.cpp forwarder for Apple cpp module', () {
      // Simulate a second module (gpu) that uses AppleNativeImpl.cpp.
      // The fixture uses nested SPM layout: ios/testing_project/Package.swift
      // so the SPM C++ target is at ios/testing_project/Sources/TestingProjectCpp/.

      // Bridge generated files
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))
        ..createSync(recursive: true);
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
      final forwarder = File(p.join(
        tmp.path, 'ios', 'testing_project', 'Sources', 'TestingProjectCpp', 'HybridGpu.cpp',
      ));
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
    late Directory originalDir;

    setUp(() {
      originalDir = Directory.current;
      tmp = Directory.systemTemp.createTempSync('nitro_scaffold_test_');
      Directory.current = tmp;
      _scaffoldPlugin(tmp, 'my_plugin', 'com.example');
    });

    tearDown(() {
      Directory.current = originalDir;
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
      expect(pkg.existsSync(), isTrue,
          reason: 'Package.swift must be at ios/<name>/Package.swift, not ios/Package.swift');
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
      final mm = File(p.join(
        tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPluginCpp', 'my_plugin.bridge.g.mm',
      ));
      expect(mm.existsSync(), isTrue,
          reason: 'nitrogen init must create bridge.g.mm in SPM C++ target');
      final content = mm.readAsStringSync();
      expect(content, contains('#import <Foundation/Foundation.h>'),
          reason: 'Foundation import required for NSException/Obj-C++ bridge');
      expect(content, contains('my_plugin.bridge.g.cpp'),
          reason: 'forwarder must reference the generated bridge .cpp');
    });

    test('macos/my_plugin/Sources/MyPluginCpp/my_plugin.bridge.g.mm created by init', () {
      final mm = File(p.join(
        tmp.path, 'macos', 'my_plugin', 'Sources', 'MyPluginCpp', 'my_plugin.bridge.g.mm',
      ));
      expect(mm.existsSync(), isTrue,
          reason: 'nitrogen init must create bridge.g.mm in macOS SPM C++ target');
      expect(mm.readAsStringSync(), contains('my_plugin.bridge.g.cpp'));
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
      final base = p.join(
          tmp.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'my_plugin');
      expect(File(p.join(base, 'MyPluginPlugin.kt')).existsSync(), isTrue);
      expect(File(p.join(base, 'MyPluginImpl.kt')).existsSync(), isTrue);
    });

    test('android Impl.kt implements HybridMyPluginSpec', () {
      final kt = File(p.join(
          tmp.path, 'android', 'src', 'main', 'kotlin',
          'com', 'example', 'my_plugin', 'MyPluginImpl.kt'));
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

    test('CMakeLists NITRO_NATIVE placeholder references src/native path', () {
      final cmake = File(p.join(tmp.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      // Placeholder points at monorepo — will be resolved by nitrogen link
      expect(cmake, contains('NITRO_NATIVE'));
    });

    test('link functions work on scaffolded project — Swift registration injected', () {
      // Create a minimal generated dir so linkSwiftPlugin has a target
      Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'swift'))
          .createSync(recursive: true);

      linkSwiftPlugin(
        'my_plugin',
        [{'module': 'MyPlugin', 'lib': 'my_plugin'}],
        baseDir: tmp.path,
      );

      final swift = File(p.join(tmp.path, 'ios', 'Classes', 'SwiftMyPluginPlugin.swift'));
      expect(swift.readAsStringSync(), contains('MyPluginRegistry.register('));
    });

    test('link functions work on scaffolded project — Kotlin registration injected', () {
      linkKotlinPlugin(
        'my_plugin',
        [{'module': 'MyPlugin', 'lib': 'my_plugin'}],
        baseDir: tmp.path,
      );

      final kt = File(p.join(
          tmp.path, 'android', 'src', 'main', 'kotlin',
          'com', 'example', 'my_plugin', 'MyPluginPlugin.kt'));
      expect(kt.readAsStringSync(), contains('MyPluginJniBridge.register('));
    });
  });
}
