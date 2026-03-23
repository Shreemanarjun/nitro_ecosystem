import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/init_command.dart' show updateCMakeNitroNative;
import 'package:test/test.dart';

// Helpers — run a block with the working directory temporarily changed.
T _withDir<T>(Directory dir, T Function() fn) {
  final orig = Directory.current;
  Directory.current = dir;
  try {
    return fn();
  } finally {
    Directory.current = orig;
  }
}

void main() {
  // ── extractLibNameFromSpec ──────────────────────────────────────────────────

  group('extractLibNameFromSpec', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File spec(String content) {
      final f = File(p.join(tmp.path, 'spec.native.dart'));
      f.writeAsStringSync(content);
      return f;
    }

    test('extracts lib from double-quoted @NitroModule', () {
      final f = spec('''
@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, lib: "my_plugin")
abstract class MyPlugin extends HybridObject {}
''');
      expect(extractLibNameFromSpec(f), equals('my_plugin'));
    });

    test('extracts lib from single-quoted @NitroModule', () {
      final f = spec("@NitroModule(lib: 'my_plugin')");
      expect(extractLibNameFromSpec(f), equals('my_plugin'));
    });

    test('extracts lib when lib comes before other params', () {
      final f = spec("@NitroModule(lib: 'sensor_hub', ios: NativeImpl.swift)");
      expect(extractLibNameFromSpec(f), equals('sensor_hub'));
    });

    test('returns null when no lib param present', () {
      final f = spec(
          '@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)');
      expect(extractLibNameFromSpec(f), isNull);
    });

    test('returns null for empty file', () {
      final f = spec('');
      expect(extractLibNameFromSpec(f), isNull);
    });

    test('returns null for file with no @NitroModule annotation', () {
      final f = spec('abstract class Foo extends HybridObject {}');
      expect(extractLibNameFromSpec(f), isNull);
    });

    test('handles underscores in lib name', () {
      final f = spec('@NitroModule(lib: "nitro_battery_extra")');
      expect(extractLibNameFromSpec(f), equals('nitro_battery_extra'));
    });
  });

  // ── discoverModuleLibs ──────────────────────────────────────────────────────

  group('discoverModuleLibs', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    void writeSpec(String relPath, String content) {
      final f = File(p.join(tmp.path, relPath));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    test('returns [pluginName] when lib/ does not exist', () {
      _withDir(tmp, () {
        expect(discoverModuleLibs('my_plugin'), equals(['my_plugin']));
      });
    });

    test('returns [pluginName] when lib/ has no .native.dart files', () {
      Directory(p.join(tmp.path, 'lib')).createSync();
      _withDir(tmp, () {
        expect(discoverModuleLibs('my_plugin'), equals(['my_plugin']));
      });
    });

    test('uses lib: param when present in spec', () {
      writeSpec('lib/src/my_plugin.native.dart',
          '@NitroModule(lib: "my_plugin_lib")');
      _withDir(tmp, () {
        expect(discoverModuleLibs('my_plugin'), equals(['my_plugin_lib']));
      });
    });

    test('falls back to stem when no lib: param', () {
      writeSpec('lib/src/my_plugin.native.dart',
          '@NitroModule(ios: NativeImpl.swift)');
      _withDir(tmp, () {
        expect(discoverModuleLibs('my_plugin'), equals(['my_plugin']));
      });
    });

    test('discovers multiple specs', () {
      writeSpec('lib/src/module_a.native.dart', '@NitroModule(lib: "mod_a")');
      writeSpec('lib/src/module_b.native.dart', '@NitroModule(lib: "mod_b")');
      _withDir(tmp, () {
        final libs = discoverModuleLibs('my_plugin');
        expect(libs, containsAll(['mod_a', 'mod_b']));
        expect(libs, hasLength(2));
      });
    });

    test('deduplicates identical lib names', () {
      writeSpec('lib/src/a.native.dart', '@NitroModule(lib: "shared")');
      writeSpec('lib/src/b.native.dart', '@NitroModule(lib: "shared")');
      _withDir(tmp, () {
        expect(discoverModuleLibs('my_plugin'), equals(['shared']));
      });
    });

    test('replaces hyphens with underscores in stem fallback', () {
      writeSpec('lib/src/my-module.native.dart', '// no annotation');
      _withDir(tmp, () {
        expect(discoverModuleLibs('my_plugin'), equals(['my_module']));
      });
    });

    test('discovers specs nested in subdirectories', () {
      writeSpec('lib/src/deep/nested/sensor.native.dart',
          '@NitroModule(lib: "sensor")');
      _withDir(tmp, () {
        expect(discoverModuleLibs('my_plugin'), equals(['sensor']));
      });
    });
  });

  // ── resolveNitroNativePath ──────────────────────────────────────────────────

  group('resolveNitroNativePath', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    void writePackageConfig(String content) {
      final dir = Directory(p.join(tmp.path, '.dart_tool'));
      dir.createSync(recursive: true);
      File(p.join(dir.path, 'package_config.json')).writeAsStringSync(content);
    }

    test('resolves absolute file:// URI from package_config.json', () {
      writePackageConfig('''{
  "configVersion": 2,
  "packages": [
    {"name": "nitro", "rootUri": "file:///some/pub/cache/nitro-0.1.0", "packageUri": "lib/"}
  ]
}''');
      final result = resolveNitroNativePath(tmp.path);
      expect(result, endsWith(p.join('src', 'native')));
      expect(result, contains('nitro-0.1.0'));
    });

    test('resolves relative URI from package_config.json', () {
      writePackageConfig('''{
  "configVersion": 2,
  "packages": [
    {"name": "nitro", "rootUri": "../packages/nitro", "packageUri": "lib/"}
  ]
}''');
      final result = resolveNitroNativePath(tmp.path);
      expect(result, endsWith(p.join('src', 'native')));
      expect(result, contains('packages'));
      expect(result, contains('nitro'));
    });

    test('falls back to monorepo path when package_config.json absent', () {
      final result = resolveNitroNativePath(tmp.path);
      expect(result, endsWith(p.join('src', 'native')));
      expect(result, contains('packages'));
    });

    test('falls back when nitro not listed in packages', () {
      writePackageConfig('''{
  "configVersion": 2,
  "packages": [
    {"name": "other_pkg", "rootUri": "file:///some/path", "packageUri": "lib/"}
  ]
}''');
      final result = resolveNitroNativePath(tmp.path);
      // Should still return something ending in src/native
      expect(result, endsWith(p.join('src', 'native')));
    });

    test('falls back on malformed JSON', () {
      writePackageConfig('not valid json');
      final result = resolveNitroNativePath(tmp.path);
      expect(result, endsWith(p.join('src', 'native')));
    });
  });

  // ── nitroNativePathExists ───────────────────────────────────────────────────

  group('nitroNativePathExists', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('returns true when dart_api_dl.h exists at resolved path', () {
      final nativeDir = Directory(p.join(tmp.path, 'native'));
      nativeDir.createSync(recursive: true);
      File(p.join(nativeDir.path, 'dart_api_dl.h')).writeAsStringSync('');
      final result = nitroNativePathExists(nativeDir.path, tmp.path);
      expect(result, isTrue);
    });

    test('returns false when dart_api_dl.h is absent', () {
      final result =
          nitroNativePathExists(p.join(tmp.path, 'nonexistent'), tmp.path);
      expect(result, isFalse);
    });

    test('expands CMAKE_CURRENT_SOURCE_DIR placeholder', () {
      final nativeDir = Directory(p.join(tmp.path, 'native'));
      nativeDir.createSync(recursive: true);
      File(p.join(nativeDir.path, 'dart_api_dl.h')).writeAsStringSync('');
      // Use a cmake value that resolves to nativeDir without any .. traversal.
      final cmakeValue = r'${CMAKE_CURRENT_SOURCE_DIR}/native';
      final result = nitroNativePathExists(cmakeValue, tmp.path);
      expect(result, isTrue);
    });
  });

  // ── dartApiDlForwarderContent ───────────────────────────────────────────────

  group('dartApiDlForwarderContent', () {
    test('includes the dart_api_dl.c file from the given path', () {
      const nativePath = '/some/pub/cache/nitro/src/native';
      final content = dartApiDlForwarderContent(nativePath);
      expect(
          content,
          contains(
              '#include "/some/pub/cache/nitro/src/native/dart_api_dl.c"'));
    });

    test('contains do-not-edit comment', () {
      final content = dartApiDlForwarderContent('/any/path');
      expect(content, contains('Generated by nitrogen link'));
    });

    test('explains C compilation requirement', () {
      final content = dartApiDlForwarderContent('/any/path');
      expect(content, contains('void*/function-pointer casts'));
    });

    test('uses forward slashes in include path on all platforms', () {
      final content = dartApiDlForwarderContent('/some/native/path');
      expect(content, isNot(contains(r'\')));
    });

    test('ends with newline', () {
      final content = dartApiDlForwarderContent('/any/path');
      expect(content, endsWith('\n'));
    });
  });

  // ── iOS podspec content ─────────────────────────────────────────────────────

  group('iOS podspec header search path', () {
    const correctPath = r'"${PODS_ROOT}/../.symlinks/plugins/nitro/src/native"';

    test('correct path contains PODS_ROOT symlinks reference', () {
      expect(correctPath, contains(r'${PODS_ROOT}'));
      expect(correctPath, contains('.symlinks/plugins/nitro/src/native'));
    });

    test('old PODS_TARGET_SRCROOT path is different from correct path', () {
      const oldPath =
          r'${PODS_TARGET_SRCROOT}/../../../packages/nitro/src/native';
      expect(oldPath, isNot(equals(correctPath)));
      expect(oldPath, contains('PODS_TARGET_SRCROOT'));
    });
  });

  // ── Swift impl starter template ────────────────────────────────────────────

  group('Swift impl starter template', () {
    String swiftImplTemplate(String className) => '''import Foundation

/// Native implementation of Hybrid${className}Protocol.
/// This file is yours to edit — the protocol is generated by `nitrogen generate`.
public class ${className}Impl: NSObject, Hybrid${className}Protocol {

    public func add(a: Double, b: Double) -> Double {
        return a + b
    }

    public func getGreeting(name: String) async throws -> String {
        return "Hello, \\(name)!"
    }
}
''';

    test('template uses Hybrid<ClassName>Protocol', () {
      final out = swiftImplTemplate('MyCamera');
      expect(out, contains('HybridMyCameraProtocol'));
    });

    test('template class name is <ClassName>Impl', () {
      final out = swiftImplTemplate('MyCamera');
      expect(out, contains('class MyCameraImpl'));
    });

    test('template implements add function', () {
      final out = swiftImplTemplate('MyCamera');
      expect(out, contains('func add(a: Double, b: Double) -> Double'));
    });

    test('template implements async getGreeting', () {
      final out = swiftImplTemplate('MyCamera');
      expect(out, contains('async throws -> String'));
      expect(out, contains('func getGreeting(name: String)'));
    });

    test('template does not contain @objc', () {
      final out = swiftImplTemplate('MyCamera');
      expect(out, isNot(contains('@objc')));
    });
  });

  // ── Kotlin impl starter template ────────────────────────────────────────────

  group('Kotlin impl starter template', () {
    String kotlinImplTemplate(String org, String pluginName, String className) {
      final moduleName = '${pluginName}_module';
      return '''
package $org.$pluginName

import android.content.Context
import nitro.$moduleName.Hybrid${className}Spec

/// Native implementation of Hybrid${className}Spec.
/// This file is yours to edit — the interface is generated by `nitrogen generate`.
class ${className}Impl(private val context: Context) : Hybrid${className}Spec {

    override fun add(a: Double, b: Double): Double = a + b

    override suspend fun getGreeting(name: String): String = "Hello, \$name!"
}
''';
    }

    test('template package matches org.pluginName', () {
      final out = kotlinImplTemplate('com.example', 'my_plugin', 'MyPlugin');
      expect(out, contains('package com.example.my_plugin'));
    });

    test('template imports Hybrid<ClassName>Spec from correct package', () {
      final out = kotlinImplTemplate('com.example', 'my_plugin', 'MyPlugin');
      expect(out, contains('nitro.my_plugin_module.HybridMyPluginSpec'));
    });

    test('template class implements Hybrid<ClassName>Spec', () {
      final out = kotlinImplTemplate('com.example', 'my_plugin', 'MyPlugin');
      expect(out, contains('class MyPluginImpl'));
      expect(out, contains('HybridMyPluginSpec'));
    });

    test('template implements add function', () {
      final out = kotlinImplTemplate('com.example', 'my_plugin', 'MyPlugin');
      expect(out, contains('override fun add(a: Double, b: Double): Double'));
    });

    test('template implements suspend getGreeting', () {
      final out = kotlinImplTemplate('com.example', 'my_plugin', 'MyPlugin');
      expect(out, contains('override suspend fun getGreeting'));
    });
  });

  // ── Package.swift content ───────────────────────────────────────────────────

  group('Package.swift template', () {
    String packageSwiftTemplate(String pluginName, String className) => '''
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$pluginName",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "$pluginName", targets: ["$pluginName"]),
    ],
    targets: [
        .target(
            name: "${className}Cpp",
            path: "Sources/${className}Cpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags([
                    "-std=c++17",
                    "-I../../.symlinks/plugins/nitro/src/native",
                ])
            ]
        ),
        .target(
            name: "$pluginName",
            dependencies: ["${className}Cpp"],
            path: "Sources/$className"
        ),
    ]
)
''';

    test('template sets correct swift-tools-version', () {
      final out = packageSwiftTemplate('my_plugin', 'MyPlugin');
      expect(out, contains('swift-tools-version: 5.9'));
    });

    test('template sets iOS 13 minimum platform', () {
      final out = packageSwiftTemplate('my_plugin', 'MyPlugin');
      expect(out, contains('.iOS(.v13)'));
    });

    test('template has separate Cpp target', () {
      final out = packageSwiftTemplate('my_plugin', 'MyPlugin');
      expect(out, contains('MyPluginCpp'));
      expect(out, contains('Sources/MyPluginCpp'));
    });

    test('template Cpp target uses -std=c++17', () {
      final out = packageSwiftTemplate('my_plugin', 'MyPlugin');
      expect(out, contains('-std=c++17'));
    });

    test('template Cpp target includes nitro native headers via symlink', () {
      final out = packageSwiftTemplate('my_plugin', 'MyPlugin');
      expect(out, contains('-I../../.symlinks/plugins/nitro/src/native'));
    });

    test('template Swift target depends on Cpp target', () {
      final out = packageSwiftTemplate('my_plugin', 'MyPlugin');
      expect(out, contains('dependencies: ["MyPluginCpp"]'));
    });

    test('template Swift target path is Sources/<ClassName>', () {
      final out = packageSwiftTemplate('my_plugin', 'MyPlugin');
      expect(out, contains('path: "Sources/MyPlugin"'));
    });
  });

  // ── src/CMakeLists.txt placeholder ─────────────────────────────────────────

  group('src/CMakeLists.txt placeholder', () {
    // Mirror of the content _setupSrc writes before path resolution.
    String cmakePlaceholder(String pluginName) => '''
cmake_minimum_required(VERSION 3.10)
project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")
set(GENERATED_CPP "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library($pluginName SHARED
  "$pluginName.cpp"
  "dart_api_dl.c"
)

target_include_directories($pluginName PRIVATE
  "\${CMAKE_CURRENT_SOURCE_DIR}"
  "\${GENERATED_CPP}"
  "\${NITRO_NATIVE}"
)

target_compile_definitions($pluginName PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries($pluginName PRIVATE android log)
  target_link_options($pluginName PRIVATE "-Wl,-z,max-page-size=16384")
endif()
''';

    test('placeholder contains cmake_minimum_required', () {
      expect(cmakePlaceholder('my_plugin'), contains('cmake_minimum_required'));
    });

    test('placeholder sets NITRO_NATIVE with CMAKE_CURRENT_SOURCE_DIR', () {
      final out = cmakePlaceholder('my_plugin');
      expect(out, contains('set(NITRO_NATIVE '));
      expect(out, contains(r'${CMAKE_CURRENT_SOURCE_DIR}'));
    });

    test('placeholder NITRO_NATIVE line matches updateCMakeNitroNative regex', () {
      // The placeholder must be replaceable by updateCMakeNitroNative.
      final placeholder = cmakePlaceholder('my_plugin');
      const resolved = '/some/pub/cache/nitro/src/native';
      final updated = updateCMakeNitroNative(placeholder, resolved);
      expect(updated, contains('set(NITRO_NATIVE "/some/pub/cache/nitro/src/native")'));
      // Only the NITRO_NATIVE set() line should no longer use CMAKE_CURRENT_SOURCE_DIR
      final nitroLine = updated
          .split('\n')
          .firstWhere((l) => l.contains('set(NITRO_NATIVE'));
      expect(nitroLine, isNot(contains(r'${CMAKE_CURRENT_SOURCE_DIR}')));
    });

    test('placeholder contains only one NITRO_NATIVE line', () {
      final out = cmakePlaceholder('my_plugin');
      final count = 'NITRO_NATIVE'.allMatches(out).length;
      // Appears in set() line AND in target_include_directories — but only one set()
      final setCount = RegExp(r'set\(NITRO_NATIVE').allMatches(out).length;
      expect(setCount, equals(1));
    });

    test('placeholder references dart_api_dl.c as a source file', () {
      expect(cmakePlaceholder('my_plugin'), contains('"dart_api_dl.c"'));
    });

    test('placeholder adds android and log link libraries', () {
      final out = cmakePlaceholder('my_plugin');
      expect(out, contains('android'));
      expect(out, contains('log'));
    });
  });

  // ── src/dart_api_dl.c placeholder ──────────────────────────────────────────

  group('src/dart_api_dl.c placeholder', () {
    // Mirror of the placeholder content _setupSrc writes before path resolution.
    const placeholder =
        '// Generated by nitrogen — do not edit.\n'
        '// Run `nitrogen link` to update this path after `flutter pub get`.\n'
        '#include "../../packages/nitro/src/native/dart_api_dl.c"\n';

    test('placeholder is a valid C include', () {
      expect(placeholder, contains('#include'));
      expect(placeholder, contains('dart_api_dl.c'));
    });

    test('placeholder has exactly one #include line', () {
      final includeCount = '#include'.allMatches(placeholder).length;
      expect(includeCount, equals(1));
    });

    test('placeholder include path is different from resolved pub-cache path', () {
      // After resolution, the include path becomes absolute — verify they differ.
      const resolved = '/some/pub/cache/nitro/src/native';
      final forwarder = dartApiDlForwarderContent(resolved);
      expect(forwarder, isNot(equals(placeholder)));
      expect(forwarder, contains(resolved));
    });
  });

  // ── updateCMakeNitroNative ─────────────────────────────────────────────────

  group('updateCMakeNitroNative', () {
    const monorepoLine =
        r'set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")';
    const resolved = '/Users/dev/.puro/pub/cache/nitro-0.1.0/src/native';
    const resolvedLine = 'set(NITRO_NATIVE "$resolved")';

    String cmake(String nitroLine) => '''
cmake_minimum_required(VERSION 3.10)
project(my_plugin_library VERSION 0.0.1 LANGUAGES C CXX)

$nitroLine
set(GENERATED_CPP "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(my_plugin SHARED
  "my_plugin.cpp"
  "dart_api_dl.c"
)
''';

    test('replaces monorepo placeholder with resolved absolute path', () {
      final updated = updateCMakeNitroNative(cmake(monorepoLine), resolved);
      expect(updated, contains(resolvedLine));
      expect(updated, isNot(contains(monorepoLine)));
    });

    test('preserves all other cmake content unchanged', () {
      final original = cmake(monorepoLine);
      final updated = updateCMakeNitroNative(original, resolved);
      // All other lines must be intact
      expect(updated, contains('cmake_minimum_required(VERSION 3.10)'));
      expect(updated, contains('project(my_plugin_library'));
      expect(updated, contains('set(GENERATED_CPP'));
      expect(updated, contains('"dart_api_dl.c"'));
    });

    test('is idempotent — applying twice gives same result, no duplication', () {
      final once = updateCMakeNitroNative(cmake(monorepoLine), resolved);
      final twice = updateCMakeNitroNative(once, resolved);
      expect(twice, equals(once));
      // Exactly one set(NITRO_NATIVE ...) line in result
      final setCount = RegExp(r'set\(NITRO_NATIVE').allMatches(twice).length;
      expect(setCount, equals(1));
    });

    test('running with a different path updates to the new path', () {
      const path1 = '/pub/cache/nitro-0.1.0/src/native';
      const path2 = '/pub/cache/nitro-0.2.0/src/native';
      final first = updateCMakeNitroNative(cmake(monorepoLine), path1);
      final second = updateCMakeNitroNative(first, path2);
      expect(second, contains('set(NITRO_NATIVE "$path2")'));
      expect(second, isNot(contains(path1)));
      final setCount = RegExp(r'set\(NITRO_NATIVE').allMatches(second).length;
      expect(setCount, equals(1));
    });

    test('returns content unchanged when no NITRO_NATIVE line exists', () {
      const noNitro = 'cmake_minimum_required(VERSION 3.10)\nproject(foo)\n';
      final result = updateCMakeNitroNative(noNitro, resolved);
      expect(result, equals(noNitro));
    });

    test('does not affect GENERATED_CPP or other set() variables', () {
      final updated = updateCMakeNitroNative(cmake(monorepoLine), resolved);
      expect(
        updated,
        contains(r'set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")'),
      );
    });

    test('result contains no CMAKE_CURRENT_SOURCE_DIR in NITRO_NATIVE line', () {
      final updated = updateCMakeNitroNative(cmake(monorepoLine), resolved);
      final nitroLine = updated
          .split('\n')
          .firstWhere((l) => l.contains('set(NITRO_NATIVE'));
      expect(nitroLine, isNot(contains(r'${CMAKE_CURRENT_SOURCE_DIR}')));
      expect(nitroLine, contains(resolved));
    });
  });

  // ── dartApiDlForwarderContent idempotency ──────────────────────────────────

  group('dartApiDlForwarderContent idempotency', () {
    test('writing the same path twice produces identical content', () {
      const path = '/pub/cache/nitro/src/native';
      expect(dartApiDlForwarderContent(path), equals(dartApiDlForwarderContent(path)));
    });

    test('content has exactly one #include line', () {
      final content = dartApiDlForwarderContent('/some/path');
      final count = '#include'.allMatches(content).length;
      expect(count, equals(1));
    });

    test('updating path replaces old include, no duplicate includes', () {
      // Simulate writing once with path1 then again with path2.
      const path2 = '/pub/cache/nitro-0.2.0/src/native';
      final second = dartApiDlForwarderContent(path2);
      final includeCount = '#include'.allMatches(second).length;
      expect(includeCount, equals(1));
      expect(second, contains(path2));
    });
  });
}
