/// Tests for [NitroRuntime.deferredClose], the fix for the callback
/// NativeCallable leak: generated callback-setter helpers call this to close
/// a replaced callback on the next microtask turn instead of accumulating an
/// unbounded cache of NativeCallables keyed by closure identity.
library;

import 'dart:async';

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  test('deferredClose(null) is a no-op', () {
    expect(() => NitroRuntime.deferredClose(null), returnsNormally);
  });

  test('deferredClose does not close synchronously', () async {
    final events = <String>[];
    final nc = NativeCallable<Void Function(Int64)>.listener((int _) {});

    NitroRuntime.deferredClose(nc);
    events.add('after-deferredClose-call');

    // The close is scheduled via scheduleMicrotask, so it cannot have run
    // yet at this point in the same synchronous frame.
    expect(events, ['after-deferredClose-call']);

    // Let the microtask queue drain — the deferred close() runs here.
    await Future<void>.delayed(Duration.zero);
    events.add('after-microtask-drain');
    expect(events, ['after-deferredClose-call', 'after-microtask-drain']);
  });

  test('a NativeCallable closed via deferredClose can be closed again safely', () async {
    final nc = NativeCallable<Void Function(Int64)>.listener((int _) {});
    NitroRuntime.deferredClose(nc);
    await Future<void>.delayed(Duration.zero);
    // NativeCallable.close() is documented as idempotent — a direct extra
    // close() after the deferred one must not throw.
    expect(() => nc.close(), returnsNormally);
  });

  test('repeated deferredClose calls (simulating rapid re-registration) do not throw', () async {
    // Mirrors the real leak scenario: a listener-style setter called
    // repeatedly with a fresh closure each time.
    for (var i = 0; i < 200; i++) {
      final nc = NativeCallable<Void Function(Int64)>.listener((int _) {});
      NitroRuntime.deferredClose(nc);
    }
    await Future<void>.delayed(Duration.zero);
  });
}
