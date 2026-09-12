import 'dart:io';
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:nitro/src/hybrid_exception.dart';
import 'package:nitro/src/nitro_background.dart';
import 'package:nitro/src/nitro_background_exception.dart';
import 'package:test/test.dart';

void main() {
  group('NitroBackground.runEntry', () {
    test('take → body → complete, with the job\'s bytes', () async {
      final completed = <(int, Uint8List)>[];
      await NitroBackground.runEntry(
        entry: 'e',
        takeJob: () => (jobId: 7, args: Uint8List.fromList([1, 2, 3])),
        complete: (id, r) => completed.add((id, r)),
        fail: (_, _, _) => fail('must not fail'),
        body: (args) => Uint8List.fromList(args.reversed.toList()),
      );
      expect(completed.single.$1, 7);
      expect(completed.single.$2, [3, 2, 1]);
    });

    test('a throwing body reports fail with the error text, never throws out', () async {
      String? error;
      await NitroBackground.runEntry(
        entry: 'e',
        takeJob: () => (jobId: 1, args: Uint8List(0)),
        complete: (_, _) => fail('must not complete'),
        fail: (id, e, _) => error = '$id:$e',
        body: (_) => throw StateError('boom'),
      );
      expect(error, startsWith('1:Bad state: boom'));
    });

    test('async bodies are awaited', () async {
      Uint8List? out;
      await NitroBackground.runEntry(
        entry: 'e',
        takeJob: () => (jobId: 2, args: Uint8List(0)),
        complete: (_, r) => out = r,
        fail: (_, _, _) => fail('must not fail'),
        body: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return Uint8List.fromList([42]);
        },
      );
      expect(out, [42]);
    });

    test('nothing queued for this entry is a no-op (speculative engine start)', () async {
      var touched = false;
      await NitroBackground.runEntry(
        entry: 'e',
        takeJob: () => null,
        complete: (_, _) => touched = true,
        fail: (_, _, _) => touched = true,
        body: (_) => throw StateError('never called'),
      );
      expect(touched, isFalse);
    });
  });

  group('NitroBackground.runStreamEntry', () {
    test('forwards every item then end', () async {
      final items = <Uint8List>[]; var ended = false;
      await NitroBackground.runStreamEntry(
        entry: 'e', takeJob: () => (jobId: 1, args: Uint8List(0)),
        emit: (_, b) { items.add(b); return true; }, end: (_) => ended = true, fail: (_, _, _) => fail('no fail'),
        body: (_) => Stream.fromIterable([Uint8List.fromList([1]), Uint8List.fromList([2])]),
      );
      expect(items.map((b) => b.first), [1, 2]);
      expect(ended, isTrue);
    });

    test('a stream error reports fail, not end', () async {
      String? error; var ended = false;
      await NitroBackground.runStreamEntry(
        entry: 'e', takeJob: () => (jobId: 1, args: Uint8List(0)),
        emit: (_, _) => true, end: (_) => ended = true, fail: (_, e, _) => error = e,
        body: (_) async* { yield Uint8List(0); throw StateError('mid'); },
      );
      expect(error, contains('mid')); expect(ended, isFalse);
    });

    test('emit returning false (submitter cancelled) stops the producer', () async {
      var produced = 0; var ended = false;
      await NitroBackground.runStreamEntry(
        entry: 'e', takeJob: () => (jobId: 1, args: Uint8List(0)),
        emit: (_, _) => produced < 3, end: (_) => ended = true, fail: (_, _, _) => fail('no fail'),
        body: (_) async* { while (true) { produced++; yield Uint8List(0); await Future<void>.delayed(Duration.zero); } },
      );
      expect(produced, 3, reason: 'the refused item is the last one pulled');
      expect(ended, isFalse, reason: 'a cancelled job is not ended (already forgotten)');
    });

    test('a body that throws synchronously reports fail', () async {
      String? error;
      await NitroBackground.runStreamEntry(
        entry: 'e', takeJob: () => (jobId: 1, args: Uint8List(0)),
        emit: (_, _) => true, end: (_) => fail('no end'), fail: (_, e, _) => error = e,
        body: (_) => throw StateError('sync boom'),
      );
      expect(error, contains('sync boom'));
    });
  });

  group('NitroBackground.openStream (submitter side)', () {
    test('blobs become items, null closes, a List is an error', () async {
      SendPort? sink; var cancelled = false;
      final s = NitroBackground.openStream<int>(
        entry: 'e',
        submit: (nativePort) { sink = _sendPortFromNative(nativePort); return 7; },
        cancel: (_) => cancelled = true,
        decode: (b) => b.first,
      );
      final got = <int>[]; final done = Completer<void>();
      s.listen(got.add, onDone: done.complete);
      await Future<void>.delayed(Duration.zero);
      sink!.send(Uint8List.fromList([5])); sink!.send(Uint8List.fromList([6])); sink!.send(null);
      await done.future;
      expect(got, [5, 6]); expect(cancelled, isTrue, reason: 'closing cancels the port');
    });

    test('cancelling the subscription cancels the job', () async {
      int? cancelledId;
      final sub = NitroBackground.openStream<int>(entry: 'e',
        submit: (_) => 42, cancel: (id) => cancelledId = id, decode: (b) => b.first).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(cancelledId, 42);
    });
  });

  group('jobIdOf / NitroBackgroundException', () {
    test('jobIdOf parses the entrypoint argument, 0 otherwise', () {
      expect(NitroBackground.jobIdOf(['42']), 42);
      expect(NitroBackground.jobIdOf([]), 0);
      expect(NitroBackground.jobIdOf(['nope']), 0);
    });
    test('fromPost maps [error, stack, entry] and falls back sanely', () {
      final e = NitroBackgroundException.fromPost('x', ['Bad state: boom', '#0 main', 'sync'], jobId: 3);
      expect(e.entry, 'sync');
      expect(e.message, 'Bad state: boom');
      expect(e.stackTrace, '#0 main');
      expect(e.jobId, 3);
      expect(e.isStartFailure, isFalse);
      expect(e, isA<HybridException>());
      expect('$e', contains('NitroBackgroundException(sync): Bad state: boom'));
      final start = NitroBackgroundException.fromPost('x', ['background engine start failed: no loader', '', '']);
      expect(start.isStartFailure, isTrue);
      expect(start.entry, 'x');
      expect(start.stackTrace, isNull);
      expect(NitroBackgroundException.fromPost('x', 7).message, contains('background job failed: 7'));
    });
  });

  test('spawnFallback runs the wrapper on another isolate', () async {
    // Globals are per-isolate, so the wrapper reports through a file — the
    // same shape as production, where the wrapper finds its job in C, not Dart.
    final marker = File('${Directory.systemTemp.path}/nitro_bg_fallback_$pid.txt');
    if (marker.existsSync()) marker.deleteSync();
    await NitroBackground.spawnFallback(_wrapper, 42);
    for (var i = 0; i < 200 && !marker.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(marker.existsSync(), isTrue, reason: 'wrapper never ran');
    expect(marker.readAsStringSync(), isNot('${Isolate.current.hashCode}'), reason: 'ran on a different isolate');
    marker.deleteSync();
  });
}

void _wrapper(List<String> args) => File('${Directory.systemTemp.path}/nitro_bg_fallback_$pid.txt').writeAsStringSync('${Isolate.current.hashCode}');

/// Posts to a native port exactly as Dart_PostCObject_DL would, via the VM's
/// own NativeApi.postCObject — no native code needed.
SendPort _sendPortFromNative(int nativePort) {
  final rp = RawReceivePort();
  final proxy = ReceivePort();
  rp.close();
  return _NativePortSendPort(nativePort, proxy);
}

class _NativePortSendPort implements SendPort {
  _NativePortSendPort(this.nativePort, this._keep);
  final int nativePort;
  final ReceivePort _keep; // ignore: unused_field
  static final _post = NativeApi.postCObject.cast<NativeFunction<Int8 Function(Int64, Pointer<Void>)>>().asFunction<int Function(int, Pointer<Void>)>();

  @override
  void send(Object? message) {
    // Dart_CObject: int32 type @0, payload @8. kNull=0, kTypedData=7 (typed-data type @8, length @16, values @24).
    if (message == null) {
      final p = calloc<Uint8>(16);
      _post(nativePort, p.cast());
      calloc.free(p);
      return;
    }
    final bytes = message as Uint8List;
    final p = calloc<Uint8>(48);
    p.cast<Int32>().value = 7; // Dart_CObject_kTypedData
    (p + 8).cast<Int32>().value = 2; // Dart_TypedData_kUint8
    (p + 16).cast<IntPtr>().value = bytes.length;
    final data = calloc<Uint8>(bytes.length + 1);
    data.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
    (p + 24).cast<Pointer<Uint8>>().value = data;
    _post(nativePort, p.cast());
    calloc.free(data);
    calloc.free(p);
  }
}
