// Web (WASM) build wiring: PlatformTargetAnalyzer.supportsWeb, the
// build-script template, and linkWeb's file-system effects.
import 'dart:io';

import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('PlatformTargetAnalyzer.supportsWeb', () {
    test('matches web: NativeImpl.wasm and WebNativeImpl.wasm', () {
      expect(
        PlatformTargetAnalyzer.fromContent('@NitroModule(lib: "x", web: NativeImpl.wasm)').supportsWeb,
        isTrue,
      );
      expect(
        PlatformTargetAnalyzer.fromContent('@NitroModule(ios: AppleNativeImpl.swift, web: WebNativeImpl.wasm)').supportsWeb,
        isTrue,
      );
    });

    test('no web target → false', () {
      expect(
        PlatformTargetAnalyzer.fromContent('@NitroModule(ios: AppleNativeImpl.swift)').supportsWeb,
        isFalse,
      );
    });
  });

  group('webBuildScriptTemplate', () {
    test('one em++ block per lib with the verified flag set', () {
      final script = webBuildScriptTemplate(['my_lib', 'other_mod']);
      expect(script, contains('em++ -O2 --no-entry -fwasm-exceptions'));
      expect(script, contains('my_lib.bridge.g.cpp'));
      expect(script, contains('-sEXPORT_NAME=createMyLibModule'));
      expect(script, contains('other_mod.bridge.g.cpp'));
      expect(script, contains('-sEXPORT_NAME=createOtherModModule'));
      expect(script, contains('-sWASM_BIGINT=1'));
      expect(script, contains('-sEXPORTED_RUNTIME_METHODS=addFunction,removeFunction,wasmExports,wasmMemory,HEAPU8'));
      // dart_api_dl.c is VM-only and must never be compiled for web.
      expect(script, contains('grep -v dart_api_dl'));
    });
  });

  group('linkWeb', () {
    test('writes web/build_web.sh + assets/web/ for web modules; no-op otherwise', () {
      final dir = Directory.systemTemp.createTempSync('nitro_linkweb_');
      addTearDown(() => dir.deleteSync(recursive: true));

      // No web module → nothing created.
      expect(
        linkWeb('demo', const [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true)], baseDir: dir.path),
        0,
      );
      expect(File(p.join(dir.path, 'web', 'build_web.sh')).existsSync(), isFalse);

      // Web module → script + asset dir.
      expect(
        linkWeb(
          'demo',
          const [
            ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true),
            ModuleInfo(lib: 'extra', module: 'Extra', isCpp: false),
          ],
          baseDir: dir.path,
        ),
        1,
      );
      final script = File(p.join(dir.path, 'web', 'build_web.sh'));
      expect(script.existsSync(), isTrue);
      expect(script.readAsStringSync(), contains('demo.bridge.g.cpp'));
      expect(script.readAsStringSync(), isNot(contains('extra.bridge.g.cpp')));
      expect(File(p.join(dir.path, 'assets', 'web', '.gitkeep')).existsSync(), isTrue);

      // Re-run refreshes idempotently.
      expect(
        linkWeb('demo', const [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)], baseDir: dir.path),
        1,
      );
    });

    test('declares assets/web/ in pubspec so the .wasm is actually bundled', () {
      // A plugin that adds web AFTER `nitrogen init` would otherwise build the
      // module and never ship it — the failure only shows up at runtime as a
      // 404 from ensure<Class>Ready().
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: demo\n\nflutter:\n  plugin:\n    platforms:\n      web:\n');

      linkWeb('demo', const [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)], baseDir: dir.path);
      expect(pubspec.readAsStringSync(), contains('assets/web/'));

      // Idempotent: a second link must not add a duplicate entry.
      linkWeb('demo', const [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)], baseDir: dir.path);
      expect('assets/web/'.allMatches(pubspec.readAsStringSync()).length, 1);
    });

    test('attaches assets to flutter:, even when it is not the last section', () {
      // Real plugins commonly end with dependency_overrides. Appending at EOF
      // would attach `- assets/web/` to that key and make the pubspec
      // unparseable — `pub get` then fails with "A dependency specification
      // must be a string or a mapping".
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_order');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'))
        ..writeAsStringSync(
          'name: demo\n\n'
          'flutter:\n'
          '  plugin:\n'
          '    platforms:\n'
          '      web:\n\n'
          'dependency_overrides:\n'
          '  nitro:\n'
          '    path: ../nitro\n',
        );

      linkWeb('demo', const [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)], baseDir: dir.path);

      final out = pubspec.readAsStringSync();
      // The entry must sit under flutter:, above dependency_overrides.
      expect(out.indexOf('assets/web/'), lessThan(out.indexOf('dependency_overrides:')));
      expect(out, contains('path: ../nitro'), reason: 'overrides untouched');
      // It must be a direct child of `flutter:` — the line straight after it.
      final lines = out.split('\n');
      final flutterAt = lines.indexOf('flutter:');
      expect(flutterAt, isNonNegative);
      expect(lines[flutterAt + 1], '  assets:');
      expect(lines[flutterAt + 2], '    - assets/web/');
      // And nothing may dangle at end of file under the wrong key.
      expect(out.trimRight().endsWith('path: ../nitro'), isTrue);
    });

    test('scaffolds the browser-test harness and its dev dependencies', () {
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_tests');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: demo\n\ndev_dependencies:\n  build_runner: ^2.4.0\n\nflutter:\n');

      linkWeb('demo', const [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)], baseDir: dir.path);

      final server = File(p.join(dir.path, 'test', 'asset_server.dart'));
      expect(server.existsSync(), isTrue);
      // Must serve the CLI's asset convention with the wasm MIME type, or
      // instantiateStreaming refuses the module.
      expect(server.readAsStringSync(), contains('assets/web/'));
      expect(server.readAsStringSync(), contains("ContentType('application', 'wasm')"));

      final stub = File(p.join(dir.path, 'test', 'demo_web_test.dart'));
      expect(stub.existsSync(), isTrue);
      expect(stub.readAsStringSync(), contains("@TestOn('browser')"));
      expect(stub.readAsStringSync(), contains('ensureDemoReady'));
      expect(stub.readAsStringSync(), contains('demo.js'));
      // The shim is imported directly — a barrel may not re-export it.
      expect(stub.readAsStringSync(), contains("src/demo.platform.g.dart"));

      final out = pubspec.readAsStringSync();
      expect(out, contains('test: ^'), reason: 'the runner for -p chrome');
      expect(out, contains('stream_channel: ^'), reason: 'hybrid isolate channel');
      expect(out, contains('build_runner: ^2.4.0'), reason: 'existing deps preserved');
    });

    test('imports use the PACKAGE name, not the module lib name', () {
      // These differ in practice: the benchmark package is `benchmark` while
      // its module lib is `benchmark_cpp`. Deriving the import from the lib
      // name produced `package:benchmark_cpp/...`, which does not resolve —
      // the generated test could never compile.
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_pkgname');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: benchmark\n\ndev_dependencies:\n\nflutter:\n');

      linkWeb(
        'benchmark',
        const [ModuleInfo(lib: 'benchmark_cpp', module: 'BenchmarkCpp', isCpp: true, webIsWasm: true)],
        baseDir: dir.path,
      );

      final stub = File(p.join(dir.path, 'test', 'benchmark_cpp_web_test.dart')).readAsStringSync();
      expect(stub, contains("import 'package:benchmark/benchmark.dart';"));
      expect(stub, contains("import 'package:benchmark/src/benchmark_cpp.platform.g.dart';"));
      expect(stub, isNot(contains('package:benchmark_cpp/')));
      // The module/asset names still follow the LIB name.
      expect(stub, contains('benchmark_cpp.js'));
      expect(stub, contains('ensureBenchmarkCppReady'));
    });

    test('never overwrites an author-edited web test', () {
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_keep');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n\ndev_dependencies:\n\nflutter:\n');
      const mods = [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)];

      linkWeb('demo', mods, baseDir: dir.path);
      final stub = File(p.join(dir.path, 'test', 'demo_web_test.dart'));
      stub.writeAsStringSync('// my real tests\n');

      linkWeb('demo', mods, baseDir: dir.path);
      expect(stub.readAsStringSync(), '// my real tests\n',
          reason: 'the starter is scaffolding, not a managed file');
      // The server IS managed boilerplate and stays refreshed.
      expect(File(p.join(dir.path, 'test', 'asset_server.dart')).readAsStringSync(), contains('hybridMain'));
    });

    test('inserts into an existing assets: list rather than duplicating the key', () {
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_assets2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final pubspec = File(p.join(dir.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: demo\n\nflutter:\n  assets:\n    - assets/images/\n');

      linkWeb('demo', const [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)], baseDir: dir.path);
      final out = pubspec.readAsStringSync();
      expect(out, contains('assets/web/'));
      expect(out, contains('assets/images/'), reason: 'existing entries preserved');
      expect('  assets:'.allMatches(out).length, 1, reason: 'no duplicate assets key');
    });
  });
}
