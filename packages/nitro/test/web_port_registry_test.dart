// The web port registry replaces SendPort.nativePort: C posts through a
// function-table callback carrying an int64 port id, and the runtime looks the
// handler up here. Pure Dart, so it runs on the VM — no browser needed.
import 'package:nitro/src/web/nitro_coalescer_web.dart' as web;
import 'package:nitro/src/web/port_registry.dart';
import 'package:test/test.dart';

void main() {
  group('NitroWebPorts', () {
    test('allocates distinct nonzero ids and delivers to the right handler', () {
      final got = <int, List<dynamic>>{};
      final a = NitroWebPorts.allocate((raw) => (got[1] ??= []).add(raw));
      final b = NitroWebPorts.allocate((raw) => (got[2] ??= []).add(raw));
      addTearDown(() {
        NitroWebPorts.close(a);
        NitroWebPorts.close(b);
      });

      expect(a, isNot(0), reason: 'port 0 is reserved');
      expect(a, isNot(b));

      expect(NitroWebPorts.deliver(a, 'for-a'), isTrue);
      expect(NitroWebPorts.deliver(b, 'for-b'), isTrue);
      expect(got[1], ['for-a']);
      expect(got[2], ['for-b']);
    });

    test('delivery to a closed port is dropped, mirroring Dart_PostCObject', () {
      final port = NitroWebPorts.allocate((_) => fail('must not deliver'));
      NitroWebPorts.close(port);
      expect(NitroWebPorts.deliver(port, 'late'), isFalse);
    });
  });

  group('WebReceivePort', () {
    test('first completes with the first delivered message', () async {
      final port = WebReceivePort();
      NitroWebPorts.deliver(port.sendPort.nativePort, 42);
      expect(await port.first, 42);
      port.close();
    });

    test('listen receives messages in order; close stops delivery', () async {
      final port = WebReceivePort();
      final seen = <dynamic>[];
      port.listen(seen.add);
      port.sendPort
        ..send(1)
        ..send(2);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1, 2]);

      port.close();
      expect(NitroWebPorts.deliver(port.sendPort.nativePort, 3), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [1, 2]);
    });
  });

  group('web NitroCoalescer', () {
    test('demuxes a batch of [callId, value] pairs', () async {
      final c = web.NitroCoalescer();
      final f1 = c.submit((id, port) {});
      final f2 = c.submit((id, port) {});
      expect(c.pendingCount, 2);

      // Inject a batch as the module post callback would (tag 4 payload).
      c.sendPort.send([0, 100, 1, 200]);
      expect(await f1, 100);
      expect(await f2, 200);
      expect(c.pendingCount, 0);
      await c.dispose();
    });

    test('tolerates JS-sourced doubles in the batch (dart2wasm numbers)', () async {
      final c = web.NitroCoalescer();
      final f = c.submit((id, port) {});
      c.sendPort.send(<num>[0.0, 7.0]);
      expect(await f, 7);
      await c.dispose();
    });

    test('dispose settles stragglers with a StateError; submit-after throws', () async {
      final c = web.NitroCoalescer();
      final f = c.submit((id, port) {});
      // Attach the expectation BEFORE disposing: dispose() completes the
      // straggler with its StateError, and if no listener is attached by then
      // that becomes an unhandled async error rather than a caught one. The
      // VM and dart2js happen to drain late enough to hide it; dart2wasm does
      // not, which is exactly why this file runs on both compilers.
      final settled = expectLater(f, throwsStateError);
      await c.dispose(drainTurns: 1);
      await settled;
      expect(() => c.submit((id, port) {}), throwsStateError);
    });
  });
}
