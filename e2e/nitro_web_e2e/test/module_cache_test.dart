// loadWebModule shares one fetch between concurrent callers. Two edge cases
// used to be wrong:
//   * the in-flight entry was only cleared on SUCCESS, so a single transient
//     failure (bad URL, network blip) made every later retry replay that same
//     rejection forever;
//   * the refcount was incremented once INSIDE the shared load, so N
//     concurrent callers produced ONE reference and the first releaseLib
//     evicted a module the others were still using.
@TestOn('browser')
library;

// NitroRuntime is CONDITIONALLY exported by package:nitro — analysis resolves
// the VM branch, where loadWebModule/webModule do not exist, so importing the
// barrel here compiles under `-p chrome` but leaves `dart analyze` errors.
// Import the web runtime directly, as int64_boundary_test.dart does.
import 'package:nitro/src/web/nitro_runtime_web.dart' show NitroRuntime;
import 'package:test/test.dart';

void main() {
  // The factory export name is derived from libName, so these must use the
  // module actually built by tool/build_wasm.sh.
  const lib = 'web_echo';
  late String goodUrl;

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    final port = ((await channel.stream.first)! as num).toInt();
    goodUrl = 'http://localhost:$port/web_echo.js';
  });

  tearDown(() {
    // Drain every reference so each test starts from an unloaded module.
    for (var i = 0; i < 8; i++) {
      NitroRuntime.releaseLib(lib);
    }
  });

  test('a failed load does not poison the cache — a retry can succeed', () async {
    await expectLater(
      NitroRuntime.loadWebModule(lib, jsUrl: 'http://localhost:1/nope.js'),
      throwsA(anything),
    );
    // Same libName, now with a URL that works: must NOT replay the failure.
    expect(await NitroRuntime.loadWebModule(lib, jsUrl: goodUrl), isNotNull);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('concurrent loads each hold their own reference', () async {
    final loads = await Future.wait([
      NitroRuntime.loadWebModule(lib, jsUrl: goodUrl),
      NitroRuntime.loadWebModule(lib, jsUrl: goodUrl),
      NitroRuntime.loadWebModule(lib, jsUrl: goodUrl),
    ]);
    expect(identical(loads[0], loads[2]), isTrue, reason: 'one fetch shared by all callers');

    // Two releases must NOT evict — a third holder is still using it.
    NitroRuntime.releaseLib(lib);
    NitroRuntime.releaseLib(lib);
    expect(
      () => NitroRuntime.webModule(lib),
      returnsNormally,
      reason: 'evicted while a third caller still held a reference',
    );
  }, timeout: const Timeout(Duration(seconds: 40)));
}
