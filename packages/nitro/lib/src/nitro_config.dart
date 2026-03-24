/// Log verbosity levels for [NitroConfig.logLevel].
enum NitroLogLevel {
  /// Completely silent — no messages emitted.
  none,

  /// Only errors (unpack failures, bridge panics).
  error,

  /// Errors + warnings (slow call detection, GC-triggered releases).
  warning,

  /// Full trace: every bridge call, stream event, isolate dispatch, timing.
  verbose,
}

/// Global configuration for the Nitro runtime.
///
/// Set before calling any Nitro APIs, typically in `main()`:
///
/// ```dart
/// NitroConfig.instance
///   ..debugMode = true
///   ..logLevel = NitroLogLevel.verbose
///   ..isolatePoolSize = 4;
/// ```
///
/// All settings are live — changing them mid-run takes effect on the next
/// call / stream event.
class NitroConfig {
  NitroConfig._();

  /// The singleton instance.
  static final NitroConfig instance = NitroConfig._();

  // ── Debug mode ────────────────────────────────────────────────────────────

  /// When `true`, Nitro emits structured log lines for every bridge
  /// invocation, stream event, and lifecycle transition.
  ///
  /// Equivalent to setting [logLevel] to [NitroLogLevel.verbose].
  /// If [logLevel] has been set explicitly, that value wins.
  bool debugMode = false;

  // ── Log level ─────────────────────────────────────────────────────────────

  /// Verbosity of the runtime logger.
  ///
  /// Defaults to [NitroLogLevel.error] so that stream unpack failures are
  /// always visible in debug builds without extra configuration.
  NitroLogLevel logLevel = NitroLogLevel.error;

  /// Resolved effective log level — respects [debugMode] override.
  NitroLogLevel get effectiveLogLevel =>
      debugMode ? NitroLogLevel.verbose : logLevel;

  // ── Log handler ───────────────────────────────────────────────────────────

  /// Custom log sink.  Replace to integrate with your logger of choice
  /// (e.g. `package:logging`, `Crashlytics`, etc.).
  ///
  /// Receives `(level, tag, message, [error, stackTrace])`.
  ///
  /// The default implementation prints to `stdout` when [logLevel] is not
  /// [NitroLogLevel.none].
  void Function(NitroLogLevel level, String tag, String message,
      [Object? error, StackTrace? stack]) logHandler = _defaultLog;

  // ── Isolate pool ──────────────────────────────────────────────────────────

  /// Number of persistent worker isolates maintained by
  /// [NitroRuntime.callAsync].
  ///
  /// - `0` — legacy mode: a new [Isolate] is spawned for every call
  ///   (same as the original behaviour).
  /// - `1` (default) — single persistent worker; eliminates spawn overhead
  ///   for sequential workloads.
  /// - `N > 1` — pool of N workers; round-robin dispatch; useful when
  ///   multiple async FFI calls are in-flight concurrently (e.g. image
  ///   processing pipeline).
  ///
  /// Changing this after [NitroRuntime.init] has been called requires calling
  /// [NitroRuntime.dispose] + [NitroRuntime.init] again to resize the pool.
  int isolatePoolSize = 1;

  /// Threshold in microseconds above which a [NitroRuntime.callAsync] call
  /// emits a [NitroLogLevel.warning] log.  Set to `0` to disable.
  int slowCallThresholdUs = 16000; // 16 ms ≈ one frame at 60 fps

  // ── Enable / Disable shortcuts ────────────────────────────────────────────

  /// Enables Nitro logging in one call.
  ///
  /// ```dart
  /// NitroConfig.instance.enable();                          // warning + 16 ms threshold
  /// NitroConfig.instance.enable(NitroLogLevel.verbose);     // full trace
  /// NitroConfig.instance.enable(NitroLogLevel.error);       // errors only, no timing
  /// ```
  ///
  /// - [level] — log verbosity to activate (defaults to [NitroLogLevel.warning]).
  /// - [slowCallThresholdMs] — emit a warning for any `callAsync` that exceeds
  ///   this many milliseconds. Pass `0` to suppress slow-call warnings even
  ///   when logging is enabled. Defaults to `16` (one frame at 60 fps).
  void enable({
    NitroLogLevel level = NitroLogLevel.warning,
    int slowCallThresholdMs = 16,
  }) {
    logLevel = level;
    slowCallThresholdUs = slowCallThresholdMs * 1000;
    if (level == NitroLogLevel.verbose) debugMode = true;
  }

  /// Disables **all** Nitro runtime overhead in one call.
  ///
  /// Sets [logLevel] to [NitroLogLevel.none], clears [slowCallThresholdUs]
  /// (so no `Stopwatch` is ever allocated), and turns off [debugMode].
  ///
  /// ```dart
  /// NitroConfig.instance.disable(); // production kill-switch
  /// ```
  void disable() {
    debugMode = false;
    logLevel = NitroLogLevel.none;
    slowCallThresholdUs = 0;
  }

  // ── Reset ─────────────────────────────────────────────────────────────────

  /// Resets all settings to their defaults.  Useful in tests.
  void reset() {
    debugMode = false;
    logLevel = NitroLogLevel.error;
    logHandler = _defaultLog;
    isolatePoolSize = 1;
    slowCallThresholdUs = 16000;
  }
}

void _defaultLog(
  NitroLogLevel level,
  String tag,
  String message, [
  Object? error,
  StackTrace? stack,
]) {
  final prefix = switch (level) {
    NitroLogLevel.none => '',
    NitroLogLevel.error => '❌ [Nitro/$tag]',
    NitroLogLevel.warning => '⚠️  [Nitro/$tag]',
    NitroLogLevel.verbose => '🔬 [Nitro/$tag]',
  };
  // ignore: avoid_print
  print('$prefix $message${error != null ? '\n  error: $error' : ''}${stack != null ? '\n  $stack' : ''}');
}
