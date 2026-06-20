// Integration tests verifying that nitrogen link places generated files
// in the correct locations for each platform before a release build.
//
// These tests are the "build-readiness benchmark" — if they all pass,
// the file placement is correct enough for ios/macos/android/windows/linux
// builds to succeed.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:test/test.dart';

// ── Scaffold helpers ──────────────────────────────────────────────────────────

/// Creates a minimal Flutter plugin project with all common platform dirs.
Directory _scaffoldPlugin(Directory tmp, String pluginName, {List<String> platforms = const ['ios', 'macos', 'android', 'windows', 'linux']}) {
  final root = Directory(p.join(tmp.path, pluginName))..createSync(recursive: true);
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: $pluginName
version: 0.0.1
dependencies:
  nitro: any
flutter:
  plugin:
    platforms:
      android:
        package: com.example.$pluginName
        pluginClass: ${_toPascal(pluginName)}Plugin
      ios:
        pluginClass: ${_toPascal(pluginName)}Plugin
''');

  if (platforms.contains('ios')) {
    Directory(p.join(root.path, 'ios', 'Classes')).createSync(recursive: true);
    File(p.join(root.path, 'ios', '$pluginName.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name             = '$pluginName'
  s.version          = '0.0.1'
  s.platform         = :ios, '11.0'
  s.swift_version    = '5.0'
  s.source_files     = 'Classes/**/*'
  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-ObjC' }
end
''');
    File(p.join(root.path, 'ios', 'Classes', '${_toPascal(pluginName)}Plugin.swift')).writeAsStringSync('''
import Flutter
import Foundation

public class ${_toPascal(pluginName)}Plugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
  }
}
''');
  }

  if (platforms.contains('macos')) {
    Directory(p.join(root.path, 'macos', 'Classes')).createSync(recursive: true);
    File(p.join(root.path, 'macos', '$pluginName.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name             = '$pluginName'
  s.version          = '0.0.1'
  s.platform         = :osx, '10.11'
  s.swift_version    = '5.0'
  s.source_files     = 'Classes/**/*'
  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-ObjC' }
end
''');
    File(p.join(root.path, 'macos', 'Classes', '${_toPascal(pluginName)}Plugin.swift')).writeAsStringSync('''
import FlutterMacOS
import Foundation

public class ${_toPascal(pluginName)}Plugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
  }
}
''');
  }

  if (platforms.contains('android')) {
    final ktDir = Directory(p.join(root.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', pluginName))..createSync(recursive: true);
    File(p.join(ktDir.path, '${_toPascal(pluginName)}Plugin.kt')).writeAsStringSync('''
package com.example.$pluginName

import io.flutter.embedding.engine.plugins.FlutterPlugin

class ${_toPascal(pluginName)}Plugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
''');
  }

  if (platforms.contains('windows')) {
    Directory(p.join(root.path, 'windows')).createSync(recursive: true);
    File(p.join(root.path, 'windows', 'CMakeLists.txt')).writeAsStringSync('''
cmake_minimum_required(VERSION 3.14)
project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)

add_library(\${PLUGIN_NAME} SHARED
  "$pluginName.cpp"
)
target_compile_definitions(\${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(\${PLUGIN_NAME} PUBLIC
  "\${CMAKE_CURRENT_SOURCE_DIR}/include")
''');
  }

  if (platforms.contains('linux')) {
    Directory(p.join(root.path, 'linux')).createSync(recursive: true);
    File(p.join(root.path, 'linux', 'CMakeLists.txt')).writeAsStringSync('''
cmake_minimum_required(VERSION 3.10)
project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)

add_library(\${PLUGIN_NAME} SHARED
  "$pluginName.cc"
)
target_compile_definitions(\${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(\${PLUGIN_NAME} PUBLIC
  "\${CMAKE_CURRENT_SOURCE_DIR}/include")
''');
  }

  // Create lib/src directory for specs
  Directory(p.join(root.path, 'lib', 'src')).createSync(recursive: true);
  Directory(p.join(root.path, 'lib', 'src', 'generated', 'cpp')).createSync(recursive: true);
  Directory(p.join(root.path, 'lib', 'src', 'generated', 'swift')).createSync(recursive: true);
  Directory(p.join(root.path, 'lib', 'src', 'generated', 'kotlin')).createSync(recursive: true);
  Directory(p.join(root.path, 'src')).createSync(recursive: true);

  return root;
}

/// Writes a NitroModule spec for a Swift/Kotlin (non-C++) module.
void _writeSwiftKotlinSpec(Directory root, String lib) {
  final pascal = _toPascal(lib);
  File(p.join(root.path, 'lib', 'src', '$lib.native.dart')).writeAsStringSync('''
import 'package:nitro/nitro.dart';
@NitroModule(lib: '$lib', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)
abstract class $pascal extends HybridObject {}
''');
  // Generated bridge files
  final gen = p.join(root.path, 'lib', 'src', 'generated');
  File(p.join(gen, 'cpp', '$lib.bridge.g.h')).writeAsStringSync('// bridge header');
  File(p.join(gen, 'cpp', '$lib.bridge.g.cpp')).writeAsStringSync('// bridge cpp');
  File(p.join(gen, 'swift', '$lib.bridge.g.swift')).writeAsStringSync('// swift bridge');
  File(p.join(gen, 'kotlin', '$lib.bridge.g.kt')).writeAsStringSync('// kotlin bridge');
}

/// Writes a NitroModule spec for an Apple C++ (AppleNativeImpl.cpp) module.
void _writeAppleCppSpec(Directory root, String lib) {
  final pascal = _toPascal(lib);
  File(p.join(root.path, 'lib', 'src', '$lib.native.dart')).writeAsStringSync('''
import 'package:nitro/nitro.dart';
@NitroModule(lib: '$lib', ios: AppleNativeImpl.cpp, android: NativeImpl.kotlin, macos: AppleNativeImpl.cpp)
abstract class $pascal extends HybridObject {}
''');
  final gen = p.join(root.path, 'lib', 'src', 'generated');
  File(p.join(gen, 'cpp', '$lib.bridge.g.h')).writeAsStringSync('// bridge header');
  File(p.join(gen, 'cpp', '$lib.bridge.g.cpp')).writeAsStringSync('// bridge cpp');
  File(p.join(gen, 'cpp', '$lib.native.g.h')).writeAsStringSync('// native header');
  File(p.join(gen, 'kotlin', '$lib.bridge.g.kt')).writeAsStringSync('// kotlin bridge');
  // Impl stub
  File(p.join(root.path, 'src', 'Hybrid$pascal.cpp')).writeAsStringSync('// impl');
}

/// Writes a NitroModule spec for a Windows-only C++ module.
void _writeWindowsCppSpec(Directory root, String lib) {
  final pascal = _toPascal(lib);
  File(p.join(root.path, 'lib', 'src', '$lib.native.dart')).writeAsStringSync('''
import 'package:nitro/nitro.dart';
@NitroModule(lib: '$lib', ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift, windows: WindowsNativeImpl.cpp)
abstract class $pascal extends HybridObject {}
''');
  final gen = p.join(root.path, 'lib', 'src', 'generated');
  File(p.join(gen, 'cpp', '$lib.bridge.g.h')).writeAsStringSync('// bridge header');
  File(p.join(gen, 'cpp', '$lib.bridge.g.cpp')).writeAsStringSync('// bridge cpp');
  File(p.join(gen, 'cpp', '$lib.native.g.h')).writeAsStringSync('// native header');
  File(p.join(gen, 'swift', '$lib.bridge.g.swift')).writeAsStringSync('// swift bridge');
  File(p.join(gen, 'kotlin', '$lib.bridge.g.kt')).writeAsStringSync('// kotlin bridge');
}

String _toPascal(String s) => s.split(RegExp(r'[_\-]')).map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nitro_platform_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ── iOS file placement ───────────────────────────────────────────────────────

  group('iOS — Swift/Kotlin module file placement', () {
    late Directory root;

    setUp(() {
      root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['ios']);
      _writeSwiftKotlinSpec(root, 'my_plugin');
    });

    test('linkPodspec adds nitro dependency', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains("s.dependency 'nitro'"));
    });

    test('linkPodspec sets HEADER_SEARCH_PATHS with all required paths', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains('HEADER_SEARCH_PATHS'));
      expect(pod, contains('lib/src/generated/cpp'));
      expect(pod, contains('PODS_TARGET_SRCROOT}/../src'));
    });

    test('linkPodspec sets CLANG_CXX_LANGUAGE_STANDARD = c++17', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains('c++17'), reason: 'Doctor checks for c++17 — linkPodspec must set it to prevent build warnings');
    });

    test('linkPodspec sets DEFINES_MODULE = YES', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains("'DEFINES_MODULE' => 'YES'"));
    });

    test('linkPodspec upgrades swift_version to 5.9', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains("swift_version = '5.9'"));
    });

    test('linkPodspec upgrades minimum iOS platform to 13.0 if lower', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains("platform = :ios, '13.0'"));
    });

    test('linkPodspec removes the outer Swift bridge glob from source_files', () {
      // First, add it manually to simulate an old podspec state
      final podFile = File(p.join(root.path, 'ios', 'my_plugin.podspec'));
      podFile.writeAsStringSync(
        podFile.readAsStringSync().replaceFirst("s.source_files     = 'Classes/**/*'", "s.source_files     = 'Classes/**/*', '../lib/src/generated/swift/**/*.swift'"),
      );

      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = podFile.readAsStringSync();
      expect(pod, isNot(contains('lib/src/generated/swift/**/*.swift')), reason: 'Bridges are now copied to Classes/ — outer glob causes "Invalid redeclaration" errors');
    });

    test('ios/Classes/dart_api_dl.c is created by linkPodspec', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(File(p.join(root.path, 'ios', 'Classes', 'dart_api_dl.c')).existsSync(), isTrue);
    });

    test('ios/Classes/nitro.h is created with NITRO_EXPORT macro', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final h = File(p.join(root.path, 'ios', 'Classes', 'nitro.h'));
      expect(h.existsSync(), isTrue);
      expect(h.readAsStringSync(), contains('NITRO_EXPORT'));
    });

    test('C++ bridge .cpp is synced to ios/Classes/ as .mm', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(
        File(p.join(root.path, 'ios', 'Classes', 'my_plugin.bridge.g.mm')).existsSync(),
        isTrue,
        reason: '.bridge.g.cpp must become .bridge.g.mm so __OBJC__ is defined for NSException handling',
      );
    });

    test('Swift bridge .bridge.g.swift is present in ios/Classes/', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(
        File(p.join(root.path, 'ios', 'Classes', 'my_plugin.bridge.g.swift')).existsSync(),
        isTrue,
        reason: 'Swift bridge must be in Classes/ so it is in the same scope as the plugin class (stability)',
      );
    });

    test('linkPodspec is idempotent — second run does not duplicate entries', () {
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final after1 = File(p.join(root.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      linkPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final after2 = File(p.join(root.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(after1, equals(after2), reason: 'linkPodspec must be idempotent');
      expect("'DEFINES_MODULE'".allMatches(after2).length, equals(1));
      expect("'CLANG_CXX_LANGUAGE_STANDARD'".allMatches(after2).length, equals(1));
      expect("s.dependency 'nitro'".allMatches(after2).length, equals(1));
    });
  });

  group('iOS — Apple C++ (AppleNativeImpl.cpp) file placement', () {
    late Directory root;

    setUp(() {
      root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['ios']);
      _writeAppleCppSpec(root, 'my_plugin');
    });

    test('Hybrid<Lib>.cpp forwarder created in ios/Classes/', () {
      linkPodspec(
        'my_plugin',
        ['my_plugin'],
        baseDir: root.path,
        moduleInfos: [const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: true)],
      );
      expect(
        File(p.join(root.path, 'ios', 'Classes', 'HybridMyPlugin.cpp')).existsSync(),
        isTrue,
      );
    });

    test('Hybrid forwarder #include points to ../../src/', () {
      linkPodspec(
        'my_plugin',
        ['my_plugin'],
        baseDir: root.path,
        moduleInfos: [const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: true)],
      );
      final content = File(p.join(root.path, 'ios', 'Classes', 'HybridMyPlugin.cpp')).readAsStringSync();
      expect(content, contains('#include "../../src/HybridMyPlugin.cpp"'));
    });

    test('no .bridge.g.swift in ios/Classes/ for Apple C++ module', () {
      // Apple C++ modules have no Swift bridge class — only the C-ABI bridge header.
      linkPodspec(
        'my_plugin',
        ['my_plugin'],
        baseDir: root.path,
        moduleInfos: [const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: true)],
      );
      final stale = File(p.join(root.path, 'ios', 'Classes', 'my_plugin.bridge.g.swift'));
      expect(stale.existsSync(), isFalse);
    });
  });

  // ── macOS file placement ─────────────────────────────────────────────────────

  group('macOS — Swift/Kotlin module file placement', () {
    late Directory root;

    setUp(() {
      root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['macos']);
      _writeSwiftKotlinSpec(root, 'my_plugin');
    });

    test('linkMacosPodspec adds nitro dependency', () {
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains("s.dependency 'nitro'"));
    });

    test('linkMacosPodspec sets CLANG_CXX_LANGUAGE_STANDARD = c++17', () {
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains('c++17'));
    });

    test('linkMacosPodspec upgrades minimum macOS platform to 10.15', () {
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains("platform = :osx, '10.15'"));
    });

    test('linkMacosPodspec sets DEFINES_MODULE = YES', () {
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final pod = File(p.join(root.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      expect(pod, contains("'DEFINES_MODULE' => 'YES'"));
    });

    test('macos/Classes/dart_api_dl.c is created', () {
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(File(p.join(root.path, 'macos', 'Classes', 'dart_api_dl.c')).existsSync(), isTrue);
    });

    test('macos/Classes/nitro.h is created with NITRO_EXPORT macro', () {
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final h = File(p.join(root.path, 'macos', 'Classes', 'nitro.h'));
      expect(h.existsSync(), isTrue);
      expect(h.readAsStringSync(), contains('NITRO_EXPORT'));
    });

    test('C++ bridge .cpp is synced to macos/Classes/ as .mm', () {
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(
        File(p.join(root.path, 'macos', 'Classes', 'my_plugin.bridge.g.mm')).existsSync(),
        isTrue,
      );
    });

    test('linkMacosPodspec is idempotent', () {
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final after1 = File(p.join(root.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: root.path);
      final after2 = File(p.join(root.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      expect(after1, equals(after2));
      expect("'CLANG_CXX_LANGUAGE_STANDARD'".allMatches(after2).length, equals(1));
    });
  });

  // ── Android file placement ───────────────────────────────────────────────────

  group('Android — Kotlin JNI file placement', () {
    late Directory root;

    setUp(() {
      root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['android']);
      _writeSwiftKotlinSpec(root, 'my_plugin');
    });

    test('linkKotlinPlugin injects JniBridge.register() call', () {
      linkKotlinPlugin('my_plugin', [
        {'lib': 'my_plugin', 'module': 'MyPlugin'},
      ], baseDir: root.path);
      final kt = File(p.join(root.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'my_plugin', 'MyPluginPlugin.kt'));
      expect(kt.readAsStringSync(), contains('MyPluginJniBridge.register'));
    });

    test('linkKotlinPlugin injects import for JniBridge class', () {
      linkKotlinPlugin('my_plugin', [
        {'lib': 'my_plugin', 'module': 'MyPlugin'},
      ], baseDir: root.path);
      final kt = File(p.join(root.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'my_plugin', 'MyPluginPlugin.kt'));
      expect(kt.readAsStringSync(), contains('import nitro.my_plugin_module.MyPluginJniBridge'));
    });

    test('linkKotlinPlugin is idempotent — no duplicate imports or registrations', () {
      linkKotlinPlugin('my_plugin', [
        {'lib': 'my_plugin', 'module': 'MyPlugin'},
      ], baseDir: root.path);
      final after1 = File(p.join(root.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'my_plugin', 'MyPluginPlugin.kt')).readAsStringSync();
      linkKotlinPlugin('my_plugin', [
        {'lib': 'my_plugin', 'module': 'MyPlugin'},
      ], baseDir: root.path);
      final after2 = File(p.join(root.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'my_plugin', 'MyPluginPlugin.kt')).readAsStringSync();
      expect(after1, equals(after2));
      expect('MyPluginJniBridge.register'.allMatches(after2).length, equals(1));
    });
  });

  // ── Android build.gradle linking ────────────────────────────────────────────

  group('Android — build.gradle linking (kotlin.srcDirs)', () {
    late Directory root;

    setUp(() {
      root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['android']);
      _writeSwiftKotlinSpec(root, 'my_plugin');
    });

    void writeBuildGradle(String content) => File(p.join(root.path, 'android', 'build.gradle')).writeAsStringSync(content);

    String readBuildGradle() => File(p.join(root.path, 'android', 'build.gradle')).readAsStringSync();

    test('no-op when android/build.gradle does not exist', () {
      // No build.gradle written — must not throw.
      expect(() => linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path), returnsNormally);
    });

    test('injects kotlin.srcDirs into existing sourceSets.main block', () {
      writeBuildGradle('''
android {
    sourceSets {
        main {
            java.srcDirs = ['src/main/java']
        }
    }
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(readBuildGradle(), contains('generated/kotlin'));
    });

    test('injects kotlin.srcDirs when sourceSets has no main {} block', () {
      writeBuildGradle('''
android {
    sourceSets {
    }
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      final content = readBuildGradle();
      expect(content, contains('generated/kotlin'));
      expect(content, contains('main {'));
    });

    test('injects kotlin.srcDirs inside android {} when no sourceSets block', () {
      writeBuildGradle('''
android {
    compileSdkVersion 33
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      final content = readBuildGradle();
      expect(content, contains('generated/kotlin'));
      expect(content, contains('sourceSets'));
    });

    test('creates android {} with sourceSets when no android block present', () {
      writeBuildGradle('''
apply plugin: 'com.android.library'
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(readBuildGradle(), contains('generated/kotlin'));
    });

    test('injects kotlinOptions with jvmTarget = "17"', () {
      writeBuildGradle('''
android {
    compileSdkVersion 33
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      final content = readBuildGradle();
      expect(content, contains('kotlinOptions'));
      expect(content, contains('jvmTarget'));
    });

    test('injects kotlinx-coroutines into existing dependencies block', () {
      writeBuildGradle('''
android {
    compileSdkVersion 33
}
dependencies {
    implementation "org.jetbrains.kotlin:kotlin-stdlib:1.8.0"
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(readBuildGradle(), contains('kotlinx-coroutines'));
    });

    test('creates dependencies block with kotlinx-coroutines when none exists', () {
      writeBuildGradle('''
android {
    compileSdkVersion 33
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(readBuildGradle(), contains('kotlinx-coroutines'));
    });

    test('kotlin.srcDirs path points to lib/src/generated/kotlin', () {
      writeBuildGradle('''
android {
    compileSdkVersion 33
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(readBuildGradle(), contains('lib/src/generated/kotlin'));
    });

    test('linkAndroid is idempotent — second run produces identical output', () {
      writeBuildGradle('''
android {
    sourceSets {
        main {
            java.srcDirs = ['src/main/java']
        }
    }
}
dependencies {
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      final after1 = readBuildGradle();
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      final after2 = readBuildGradle();
      expect(after1, equals(after2), reason: 'linkAndroid must be idempotent');
      expect('generated/kotlin'.allMatches(after2).length, equals(1), reason: 'kotlin.srcDirs must not be duplicated');
      expect('kotlinOptions'.allMatches(after2).length, equals(1), reason: 'kotlinOptions must not be duplicated');
    });

    test('supports Kotlin DSL (build.gradle.kts) with setOf() syntax', () {
      File(p.join(root.path, 'android', 'build.gradle.kts')).writeAsStringSync('''
android {
    compileSdk = 33
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      final kts = File(p.join(root.path, 'android', 'build.gradle.kts')).readAsStringSync();
      expect(kts, contains('generated/kotlin'));
      expect(kts, contains('setOf('), reason: 'Kotlin DSL requires setOf() instead of simple string assignment');
    });

    test('Groovy DSL does not use setOf() syntax', () {
      writeBuildGradle('''
android {
    compileSdkVersion 33
}
''');
      linkAndroid('my_plugin', ['my_plugin'], baseDir: root.path);
      expect(readBuildGradle(), isNot(contains('setOf(')));
    });
  });

  // ── Windows file placement ───────────────────────────────────────────────────

  group('Windows — CMakeLists.txt file placement', () {
    late Directory root;

    setUp(() {
      root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['windows']);
      _writeSwiftKotlinSpec(root, 'my_plugin');
    });

    test('linkWindows injects NITRO_NATIVE into CMakeLists.txt', () {
      linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains(r'set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")'));
      expect(cmake, isNot(contains('/path/to/nitro/native')));
    });

    test('linkWindows adds bridge .cpp to add_library target', () {
      linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('../lib/src/generated/cpp/my_plugin.bridge.g.cpp'));
    });

    test('linkWindows adds dart_api_dl.c from ../src/ to add_library target', () {
      linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('dart_api_dl.c'));
    });

    test('linkWindows adds NITRO_NATIVE and generated/cpp include paths', () {
      linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains(r'${NITRO_NATIVE}'));
      expect(cmake, contains('../lib/src/generated/cpp'));
    });

    test('linkWindows adds ../src to target_include_directories', () {
      linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('/../src"'), reason: 'Headers in src/ must be reachable from windows/CMakeLists.txt');
    });

    test('linkWindows is idempotent', () {
      linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final after1 = File(p.join(root.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final after2 = File(p.join(root.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      expect(after1, equals(after2), reason: 'linkWindows must be idempotent');
    });
  });

  group('Windows — WindowsNativeImpl.cpp stub creation', () {
    late Directory root;

    setUp(() {
      root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['windows']);
    });

    test('isWindowsCppModule returns true for windows: WindowsNativeImpl.cpp', () {
      final spec = File(p.join(root.path, 'lib', 'src', 'win_mod.native.dart'));
      spec.writeAsStringSync(
        "@NitroModule(lib: 'win_mod', ios: NativeImpl.swift, android: NativeImpl.kotlin, windows: WindowsNativeImpl.cpp)\n"
        'abstract class WinMod extends HybridObject {}\n',
      );
      expect(isWindowsCppModule(spec), isTrue);
    });

    test('isWindowsCppModule returns false for android: NativeImpl.cpp (not windows)', () {
      final spec = File(p.join(root.path, 'lib', 'src', 'android_mod.native.dart'));
      spec.writeAsStringSync(
        "@NitroModule(lib: 'android_mod', android: NativeImpl.cpp)\n"
        'abstract class AndroidMod extends HybridObject {}\n',
      );
      expect(isWindowsCppModule(spec), isFalse);
    });

    test('isWindowsCppModule returns false for ios: NativeImpl.cpp', () {
      final spec = File(p.join(root.path, 'lib', 'src', 'ios_mod.native.dart'));
      spec.writeAsStringSync(
        "@NitroModule(lib: 'ios_mod', ios: NativeImpl.cpp)\n"
        'abstract class IosMod extends HybridObject {}\n',
      );
      expect(isWindowsCppModule(spec), isFalse);
    });

    test('linkWindowsCppImplStubs creates windows/src/Hybrid<Lib>.cpp stub', () {
      _writeWindowsCppSpec(root, 'win_mod');
      linkWindowsCppImplStubs(
        [const ModuleInfo(lib: 'win_mod', module: 'WinMod', isCpp: true)],
        baseDir: root.path,
      );
      expect(
        File(p.join(root.path, 'windows', 'src', 'HybridWinMod.cpp')).existsSync(),
        isTrue,
      );
    });

    test('Windows stub uses static initializer for auto-registration (no __attribute__((constructor)))', () {
      _writeWindowsCppSpec(root, 'win_mod');
      linkWindowsCppImplStubs(
        [const ModuleInfo(lib: 'win_mod', module: 'WinMod', isCpp: true)],
        baseDir: root.path,
      );
      final content = File(p.join(root.path, 'windows', 'src', 'HybridWinMod.cpp')).readAsStringSync();
      expect(content, contains('_AutoRegister'));
      expect(content, contains('win_mod_register_impl'));
    });

    test('linkWindowsCppImplStubs does NOT overwrite existing stub', () {
      _writeWindowsCppSpec(root, 'win_mod');
      Directory(p.join(root.path, 'windows', 'src')).createSync(recursive: true);
      File(p.join(root.path, 'windows', 'src', 'HybridWinMod.cpp')).writeAsStringSync('// user code — do not overwrite');
      linkWindowsCppImplStubs(
        [const ModuleInfo(lib: 'win_mod', module: 'WinMod', isCpp: true)],
        baseDir: root.path,
      );
      final content = File(p.join(root.path, 'windows', 'src', 'HybridWinMod.cpp')).readAsStringSync();
      expect(content, contains('// user code — do not overwrite'));
    });

    test('linkWindowsCppImplStubs skips modules without WindowsNativeImpl.cpp spec', () {
      _writeSwiftKotlinSpec(root, 'swift_mod');
      linkWindowsCppImplStubs(
        [const ModuleInfo(lib: 'swift_mod', module: 'SwiftMod', isCpp: false)],
        baseDir: root.path,
      );
      expect(Directory(p.join(root.path, 'windows', 'src')).existsSync(), isFalse, reason: 'Non-Windows-cpp modules must not create stubs in windows/src/');
    });
  });

  // ── Linux file placement ─────────────────────────────────────────────────────

  group('Linux — CMakeLists.txt file placement', () {
    late Directory root;

    setUp(() {
      root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['linux']);
      _writeSwiftKotlinSpec(root, 'my_plugin');
    });

    test('linkLinux injects NITRO_NATIVE into CMakeLists.txt', () {
      linkLinux('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'linux', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains(r'set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")'));
      expect(cmake, isNot(contains('/path/to/nitro/native')));
    });

    test('linkLinux adds bridge .cpp to add_library target', () {
      linkLinux('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'linux', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('../lib/src/generated/cpp/my_plugin.bridge.g.cpp'));
    });

    test('linkLinux adds ../src to target_include_directories', () {
      linkLinux('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'linux', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('/../src"'), reason: 'Headers in src/ must be reachable from linux/CMakeLists.txt');
    });

    test('linkLinux is idempotent', () {
      linkLinux('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final after1 = File(p.join(root.path, 'linux', 'CMakeLists.txt')).readAsStringSync();
      linkLinux('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final after2 = File(p.join(root.path, 'linux', 'CMakeLists.txt')).readAsStringSync();
      expect(after1, equals(after2), reason: 'linkLinux must be idempotent');
    });
  });

  // ── src/CMakeLists.txt (shared Android+Linux) ────────────────────────────────

  group('src/CMakeLists.txt — generateCMake', () {
    test('generated CMakeLists sets CMAKE_CXX_STANDARD 17', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      generateCMake('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('CMAKE_CXX_STANDARD 17'));
    });

    test('generated CMakeLists sets CMAKE_CXX_STANDARD_REQUIRED ON', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      generateCMake('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('CMAKE_CXX_STANDARD_REQUIRED ON'));
    });

    test('generated CMakeLists includes bridge .cpp file', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      generateCMake('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('my_plugin.bridge.g.cpp'));
    });

    test('generated CMakeLists includes dart_api_dl.c', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      generateCMake('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('dart_api_dl.c'));
    });

    test('generated CMakeLists has Android-specific link libraries', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      generateCMake('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('android log'));
    });

    test('generated CMakeLists has Windows-specific link libraries', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      generateCMake('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final cmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(cmake, contains('dbghelp'));
    });

    test('linkCMake injects CMAKE_CXX_STANDARD 17 into existing CMakeLists without it', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      final cmake = File(p.join(root.path, 'src', 'CMakeLists.txt'));
      cmake.writeAsStringSync('''
cmake_minimum_required(VERSION 3.10)
project(my_plugin_library VERSION 0.0.1 LANGUAGES C CXX)

add_library(my_plugin SHARED "my_plugin.cpp")
target_include_directories(my_plugin PRIVATE "\${CMAKE_CURRENT_SOURCE_DIR}")
''');
      linkCMake('my_plugin', ['my_plugin'], '/path/to/nitro/native', baseDir: root.path);
      final content = cmake.readAsStringSync();
      expect(content, contains('CMAKE_CXX_STANDARD 17'));
    });
  });

  // ── Web platform ─────────────────────────────────────────────────────────────

  group('Web — no native file placement required', () {
    test('isWindowsCppModule returns false for web-only spec (no windows key)', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      final spec = File(p.join(root.path, 'lib', 'src', 'web_mod.native.dart'));
      spec.writeAsStringSync(
        "@NitroModule(lib: 'web_mod', ios: NativeImpl.swift, android: NativeImpl.kotlin)\n"
        'abstract class WebMod extends HybridObject {}\n',
      );
      // Web modules don't use NativeImpl.cpp at all — no file placement needed.
      expect(isWindowsCppModule(spec), isFalse);
      expect(isCppModule(spec), isFalse);
    });

    test('isCppModule returns false for Wasm-targeted spec', () {
      // Future web/Wasm modules would use a different annotation key;
      // ensure they don't accidentally trigger C++ file placement.
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: []);
      final spec = File(p.join(root.path, 'lib', 'src', 'wasm_mod.native.dart'));
      spec.writeAsStringSync(
        "@NitroModule(lib: 'wasm_mod', ios: NativeImpl.swift)\n"
        'abstract class WasmMod extends HybridObject {}\n',
      );
      expect(isCppModule(spec), isFalse, reason: 'Web/Wasm modules use a separate codegen path; no C++ placement must occur');
    });

    test('no windows/linux/ios/macos platform directories are touched when only web spec present', () {
      final root = _scaffoldPlugin(tmp, 'my_plugin', platforms: ['windows', 'linux']);
      final spec = File(p.join(root.path, 'lib', 'src', 'web_mod.native.dart'));
      spec.writeAsStringSync(
        "@NitroModule(lib: 'web_mod', ios: NativeImpl.swift, android: NativeImpl.kotlin)\n"
        'abstract class WebMod extends HybridObject {}\n',
      );
      // linkWindows is a no-op for non-cpp modules (it won't stub Hybrid*.cpp).
      linkWindowsCppImplStubs(
        [const ModuleInfo(lib: 'web_mod', module: 'WebMod', isCpp: false)],
        baseDir: root.path,
      );
      expect(Directory(p.join(root.path, 'windows', 'src')).existsSync(), isFalse, reason: 'No C++ stubs must be created for a web-only module');
    });
  });

  // ── Full plugin scaffold integration (all platforms) ─────────────────────────

  group('Full-plugin integration — all platforms linked correctly', () {
    test('all platforms linked for a Swift/Kotlin plugin', () {
      final root = _scaffoldPlugin(tmp, 'benchmark', platforms: ['ios', 'macos', 'android', 'windows', 'linux']);
      _writeSwiftKotlinSpec(root, 'benchmark');
      const nitroPath = '/path/to/nitro/native';

      final moduleInfos = [const ModuleInfo(lib: 'benchmark', module: 'Benchmark', isCpp: false)];
      linkCMake('benchmark', ['benchmark'], nitroPath, baseDir: root.path, moduleInfos: moduleInfos);
      linkPodspec('benchmark', ['benchmark'], baseDir: root.path, moduleInfos: moduleInfos);
      linkMacosPodspec('benchmark', ['benchmark'], baseDir: root.path, moduleInfos: moduleInfos);
      linkKotlinPlugin('benchmark', [
        {'lib': 'benchmark', 'module': 'Benchmark'},
      ], baseDir: root.path);
      linkWindows('benchmark', ['benchmark'], nitroPath, baseDir: root.path, moduleInfos: moduleInfos);
      linkLinux('benchmark', ['benchmark'], nitroPath, baseDir: root.path, moduleInfos: moduleInfos);

      // iOS assertions
      final iosPod = File(p.join(root.path, 'ios', 'benchmark.podspec')).readAsStringSync();
      expect(iosPod, contains("s.dependency 'nitro'"), reason: 'iOS podspec must declare nitro dependency');
      expect(iosPod, contains('c++17'), reason: 'iOS podspec must set C++17 standard');
      expect(iosPod, isNot(contains('lib/src/generated/swift')), reason: 'iOS podspec should not have outer Swift glob');
      expect(File(p.join(root.path, 'ios', 'Classes', 'benchmark.bridge.g.swift')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'ios', 'Classes', 'dart_api_dl.c')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'ios', 'Classes', 'nitro.h')).existsSync(), isTrue);

      // macOS assertions
      final macosPod = File(p.join(root.path, 'macos', 'benchmark.podspec')).readAsStringSync();
      expect(macosPod, contains("s.dependency 'nitro'"), reason: 'macOS podspec must declare nitro dependency');
      expect(macosPod, contains('c++17'), reason: 'macOS podspec must set C++17 standard');
      expect(File(p.join(root.path, 'macos', 'Classes', 'dart_api_dl.c')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'macos', 'Classes', 'nitro.h')).existsSync(), isTrue);

      // Android assertions
      final ktPath = p.join(root.path, 'android', 'src', 'main', 'kotlin', 'com', 'example', 'benchmark', 'BenchmarkPlugin.kt');
      expect(File(ktPath).readAsStringSync(), contains('BenchmarkJniBridge.register'));

      // Windows assertions
      final winCmake = File(p.join(root.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      expect(winCmake, contains('NITRO_NATIVE'));
      expect(winCmake, contains('benchmark.bridge.g.cpp'));
      expect(winCmake, contains('/../src"'), reason: 'src/ headers must be reachable from windows/');

      // Linux assertions
      final linuxCmake = File(p.join(root.path, 'linux', 'CMakeLists.txt')).readAsStringSync();
      expect(linuxCmake, contains('NITRO_NATIVE'));
      expect(linuxCmake, contains('benchmark.bridge.g.cpp'));
      expect(linuxCmake, contains('/../src"'), reason: 'src/ headers must be reachable from linux/');

      // src/CMakeLists.txt assertions (shared Android+Linux)
      final srcCmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(srcCmake, contains('CMAKE_CXX_STANDARD 17'));
      expect(srcCmake, contains('dart_api_dl.c'));
    });

    test('all platforms linked correctly for an Apple C++ plugin', () {
      final root = _scaffoldPlugin(tmp, 'nitro_math', platforms: ['ios', 'macos', 'android']);
      _writeAppleCppSpec(root, 'nitro_math');
      const nitroPath = '/path/to/nitro/native';

      final moduleInfos = [const ModuleInfo(lib: 'nitro_math', module: 'NitroMath', isCpp: true)];
      linkPodspec('nitro_math', ['nitro_math'], baseDir: root.path, moduleInfos: moduleInfos);
      linkMacosPodspec('nitro_math', ['nitro_math'], baseDir: root.path, moduleInfos: moduleInfos);
      linkCMake('nitro_math', ['nitro_math'], nitroPath, baseDir: root.path, moduleInfos: moduleInfos);

      // iOS: HybridNitroMath.cpp forwarder must be present
      expect(
        File(p.join(root.path, 'ios', 'Classes', 'HybridNitroMath.cpp')).existsSync(),
        isTrue,
        reason: 'AppleNativeImpl.cpp modules need a forwarder in ios/Classes/ for CocoaPods',
      );

      // macOS: same
      expect(
        File(p.join(root.path, 'macos', 'Classes', 'HybridNitroMath.cpp')).existsSync(),
        isTrue,
        reason: 'AppleNativeImpl.cpp modules need a forwarder in macos/Classes/ for CocoaPods',
      );

      // src/CMakeLists.txt must NOT have the HybridNitroMath.cpp (isNativeCpp is false — apple only)
      final srcCmake = File(p.join(root.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(srcCmake, isNot(contains('HybridNitroMath.cpp')), reason: 'Apple-only C++ modules are compiled via CocoaPods, not src/CMakeLists.txt');
    });
  });
}
