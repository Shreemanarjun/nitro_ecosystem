
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
  NitroLogLevel get effectiveLogLevel => debugMode ? NitroLogLevel.verbose : logLevel;

  // ── Log handler ───────────────────────────────────────────────────────────

  /// Custom log sink.  Replace to integrate with your logger of choice
  /// (e.g. `package:logging`, `Crashlytics`, etc.).
  ///
  /// Receives `(level, tag, message, [error, stackTrace])`.
  ///
  /// The default implementation prints to `stdout` when [logLevel] is not
  /// [NitroLogLevel.none].
  void Function(NitroLogLevel level, String tag, String message, [Object? error, StackTrace? stack]) logHandler = _defaultLog;

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
  /// Slow-call warning threshold for sync calls, in microseconds; 0 disables.
  ///
  /// Off by default since 0.7.6: timing a call needs two clock reads, which
  /// cost ~150 ns in a Flutter build — more than the checked sync call itself
  /// (~20 ns). Turn it on for a diagnosis session with [enable] (16 ms, one
  /// frame at 60 fps) or by setting this directly.
  int slowCallThresholdUs = 0;

  /// Timeout in milliseconds for `@nitroNativeAsync` calls. When `> 0`, if the
  /// native side fails to post a result within this window (a crashed or buggy
  /// native impl), the returned `Future` completes with a [TimeoutException]
  /// instead of hanging forever, and the underlying [ReceivePort] + per-call
  /// error slot are released. Set to `0` (the default) to wait indefinitely —
  /// the native contract is to post exactly one message, so this is opt-in
  /// resilience against a misbehaving implementation.
  int nativeAsyncTimeoutMs = 0;

  /// Spin window in **microseconds** for a single-in-flight `@nitroNativeAsync`
  /// completion (issue #57), capped — not a fixed spend. When no other
  /// native-async call is outstanding, the Dart side busy-polls a shared
  /// completion slot before parking on the port; a result that lands inside the
  /// window is picked up with no port message and no OS reschedule. Measured
  /// lone-call wins: macOS 23 → 4.5 µs, Android 139 → 25 µs.
  ///
  /// **`null` (the default) means auto**: the window is sized to ≈ the OS wake
  /// the platform would otherwise pay — about **20 µs desktop**
  /// (macOS/Windows/Linux), **40 µs iOS**, **100 µs Android** — so a completion
  /// faster than the wake is caught and a slower one is left to park (catching
  /// it would cost more than it saves). Web ignores it (no ports there). End
  /// users need set nothing.
  ///
  /// It is cheap to leave on: the loop breaks the instant the result lands (so
  /// the cap bounds only the *miss* path), a circuit breaker disables it when
  /// the native side is reliably slower than the cap, and the single-in-flight
  /// guard skips it entirely under concurrency (where the wake already
  /// amortizes). Set an explicit µs value to override the auto cap, or `0` to
  /// disable — e.g. on a battery-critical path that makes many lone, slow
  /// native-async calls. [NitroSpinStats] reports whether it is paying off.
  ///
  /// Profiling note: the spin is a **synchronous busy-wait**. A duty-cycle cap
  /// bounds it to ≤25% of wall-clock over a sliding window, so a tight
  /// native-async loop (e.g. under a profiler / `flutter_driver`) can't starve
  /// the driver channel — you don't need to turn it off to profile. Set `0`
  /// only if you want the busy-wait gone entirely from a measurement.
  int? nativeAsyncSpinUs;

  // ── Timeline tracing ─────────────────────────────────────────────────────

  /// When `true`, [NitroRuntime] wraps bridge calls in `dart:developer`
  /// timeline spans so DevTools can attribute native bridge cost per method.
  ///
  /// Defaults to `false`; enable only while profiling to keep production's
  /// default bridge path free of timeline instrumentation overhead.
  bool timelineTracingEnabled = false;

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
    slowCallThresholdUs = 0;
    nativeAsyncTimeoutMs = 0;
    nativeAsyncSpinUs = null;
    timelineTracingEnabled = false;
  }
}

/// Observability for the single-in-flight completion spin (issue #57).
///
/// The spin self-tunes per library (it sizes its window to the recent
/// completion latency and backs off when spinning stops paying), so these
/// aggregate counters let you confirm it is actually winning before you widen
/// [NitroConfig.nativeAsyncSpinUs] — or notice it never helps and turn it off.
///
/// ```dart
/// final s = NitroSpinStats.instance;
/// print('spin hit-rate ${(s.hitRate * 100).toStringAsFixed(0)}% '
///       'avg ${s.avgHitUs.toStringAsFixed(1)}µs over ${s.spins} calls');
/// ```
class NitroSpinStats {
  NitroSpinStats._();
  static final NitroSpinStats instance = NitroSpinStats._();

  /// Completions picked up from the slot — no port message, no OS wake.
  int hits = 0;

  /// Completions that parked and came back through the port instead.
  int misses = 0;

  int _sumHitUs = 0;
  int _sumMissUs = 0;

  /// Native-async calls that attempted a spin.
  int get spins => hits + misses;

  /// Fraction of spins that landed off-port, `0` when nothing has spun yet.
  double get hitRate => spins == 0 ? 0 : hits / spins;

  /// Mean microseconds a hit took from spin start to the completion landing.
  double get avgHitUs => hits == 0 ? 0 : _sumHitUs / hits;

  /// Mean **true** completion latency of the calls that missed the window —
  /// measured uncensored (arm → port delivery), so it reflects how slow the
  /// missed completions really were, not the window. `avgMissUs` far above
  /// [avgHitUs] with a low [hitRate] means the workload is bimodal (a fast mode
  /// the spin catches plus a slow tail it can't) — the only shape where sizing
  /// the window below the cap could help. When it's empty or ≈ [avgHitUs] the
  /// workload is unimodal and the fixed cap is already near-optimal.
  double get avgMissUs => misses == 0 ? 0 : _sumMissUs / misses;

  /// Clears the counters (e.g. between benchmark phases or in tests).
  void reset() {
    hits = misses = _sumHitUs = _sumMissUs = 0;
  }

  // Updated by NitroCompletionBatch.spinPoll — not part of the public surface.
  void recordHit(int us) {
    hits++;
    _sumHitUs += us;
  }

  void recordMiss() => misses++;

  /// The uncensored latency of a missed completion, recorded when its port
  /// message finally arrives (see NitroCompletionBatch). Separate from
  /// [recordMiss] because the latency isn't known until later.
  void recordMissLatency(int us) => _sumMissUs += us;
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
  // Zone-aware print keeps package:nitro's import graph flutter-free, which
  // is what lets the runtime compile under plain `dart compile js/wasm` and
  // run in pure-Dart browser tests. Apps that want debugPrint throttling or
  // structured logging replace this whole handler via NitroConfig.logHandler.
  // ignore: avoid_print
  print('$prefix $message${error != null ? '\n  error: $error' : ''}${stack != null ? '\n  $stack' : ''}');
}
