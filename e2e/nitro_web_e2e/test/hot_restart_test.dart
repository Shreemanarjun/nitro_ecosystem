// Hot-restart contract for the bridge's EM_JS ownership helper.
//
// A Flutter hot restart re-runs ensure<Class>Ready() in the SAME JS context,
// instantiating the module a second time while the first instance survives on
// the page. nitro_web_instance_changed() is the ownership claim that lets the
// newest instance's bootstrap stand the old one's emitters down. This test
// simulates the restart by instantiating the module factory a second time and
// reads back the bookkeeping web_echo_impl.cpp records at each boot.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:nitro_web_e2e/nitro_web_e2e.dart';
import 'package:test/test.dart';

int _boot(String key) {
  final g = globalContext.getProperty('__nitroWebEchoBoot'.toJS);
  if (g == null || g.isUndefinedOrNull) fail('__nitroWebEchoBoot missing — the impl bootstrap did not run');
  // dart2wasm surfaces JS numbers as double — go through num.
  return ((g as JSObject).getProperty(key.toJS)! as JSNumber).toDartDouble.toInt();
}

void main() {
  late WebEcho echo;

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    final port = ((await channel.stream.first)! as num).toInt();
    await ensureWebEchoReady(jsUrl: 'http://localhost:$port/web_echo.js');
    echo = WebEcho.instance;
  });

  test('first boot claims ownership exactly once', () {
    expect(_boot('boots'), 1);
    expect(_boot('claims'), 1, reason: 'nitro_web_instance_changed() must return 1 on the first call');
    expect(_boot('repeats'), 0, reason: 'and 0 on every later call from the same instance');
    final reg = globalContext.getProperty('__nitroInstances'.toJS);
    expect(reg, isNotNull);
    expect((reg! as JSObject).getProperty('web_echo'.toJS), isNotNull);
  });

  test('a second instantiation (simulated hot restart) claims ownership anew', () async {
    final factory = globalContext.getProperty('createWebEchoModule'.toJS)! as JSFunction;
    await (factory.callAsFunction(null, JSObject())! as JSPromise<JSAny?>).toDart;

    expect(_boot('boots'), 2);
    expect(_boot('claims'), 2, reason: 'each NEW instance sees changed=1 once');
    expect(_boot('repeats'), 0);
    // The Dart-wired first instance keeps answering — the claim stands down
    // self-driven emitters, not calls through a held module reference.
    expect(echo.addInt(20, 22), 42);
  });
}
