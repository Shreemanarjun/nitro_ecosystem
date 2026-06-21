/// Web stub for NitroRuntime.
///
/// `dart:ffi` and `dart:io` are unavailable on web targets. This file provides
/// the same public API surface as `nitro_runtime.dart` but throws
/// [UnsupportedError] for all operations. Web modules must use
/// `NativeImpl.wasm` and a `WebBridgeGenerator`-produced bridge instead.
library;

import 'nitro_config.dart';

export 'nitro_config.dart';

// ── Web-side NitroRuntime stub ─────────────────────────────────────────────────

/// Stub error factory — every method on the web stub throws this.
UnsupportedError _webError(String method) => UnsupportedError(
    'NitroRuntime.$method is not supported on web. '
    'Web modules must use NativeImpl.wasm and a WASM/JS interop bridge. '
    'Rebuild with the web target enabled and a WebBridgeGenerator output.');

// ignore_for_file: avoid_classes_with_only_static_members
class NitroRuntime {
  static const int expectedAbiVersion = 1;

  static dynamic loadLib(String libName) => throw _webError('loadLib');

  static dynamic loadLibForTargets(
    String libName, {
    required bool ios,
    required bool android,
    required bool macos,
    required bool windows,
    required bool linux,
    required bool web,
  }) =>
      throw _webError('loadLibForTargets');

  static void checkSupportedPlatform(
    String libName, {
    required bool ios,
    required bool android,
    required bool macos,
    required bool windows,
    required bool linux,
    required bool web,
  }) =>
      throw _webError('checkSupportedPlatform');

  static T callSync<T>(T Function() fn, {required String methodName}) =>
      throw _webError('callSync');

  static Future<T> callAsync<T>(
    dynamic fn,
    List<dynamic> args,
    {required dynamic getError,
    required dynamic clearError,
    required String methodName}
  ) =>
      throw _webError('callAsync');

  static Future<T> openNativeAsync<T>(
    T Function(dynamic) decoder,
    void Function(int dartPort) nativeCall, {
    required String methodName,
  }) =>
      throw _webError('openNativeAsync');

  static dynamic openStream(
    void Function(int dartPort) registerNative,
    void Function(int dartPort) releaseNative,
    dynamic decoder, {
    required String itemTypeName,
  }) =>
      throw _webError('openStream');

  static void checkError(dynamic getError, dynamic clearError) =>
      throw _webError('checkError');

  static void checkAbiVersion(String libName, dynamic versionFn) =>
      throw _webError('checkAbiVersion');

  static void checkLinkChecksum(
    String libName,
    String expectedChecksum,
    dynamic checksumFn,
  ) =>
      throw _webError('checkLinkChecksum');

  static void logLifecycle(String tag, String message) {
    // Best-effort: log on web without crashing
    final cfg = NitroConfig.instance;
    if (cfg.effectiveLogLevel != NitroLogLevel.none) {
      cfg.logHandler(NitroLogLevel.verbose, tag, message, null, null);
    }
  }

  static void enable({NitroLogLevel level = NitroLogLevel.verbose}) {
    NitroConfig.instance.enable(level: level);
  }
}
