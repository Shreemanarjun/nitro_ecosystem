import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/link_command.dart';
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
      expect(modules.first.isCpp, isTrue,
          reason: 'macos: NativeImpl.cpp alone is sufficient to mark the module as cpp');
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
    // For _syncCppModuleSourcesToSpm to execute, ios/Sources/<PluginCpp>/ must
    // already exist (the function returns early otherwise).  We create it here
    // to simulate an existing SPM-enabled project.
    void scaffoldSpm(String pluginName) {
      scaffoldPodspec(pluginName);
      final pascal = pluginName.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');
      Directory(p.join(tmp.path, 'ios', 'Sources', '${pascal}Cpp')).createSync(recursive: true);
      // Also create Package.swift so ensureIosPackageSwift does not re-create it
      // (which would redundantly call createSync and mask real failures).
      File(p.join(tmp.path, 'ios', 'Package.swift')).writeAsStringSync('// existing');
    }

    test('creates .bridge.g.mm forwarder in Sources/<PluginCpp>/', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'my_cpp_mod.bridge.g.mm')).existsSync(),
        isTrue,
      );
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
          'MyPluginCpp',
          'my_cpp_mod.bridge.g.mm',
        ),
      ).readAsStringSync();
      expect(content, contains('my_cpp_mod.bridge.g.cpp'));
    });

    test('creates Hybrid<Lib>.cpp forwarder in Sources/<PluginCpp>/', () {
      scaffoldSpm('my_plugin');
      scaffoldCppModule('my_cpp_mod', appleCpp: true);

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'my_cpp_mod'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
      );

      expect(
        File(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'HybridMyCppMod.cpp')).existsSync(),
        isTrue,
      );
    });

    test('copies .bridge.g.h into Sources/<PluginCpp>/include/', () {
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
            'MyPluginCpp',
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
            'MyPluginCpp',
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

    test('no-op when Sources/<PluginCpp>/ does not exist', () {
      scaffoldPodspec('my_plugin');
      scaffoldCppModule('my_cpp_mod');
      // No ios/Sources/MyPluginCpp/ directory.

      expect(
        () => linkPodspec(
          'my_plugin',
          ['my_plugin', 'my_cpp_mod'],
          baseDir: tmp.path,
          moduleInfos: [const ModuleInfo(lib: 'my_cpp_mod', module: 'MyCppMod', isCpp: true)],
        ),
        returnsNormally,
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
      expect(content, contains('set(NITRO_NATIVE "/path/to/nitro/native")'));
      expect(content, contains('add_library(other_lib SHARED'));
      expect(content, contains('dart_api_dl.c'));
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

      expect(podspec.readAsStringSync(), contains("s.platform = :osx, '10.15'"),
          reason: 'platform line must be inserted when absent');
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
      expect("'DEFINES_MODULE'".allMatches(content).length, equals(1),
          reason: 'second run must not duplicate DEFINES_MODULE');
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

    test('linkPodspec appends generated swift glob to existing source_files', () {
      scaffoldMinimalPodspec('ios', 'my_plugin',
          sourceFilesLine: "s.source_files = 'Classes/**/*'");
      Directory(p.join(tmp.path, 'src')).createSync();

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final content = File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(content, contains("lib/src/generated/swift/**/*.swift"));
    });

    test('linkPodspec inserts source_files when absent from podspec', () {
      scaffoldMinimalPodspec('ios', 'my_plugin');
      Directory(p.join(tmp.path, 'src')).createSync();

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final content = File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(content, contains("lib/src/generated/swift/**/*.swift"));
    });

    test('linkPodspec does not duplicate source_files on second run', () {
      scaffoldMinimalPodspec('ios', 'my_plugin',
          sourceFilesLine: "s.source_files = 'Classes/**/*'");
      Directory(p.join(tmp.path, 'src')).createSync();

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);
      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final content = File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).readAsStringSync();
      expect(
        'lib/src/generated/swift'.allMatches(content).length,
        equals(1),
        reason: 'second run must not add a second swift glob',
      );
    });

    test('linkPodspec deletes stale .bridge.g.swift from ios/Classes/', () {
      scaffoldMinimalPodspec('ios', 'my_plugin',
          sourceFilesLine: "s.source_files = 'Classes/**/*'");
      Directory(p.join(tmp.path, 'src')).createSync();
      // Plant a stale copy that would cause duplicate-symbol errors.
      final stale = File(p.join(tmp.path, 'ios', 'Classes', 'my_plugin.bridge.g.swift'))
        ..writeAsStringSync('// stale copy');

      linkPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      expect(stale.existsSync(), isFalse,
          reason: 'stale .bridge.g.swift must be deleted — canonical file is in lib/src/generated/swift/');
    });

    test('linkMacosPodspec appends generated swift glob to existing source_files', () {
      scaffoldMinimalPodspec('macos', 'my_plugin',
          sourceFilesLine: "s.source_files = 'Classes/**/*'");
      Directory(p.join(tmp.path, 'src')).createSync();

      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      final content = File(p.join(tmp.path, 'macos', 'my_plugin.podspec')).readAsStringSync();
      expect(content, contains("lib/src/generated/swift/**/*.swift"));
    });

    test('linkMacosPodspec deletes stale .bridge.g.swift from macos/Classes/', () {
      scaffoldMinimalPodspec('macos', 'my_plugin',
          sourceFilesLine: "s.source_files = 'Classes/**/*'");
      Directory(p.join(tmp.path, 'src')).createSync();
      final stale = File(p.join(tmp.path, 'macos', 'Classes', 'my_plugin.bridge.g.swift'))
        ..writeAsStringSync('// stale copy');

      linkMacosPodspec('my_plugin', ['my_plugin'], baseDir: tmp.path);

      expect(stale.existsSync(), isFalse);
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

      linkMacosSwiftPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect(content, contains('MathRegistry.register('));
    });

    test('appends after last existing Registry.register call', () {
      final plugin = writeMacosPlugin(tmp, '''
public static func register(with registrar: FlutterPluginRegistrar) {
  FooRegistry.register(FooImpl())
}
''');

      linkMacosSwiftPlugin('my_plugin', [{'module': 'Bar', 'lib': 'bar'}], baseDir: tmp.path);

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

      linkMacosSwiftPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect('MathRegistry.register'.allMatches(content).length, equals(1));
    });

    test('no-op when macos/ directory does not exist', () {
      expect(
        () => linkMacosSwiftPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path),
        returnsNormally,
      );
    });

    test('no-op when no Plugin.swift found in macos/', () {
      Directory(p.join(tmp.path, 'macos', 'Classes')).createSync(recursive: true);
      expect(
        () => linkMacosSwiftPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path),
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
      expect(content, contains('set(NITRO_NATIVE "/nitro/native")'));
      // Must appear before the cmake_minimum_required line
      expect(content.indexOf('NITRO_NATIVE'), lessThan(content.indexOf('cmake_minimum')));
    });

    test('does not duplicate set(NITRO_NATIVE) if already present', () {
      final cmake = writeWinCmake(tmp, 'set(NITRO_NATIVE "old/path")\n$minimalWinCmake');
      linkWindows('my_plugin', ['my_plugin'], '/nitro/native', baseDir: tmp.path);
      final content = cmake.readAsStringSync();
      // set(NITRO_NATIVE) must appear exactly once (not injected again)
      expect('set(NITRO_NATIVE'.allMatches(content).length, equals(1));
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
      expect(content, contains('set(NITRO_NATIVE "/nitro/native")'));
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
      expect(isAppleCppModule(spec), isFalse,
          reason: 'Windows-only C++ must NOT produce an Apple forwarder in ios/Classes/');
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
      expect(isNativeCppModule(spec), isFalse,
          reason: 'Apple-only C++ does not belong in src/CMakeLists.txt');
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
  });

  // ── purgeStaleCppKotlinRegistrations ─────────────────────────────────────────

  group('purgeStaleCppKotlinRegistrations', () {
    File writeKotlinPlugin2(Directory dir, String content) {
      final d = Directory(p.join(dir.path, 'android', 'src', 'main', 'kotlin', 'dev', 'test'))
        ..createSync(recursive: true);
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
  });

  // ── linkKotlinPlugin — import + register injection ────────────────────────────

  group('linkKotlinPlugin', () {
    Directory ktDir(Directory base) =>
        Directory(p.join(base.path, 'android', 'src', 'main', 'kotlin', 'dev', 'test'))
          ..createSync(recursive: true);

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

      linkKotlinPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      expect(content, contains('import nitro.math_module.MathJniBridge'));
      expect(content, contains('MathJniBridge.register(MathImpl())'));
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

      linkKotlinPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path);

      final plugin = File(p.join(ktImplDir.path, 'TestPlugin.kt'));
      final content = plugin.readAsStringSync();
      expect(content, contains('MathJniBridge.register(MathImpl(binding.applicationContext))'));
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

      linkKotlinPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path);

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

      linkKotlinPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path);

      final content = plugin.readAsStringSync();
      // import must appear after FlutterPlugin import
      final flutterIdx = content.indexOf('import io.flutter');
      final nitroIdx = content.indexOf('import nitro.math_module.MathJniBridge');
      expect(nitroIdx, greaterThan(flutterIdx));
    });

    test('no-op when no Plugin.kt file found in android/', () {
      expect(
        () => linkKotlinPlugin('my_plugin', [{'module': 'Math', 'lib': 'math'}], baseDir: tmp.path),
        returnsNormally,
      );
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
      final stale = File(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'HybridBenchmark.cpp'))
        ..writeAsStringSync('// stale');
      // Plant bridge files for the windows-only module.
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))
        ..createSync(recursive: true);
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

      expect(stale.existsSync(), isFalse,
          reason: 'Windows-only forwarder must be removed from ios/Sources — it has no iOS implementation');
    });

    test('keeps Hybrid*.cpp forwarder for Apple cpp module', () {
      scaffoldSpmFull('my_plugin');

      // Scaffold the Apple-cpp module.
      final genCpp = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'cpp'))
        ..createSync(recursive: true);
      File(p.join(genCpp.path, 'gpu.bridge.g.cpp')).writeAsStringSync('// bridge');
      File(p.join(genCpp.path, 'gpu.bridge.g.h')).writeAsStringSync('// header');
      Directory(p.join(tmp.path, 'src')).createSync();
      File(p.join(tmp.path, 'src', 'HybridGpu.cpp')).writeAsStringSync('// impl');

      final specDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(specDir.path, 'gpu.native.dart')).writeAsStringSync(
        "@NitroModule(lib: 'gpu', ios: AppleNativeImpl.cpp, macos: AppleNativeImpl.cpp)\n"
        'abstract class Gpu extends HybridObject {}\n',
      );

      linkPodspec(
        'my_plugin',
        ['my_plugin', 'gpu'],
        baseDir: tmp.path,
        moduleInfos: [const ModuleInfo(lib: 'gpu', module: 'Gpu', isCpp: true)],
      );

      final forwarder = File(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'HybridGpu.cpp'));
      expect(forwarder.existsSync(), isTrue,
          reason: 'Apple C++ module must have a Hybrid*.cpp forwarder in ios/Sources/');
      expect(forwarder.readAsStringSync(), contains('#include "../../../../src/HybridGpu.cpp"'));
    });
  });
}

