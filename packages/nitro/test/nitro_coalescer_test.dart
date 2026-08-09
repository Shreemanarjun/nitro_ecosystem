// Tests for NitroCoalescer — the shared-port demultiplexer for coalesced
// @nitroNativeAsync completions (issue #39). A native batch is simulated by
// posting a [callId0, value0, …] list to the coalescer's SendPort.
import 'package:leak_tracker/leak_tracker.dart';
import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  group('NitroCoalescer', () {
    test('assigns sequential callIds and resolves each by id', () async {
      final c = NitroCoalescer();
      final ids = <int>[];
      final f0 = c.submit((id, _) => ids.add(id));
      final f1 = c.submit((id, _) => ids.add(id));
      final f2 = c.submit((id, _) => ids.add(id));
      expect(ids, [0, 1, 2]);
      expect(c.pendingCount, 3);

      // One coalesced batch carrying all three, out of order.
      c.sendPort.send([2, 222, 0, 200, 1, 211]);

      expect(await f0, 200);
      expect(await f1, 211);
      expect(await f2, 222);
      expect(c.pendingCount, 0);
      await c.dispose();
    });

    test('resolves across multiple partial batches', () async {
      final c = NitroCoalescer();
      final f0 = c.submit((_, __) {});
      final f1 = c.submit((_, __) {});
      c.sendPort.send([0, 10]); // first batch: only call 0
      expect(await f0, 10);
      expect(c.pendingCount, 1);
      c.sendPort.send([1, 11]); // later batch: call 1
      expect(await f1, 11);
      await c.dispose();
    });

    test('nativePort is stable and matches the send port', () async {
      final c = NitroCoalescer();
      expect(c.nativePort, c.sendPort.nativePort);
      expect(c.nativePort, isNot(0));
      await c.dispose();
    });

    test('ignores unknown callIds without throwing', () async {
      final c = NitroCoalescer();
      final f0 = c.submit((_, __) {});
      c.sendPort.send([999, 42, 0, 7]); // 999 unknown, 0 pending
      expect(await f0, 7);
      await c.dispose();
    });

    test('disposed coalescers are GC-collectable (no port/subscription leak)', () async {
      Future<WeakReference<Object>> makeAndDispose() async {
        final c = NitroCoalescer();
        c.submit((_, __) {}); // register a pending completer, then drop it
        final w = WeakReference<Object>(c);
        await c.dispose();
        return w; // `c` goes out of scope here → collectable if not retained
      }

      final weaks = <WeakReference<Object>>[];
      for (var i = 0; i < 30; i++) {
        weaks.add(await makeAndDispose());
      }
      await forceGC(fullGcCycles: 3, timeout: const Duration(seconds: 10));
      final live = weaks.where((w) => w.target != null).length;
      expect(live, lessThan(8),
          reason: '$live/30 disposed coalescers still live — retained port/subscription');
    });
  });
}
