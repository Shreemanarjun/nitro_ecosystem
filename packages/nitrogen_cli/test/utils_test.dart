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

    test('syncBridgeFiles copies C++ bridge files to ios/Classes and deletes stale Swift bridges', () async {
      // Swift bridges live in lib/src/generated/swift/ and are compiled via the
      // podspec source_files pattern — they must NOT be copied to ios/Classes/.
      // C++ bridge files (.bridge.g.h, .bridge.g.cpp→.mm) are still needed there.
      final iosClasses = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final generatedSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      final generatedCpp = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);

      // Create dummy bridge files — including a stale Swift copy that should be removed.
      File(p.join(generatedSwift.path, 'my.bridge.g.swift')).writeAsStringSync('swift code');
      File(p.join(iosClasses.path, 'my.bridge.g.swift')).writeAsStringSync('stale copy');
      File(p.join(generatedCpp.path, 'my.bridge.g.h')).writeAsStringSync('header code');
      File(p.join(generatedCpp.path, 'my.bridge.g.cpp')).writeAsStringSync('cpp code');

      syncBridgeFiles(temp.path);

      // Swift bridge must NOT be in ios/Classes — compiled from canonical location.
      expect(File(p.join(iosClasses.path, 'my.bridge.g.swift')).existsSync(), isFalse,
          reason: 'Swift bridges are served via podspec source_files, not ios/Classes/');
      // C++ bridge files must still be present.
      expect(File(p.join(iosClasses.path, 'my.bridge.g.h')).existsSync(), isTrue);
      // .cpp should be renamed to .mm for Objective-C++ support on iOS.
      expect(File(p.join(iosClasses.path, 'my.bridge.g.mm')).existsSync(), isTrue);
      expect(File(p.join(iosClasses.path, 'my.bridge.g.mm')).readAsStringSync(), equals('cpp code'));
      expect(File(p.join(iosClasses.path, 'my.bridge.g.cpp')).existsSync(), isFalse);
    });

    // ── NativeImpl.cpp Swift-bridge exclusion ─────────────────────────────────

    // Helper: writes a minimal .native.dart spec into lib/ so _discoverCppLibs
    // can detect whether the module is a direct C++ implementation.
    void writeNativeSpec(String libName, {required bool isCpp, String? customAnnotation}) {
      final libDir = Directory(p.join(temp.path, 'lib'))..createSync(recursive: true);
      final annotation = customAnnotation ?? (isCpp
          ? 'ios: NativeImpl.cpp, android: NativeImpl.cpp'
          : 'ios: NativeImpl.swift, android: NativeImpl.kotlin');
      File(p.join(libDir.path, '$libName.native.dart')).writeAsStringSync(
        '@NitroModule(lib: "$libName", $annotation)\n'
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

    test('.bridge.g.swift for non-cpp module is NOT in ios/Classes (served from canonical location)', () async {
      // Swift bridges are compiled directly from lib/src/generated/swift/ via the
      // podspec source_files pattern — no copy in ios/Classes/ is needed or wanted.
      final classesDir = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'swift_mod.bridge.g.swift')).writeAsStringSync('swift code');
      // Plant a stale copy — syncBridgeFiles must delete it.
      File(p.join(classesDir.path, 'swift_mod.bridge.g.swift')).writeAsStringSync('stale');

      writeNativeSpec('swift_mod', isCpp: false);

      syncBridgeFiles(temp.path);

      expect(
        File(p.join(classesDir.path, 'swift_mod.bridge.g.swift')).existsSync(),
        isFalse,
        reason: 'Swift bridge is compiled from lib/src/generated/swift/ — copies in ios/Classes/ cause "Invalid redeclaration" errors',
      );
    });

    test('skips .bridge.g.swift when macos-only NativeImpl.cpp spec', () async {
      // macos: NativeImpl.cpp alone — still detected as cpp; Swift bridge excluded.
      final classesDir = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'macos_mod.bridge.g.swift')).writeAsStringSync('swift stubs');

      writeNativeSpec('macos_mod', isCpp: false, customAnnotation: 'macos: NativeImpl.cpp');

      syncBridgeFiles(temp.path);

      expect(
        File(p.join(classesDir.path, 'macos_mod.bridge.g.swift')).existsSync(),
        isFalse,
        reason: 'macos: NativeImpl.cpp is cpp — Swift stubs must be excluded',
      );
    });

    test('syncBridgeFiles is no-op when ios/Classes/ does not exist', () async {
      // No ios/ directory — should not crash.
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'mod.bridge.g.swift')).writeAsStringSync('code');
      expect(() => syncBridgeFiles(temp.path), returnsNormally);
    });

    test('syncBridgeFiles is no-op when lib/src/generated/ does not exist', () async {
      Directory(p.join(temp.path, 'ios', 'Classes')).createSync(recursive: true);
      // No generated/ directory — should not crash.
      expect(() => syncBridgeFiles(temp.path), returnsNormally);
    });

    test('syncBridgeFiles(platform: macos) copies C++ bridges to macos/Classes/ and removes stale Swift bridges', () async {
      final macosClasses = Directory(p.join(temp.path, 'macos', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      final genCpp = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'my.bridge.g.swift')).writeAsStringSync('swift code');
      // Stale copy in macos/Classes/ — must be deleted.
      File(p.join(macosClasses.path, 'my.bridge.g.swift')).writeAsStringSync('stale');
      File(p.join(genCpp.path, 'my.bridge.g.h')).writeAsStringSync('header code');
      File(p.join(genCpp.path, 'my.bridge.g.cpp')).writeAsStringSync('cpp code');

      syncBridgeFiles(temp.path, platform: 'macos');

      // Swift bridge: stale copy must be removed.
      expect(File(p.join(macosClasses.path, 'my.bridge.g.swift')).existsSync(), isFalse,
          reason: 'Swift bridge is compiled from canonical location via podspec — copies cause redeclaration errors');
      // C++ bridge files must still be present.
      expect(File(p.join(macosClasses.path, 'my.bridge.g.h')).existsSync(), isTrue);
      expect(File(p.join(macosClasses.path, 'my.bridge.g.mm')).existsSync(), isTrue,
          reason: '.bridge.g.cpp is renamed to .mm for Objective-C++ on macOS too');
      expect(File(p.join(macosClasses.path, 'my.bridge.g.cpp')).existsSync(), isFalse);
    });

    test('syncBridgeFiles(platform: macos) is no-op when macos/Classes/ does not exist', () async {
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'mod.bridge.g.swift')).writeAsStringSync('code');
      expect(() => syncBridgeFiles(temp.path, platform: 'macos'), returnsNormally);
    });

    test('syncBridgeFiles(platform: macos) skips .bridge.g.swift for cpp module', () async {
      final macosClasses = Directory(p.join(temp.path, 'macos', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('stubs');
      writeNativeSpec('cpp_mod', isCpp: true);

      syncBridgeFiles(temp.path, platform: 'macos');

      expect(File(p.join(macosClasses.path, 'cpp_mod.bridge.g.swift')).existsSync(), isFalse,
          reason: 'C++ modules do not use the Swift bridge on macOS either');
    });

    test('syncBridgeFiles(platform: macos) removes stale .bridge.g.swift for cpp module', () async {
      final macosClasses = Directory(p.join(temp.path, 'macos', 'Classes'))..createSync(recursive: true);
      File(p.join(macosClasses.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('stale');
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('stubs');
      writeNativeSpec('cpp_mod', isCpp: true);

      syncBridgeFiles(temp.path, platform: 'macos');

      expect(File(p.join(macosClasses.path, 'cpp_mod.bridge.g.swift')).existsSync(), isFalse);
    });

    test('mixed project: neither Swift nor C++ module bridge in ios/Classes/ (stale copies deleted)', () async {
      // Both Swift-backed and C++-backed Swift bridges live in lib/src/generated/swift/.
      // Neither should be in ios/Classes/ — the podspec picks them up from the canonical location.
      final classesDir = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'swift_mod.bridge.g.swift')).writeAsStringSync('swift bridge');
      File(p.join(genSwift.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('unwanted stubs');
      // Plant stale copies that should be removed.
      File(p.join(classesDir.path, 'swift_mod.bridge.g.swift')).writeAsStringSync('stale swift');
      File(p.join(classesDir.path, 'cpp_mod.bridge.g.swift')).writeAsStringSync('stale cpp');

      writeNativeSpec('swift_mod', isCpp: false);
      writeNativeSpec('cpp_mod', isCpp: true);

      syncBridgeFiles(temp.path);

      expect(File(p.join(classesDir.path, 'swift_mod.bridge.g.swift')).existsSync(), isFalse,
          reason: 'Swift module bridge: compiled from canonical location, not ios/Classes/');
      expect(File(p.join(classesDir.path, 'cpp_mod.bridge.g.swift')).existsSync(), isFalse,
          reason: 'C++ module bridge: never needed in ios/Classes/');
    });

    test('skips .bridge.g.swift when any platform (ios-only) is NativeImpl.cpp', () async {
      // ios: NativeImpl.cpp means iOS uses direct C++ — the Swift @_cdecl stubs
      // must NOT land in ios/Classes/ or they cause duplicate-symbol linker errors.
      final classesDir = Directory(p.join(temp.path, 'ios', 'Classes'))..createSync(recursive: true);
      final genSwift = Directory(p.join(temp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(genSwift.path, 'mixed.bridge.g.swift')).writeAsStringSync('swift stubs');

      writeNativeSpec('mixed', isCpp: false, customAnnotation: 'ios: NativeImpl.cpp, android: NativeImpl.kotlin');

      syncBridgeFiles(temp.path);

      expect(
        File(p.join(classesDir.path, 'mixed.bridge.g.swift')).existsSync(),
        isFalse,
        reason: 'Any platform using NativeImpl.cpp excludes the Swift bridge — duplicate-symbol guard',
      );
    });
  });
}
