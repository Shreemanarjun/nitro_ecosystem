// The Emscripten seam in the C++ bridge (0.7.0 web support): a web-targeting
// spec compiles the SAME bridge under emcc — the only differences are the
// compat-header include, the post-fn setter export, and __EMSCRIPTEN__ joining
// the platform guards. Non-web specs must stay byte-free of all of it.
import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/c_bridge/cpp_bridge_generator.dart';
import 'package:test/test.dart';

BridgeSpec _spec({
  NativeImpl? ios,
  NativeImpl? android,
  NativeImpl? windows,
  NativeImpl? web,
}) => BridgeSpec(
  dartClassName: 'WebMod',
  lib: 'web_mod',
  namespace: 'web_mod_module',
  iosImpl: ios,
  androidImpl: android,
  windowsImpl: windows,
  webImpl: web,
  sourceUri: 'web_mod.native.dart',
  functions: [
    BridgeFunction(
      dartName: 'add',
      cSymbol: 'web_mod_add',
      isAsync: false,
      returnType: BridgeType(name: 'double'),
      params: [
        BridgeParam(name: 'a', type: BridgeType(name: 'double')),
        BridgeParam(name: 'b', type: BridgeType(name: 'double')),
      ],
    ),
  ],
);

void main() {
  group('web-targeting specs (WasmImpl)', () {
    test('all-cpp + web: compat include seam and weak post-fn setter', () {
      final out = CppBridgeGenerator.generate(
        _spec(ios: NativeImpl.cpp, android: NativeImpl.cpp, web: NativeImpl.wasm),
      );
      expect(out, contains('#ifdef __EMSCRIPTEN__'));
      expect(out, contains('#include "nitro_wasm_compat.h"'));
      expect(out, contains('#else'));
      expect(out, contains('#include "dart_api_dl.h"'));
      expect(
        out,
        contains('NITRO_EXPORT __attribute__((weak)) void web_mod_nitro_set_post_fn(NitroPostFn fn)'),
      );
      expect(out, contains('g_nitro_post_fn = fn;'));
    });

    test('web-only spec routes through the direct C++ dispatch', () {
      final out = CppBridgeGenerator.generate(_spec(web: NativeImpl.wasm));
      expect(out, contains('shared C++ virtual-dispatch bridge'));
      expect(out, contains('web_mod_nitro_set_post_fn'));
      expect(out, isNot(contains('JNI_OnLoad')), reason: 'no JNI in a web-only bridge');
      // No native platform → no #ifdef platform wrapper at all.
      expect(out, isNot(contains('#ifdef __APPLE__')));
      expect(out, isNot(contains('#ifdef __ANDROID__')));
    });

    test('apple-cpp-only + web widens the platform guard to __EMSCRIPTEN__', () {
      final out = CppBridgeGenerator.generate(
        _spec(ios: NativeImpl.cpp, web: NativeImpl.wasm),
      );
      expect(out, contains('#if defined(__APPLE__) || defined(__EMSCRIPTEN__)'));
      expect(out, contains('#endif // __APPLE__ || __EMSCRIPTEN__'));
    });

    test('mixed kotlin + web joins the standalone C++ dispatch as an #elif', () {
      final out = CppBridgeGenerator.generate(
        _spec(android: NativeImpl.kotlin, web: NativeImpl.wasm),
      );
      expect(out, contains('#elif defined(__EMSCRIPTEN__)'));
      expect(out, contains('web_mod_nitro_set_post_fn'));
      // The direct dispatch section pulls in the C++ interface header.
      expect(out, contains('#include "web_mod.native.g.h"'));
    });

    test('mixed kotlin + windows-cpp + web merges all standalone guards', () {
      final out = CppBridgeGenerator.generate(
        _spec(android: NativeImpl.kotlin, windows: NativeImpl.cpp, web: NativeImpl.wasm),
      );
      expect(out, contains('#elif defined(_WIN32) || defined(__EMSCRIPTEN__)'));
    });
  });

  group('non-web specs stay untouched (byte-identical output)', () {
    test('all-cpp without web has no emscripten seam', () {
      final out = CppBridgeGenerator.generate(
        _spec(ios: NativeImpl.cpp, android: NativeImpl.cpp),
      );
      expect(out, isNot(contains('__EMSCRIPTEN__')));
      expect(out, isNot(contains('nitro_wasm_compat')));
      expect(out, isNot(contains('nitro_set_post_fn')));
      expect(out, contains('#include "dart_api_dl.h"'));
    });

    test('mixed kotlin+windows keeps the historical guard comment', () {
      final out = CppBridgeGenerator.generate(
        _spec(android: NativeImpl.kotlin, windows: NativeImpl.cpp),
      );
      expect(
        out,
        contains('#elif defined(_WIN32)  // Windows/Linux: NativeImpl.cpp — direct C++ dispatch'),
      );
      expect(out, isNot(contains('__EMSCRIPTEN__')));
    });

    test('apple-cpp-only without web keeps the historical #ifdef spelling', () {
      final out = CppBridgeGenerator.generate(_spec(ios: NativeImpl.cpp));
      expect(out, contains('#ifdef __APPLE__    // iOS + macOS'));
      expect(out, contains('#endif // __APPLE__  // iOS + macOS'));
    });
  });
}
