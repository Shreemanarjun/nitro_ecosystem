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

    test('stamps each lib with the generator bridge checksum, shebang first', () {
      final script = webBuildScriptTemplate(
        ['my_lib', 'other_mod'],
        bridgeChecksums: const {'my_lib': 'deadbeefcafef00d', 'other_mod': '0123456789abcdef'},
      );
      // A comment ahead of #! would stop the kernel treating this as bash.
      expect(script.split('\n').first, '#!/usr/bin/env bash');
      expect(script, contains('# NITRO_BRIDGE_CHECKSUM my_lib deadbeefcafef00d'));
      expect(script, contains('# NITRO_BRIDGE_CHECKSUM other_mod 0123456789abcdef'));
      expect(stampedBridgeChecksums(script),
          {'my_lib': 'deadbeefcafef00d', 'other_mod': '0123456789abcdef'});
    });

    test('compiles a web-specific impl for only the libs that opted in', () {
      final script = webBuildScriptTemplate(['my_lib', 'other_mod'], webSpecificImpls: const {'my_lib'});
      final blocks = script.split('em++');
      final mine = blocks.firstWhere((b) => b.contains('my_lib.bridge.g.cpp'));
      final other = blocks.firstWhere((b) => b.contains('other_mod.bridge.g.cpp'));
      expect(mine, contains('web/src/HybridMyLib.cpp'));
      expect(mine, isNot(contains(r'$IMPL_SOURCES')), reason: 'must not also link the shared impl — duplicate registration');
      expect(other, contains(r'$IMPL_SOURCES'));
      expect(other, isNot(contains('web/src/')));
    });

    test('marks a lib unavailable rather than emitting an empty checksum', () {
      // An empty value would read as a real checksum and never match, so
      // doctor would nag forever instead of saying the bridge is ungenerated.
      final script = webBuildScriptTemplate(['my_lib']);
      expect(script, contains('# NITRO_BRIDGE_CHECKSUM my_lib unavailable'));
      expect(stampedBridgeChecksums(script), {'my_lib': 'unavailable'});
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

    test('stamps build_web.sh with the generator bridge checksum and refreshes it', () {
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_stamp');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n\nflutter:\n');
      // The generated C++ is the source of truth the stamp must mirror.
      final cpp = Directory(p.join(dir.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      final bridge = File(p.join(cpp.path, 'demo.bridge.g.cpp'))
        ..writeAsStringSync('NITRO_EXPORT const char* demo_nitro_bridge_checksum(void) {\n    return "1111aaaa2222bbbb";\n}\n');
      const mods = [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)];

      linkWeb('demo', mods, baseDir: dir.path);
      final script = File(p.join(dir.path, 'web', 'build_web.sh'));
      expect(stampedBridgeChecksums(script.readAsStringSync()), {'demo': '1111aaaa2222bbbb'},
          reason: 'the stamp is the generator constant, not a hash of spec text');

      // Regenerating with a changed ABI must move the stamp on the next link.
      bridge.writeAsStringSync('NITRO_EXPORT const char* demo_nitro_bridge_checksum(void) {\n    return "3333cccc4444dddd";\n}\n');
      expect(readBridgeChecksum(dir.path, 'demo'), '3333cccc4444dddd');
      linkWeb('demo', mods, baseDir: dir.path);
      expect(stampedBridgeChecksums(script.readAsStringSync()), {'demo': '3333cccc4444dddd'});
    });

    test('stamp is unavailable when the bridge has not been generated yet', () {
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_nobridge');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n\nflutter:\n');

      linkWeb('demo', const [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)], baseDir: dir.path);
      // link may legitimately run before generate; that must not crash or
      // bake in a wrong value.
      expect(readBridgeChecksum(dir.path, 'demo'), isNull);
      expect(stampedBridgeChecksums(File(p.join(dir.path, 'web', 'build_web.sh')).readAsStringSync()),
          {'demo': 'unavailable'});
    });

    test('drops an inert web/src stub and keeps sharing until it holds real code', () {
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_impl');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n\nflutter:\n');
      const mods = [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)];
      final script = File(p.join(dir.path, 'web', 'build_web.sh'));
      final stub = File(p.join(dir.path, 'web', 'src', 'HybridDemo.cpp'));

      linkWeb('demo', mods, baseDir: dir.path);
      expect(stub.existsSync(), isTrue);
      expect(stub.readAsStringSync(), contains('TODO: implement all pure-virtual methods declared in HybridDemo'));
      expect(stub.readAsStringSync(), contains('#include "../../lib/src/generated/cpp/demo.native.g.h"'),
          reason: 'one directory deeper than src/, like linux/src');
      expect(webUsesSpecificImpl(dir.path, 'demo'), isFalse);
      expect(script.readAsStringSync(), contains(r'$IMPL_SOURCES'));
      expect(script.readAsStringSync(), isNot(contains('web/src/HybridDemo.cpp')));

      // A comments-only file is not an opt-in (issue #12's detection note).
      stub.writeAsStringSync('// notes about what web will need\n/* later */\n');
      linkWeb('demo', mods, baseDir: dir.path);
      expect(webUsesSpecificImpl(dir.path, 'demo'), isFalse);
      expect(script.readAsStringSync(), isNot(contains('web/src/HybridDemo.cpp')));
      expect(stub.readAsStringSync(), '// notes about what web will need\n/* later */\n',
          reason: 'the author\'s file is never overwritten, even without the marker');

      // Real code flips this module — and only this module — to web/src.
      stub.writeAsStringSync('#include "../../lib/src/generated/cpp/demo.native.g.h"\nclass HybridDemoImpl final : public HybridDemo {};\n');
      linkWeb('demo', mods, baseDir: dir.path);
      expect(webUsesSpecificImpl(dir.path, 'demo'), isTrue);
      expect(script.readAsStringSync(), contains('"\$GEN/demo.bridge.g.cpp" web/src/HybridDemo.cpp'));
      expect(script.readAsStringSync(), isNot(contains(r'$IMPL_SOURCES \\')));
      expect(stub.readAsStringSync(), startsWith('#include'), reason: 'still the author\'s bytes');
    });

    test('seeds web/src from the generated impl starter, inert until the marker line goes', () {
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_seed');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n\nflutter:\n');
      final cpp = Directory(p.join(dir.path, 'lib', 'src', 'generated', 'cpp'))..createSync(recursive: true);
      File(p.join(cpp.path, 'demo.impl.g.cpp')).writeAsStringSync([
        '// Generated by Nitrogen — edit this file to implement Demo.',
        '// Rename it to e.g. "DemoImpl.cpp" and add it to CMakeLists.txt.',
        '//',
        '// Ownership conventions:',
        '//   • records transfer ownership',
        '',
        '#include "demo.native.g.h"',
        'class DemoImpl final : public HybridDemo {',
        'public:',
        '    int64_t foo(int64_t v) override {',
        '        // TODO: implement foo',
        '        throw std::runtime_error("Not implemented: foo");',
        '    }',
        '};',
        '',
      ].join('\n'));
      const mods = [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)];
      final stub = File(p.join(dir.path, 'web', 'src', 'HybridDemo.cpp'));
      final script = File(p.join(dir.path, 'web', 'build_web.sh'));

      linkWeb('demo', mods, baseDir: dir.path);
      final seeded = stub.readAsStringSync();
      expect(seeded, contains('int64_t foo(int64_t v) override'), reason: 'every spec method, with its signature');
      expect(seeded, contains('// Ownership conventions:'));
      expect(seeded, isNot(contains('add it to CMakeLists.txt')), reason: 'desktop quick-start does not apply to wasm');
      expect(seeded, contains('demo_register_impl(new DemoImpl())'), reason: 'wasm has no plugin-init hook; self-register');
      expect(seeded, contains('TODO: implement all pure-virtual methods declared in HybridDemo'));
      // Real code, but still inert: the marker keeps web on the shared impl.
      expect(webUsesSpecificImpl(dir.path, 'demo'), isFalse);
      expect(script.readAsStringSync(), isNot(contains('web/src/HybridDemo.cpp')));

      // The documented opt-in: delete the marker line, re-link.
      stub.writeAsStringSync(seeded.split('\n').where((l) => !l.contains('TODO: implement all pure-virtual')).join('\n'));
      linkWeb('demo', mods, baseDir: dir.path);
      expect(webUsesSpecificImpl(dir.path, 'demo'), isTrue);
      expect(script.readAsStringSync(), contains('web/src/HybridDemo.cpp'));
      expect(stub.readAsStringSync(), contains('int64_t foo(int64_t v) override'), reason: 'never re-seeded');
    });

    test('never overwrites an author-edited web test', () {
      final dir = Directory.systemTemp.createTempSync('nitro_link_web_keep');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n\ndev_dependencies:\n\nflutter:\n');
      const mods = [ModuleInfo(lib: 'demo', module: 'Demo', isCpp: true, webIsWasm: true)];

      linkWeb('demo', mods, baseDir: dir.path);
      final stub = File(p.join(dir.path, 'test', 'demo_web_test.dart'));
      stub.writeAsStringSync('// my real tests\n');

      final server = File(p.join(dir.path, 'test', 'asset_server.dart'));
      server.writeAsStringSync('// my server, with an auth route\n');

      linkWeb('demo', mods, baseDir: dir.path);
      expect(stub.readAsStringSync(), '// my real tests\n',
          reason: 'the starter is scaffolding, not a managed file');
      // Authors extend the server too (auth headers, extra routes, fixtures).
      expect(server.readAsStringSync(), '// my server, with an auth route\n',
          reason: 'the asset server is the author\'s file after the first link');
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
