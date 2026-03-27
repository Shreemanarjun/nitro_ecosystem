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
    test('returns true when both iosImpl and androidImpl are NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
import 'package:nitro/nitro.dart';
@NitroModule(lib: "math", iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isTrue);
    });

    test('returns false when only iosImpl is NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.kotlin)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isFalse);
    });

    test('returns false when only androidImpl is NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", iosImpl: NativeImpl.swift, androidImpl: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isFalse);
    });

    test('returns false when neither impl is NativeImpl.cpp', () {
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "math", iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin)
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

    test('returns false when NativeImpl.cpp appears only once in annotation', () {
      // Edge case: someone writes the lib name as "NativeImpl.cpp" — still only one occurrence
      final spec = _writeSpec(_libDir(tmp), 'math.native.dart', '''
@NitroModule(lib: "NativeImpl.cpp", androidImpl: NativeImpl.kotlin)
abstract class Math extends HybridObject {}
''');
      expect(isCppModule(spec), isFalse);
    });
  });

  // ── discoverModuleInfos ──────────────────────────────────────────────────────

  group('discoverModuleInfos', () {
    test('sets isCpp=true for NativeImpl.cpp spec', () {
      final libDir = _libDir(tmp);
      _writeSpec(libDir, 'math.native.dart', '''
@NitroModule(lib: "math", iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp)
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
@NitroModule(lib: "math", iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin)
abstract class Math extends HybridObject {}
''');
      final modules = discoverModuleInfos('plugin_name', baseDir: tmp.path);
      expect(modules, hasLength(1));
      expect(modules.first.isCpp, isFalse);
    });

    test('handles mixed cpp and kotlin modules in same project', () {
      final libDir = _libDir(tmp);
      _writeSpec(libDir, 'math.native.dart', '''
@NitroModule(lib: "math", iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      _writeSpec(libDir, 'utils.native.dart', '''
@NitroModule(lib: "utils", iosImpl: NativeImpl.swift, androidImpl: NativeImpl.kotlin)
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
@NitroModule(lib: "math", iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      final subDir = Directory(p.join(libDir.path, 'sub'))..createSync();
      _writeSpec(subDir, 'math.native.dart', '''
@NitroModule(lib: "math", iosImpl: NativeImpl.cpp, androidImpl: NativeImpl.cpp)
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
      linkCppImplStubs([ModuleInfo(lib: 'math', module: 'Math', isCpp: true)], baseDir: tmp.path);
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
      linkCppImplStubs([ModuleInfo(lib: 'math', module: 'Math', isCpp: true)], baseDir: tmp.path);
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
        ModuleInfo(lib: 'math', module: 'Math', isCpp: true),
        ModuleInfo(lib: 'crypto', module: 'Crypto', isCpp: true),
      ], baseDir: tmp.path);
      expect(File(p.join(tmp.path, 'src', 'HybridMath.cpp')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'src', 'HybridCrypto.cpp')).existsSync(), isTrue);
    });

    test('lib name with underscores produces correct PascalCase class name', () {
      Directory(p.join(tmp.path, 'src')).createSync();
      linkCppImplStubs([ModuleInfo(lib: 'my_math_lib', module: 'MyMathLib', isCpp: true)], baseDir: tmp.path);
      final stub = File(p.join(tmp.path, 'src', 'HybridMyMathLib.cpp'));
      expect(stub.existsSync(), isTrue);
      expect(stub.readAsStringSync(), contains('my_math_lib_register_impl'));
    });
  });

  // ── linkKotlinLoadLibraries ───────────────────────────────────────────────────

  group('linkKotlinLoadLibraries', () {
    File writeKotlinPlugin(Directory tmp, String content) {
      final dir = Directory(p.join(tmp.path, 'android', 'src', 'main', 'kotlin', 'dev', 'test'))
        ..createSync(recursive: true);
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
  });
}
