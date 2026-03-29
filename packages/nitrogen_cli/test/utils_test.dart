import 'dart:io';
import 'package:test/test.dart';
import 'package:nitrogen_cli/utils.dart';
import 'package:path/path.dart' as p;

void main() {
  group('Nitrogen Utils', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('nitro_test_utils_');
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('parsePubspec returns correct info for a Nitro project', () {
      final pubspec = File(p.join(temp.path, 'pubspec.yaml'));
      pubspec.writeAsStringSync('''
name: my_plugin
version: 1.2.3
dependencies:
  nitro: ^0.1.0
''');

      final info = parsePubspec(temp);
      expect(info, isNotNull);
      expect(info!.name, equals('my_plugin'));
      expect(info.version, equals('1.2.3'));
    });

    test('parsePubspec returns null for a non-Nitro project', () {
      final pubspec = File(p.join(temp.path, 'pubspec.yaml'));
      pubspec.writeAsStringSync('''
name: normal_plugin
version: 1.0.0
dependencies:
  flutter:
    sdk: flutter
''');

      final info = parsePubspec(temp);
      expect(info, isNull);
    });

    test('getAllProjects discovers multiple modules in subdirectories', () async {
      // Setup:
      // root/ (temp)
      //  packages/
      //    nitro_one/ (nitro)
      //    nitro_two/ (nitro)
      //    normal/    (not nitro)
      //  apps/
      //    my_app/    (nitro)

      final packagesDir = await Directory(p.join(temp.path, 'packages')).create();
      final p1 = await Directory(p.join(packagesDir.path, 'nitro_one')).create();
      final p2 = await Directory(p.join(packagesDir.path, 'nitro_two')).create();
      final p3 = await Directory(p.join(packagesDir.path, 'normal')).create();

      final appsDir = await Directory(p.join(temp.path, 'apps')).create();
      final a1 = await Directory(p.join(appsDir.path, 'my_app')).create();

      File(p.join(p1.path, 'pubspec.yaml')).writeAsStringSync('name: nitro_one\ndependencies:\n  nitro: any');
      File(p.join(p2.path, 'pubspec.yaml')).writeAsStringSync('name: nitro_two\ndependencies:\n  nitro_generator: any');
      File(p.join(p3.path, 'pubspec.yaml')).writeAsStringSync('name: normal\ndependencies:\n  flutter: any');
      File(p.join(a1.path, 'pubspec.yaml')).writeAsStringSync('name: my_app\ndependencies:\n  nitro: any');

      final projects = getAllProjects(baseDir: temp);
      // Should find nitro_one, nitro_two, my_app
      expect(projects.length, equals(3));

      final names = projects.map((p) => p.name).toSet();
      expect(names.contains('nitro_one'), isTrue);
      expect(names.contains('nitro_two'), isTrue);
      expect(names.contains('my_app'), isTrue);
      expect(names.contains('normal'), isFalse);
    });

    test('syncBridgeFiles correctly copies and renames bridge files to ios/Classes', () async {
      // Setup mock file structure in temp dir
      final iosClasses = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final generatedSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      final generatedCpp = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);

      // Create dummy bridge files
      File(p.join(generatedSwift.path, 'my.bridge.g.swift')).writeAsStringSync('swift code');
      File(p.join(generatedCpp.path, 'my.bridge.g.h')).writeAsStringSync('header code');
      File(p.join(generatedCpp.path, 'my.bridge.g.cpp')).writeAsStringSync('cpp code');

      // Run sync utility
      syncBridgeFiles(temp.path);

      // Verify they now exist in ios/Classes
      expect(File(p.join(iosClasses.path, 'my.bridge.g.swift')).existsSync(), isTrue);
      expect(File(p.join(iosClasses.path, 'my.bridge.g.h')).existsSync(), isTrue);
      // .cpp should be renamed to .mm for Objective-C++ support on iOS
      expect(File(p.join(iosClasses.path, 'my.bridge.g.mm')).existsSync(), isTrue);
      expect(File(p.join(iosClasses.path, 'my.bridge.g.mm')).readAsStringSync(), equals('cpp code'));
      // The original .cpp should NOT be in ios/Classes (it was renamed/copied)
      expect(File(p.join(iosClasses.path, 'my.bridge.g.cpp')).existsSync(), isFalse);
    });

    // ── NativeImpl.cpp Swift-bridge exclusion ─────────────────────────────────

    // Helper: writes a minimal .native.dart spec into lib/ so _discoverCppLibs
    // can detect whether the module is a direct C++ implementation.
    void writeNativeSpec(String libName, {required bool isCpp}) {
      final libDir = Directory(p.join(temp.path, 'lib'))..createSync(recursive: true);
      final impl = isCpp ? 'NativeImpl.cpp' : 'NativeImpl.swift';
      final otherImpl = isCpp ? 'NativeImpl.cpp' : 'NativeImpl.kotlin';
      File(p.join(libDir.path, '$libName.native.dart')).writeAsStringSync(
        '@NitroModule(lib: "$libName", iosImpl: $impl, androidImpl: $otherImpl)\n'
        'abstract class ${libName[0].toUpperCase()}${libName.substring(1)} extends HybridObject {}\n',
      );
    }

    test('skips .bridge.g.swift for a NativeImpl.cpp module', () async {
      Directory(p.join(temp.path, 'ios', 'Classes')).createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('swift stubs');

      writeNativeSpec('cpp_mod', isCpp: true);

      syncBridgeFiles(temp.path);

      expect(
        File(p.join(temp.path, 'ios', 'Classes', 'cpp_mod.bridge.g.swift')).existsSync(),
        isFalse,
        reason: 'C++ bridge calls g_impl directly — the Swift @_cdecl stubs must not be compiled',
      );
    });

    test('removes a stale .bridge.g.swift from ios/Classes when module is NativeImpl.cpp', () async {
      final classesDir = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      // Pre-existing stale copy from a previous run before the module was converted.
      File(p.join(classesDir.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('stale');

      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('swift stubs');

      writeNativeSpec('cpp_mod', isCpp: true);

      syncBridgeFiles(temp.path);

      expect(
        File(p.join(classesDir.path, 'cpp_mod.bridge.g.swift')).existsSync(),
        isFalse,
        reason: 'stale Swift bridge file must be deleted for NativeImpl.cpp modules',
      );
    });

    test('still copies .bridge.g.swift for a non-cpp (Swift/Kotlin) module', () async {
      final classesDir = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'swift_mod.bridge.g.swift')).writeAsStringSync('swift code');

      writeNativeSpec('swift_mod', isCpp: false);

      syncBridgeFiles(temp.path);

      expect(
        File(p.join(classesDir.path, 'swift_mod.bridge.g.swift')).existsSync(),
        isTrue,
        reason: 'Swift-backed modules still need their .bridge.g.swift in ios/Classes',
      );
    });

    test('mixed project: copies Swift module bridge but skips C++ module bridge', () async {
      final classesDir = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'swift_mod.bridge.g.swift')).writeAsStringSync('swift bridge');
      File(p.join(genSwift.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('unwanted stubs');

      writeNativeSpec('swift_mod', isCpp: false);
      writeNativeSpec('cpp_mod', isCpp: true);

      syncBridgeFiles(temp.path);

      expect(File(p.join(classesDir.path, 'swift_mod.bridge.g.swift')).existsSync(), isTrue);
      expect(File(p.join(classesDir.path, 'cpp_mod.bridge.g.swift')).existsSync(), isFalse);
    });

    test('copies .bridge.g.swift when only one platform is NativeImpl.cpp (not both)', () async {
      // A module where only iosImpl is NativeImpl.cpp is NOT a fully-cpp module;
      // it still uses the Swift bridge on iOS and needs the .bridge.g.swift.
      final classesDir = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'mixed.bridge.g.swift')).writeAsStringSync('swift bridge');

      final libDir = Directory(p.join(temp.path, 'lib'))..createSync(recursive: true);
      File(p.join(libDir.path, 'mixed.native.dart')).writeAsStringSync(
        '@NitroModule(lib: "mixed", iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.kotlin)\n'
        'abstract class Mixed extends HybridObject {}\n',
      );

      syncBridgeFiles(temp.path);

      expect(
        File(p.join(classesDir.path, 'mixed.bridge.g.swift')).existsSync(),
        isTrue,
        reason: 'Only both-platform cpp counts as NativeImpl.cpp; one-platform cpp is not excluded',
      );
    });
  });
}
