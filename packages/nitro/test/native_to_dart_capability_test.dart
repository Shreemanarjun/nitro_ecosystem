// Capability + latency probes for the native → Dart direction, with no native
// code: dart:ffi exposes the same primitives native uses.
//
//   * NativeApi.postCObject   — what Dart_PostCObject_DL resolves to; posting
//                               from this isolate's thread is the "inline"
//                               completion, posting from another isolate's
//                               thread is a foreign-thread completion.
//   * NativeCallable.listener — how generated code delivers Dart callbacks to
//                               native; invoking its address from another
//                               isolate is exactly a native thread calling it.
//   * PluginUtilities          — the only way native can *locate* a Dart
//                               function without a live reference to it
//                               (needs @pragma('vm:entry-point') under AOT).
//
// Numbers print to the test output; assertions are about capability only.
// ignore_for_file: avoid_print — the latencies are the point of this file.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show PluginUtilities;

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// Dart_CObject layout: int32 type @0, union @8 (8-aligned). kInt64 == 3.
const _kInt64 = 3;
typedef _PostNative = Int8 Function(Int64, Pointer<Void>);
typedef _Post = int Function(int, Pointer<Void>);

_Post _postFn() => NativeApi.postCObject.cast<NativeFunction<_PostNative>>().asFunction<_Post>();

Pointer<Void> _int64Obj(int v) {
  final p = calloc<Uint8>(16);
  p.cast<Int32>().value = _kInt64;
  (p + 8).cast<Int64>().value = v;
  return p.cast();
}

@pragma('vm:entry-point')
int backgroundEntry(int x) => x * 2;

int plainTopLevel(int x) => x + 1;

void main() {
  group('native → Dart delivery (what every completion/stream/callback rides on)', () {
    test('inline post from the isolate thread: delivered, only via the event loop', () async {
      final port = ReceivePort();
      final post = _postFn();
      final obj = _int64Obj(7);
      var pending = Completer<int>();
      var seen = 0;
      final sub = port.listen((m) { seen++; pending.complete(m as int); });
      // The post enqueues; nothing is observable until this frame yields.
      expect(post(port.sendPort.nativePort, obj), 1);
      expect(pending.isCompleted, isFalse, reason: 'inline post still needs an event-loop turn');
      expect(await pending.future, 7);

      // Latency: sequential round trips, each awaiting delivery.
      const n = 2000;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        pending = Completer<int>();
        post(port.sendPort.nativePort, obj);
        await pending.future;
      }
      sw.stop();
      expect(seen, n + 1);
      print('CAPABILITY inline post → Dart: ${(sw.elapsedMicroseconds / n).toStringAsFixed(1)} µs per message');
      await sub.cancel(); port.close(); calloc.free(obj);
    });

    test('post from another thread (spawned isolate): delivered', () async {
      final port = ReceivePort();
      final got = port.first;
      await Isolate.spawn(_postFromOtherIsolate, port.sendPort.nativePort);
      expect(await got, 99);
      port.close();
    });

    test('NativeCallable.listener invoked from another thread reaches this isolate', () async {
      final got = Completer<int>();
      final cb = NativeCallable<Void Function(Int64)>.listener((int v) => got.complete(v));
      await Isolate.spawn(_callListenerFromOtherIsolate, cb.nativeFunction.address);
      expect(await got.future.timeout(const Duration(seconds: 5)), 42);
      cb.close();
    });
  });

  group('the alternative for inline completions', () {
    test('NativeCallable.isolateLocal completes synchronously on the isolate thread — no event-loop turn', () {
      var seen = 0;
      final cb = NativeCallable<Void Function(Int64)>.isolateLocal((int v) => seen += v);
      final fn = cb.nativeFunction.asFunction<void Function(int)>();
      fn(1);
      expect(seen, 1, reason: 'delivered before the call even returned');
      const n = 200000;
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        fn(1);
      }
      sw.stop();
      expect(seen, n + 1);
      print('CAPABILITY isolateLocal direct call → Dart: ${(sw.elapsedMicroseconds * 1000 / n).toStringAsFixed(0)} ns per call (vs the port post above)');
      cb.close();
    });
  });

  group('background invocation of Dart (a headless engine or fresh isolate)', () {
    test('a function can be located by handle — the entry-point mechanism Nitro does not wrap', () {
      final h = PluginUtilities.getCallbackHandle(backgroundEntry);
      expect(h, isNotNull);
      final f = PluginUtilities.getCallbackFromHandle(h!)! as int Function(int);
      expect(f(21), 42);
      // Works for any top-level function in JIT; under AOT only functions
      // carrying @pragma('vm:entry-point') survive tree-shaking for this.
      expect(PluginUtilities.getCallbackHandle(plainTopLevel), isNotNull);
    });

    test('Nitro closes the gap with @NitroEntryPoint: a runtime helper, no callback handles', () {
      // The generated `@pragma('vm:entry-point')` wrapper references the user
      // function directly, so PluginUtilities handles are never needed.
      final src = File('lib/nitro.dart').readAsStringSync() +
          Directory('lib/src').listSync(recursive: true).whereType<File>()
              .where((f) => f.path.endsWith('.dart'))
              .map((f) => f.readAsStringSync()).join();
      expect(src, contains("export 'src/nitro_background.dart'"));
      expect(src, contains('class NitroBackground'));
      expect(src, isNot(contains('PluginUtilities')));
    });
  });
}

void _postFromOtherIsolate(int nativePort) {
  final post = _postFn();
  final obj = _int64Obj(99);
  post(nativePort, obj);
  calloc.free(obj);
}

void _callListenerFromOtherIsolate(int address) {
  final fn = Pointer<NativeFunction<Void Function(Int64)>>.fromAddress(address).asFunction<void Function(int)>();
  fn(42);
}
