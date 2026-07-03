// Headless benchmark harness — no UI, no signals, no charts.
//
// Measures every bridge tier (raw FFI floor → Nitro paths → MethodChannel)
// with a consistent methodology and produces a machine-readable report:
//
//   * warmup pass before any timing
//   * batch timing: one Stopwatch around a tight loop of N calls
//     (never per-call Stopwatch — its own overhead is ~40ns)
//   * K independent samples per case → median / mean / min / p95
//
// Consumed by `integration_test/benchmark_regression_test.dart` (regression
// gate) and serialized to JSON for `tool/bench.sh` / CI trend tracking.
//
// This file is native-only (dart:ffi via package:nitro). It is deliberately
// NOT imported from main.dart so the example app still builds for web.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:benchmark/benchmark.dart' as bench;
import 'package:flutter/foundation.dart'
    show debugPrint, kProfileMode, kReleaseMode;
import 'package:flutter/services.dart';
import 'package:nitro/nitro.dart';

/// What a case measures — latency cases gate regressions; throughput cases
/// are informational (MB/s varies too much across hardware to gate).
enum BenchKind { latency, throughput }

/// Iteration/sample counts for one run.
class BenchConfig {
  final String mode;

  /// Iterations per sample for tight sync loops (sub-µs calls).
  final int syncIters;

  /// Iterations per sample for async / MethodChannel cases (µs–ms calls).
  final int asyncIters;

  /// Independent samples per case; median over samples is the headline stat.
  final int samples;

  /// Payload size for buffer-throughput cases.
  final int bufferBytes;

  /// Calls per sample for buffer cases.
  final int bufferIters;

  const BenchConfig({
    required this.mode,
    required this.syncIters,
    required this.asyncIters,
    required this.samples,
    required this.bufferBytes,
    required this.bufferIters,
  });

  /// CI-friendly: full suite in well under a minute on a shared runner.
  static const quick = BenchConfig(
    mode: 'quick',
    syncIters: 20000,
    asyncIters: 500,
    samples: 5,
    bufferBytes: 16 * 1024 * 1024,
    bufferIters: 3,
  );

  /// Publication-quality numbers on a dedicated machine.
  static const full = BenchConfig(
    mode: 'full',
    syncIters: 100000,
    asyncIters: 2000,
    samples: 10,
    bufferBytes: 64 * 1024 * 1024,
    bufferIters: 5,
  );

  static BenchConfig fromMode(String mode) =>
      mode == 'full' ? full : quick;
}

class BenchStats {
  final double medianUs;
  final double meanUs;
  final double minUs;
  final double p95Us;
  final List<double> samplesUs;

  BenchStats(this.samplesUs)
      : medianUs = _percentile(samplesUs, 0.50),
        meanUs = samplesUs.reduce((a, b) => a + b) / samplesUs.length,
        minUs = samplesUs.reduce(math.min),
        p95Us = _percentile(samplesUs, 0.95);

  static double _percentile(List<double> values, double p) {
    final sorted = [...values]..sort();
    final rank = (sorted.length - 1) * p;
    final low = sorted[rank.floor()];
    final high = sorted[rank.ceil()];
    return low + (high - low) * (rank - rank.floor());
  }
}

class BenchResult {
  final String id;
  final String label;
  final BenchKind kind;
  final int iterations;

  /// null when the case was skipped on this platform (see [skipReason]).
  final BenchStats? stats;

  /// Why the case did not run — e.g. no MethodChannel handler on this
  /// platform, or a bridge tier that does not exist here. A skipped case is
  /// recorded (so reports stay comparable across platforms) but never gated.
  final String? skipReason;

  /// Bytes moved per call for throughput cases (null for latency cases).
  final int? bytesPerOp;

  BenchResult({
    required this.id,
    required this.label,
    required this.kind,
    required this.iterations,
    required BenchStats this.stats,
    this.bytesPerOp,
  }) : skipReason = null;

  BenchResult.skipped({
    required this.id,
    required this.label,
    required this.kind,
    required String reason,
  })  : iterations = 0,
        stats = null,
        bytesPerOp = null,
        skipReason = reason;

  bool get isSkipped => stats == null;

  /// bytes/µs numerically equals MB/s (10^6 bytes per second).
  double? get mbPerSec => bytesPerOp == null || stats == null
      ? null
      : bytesPerOp! / stats!.medianUs;

  Map<String, Object?> toJson() => {
        'label': label,
        'kind': kind.name,
        if (skipReason != null) 'skipped': skipReason,
        if (stats != null) ...{
          'iterations': iterations,
          'samples': stats!.samplesUs.length,
          'medianUs': stats!.medianUs,
          'meanUs': stats!.meanUs,
          'minUs': stats!.minUs,
          'p95Us': stats!.p95Us,
        },
        if (bytesPerOp != null) 'bytesPerOp': bytesPerOp,
        if (mbPerSec != null) 'mbPerSec': mbPerSec,
      };
}

class BenchReport {
  static const schemaVersion = 1;

  final String platform;
  final String buildMode;
  final BenchConfig config;
  final List<BenchResult> results;
  final DateTime timestamp;

  /// Cross-tier workload equivalence proof: the FNV-1a hash each bridge tier
  /// returned for the same payload, and whether they all agree.
  final Map<String, Object?>? verification;

  BenchReport({
    required this.platform,
    required this.buildMode,
    required this.config,
    required this.results,
    required this.timestamp,
    this.verification,
  });

  BenchResult? caseById(String id) {
    for (final r in results) {
      if (r.id == id) return r;
    }
    return null;
  }

  double? _ratio(String numeratorId, String denominatorId) {
    final n = caseById(numeratorId)?.stats;
    final d = caseById(denominatorId)?.stats;
    if (n == null || d == null || d.medianUs == 0) return null;
    return n.medianUs / d.medianUs;
  }

  /// Cross-bridge ratios — machine-independent, so these (not absolute µs)
  /// are what the CI regression gate enforces.
  Map<String, double?> get derived => {
        'nitro_leaf_over_raw_ffi': _ratio('nitro_leaf_add', 'raw_ffi_add'),
        'nitro_cpp_over_raw_ffi': _ratio('nitro_cpp_add', 'raw_ffi_add'),
        'nitro_platform_over_raw_ffi':
            _ratio('nitro_platform_add', 'raw_ffi_add'),
        'method_channel_over_nitro_cpp':
            _ratio('method_channel_add', 'nitro_cpp_add'),
        'method_channel_over_nitro_leaf':
            _ratio('method_channel_add', 'nitro_leaf_add'),
      };

  Map<String, Object?> toJson() => {
        'schema': schemaVersion,
        'platform': platform,
        'buildMode': buildMode,
        'mode': config.mode,
        'timestampMs': timestamp.millisecondsSinceEpoch,
        if (verification != null) 'verification': verification,
        'cases': {for (final r in results) r.id: r.toJson()},
        'derived': derived,
      };

  /// Human-readable summary printed to the device log.
  List<String> toTableLines() {
    final lines = <String>[];
    final rawFfi = caseById('raw_ffi_add')?.stats?.medianUs;
    final channel = caseById('method_channel_add')?.stats?.medianUs;
    lines.add('── Nitro bridge benchmark ($platform, $buildMode, '
        '${config.mode}) ──');
    for (final r in results.where((r) => r.kind == BenchKind.latency)) {
      final stats = r.stats;
      if (stats == null) {
        lines.add('  ${r.label.padRight(28)}    skipped — ${r.skipReason}');
        continue;
      }
      final vsFfi = rawFfi == null || rawFfi == 0
          ? ''
          : ' · ${(stats.medianUs / rawFfi).toStringAsFixed(2)}× raw FFI';
      final vsChan = channel == null || stats.medianUs == 0
          ? ''
          : ' · ${(channel / stats.medianUs).toStringAsFixed(1)}× faster '
              'than channel';
      lines.add('  ${r.label.padRight(28)} '
          '${stats.medianUs.toStringAsFixed(3).padLeft(10)} µs$vsFfi$vsChan');
    }
    for (final r in results.where((r) => r.kind == BenchKind.throughput)) {
      final mb = r.mbPerSec;
      if (mb == null) {
        lines.add('  ${r.label.padRight(28)}    skipped — ${r.skipReason}');
        continue;
      }
      lines.add('  ${r.label.padRight(28)} '
          '${mb.toStringAsFixed(0).padLeft(10)} MB/s '
          '(${(r.bytesPerOp! / (1024 * 1024)).toStringAsFixed(0)} MiB/op)');
    }
    return lines;
  }
}

/// Runs the full cross-bridge suite and returns the report.
class BenchHarness {
  BenchHarness._();

  static const _channel = MethodChannel('dev.shreeman.benchmark/method_channel');

  static String get _buildMode =>
      kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');

  static Future<BenchReport> run({
    BenchConfig config = BenchConfig.quick,
    void Function(String caseId)? onCaseStart,
  }) async {
    final cpp = bench.BenchmarkCpp.instance;
    final platformBridge = bench.Benchmark.instance;

    // Raw FFI floor — resolved explicitly so a failed lookup is a hard error,
    // never a silent fall-back to pure Dart (which would corrupt every ratio).
    final rawAdd = NitroRuntime.loadLib('benchmark_cpp').lookupFunction<
        Double Function(Double, Double),
        double Function(double, double)>('add_double', isLeaf: true);

    // Keep results observable so the optimizer cannot elide any call.
    var sink = 0.0;

    final results = <BenchResult>[];

    Future<void> latencyCase(
      String id,
      String label,
      int iters,
      FutureOr<void> Function(int n) batch,
    ) async {
      onCaseStart?.call(id);
      try {
        final stats = await _measure(
          iters: iters,
          samples: config.samples,
          batch: batch,
        );
        results.add(BenchResult(
          id: id,
          label: label,
          kind: BenchKind.latency,
          iterations: iters,
          stats: stats,
        ));
      } catch (e) {
        // A bridge tier that doesn't exist on this platform (no MethodChannel
        // handler, no platform impl, …). Recorded so the report shape stays
        // comparable across platforms; the gate decides which cases are
        // mandatory — a skipped core case still fails the run there.
        results.add(BenchResult.skipped(
          id: id,
          label: label,
          kind: BenchKind.latency,
          reason: '${e.runtimeType}: $e'.split('\n').first,
        ));
      }
    }

    // ── Latency: add(double, double) across every bridge tier ──────────────

    await latencyCase('raw_ffi_add', 'Raw FFI (leaf)', config.syncIters, (n) {
      for (var i = 0; i < n; i++) {
        sink += rawAdd(1.0, i.toDouble());
      }
    });

    await latencyCase('nitro_leaf_add', 'Nitro C++ (leaf)', config.syncIters,
        (n) {
      for (var i = 0; i < n; i++) {
        sink += cpp.addFast(1.0, i.toDouble());
      }
    });

    await latencyCase('nitro_cpp_add', 'Nitro C++ (checked)', config.syncIters,
        (n) {
      for (var i = 0; i < n; i++) {
        sink += cpp.add(1.0, i.toDouble());
      }
    });

    final platformBridgeLabel = switch (Platform.operatingSystem) {
      'android' => 'Nitro Kotlin (JNI)',
      'ios' || 'macos' => 'Nitro Swift',
      _ => 'Nitro platform C++',
    };
    await latencyCase(
        'nitro_platform_add', platformBridgeLabel, config.syncIters, (n) {
      for (var i = 0; i < n; i++) {
        sink += platformBridge.add(1.0, i.toDouble());
      }
    });

    await latencyCase(
        'method_channel_add', 'MethodChannel', config.asyncIters, (n) async {
      for (var i = 0; i < n; i++) {
        final v = await _channel
            .invokeMethod<double>('add', {'a': 1.0, 'b': i.toDouble()});
        sink += v ?? 0.0;
      }
    });

    // ── Latency: richer payloads through Nitro ──────────────────────────────

    await latencyCase(
        'nitro_string_roundtrip', 'Nitro String round-trip', config.syncIters,
        (n) {
      for (var i = 0; i < n; i++) {
        sink += cpp.getGreeting('bench').length.toDouble();
      }
    });

    await latencyCase(
        'nitro_struct_roundtrip', 'Nitro zero-copy struct', config.syncIters,
        (n) {
      const pt = bench.BenchmarkPoint(x: 1.5, y: 2.5);
      for (var i = 0; i < n; i++) {
        sink += cpp.scalePoint(pt, 2.0).x;
      }
    });

    await latencyCase(
        'nitro_async_record', 'Nitro @nitroAsync + record', config.asyncIters,
        (n) async {
      for (var i = 0; i < n; i++) {
        sink += (await cpp.computeStats(1)).meanUs;
      }
    });

    // ── Latency: identical FNV-1a workload across every tier ────────────────
    // 1 KiB × 16 rounds ≈ 16k sequential byte-ops per call — real CPU work at
    // a scale where bridge overhead still matters. Every tier implements the
    // exact same algorithm (src/nitro_workload.h); the verification below
    // fails the whole run if any tier's hash disagrees, so these timings are
    // provably comparing identical work — only the bridge differs.
    final workload =
        Uint8List.fromList(List<int>.generate(1024, (i) => (i * 31) & 0xFF));
    const workloadRounds = 16;
    final rawFnv = NitroRuntime.loadLib('benchmark_cpp').lookupFunction<
        Uint64 Function(Pointer<Uint8>, Int64, Int64),
        int Function(Pointer<Uint8>, int, int)>('fnv1a_hash');
    int rawFfiHash() => withArena((arena) =>
        rawFnv(workload.toPointer(arena), workload.length, workloadRounds));

    final verification = <String, Object?>{
      'workload': 'fnv1a-64 · 1 KiB × $workloadRounds rounds',
    };
    {
      final ffiH = rawFfiHash();
      final cppH = cpp.hashBuffer(workload, workloadRounds);
      int? platH;
      try {
        platH = platformBridge.hashBuffer(workload, workloadRounds);
      } catch (_) {}
      int? chanH;
      try {
        chanH = await _channel.invokeMethod<int>(
            'hashBuffer', {'data': workload, 'rounds': workloadRounds});
      } catch (_) {}
      verification['rawFfiHash'] = ffiH;
      verification['nitroCppHash'] = cppH;
      if (platH != null) verification['nitroPlatformHash'] = platH;
      if (chanH != null) verification['methodChannelHash'] = chanH;
      final hashes = [ffiH, cppH, ?platH, ?chanH];
      final agree = hashes.every((h) => h == ffiH);
      verification['allTiersAgree'] = agree;
      verification['tiersVerified'] = hashes.length;
      if (!agree) {
        throw StateError(
            'Cross-tier workload hash mismatch — the comparison would not '
            'be measuring identical work: $verification');
      }
    }

    await latencyCase(
        'raw_ffi_hash', 'Raw FFI + FNV-1a work', config.asyncIters, (n) {
      for (var i = 0; i < n; i++) {
        sink += rawFfiHash().toDouble();
      }
    });

    await latencyCase(
        'nitro_cpp_hash', 'Nitro C++ + FNV-1a work', config.asyncIters, (n) {
      for (var i = 0; i < n; i++) {
        sink += cpp.hashBuffer(workload, workloadRounds).toDouble();
      }
    });

    await latencyCase('nitro_platform_hash',
        '$platformBridgeLabel + FNV-1a work', config.asyncIters, (n) {
      for (var i = 0; i < n; i++) {
        sink += platformBridge.hashBuffer(workload, workloadRounds).toDouble();
      }
    });

    await latencyCase('channel_hash', 'MethodChannel + FNV-1a work',
        config.asyncIters, (n) async {
      for (var i = 0; i < n; i++) {
        final v = await _channel.invokeMethod<int>(
            'hashBuffer', {'data': workload, 'rounds': workloadRounds});
        sink += (v ?? 0).toDouble();
      }
    });

    // ── Throughput: 16–64 MiB buffer transport (informational) ─────────────

    final buffer = Uint8List(config.bufferBytes);

    Future<void> throughputCase(
      String id,
      String label,
      FutureOr<void> Function(int n) batch,
    ) async {
      onCaseStart?.call(id);
      try {
        final stats = await _measure(
          iters: config.bufferIters,
          samples: config.samples,
          warmupIters: 1,
          batch: batch,
        );
        results.add(BenchResult(
          id: id,
          label: label,
          kind: BenchKind.throughput,
          iterations: config.bufferIters,
          stats: stats,
          bytesPerOp: config.bufferBytes,
        ));
      } catch (e) {
        results.add(BenchResult.skipped(
          id: id,
          label: label,
          kind: BenchKind.throughput,
          reason: '${e.runtimeType}: $e'.split('\n').first,
        ));
      }
    }

    await throughputCase('channel_buffer', 'MethodChannel buffer copy',
        (n) async {
      for (var i = 0; i < n; i++) {
        await _channel.invokeMethod<int>('sendLargeBuffer', buffer);
      }
    });

    // The "vanilla dart:ffi" way to send a Dart buffer: manually copy it into
    // arena-allocated native memory, call, free. The copy is the real cost of
    // hand-written FFI here — Nitro's pinned path below skips it entirely.
    final rawSendNoop = NitroRuntime.loadLib('benchmark_cpp').lookupFunction<
        Int64 Function(Pointer<Uint8>, Int64),
        int Function(Pointer<Uint8>, int)>('send_large_buffer_noop');
    await throughputCase('raw_ffi_buffer', 'Raw FFI (manual copy)', (n) {
      for (var i = 0; i < n; i++) {
        withArena((arena) {
          sink += rawSendNoop(buffer.toPointer(arena), buffer.length)
              .toDouble();
        });
      }
    });

    await throughputCase('nitro_buffer_pinned', 'Nitro pinned buffer (leaf)',
        (n) {
      for (var i = 0; i < n; i++) {
        sink += cpp.sendLargeBufferNoopFast(buffer).toDouble();
      }
    });

    final rawPtr = malloc<Uint8>(config.bufferBytes);
    try {
      await throughputCase('nitro_buffer_unsafe', 'Nitro unsafe pointer', (n) {
        for (var i = 0; i < n; i++) {
          sink += cpp
              .sendLargeBufferUnsafe(rawPtr, config.bufferBytes)
              .toDouble();
        }
      });
    } finally {
      malloc.free(rawPtr);
    }

    // Publish the sink so the whole run is observably side-effecting.
    debugPrint('[BenchHarness] checksum: ${sink.toStringAsFixed(1)}');

    return BenchReport(
      platform: Platform.operatingSystem,
      buildMode: _buildMode,
      config: config,
      results: results,
      timestamp: DateTime.now(),
      verification: verification,
    );
  }

  static Future<BenchStats> _measure({
    required int iters,
    required int samples,
    required FutureOr<void> Function(int n) batch,
    int? warmupIters,
  }) async {
    await batch(warmupIters ?? math.max(iters ~/ 10, 50));
    final perOpUs = <double>[];
    for (var s = 0; s < samples; s++) {
      // Let the event loop drain between samples so queued microtasks from
      // async cases don't bleed into the next timing window.
      await Future<void>.delayed(Duration.zero);
      final sw = Stopwatch()..start();
      await batch(iters);
      sw.stop();
      perOpUs.add(sw.elapsedMicroseconds / iters);
    }
    return BenchStats(perOpUs);
  }
}
