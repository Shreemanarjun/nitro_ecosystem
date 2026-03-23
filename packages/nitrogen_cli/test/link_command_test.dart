import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/link_command.dart';
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
}
