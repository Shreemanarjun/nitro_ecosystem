import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nitro/nitro.dart';

void main() {
  // ── Lazy registration ─────────────────────────────────────────────────────

  group('NitroRuntime.openStream — lazy registration', () {
    test('register is NOT called before any listener attaches', () async {
      var registerCalled = false;
      final fakePort = ReceivePort();
      addTearDown(fakePort.close);

      NitroRuntime.openStream<int>(
        register: (_) => registerCalled = true,
        unpack: (m) => m as int,
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      await Future.microtask(() {});
      expect(registerCalled, isFalse);
    });

    test('register is called exactly once when the first listener attaches', () async {
      var registerCount = 0;
      final fakePort = ReceivePort();

      final stream = NitroRuntime.openStream<int>(
        register: (_) => registerCount++,
        unpack: (m) => m as int,
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});
      await Future.microtask(() {});
      expect(registerCount, 1);
      await sub.cancel();
    });

    test('register is called with the port of the internal ReceivePort', () async {
      int? capturedPort;
      final fakePort = ReceivePort();

      final stream = NitroRuntime.openStream<int>(
        register: (p) => capturedPort = p,
        unpack: (m) => m as int,
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});
      await Future.microtask(() {});
      expect(capturedPort, isNotNull);
      expect(capturedPort, fakePort.sendPort.nativePort);
      await sub.cancel();
    });
  });

  // ── Cancellation lifecycle ────────────────────────────────────────────────

  group('NitroRuntime.openStream — cancellation', () {
    test('release is NOT called before subscription is cancelled', () async {
      var releaseCalled = false;
      final fakePort = ReceivePort();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) => m as int,
        release: (_) => releaseCalled = true,
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});
      await Future.microtask(() {});
      expect(releaseCalled, isFalse);
      await sub.cancel();
    });

    test('release is called when subscription is cancelled', () async {
      var releaseCalled = false;
      final fakePort = ReceivePort();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) => m as int,
        release: (_) => releaseCalled = true,
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});
      await sub.cancel();
      expect(releaseCalled, isTrue);
    });

    test('release is called exactly once on double cancel (idempotent)', () async {
      var releaseCount = 0;
      final fakePort = ReceivePort();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) => m as int,
        release: (_) => releaseCount++,
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});
      await sub.cancel();
      await sub.cancel(); // second cancel — must be a no-op
      expect(releaseCount, 1);
    });

    test('cancel before first event: register and release both called, no crash', () async {
      var registerCalled = false;
      var releaseCalled = false;
      final fakePort = ReceivePort();

      final stream = NitroRuntime.openStream<int>(
        register: (_) => registerCalled = true,
        unpack: (m) => m as int,
        release: (_) => releaseCalled = true,
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});
      await sub.cancel(); // cancel before any events are posted
      expect(registerCalled, isTrue);
      expect(releaseCalled, isTrue);
    });
  });

  // ── Single-subscriber contract ────────────────────────────────────────────

  group('NitroRuntime.openStream — single-subscriber contract', () {
    test('second listen() while first subscription is active throws StateError', () async {
      final fakePort = ReceivePort();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) => m as int,
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});
      expect(
        () => stream.listen((_) {}),
        throwsStateError,
        reason: 'single-subscription streams must reject a second listener',
      );
      await sub.cancel();
    });

    test('listen() after cancel throws StateError (cannot re-subscribe)', () async {
      final fakePort = ReceivePort();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) => m as int,
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});
      await sub.cancel();
      expect(() => stream.listen((_) {}), throwsStateError);
    });
  });

  // ── Event delivery ────────────────────────────────────────────────────────

  group('NitroRuntime.openStream — event delivery', () {
    test('single subscriber receives events in arrival order', () async {
      final fakePort = ReceivePort();
      final received = <int>[];
      final done = Completer<void>();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) => m as int,
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((v) {
        received.add(v);
        if (received.length == 3) done.complete();
      });

      fakePort.sendPort.send(1);
      fakePort.sendPort.send(2);
      fakePort.sendPort.send(3);

      await done.future;
      expect(received, [1, 2, 3]);
      await sub.cancel();
    });

    test('high-frequency emission: 1000 events arrive without loss and in order', () async {
      const total = 1000;
      final fakePort = ReceivePort();
      final received = <int>[];
      final done = Completer<void>();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) => m as int,
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((v) {
        received.add(v);
        if (received.length == total) done.complete();
      });

      for (var i = 0; i < total; i++) {
        fakePort.sendPort.send(i);
      }

      await done.future.timeout(const Duration(seconds: 5));
      expect(received.length, total);
      expect(received, List.generate(total, (i) => i));
      await sub.cancel();
    });

    test('cancel mid-emission does not throw', () async {
      final fakePort = ReceivePort();
      var releaseCalled = false;

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) => m as int,
        release: (_) => releaseCalled = true,
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen((_) {});

      // Queue events and cancel immediately — some events may or may not be processed.
      for (var i = 0; i < 100; i++) {
        fakePort.sendPort.send(i);
      }
      await sub.cancel();
      expect(releaseCalled, isTrue);
    });
  });

  // ── Error handling ────────────────────────────────────────────────────────

  group('NitroRuntime.openStream — unpack error handling', () {
    test('unpack error is forwarded as a stream error', () async {
      final fakePort = ReceivePort();
      final errors = <Object>[];
      final done = Completer<void>();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) {
          if (m as int == 99) throw ArgumentError('bad value: $m');
          return m;
        },
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen(
        (_) {},
        onError: (e) {
          errors.add(e);
          done.complete();
        },
        cancelOnError: false,
      );

      fakePort.sendPort.send(99);
      await done.future;
      expect(errors.length, 1);
      expect(errors.first, isA<ArgumentError>());
      await sub.cancel();
    });

    test('stream continues delivering events after an unpack error', () async {
      final fakePort = ReceivePort();
      final received = <int>[];
      var errorCount = 0;
      var processed = 0;
      const expectedProcessed = 3; // 2 good + 1 error
      final done = Completer<void>();

      final stream = NitroRuntime.openStream<int>(
        register: (_) {},
        unpack: (m) {
          if (m as int == 42) throw ArgumentError('skip 42');
          return m;
        },
        release: (_) {},
        backpressure: Backpressure.dropLatest,
        testPort: fakePort,
      );

      final sub = stream.listen(
        (v) {
          received.add(v);
          processed++;
          if (processed == expectedProcessed) done.complete();
        },
        onError: (_) {
          errorCount++;
          processed++;
          if (processed == expectedProcessed) done.complete();
        },
        cancelOnError: false,
      );

      fakePort.sendPort.send(1);
      fakePort.sendPort.send(42); // triggers unpack error
      fakePort.sendPort.send(2);

      await done.future;
      expect(received, [1, 2]);
      expect(errorCount, 1);
      await sub.cancel();
    });
  });
}
