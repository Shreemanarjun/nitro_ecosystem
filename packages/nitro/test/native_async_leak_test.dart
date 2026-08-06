// Native-memory leak verification for openNativeAsync's guaranteed `cleanup`
// (leak-audit #2), using ffi_leak_tracker. The per-call error slot must be
// freed on EVERY terminal path. The success path is covered by the
// nitro_type_coverage §M native-async soak; here we drive the timeout and
// call-throw paths — the ones a native side that never posts would leak.
import 'dart:async';
import 'dart:ffi';

import 'package:ffi_leak_tracker/ffi_leak_tracker.dart';
import 'package:nitro/src/nitro_runtime.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    LeakTracker.reset();
    LeakTracker.enable();
  });
  tearDown(() {
    LeakTracker.disable();
    LeakTracker.reset();
    NitroConfig.instance.reset();
  });

  test('sanity: the tracker actually detects an unfreed native allocation', () {
    // Guards against the assertions below being vacuous — an unfreed tracked
    // allocation must register as a leak, and freeing it must clear it.
    final ptr = adaptiveCalloc<Uint8>(64);
    expect(LeakTracker.hasLeaks, isTrue);
    adaptiveCalloc.free(ptr);
    expect(LeakTracker.hasLeaks, isFalse);
  });

  test('cleanup frees the per-call slot on the TIMEOUT path — no native leak', () async {
    NitroConfig.instance.nativeAsyncTimeoutMs = 40;
    // Stands in for the calloc'd error slot the generated wrapper hands to
    // `cleanup`; tracked so a missed free surfaces as a leak.
    final slot = adaptiveCalloc<Uint8>(64);
    expect(LeakTracker.hasLeaks, isTrue, reason: 'slot is live before the call settles');

    await expectLater(
      NitroRuntime.openNativeAsync<int>(
        call: (port) {}, // never posts → the call times out
        unpack: (raw) => raw as int,
        cleanup: () => adaptiveCalloc.free(slot),
        methodName: 'neverPosts',
      ),
      throwsA(isA<TimeoutException>()),
    );
    // cleanup runs in whenComplete — let the microtask queue drain.
    await Future<void>.delayed(Duration.zero);
    expect(LeakTracker.hasLeaks, isFalse, reason: 'cleanup must free the slot on the timeout path');
  });

  test('cleanup frees the slot when call() THROWS — no native leak', () {
    final slot = adaptiveCalloc<Uint8>(64);
    expect(
      () => NitroRuntime.openNativeAsync<int>(
        call: (port) => throw StateError('native dispatch failed'),
        unpack: (raw) => raw as int,
        cleanup: () => adaptiveCalloc.free(slot),
      ),
      throwsA(isA<StateError>()),
    );
    expect(LeakTracker.hasLeaks, isFalse, reason: 'cleanup must free the slot when call() throws');
  });
}
