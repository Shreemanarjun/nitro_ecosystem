import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:test/test.dart';

// Runs [fn] with the working directory temporarily set to [dir].
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

      _withDir(tmp, () {
        final modules = discoverModules('plugin_name');
        expect(modules, hasLength(1));
        expect(modules.first['lib'], equals('my_lib'));
        expect(modules.first['module'], equals('MyModule'));
      });
    });

    test('defaults to plugin name when no specs found', () {
      _withDir(tmp, () {
        final modules = discoverModules('plugin_name');
        expect(modules, hasLength(1));
        expect(modules.first['lib'], equals('plugin_name'));
        expect(modules.first['module'], equals('plugin_name'));
      });
    });

    test('extracts multiple modules correctly', () {
      final libDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      
      File(p.join(libDir.path, 'a.native.dart')).writeAsStringSync('''
@NitroModule(lib: "libA")
abstract class ModuleA extends HybridObject {}
''');
      File(p.join(libDir.path, 'b.native.dart')).writeAsStringSync('''
@NitroModule(lib: "libB")
abstract class ModuleB extends HybridObject {}
''');

      _withDir(tmp, () {
        final modules = discoverModules('plugin_name');
        expect(modules, hasLength(2));
        final libNames = modules.map((m) => m['lib']).toList();
        expect(libNames, containsAll(['libA', 'libB']));
      });
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
}
