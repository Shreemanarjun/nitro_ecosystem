import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'nitro_background_exception.dart';

/// Runtime half of `@NitroEntryPoint` (see nitro_annotations). Generated
/// wrappers call [runEntry]; generated `run<Name>InBackground` calls
/// [spawnFallback] when no native host registered an engine starter.
///
/// Arguments and results cross the process-wide job table as one binary blob
/// in the record wire format, so every type a record field can carry works.
class NitroBackground {
  NitroBackground._();

  /// Runs one queued job for [entry] on the current (background) isolate:
  /// take → body → complete/fail. A start with nothing queued is a no-op, so a
  /// host that launched an engine speculatively cannot wedge anything.
  static Future<void> runEntry({
    required String entry,
    required ({int jobId, Uint8List args})? Function() takeJob,
    required void Function(int jobId, Uint8List result) complete,
    required void Function(int jobId, String error, String stackTrace) fail,
    required FutureOr<Uint8List> Function(Uint8List args) body,
  }) async {
    final job = takeJob();
    if (job == null) return;
    try {
      final result = await Future.sync(() => body(job.args));
      complete(job.jobId, result);
    } catch (e, st) {
      fail(job.jobId, '$e', '$st');
    }
  }

  /// Stream flavour: forwards every item of [body]'s stream as one blob until
  /// it is done (→ [end]) or errors (→ [fail]). When [emit] reports false the
  /// submitter cancelled, so the subscription is cancelled and the producer
  /// stops.
  static Future<void> runStreamEntry({
    required String entry,
    required ({int jobId, Uint8List args})? Function() takeJob,
    required bool Function(int jobId, Uint8List item) emit,
    required void Function(int jobId) end,
    required void Function(int jobId, String error, String stackTrace) fail,
    required Stream<Uint8List> Function(Uint8List args) body,
  }) async {
    final job = takeJob();
    if (job == null) return;
    final done = Completer<void>();
    late final StreamSubscription<Uint8List> sub;
    void finish() {
      if (!done.isCompleted) done.complete();
    }
    try {
      sub = body(job.args).listen(
        (item) {
          if (!emit(job.jobId, item)) {
            sub.cancel();
            finish();
          }
        },
        onError: (Object e, StackTrace st) {
          fail(job.jobId, '$e', '$st');
          finish();
        },
        onDone: () {
          end(job.jobId);
          finish();
        },
        cancelOnError: true,
      );
    } catch (e, st) {
      fail(job.jobId, '$e', '$st');
      return;
    }
    await done.future;
  }

  /// Submitter side of a `Stream<T>` entry point. [submit] enqueues the job
  /// with the given native port (and starts the fallback isolate when no host
  /// took it) and returns the job id; [cancel] forgets the job so the producer
  /// stops; [decode] turns one posted blob into an item. Wire: a Uint8 blob per
  /// item, `null` when done, a one-element `List<String>` on error.
  static Stream<R> openStream<R>({
    required String entry,
    required int Function(int nativePort) submit,
    required void Function(int jobId) cancel,
    required R Function(Uint8List blob) decode,
    void Function()? onClose,
  }) {
    final port = ReceivePort();
    var jobId = 0;
    late final StreamController<R> controller;
    controller = StreamController<R>(
      onListen: () {
        port.listen((dynamic raw) {
          if (raw == null) {
            port.close();
            onClose?.call();
            controller.close();
            return;
          }
          if (raw is Uint8List) {
            try {
              controller.add(decode(raw));
            } catch (e, st) {
              controller.addError(e, st);
            }
            return;
          }
          controller.addError(NitroBackgroundException.fromPost(entry, raw, jobId: jobId));
          port.close();
          onClose?.call();
          controller.close();
        });
        jobId = submit(port.sendPort.nativePort);
      },
      onCancel: () {
        cancel(jobId);
        port.close();
        onClose?.call();
      },
    );
    return controller.stream;
  }

  /// Caller-side half of a callback parameter: the background isolate posts
  /// each invocation's arguments as one blob to this port and [onCall] runs
  /// the real callback here. Returns the native port to put in the args blob
  /// and a closer the generated runner calls once the job is over — calls
  /// that arrive after that are dropped.
  static (int nativePort, void Function() close) callbackPort(void Function(Uint8List blob) onCall) {
    final port = ReceivePort();
    port.listen((dynamic raw) => onCall(raw as Uint8List));
    return (port.sendPort.nativePort, port.close);
  }

  /// No host engine: run the entry wrapper on a fresh isolate. The wrapper
  /// takes its job from the process-wide table exactly as it would under a
  /// headless engine, so both paths exercise the same code.
  /// Job id a host passed to the entry wrapper as its only argument, or 0
  /// when the wrapper was started without one — the table then hands out the
  /// oldest pending job of that entry (hosts that cannot pass arguments).
  static int jobIdOf(List<String> args) => args.isEmpty ? 0 : (int.tryParse(args.first) ?? 0);

  /// Runs [wrapper] for [jobId] on a fresh isolate of this process — the path
  /// taken when no native host registered (desktop, C++-only implementations).
  static Future<void> spawnFallback(void Function(List<String>) wrapper, int jobId) =>
      Isolate.spawn(_invoke, (wrapper, <String>['$jobId']));
  static void _invoke((void Function(List<String>), List<String>) m) => m.$1(m.$2);
}
