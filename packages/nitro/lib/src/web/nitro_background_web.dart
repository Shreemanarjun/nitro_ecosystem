import 'dart:async';
import 'dart:typed_data';

/// Web twin of `NitroBackground`: entry-point wrappers are never started on
/// web (no headless engine, no isolates), so only the API surface exists.
class NitroBackground {
  NitroBackground._();

  static Future<void> runEntry({
    required String entry,
    required ({int jobId, Uint8List args})? Function() takeJob,
    required void Function(int jobId, Uint8List result) complete,
    required void Function(int jobId, String error, String stackTrace) fail,
    required FutureOr<Uint8List> Function(Uint8List args) body,
  }) async {
    throw UnsupportedError('@NitroEntryPoint "$entry": background entry points are not available on web');
  }

  static Future<void> runStreamEntry({
    required String entry,
    required ({int jobId, Uint8List args})? Function() takeJob,
    required bool Function(int jobId, Uint8List item) emit,
    required void Function(int jobId) end,
    required void Function(int jobId, String error, String stackTrace) fail,
    required Stream<Uint8List> Function(Uint8List args) body,
  }) async {
    throw UnsupportedError('@NitroEntryPoint "$entry": background entry points are not available on web');
  }

  static Stream<R> openStream<R>({
    required String entry,
    required int Function(int nativePort) submit,
    required void Function(int jobId) cancel,
    required R Function(Uint8List blob) decode,
    void Function()? onClose,
  }) {
    throw UnsupportedError('@NitroEntryPoint: background entry points are not available on web');
  }

  static (int nativePort, void Function() close) callbackPort(void Function(Uint8List blob) onCall) {
    throw UnsupportedError('@NitroEntryPoint: background entry points are not available on web');
  }

  static int jobIdOf(List<String> args) => 0;

  static Future<void> spawnFallback(void Function(List<String>) wrapper, int jobId) async {
    throw UnsupportedError('@NitroEntryPoint: background entry points are not available on web');
  }
}
