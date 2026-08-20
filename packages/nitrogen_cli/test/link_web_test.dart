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
      expect(script, contains('-sEXPORTED_RUNTIME_METHODS=addFunction,wasmExports,wasmMemory,HEAPU8'));
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
  });
}
