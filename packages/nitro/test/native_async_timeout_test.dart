// openNativeAsync resilience (leak-audit finding #2): if the native side never
// posts a result, the call must not hang or leak the ReceivePort + per-call
// error slot forever. A configurable timeout completes the Future with a
// TimeoutException and runs `cleanup` (which frees the slot) on every terminal
// path — success, native error, or timeout.
import 'dart:async';

import 'package:nitro/src/nitro_runtime.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() => NitroConfig.instance.reset());

  test('nativeAsyncTimeoutMs defaults to 0 (wait indefinitely) and resets', () {
    expect(NitroConfig.instance.nativeAsyncTimeoutMs, 0);
    NitroConfig.instance.nativeAsyncTimeoutMs = 500;
    NitroConfig.instance.reset();
    expect(NitroConfig.instance.nativeAsyncTimeoutMs, 0);
  });

  test('times out when native never posts, and runs cleanup', () async {
    NitroConfig.instance.nativeAsyncTimeoutMs = 40;
    var cleaned = false;
    final future = NitroRuntime.openNativeAsync<int>(
      call: (port) {}, // never posts a message to the port
      unpack: (raw) => raw as int,
      cleanup: () => cleaned = true,
      methodName: 'neverPosts',
    );
    await expectLater(future, throwsA(isA<TimeoutException>()));
    // cleanup (frees the slot) + port close happen in whenComplete, so let the
    // microtask/timer queue drain before asserting.
    await Future<void>.delayed(Duration.zero);
    expect(cleaned, isTrue, reason: 'cleanup must run on the timeout path');
  });

  test('cleanup runs and the error rethrows synchronously when call() throws', () {
    var cleaned = false;
    expect(
      () => NitroRuntime.openNativeAsync<int>(
        call: (port) => throw StateError('native call failed to dispatch'),
        unpack: (raw) => raw as int,
        cleanup: () => cleaned = true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(cleaned, isTrue, reason: 'cleanup must run when call() throws');
  });

  test('a longer timeout does not fire when the call settles first (call throws)', () async {
    // A generous timeout must not spuriously fire for a call that terminates
    // synchronously (here via a throwing call()).
    NitroConfig.instance.nativeAsyncTimeoutMs = 10000;
    var cleaned = false;
    expect(
      () => NitroRuntime.openNativeAsync<int>(
        call: (port) => throw StateError('boom'),
        unpack: (raw) => raw as int,
        cleanup: () => cleaned = true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(cleaned, isTrue);
    // If a stray Timer were left pending it would keep the test alive; the
    // synchronous throw path never arms one.
  });
}
