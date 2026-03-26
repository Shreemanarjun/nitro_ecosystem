import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nitro_link_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
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
