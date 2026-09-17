// NitroCompletionBatch: the Dart half of shared-port completion batching.
// The "native" side is simulated by sending [id, value, ...] arrays to the
// batch port and recording bind/ack calls.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nitro/nitro.dart';

void main() {
  test('ids come from bind, batches demux by id, and every batch is acked once', () async {
    var nextId = 100;
    final binds = <int>[];
    final acks = <int>[];
    final batch = NitroCompletionBatch(bind: (port) { binds.add(port); return nextId++; }, ack: acks.add);
    final got = <int, dynamic>{};
    final a = batch.register((raw) => got[100] = raw);
    final b = batch.register((raw) => got[101] = raw);
    final c = batch.register((raw) => got[102] = raw);
    expect([a, b, c], [100, 101, 102]);
    expect(binds, [batch.nativePort, batch.nativePort, batch.nativePort]);
    final send = batch.sendPort;
    // One lone completion, then a two-call batch, as the C++ side would send.
    send.send([102, 'c']);
    send.send([100, 1, 101, 2.5]);
    await Future<void>.delayed(Duration.zero);
    expect(got, {102: 'c', 100: 1, 101: 2.5});
    expect(acks, [batch.nativePort, batch.nativePort], reason: 'one ack per message, not per completion');
    expect(batch.pendingCount, 0);
  });

  test('a forgotten (timed-out) id is ignored but still acked; unknown ids never throw', () async {
    final acks = <int>[];
    final batch = NitroCompletionBatch(bind: (_) => 7, ack: acks.add);
    var called = false;
    batch.register((_) => called = true);
    batch.forget(7);
    batch.sendPort.send([7, 'late', 999, 'unknown']);
    await Future<void>.delayed(Duration.zero);
    expect(called, isFalse);
    expect(acks, hasLength(1));
  });

  test('openNativeAsync with a batch resolves through it, keeps unpack errors as future errors, and honours the timeout', () async {
    var seq = 0;
    final acks = <int>[];
    final batch = NitroCompletionBatch(bind: (_) => ++seq, ack: acks.add);
    final send = batch.sendPort;
    final ok = NitroRuntime.openNativeAsync<int>(call: (id) => send.send([id, 41]), unpack: (raw) => (raw as int) + 1, batch: batch);
    expect(await ok, 42);
    final bad = NitroRuntime.openNativeAsync<int>(call: (id) => send.send([id, 'x']), unpack: (raw) => throw StateError('bad $raw'), batch: batch);
    await expectLater(bad, throwsA(isA<StateError>()));
    NitroConfig.instance.nativeAsyncTimeoutMs = 20;
    try {
      final slow = NitroRuntime.openNativeAsync<int>(call: (_) {}, unpack: (raw) => raw as int, batch: batch);
      await expectLater(slow, throwsA(isA<TimeoutException>()));
      expect(batch.pendingCount, 0, reason: 'timed-out id forgotten');
    } finally {
      NitroConfig.instance.reset();
    }
  });
}
