import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/spm_utils.dart' as spm;
import 'package:nitrogen_cli/templates/cmake_templates.dart' as ct;
import 'package:nitrogen_cli/templates/cpp_stubs.dart' as t;
import 'package:nitrogen_cli/templates/swift_templates.dart' as st;
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

File _writeSpec(Directory dir, String name, String content) {
  final f = File(p.join(dir.path, name));
  f.writeAsStringSync(content);
  return f;
}

Directory _libDir(Directory tmp) {
  return Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nitro_link_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ── isCppModule ─────────────────────────────────────────────────────────────

  group('isCppModule', () {
    test('returns true when both ios and android are NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
import 'package:nitro/nitro.dart';
@NitroModule(lib: "math", ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when only ios is NativeImpl.cpp (ios-only cpp)', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when only macosImpl is NativeImpl.cpp (macos-only cpp)', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", macos: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when ios+macos are both NativeImpl.cpp (no android)', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when ios is NativeImpl.cpp even when android is kotlin (mixed)', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.cpp, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns false when neither impl is NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isFalse);
    });

    test('returns false when no @NitroModule annotation present', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
abstract class Math {}
''');
      expect(isCppModule(spec), isFalse);
    });

    test('returns false when annotation is empty', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule()
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isFalse);
    });

    test('returns false when lib name contains NativeImpl.cpp but no platform uses it', () {
      // lib name "NativeImpl.cpp" must not be confused with a platform arg
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "NativeImpl.cpp", android: NativeImpl.kotlin)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isFalse);
    });

    test('returns true for multi-line annotation with macos: NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(
  lib: "math",
  macos: NativeImpl.cpp,
)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when all three Apple/Android platforms are NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when only windows is NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", windows: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when only linux is NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", linux: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when windows + linux are both NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", windows: NativeImpl.cpp, linux: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns true when all five native platforms are NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(
  lib: "math",
  ios: NativeImpl.cpp,
  android: NativeImpl.cpp,
  macos: NativeImpl.cpp,
  windows: NativeImpl.cpp,
  linux: NativeImpl.cpp,
)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns false when only web: NativeImpl.wasm (web is not a native C++ platform)', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", web: NativeImpl.wasm)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isFalse);
    });

    test('returns false when annotation body contains NativeImpl.cpp only in a comment', () {
      // Comment-only occurrence must not trigger the platform check
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
// Use ios: NativeImpl.cpp for fast path
@NitroModule(lib: "math", ios: NativeImpl.swift)
abstract class Math extends HybridObject {}
''');
      // The comment is outside the annotation body captured by the regex, so isFalse
      expect(isCppModule(spec), isFalse);
    });
  });

  // ── discoverModuleInfos ──────────────────────────────────────────────────────

  group('discoverModuleInfos', () {
    test('sets isCpp=true for NativeImpl.cpp spec', () {
      final libDir = _libDir(tmp);
      _writeSpec(libDir, 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      final modules = discoverModuleInfos('plugin_name', baseDir: tmp.path);
      expect(modules, hasLength(1));
      expect(modules.first.lib, equals('math'));
      expect(modules.first.isCpp, isTrue);
    });

    test('sets isCpp=false for Swift/Kotlin spec', () {
      final libDir = _libDir(tmp);
      _writeSpec(libDir, 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {}
''');
      final modules = discoverModuleInfos('plugin_name', baseDir: tmp.path);
      expect(modules, hasLength(1));
      expect(modules.first.isCpp, isFalse);
    });

    test('handles mixed cpp and kotlin modules in same project', () {
      final libDir = _libDir(tmp);
      _writeSpec(libDir, 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      _writeSpec(libDir, 'utils.native.dart', '''
@NitroModule(lib: "utils", ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Utils extends HybridObject {}
''');
      final modules = discoverModuleInfos('plugin_name', baseDir: tmp.path);
      expect(modules, hasLength(2));
      final math = modules.firstWhere((m) => m.lib == 'math');
      final utils = modules.firstWhere((m) => m.lib == 'utils');
      expect(math.isCpp, isTrue);
      expect(utils.isCpp, isFalse);
    });

    test('deduplicates modules with the same class name', () {
      final libDir = _libDir(tmp);
      // Two files with the same class name — only one module should be discovered
      _writeSpec(libDir, 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      final subDir = Directory(p.join(libDir.path, 'sub'))..createSync();
      _writeSpec(subDir, 'math.native.dart', '''
@NitroModule(lib: "math", ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      final modules = discoverModuleInfos('plugin_name', baseDir: tmp.path);
      expect(modules.where((m) => m.module == 'Math'), hasLength(1));
    });

    test('defaults to plugin name fallback when lib/ does not exist', () {
      final modules = discoverModuleInfos('my_plugin', baseDir: tmp.path);
      expect(modules, hasLength(1));
      expect(modules.first.lib, equals('my_plugin'));
      expect(modules.first.isCpp, isFalse);
    });

    test('defaults to plugin name fallback when no specs found in lib/', () {
      Directory(p.join(tmp.path, 'lib')).createSync();
      final modules = discoverModuleInfos('my_plugin', baseDir: tmp.path);
      expect(modules, hasLength(1));
      expect(modules.first.lib, equals('my_plugin'));
    });

    test('sets isCpp=true for macos-only NativeImpl.cpp spec', () {
      _writeSpec(_libDir(tmp), 'nav.native.dart', '''
@NitroModule(lib: "nav", macos: NativeImpl.cpp)
abstract class Nav extends HybridObject {}
''');
      final modules = discoverModuleInfos('plugin_name', baseDir: tmp.path);
      expect(modules.first.isCpp, isTrue, reason: 'macos: NativeImpl.cpp alone is sufficient to mark the module as cpp');
    });

    test('sets isCpp=true for tri-platform cpp spec (ios+android+macos)', () {
      _writeSpec(_libDir(tmp), 'engine.native.dart', '''
@NitroModule(lib: "engine", ios: NativeImpl.cpp, android: NativeImpl.cpp, macos: NativeImpl.cpp)
abstract class Engine extends HybridObject {}
''');
      final modules = discoverModuleInfos('plugin_name', baseDir: tmp.path);
      expect(modules.first.isCpp, isTrue);
    });

    test('handles filenames with consecutive underscores (toPascalCase safety)', () {
      final libDir = _libDir(tmp);
      _writeSpec(libDir, 'my__module.native.dart', '''
@NitroModule(lib: "my_lib")
abstract class MyModule extends HybridObject {}
''');
      final modules = discoverModuleInfos('plugin_name', baseDir: tmp.path);
      expect(modules, hasLength(1));
      expect(modules.first.module, equals('MyModule'));
    });
  });

  group('LinkCommand Module Discovery', () {
    test('discovers modules from *.native.dart files', () {
      final libDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);

      File(p.join(libDir.path, 'my_module.native.dart')).writeAsStringSync('''
import 'package:nitro/nitro.dart';

@NitroModule(lib: "my_lib")
abstract class MyModule extends HybridObject {
}
''');

      final modules = discoverModules('plugin_name', baseDir: tmp.path);
      expect(modules, hasLength(1));
      expect(modules.first['lib'], equals('my_lib'));
      expect(modules.first['module'], equals('MyModule'));
    });

    test('defaults to plugin name when no specs found', () {
      final modules = discoverModules('plugin_name', baseDir: tmp.path);
      expect(modules, hasLength(1));
      expect(modules.first['lib'], equals('plugin_name'));
      expect(modules.first['module'], equals('plugin_name'));
    });
  });

  group('LinkCommand Native Path Resolution', () {
    test('resolves nitro native path from package_config.json', () {
      final dotTool = Directory(p.join(tmp.path, '.dart_tool'))..createSync();
      File(p.join(dotTool.path, 'package_config.json')).writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "nitro",
      "rootUri": "file:///path/to/nitro",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    }
  ]
}
''');

      final path = resolveNitroNativePath(tmp.path);
      expect(path, equals(p.join('/path/to/nitro', 'src', 'native')));
    });

    test('resolves relative paths from package_config.json correctly', () {
      final dotTool = Directory(p.join(tmp.path, '.dart_tool'))..createSync();
      File(p.join(dotTool.path, 'package_config.json')).writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "nitro",
      "rootUri": "../relative/nitro",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    }
  ]
}
''');

      final path = resolveNitroNativePath(tmp.path);
      // .dart_tool/../relative/nitro/src/native -> <tmp>/relative/nitro/src/native
      expect(path, equals(p.normalize(p.join(tmp.path, 'relative', 'nitro', 'src', 'native'))));
    });

    test('throws contextual error when package_config.json is malformed', () {
      final dotTool = Directory(p.join(tmp.path, '.dart_tool'))..createSync();
      final config = File(p.join(dotTool.path, 'package_config.json'))..writeAsStringSync('{ not json');

      expect(
        () => resolveNitroNativePath(tmp.path),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Failed to parse'),
              contains(config.path),
              contains('nitro native path'),
            ),
          ),
        ),
      );
    });
  });

  // ── linkCppImplStubs ──────────────────────────────────────────────────────────

  group('linkCppImplStubs', () {
    test('creates stub file for a cpp module when none exists', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true)], baseDir: tmp.path);
      final stub = File(p.join(tmp.path, 'src', 'HybridMath.cpp'));
      expect(stub.existsSync(), isTrue);
      final content = stub.readAsStringSync();
      expect(content, contains('HybridMath'));
      expect(content, contains('math_register_impl'));
      expect(content, contains('__attribute__((constructor))'));
      expect(content, contains('#include "../lib/src/generated/cpp/math.native.g.h"'));
    });

    test('does not overwrite an existing stub file', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      final stub = File(p.join(tmp.path, 'src', 'HybridMath.cpp'));
      stub.writeAsStringSync('// user code');
      linkCppImplStubs([ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true)], baseDir: tmp.path);
      expect(stub.readAsStringSync(), equals('// user code'));
    });

    test('does not create stub for a non-cpp module', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([ModuleInfo(lib: 'sensor', module: 'Sensor', isCpp: false)], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'src', 'HybridSensor.cpp')).existsSync(), isFalse);
    });

    test('creates stubs for multiple cpp modules', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([
        ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true),
        ModuleInfo(lib: 'crypto', module: 'Crypto', isCpp: true, isNativeCpp: true),
      ], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'src', 'HybridMath.cpp')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'src', 'HybridCrypto.cpp')).existsSync(), isTrue);
    });

    test('lib name with underscores produces correct PascalCase class name', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([ModuleInfo(lib: 'my_math_lib', module: 'MyMathLib', isCpp: true, isNativeCpp: true)], baseDir: tmp.path);
      final stub = File(p.join(tmp.path, 'src', 'HybridMyMathLib.cpp'));
      expect(stub.existsSync(), isTrue);
      expect(stub.readAsStringSync(), contains('my_math_lib_register_impl'));
    });

    test('linux-only C++ stub excludes __ANDROID__ from auto-register guard', () {
      // isNativeCpp=true + isAndroidCpp=false means only Linux uses C++.
      // Android uses Kotlin JNI — register_impl is NOT defined on Android, so
      // the auto-register must be guarded with !defined(__ANDROID__).
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs(
        [ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true, isAndroidCpp: false)],
        baseDir: tmp.path,
      );
      final content = File(p.join(tmp.path, 'src', 'HybridMath.cpp')).readAsStringSync();
      expect(content, contains('!defined(__ANDROID__)'), reason: 'Linux-only C++ guard must exclude Android NDK');
      expect(content, isNot(contains('#if !defined(__APPLE__)')), reason: 'bare !defined(__APPLE__) would wrongly include Android');
    });

    test('android C++ stub uses !defined(__APPLE__) guard without Android exclusion', () {
      // isAndroidCpp=true: Android uses C++ directly, so register_impl IS defined
      // on Android. The guard should NOT exclude Android.
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs(
        [ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true, isAndroidCpp: true)],
        baseDir: tmp.path,
      );
      final content = File(p.join(tmp.path, 'src', 'HybridMath.cpp')).readAsStringSync();
      expect(content, contains('!defined(__APPLE__)'), reason: 'Android C++ guard must include Android');
    });
  });

  // ── linkKotlinLoadLibraries ───────────────────────────────────────────────────

  group('linkKotlinLoadLibraries', () {
    File writeKotlinPlugin(Directory tmp, String content) {
      final dir = Directory(p.join(tmp.path, 'android', 'src', 'main', 'kotlin', 'dev', 'test'))..createSync(recursive: true);
      final f = File(p.join(dir.path, 'TestPlugin.kt'));
      f.writeAsStringSync(content);
      return f;
    }

    test('adds System.loadLibrary for a cpp module lib', () {
      final plugin = writeKotlinPlugin(tmp, '''
package dev.test
class TestPlugin {
    companion object {
        init { System.loadLibrary("my_plugin") }
    }
}
''');
      linkKotlinLoadLibraries(['math_cpp'], baseDir: tmp.path);
      final content = plugin.readAsStringSync();
      expect(content, contains('System.loadLibrary("math_cpp")'));
    });

    test('does not add duplicate System.loadLibrary', () {
      final plugin = writeKotlinPlugin(tmp, '''
package dev.test
class TestPlugin {
    companion object {
        init {
            System.loadLibrary("my_plugin")
            System.loadLibrary("math_cpp")
        }
    }
}
''');
      linkKotlinLoadLibraries(['math_cpp'], baseDir: tmp.path);
      final content = plugin.readAsStringSync();
      expect('System.loadLibrary("math_cpp")'.allMatches(content).length, equals(1));
    });

    test('adds multiple cpp libraries', () {
      final plugin = writeKotlinPlugin(tmp, '''
package dev.test
class TestPlugin {
    companion object {
        init { System.loadLibrary("my_plugin") }
    }
}
''');
      linkKotlinLoadLibraries(['lib_a', 'lib_b'], baseDir: tmp.path);
      final content = plugin.readAsStringSync();
      expect(content, contains('System.loadLibrary("lib_a")'));
      expect(content, contains('System.loadLibrary("lib_b")'));
    });
  });

  // ── linkPodspec — NativeImpl.cpp impl file wiring ───────────────────────────

  // Builds the minimum directory/file layout that linkPodspec needs to run
  // without hitting "file not found" early-exits.
  void scaffoldPodspec(String pluginName) {
    Directory(p.join(tmp.path, 'ios', 'Classes')).createSync(recursive: true);
    File(p.join(tmp.path, 'ios', '$pluginName.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name          = '$pluginName'
  s.version       = '0.0.1'
  s.platform      = :ios, '11.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = {}
end
''');
  }

  // Creates the generated bridge files and src impl file for a single C++ module.
  // Pass [appleCpp: true] to also write a .native.dart spec that marks it as an
  // Apple C++ module so linkPodspec's isAppleCppModule check recognises it.
  void scaffoldCppModule(String lib, {bool appleCpp = false}) {
    final pascal = lib.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');
    Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
    File(p.join(tmp.path, 'src', 'Hybrid$pascal.cpp')).writeAsStringSync('// impl');
    final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
    File(p.join(genCpp.path, '$lib.bridge.g.cpp')).writeAsStringSync('// bridge cpp');
    File(p.join(genCpp.path, '$lib.bridge.g.h')).writeAsStringSync('// bridge header');
    File(p.join(genCpp.path, '$lib.native.g.h')).writeAsStringSync('// native header (C++ types)');
    if (appleCpp) {
      // Spec file so isAppleCppModule recognises this as an Apple C++ module.
      final specDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(specDir.path, '$lib.native.dart')).writeAsStringSync(
        "@NitroModule(lib: '$lib', ios: AppleNativeImpl.cpp, macos: AppleNativeImpl.cpp)\n"
        'abstract class $pascal extends HybridObject {}\n',
      );
    }
  }

  group('linkPodspec — NativeImpl.cpp impl file wiring', () {
    test('creates ios/Classes/Hybrid<Lib>.cpp forwarder for a NativeImpl.cpp module', () {
      scaffoldPodspec('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true),
        ],
      );

      final forwarder = File(p.join(tmp.path, 'ios', 'Classes', 'HybridMyCppMod.cpp'));
      expect(forwarder.existsSync(), isTrue);
    });

    test('forwarder includes the correct relative path to src/', () {
      scaffoldPodspec('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true),
        ],
      );

      final content = File(p.join(tmp.path, 'ios', 'Classes', 'HybridMyCppMod.cpp')).readAsStringSync();
      expect(content, contains('#include "../../src/HybridMyCppMod.cpp"'));
    });

    test('does NOT create forwarder when the impl src file does not exist', () {
      scaffoldPodspec('my_plugin');
      // Scaffold generated files but NOT the src/HybridMyCppMod.cpp file.
      Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp')).createSync(recursive: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true),
        ],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Classes', 'HybridMyCppMod.cpp')).existsSync(),
        isFalse,
      );
    });

    test('does NOT create forwarder for a non-cpp (Swift) module', () {
      scaffoldPodspec('my_plugin');
      scaffoldCppModule('my_swift_mod');

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_swift_mod'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_swift_mod', module: 'MySwiftMod', isCpp: false),
        ],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Classes', 'HybridMySwiftMod.cpp')).existsSync(),
        isFalse,
        reason: 'Swift modules are registered at runtime; no compile-time forwarder needed',
      );
    });

    test('null moduleInfos skips C++ impl wiring without crashing', () {
      scaffoldPodspec('my_plugin');

      expect(
        () => linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path, moduleInfos: null),
        returnsNormally,
      );
    });
  });

  // ── _syncCppModuleSourcesToSpm (via linkPodspec → ensureIosPackageSwift) ────

  group('_syncCppModuleSourcesToSpm — SPM C++ module source wiring', () {
    // Sets up a flat SPM layout with Package.swift + Sources/<PluginCpp>/ already
    // present, simulating an existing SPM-enabled project that has been fully
    // initialised before.  Both Package.swift and the Cpp target dir are required
    // so that _syncCppModuleSourcesToSpm can locate and populate them.
    void scaffoldSpm(String pluginName) {
      scaffoldPodspec(pluginName);
      final pascal = pluginName.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');
      Directory(p.join(tmp.path, 'ios', 'Sources', '${pascal}Cpp')).createSync(recursive: true);
      // Also create Package.swift so ensureIosPackageSwift does not re-create it
      // (which would redundantly call createSync and mask real failures).
      File(p.join(tmp.path, 'ios', 'Package.swift')).writeAsStringSync('// existing');
    }

    test('creates .bridge.g.mm forwarder in the module\'s own Sources/<ModuleCpp>/ (issue #15)', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'MyCppModCpp', 'my_cpp_mod.bridge.g.mm')).existsSync(),
        isTrue,
        reason: 'each non-main module owns its own SPM C++ target',
      );
      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'my_cpp_mod.bridge.g.mm')).existsSync(),
        isFalse,
        reason: 'the plugin-level target must NOT also compile it (duplicate symbols)',
      );
    });

    test('module target gets an umbrella header re-exporting the Dart DL API (issue #15)', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      final umbrella = File(p.join(tmp.path, 'ios', 'Sources', 'MyCppModCpp', 'include', 'MyCppModCpp.h'));
      expect(umbrella.existsSync(), isTrue, reason: 'umbrella header makes `import MyCppModCpp` resolve in Swift');
      expect(umbrella.readAsStringSync(), contains('#include "dart_api_dl.h"'));
    });

    test('REPAIR: module sources previously synced into the plugin target are removed (issue #15)', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);
      // Simulate the pre-fix state: the module's files live in the plugin target.
      final pluginCpp = Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp'))..createSync(recursive: true);
      Directory(p.join(pluginCpp.path, 'include')).createSync(recursive: true);
      final staleMm = File(p.join(pluginCpp.path, 'my_cpp_mod.bridge.g.mm'))..writeAsStringSync('// stale');
      final staleImpl = File(p.join(pluginCpp.path, 'HybridMyCppMod.cpp'))..writeAsStringSync('// stale');
      final staleH = File(p.join(pluginCpp.path, 'include', 'my_cpp_mod.bridge.g.h'))..writeAsStringSync('// stale');

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(staleMm.existsSync(), isFalse, reason: 'duplicate bridge compilation causes duplicate-symbol link errors');
      expect(staleImpl.existsSync(), isFalse);
      expect(staleH.existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'ios', 'Sources', 'MyCppModCpp', 'my_cpp_mod.bridge.g.mm')).existsSync(), isTrue);
    });

    test('.bridge.g.mm forwarder includes path to the generated .bridge.g.cpp', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      final content = File(
        p.join(
          tmp.path,
          'ios',
          'Sources',
          'MyCppModCpp',
          'my_cpp_mod.bridge.g.mm',
        ),
      ).readAsStringSync();
      expect(content, contains('my_cpp_mod.bridge.g.cpp'));
    });

    test('creates Hybrid<Lib>.cpp forwarder in the module target (issue #15)', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'MyCppModCpp', 'HybridMyCppMod.cpp')).existsSync(),
        isTrue,
      );
    });

    test('copies .bridge.g.h into the module target include/', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(
        File(
          p.join(
            tmp.path,
            'ios',
            'Sources',
            'MyCppModCpp',
            'include',
            'my_cpp_mod.bridge.g.h',
          ),
        ).existsSync(),
        isTrue,
        reason: '.bridge.g.h is C-compatible and safe to expose as a public SPM header',
      );
    });

    test('does NOT copy .native.g.h into Sources/<PluginCpp>/include/', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod');

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(
        File(
          p.join(
            tmp.path,
            'ios',
            'Sources',
            'MyCppModCpp',
            'include',
            'my_cpp_mod.native.g.h',
          ),
        ).existsSync(),
        isFalse,
        reason:
            '.native.g.h contains C++ types (std::string, classes) that break the '
            'CocoaPods umbrella header when placed in a public include dir',
      );
    });

    test('auto-creates Sources/<PluginCpp>/ when Package.swift exists but dir is missing', () {
      // Simulate the real-world scenario that caused "Failed to lookup symbol
      // '<plugin>_init_dart_api_dl'": Package.swift exists (iosHasSpm=true) but
      // Sources/<PluginCpp>/ was never created — e.g. manual Package.swift setup
      // or a previous partial nitrogen link run.
      scaffoldPodspec('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);
      // Create Package.swift WITHOUT Sources/<PluginCpp>/.
      File(p.join(tmp.path, 'ios', 'Package.swift')).writeAsStringSync('// existing');
      // Ensure the dir does NOT exist before link runs.
      expect(
        Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp')).existsSync(),
        isFalse,
      );

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      // After link, the directory should have been created and the bridge forwarder written.
      expect(
        Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp')).existsSync(),
        isTrue,
        reason: 'nitrogen link should create Sources/<PluginCpp>/ when missing',
      );
    });

    test('no-op when moduleInfos contains no C++ modules', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_swift_mod');

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_swift_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_swift_mod', module: 'MySwiftMod', isCpp: false)],
      );

      final spmDir = Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp'));
      // Nothing should be created inside the SPM dir (no .mm or .cpp forwarders).
      final children = spmDir.listSync().whereType<File>().toList();
      expect(children, isEmpty);
    });

    // ── Regression: bridge.g.mm must survive when lib == pluginName ──────────
    //
    // The most common plugin layout has a single module whose lib name matches
    // the plugin name (e.g. plugin "my_plugin", @NitroModule(lib: "my_plugin")).
    // A previous bug caused _syncCppModuleSourcesToSpm to delete the main plugin
    // bridge.g.mm written earlier in the same function when the module was in
    // allCppModules (isCpp=true) but NOT an Apple C++ module (isApple=false),
    // because the stale-cleanup `else` branch used `bridgeMm.deleteSync()` without
    // checking whether `lib == pluginName`.

    test('bridge.g.mm survives link when lib == pluginName and module is not Apple-cpp', () {
      scaffoldSpm('my_plugin');
      // The main plugin C++ file (src/my_plugin.cpp) makes hasCContent=true so
      // the SPM target is populated.
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'my_plugin.cpp')).writeAsStringSync('// stub');

      // Single module with lib == pluginName, isCpp=true but NOT Apple-cpp
      // (e.g. android: NativeImpl.cpp only). The module is in allCppModules
      // (broad isCpp check) but isApple=false because the .native.dart has no
      // ios/macos NativeImpl.cpp annotation — so the else-branch ran deleteSync.
      linkPodspec(
        'my_plugin',
        ['my_plugin'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: true)],
      );

      final bridgeMm = File(
        p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'my_plugin.bridge.g.mm'),
      );
      expect(
        bridgeMm.existsSync(),
        isTrue,
        reason: 'bridge.g.mm must not be deleted when lib == pluginName',
      );
      // Content must include Foundation import (main plugin bridge format).
      expect(bridgeMm.readAsStringSync(), contains('#import <Foundation/Foundation.h>'));
    });

    test('bridge.g.mm uses relative path (not absolute) for portability', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      final content = File(
        p.join(tmp.path, 'ios', 'Sources', 'MyCppModCpp', 'my_cpp_mod.bridge.g.mm'),
      ).readAsStringSync();
      // Must use a relative path (starts with ../) not an absolute path.
      expect(
        content,
        isNot(contains(tmp.path)),
        reason: 'bridge.g.mm #include must use a relative path, not an absolute filesystem path',
      );
      expect(content, contains('../'));
    });

    test('bridge.g.mm for Apple-cpp module written even when bridge.g.cpp not yet generated', () {
      scaffoldSpm('my_plugin');
      // NOTE: do NOT create the .bridge.g.cpp — simulates running link before generate.
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'my_plugin.cpp')).writeAsStringSync('// stub');

      // Scaffold the .native.dart with ios: AppleNativeImpl.cpp so isApple=true.
      final libDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(libDir.path, 'my_cpp_mod.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'my_cpp_mod', ios: AppleNativeImpl.cpp)\n"
        'abstract class MyCppMod extends HybridObject {}',
      );

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'MyCppModCpp', 'my_cpp_mod.bridge.g.mm')).existsSync(),
        isTrue,
        reason: 'bridge.g.mm must be written even when bridge.g.cpp does not exist yet',
      );
    });

    // ── Multi-spec Swift plugin: additional Swift module .mm wrappers ─────────
    //
    // When a Flutter plugin has multiple @NitroModule specs and all use Swift
    // (isCpp: false), each spec generates a ${lib}.bridge.g.cpp that defines
    // C symbols like ${lib}_init_dart_api_dl.  SPM compiles only files in
    // Sources/<PluginCpp>/, so a .mm wrapper must exist for every module.
    // Without it, the app crashes at runtime:
    //   "Failed to lookup symbol 'nitro_ui_init_dart_api_dl': symbol not found"

    test('multi-spec Swift: 2nd Swift module gets .bridge.g.mm in its OWN Cpp target (issue #15)', () {
      scaffoldSpm('my_plugin');
      // src/my_plugin.cpp makes hasCContent=true so the Cpp target is populated.
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'my_plugin.cpp')).writeAsStringSync('// stub');
      // Scaffold bridge cpp for the additional Swift module.
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'nitro_ui.bridge.g.cpp')).writeAsStringSync('// bridge');

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'nitro_ui'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: false),
          const ModuleInfo(lib: 'nitro_ui', module: 'NitroUi', isCpp: false),
        ],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'NitroUiCpp', 'nitro_ui.bridge.g.mm')).existsSync(),
        isTrue,
        reason: 'Swift module nitro_ui must have a .mm wrapper (in its own target, issue #15) so SPM links nitro_ui_init_dart_api_dl',
      );
    });

    test('multi-spec Swift: 3-spec plugin writes .mm for all non-plugin modules', () {
      scaffoldSpm('my_plugin');
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'my_plugin.cpp')).writeAsStringSync('// stub');
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'nitro_ui.bridge.g.cpp')).writeAsStringSync('// bridge');
      File(p.join(genCpp.path, 'nitro_system.bridge.g.cpp')).writeAsStringSync('// bridge');

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'nitro_ui', 'nitro_system'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: false),
          const ModuleInfo(lib: 'nitro_ui', module: 'NitroUi', isCpp: false),
          const ModuleInfo(lib: 'nitro_system', module: 'NitroSystem', isCpp: false),
        ],
      );

      final sourcesDir = p.join(tmp.path, 'ios', 'Sources');
      expect(File(p.join(sourcesDir, 'NitroUiCpp', 'nitro_ui.bridge.g.mm')).existsSync(), isTrue);
      expect(File(p.join(sourcesDir, 'NitroSystemCpp', 'nitro_system.bridge.g.mm')).existsSync(), isTrue);
      // The main plugin bridge stays in the plugin-level target.
      expect(File(p.join(sourcesDir, 'MyPluginCpp', 'my_plugin.bridge.g.mm')).existsSync(), isTrue);
    });

    test('multi-spec Swift: .mm uses relative path to generated bridge .cpp', () {
      scaffoldSpm('my_plugin');
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'my_plugin.cpp')).writeAsStringSync('// stub');
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'nitro_ui.bridge.g.cpp')).writeAsStringSync('// bridge');

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'nitro_ui'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: false),
          const ModuleInfo(lib: 'nitro_ui', module: 'NitroUi', isCpp: false),
        ],
      );

      final content = File(
        p.join(tmp.path, 'ios', 'Sources', 'NitroUiCpp', 'nitro_ui.bridge.g.mm'),
      ).readAsStringSync();
      expect(content, contains('nitro_ui.bridge.g.cpp'), reason: 'must reference the correct bridge file');
      expect(content, contains('../'), reason: 'path must be relative, not absolute');
      expect(content, isNot(contains(tmp.path)), reason: 'must not embed absolute filesystem path');
    });

    test('multi-spec Swift: .mm written even when bridge.g.cpp does not exist yet', () {
      scaffoldSpm('my_plugin');
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'my_plugin.cpp')).writeAsStringSync('// stub');
      // Intentionally do NOT create nitro_ui.bridge.g.cpp — simulates link-before-generate.

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'nitro_ui'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: false),
          const ModuleInfo(lib: 'nitro_ui', module: 'NitroUi', isCpp: false),
        ],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'NitroUiCpp', 'nitro_ui.bridge.g.mm')).existsSync(),
        isTrue,
        reason: '.mm forwarder must exist even before nitrogen generate has run',
      );
    });

    test('multi-spec Swift: macOS SPM target also gets .mm wrappers for additional modules', () {
      // ensureMacosPackageSwift is what triggers _syncCppModuleSourcesToSpm for macOS.
      // (linkMacosPodspec does not call it — see link_command.dart line 3019-3020.)
      final pascal = 'MyPlugin';
      Directory(p.join(tmp.path, 'macos', 'Sources', '${pascal}Cpp')).createSync(recursive: true);
      File(p.join(tmp.path, 'macos', 'Package.swift')).writeAsStringSync('// existing');
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'my_plugin.cpp')).writeAsStringSync('// stub');

      ensureMacosPackageSwift(
        'my_plugin',
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: false),
          const ModuleInfo(lib: 'nitro_ui', module: 'NitroUi', isCpp: false),
        ],
      );

      expect(
        File(p.join(tmp.path, 'macos', 'Sources', 'NitroUiCpp', 'nitro_ui.bridge.g.mm')).existsSync(),
        isTrue,
        reason: 'macOS also gets the per-module Cpp target (issue #15)',
      );
    });
  });

  group('LinkCommand Content Generation', () {
    test('linkPodspec updates Swift version and Header Search Paths', () {
      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      final podspec = File(p.join(iosDir.path, 'my_plugin.podspec'));
      podspec.writeAsStringSync('''
Pod::Spec.new do |s|
  s.name             = 'my_plugin'
  s.version          = '0.0.1'
  s.platform         = :ios, '11.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-framework SomeFramework' }
end
''');

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final content = podspec.readAsStringSync();
      expect(content, contains("s.swift_version = '5.9'"));
      expect(content, contains("s.platform = :ios, '13.0'"));
      expect(content, contains('HEADER_SEARCH_PATHS'));
      expect(content, contains('DEFINES_MODULE'));
    });

    test('linkCMake updates NITRO_NATIVE and modules', () {
      final srcDir = Directory(p.join(tmp.path, 'src'))..createSync();
      final cmake = File(p.join(srcDir.path, 'CMakeLists.txt'));
      cmake.writeAsStringSync('''
add_library(my_plugin SHARED "my_plugin.cpp")
target_include_directories(my_plugin PRIVATE "\${CMAKE_CURRENT_SOURCE_DIR}")
''');

      linkCMake('my_plugin', ['my_plugin', 'other_lib'], '/path/to/nitro/native', baseDir: tmp.path);

      final content = cmake.readAsStringSync();
      expect(content, contains(r'set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")'));
      expect(content, contains('add_library(other_lib SHARED'));
      expect(content, contains('dart_api_dl.c'));
    });

    test('linkCMake adds HybridXxx.cpp inside add_library when android uses C++', () {
      final srcDir = Directory(p.join(tmp.path, 'src'))..createSync();
      final cmake = File(p.join(srcDir.path, 'CMakeLists.txt'));
      cmake.writeAsStringSync('''
add_library(my_plugin SHARED "my_plugin.cpp")
target_include_directories(my_plugin PRIVATE "\${CMAKE_CURRENT_SOURCE_DIR}")
''');
      // Create the impl stub so linkCMake can find it.
      File(p.join(srcDir.path, 'HybridMyPlugin.cpp')).writeAsStringSync('');

      final androidCppInfo = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        isAndroidCpp: true,
      );
      linkCMake(
        'my_plugin',
        ['my_plugin'],
        '/path/to/nitro/native',
        baseDir: tmp.path,
        moduleInfos: [androidCppInfo],
      );

      final content = cmake.readAsStringSync();
      // Android C++ — impl embedded directly in add_library, no NOT ANDROID guard.
      expect(content, contains('"HybridMyPlugin.cpp"'));
      expect(content, isNot(contains('if(NOT ANDROID)')));
    });

    test('linkCMake wraps HybridXxx.cpp in if(NOT ANDROID) when android uses Kotlin', () {
      final srcDir = Directory(p.join(tmp.path, 'src'))..createSync();
      final cmake = File(p.join(srcDir.path, 'CMakeLists.txt'));
      cmake.writeAsStringSync('''
add_library(my_plugin SHARED "my_plugin.cpp")
target_include_directories(my_plugin PRIVATE "\${CMAKE_CURRENT_SOURCE_DIR}")
''');
      File(p.join(srcDir.path, 'HybridMyPlugin.cpp')).writeAsStringSync('');

      final linuxCppInfo = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        isAndroidCpp: false,
      );
      linkCMake(
        'my_plugin',
        ['my_plugin'],
        '/path/to/nitro/native',
        baseDir: tmp.path,
        moduleInfos: [linuxCppInfo],
      );

      final content = cmake.readAsStringSync();
      // Linux-only C++ — impl must be excluded from Android NDK builds.
      expect(content, contains('if(NOT ANDROID)'));
      expect(content, contains('target_sources(my_plugin PRIVATE "HybridMyPlugin.cpp")'));
      expect(content, contains('endif()'));
      // Must NOT be inside add_library block.
      final addLibIdx = content.indexOf('add_library(my_plugin SHARED');
      final ifNotAndroidIdx = content.indexOf('if(NOT ANDROID)');
      expect(ifNotAndroidIdx, greaterThan(addLibIdx));
    });

    test('linkCMake NOT ANDROID guard is idempotent on second run', () {
      final srcDir = Directory(p.join(tmp.path, 'src'))..createSync();
      final cmake = File(p.join(srcDir.path, 'CMakeLists.txt'));
      cmake.writeAsStringSync('''
add_library(my_plugin SHARED "my_plugin.cpp")
if(NOT ANDROID)
  target_sources(my_plugin PRIVATE "HybridMyPlugin.cpp")
endif()
target_include_directories(my_plugin PRIVATE "\${CMAKE_CURRENT_SOURCE_DIR}")
''');
      File(p.join(srcDir.path, 'HybridMyPlugin.cpp')).writeAsStringSync('');

      final linuxCppInfo = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        isAndroidCpp: false,
      );
      linkCMake(
        'my_plugin',
        ['my_plugin'],
        '/path/to/nitro/native',
        baseDir: tmp.path,
        moduleInfos: [linuxCppInfo],
      );

      final content = cmake.readAsStringSync();
      // Guard must appear exactly once.
      expect('"HybridMyPlugin.cpp"'.allMatches(content).length, equals(1));
    });

    test('generateCMakeContent adds if(NOT ANDROID) guard for linux-only C++', () {
      final result = ct.generateCMakeContent(
        'my_plugin',
        ['my_plugin'],
        '/path/to/nitro/native',
        moduleInfos: [
          (lib: 'my_plugin', module: 'MyPlugin', isNativeCpp: true, isAndroidCpp: false),
        ],
      );
      expect(result, contains('if(NOT ANDROID)'));
      expect(result, contains('target_sources(my_plugin PRIVATE "HybridMyPlugin.cpp")'));
      // Must NOT be inside add_library source list.
      expect(result, isNot(contains('"HybridMyPlugin.cpp"\n  "my_plugin.cpp"')));
    });

    test('generateCMakeContent embeds impl in add_library when android uses C++', () {
      final result = ct.generateCMakeContent(
        'my_plugin',
        ['my_plugin'],
        '/path/to/nitro/native',
        moduleInfos: [
          (lib: 'my_plugin', module: 'MyPlugin', isNativeCpp: true, isAndroidCpp: true),
        ],
      );
      expect(result, isNot(contains('if(NOT ANDROID)')));
      expect(result, contains('"HybridMyPlugin.cpp"'));
    });

    test('createSharedHeaders includes NitroError idempotency guard', () {
      final nitroNative = Directory(p.join(tmp.path, 'nitro_native'))..createSync();
      createSharedHeaders(nitroNative.path, baseDir: tmp.path);

      final nitroH = File(p.join(tmp.path, 'src', 'nitro.h'));
      expect(nitroH.existsSync(), isTrue);
      final content = nitroH.readAsStringSync();
      expect(content, contains('#ifndef NITRO_ERROR_DEFINED'));
      expect(content, contains('#define NITRO_ERROR_DEFINED'));
      expect(content, contains('} NitroError;'));
      expect(content, contains('#endif'));
    });

    test('createSharedHeaders writes bundled dart_api_dl.c and local native headers', () {
      final nitroNative = Directory(p.join(tmp.path, 'nitro_native'))..createSync();
      Directory(p.join(nitroNative.path, 'internal')).createSync();
      for (final header in ['dart_api_dl.h', 'dart_api.h', 'dart_native_api.h', 'dart_version.h']) {
        File(p.join(nitroNative.path, header)).writeAsStringSync('// $header\n');
      }
      File(p.join(nitroNative.path, 'internal', 'dart_api_dl_impl.h')).writeAsStringSync('// impl\n');

      createSharedHeaders(nitroNative.path, baseDir: tmp.path);

      final dartApiDl = File(p.join(tmp.path, 'src', 'dart_api_dl.c')).readAsStringSync();
      expect(dartApiDl, contains('Bundled by nitrogen'));
      expect(dartApiDl, isNot(contains(nitroNative.path)));
      expect(dartApiDl, isNot(contains('#include "${nitroNative.path}')));
      expect(File(p.join(tmp.path, 'src', 'native', 'dart_api_dl.h')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'src', 'native', 'internal', 'dart_api_dl_impl.h')).existsSync(), isTrue);
    });

    test('cleanRedundantIncludes removes bridge imports', () {
      final file = File(p.join(tmp.path, 'plugin.cpp'));
      file.writeAsStringSync('''
#include <stdint.h>
#include "my_plugin.bridge.g.h"
#include "my_plugin.bridge.g.cpp"

void foo() {}
''');

      cleanRedundantIncludes(file);

      final content = file.readAsStringSync();
      expect(content, contains('#include "my_plugin.bridge.g.h"'));
      expect(content, isNot(contains('#include "my_plugin.bridge.g.cpp"')));
      expect(content, contains('void foo() {}'));
    });

    test('linkMacosPodspec is no-op when macos/ directory does not exist', () {
      // No macos/ directory — should not crash.
      expect(
        () => linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path),
        returnsNormally,
      );
    });

    test('linkMacosPodspec inserts s.platform when absent from podspec', () {
      final macosDir = Directory(p.join(tmp.path, 'macos'))..createSync();
      final podspec = File(p.join(macosDir.path, 'my_plugin.podspec'));
      podspec.writeAsStringSync('''
Pod::Spec.new do |s|
  s.name             = 'my_plugin'
  s.version          = '0.0.1'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-framework CoreBluetooth' }
end
''');
      Directory(p.join(tmp.path, 'src')).createSync();

      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      expect(podspec.readAsStringSync(), contains("s.platform = :osx, '10.15'"), reason: 'platform line must be inserted when absent');
    });

    test('linkMacosPodspec does not duplicate DEFINES_MODULE on second run', () {
      final macosDir = Directory(p.join(tmp.path, 'macos'))..createSync();
      final podspec = File(p.join(macosDir.path, 'my_plugin.podspec'));
      podspec.writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.swift_version = '5.9'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '"\${PODS_TARGET_SRCROOT}/../src" "\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp"',
  }
end
''');
      Directory(p.join(tmp.path, 'src')).createSync();

      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);
      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final content = podspec.readAsStringSync();
      expect("'DEFINES_MODULE'".allMatches(content).length, equals(1), reason: 'second run must not duplicate DEFINES_MODULE');
    });

    test('linkMacosPodspec updates Swift version, osx platform and HEADER_SEARCH_PATHS', () {
      final macosDir = Directory(p.join(tmp.path, 'macos'))..createSync();
      final podspec = File(p.join(macosDir.path, 'my_plugin.podspec'));
      podspec.writeAsStringSync('''
Pod::Spec.new do |s|
  s.name             = 'my_plugin'
  s.version          = '0.0.1'
  s.platform         = :osx, '10.11'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-framework SomeFramework' }
end
''');

      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final content = podspec.readAsStringSync();
      expect(content, contains("s.swift_version = '5.9'"));
      expect(content, contains("s.platform = :osx, '10.15'"));
      expect(content, contains('HEADER_SEARCH_PATHS'));
      expect(content, contains('DEFINES_MODULE'));
    });

    test('linkMacosPodspec creates macos/Classes/dart_api_dl.c forwarder', () {
      final macosDir = Directory(p.join(tmp.path, 'macos'))..createSync();
      File(p.join(macosDir.path, 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.pod_target_xcconfig = {}
end
''');
      Directory(p.join(tmp.path, 'src')).createSync();

      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final dartApiDl = File(p.join(tmp.path, 'macos', 'Classes', 'dart_api_dl.c'));
      expect(dartApiDl.existsSync(), isTrue);
      expect(dartApiDl.readAsStringSync(), contains('dart_api_dl.c'));
    });

    test('linkMacosPodspec links C++ impl forwarder for cpp module', () {
      final macosDir = Directory(p.join(tmp.path, 'macos'))..createSync();
      File(p.join(macosDir.path, 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.pod_target_xcconfig = {}
end
''');
      final srcDir = Directory(p.join(tmp.path, 'src'))..createSync();
      File(p.join(srcDir.path, 'HybridMath.cpp')).writeAsStringSync('// impl');
      // Spec file needed so linkMacosPodspec's isAppleCppModule check recognises math as Apple C++.
      final libSrc = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(libSrc.path, 'math.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'math', ios: AppleNativeImpl.cpp, macos: AppleNativeImpl.cpp)\n"
        'abstract class Math extends HybridObject {}\n',
      );

      linkMacosPodspec(
        'my_plugin',
        ['my_plugin'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'math', module: 'Math', isCpp: true)],
      );

      final forwarder = File(p.join(tmp.path, 'macos', 'Classes', 'HybridMath.cpp'));
      expect(forwarder.existsSync(), isTrue);
      expect(forwarder.readAsStringSync(), contains('#include "../../src/HybridMath.cpp"'));
    });
  });

  // ── linkPodspec — source_files + stale Swift bridge cleanup ─────────────────

  group('linkPodspec — source_files and stale Swift bridge cleanup', () {
    void scaffoldMinimalPodspec(String platform, String pluginName, {String? sourceFilesLine}) {
      Directory(p.join(tmp.path, platform, 'Classes')).createSync(recursive: true);
      final srcFilesDecl = sourceFilesLine != null ? "\n  $sourceFilesLine" : '';
      File(p.join(tmp.path, platform, '$pluginName.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = '$pluginName'$srcFilesDecl
  s.pod_target_xcconfig = {}
end
''');
    }

    test('linkPodspec copies .bridge.g.swift into ios/Classes/', () {
      scaffoldMinimalPodspec('ios', 'my_plugin', sourceFilesLine: "s.source_files = 'Classes/**/*'");
      Directory(p.join(tmp.path, 'src')).createSync();
      // Create a generated bridge file that should be copied.
      Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'swift')).createSync(recursive: true);
      File(p.join(tmp.path, 'lib', 'src', 'generated', 'swift', 'my_plugin.bridge.g.swift')).writeAsStringSync('// generated bridge');

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final copied = File(p.join(tmp.path, 'ios', 'Classes', 'my_plugin.bridge.g.swift'));
      expect(copied.existsSync(), isTrue, reason: 'bridge must be copied into Classes/ so Xcode can compile it in scope');
      expect(copied.readAsStringSync(), contains('generated bridge'));
      // The podspec must NOT have the lib/src/generated/swift glob (avoids duplicates).
      final spec = File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(spec, isNot(contains('lib/src/generated/swift')));
    });

    test('linkPodspec is idempotent — copying bridge twice does not duplicate it', () {
      scaffoldMinimalPodspec('ios', 'my_plugin', sourceFilesLine: "s.source_files = 'Classes/**/*'");
      Directory(p.join(tmp.path, 'src')).createSync();
      Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'swift')).createSync(recursive: true);
      File(p.join(tmp.path, 'lib', 'src', 'generated', 'swift', 'my_plugin.bridge.g.swift')).writeAsStringSync('// generated bridge');

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);
      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      // Should still only have one copy and no duplicates in podspec.
      final spec = File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(spec, isNot(contains('lib/src/generated/swift')));
    });

    test('linkMacosPodspec copies .bridge.g.swift into macos/Classes/', () {
      scaffoldMinimalPodspec('macos', 'my_plugin', sourceFilesLine: "s.source_files = 'Classes/**/*'");
      Directory(p.join(tmp.path, 'src')).createSync();
      Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'swift')).createSync(recursive: true);
      File(p.join(tmp.path, 'lib', 'src', 'generated', 'swift', 'my_plugin.bridge.g.swift')).writeAsStringSync('// generated bridge');

      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final copied = File(p.join(tmp.path, 'macos', 'Classes', 'my_plugin.bridge.g.swift'));
      expect(copied.existsSync(), isTrue, reason: 'bridge must be copied into macos/Classes/ for Xcode scope resolution');
      final spec = File(p.join(tmp.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      expect(spec, isNot(contains('lib/src/generated/swift')));
    });

    // ── source_files normalization ──────────────────────────────────────────

    test('linkPodspec fixes SPM-template source_files to Classes/**/* (iOS)', () {
      // The Flutter SPM-first template generates source_files like
      // 'my_plugin/Sources/my_plugin/**/*' which is non-existent when CocoaPods
      // is the build system. nitrogen link must normalise it to 'Classes/**/*'.
      Directory(p.join(tmp.path, 'ios', 'Classes')).createSync(recursive: true);
      File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.source_files = 'my_plugin/Sources/my_plugin/**/*'
  s.pod_target_xcconfig = {}
end
''');
      Directory(p.join(tmp.path, 'src')).createSync();

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final spec = File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(spec, contains("s.source_files = 'Classes/**/*'"), reason: 'linkPodspec must normalise non-existent source_files to Classes/**/*');
      expect(spec, isNot(contains("my_plugin/Sources/my_plugin")));
    });

    test('linkPodspec does NOT change source_files when it is already Classes/**/* (iOS)', () {
      Directory(p.join(tmp.path, 'ios', 'Classes')).createSync(recursive: true);
      File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.source_files = 'Classes/**/*'
  s.pod_target_xcconfig = {}
end
''');
      Directory(p.join(tmp.path, 'src')).createSync();

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final spec = File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(spec, contains("s.source_files = 'Classes/**/*'"), reason: 'Classes/**/* must be preserved as-is');
    });

    test('linkMacosPodspec fixes SPM-template source_files to Classes/**/* (macOS)', () {
      Directory(p.join(tmp.path, 'macos', 'Classes')).createSync(recursive: true);
      File(p.join(tmp.path, 'macos', 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = 'my_plugin'
  s.source_files = 'my_plugin/Sources/my_plugin/**/*'
  s.pod_target_xcconfig = {}
end
''');
      Directory(p.join(tmp.path, 'src')).createSync();

      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final spec = File(p.join(tmp.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      expect(spec, contains("s.source_files = 'Classes/**/*'"), reason: 'linkMacosPodspec must normalise non-existent source_files to Classes/**/*');
      expect(spec, isNot(contains("my_plugin/Sources/my_plugin")));
    });
  });

  // ── linkMacosSwiftPlugin ─────────────────────────────────────────────────────

  group('linkMacosSwiftPlugin', () {
    File writeMacosPlugin(Directory tmp, String content) {
      final dir = Directory(p.join(tmp.path, 'macos', 'Classes'))..createSync(recursive: true);
      final f = File(p.join(dir.path, 'MyPlugin.swift'));
      f.writeAsStringSync(content);
      return f;
    }

    test('injects Registry.register into a new macOS Plugin.swift', () {
      final plugin = writeMacosPlugin(tmp, '''
import Flutter
public class MyPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
  }
}
''');

      linkMacosSwiftPlugin('my_plugin', [
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect(content, contains('MathRegistry.register('));
    });

    test('appends after last existing Registry.register call', () {
      final plugin = writeMacosPlugin(tmp, '''
public static func register(with registrar: FlutterPluginRegistrar) {
  FooRegistry.register(FooImpl())
}
''');

      linkMacosSwiftPlugin('my_plugin', [
        {'module': 'Bar', 'lib': 'bar'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect(content, contains('FooRegistry.register(FooImpl())'));
      expect(content, contains('BarRegistry.register('));
    });

    test('does not duplicate an existing registration', () {
      final plugin = writeMacosPlugin(tmp, '''
public static func register(with registrar: FlutterPluginRegistrar) {
  MathRegistry.register(MathModuleImpl())
}
''');

      linkMacosSwiftPlugin('my_plugin', [
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect('MathRegistry.register'.allMatches(content).length, equals(1));
    });

    test('does not add module import when Registry.register() call already exists (SPM: no module import needed)', () {
      // In the SPM-only model bridge files are compiled into the same package target,
      // so `import nitro_*_module` is not required and is actively removed if stale.
      final plugin = writeMacosPlugin(tmp, '''
import Flutter
public class MyPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    MathRegistry.register(MathImpl())
  }
}
''');

      linkMacosSwiftPlugin('my_plugin', [
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      // No module import is injected in the SPM model.
      expect(content, isNot(contains('import nitro_math_module')));
      // The existing registration is preserved (not duplicated).
      expect('MathRegistry.register'.allMatches(content).length, equals(1));
    });

    test('no-op when macos/ directory does not exist', () {
      expect(
        () => linkMacosSwiftPlugin('my_plugin', [
          {'module': 'Math', 'lib': 'math'},
        ], baseDir: tmp.path),
        returnsNormally,
      );
    });

    test('no-op when no Plugin.swift found in macos/', () {
      Directory(p.join(tmp.path, 'macos', 'Classes')).createSync(recursive: true);
      expect(
        () => linkMacosSwiftPlugin('my_plugin', [
          {'module': 'Math', 'lib': 'math'},
        ], baseDir: tmp.path),
        returnsNormally,
      );
    });
  });

  // ── linkWindows ──────────────────────────────────────────────────────────────

  group('linkWindows', () {
    File writeWinCmake(Directory dir, String content) {
      final winDir = Directory(p.join(dir.path, 'windows'))..createSync(recursive: true);
      final f = File(p.join(winDir.path, 'CMakeLists.txt'));
      f.writeAsStringSync(content);
      return f;
    }

    const minimalWinCmake = '''cmake_minimum_required(VERSION 3.14)
set(PLUGIN_NAME "my_plugin_plugin")

add_library(\${PLUGIN_NAME} SHARED
  "my_plugin_plugin.cpp"
)
target_compile_definitions(\${PLUGIN_NAME} PRIVATE DART_SHARED_LIB)
target_include_directories(\${PLUGIN_NAME} PUBLIC
  "\${CMAKE_CURRENT_SOURCE_DIR}/include")
''';

    test('no-op when windows/ directory does not exist', () {
      expect(
        () => linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro', baseDir: tmp.path),
        returnsNormally,
      );
    });

    test('no-op when windows/CMakeLists.txt does not exist', () {
      Directory(p.join(tmp.path, 'windows')).createSync();
      expect(
        () => linkWindows('my_plugin', ['my_plugin'], '/path/to/nitro', baseDir: tmp.path),
        returnsNormally,
      );
    });

    test('injects NITRO_NATIVE at top of CMakeLists.txt', () {
      final cmake = writeWinCmake(tmp, minimalWinCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect(content, contains(r'set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")'));
      // Must appear before the cmake_minimum_required line
      expect(content.indexOf('NITRO_NATIVE'), lessThan(content.indexOf('cmake_minimum')));
    });

    test('does not duplicate set(NITRO_NATIVE) if already present', () {
      final cmake = writeWinCmake(tmp, 'set(NITRO_NATIVE "old/path")\n$minimalWinCmake');
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      // set(NITRO_NATIVE) must appear exactly once (not injected again)
      expect('set(NITRO_NATIVE'.allMatches(content).length, equals(1));
      expect(content, contains(r'set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")'));
    });

    test('injects dart_api_dl.c into add_library target', () {
      final cmake = writeWinCmake(tmp, minimalWinCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect(content, contains('dart_api_dl.c'));
    });

    test('does not duplicate dart_api_dl.c if already present', () {
      final cmake = writeWinCmake(tmp, 'add_library(\${PLUGIN_NAME} SHARED\n  "dart_api_dl.c"\n)\n');
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect('dart_api_dl.c'.allMatches(content).length, equals(1));
    });

    test('injects bridge .cpp into add_library target', () {
      final cmake = writeWinCmake(tmp, minimalWinCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect(content, contains('../lib/src/generated/cpp/my_plugin.bridge.g.cpp'));
    });

    test('adds NITRO_NATIVE to target_include_directories', () {
      final cmake = writeWinCmake(tmp, minimalWinCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect(content, contains(r'${NITRO_NATIVE}'));
      expect(content, contains('../lib/src/generated/cpp'));
    });
  });

  // ── linkLinux ────────────────────────────────────────────────────────────────

  group('linkLinux', () {
    File writeLinuxCmake(Directory dir, String content) {
      final linuxDir = Directory(p.join(dir.path, 'linux'))..createSync(recursive: true);
      final f = File(p.join(linuxDir.path, 'CMakeLists.txt'));
      f.writeAsStringSync(content);
      return f;
    }

    const minimalLinuxCmake = '''cmake_minimum_required(VERSION 3.10)
set(PLUGIN_NAME "my_plugin_plugin")

add_library(\${PLUGIN_NAME} SHARED
  "my_plugin_plugin.cc"
)
target_compile_definitions(\${PLUGIN_NAME} PRIVATE DART_SHARED_LIB)
target_include_directories(\${PLUGIN_NAME} PUBLIC
  "\${CMAKE_CURRENT_SOURCE_DIR}/include")
''';

    test('no-op when linux/ directory does not exist', () {
      expect(
        () => linkLinux('my_plugin', ['my_plugin'], '/path/to/nitro', baseDir: tmp.path),
        returnsNormally,
      );
    });

    test('injects NITRO_NATIVE at top of CMakeLists.txt', () {
      final cmake = writeLinuxCmake(tmp, minimalLinuxCmake);
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect(content, contains(r'set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")'));
    });

    test('injects dart_api_dl.c into add_library target', () {
      final cmake = writeLinuxCmake(tmp, minimalLinuxCmake);
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect(content, contains('dart_api_dl.c'));
    });

    test('injects bridge .cpp into add_library target', () {
      final cmake = writeLinuxCmake(tmp, minimalLinuxCmake);
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect(content, contains('../lib/src/generated/cpp/my_plugin.bridge.g.cpp'));
    });

    test('adds NITRO_NATIVE to target_include_directories', () {
      final cmake = writeLinuxCmake(tmp, minimalLinuxCmake);
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      expect(content, contains(r'${NITRO_NATIVE}'));
      expect(content, contains('../lib/src/generated/cpp'));
    });

    test('does not duplicate entries on re-run (idempotent)', () {
      final cmake = writeLinuxCmake(tmp, minimalLinuxCmake);
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final afterFirst = cmake.readAsStringSync();
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final afterSecond = cmake.readAsStringSync();
      expect(afterFirst, equals(afterSecond), reason: 'linkLinux must be idempotent');
    });
  });

  // ── shared-src desktop CMake — two distinct plugin shapes ───────────────────
  //
  // "Shared-src" plugins delegate their Nitro module libraries to ../src via
  // add_subdirectory. That marker alone is ambiguous between two shapes:
  //   1. Pure shared-src (single-spec FFI plugins, e.g. nitro_torch): the
  //      Nitro module library IS the only target; `${PLUGIN_NAME}` is never
  //      defined. Appending target_include_directories(${PLUGIN_NAME} ...) is
  //      a hard CMake configure error ("target not found").
  //   2. Multi-spec plugins (e.g. a package bundling several @NitroModule
  //      specs, each becoming its own shared library, PLUS a separate
  //      `<pkg>_plugin` registrant target, e.g. "benchmark_plugin.cc"):
  //      `${PLUGIN_NAME}` IS a real target here. Its public include/ dir must
  //      be exposed via INTERFACE, or the example app's
  //      generated_plugin_registrant.cc fails to find `<pkg>/<pkg>_plugin.h`.
  group('linkLinux / linkWindows — shared-src plugin shapes', () {
    // Shape 1: pure shared-src, no separate plugin_class target (nitro_torch-style).
    const pureSharedSrcCmake = '''cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "my_plugin")
project(\${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("\${CMAKE_CURRENT_SOURCE_DIR}/../src" "\${CMAKE_CURRENT_BINARY_DIR}/shared")

set(my_plugin_bundled_libraries
  \$<TARGET_FILE:my_plugin>
  PARENT_SCOPE
)
''';

    // Shape 2: multi-spec — shared src/ for module libs, PLUS its own
    // registrant target (mirrors benchmark/linux/CMakeLists.txt exactly).
    String multiSpecCmake({bool withStaleIncludeBlock = false}) =>
        '''cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "my_plugin")
project(\${PROJECT_NAME} LANGUAGES C CXX)

set(PLUGIN_NAME "my_plugin_plugin")

add_subdirectory("\${CMAKE_CURRENT_SOURCE_DIR}/../src" nitro_modules)

add_library(\${PLUGIN_NAME} SHARED
  "my_plugin_plugin.cc"
)
${withStaleIncludeBlock ? 'target_include_directories(\${PLUGIN_NAME} INTERFACE\n  "\${CMAKE_CURRENT_SOURCE_DIR}/include")\n' : ''}
target_link_libraries(\${PLUGIN_NAME} PRIVATE flutter)

set(my_plugin_bundled_libraries
  \$<TARGET_FILE:my_plugin>
  PARENT_SCOPE
)
''';

    File writeCmake(Directory dir, String platform, String content) {
      final platDir = Directory(p.join(dir.path, platform))..createSync(recursive: true);
      final f = File(p.join(platDir.path, 'CMakeLists.txt'));
      f.writeAsStringSync(content);
      return f;
    }

    void makeIncludeDir(Directory dir, String platform) {
      Directory(p.join(dir.path, platform, 'include', 'my_plugin')).createSync(recursive: true);
    }

    for (final platform in ['linux', 'windows']) {
      void link() => platform == 'linux'
          ? linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path)
          : linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);

      group('($platform)', () {
        test('shape 1 (pure shared-src, no own target): never adds target_include_directories(\${PLUGIN_NAME})', () {
          final cmake = writeCmake(tmp, platform, pureSharedSrcCmake);
          link();
          final content = cmake.readAsStringSync();
          expect(content, isNot(contains(r'target_include_directories(${PLUGIN_NAME}')));
        });

        test('shape 1: strips a stale target_include_directories(\${PLUGIN_NAME}) block left by an older nitrogen version', () {
          final stale = '$pureSharedSrcCmake\ntarget_include_directories(\${PLUGIN_NAME} PRIVATE "\${NITRO_NATIVE}")\n';
          final cmake = writeCmake(tmp, platform, stale);
          link();
          final content = cmake.readAsStringSync();
          expect(content, isNot(contains(r'target_include_directories(${PLUGIN_NAME}')));
        });

        test('shape 2 (multi-spec, own target + include/ present): adds INTERFACE include_directories', () {
          makeIncludeDir(tmp, platform);
          final cmake = writeCmake(tmp, platform, multiSpecCmake());
          link();
          final content = cmake.readAsStringSync();
          expect(content, contains(r'target_include_directories(${PLUGIN_NAME} INTERFACE'));
          expect(content, contains(r'${CMAKE_CURRENT_SOURCE_DIR}/include'));
        });

        test('shape 2: added include_directories block appears after add_library(\${PLUGIN_NAME} ...)', () {
          makeIncludeDir(tmp, platform);
          final cmake = writeCmake(tmp, platform, multiSpecCmake());
          link();
          final content = cmake.readAsStringSync();
          final addLibIdx = content.indexOf(r'add_library(${PLUGIN_NAME}');
          final inclIdx = content.indexOf(r'target_include_directories(${PLUGIN_NAME} INTERFACE');
          expect(addLibIdx, isNot(-1));
          expect(inclIdx, isNot(-1));
          expect(addLibIdx, lessThan(inclIdx));
        });

        test('shape 2: preserves an already-correct INTERFACE include_directories block unchanged', () {
          // Compare after-first-link to after-second-link (not "never linked"
          // vs "linked once") — the unrelated NITRO_NATIVE auto-injection also
          // fires on the first call against this deliberately minimal fixture,
          // same as every other idempotency test in this file.
          makeIncludeDir(tmp, platform);
          final cmake = writeCmake(tmp, platform, multiSpecCmake(withStaleIncludeBlock: true));
          link();
          final afterFirst = cmake.readAsStringSync();
          expect('target_include_directories'.allMatches(afterFirst).length, equals(1), reason: 'the pre-existing correct block must not be duplicated on first link');
          link();
          final afterSecond = cmake.readAsStringSync();
          expect(afterSecond, equals(afterFirst), reason: 'an already-correct block must not be touched or duplicated');
        });

        test('shape 2: does not add include_directories when include/ directory does not exist on disk', () {
          // No makeIncludeDir() call — nothing to expose, so nothing should be added.
          final cmake = writeCmake(tmp, platform, multiSpecCmake());
          link();
          final content = cmake.readAsStringSync();
          expect(content, isNot(contains(r'target_include_directories(${PLUGIN_NAME}')));
        });

        test('shape 2: idempotent across repeated link runs', () {
          makeIncludeDir(tmp, platform);
          final cmake = writeCmake(tmp, platform, multiSpecCmake());
          link();
          final afterFirst = cmake.readAsStringSync();
          link();
          final afterSecond = cmake.readAsStringSync();
          expect(afterFirst, equals(afterSecond));
          expect('target_include_directories'.allMatches(afterSecond).length, equals(1));
        });

        test('shape 2: does not disturb an existing unrelated target_include_directories(\${PLUGIN_NAME} PRIVATE ...) block', () {
          makeIncludeDir(tmp, platform);
          const withPrivateBlock = '''cmake_minimum_required(VERSION 3.10)
set(PLUGIN_NAME "my_plugin_plugin")
add_subdirectory("\${CMAKE_CURRENT_SOURCE_DIR}/../src" nitro_modules)
add_library(\${PLUGIN_NAME} SHARED "my_plugin_plugin.cc")
target_include_directories(\${PLUGIN_NAME} PRIVATE "\${CMAKE_CURRENT_SOURCE_DIR}/internal")
''';
          final cmake = writeCmake(tmp, platform, withPrivateBlock);
          link();
          final content = cmake.readAsStringSync();
          // The pre-existing PRIVATE block for internal headers must survive...
          expect(content, contains(r'target_include_directories(${PLUGIN_NAME} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/internal")'));
          // ...alongside the newly-added INTERFACE block for the registrant header.
          expect(content, contains(r'target_include_directories(${PLUGIN_NAME} INTERFACE'));
        });
      });
    }
  });

  // ── per-platform impl separation (Windows-C++ AND Linux-C++ together) ──────
  //
  // Found via a real Windows/Linux CI run of nitro_type_coverage: both
  // platforms delegate to shared src/CMakeLists.txt via add_subdirectory,
  // which forced them to compile the SAME src/HybridXxx.cpp — and
  // windows/src/HybridXxx.cpp (a separate stub the generator already wrote)
  // was silently never wired into windows/CMakeLists.txt at all, so it sat
  // as dead code.
  //
  // Separation is opt-in per platform, driven by file content (see
  // hasCustomPlatformImpl) — NOT automatic just because a module targets
  // NativeImpl.cpp on both desktop platforms. Some plugins genuinely want
  // one shared file (the logic really is identical); others want Windows
  // and Linux to diverge. Both stay available: an untouched stub (or no
  // file at all) keeps sharing src/HybridXxx.cpp; writing real code into
  // windows/src/ or linux/src/ activates that platform's own file.
  group('linkWindows / linkLinux — NITRO_IMPL_SRC activates only once the platform stub has real code', () {
    const sharedSrcCmake = '''cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "my_plugin")
project(\${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("\${CMAKE_CURRENT_SOURCE_DIR}/../src" "\${CMAKE_CURRENT_BINARY_DIR}/shared")
''';

    File writeCmake(Directory dir, String platform, String content) {
      final platDir = Directory(p.join(dir.path, platform))..createSync(recursive: true);
      final f = File(p.join(platDir.path, 'CMakeLists.txt'));
      f.writeAsStringSync(content);
      return f;
    }

    File writeCustomImpl(Directory dir, String platform, String className, String body) {
      final srcDir = Directory(p.join(dir.path, platform, 'src'))..createSync(recursive: true);
      final f = File(p.join(srcDir.path, 'Hybrid$className.cpp'));
      f.writeAsStringSync(body);
      return f;
    }

    final bothCppModule = ModuleInfo(
      lib: 'my_plugin',
      module: 'MyPlugin',
      isCpp: true,
      isNativeCpp: true,
      windowsIsCpp: true,
      linuxIsCpp: true,
    );

    test('windows: no windows/src/HybridMyPlugin.cpp on disk at all — keeps sharing, NITRO_IMPL_SRC not set', () {
      // linkWindowsCppImplStubs re-scans lib/**/*.native.dart on disk — needs
      // a real spec file present to find this module as Windows-C++.
      _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(lib: "my_plugin", windows: NativeImpl.cpp, linux: NativeImpl.cpp)
abstract class MyPlugin extends HybridObject {}
''');
      final cmake = writeCmake(tmp, 'windows', sharedSrcCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [bothCppModule]);
      expect(cmake.readAsStringSync(), isNot(contains('NITRO_IMPL_SRC')));
      // linkWindowsCppImplStubs (called by linkWindows) DOES create the
      // starter stub — that's just an option sitting on disk, not activation.
      final stub = File(p.join(tmp.path, 'windows', 'src', 'HybridMyPlugin.cpp'));
      expect(stub.existsSync(), isTrue);
      expect(stub.readAsStringSync(), contains('TODO: implement all pure-virtual methods'));
    });

    test('windows: untouched auto-created stub (still has the TODO marker) — keeps sharing', () {
      writeCmake(tmp, 'windows', sharedSrcCmake);
      writeCustomImpl(tmp, 'windows', 'MyPlugin', '// TODO: implement all pure-virtual methods declared in HybridMyPlugin\n');
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [bothCppModule]);
      final content = File(p.join(tmp.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      expect(content, isNot(contains('NITRO_IMPL_SRC')));
    });

    test('windows: real code written into windows/src/HybridMyPlugin.cpp — activates NITRO_IMPL_SRC before add_subdirectory', () {
      final cmake = writeCmake(tmp, 'windows', sharedSrcCmake);
      writeCustomImpl(tmp, 'windows', 'MyPlugin', 'class HybridMyPluginImpl final : public HybridMyPlugin { /* real code */ };\n');
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [bothCppModule]);
      final content = cmake.readAsStringSync();
      expect(content, contains(r'set(NITRO_IMPL_SRC_my_plugin "${CMAKE_CURRENT_SOURCE_DIR}/src/HybridMyPlugin.cpp")'));
      final setIdx = content.indexOf('NITRO_IMPL_SRC_my_plugin');
      final subdirIdx = content.indexOf('add_subdirectory');
      expect(setIdx, lessThan(subdirIdx), reason: 'must be set before add_subdirectory so src/CMakeLists.txt sees it');
    });

    test('linux: real code written into linux/src/HybridMyPlugin.cpp — activates NITRO_IMPL_SRC, independent of Windows', () {
      final cmake = writeCmake(tmp, 'linux', sharedSrcCmake);
      writeCustomImpl(tmp, 'linux', 'MyPlugin', 'class HybridMyPluginImpl final : public HybridMyPlugin { /* real code */ };\n');
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [bothCppModule]);
      final content = cmake.readAsStringSync();
      expect(content, contains(r'set(NITRO_IMPL_SRC_my_plugin "${CMAKE_CURRENT_SOURCE_DIR}/src/HybridMyPlugin.cpp")'));
      final setIdx = content.indexOf('NITRO_IMPL_SRC_my_plugin');
      final subdirIdx = content.indexOf('add_subdirectory');
      expect(setIdx, lessThan(subdirIdx));
    });

    test('only Windows has diverged (linux/src/ untouched): Windows activates, Linux keeps sharing', () {
      writeCmake(tmp, 'windows', sharedSrcCmake);
      final linuxCmake = writeCmake(tmp, 'linux', sharedSrcCmake);
      writeCustomImpl(tmp, 'windows', 'MyPlugin', 'class HybridMyPluginImpl final : public HybridMyPlugin { /* windows-specific */ };\n');
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [bothCppModule]);
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [bothCppModule]);
      final winContent = File(p.join(tmp.path, 'windows', 'CMakeLists.txt')).readAsStringSync();
      final linuxContent = linuxCmake.readAsStringSync();
      expect(winContent, contains('NITRO_IMPL_SRC_my_plugin'), reason: 'Windows diverged — should activate its own file');
      expect(linuxContent, isNot(contains('NITRO_IMPL_SRC')), reason: 'Linux never diverged — should keep sharing src/HybridMyPlugin.cpp');
    });

    test('idempotent: running linkWindows twice does not duplicate the set() line', () {
      final cmake = writeCmake(tmp, 'windows', sharedSrcCmake);
      writeCustomImpl(tmp, 'windows', 'MyPlugin', 'class HybridMyPluginImpl final : public HybridMyPlugin { /* real code */ };\n');
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [bothCppModule]);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [bothCppModule]);
      final content = cmake.readAsStringSync();
      expect('NITRO_IMPL_SRC_my_plugin'.allMatches(content).length, equals(1));
    });

    test('linux-only C++ (windows not targeted), untouched stub: NITRO_IMPL_SRC NOT set — keeps sharing src/HybridXxx.cpp (unchanged behavior, the common case)', () {
      final linuxOnlyModule = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: false,
        linuxIsCpp: true,
      );
      final cmake = writeCmake(tmp, 'linux', sharedSrcCmake);
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [linuxOnlyModule]);
      final content = cmake.readAsStringSync();
      expect(content, isNot(contains('NITRO_IMPL_SRC')));
    });

    test('linux-only C++ (windows not targeted), real code written: activates anyway — separation is per-platform, independent of Windows', () {
      final linuxOnlyModule = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: false,
        linuxIsCpp: true,
      );
      final cmake = writeCmake(tmp, 'linux', sharedSrcCmake);
      writeCustomImpl(tmp, 'linux', 'MyPlugin', 'class HybridMyPluginImpl final : public HybridMyPlugin { /* real code */ };\n');
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [linuxOnlyModule]);
      final content = cmake.readAsStringSync();
      expect(content, contains('NITRO_IMPL_SRC_my_plugin'), reason: 'writing real code activates it regardless of what Windows targets');
    });
  });

  group('linkCppImplStubs — always creates the shared stub (the default every plugin starts from)', () {
    test('windows+linux both C++, android is not: still creates src/HybridMyPlugin.cpp (the shared starting point)', () {
      final m = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        isAndroidCpp: false,
        windowsIsCpp: true,
        linuxIsCpp: true,
      );
      linkCppImplStubs([m], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'src', 'HybridMyPlugin.cpp')).existsSync(), isTrue);
    });

    test('android is also C++: still creates the shared src/HybridMyPlugin.cpp (android needs it)', () {
      final m = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        isAndroidCpp: true,
        windowsIsCpp: true,
        linuxIsCpp: true,
      );
      linkCppImplStubs([m], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'src', 'HybridMyPlugin.cpp')).existsSync(), isTrue);
    });

    test('linux-only C++ (windows not targeted): still creates the shared src/HybridMyPlugin.cpp (unchanged behavior)', () {
      final m = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        isAndroidCpp: false,
        windowsIsCpp: false,
        linuxIsCpp: true,
      );
      linkCppImplStubs([m], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'src', 'HybridMyPlugin.cpp')).existsSync(), isTrue);
    });

    test('does not overwrite an already-diverged shared file (never touches user code)', () {
      final m = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: true,
        linuxIsCpp: true,
      );
      Directory(p.join(tmp.path, 'src')).createSync();
      final shared = File(p.join(tmp.path, 'src', 'HybridMyPlugin.cpp'))..writeAsStringSync('// shared user code');
      linkCppImplStubs([m], baseDir: tmp.path);
      expect(shared.readAsStringSync(), equals('// shared user code'));
    });
  });

  group('hasCustomPlatformImpl', () {
    test('false when the file does not exist', () {
      expect(hasCustomPlatformImpl(tmp.path, 'windows', 'MyPlugin'), isFalse);
    });

    test('false when the file exists but is still the auto-generated TODO stub', () {
      final srcDir = Directory(p.join(tmp.path, 'windows', 'src'))..createSync(recursive: true);
      File(p.join(srcDir.path, 'HybridMyPlugin.cpp')).writeAsStringSync(
        t.windowsCppStubContent(lib: 'my_plugin', className: 'MyPlugin'),
      );
      expect(hasCustomPlatformImpl(tmp.path, 'windows', 'MyPlugin'), isFalse);
    });

    test('true once the TODO marker is gone (real code written)', () {
      final srcDir = Directory(p.join(tmp.path, 'linux', 'src'))..createSync(recursive: true);
      File(p.join(srcDir.path, 'HybridMyPlugin.cpp')).writeAsStringSync(
        'class HybridMyPluginImpl final : public HybridMyPlugin { int64_t echoInt(int64_t v) override { return v; } };\n',
      );
      expect(hasCustomPlatformImpl(tmp.path, 'linux', 'MyPlugin'), isTrue);
    });
  });

  // ── requestsSeparateWindowsImpl / requestsSeparateLinuxImpl ─────────────────
  // ── PlatformTargetAnalyzer — balanced-paren annotation extraction ──────────
  //
  // Found via a real, self-inflicted repro while building the feature below:
  // the old extractor used a `[^)]+` regex to capture the @NitroModule(...)
  // body, which stops at the FIRST `)` regardless of nesting — including one
  // sitting inside an ordinary parenthesized code comment between two
  // annotation params (e.g. `// (see the docs)`). That silently truncates
  // the captured text, and with it every getter on this class — including
  // ones this test file already relied on (supportsWindows, isNativeCpp,
  // etc.), not just the new requestsSeparate* getters. Affects ANY plugin's
  // @NitroModule annotation, independent of the separation feature.
  group('PlatformTargetAnalyzer — balanced-paren extraction (not a truncating [^)]+ regex)', () {
    test('a parenthesized comment between params no longer truncates the annotation', () {
      final spec = _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(
  lib: "my_plugin",
  android: NativeImpl.kotlin,
  // A comment with a parenthetical (like this one) used to break parsing.
  windows: WindowsNativeImpl.cpp,
  linux: LinuxNativeImpl.cpp,
)
abstract class MyPlugin extends HybridObject {}
''');
      final analyzer = PlatformTargetAnalyzer.fromSpec(spec);
      expect(analyzer.supportsAndroid, isFalse, reason: 'android uses kotlin here, not cpp');
      expect(analyzer.supportsWindows, isTrue);
      expect(analyzer.supportsLinux, isTrue);
      expect(analyzer.isNativeCpp, isTrue);
      expect(analyzer.requestsSeparateWindowsImpl, isTrue);
      expect(analyzer.requestsSeparateLinuxImpl, isTrue);
    });

    test('nested balanced parens anywhere in the body are handled, not just in comments', () {
      final spec = _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(
  lib: "my_plugin",
  android: NativeImpl.kotlin,
  windows: WindowsNativeImpl.cpp, // trailing note (nested (double) parens)
  linux: LinuxNativeImpl.cpp,
)
abstract class MyPlugin extends HybridObject {}
''');
      final analyzer = PlatformTargetAnalyzer.fromSpec(spec);
      expect(analyzer.supportsLinux, isTrue);
      expect(analyzer.requestsSeparateLinuxImpl, isTrue);
    });

    test('empty when @NitroModule is entirely absent (no false match, no crash)', () {
      final spec = _writeSpec(_libDir(tmp), 'not_a_module.native.dart', '''
abstract class NotAModule {}
''');
      final analyzer = PlatformTargetAnalyzer.fromSpec(spec);
      expect(analyzer.supportsWindows, isFalse);
      expect(analyzer.isNativeCpp, isFalse);
    });

    test('malformed source (missing close paren) degrades gracefully instead of throwing', () {
      final spec = _writeSpec(_libDir(tmp), 'malformed.native.dart', '''
@NitroModule(
  lib: "my_plugin",
  windows: WindowsNativeImpl.cpp,
''');
      expect(() => PlatformTargetAnalyzer.fromSpec(spec), returnsNormally);
      final analyzer = PlatformTargetAnalyzer.fromSpec(spec);
      expect(analyzer.requestsSeparateWindowsImpl, isTrue, reason: 'text through EOF is still usable even without a closing paren');
    });
  });

  // Second, explicit way to opt into per-platform separation (alongside the
  // implicit hasCustomPlatformImpl file-content check above): spelling a
  // platform's impl with its SPECIFIC marker type (`WindowsNativeImpl.cpp` /
  // `LinuxNativeImpl.cpp`) rather than the generic `NativeImpl.cpp`
  // shorthand. Both forms resolve to the identical CppImpl singleton at the
  // Dart type level — this reads the distinction from the annotation's
  // SOURCE TEXT, which only the link-time analyzer sees.
  group('PlatformTargetAnalyzer.requestsSeparateWindowsImpl / requestsSeparateLinuxImpl', () {
    test('false for the generic NativeImpl.cpp shorthand on both platforms', () {
      final spec = _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(lib: "my_plugin", windows: NativeImpl.cpp, linux: NativeImpl.cpp)
abstract class MyPlugin extends HybridObject {}
''');
      final analyzer = PlatformTargetAnalyzer.fromSpec(spec);
      expect(analyzer.requestsSeparateWindowsImpl, isFalse);
      expect(analyzer.requestsSeparateLinuxImpl, isFalse);
    });

    test('true for the specific WindowsNativeImpl.cpp / LinuxNativeImpl.cpp markers', () {
      final spec = _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(lib: "my_plugin", windows: WindowsNativeImpl.cpp, linux: LinuxNativeImpl.cpp)
abstract class MyPlugin extends HybridObject {}
''');
      final analyzer = PlatformTargetAnalyzer.fromSpec(spec);
      expect(analyzer.requestsSeparateWindowsImpl, isTrue);
      expect(analyzer.requestsSeparateLinuxImpl, isTrue);
    });

    test('independent per platform: only Windows uses the specific marker', () {
      final spec = _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(lib: "my_plugin", windows: WindowsNativeImpl.cpp, linux: NativeImpl.cpp)
abstract class MyPlugin extends HybridObject {}
''');
      final analyzer = PlatformTargetAnalyzer.fromSpec(spec);
      expect(analyzer.requestsSeparateWindowsImpl, isTrue);
      expect(analyzer.requestsSeparateLinuxImpl, isFalse);
    });

    // supportsWindows/supportsLinux (targets-cpp-at-all) must stay true
    // regardless of which marker spelling was used — requestsSeparate* is an
    // ADDITIONAL signal, not a replacement for the broader "is this cpp" check.
    test('supportsWindows/supportsLinux remain true for the specific markers too', () {
      final spec = _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(lib: "my_plugin", windows: WindowsNativeImpl.cpp, linux: LinuxNativeImpl.cpp)
abstract class MyPlugin extends HybridObject {}
''');
      final analyzer = PlatformTargetAnalyzer.fromSpec(spec);
      expect(analyzer.supportsWindows, isTrue);
      expect(analyzer.supportsLinux, isTrue);
    });
  });

  group('linkWindows / linkLinux — explicit WindowsNativeImpl.cpp/LinuxNativeImpl.cpp activates immediately', () {
    const sharedSrcCmake = '''cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "my_plugin")
project(\${PROJECT_NAME} LANGUAGES CXX)

add_subdirectory("\${CMAKE_CURRENT_SOURCE_DIR}/../src" "\${CMAKE_CURRENT_BINARY_DIR}/shared")
''';

    File writeCmake(Directory dir, String platform, String content) {
      final platDir = Directory(p.join(dir.path, platform))..createSync(recursive: true);
      final f = File(p.join(platDir.path, 'CMakeLists.txt'));
      f.writeAsStringSync(content);
      return f;
    }

    test('windows: explicit marker activates NITRO_IMPL_SRC even with an untouched shared file (no prior divergence needed)', () {
      final explicitModule = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: true,
        linuxIsCpp: true,
        windowsRequestsSeparateImpl: true,
      );
      final cmake = writeCmake(tmp, 'windows', sharedSrcCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [explicitModule]);
      expect(cmake.readAsStringSync(), contains('NITRO_IMPL_SRC_my_plugin'));
    });

    test('linux: explicit marker activates independently of Windows', () {
      final explicitModule = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: false,
        linuxIsCpp: true,
        linuxRequestsSeparateImpl: true,
      );
      final cmake = writeCmake(tmp, 'linux', sharedSrcCmake);
      linkLinux('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [explicitModule]);
      expect(cmake.readAsStringSync(), contains('NITRO_IMPL_SRC_my_plugin'));
    });

    test('windows: without the explicit marker AND without prior divergence, stays shared (both opt-ins absent)', () {
      final genericModule = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: true,
        linuxIsCpp: true,
      );
      final cmake = writeCmake(tmp, 'windows', sharedSrcCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [genericModule]);
      expect(cmake.readAsStringSync(), isNot(contains('NITRO_IMPL_SRC')));
    });

    test('migrates real shared content into the new windows/src/ file instead of the empty stub', () {
      // linkWindowsCppImplStubs re-scans lib/**/*.native.dart on disk — needs
      // a real spec file present to find this module as Windows-C++.
      _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(lib: "my_plugin", windows: WindowsNativeImpl.cpp, linux: LinuxNativeImpl.cpp)
abstract class MyPlugin extends HybridObject {}
''');
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'HybridMyPlugin.cpp')).writeAsStringSync(
        '// Hybrid impl\n#include "../lib/src/generated/cpp/my_plugin.native.g.h"\nclass HybridMyPluginImpl final : public HybridMyPlugin { int64_t echoInt(int64_t v) override { return v * 2; } };\n',
      );
      final explicitModule = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: true,
        linuxIsCpp: true,
        windowsRequestsSeparateImpl: true,
      );
      writeCmake(tmp, 'windows', sharedSrcCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [explicitModule]);
      final migrated = File(p.join(tmp.path, 'windows', 'src', 'HybridMyPlugin.cpp')).readAsStringSync();
      expect(migrated, contains('return v * 2;'), reason: 'real shared logic must carry over, not an empty stub');
      expect(migrated, contains('#include "../../lib/src/generated/cpp/my_plugin.native.g.h"'), reason: 'include path must gain one more ../ level');
      expect(migrated, isNot(contains('TODO: implement all pure-virtual methods')));
    });

    test('does NOT migrate when the shared file is itself still just the auto-generated stub', () {
      _writeSpec(_libDir(tmp), 'my_plugin.native.dart', '''
@NitroModule(lib: "my_plugin", windows: WindowsNativeImpl.cpp, linux: LinuxNativeImpl.cpp)
abstract class MyPlugin extends HybridObject {}
''');
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'HybridMyPlugin.cpp')).writeAsStringSync(
        t.cppImplStubContent(lib: 'my_plugin', className: 'MyPlugin', isNativeCpp: true, iosIsCpp: false, macosIsCpp: false),
      );
      final explicitModule = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: true,
        linuxIsCpp: true,
        windowsRequestsSeparateImpl: true,
      );
      writeCmake(tmp, 'windows', sharedSrcCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [explicitModule]);
      final content = File(p.join(tmp.path, 'windows', 'src', 'HybridMyPlugin.cpp')).readAsStringSync();
      expect(content, contains('TODO: implement all pure-virtual methods'));
    });

    test('never overwrites an already-existing windows/src/ file, migrated or not', () {
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'HybridMyPlugin.cpp')).writeAsStringSync('class HybridMyPluginImpl final : public HybridMyPlugin {};\n');
      final winSrcDir = Directory(p.join(tmp.path, 'windows', 'src'))..createSync(recursive: true);
      File(p.join(winSrcDir.path, 'HybridMyPlugin.cpp')).writeAsStringSync('// pre-existing windows-specific user code, must survive\n');
      final explicitModule = ModuleInfo(
        lib: 'my_plugin',
        module: 'MyPlugin',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: true,
        linuxIsCpp: true,
        windowsRequestsSeparateImpl: true,
      );
      writeCmake(tmp, 'windows', sharedSrcCmake);
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path, moduleInfos: [explicitModule]);
      final content = File(p.join(winSrcDir.path, 'HybridMyPlugin.cpp')).readAsStringSync();
      expect(content, equals('// pre-existing windows-specific user code, must survive\n'));
    });
  });

  // ── generateCMake cross-platform ────────────────────────────────────────────

  group('generateCMake — cross-platform link libraries', () {
    test('generated CMakeLists.txt contains if(ANDROID) block', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      generateCMake('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(content, contains('if(ANDROID)'));
      expect(content, contains('target_link_libraries(my_plugin PRIVATE android log)'));
    });

    test('generated CMakeLists.txt contains elseif(WIN32) block', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      generateCMake('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(content, contains('elseif(WIN32)'));
      expect(content, contains('target_link_libraries(my_plugin PRIVATE dbghelp)'));
    });

    test('generated CMakeLists.txt contains elseif(UNIX AND NOT APPLE) block', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      generateCMake('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      expect(content, contains('elseif(UNIX AND NOT APPLE)'));
      expect(content, contains('target_link_libraries(my_plugin PRIVATE dl pthread)'));
    });

    test('conditional blocks appear in correct order (ANDROID, WIN32, UNIX, endif)', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      generateCMake('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'src', 'CMakeLists.txt')).readAsStringSync();
      final androidIdx = content.indexOf('if(ANDROID)');
      final win32Idx = content.indexOf('elseif(WIN32)');
      final unixIdx = content.indexOf('elseif(UNIX AND NOT APPLE)');
      final endifIdx = content.indexOf('endif()');
      expect(androidIdx, lessThan(win32Idx));
      expect(win32Idx, lessThan(unixIdx));
      expect(unixIdx, lessThan(endifIdx));
    });
  });

  // ── linkCppImplStubs — cross-platform constructor ────────────────────────────

  group('linkCppImplStubs — cross-platform constructor', () {
    test('stub contains #if defined(_WIN32) guard', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true)], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'src', 'HybridMath.cpp')).readAsStringSync();
      expect(content, contains('#if defined(_WIN32)'));
    });

    test('stub contains static object registration on Windows path', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true)], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'src', 'HybridMath.cpp')).readAsStringSync();
      expect(content, contains('struct _AutoRegister'));
      expect(content, contains('_AutoRegister()'));
    });

    test('stub contains __attribute__((constructor)) on non-Windows path', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true)], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'src', 'HybridMath.cpp')).readAsStringSync();
      expect(content, contains('__attribute__((constructor))'));
      expect(content, contains('#else'));
      expect(content, contains('#endif'));
    });

    test('stub register call appears in both Windows and non-Windows blocks', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true)], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'src', 'HybridMath.cpp')).readAsStringSync();
      expect('math_register_impl'.allMatches(content).length, greaterThanOrEqualTo(2));
    });
  });

  // ── isAppleCppModule ──────────────────────────────────────────────────────────

  group('isAppleCppModule', () {
    test('returns true for ios: AppleNativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'cam.native.dart', '''
@NitroModule(lib: "cam", ios: AppleNativeImpl.cpp)
abstract class Cam extends HybridObject {}
''');
      expect(isAppleCppModule(spec), isTrue);
    });

    test('returns true for macos: AppleNativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'cam.native.dart', '''
@NitroModule(lib: "cam", macos: AppleNativeImpl.cpp)
abstract class Cam extends HybridObject {}
''');
      expect(isAppleCppModule(spec), isTrue);
    });

    test('returns true for legacy ios: NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'cam.native.dart', '''
@NitroModule(lib: "cam", ios: NativeImpl.cpp)
abstract class Cam extends HybridObject {}
''');
      expect(isAppleCppModule(spec), isTrue);
    });

    test('returns false for android-only: AndroidNativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'cam.native.dart', '''
@NitroModule(lib: "cam", android: AndroidNativeImpl.cpp)
abstract class Cam extends HybridObject {}
''');
      expect(isAppleCppModule(spec), isFalse);
    });

    test('returns false for windows-only: WindowsNativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'cam.native.dart', '''
@NitroModule(lib: "cam", windows: WindowsNativeImpl.cpp)
abstract class Cam extends HybridObject {}
''');
      expect(isAppleCppModule(spec), isFalse, reason: 'Windows-only C++ must NOT produce an Apple forwarder in ios/Classes/');
    });

    test('returns false for ios: AppleNativeImpl.swift (Swift, not C++)', () {
      final spec = _writeSpec(_libDir(tmp), 'cam.native.dart', '''
@NitroModule(lib: "cam", ios: NativeImpl.swift)
abstract class Cam extends HybridObject {}
''');
      expect(isAppleCppModule(spec), isFalse);
    });

    test('returns true for multi-line annotation with ios: AppleNativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'cam.native.dart', '''
@NitroModule(
  lib: "cam",
  ios: AppleNativeImpl.cpp,
  android: AndroidNativeImpl.cpp,
)
abstract class Cam extends HybridObject {}
''');
      expect(isAppleCppModule(spec), isTrue);
    });
  });

  // ── isNativeCppModule ─────────────────────────────────────────────────────────

  group('isNativeCppModule', () {
    test('returns true for android: AndroidNativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'eng.native.dart', '''
@NitroModule(lib: "eng", android: AndroidNativeImpl.cpp)
abstract class Eng extends HybridObject {}
''');
      expect(isNativeCppModule(spec), isTrue);
    });

    test('returns true for linux: LinuxNativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'eng.native.dart', '''
@NitroModule(lib: "eng", linux: LinuxNativeImpl.cpp)
abstract class Eng extends HybridObject {}
''');
      expect(isNativeCppModule(spec), isTrue);
    });

    test('returns true for legacy android: NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'eng.native.dart', '''
@NitroModule(lib: "eng", android: NativeImpl.cpp)
abstract class Eng extends HybridObject {}
''');
      expect(isNativeCppModule(spec), isTrue);
    });

    test('returns false for ios-only: AppleNativeImpl.cpp (not Android/Linux)', () {
      final spec = _writeSpec(_libDir(tmp), 'eng.native.dart', '''
@NitroModule(lib: "eng", ios: AppleNativeImpl.cpp)
abstract class Eng extends HybridObject {}
''');
      expect(isNativeCppModule(spec), isFalse, reason: 'Apple-only C++ does not belong in src/CMakeLists.txt');
    });

    test('returns false for windows-only: WindowsNativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'eng.native.dart', '''
@NitroModule(lib: "eng", windows: WindowsNativeImpl.cpp)
abstract class Eng extends HybridObject {}
''');
      expect(isNativeCppModule(spec), isFalse);
    });
  });

  // ── purgeStaleCppSwiftRegistrations ──────────────────────────────────────────

  group('purgeStaleCppSwiftRegistrations', () {
    File writeIosPlugin(Directory dir, String content) {
      final d = Directory(p.join(dir.path, 'ios', 'Classes'))..createSync(recursive: true);
      final f = File(p.join(d.path, 'MyPlugin.swift'));
      f.writeAsStringSync(content);
      return f;
    }

    test('removes stale XxxRegistry.register() call for a cpp module', () {
      final plugin = writeIosPlugin(tmp, '''
public static func register(with registrar: FlutterPluginRegistrar) {
    BenchmarkRegistry.register(BenchmarkImpl())
    BenchmarkCppRegistry.register(BenchmarkCppModuleImpl())
}
''');
      purgeStaleCppSwiftRegistrations(
        [const ModuleInfo(lib: 'benchmark_cpp', module: 'BenchmarkCpp', isCpp: true)],
        platform: 'ios',
        baseDir: tmp.path,
      );
      final content = plugin.readAsStringSync();
      expect(content, isNot(contains('BenchmarkCppRegistry.register')));
      expect(content, contains('BenchmarkRegistry.register')); // non-cpp untouched
    });

    test('no-op when stale call is not present', () {
      const original = '''
public static func register(with registrar: FlutterPluginRegistrar) {
    BenchmarkRegistry.register(BenchmarkImpl())
}
''';
      final plugin = writeIosPlugin(tmp, original);
      purgeStaleCppSwiftRegistrations(
        [const ModuleInfo(lib: 'benchmark_cpp', module: 'BenchmarkCpp', isCpp: true)],
        platform: 'ios',
        baseDir: tmp.path,
      );
      expect(plugin.readAsStringSync(), equals(original));
    });

    test('no-op when cppModules list is empty', () {
      const original = 'public static func register(with r: FlutterPluginRegistrar) {}';
      final plugin = writeIosPlugin(tmp, original);
      purgeStaleCppSwiftRegistrations([], platform: 'ios', baseDir: tmp.path);
      expect(plugin.readAsStringSync(), equals(original));
    });

    test('handles impl variant without ModuleImpl suffix', () {
      final plugin = writeIosPlugin(tmp, '''
public static func register(with registrar: FlutterPluginRegistrar) {
    FooRegistry.register(FooImpl())
}
''');
      purgeStaleCppSwiftRegistrations(
        [const ModuleInfo(lib: 'foo', module: 'Foo', isCpp: true)],
        platform: 'ios',
        baseDir: tmp.path,
      );
      expect(plugin.readAsStringSync(), isNot(contains('FooRegistry.register')));
    });

    test('removes stale call with nested parentheses perfectly', () {
      final plugin = writeIosPlugin(tmp, '''
public static func register(with registrar: FlutterPluginRegistrar) {
    BenchmarkRegistry.register(BenchmarkImpl())
    BenchmarkCppRegistry.register(BenchmarkCppModuleImpl())
}
''');
      purgeStaleCppSwiftRegistrations(
        [const ModuleInfo(lib: 'benchmark_cpp', module: 'BenchmarkCpp', isCpp: true)],
        platform: 'ios',
        baseDir: tmp.path,
      );
      final content = plugin.readAsStringSync();
      // Should not leave a stray ')'
      expect(
        content,
        equals('''
public static func register(with registrar: FlutterPluginRegistrar) {
    BenchmarkRegistry.register(BenchmarkImpl())
}
'''),
      );
    });
  });

  // ── purgeStaleCppKotlinRegistrations ─────────────────────────────────────────

  group('purgeStaleCppKotlinRegistrations', () {
    File writeKotlinPlugin2(Directory dir, String content) {
      final d = Directory(p.join(dir.path, 'android', 'src', 'main', 'kotlin', 'dev', 'test'))..createSync(recursive: true);
      final f = File(p.join(d.path, 'TestPlugin.kt'));
      f.writeAsStringSync(content);
      return f;
    }

    test('removes stale XxxJniBridge.register() call for a cpp module', () {
      final plugin = writeKotlinPlugin2(tmp, '''
override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    BenchmarkJniBridge.register(BenchmarkImpl(binding.applicationContext))
    BenchmarkCppJniBridge.register(BenchmarkCppImpl())
}
''');
      purgeStaleCppKotlinRegistrations(
        [const ModuleInfo(lib: 'benchmark_cpp', module: 'BenchmarkCpp', isCpp: true)],
        baseDir: tmp.path,
      );
      final content = plugin.readAsStringSync();
      expect(content, isNot(contains('BenchmarkCppJniBridge.register')));
      expect(content, contains('BenchmarkJniBridge.register')); // non-cpp untouched
    });

    test('also removes stale import for the cpp module', () {
      final plugin = writeKotlinPlugin2(tmp, '''
package dev.test
import nitro.benchmark_cpp_module.BenchmarkCppJniBridge
import nitro.benchmark_module.BenchmarkJniBridge
override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    BenchmarkCppJniBridge.register(BenchmarkCppImpl())
}
''');
      purgeStaleCppKotlinRegistrations(
        [const ModuleInfo(lib: 'benchmark_cpp', module: 'BenchmarkCpp', isCpp: true)],
        baseDir: tmp.path,
      );
      final content = plugin.readAsStringSync();
      expect(content, isNot(contains('BenchmarkCppJniBridge')));
      expect(content, contains('BenchmarkJniBridge')); // non-cpp import untouched
    });

    test('no-op when cppModules list is empty', () {
      const original = 'class TestPlugin {}';
      final plugin = writeKotlinPlugin2(tmp, original);
      purgeStaleCppKotlinRegistrations([], baseDir: tmp.path);
      expect(plugin.readAsStringSync(), equals(original));
    });

    test('removes stale call with nested parentheses perfectly', () {
      final plugin = writeKotlinPlugin2(tmp, '''
override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    BenchmarkJniBridge.register(BenchmarkImpl(binding.applicationContext))
    BenchmarkCppJniBridge.register(BenchmarkCppImpl())
}
''');
      purgeStaleCppKotlinRegistrations(
        [const ModuleInfo(lib: 'benchmark_cpp', module: 'BenchmarkCpp', isCpp: true)],
        baseDir: tmp.path,
      );
      final content = plugin.readAsStringSync();
      // Should not leave a stray ')'
      expect(
        content,
        equals('''
override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    BenchmarkJniBridge.register(BenchmarkImpl(binding.applicationContext))
}
'''),
      );
    });
  });

  // ── linkKotlinPlugin — import + register injection ────────────────────────────

  group('linkKotlinPlugin', () {
    Directory ktDir(Directory base) => Directory(p.join(base.path, 'android', 'src', 'main', 'kotlin', 'dev', 'test'))..createSync(recursive: true);

    File writePlugin(Directory base, String content) {
      final f = File(p.join(ktDir(base).path, 'TestPlugin.kt'));
      f.writeAsStringSync(content);
      return f;
    }

    test('injects import and register() call for a no-arg impl', () {
      final plugin = writePlugin(tmp, '''
package dev.test
import io.flutter.embedding.engine.plugins.FlutterPlugin
class TestPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
  }
}
''');

      linkKotlinPlugin('my_plugin', [
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect(content, contains('import nitro.math_module.MathJniBridge'));
      // registerFactory is the JniBridge's only registration API since the
      // multi-instance registry landed.
      expect(content, contains('MathJniBridge.registerFactory({ MathImpl() }, binding.applicationContext)'));
    });

    test('hand-added user imports and code survive repeated link runs (issue #16)', () {
      // The nitro_webgpu case: the plugin calls into an all-cpp module's
      // JniBridge (onActivityAttached), needing a hand-added import that no
      // template produces. It must survive every regen.
      final plugin = writePlugin(tmp, '''
package dev.test
import io.flutter.embedding.engine.plugins.FlutterPlugin
import nitro.webgpu_module.NitroWebgpuJniBridge
import android.view.Surface
class TestPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    NitroWebgpuJniBridge.onActivityAttached(binding)
  }
}
''');

      for (var run = 0; run < 3; run++) {
        linkKotlinPlugin('my_plugin', [
          {'module': 'Math', 'lib': 'math'},
        ], baseDir: tmp.path);
      }

      final content = plugin.readAsStringSync();
      expect(content, contains('import nitro.webgpu_module.NitroWebgpuJniBridge'));
      expect(content, contains('import android.view.Surface'));
      expect(content, contains('NitroWebgpuJniBridge.onActivityAttached(binding)'));
      // And the managed content was still added exactly once.
      expect('import nitro.math_module.MathJniBridge'.allMatches(content).length, 1);
    });

    test('injects register() with binding.applicationContext when impl takes Context', () {
      // Create a MathImpl.kt file whose constructor takes Context.
      final ktImplDir = ktDir(tmp);
      File(p.join(ktImplDir.path, 'MathImpl.kt')).writeAsStringSync('''
package dev.test
import android.content.Context
class MathImpl(private val context: Context) : HybridMathSpec {}
''');

      writePlugin(tmp, '''
package dev.test
import io.flutter.embedding.engine.plugins.FlutterPlugin
class TestPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
  }
}
''');

      linkKotlinPlugin('my_plugin', [
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);

      final plugin = File(p.join(ktImplDir.path, 'TestPlugin.kt'));
      final content = plugin.readAsStringSync();
      expect(content, contains('MathJniBridge.registerFactory({ MathImpl(binding.applicationContext) }, binding.applicationContext)'));
    });

    test('adds missing import when register() call already exists', () {
      final plugin = writePlugin(tmp, '''
package dev.test
import io.flutter.embedding.engine.plugins.FlutterPlugin
class TestPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    MathJniBridge.register(MathImpl())
  }
}
''');

      linkKotlinPlugin('my_plugin', [
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect(content, contains('import nitro.math_module.MathJniBridge'));
    });

    test('does not duplicate import on second run (idempotent)', () {
      final plugin = writePlugin(tmp, '''
package dev.test
import nitro.math_module.MathJniBridge
class TestPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    MathJniBridge.register(MathImpl())
  }
}
''');

      linkKotlinPlugin('my_plugin', [
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect('import nitro.math_module.MathJniBridge'.allMatches(content).length, equals(1));
      expect('MathJniBridge.register'.allMatches(content).length, equals(1));
    });

    test('appends after last existing JniBridge.register() when multiple modules', () {
      final plugin = writePlugin(tmp, '''
package dev.test
import nitro.foo_module.FooJniBridge
class TestPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    FooJniBridge.register(FooImpl())
  }
}
''');

      linkKotlinPlugin('my_plugin', [
        {'module': 'Foo', 'lib': 'foo'},
        {'module': 'Bar', 'lib': 'bar'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect(content, contains('FooJniBridge.register'));
      expect(content, contains('BarJniBridge.register'));
      expect(content, contains('import nitro.bar_module.BarJniBridge'));
    });

    test('inserts import after last existing import line', () {
      final plugin = writePlugin(tmp, '''
package dev.test
import io.flutter.embedding.engine.plugins.FlutterPlugin
class TestPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
  }
}
''');

      linkKotlinPlugin('my_plugin', [
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      // import must appear after FlutterPlugin import
      final flutterIdx = content.indexOf('import io.flutter');
      final nitroIdx = content.indexOf('import nitro.math_module.MathJniBridge');
      expect(nitroIdx, greaterThan(flutterIdx));
    });

    test('no-op when no Plugin.kt file found in android/', () {
      expect(
        () => linkKotlinPlugin('my_plugin', [
          {'module': 'Math', 'lib': 'math'},
        ], baseDir: tmp.path),
        returnsNormally,
      );
    });
  });

  // ── linkAndroid — consumerProguardFiles wiring ──────────────────────────
  //
  // Generating a correct consumer-rules.pro is pointless if it's never
  // actually applied — Flutter's plugin scaffold doesn't always wire
  // `consumerProguardFiles "consumer-rules.pro"` into defaultConfig (found
  // missing entirely on a real plugin this was built for).
  group('linkAndroid — consumerProguardFiles wiring', () {
    File writeBuildGradle(String content) {
      Directory(p.join(tmp.path, 'android')).createSync(recursive: true);
      final f = File(p.join(tmp.path, 'android', 'build.gradle'));
      f.writeAsStringSync(content);
      return f;
    }

    const minimalGroovy = '''
android {
    namespace "dev.example.math"
    defaultConfig {
        minSdk = 24
    }
}
''';

    test('adds consumerProguardFiles into an existing defaultConfig block', () {
      final gradle = writeBuildGradle(minimalGroovy);
      linkAndroid('math', ['math'], baseDir: tmp.path);
      expect(gradle.readAsStringSync(), contains('consumerProguardFiles "consumer-rules.pro"'));
    });

    // Found on a real plugin: `defaultConfig { minSdk = 24 }` written on a
    // SINGLE line is valid, common Gradle syntax — a plain leading-newline
    // insertion right after `defaultConfig {` spliced onto the rest of that
    // same line, producing invalid Groovy:
    // `consumerProguardFiles "consumer-rules.pro" minSdk = 24 }`.
    test('inserts a clean, separate statement into a single-line defaultConfig block', () {
      final gradle = writeBuildGradle('''
android {
    namespace "dev.example.math"
    defaultConfig { minSdk = 24 }
}
''');
      linkAndroid('math', ['math'], baseDir: tmp.path);
      final content = gradle.readAsStringSync();
      expect(content, isNot(contains('consumerProguardFiles "consumer-rules.pro" minSdk')), reason: 'must not splice onto the rest of the original line');
      expect(content, contains('consumerProguardFiles "consumer-rules.pro"'));
      expect(content, contains('minSdk = 24'));
    });

    test('creates defaultConfig if absent, inside android {}', () {
      final gradle = writeBuildGradle('''
android {
    namespace "dev.example.math"
}
''');
      linkAndroid('math', ['math'], baseDir: tmp.path);
      final content = gradle.readAsStringSync();
      expect(content, contains('defaultConfig'));
      expect(content, contains('consumerProguardFiles "consumer-rules.pro"'));
    });

    test('does not duplicate an already-wired consumerProguardFiles', () {
      final gradle = writeBuildGradle('''
android {
    defaultConfig {
        minSdk = 24
        consumerProguardFiles "consumer-rules.pro"
    }
}
''');
      linkAndroid('math', ['math'], baseDir: tmp.path);
      expect('consumerProguardFiles'.allMatches(gradle.readAsStringSync()).length, equals(1));
    });

    test('uses Kotlin DSL call syntax for build.gradle.kts', () {
      Directory(p.join(tmp.path, 'android')).createSync(recursive: true);
      final gradle = File(p.join(tmp.path, 'android', 'build.gradle.kts'));
      gradle.writeAsStringSync('''
android {
    namespace = "dev.example.math"
    defaultConfig {
        minSdk = 24
    }
}
''');
      linkAndroid('math', ['math'], baseDir: tmp.path);
      expect(gradle.readAsStringSync(), contains('consumerProguardFiles("consumer-rules.pro")'));
    });

    test('creates an empty consumer-rules.pro placeholder so the reference is never dangling', () {
      writeBuildGradle(minimalGroovy);
      linkAndroid('math', ['math'], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'android', 'consumer-rules.pro')).existsSync(), isTrue);
    });

    test('does not overwrite an already-populated consumer-rules.pro with an empty placeholder', () {
      writeBuildGradle(minimalGroovy);
      Directory(p.join(tmp.path, 'android')).createSync(recursive: true);
      File(p.join(tmp.path, 'android', 'consumer-rules.pro')).writeAsStringSync('-keep class existing.** { *; }');
      linkAndroid('math', ['math'], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync(), contains('existing'));
    });

    test('skipped entirely when every module is android:cpp (no Kotlin bridge to protect)', () {
      final gradle = writeBuildGradle(minimalGroovy);
      linkAndroid(
        'math',
        ['math'],
        baseDir: tmp.path,
        moduleInfos: [ModuleInfo(lib: 'math', module: 'Math', isCpp: true, isNativeCpp: true, isAndroidCpp: true)],
      );
      expect(gradle.readAsStringSync(), isNot(contains('consumerProguardFiles')));
    });
  });

  // ── linkAndroidConsumerRules ─────────────────────────────────────────────
  //
  // Found via a real R8 full-mode crash in a Nitro Android plugin: a plain
  // `-keep class X { *; }` protects a JNI-called method from removal/
  // renaming but NOT the parameter/return types referenced in its
  // signature — R8 full mode can still rename or merge those, producing a
  // VerifyError ("... Long (Low Half)") at the exact JNI call site.
  // includedescriptorclasses is ProGuard's own documented fix for native/
  // JNI-called methods, not a nitro-specific workaround.
  group('linkAndroidConsumerRules', () {
    void scaffoldAndroid(String namespace) {
      Directory(p.join(tmp.path, 'android')).createSync(recursive: true);
      File(p.join(tmp.path, 'android', 'build.gradle')).writeAsStringSync('''
android {
    namespace "$namespace"
}
''');
    }

    test('no-op when android/ does not exist', () {
      expect(
        () => linkAndroidConsumerRules([
          {'module': 'Math', 'lib': 'math'},
        ], baseDir: tmp.path),
        returnsNormally,
      );
      expect(File(p.join(tmp.path, 'android', 'consumer-rules.pro')).existsSync(), isFalse);
    });

    test('no-op when kotlinModules is empty (e.g. android is pure C++)', () {
      scaffoldAndroid('dev.example.math');
      linkAndroidConsumerRules([], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'android', 'consumer-rules.pro')).existsSync(), isFalse);
    });

    test('creates consumer-rules.pro with the bridge package, namespace, and native-methods rules', () {
      scaffoldAndroid('dev.example.math');
      linkAndroidConsumerRules([
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync();
      expect(content, contains('-keep,includedescriptorclasses class nitro.math_module.** {'));
      expect(content, contains('-keep,includedescriptorclasses class dev.example.math.** {'));
      expect(content, contains('-keepclasseswithmembernames,includedescriptorclasses class * {'));
      expect(content, contains('native <methods>;'));
    });

    test('lib names with hyphens become underscores in the bridge package (matches the Kotlin generator)', () {
      scaffoldAndroid('dev.example.my_plugin');
      linkAndroidConsumerRules([
        {'module': 'MyPlugin', 'lib': 'my-plugin'},
      ], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync();
      expect(content, contains('nitro.my_plugin_module.**'));
    });

    test('multiple Kotlin modules each get their own bridge-package keep rule', () {
      scaffoldAndroid('dev.example.multi');
      linkAndroidConsumerRules([
        {'module': 'Math', 'lib': 'math'},
        {'module': 'Crypto', 'lib': 'crypto'},
      ], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync();
      expect(content, contains('nitro.math_module.**'));
      expect(content, contains('nitro.crypto_module.**'));
    });

    test('preserves a plugin author\'s pre-existing unrelated rules', () {
      scaffoldAndroid('dev.example.math');
      Directory(p.join(tmp.path, 'android')).createSync(recursive: true);
      File(p.join(tmp.path, 'android', 'consumer-rules.pro')).writeAsStringSync('''
# Keep rules for some unrelated third-party dependency.
-keep class com.example.thirdparty.** { *; }
''');
      linkAndroidConsumerRules([
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync();
      expect(content, contains('-keep class com.example.thirdparty.** { *; }'));
      expect(content, contains('nitro.math_module.**'));
    });

    test('idempotent: running twice does not duplicate the block', () {
      scaffoldAndroid('dev.example.math');
      linkAndroidConsumerRules([
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);
      linkAndroidConsumerRules([
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync();
      expect('nitro.math_module.**'.allMatches(content).length, equals(1));
    });

    test('re-running with an additional module updates the block in place', () {
      scaffoldAndroid('dev.example.math');
      linkAndroidConsumerRules([
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);
      linkAndroidConsumerRules([
        {'module': 'Math', 'lib': 'math'},
        {'module': 'Crypto', 'lib': 'crypto'},
      ], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync();
      expect(content, contains('nitro.math_module.**'));
      expect(content, contains('nitro.crypto_module.**'));
      // The marker itself must still appear exactly once (replaced, not duplicated).
      expect('BEGIN nitrogen-generated'.allMatches(content).length, equals(1));
    });

    test('works with build.gradle.kts (Kotlin DSL) namespace syntax', () {
      Directory(p.join(tmp.path, 'android')).createSync(recursive: true);
      File(p.join(tmp.path, 'android', 'build.gradle.kts')).writeAsStringSync('''
android {
    namespace = "dev.example.math"
}
''');
      linkAndroidConsumerRules([
        {'module': 'Math', 'lib': 'math'},
      ], baseDir: tmp.path);
      final content = File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync();
      expect(content, contains('dev.example.math.**'));
    });

    test('does not emit a namespace rule when namespace cannot be determined (no crash)', () {
      Directory(p.join(tmp.path, 'android')).createSync(recursive: true);
      File(p.join(tmp.path, 'android', 'build.gradle')).writeAsStringSync('// no namespace here\n');
      expect(
        () => linkAndroidConsumerRules([
          {'module': 'Math', 'lib': 'math'},
        ], baseDir: tmp.path),
        returnsNormally,
      );
      final content = File(p.join(tmp.path, 'android', 'consumer-rules.pro')).readAsStringSync();
      expect(content, contains('nitro.math_module.**'));
    });
  });

  // ── _syncCppModuleSourcesToSpm — non-Apple-cpp stale cleanup ─────────────────

  group('_syncCppModuleSourcesToSpm — stale forwarder cleanup for non-Apple-cpp', () {
    void scaffoldSpmFull(String pluginName) {
      Directory(p.join(tmp.path, 'ios', 'Classes')).createSync(recursive: true);
      File(p.join(tmp.path, 'ios', '$pluginName.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = '$pluginName'
  s.pod_target_xcconfig = {}
end
''');
      final pascal = pluginName.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');
      Directory(p.join(tmp.path, 'ios', 'Sources', '${pascal}Cpp')).createSync(recursive: true);
      File(p.join(tmp.path, 'ios', 'Package.swift')).writeAsStringSync('// existing');
    }

    test('removes stale Hybrid*.cpp forwarder for Windows-only cpp module', () {
      scaffoldSpmFull('my_plugin');

      // Plant a stale forwarder for a Windows-only module.
      final stale = File(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'HybridBenchmark.cpp'))..writeAsStringSync('// stale');
      // Plant bridge files for the windows-only module.
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'benchmark.bridge.g.cpp')).writeAsStringSync('// bridge');
      File(p.join(genCpp.path, 'benchmark.bridge.g.h')).writeAsStringSync('// header');
      Directory(p.join(tmp.path, 'src')).createSync();
      File(p.join(tmp.path, 'src', 'HybridBenchmark.cpp')).writeAsStringSync('// impl');

      // Write a spec marking benchmark as Windows-only cpp — NOT Apple.
      final specDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(specDir.path, 'benchmark.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'benchmark', windows: WindowsNativeImpl.cpp)\n"
        'abstract class Benchmark extends HybridObject {}\n',
      );

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'benchmark'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'benchmark', module: 'Benchmark', isCpp: true)],
      );

      expect(stale.existsSync(), isFalse, reason: 'Windows-only forwarder must be removed from ios/Sources — it has no iOS implementation');
    });

    test('keeps Hybrid*.cpp forwarder for Apple cpp module — now in its own target (issue #15)', () {
      scaffoldSpmFull('my_plugin');

      // Plant forwarder in the OLD location (plugin-level target).
      final oldForwarder = File(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'HybridMyCppMod.cpp'))..writeAsStringSync('// forwarder');
      // Plant bridge files.
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'my_cpp_mod.bridge.g.cpp')).writeAsStringSync('// bridge');
      File(p.join(genCpp.path, 'my_cpp_mod.bridge.g.h')).writeAsStringSync('// header');
      Directory(p.join(tmp.path, 'src')).createSync();
      File(p.join(tmp.path, 'src', 'HybridMyCppMod.cpp')).writeAsStringSync('// impl');

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'MyCppModCpp', 'HybridMyCppMod.cpp')).existsSync(),
        isTrue,
        reason: 'Apple cpp forwarder lives in the module target now',
      );
      expect(oldForwarder.existsSync(), isFalse, reason: 'plugin-level copy removed by the issue-#15 repair pass');
    });

    // ── Multi-spec mixed-platform: bridge mm forwarder for Swift-on-Apple ──
    //
    // Regression tests for the bug where a module with `ios: NativeImpl.swift`
    // but `windows: WindowsNativeImpl.cpp` was incorrectly classified as
    // "non-Apple" by the stale cleanup loop, causing its bridge.g.mm forwarder
    // to be deleted. This makes `${lib}_init_dart_api_dl` missing from the SPM
    // binary, causing a symbol-not-found crash at runtime on the 2nd/3rd spec.

    test('bridge.g.mm is created for a Swift-on-iOS module that is C++ on Windows', () {
      scaffoldSpmFull('nitro_view');

      // Bridge file in generated/cpp for nitro_system (Swift on iOS, C++ on Windows)
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'nitro_system.bridge.g.cpp')).writeAsStringSync('// bridge');
      File(p.join(genCpp.path, 'nitro_system.bridge.g.h')).writeAsStringSync('// header');

      // Spec: ios=Swift, windows=C++. isCpp=true but iosIsCpp=false.
      final specDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(specDir.path, 'nitro_system.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'nitro_system', ios: NativeImpl.swift, windows: WindowsNativeImpl.cpp)\n"
        'abstract class NitroSystem extends HybridObject {}\n',
      );

      linkPodspec(
        'nitro_view',
        ['nitro_view', 'nitro_system'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'nitro_system', module: 'NitroSystem', isCpp: true, iosIsCpp: false)],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'NitroSystemCpp', 'nitro_system.bridge.g.mm')).existsSync(),
        isTrue,
        reason: 'nitro_system is Swift on iOS — its bridge.g.mm (in its own target, issue #15) must be compiled to define nitro_system_init_dart_api_dl',
      );
    });

    test('bridge.g.mm migrates from the plugin target to the module target (issue #15)', () {
      scaffoldSpmFull('nitro_view');

      // Pre-plant the bridge mm (as if a previous link run created it).
      final cppDir = Directory(p.join(tmp.path, 'ios', 'Sources', 'NitroViewCpp'));
      final bridgeMm = File(p.join(cppDir.path, 'nitro_ui.bridge.g.mm'))..writeAsStringSync('// pre-existing mm');

      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'nitro_ui.bridge.g.cpp')).writeAsStringSync('// bridge');
      File(p.join(genCpp.path, 'nitro_ui.bridge.g.h')).writeAsStringSync('// header');

      final specDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(specDir.path, 'nitro_ui.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'nitro_ui', ios: NativeImpl.swift, linux: LinuxNativeImpl.cpp)\n"
        'abstract class NitroUI extends HybridObject {}\n',
      );

      linkPodspec(
        'nitro_view',
        ['nitro_view', 'nitro_ui'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'nitro_ui', module: 'NitroUI', isCpp: true, iosIsCpp: false)],
      );

      // The plugin-level copy is migrated to the module's own target: the
      // symbol nitro_ui_init_dart_api_dl stays linked, just from NitroUICpp.
      expect(bridgeMm.existsSync(), isFalse, reason: 'plugin-level copy removed by the issue-#15 repair pass');
      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'NitroUICpp', 'nitro_ui.bridge.g.mm')).existsSync(),
        isTrue,
        reason: 'the module target now provides nitro_ui_init_dart_api_dl for the SPM binary',
      );
    });

    test('Hybrid*.cpp impl forwarder IS removed for Swift-on-iOS module (no Apple C++ impl)', () {
      scaffoldSpmFull('nitro_view');

      // A stale HybridNitroSystem.cpp that somehow ended up in the Cpp target.
      final cppDir = Directory(p.join(tmp.path, 'ios', 'Sources', 'NitroViewCpp'));
      final staleImpl = File(p.join(cppDir.path, 'HybridNitroSystem.cpp'))..writeAsStringSync('// stale impl');

      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(genCpp.path, 'nitro_system.bridge.g.cpp')).writeAsStringSync('// bridge');
      File(p.join(genCpp.path, 'nitro_system.bridge.g.h')).writeAsStringSync('// header');

      final specDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(specDir.path, 'nitro_system.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'nitro_system', ios: NativeImpl.swift, windows: WindowsNativeImpl.cpp)\n"
        'abstract class NitroSystem extends HybridObject {}\n',
      );

      linkPodspec(
        'nitro_view',
        ['nitro_view', 'nitro_system'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'nitro_system', module: 'NitroSystem', isCpp: true, iosIsCpp: false)],
      );

      expect(
        staleImpl.existsSync(),
        isFalse,
        reason: 'HybridNitroSystem.cpp must be removed: nitro_system uses Swift on iOS, not C++',
      );
    });

    test('three-spec plugin: all three bridge.g.mm forwarders created (nitro_system+nitro_ui+nitro_view)', () {
      // This is the full nitro_view scenario: 3 specs, all Swift on iOS,
      // nitro_system and nitro_ui are also C++ on Windows/Linux.
      scaffoldSpmFull('nitro_view');

      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      for (final lib in ['nitro_system', 'nitro_ui', 'nitro_view']) {
        File(p.join(genCpp.path, '$lib.bridge.g.cpp')).writeAsStringSync('// bridge');
      }

      final specDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(specDir.path, 'nitro_system.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'nitro_system', ios: NativeImpl.swift, windows: WindowsNativeImpl.cpp)\n"
        'abstract class NitroSystem extends HybridObject {}\n',
      );
      File(p.join(specDir.path, 'nitro_ui.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'nitro_ui', ios: NativeImpl.swift, linux: LinuxNativeImpl.cpp)\n"
        'abstract class NitroUI extends HybridObject {}\n',
      );

      linkPodspec(
        'nitro_view',
        ['nitro_view', 'nitro_system', 'nitro_ui'],
        baseDir: tmp.path,
        moduleInfos: [
          const ModuleInfo(lib: 'nitro_system', module: 'NitroSystem', isCpp: true, iosIsCpp: false),
          const ModuleInfo(lib: 'nitro_ui', module: 'NitroUI', isCpp: true, iosIsCpp: false),
        ],
      );

      final sourcesDir = p.join(tmp.path, 'ios', 'Sources');
      // nitro_view.bridge.g.mm (main) stays in the plugin-level target;
      // the other two live in their own module targets (issue #15).
      final expected = {
        'nitro_view': 'NitroViewCpp',
        'nitro_system': 'NitroSystemCpp',
        'nitro_ui': 'NitroUICpp',
      };
      expected.forEach((lib, target) {
        expect(
          File(p.join(sourcesDir, target, '$lib.bridge.g.mm')).existsSync(),
          isTrue,
          reason: '$lib.bridge.g.mm must exist in $target so ${lib}_init_dart_api_dl is defined in the SPM binary',
        );
      });
    });
  });

  // ── _syncSwiftPluginToSpm — Swift plugin sync to SPM target ────────────

  group('_syncSwiftPluginToSpm — copies Swift plugin files to SPM target', () {
    void scaffoldSpmWithSwiftPlugin(String pluginName, String platform) {
      // Create the SPM layout.
      final pascal = pluginName.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');
      Directory(p.join(tmp.path, platform, 'Sources', pascal)).createSync(recursive: true);
      Directory(p.join(tmp.path, platform, 'Sources', '${pascal}Cpp')).createSync(recursive: true);
      Directory(p.join(tmp.path, platform, 'Classes')).createSync(recursive: true);
      File(p.join(tmp.path, platform, 'Package.swift')).writeAsStringSync('// SPM package');
      // Create Swift plugin class in Classes.
      File(p.join(tmp.path, platform, 'Classes', 'Swift$pascal.swift')).writeAsStringSync('// plugin');
      // Create impl in Classes.
      File(p.join(tmp.path, platform, 'Classes', '${pascal}Impl.swift')).writeAsStringSync('// impl');
    }

    test('iOS: copies SwiftPlugin.swift from Classes to Sources/<className>/', () {
      scaffoldSpmWithSwiftPlugin('my_plugin', 'ios');
      scaffoldPodspec('my_plugin');

      ensureIosPackageSwift('my_plugin', baseDir: tmp.path);

      final copied = File(p.join(tmp.path, 'ios', 'Sources', 'MyPlugin', 'SwiftMyPlugin.swift'));
      expect(copied.existsSync(), isTrue, reason: 'SwiftPlugin must be copied to SPM target');
    });

    test('iOS: copies Impl.swift from Classes to Sources/<className>/', () {
      scaffoldSpmWithSwiftPlugin('my_plugin', 'ios');
      scaffoldPodspec('my_plugin');

      ensureIosPackageSwift('my_plugin', baseDir: tmp.path);

      final copied = File(p.join(tmp.path, 'ios', 'Sources', 'MyPlugin', 'MyPluginImpl.swift'));
      expect(copied.existsSync(), isTrue, reason: 'Impl must be copied to SPM target');
    });

    test('iOS: does not overwrite existing Swift files in SPM target', () {
      scaffoldSpmWithSwiftPlugin('my_plugin', 'ios');
      scaffoldPodspec('my_plugin');
      // Pre-create with different content.
      final existing = File(p.join(tmp.path, 'ios', 'Sources', 'MyPlugin', 'SwiftMyPlugin.swift'))..writeAsStringSync('// existing');
      final existingImpl = File(p.join(tmp.path, 'ios', 'Sources', 'MyPlugin', 'MyPluginImpl.swift'))..writeAsStringSync('// existing');

      ensureIosPackageSwift('my_plugin', baseDir: tmp.path);

      expect(existing.readAsStringSync(), equals('// existing'), reason: 'Existing file must not be overwritten');
      expect(existingImpl.readAsStringSync(), equals('// existing'), reason: 'Existing impl must not be overwritten');
    });

    test('macOS: copies SwiftPlugin.swift from Classes to Sources/<className>/', () {
      scaffoldSpmWithSwiftPlugin('my_plugin', 'macos');
      scaffoldPodspec('my_plugin');

      ensureMacosPackageSwift('my_plugin', baseDir: tmp.path);

      final copied = File(p.join(tmp.path, 'macos', 'Sources', 'MyPlugin', 'SwiftMyPlugin.swift'));
      expect(copied.existsSync(), isTrue, reason: 'SwiftPlugin must be copied to SPM target');
    });

    test('macOS: copies Impl.swift from Classes to Sources/<className>/', () {
      scaffoldSpmWithSwiftPlugin('my_plugin', 'macos');
      scaffoldPodspec('my_plugin');

      ensureMacosPackageSwift('my_plugin', baseDir: tmp.path);

      final copied = File(p.join(tmp.path, 'macos', 'Sources', 'MyPlugin', 'MyPluginImpl.swift'));
      expect(copied.existsSync(), isTrue, reason: 'Impl must be copied to SPM target');
    });

    test('iOS: skips if no Classes directory exists', () {
      scaffoldSpmWithSwiftPlugin('my_plugin', 'ios');
      scaffoldPodspec('my_plugin');
      // Delete Classes directory.
      Directory(p.join(tmp.path, 'ios', 'Classes')).deleteSync(recursive: true);

      ensureIosPackageSwift('my_plugin', baseDir: tmp.path);

      final copied = File(p.join(tmp.path, 'ios', 'Sources', 'MyPlugin', 'SwiftMyPlugin.swift'));
      expect(copied.existsSync(), isFalse, reason: 'Nothing should be copied when Classes is missing');
    });
  });

  // ── Package.swift template tests ────────────────────────────────────────────────

  group('Package.swift template — iOS', () {
    test('generates valid SPM Package.swift with FlutterFramework', () {
      final out = st.iosPackageSwiftContent('my_plugin', 'MyPlugin');
      expect(out, contains('// swift-tools-version: 5.9'));
      expect(out, contains('name: "my_plugin"'));
      expect(out, contains('name: "MyPluginCpp"'));
      expect(out, contains('path: "Sources/MyPluginCpp"'));
      expect(out, contains('path: "Sources/MyPlugin"'));
      expect(out, contains('.package(name: "FlutterFramework", path: "../FlutterFramework")'));
      expect(out, contains('.product(name: "FlutterFramework", package: "FlutterFramework")'));
      // No arbitrary external header search paths (nitro paths are resolved at link time).
      expect(out, isNot(contains('../../')), reason: 'No relative header paths in SPM');
    });

    test('depends on C++ target via publicHeadersPath', () {
      final out = st.iosPackageSwiftContent('my_plugin', 'MyPlugin');
      expect(out, contains('"MyPluginCpp"'));
      expect(out, contains('publicHeadersPath: "include"'));
    });

    test('uses c++17 for C++ target', () {
      final out = st.iosPackageSwiftContent('my_plugin', 'MyPlugin');
      expect(out, contains('.unsafeFlags(["-std=c++17"])'));
    });

    test('targets iOS 13+', () {
      final out = st.iosPackageSwiftContent('my_plugin', 'MyPlugin');
      expect(out, contains('.iOS(.v13)'));
    });
  });

  group('Package.swift template — macOS', () {
    test('generates valid SPM Package.swift with FlutterFramework', () {
      final out = st.macosPackageSwiftContent('my_plugin', 'MyPlugin');
      expect(out, contains('// swift-tools-version: 5.9'));
      expect(out, contains('name: "my_plugin"'));
      expect(out, contains('name: "MyPluginCpp"'));
      expect(out, contains('path: "Sources/MyPluginCpp"'));
      expect(out, contains('path: "Sources/MyPlugin"'));
      expect(out, contains('.package(name: "FlutterFramework", path: "../FlutterFramework")'));
      expect(out, contains('.product(name: "FlutterFramework", package: "FlutterFramework")'));
      expect(out, isNot(contains('../../')), reason: 'No relative header paths in SPM');
    });

    test('depends on C++ target via publicHeadersPath', () {
      final out = st.macosPackageSwiftContent('my_plugin', 'MyPlugin');
      expect(out, contains('"MyPluginCpp"'));
      expect(out, contains('publicHeadersPath: "include"'));
    });

    test('uses c++17 for C++ target', () {
      final out = st.macosPackageSwiftContent('my_plugin', 'MyPlugin');
      expect(out, contains('.unsafeFlags(["-std=c++17"])'));
    });

    test('targets macOS 10.15+', () {
      final out = st.macosPackageSwiftContent('my_plugin', 'MyPlugin');
      expect(out, contains('.macOS(.v10_15)'));
    });
  });

  // ── ensureFlutterFrameworkDependency ─────────────────────────────────────

  group('ensureFlutterFrameworkDependency', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('flutter_fw_dep_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String path0() => p.join(tmp.path, 'Package.swift');

    test('returns false when file does not exist', () {
      expect(spm.ensureFlutterFrameworkDependency(path0()), isFalse);
    });

    test('returns false and does not modify when FlutterFramework already present', () {
      File(path0()).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'let p = Package(name:"x", platforms:[.iOS(.v13)],\n'
        '  dependencies:[.package(name:"FlutterFramework",path:"../FlutterFramework")],\n'
        '  targets:[.target(name:"x",dependencies:["XCpp"],path:"Sources/X")])',
      );
      final before = File(path0()).readAsStringSync();
      expect(spm.ensureFlutterFrameworkDependency(path0()), isFalse);
      expect(File(path0()).readAsStringSync(), equals(before));
    });

    test('injects package-level dependency when no dependencies block exists (2-space indent)', () {
      // Format produced by swift_templates.dart (2-space, old format without FlutterFramework)
      File(path0()).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'import PackageDescription\n'
        '\n'
        'let package = Package(\n'
        '  name: "my_plugin",\n'
        '  platforms: [.iOS(.v13)],\n'
        '  products: [\n'
        '    .library(name: "my-plugin", targets: ["my_plugin"])\n'
        '  ],\n'
        '  targets: [\n'
        '    .target(name: "MyPluginCpp", path: "Sources/MyPluginCpp", publicHeadersPath: "include"),\n'
        '    .target(name: "my_plugin", dependencies: ["MyPluginCpp"], path: "Sources/MyPlugin")\n'
        '  ]\n'
        ')\n',
      );
      expect(spm.ensureFlutterFrameworkDependency(path0()), isTrue);
      final result = File(path0()).readAsStringSync();
      expect(result, contains('.package(name: "FlutterFramework", path: "../FlutterFramework")'));
      expect(result, contains('.product(name: "FlutterFramework", package: "FlutterFramework")'));
    });

    test('injects package-level dependency when no dependencies block exists (4-space indent)', () {
      // Format produced by scaffold_templates.dart (4-space, old format without FlutterFramework)
      File(path0()).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'import PackageDescription\n'
        '\n'
        'let package = Package(\n'
        '    name: "my_plugin",\n'
        '    platforms: [.iOS(.v13)],\n'
        '    products: [\n'
        '        .library(name: "my-plugin", targets: ["my_plugin"]),\n'
        '    ],\n'
        '    targets: [\n'
        '        .target(name: "MyPluginCpp", path: "Sources/MyPluginCpp", publicHeadersPath: "include"),\n'
        '        .target(name: "my_plugin", dependencies: ["MyPluginCpp"], path: "Sources/MyPlugin"),\n'
        '    ]\n'
        ')\n',
      );
      expect(spm.ensureFlutterFrameworkDependency(path0()), isTrue);
      final result = File(path0()).readAsStringSync();
      expect(result, contains('.package(name: "FlutterFramework", path: "../FlutterFramework")'));
      expect(result, contains('.product(name: "FlutterFramework", package: "FlutterFramework")'));
    });

    test('appends into existing package-level dependencies array', () {
      File(path0()).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'let p = Package(name:"x", platforms:[.iOS(.v13)],\n'
        '  dependencies:[\n'
        '    .package(url:"https://example.com/foo", from:"1.0.0"),\n'
        '  ],\n'
        '  targets:[.target(name:"x",dependencies:["XCpp"],path:"Sources/X")])',
      );
      expect(spm.ensureFlutterFrameworkDependency(path0()), isTrue);
      final result = File(path0()).readAsStringSync();
      expect(result, contains('.package(name: "FlutterFramework", path: "../FlutterFramework")'));
      // Original dependency should still be present.
      expect(result, contains('https://example.com/foo'));
    });

    test('converts inline Swift-target dependencies to expanded form with FlutterFramework', () {
      File(path0()).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'let p = Package(name:"x",\n'
        '  targets:[\n'
        '    .target(name:"XCpp",path:"Sources/XCpp",publicHeadersPath:"include"),\n'
        '    .target(name:"x",dependencies:["XCpp"],path:"Sources/X")\n'
        '  ])',
      );
      spm.ensureFlutterFrameworkDependency(path0());
      final result = File(path0()).readAsStringSync();
      expect(result, contains('"XCpp"'));
      expect(result, contains('.product(name: "FlutterFramework", package: "FlutterFramework")'));
    });

    test('is idempotent — second call makes no changes', () {
      File(path0()).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'let p = Package(name:"x",\n'
        '  targets:[\n'
        '    .target(name:"XCpp",path:"Sources/XCpp",publicHeadersPath:"include"),\n'
        '    .target(name:"x",dependencies:["XCpp"],path:"Sources/X")\n'
        '  ])',
      );
      spm.ensureFlutterFrameworkDependency(path0());
      final afterFirst = File(path0()).readAsStringSync();
      final secondResult = spm.ensureFlutterFrameworkDependency(path0());
      expect(secondResult, isFalse);
      expect(File(path0()).readAsStringSync(), equals(afterFirst));
    });

    test('ensureIosPackageSwift patches FlutterFramework into existing Package.swift', () {
      // Scaffold an old-style ios/Package.swift without FlutterFramework
      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      final pkgFile = File(p.join(iosDir.path, 'Package.swift'));
      pkgFile.writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'let p = Package(name:"my_plugin",\n'
        '  platforms:[.iOS(.v13)],\n'
        '  targets:[\n'
        '    .target(name:"MyPluginCpp",path:"Sources/MyPluginCpp",publicHeadersPath:"include"),\n'
        '    .target(name:"my_plugin",dependencies:["MyPluginCpp"],path:"Sources/MyPlugin")\n'
        '  ])',
      );
      ensureIosPackageSwift('my_plugin', baseDir: tmp.path);
      expect(pkgFile.readAsStringSync(), contains('FlutterFramework'));
    });

    test('ensureMacosPackageSwift patches FlutterFramework into existing Package.swift', () {
      final macosDir = Directory(p.join(tmp.path, 'macos'))..createSync();
      final pkgFile = File(p.join(macosDir.path, 'Package.swift'));
      pkgFile.writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'let p = Package(name:"my_plugin",\n'
        '  platforms:[.macOS(.v10_15)],\n'
        '  targets:[\n'
        '    .target(name:"MyPluginCpp",path:"Sources/MyPluginCpp",publicHeadersPath:"include"),\n'
        '    .target(name:"my_plugin",dependencies:["MyPluginCpp"],path:"Sources/MyPlugin")\n'
        '  ])',
      );
      ensureMacosPackageSwift('my_plugin', baseDir: tmp.path);
      expect(pkgFile.readAsStringSync(), contains('FlutterFramework'));
    });
  });

  group('linkDesktopPubspecFfiOnly — issue #10 (pluginClass on FFI-only desktop)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_pubspec_ffi_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    ModuleInfo cppDesktopModule() => ModuleInfo(
      lib: 'printing',
      module: 'Printing',
      isCpp: true,
      windowsIsCpp: true,
      linuxIsCpp: true,
    );

    String writePubspec(String platformsBody) {
      final content =
          'name: nitro_printing\n'
          'flutter:\n'
          '  plugin:\n'
          '    platforms:\n'
          '$platformsBody';
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(content);
      return content;
    }

    String readPubspec() => File(p.join(tmp.path, 'pubspec.yaml')).readAsStringSync();

    test('removes pluginClass from block-form windows/linux entries, keeps other platforms', () {
      writePubspec(
        '      android:\n'
        '        pluginClass: NitroPrintingPlugin\n'
        '        package: dev.shreeman.nitro_printing\n'
        '        ffiPlugin: true\n'
        '      windows:\n'
        '        pluginClass: NitroPrintingPlugin\n'
        '        ffiPlugin: true\n'
        '      linux:\n'
        '        pluginClass: NitroPrintingPlugin\n'
        '        ffiPlugin: true\n',
      );
      linkDesktopPubspecFfiOnly([cppDesktopModule()], baseDir: tmp.path);
      final out = readPubspec();
      // Desktop entries are FFI-only now…
      expect(out, contains('      windows:\n        ffiPlugin: true'));
      expect(out, contains('      linux:\n        ffiPlugin: true'));
      // …but Android (a real plugin class) is untouched.
      expect(out, contains('      android:\n        pluginClass: NitroPrintingPlugin'));
    });

    test('cleans inline flow-map entries (the issue #10 repro shape)', () {
      writePubspec(
        '      windows: { pluginClass: NitroPrintingPlugin, ffiPlugin: true }\n'
        '      linux: { pluginClass: NitroPrintingPlugin, ffiPlugin: true }\n',
      );
      linkDesktopPubspecFfiOnly([cppDesktopModule()], baseDir: tmp.path);
      final out = readPubspec();
      expect(out, contains('      windows: { ffiPlugin: true }'));
      expect(out, contains('      linux: { ffiPlugin: true }'));
      expect(out, isNot(contains('pluginClass')));
    });

    test('idempotent: an already-clean pubspec is byte-identical after a re-run', () {
      final original = writePubspec(
        '      windows:\n'
        '        ffiPlugin: true\n'
        '      linux:\n'
        '        ffiPlugin: true\n',
      );
      linkDesktopPubspecFfiOnly([cppDesktopModule()], baseDir: tmp.path);
      expect(readPubspec(), original);
    });

    test('only cleans platforms the module actually targets as cpp', () {
      writePubspec(
        '      windows:\n'
        '        pluginClass: NitroPrintingPlugin\n'
        '        ffiPlugin: true\n'
        '      linux:\n'
        '        pluginClass: NitroPrintingPlugin\n'
        '        ffiPlugin: true\n',
      );
      final windowsOnly = ModuleInfo(lib: 'printing', module: 'Printing', isCpp: true, windowsIsCpp: true);
      linkDesktopPubspecFfiOnly([windowsOnly], baseDir: tmp.path);
      final out = readPubspec();
      expect(out, contains('      windows:\n        ffiPlugin: true'));
      // Linux isn't nitro-cpp-managed here — left exactly as the author wrote it.
      expect(out, contains('      linux:\n        pluginClass: NitroPrintingPlugin'));
    });

    test('leaves a pluginClass-only entry (no ffiPlugin) alone — not a Nitro FFI shape', () {
      final original = writePubspec(
        '      windows:\n'
        '        pluginClass: HandRolledMethodChannelPlugin\n',
      );
      linkDesktopPubspecFfiOnly([cppDesktopModule()], baseDir: tmp.path);
      expect(readPubspec(), original);
    });

    test('no cpp desktop modules → pubspec untouched', () {
      final original = writePubspec(
        '      windows:\n'
        '        pluginClass: NitroPrintingPlugin\n'
        '        ffiPlugin: true\n',
      );
      linkDesktopPubspecFfiOnly(
        [ModuleInfo(lib: 'printing', module: 'Printing', isCpp: false)],
        baseDir: tmp.path,
      );
      expect(readPubspec(), original);
    });

    test('does not touch same-named keys outside the platforms block', () {
      final content =
          'name: nitro_printing\n'
          'environments:\n'
          '  windows: { pluginClass: NotAPlatformEntry, ffiPlugin: true }\n'
          'flutter:\n'
          '  plugin:\n'
          '    platforms:\n'
          '      windows:\n'
          '        pluginClass: NitroPrintingPlugin\n'
          '        ffiPlugin: true\n';
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(content);
      linkDesktopPubspecFfiOnly([cppDesktopModule()], baseDir: tmp.path);
      final out = readPubspec();
      // The stray top-level key keeps its pluginClass (not under platforms:).
      expect(out, contains('  windows: { pluginClass: NotAPlatformEntry, ffiPlugin: true }'));
      expect(out, contains('      windows:\n        ffiPlugin: true'));
    });
  });

  group('linkWindows / linkLinux — issue #11 (app-runner CMakeLists must stay untouched)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_runner_cmake_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    final module = ModuleInfo(
      lib: 'printing_example',
      module: 'PrintingExample',
      isCpp: true,
      windowsIsCpp: true,
      linuxIsCpp: true,
    );

    // A trimmed Flutter app-runner CMakeLists (example/windows|linux): defines
    // BINARY_NAME + add_executable; PLUGIN_NAME is never defined in this scope.
    const runnerBody =
        'cmake_minimum_required(VERSION 3.14)\n'
        'project(example LANGUAGES CXX)\n'
        'set(BINARY_NAME "example")\n'
        'add_subdirectory("flutter")\n'
        'add_executable(\${BINARY_NAME} WIN32 "main.cpp")\n';

    File writeRunner(String platform, String content) {
      final dir = Directory(p.join(tmp.path, platform))..createSync(recursive: true);
      return File(p.join(dir.path, 'CMakeLists.txt'))..writeAsStringSync(content);
    }

    test('strips a previously injected \${PLUGIN_NAME} block and NITRO_NATIVE from a runner', () {
      // What an older nitrogen wrote into nitro_printing's example runner:
      // an absolute local-checkout NITRO_NATIVE and an include block on an
      // undefined target — both break configure on any other machine.
      final f = writeRunner(
        'windows',
        'set(NITRO_NATIVE "/Users/someone/nitro_ecosystem/packages/nitro/src/native")\n'
        '\n'
        '$runnerBody'
        '\n'
        'target_include_directories(\${PLUGIN_NAME} PRIVATE\n'
        '  "\${NITRO_NATIVE}"\n'
        '  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"\n'
        '  "\${CMAKE_CURRENT_SOURCE_DIR}/../src"\n'
        ')\n',
      );
      linkWindows('printing_example', ['printing_example'], '/nitro/native', baseDir: tmp.path, moduleInfos: [module]);
      final out = f.readAsStringSync();
      expect(out, isNot(contains('PLUGIN_NAME')));
      expect(out, isNot(contains('NITRO_NATIVE')));
      expect(out, contains('add_executable(\${BINARY_NAME}'));
    });

    test('a clean runner stays byte-identical (nothing is injected)', () {
      final f = writeRunner('linux', runnerBody);
      linkLinux('printing_example', ['printing_example'], '/nitro/native', baseDir: tmp.path, moduleInfos: [module]);
      expect(f.readAsStringSync(), runnerBody);
    });

    test('a real plugin platform CMakeLists still gets the nitro include block', () {
      // Non-shared-src plugin file: add_library on ${PLUGIN_NAME}, no
      // BINARY_NAME/add_executable — the classic FFI plugin template shape.
      final f = writeRunner(
        'windows',
        'cmake_minimum_required(VERSION 3.14)\n'
        'project(printing_example LANGUAGES CXX)\n'
        'set(PLUGIN_NAME "printing_example")\n'
        'add_library(\${PLUGIN_NAME} SHARED\n'
        '  "stub.cpp"\n'
        ')\n',
      );
      linkWindows('printing_example', ['printing_example'], '/nitro/native', baseDir: tmp.path, moduleInfos: [module]);
      final out = f.readAsStringSync();
      expect(out, contains('set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../src/native")'));
      expect(out, contains('target_include_directories(\${PLUGIN_NAME} PRIVATE'));
    });

    test('linkCMake repairs an absolute NITRO_NATIVE in an existing src/CMakeLists.txt', () {
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      final f = File(p.join(tmp.path, 'src', 'CMakeLists.txt'))
        ..writeAsStringSync(
          'set(NITRO_NATIVE "/Users/someone/nitro_ecosystem/packages/nitro/src/native")\n'
          'project(printing_example_library VERSION 0.0.1 LANGUAGES C CXX)\n'
          'add_library(printing_example SHARED\n'
          '  "dart_api_dl.c"\n'
          ')\n'
          'target_include_directories(printing_example PRIVATE\n'
          '  "\${NITRO_NATIVE}"\n'
          ')\n',
        );
      linkCMake('printing_example', ['printing_example'], '/abs/nitro/native', baseDir: tmp.path, moduleInfos: [module]);
      final out = f.readAsStringSync();
      expect(out, isNot(contains('/Users/someone/')));
      expect(out, contains(RegExp(r'set\(NITRO_NATIVE "\$\{CMAKE_CURRENT_SOURCE_DIR\}[^"]*"\)')));
    });
  });

  group('issue #12 — per-platform separation transition completes', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_sep_transition_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    const todoStub = '// TODO: implement all pure-virtual methods declared in HybridPrinting\n';
    const realImpl =
        '#include "../lib/src/generated/cpp/printing.native.g.h"\n'
        'class HybridPrintingImpl final : public HybridPrinting {\n'
        'public:\n'
        '    int64_t addPrinter() override { return 42; }\n'
        '};\n';

    ModuleInfo separated({bool windows = true, bool linux = true}) => ModuleInfo(
      lib: 'printing',
      module: 'Printing',
      isCpp: true,
      isNativeCpp: true,
      windowsIsCpp: true,
      linuxIsCpp: true,
      windowsRequestsSeparateImpl: windows,
      linuxRequestsSeparateImpl: linux,
    );

    void writeSharedImpl() {
      Directory(p.join(tmp.path, 'src')).createSync(recursive: true);
      File(p.join(tmp.path, 'src', 'HybridPrinting.cpp')).writeAsStringSync(realImpl);
    }

    void writeSpec({required bool explicitMarkers}) {
      final libSrc = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      final markers = explicitMarkers ? 'windows: WindowsNativeImpl.cpp, linux: LinuxNativeImpl.cpp' : 'windows: NativeImpl.cpp, linux: NativeImpl.cpp';
      File(p.join(libSrc.path, 'printing.native.dart')).writeAsStringSync('''
@NitroModule(lib: "printing", $markers)
abstract class Printing extends HybridObject {}
''');
    }

    test('existing untouched TODO stub is replaced by the migrated shared impl on marker switch', () {
      // The exact issue #12 repro: stubs were auto-created on an earlier link
      // (before the annotation switch), so plain never-overwrite left the
      // real impl stranded in src/ while NITRO_IMPL_SRC pointed at the stub.
      writeSharedImpl();
      writeSpec(explicitMarkers: true);
      final winStub = File(p.join(tmp.path, 'windows', 'src', 'HybridPrinting.cpp'))
        ..createSync(recursive: true)
        ..writeAsStringSync(todoStub);
      linkWindowsCppImplStubs([separated()], baseDir: tmp.path);
      final out = winStub.readAsStringSync();
      expect(out, contains('addPrinter'));
      // Include path adjusted one level deeper for the new location.
      expect(out, contains('#include "../../lib/src/generated/cpp/printing.native.g.h"'));
      expect(out, isNot(contains('TODO: implement all pure-virtual methods')));
    });

    test('a platform file with user code is NEVER overwritten, even on marker switch', () {
      writeSharedImpl();
      writeSpec(explicitMarkers: true);
      const userCode = '// my own windows impl\nint x() { return 1; }\n';
      final winStub = File(p.join(tmp.path, 'windows', 'src', 'HybridPrinting.cpp'))
        ..createSync(recursive: true)
        ..writeAsStringSync(userCode);
      linkWindowsCppImplStubs([separated()], baseDir: tmp.path);
      expect(winStub.readAsStringSync(), userCode);
    });

    test('without the explicit markers an untouched stub stays a stub', () {
      writeSharedImpl();
      writeSpec(explicitMarkers: false);
      final linuxStub = File(p.join(tmp.path, 'linux', 'src', 'HybridPrinting.cpp'))
        ..createSync(recursive: true)
        ..writeAsStringSync(todoStub);
      linkLinuxCppImplStubs([separated(windows: false, linux: false)], baseDir: tmp.path);
      expect(linuxStub.readAsStringSync(), todoStub);
    });

    test('linkCMake retrofits the NITRO_IMPL_SRC guard onto an if(NOT ANDROID)-wrapped target_sources', () {
      writeSharedImpl();
      // Also mark separation active via an explicit request.
      final cmake = File(p.join(tmp.path, 'src', 'CMakeLists.txt'))
        ..writeAsStringSync(
          'project(printing_library VERSION 0.0.1 LANGUAGES C CXX)\n'
          'add_library(printing SHARED\n'
          '  "dart_api_dl.c"\n'
          ')\n'
          'if(NOT ANDROID)\n'
          '  target_sources(printing PRIVATE "HybridPrinting.cpp")\n'
          'endif()\n'
          'target_include_directories(printing PRIVATE\n'
          '  "\${NITRO_NATIVE}"\n'
          ')\n',
        );
      linkCMake('printing', ['printing'], '/nitro/native', baseDir: tmp.path, moduleInfos: [separated()]);
      final out = cmake.readAsStringSync();
      expect(out, contains('if(DEFINED NITRO_IMPL_SRC_printing)'));
      expect(out, contains('target_sources(printing PRIVATE "\${NITRO_IMPL_SRC_printing}")'));
      // The shared file remains the else-branch fallback (Android and
      // never-opted-in desktop builds keep their exact old behavior).
      expect(out, contains('target_sources(printing PRIVATE "HybridPrinting.cpp")'));
    });

    test('linkCMake retrofits a bare target_sources line too', () {
      writeSharedImpl();
      final cmake = File(p.join(tmp.path, 'src', 'CMakeLists.txt'))
        ..writeAsStringSync(
          'project(printing_library VERSION 0.0.1 LANGUAGES C CXX)\n'
          'add_library(printing SHARED\n'
          '  "dart_api_dl.c"\n'
          ')\n'
          'target_sources(printing PRIVATE "HybridPrinting.cpp")\n'
          'target_include_directories(printing PRIVATE\n'
          '  "\${NITRO_NATIVE}"\n'
          ')\n',
        );
      linkCMake('printing', ['printing'], '/nitro/native', baseDir: tmp.path, moduleInfos: [separated()]);
      expect(cmake.readAsStringSync(), contains('if(DEFINED NITRO_IMPL_SRC_printing)'));
    });

    test('no separation requested → src/CMakeLists.txt stays byte-identical', () {
      writeSharedImpl();
      const original =
          'project(printing_library VERSION 0.0.1 LANGUAGES C CXX)\n'
          'set(CMAKE_CXX_STANDARD 17)\n'
          'set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/native")\n'
          'add_library(printing SHARED\n'
          '  "dart_api_dl.c"\n'
          '  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/printing.bridge.g.cpp"\n'
          ')\n'
          'if(NOT ANDROID)\n'
          '  target_sources(printing PRIVATE "HybridPrinting.cpp")\n'
          'endif()\n'
          'target_include_directories(printing PRIVATE\n'
          '  "\${NITRO_NATIVE}"\n'
          ')\n';
      final cmake = File(p.join(tmp.path, 'src', 'CMakeLists.txt'))..writeAsStringSync(original);
      final notSeparated = ModuleInfo(
        lib: 'printing',
        module: 'Printing',
        isCpp: true,
        isNativeCpp: true,
        windowsIsCpp: true,
        linuxIsCpp: true,
      );
      linkCMake('printing', ['printing'], '/nitro/native', baseDir: tmp.path, moduleInfos: [notSeparated]);
      expect(cmake.readAsStringSync(), isNot(contains('NITRO_IMPL_SRC')));
    });

    test('hasCustomPlatformImpl: comment-only file (marker deleted) is NOT an opt-in', () {
      final f = File(p.join(tmp.path, 'windows', 'src', 'HybridPrinting.cpp'))..createSync(recursive: true);
      f.writeAsStringSync(
        '// I removed the stub body but have not written anything yet.\n'
        '/* just notes:\n   maybe use WinSpool here later */\n'
        '\n',
      );
      expect(hasCustomPlatformImpl(tmp.path, 'windows', 'Printing'), isFalse);
    });

    test('hasCustomPlatformImpl: real code (marker gone) IS an opt-in', () {
      final f = File(p.join(tmp.path, 'windows', 'src', 'HybridPrinting.cpp'))..createSync(recursive: true);
      f.writeAsStringSync(realImpl);
      expect(hasCustomPlatformImpl(tmp.path, 'windows', 'Printing'), isTrue);
    });
  });

  group('linkBuildYamlSourcesExcludes — issue #20 (build_runner symlink-cycle hang guard)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nitro_buildyaml_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String read() => File(p.join(tmp.path, 'build.yaml')).readAsStringSync();

    test('creates build.yaml with sources excludes when absent', () {
      linkBuildYamlSourcesExcludes(baseDir: tmp.path);
      final out = read();
      expect(out, contains('- example/**'));
      expect(out, contains('"**/.symlinks/**"'));
      expect(out, contains('"**/ephemeral/**"'));
      expect(out, contains('- lib/src/**.native.dart'));
    });

    test('inserts sources block into an existing nitrogen-shaped build.yaml', () {
      File(p.join(tmp.path, 'build.yaml')).writeAsStringSync(
        'targets:\n'
        '  \$default:\n'
        '    builders:\n'
        '      nitro_generator:\n'
        '        generate_for:\n'
        '          - lib/src/**.native.dart\n',
      );
      linkBuildYamlSourcesExcludes(baseDir: tmp.path);
      final out = read();
      expect(out, contains('    sources:\n'));
      expect(out, contains('- example/**'));
      // The builder config survives untouched below the inserted block.
      expect(out, contains('generate_for:\n          - lib/src/**.native.dart'));
    });

    test('idempotent: second run leaves the file byte-identical', () {
      linkBuildYamlSourcesExcludes(baseDir: tmp.path);
      final first = read();
      linkBuildYamlSourcesExcludes(baseDir: tmp.path);
      expect(read(), first);
    });

    test('never touches a build.yaml that already declares sources (user-owned)', () {
      const custom =
          'targets:\n'
          '  \$default:\n'
          '    sources:\n'
          '      exclude:\n'
          '        - my/custom/path/**\n';
      File(p.join(tmp.path, 'build.yaml')).writeAsStringSync(custom);
      linkBuildYamlSourcesExcludes(baseDir: tmp.path);
      expect(read(), custom);
    });
  });
}
