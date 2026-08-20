// End-to-end browser test for nitro's WASM web bridge: drives the REAL
// generated web bridge against the REAL C++ impl compiled by Emscripten.
//
// Run under both compilers (tool/build_wasm.sh must have been run first):
//   dart test -p chrome
//   dart test -p chrome -c dart2wasm
@TestOn('browser')
library;

import 'dart:async';

import 'package:nitro/nitro.dart';
import 'package:nitro_web_e2e/nitro_web_e2e.dart';
import 'package:test/test.dart';

void main() {
  late WebEcho echo;

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    // dart2wasm deserializes JS numbers as double — never `as int` here.
    final port = ((await channel.stream.first)! as num).toInt();
    await ensureWebEchoReady(jsUrl: 'http://localhost:$port/web_echo.js');
    echo = WebEcho.instance;
  });

  group('sync calls', () {
    test('double round-trip', () {
      expect(echo.addDouble(1.25, 2.25), 3.5);
    });

    test('int64 round-trip (BigInt boundary)', () {
      expect(echo.addInt(1, 2), 3);
      expect(echo.addInt(-5, 2), -3);
      expect(echo.addInt(1 << 40, 1), (1 << 40) + 1);
    });

    test('bool round-trip', () {
      expect(echo.negate(true), isFalse);
      expect(echo.negate(false), isTrue);
    });

    test('string round-trip incl. unicode', () {
      expect(echo.concat('héllo ', 'wörld ⚡'), 'héllo wörld ⚡');
      expect(echo.concat('', ''), '');
    });

    test('nullable int: value and null both survive', () {
      expect(echo.echoNullableInt(42), 42);
      expect(echo.echoNullableInt(-1), -1);
      expect(echo.echoNullableInt(null), isNull);
    });

    test('enum round-trip', () {
      expect(echo.echoEnum(EchoLevel.high), EchoLevel.high);
      expect(echo.echoEnum(EchoLevel.low), EchoLevel.low);
    });

    test('typed data (@zeroCopy): payload crosses both ways', () {
      final input = Uint8List.fromList([0, 1, 2, 250, 255]);
      final out = echo.echoBytes(input);
      expect(out, [1, 2, 3, 251, 0]); // C++ increments every byte (mod 256)
    });

    test('record round-trip: every field transformed by C++', () {
      final out = echo.echoStat(
        const EchoStat(count: 41, mean: 1.5, label: 'run', ok: false),
      );
      expect(out.count, 42);
      expect(out.mean, 3.0);
      expect(out.label, 'run!');
      expect(out.ok, isTrue);
    });

    test('Map<String,int> round-trip: values incremented', () {
      final out = echo.incrementValues({'a': 1, 'b': -7, 'unicode ⚡': 0});
      expect(out, {'a': 2, 'b': -6, 'unicode ⚡': 1});
    });

    test('property get/set', () {
      echo.counter = 7;
      expect(echo.counter, 7);
      echo.counter = -3;
      expect(echo.counter, -3);
    });
  });

  group('errors', () {
    test('C++ exception surfaces as HybridException with message', () {
      expect(
        () => echo.alwaysThrows(),
        throwsA(
          isA<HybridException>().having(
            (e) => e.message,
            'message',
            contains('boom from wasm'),
          ),
        ),
      );
    });

    test('the error slot resets — next call succeeds', () {
      expect(() => echo.alwaysThrows(), throwsA(isA<HybridException>()));
      expect(echo.addDouble(1, 1), 2.0);
    });
  });

  group('async', () {
    test('@nitroAsync runs inline and returns', () async {
      expect(await echo.sumTo(100), 4950);
    });

    test('@nitroNativeAsync completes through the post callback', () async {
      expect(await echo.nativeAsyncEcho(21), 42);
    });

    test('concurrent native-async calls all complete', () async {
      final results = await Future.wait([
        for (var i = 0; i < 10; i++) echo.nativeAsyncEcho(i),
      ]);
      expect(results, [for (var i = 0; i < 10; i++) i * 2]);
    });
  });

  group('streams', () {
    test('items posted from C++ arrive in order', () async {
      final received = <int>[];
      final sub = echo.ticks.listen(received.add);
      echo.emitTicks(5);
      // Delivery is microtask-deferred; give the event loop a turn.
      await Future<void>.delayed(Duration.zero);
      expect(received, [0, 1, 2, 3, 4]);
      await sub.cancel();
    });

    test('cancel releases the port — later emits are dropped', () async {
      final received = <int>[];
      final sub = echo.ticks.listen(received.add);
      echo.emitTicks(2);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      echo.emitTicks(3);
      await Future<void>.delayed(Duration.zero);
      expect(received, [0, 1]);
    });
  });
}
