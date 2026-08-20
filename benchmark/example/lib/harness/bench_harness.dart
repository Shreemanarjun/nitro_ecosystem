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
import 'dart:math' as math;

import 'package:benchmark/benchmark.dart' as bench;

import 'native_probes.dart' if (dart.library.io) 'native_probes_native.dart';
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

  static BenchConfig fromMode(String mode) => mode == 'full' ? full : quick;
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
  }) : iterations = 0,
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

  /// The hardware the run executed on: model/manufacturer/os (from the
  /// platform host via the `deviceInfo` channel method when available,
  /// Platform.* fallback otherwise). A benchmark number without the machine
  /// it ran on is not comparable to anything.
  final Map<String, Object?> device;

  /// Cross-tier workload equivalence proof: the FNV-1a hash each bridge tier
  /// returned for the same payload, and whether they all agree.
  final Map<String, Object?>? verification;

  BenchReport({
    required this.platform,
    required this.buildMode,
    required this.config,
    required this.results,
    required this.timestamp,
    this.device = const {},
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
    'nitro_platform_over_raw_ffi': _ratio('nitro_platform_add', 'raw_ffi_add'),
    'method_channel_over_nitro_cpp': _ratio(
      'method_channel_add',
      'nitro_cpp_add',
    ),
    'method_channel_over_nitro_leaf': _ratio(
      'method_channel_add',
      'nitro_leaf_add',
    ),
    'nitro_async_over_channel': _ratio(
      'nitro_async_record',
      'method_channel_add',
    ),
    'nitro_native_async_over_channel': _ratio(
      'nitro_native_async_record',
      'method_channel_add',
    ),
    // Cross-thread vs inline @nitroNativeAsync scalar: the multiplier the OS
    // isolate-wake adds over an inline post. >1 quantifies the real completion
    // cost the inline benchmark hides (issue #39).
    'nitro_native_async_xthread_over_inline': _ratio(
      'nitro_native_async_scalar_xthread',
      'nitro_native_async_scalar',
    ),
    // Coalescing effect on a 64-in-flight burst: coalesced ÷ per-call post.
    // <1 means batching the drained burst into one wake helped (issue #39).
    'nitro_native_async_coalesced_over_burst': _ratio(
      'nitro_native_async_burst64_coalesced',
      'nitro_native_async_burst64_percall',
    ),
    // Second algorithm (sieve): language-vs-language compute with near-zero
    // marshalling. dart_over_ffi ≈ Dart AOT vs C on identical work.
    'sieve_dart_over_raw_ffi': _ratio('dart_sieve', 'raw_ffi_sieve'),
    'sieve_cpp_over_raw_ffi': _ratio('nitro_cpp_sieve', 'raw_ffi_sieve'),
    'sieve_platform_over_raw_ffi': _ratio(
      'nitro_platform_sieve',
      'raw_ffi_sieve',
    ),
    'sieve_channel_over_cpp': _ratio('channel_sieve', 'nitro_cpp_sieve'),
  };

  Map<String, Object?> toJson() => {
    'schema': schemaVersion,
    'platform': platform,
    'buildMode': buildMode,
    'device': device,
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
    lines.add(
      '── Nitro bridge benchmark ($platform, $buildMode, '
      '${config.mode}) ──',
    );
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
      lines.add(
        '  ${r.label.padRight(28)} '
        '${stats.medianUs.toStringAsFixed(3).padLeft(10)} µs$vsFfi$vsChan',
      );
    }
    for (final r in results.where((r) => r.kind == BenchKind.throughput)) {
      final mb = r.mbPerSec;
      if (mb == null) {
        lines.add('  ${r.label.padRight(28)}    skipped — ${r.skipReason}');
        continue;
      }
      lines.add(
        '  ${r.label.padRight(28)} '
        '${mb.toStringAsFixed(0).padLeft(10)} MB/s '
        '(${(r.bytesPerOp! / (1024 * 1024)).toStringAsFixed(0)} MiB/op)',
      );
    }
    return lines;
  }
}

/// Runs the full cross-bridge suite and returns the report.
class BenchHarness {
  BenchHarness._();

  static const _channel = MethodChannel(
    'dev.shreeman.benchmark/method_channel',
  );

  static String get _buildMode =>
      kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug');

  static Future<BenchReport> run({
    BenchConfig config = BenchConfig.quick,
    void Function(String caseId)? onCaseStart,
  }) async {
    final cpp = bench.BenchmarkCpp.instance;
    final platformBridge = bench.Benchmark.instance;

    // Raw FFI floor — native-only (null on web, where the rows are skipped).
    // On native the probe resolves explicitly so a failed lookup is a hard
    // error, never a silent fall-back to pure Dart.
    final rawAdd = rawAddProbe();

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
        results.add(
          BenchResult(
            id: id,
            label: label,
            kind: BenchKind.latency,
            iterations: iters,
            stats: stats,
          ),
        );
      } catch (e) {
        // A bridge tier that doesn't exist on this platform (no MethodChannel
        // handler, no platform impl, …). Recorded so the report shape stays
        // comparable across platforms; the gate decides which cases are
        // mandatory — a skipped core case still fails the run there.
        results.add(
          BenchResult.skipped(
            id: id,
            label: label,
            kind: BenchKind.latency,
            reason: '${e.runtimeType}: $e'.split('\n').first,
          ),
        );
      }
    }

    // ── Latency: add(double, double) across every bridge tier ──────────────

    if (rawAdd != null) {
      await latencyCase('raw_ffi_add', 'Raw FFI (leaf)', config.syncIters, (n) {
        for (var i = 0; i < n; i++) {
          sink += rawAdd(1.0, i.toDouble());
        }
      });
    }

    await latencyCase('nitro_leaf_add', 'Nitro C++ (leaf)', config.syncIters, (
      n,
    ) {
      for (var i = 0; i < n; i++) {
        sink += cpp.addFast(1.0, i.toDouble());
      }
    });

    await latencyCase(
      'nitro_cpp_add',
      'Nitro C++ (checked)',
      config.syncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += cpp.add(1.0, i.toDouble());
        }
      },
    );

    // Multi-instance dispatch (improvement A): rotate calls across 4 distinct
    // native instances so the C-bridge instance cache is exercised. A single-
    // entry cache thrashed to the mutex+hashmap on every rotated call; the
    // 8-way cache keeps all four resident and lock-free. Compare against
    // nitro_cpp_add (same body, one instance) to isolate the lookup cost.
    const nInst = 4;
    final insts = [
      for (var i = 0; i < nInst; i++)
        bench.createBenchmarkCppInstance('bench_inst_$i'),
    ];
    for (final inst in insts) {
      inst.add(1.0, 1.0); // warm each instance into the cache
    }
    await latencyCase(
      'nitro_cpp_multi_instance',
      'Nitro C++ (4 instances, round-robin)',
      config.syncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += insts[i & (nInst - 1)].add(1.0, i.toDouble());
        }
      },
    );

    final platformBridgeLabel = switch (harnessOperatingSystem) {
      'android' => 'Nitro Kotlin (JNI)',
      'ios' || 'macos' => 'Nitro Swift',
      _ => 'Nitro platform C++',
    };
    await latencyCase(
      'nitro_platform_add',
      platformBridgeLabel,
      config.syncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += platformBridge.add(1.0, i.toDouble());
        }
      },
    );

    await latencyCase(
      'method_channel_add',
      'MethodChannel',
      config.asyncIters,
      (n) async {
        for (var i = 0; i < n; i++) {
          final v = await _channel.invokeMethod<double>('add', {
            'a': 1.0,
            'b': i.toDouble(),
          });
          sink += v ?? 0.0;
        }
      },
    );

    // ── Latency: richer payloads through Nitro ──────────────────────────────

    await latencyCase(
      'nitro_string_roundtrip',
      'Nitro String round-trip',
      config.syncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += cpp.getGreeting('bench').length.toDouble();
        }
      },
    );

    await latencyCase(
      'nitro_struct_roundtrip',
      'Nitro zero-copy struct',
      config.syncIters,
      (n) {
        const pt = bench.BenchmarkPoint(x: 1.5, y: 2.5);
        for (var i = 0; i < n; i++) {
          sink += cpp.scalePoint(pt, 2.0).x;
        }
      },
    );

    await latencyCase(
      'nitro_async_record',
      'Nitro @nitroAsync + record',
      config.asyncIters,
      (n) async {
        for (var i = 0; i < n; i++) {
          sink += (await cpp.computeStats(1)).meanUs;
        }
      },
    );

    // Zero-hop native-async twin of the case above — same payload, same
    // native computation (see HybridBenchmarkCpp::computeStatsBuffer), but
    // dispatched via Dart_PostCObject_DL from a persistent native worker
    // thread instead of the Dart isolate pool. Apples-to-apples comparison
    // of @nitroAsync vs @nitroNativeAsync dispatch overhead.
    await latencyCase(
      'nitro_native_async_record',
      'Nitro @nitroNativeAsync + record',
      config.asyncIters,
      (n) async {
        for (var i = 0; i < n; i++) {
          sink += (await cpp.computeStatsNative(1)).meanUs;
        }
      },
    );

    // ── Async DISPATCH isolation (near-zero payload) ─────────────────────────
    // The two cases above bundle record marshalling into the timing. These two
    // echo a single int, so the median is almost purely dispatch overhead:
    // the @nitroAsync isolate-pool hop vs the @nitroNativeAsync per-call
    // ReceivePort + error slot + Future (perf-audit target "D").
    await latencyCase(
      'nitro_async_scalar',
      'Nitro @nitroAsync (scalar)',
      config.asyncIters,
      (n) async {
        for (var i = 0; i < n; i++) {
          sink += (await cpp.asyncEcho(i)).toDouble();
        }
      },
    );

    await latencyCase(
      'nitro_native_async_scalar',
      'Nitro @nitroNativeAsync (scalar, inline post)',
      config.asyncIters,
      (n) async {
        for (var i = 0; i < n; i++) {
          sink += (await cpp.nativeAsyncEcho(i)).toDouble();
        }
      },
    );

    // Cross-thread completion: the native side posts from a long-lived worker
    // thread, so this pays the OS wake of a sleeping isolate that the inline
    // case above skips. The delta is the real cost of the @nitroNativeAsync
    // path any I/O plugin walks (issue #39).
    await latencyCase(
      'nitro_native_async_scalar_xthread',
      'Nitro @nitroNativeAsync (scalar, cross-thread post)',
      config.asyncIters,
      (n) async {
        for (var i = 0; i < n; i++) {
          sink += (await cpp.nativeAsyncEchoFromThread(i)).toDouble();
        }
      },
    );

    // ── Coalesced completion experiment (issue #39) ──────────────────────────
    // Sweep burst sizes: per-call posts vs coalesced (worker batches the drained
    // burst into one kArray). Logs the average batch size achieved.
    // Framework demuxer (package:nitro NitroCoalescer): one shared port + a
    // callId → Completer map. The native submit forwards (callId, nativePort)
    // to its coalescer; the batch arrives here and resolves each pending call.
    final coalescer = NitroCoalescer();
    Future<int> submitCoalesced(int value) => coalescer.submit(
        (callId, nativePort) => cpp.submitCoalesced(callId, value, nativePort));

    // Correctness pre-check on a 64-burst: every callId resolves to its value.
    {
      final r = await Future.wait([for (var i = 0; i < 64; i++) submitCoalesced(i)]);
      for (var i = 0; i < 64; i++) {
        if (r[i] != i) throw StateError('coalesce mismatch at $i: ${r[i]}');
      }
    }

    for (final burstSize in const [1, 4, 16, 64, 256]) {
      final burstIters = (config.asyncIters ~/ burstSize).clamp(20, 2000);

      await latencyCase(
        'nitro_native_async_burst${burstSize}_percall',
        'Nitro @nitroNativeAsync (burst×$burstSize, per-call post)',
        burstIters,
        (n) async {
          for (var b = 0; b < n; b++) {
            await Future.wait([
              for (var i = 0; i < burstSize; i++) cpp.nativeAsyncEchoFromThread(i),
            ]);
          }
        },
      );

      cpp.resetCoalesceStats();
      await latencyCase(
        'nitro_native_async_burst${burstSize}_coalesced',
        'Nitro @nitroNativeAsync (burst×$burstSize, coalesced post)',
        burstIters,
        (n) async {
          for (var b = 0; b < n; b++) {
            await Future.wait([
              for (var i = 0; i < burstSize; i++) submitCoalesced(i),
            ]);
          }
        },
      );
      final flushes = cpp.coalesceFlushes();
      final items = cpp.coalesceItems();
      final avgBatch = flushes == 0 ? 0.0 : items / flushes;
      // ignore: avoid_print
      print('BENCHX|coalesce burst=$burstSize avgBatch=${avgBatch.toStringAsFixed(1)} '
          'flushes=$flushes items=$items');
    }
    await coalescer.dispose();

    // ── Map<String,int> codec round-trip ─────────────────────────────────────
    // Echoes a fixed map through the Nitro binary map codec (Dart encode →
    // native re-emit → Dart decode). Isolates the map marshalling cost — the
    // encode currently does 3 full buffer copies (perf-audit target "B").
    final mapWorkload = <String, int>{
      for (var i = 0; i < 16; i++) 'key_$i': i * 7,
    };
    await latencyCase(
      'nitro_cpp_map',
      'Nitro C++ + Map<String,int> echo',
      config.asyncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += cpp.echoIntMap(mapWorkload).length.toDouble();
        }
      },
    );

    // ── List<@HybridRecord> codec round-trip ─────────────────────────────────
    // Echoes a fixed 16-record list through the indexed record-list codec
    // (encode → native re-emit → decode). Exercises `encodeIndexedList`, which
    // built one RecordWriter per item plus intermediate copies (perf-audit
    // target "#1").
    final statsWorkload = <bench.BenchmarkStats>[
      for (var i = 0; i < 16; i++)
        bench.BenchmarkStats(
          count: i,
          meanUs: i * 1.5,
          minUs: i.toDouble(),
          maxUs: i * 2.0,
        ),
    ];
    // Verify the round-trip before timing it. Summing `.length` alone cannot
    // tell a correct decode from a corrupt one: a codec that misreads item
    // bytes as an offset table still returns `count` items, so a silent
    // wire-format mismatch would be timed as if it were a real result.
    final statsEcho = cpp.echoStatsList(statsWorkload);
    if (statsEcho.length != statsWorkload.length) {
      throw StateError(
        'record-list echo returned ${statsEcho.length} items, '
        'expected ${statsWorkload.length}',
      );
    }
    for (var i = 0; i < statsWorkload.length; i++) {
      final a = statsWorkload[i], b = statsEcho[i];
      if (b.count != a.count ||
          b.meanUs != a.meanUs ||
          b.minUs != a.minUs ||
          b.maxUs != a.maxUs) {
        throw StateError(
          'record-list echo corrupted item $i: '
          'sent (${a.count}, ${a.meanUs}, ${a.minUs}, ${a.maxUs}) '
          'got (${b.count}, ${b.meanUs}, ${b.minUs}, ${b.maxUs})',
        );
      }
    }
    await latencyCase(
      'nitro_cpp_record_list',
      'Nitro C++ + List<@HybridRecord> echo',
      config.asyncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += cpp.echoStatsList(statsWorkload).length.toDouble();
        }
      },
    );

    // ── Latency: identical FNV-1a workload across every tier ────────────────
    // 1 KiB × 16 rounds ≈ 16k sequential byte-ops per call — real CPU work at
    // a scale where bridge overhead still matters. Every tier implements the
    // exact same algorithm (src/nitro_workload.h); the verification below
    // fails the whole run if any tier's hash disagrees, so these timings are
    // provably comparing identical work — only the bridge differs.
    final workload = Uint8List.fromList(
      List<int>.generate(1024, (i) => (i * 31) & 0xFF),
    );
    const workloadRounds = 16;
    // Raw dart:ffi tier — native-only (null on web, where the row is skipped).
    final rawFfiHash = rawFfiHashProbe(workload, workloadRounds);

    final verification = <String, Object?>{
      'workload': 'fnv1a-64 · 1 KiB × $workloadRounds rounds',
    };
    {
      final ffiH = rawFfiHash?.call();
      final cppH = cpp.hashBuffer(workload, workloadRounds);
      int? platH;
      try {
        platH = platformBridge.hashBuffer(workload, workloadRounds);
      } catch (_) {}
      int? chanH;
      try {
        chanH = await _channel.invokeMethod<int>('hashBuffer', {
          'data': workload,
          'rounds': workloadRounds,
        });
      } catch (_) {}
      if (ffiH != null) verification['rawFfiHash'] = ffiH;
      verification['nitroCppHash'] = cppH;
      if (platH != null) verification['nitroPlatformHash'] = platH;
      if (chanH != null) verification['methodChannelHash'] = chanH;
      final hashes = [?ffiH, cppH, ?platH, ?chanH];
      final agree = hashes.every((h) => h == cppH);
      verification['allTiersAgree'] = agree;
      verification['tiersVerified'] = hashes.length;
      if (!agree) {
        throw StateError(
          'Cross-tier workload hash mismatch — the comparison would not '
          'be measuring identical work: $verification',
        );
      }
    }

    if (rawFfiHash != null) {
      await latencyCase(
        'raw_ffi_hash',
        'Raw FFI + FNV-1a work',
        config.asyncIters,
        (n) {
          for (var i = 0; i < n; i++) {
            sink += rawFfiHash().toDouble();
          }
        },
      );
    }

    await latencyCase(
      'nitro_cpp_hash',
      'Nitro C++ + FNV-1a work',
      config.asyncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += cpp.hashBuffer(workload, workloadRounds).toDouble();
        }
      },
    );

    await latencyCase(
      'nitro_platform_hash',
      '$platformBridgeLabel + FNV-1a work',
      config.asyncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += platformBridge
              .hashBuffer(workload, workloadRounds)
              .toDouble();
        }
      },
    );

    await latencyCase(
      'channel_hash',
      'MethodChannel + FNV-1a work',
      config.asyncIters,
      (n) async {
        for (var i = 0; i < n; i++) {
          final v = await _channel.invokeMethod<int>('hashBuffer', {
            'data': workload,
            'rounds': workloadRounds,
          });
          sink += (v ?? 0).toDouble();
        }
      },
    );

    // ── Latency: identical sieve workload across every tier ────────────────
    // Second algorithm, deliberately different profile from FNV-1a: one heap
    // allocation + strided memory WRITES + data-dependent branches, and only
    // a single int64 crosses the bridge — so it isolates pure implementation-
    // language compute (C vs C++ vs Swift/Kotlin) with near-zero marshalling,
    // while the FNV-1a rows above include the 1 KiB payload crossing. Every
    // tier implements the exact same algorithm (src/nitro_workload.h); the
    // verification below fails the whole run on any disagreement.
    const sieveLimit = 4096;
    int dartSievePrimes(int limit) {
      if (limit < 2) return 0;
      final composite = List<bool>.filled(limit, false);
      var count = 0;
      for (var i = 2; i < limit; i++) {
        if (!composite[i]) {
          count++;
          for (var j = i * i; j < limit; j += i) {
            composite[j] = true;
          }
        }
      }
      return count;
    }

    final rawSieve = rawSieveProbe();

    {
      final dartCount = dartSievePrimes(sieveLimit);
      final ffiCount = rawSieve?.call(sieveLimit);
      final cppCount = cpp.sievePrimes(sieveLimit);
      int? platCount;
      try {
        platCount = platformBridge.sievePrimes(sieveLimit);
      } catch (_) {}
      int? chanCount;
      try {
        chanCount = await _channel.invokeMethod<int>('sievePrimes', {
          'limit': sieveLimit,
        });
      } catch (_) {}
      verification['workload2'] = 'sieve-of-eratosthenes · limit $sieveLimit';
      verification['dartSieve'] = dartCount;
      if (ffiCount != null) verification['rawFfiSieve'] = ffiCount;
      verification['nitroCppSieve'] = cppCount;
      if (platCount != null) verification['nitroPlatformSieve'] = platCount;
      if (chanCount != null) verification['methodChannelSieve'] = chanCount;
      final counts = [dartCount, ?ffiCount, cppCount, ?platCount, ?chanCount];
      final sieveAgree = counts.every((c) => c == dartCount);
      verification['sieveTiersAgree'] = sieveAgree;
      verification['sieveTiersVerified'] = counts.length;
      if (!sieveAgree) {
        throw StateError(
          'Cross-tier sieve count mismatch — the comparison would not '
          'be measuring identical work: $verification',
        );
      }
    }

    await latencyCase('dart_sieve', 'Pure Dart sieve (no bridge)', config.asyncIters, (
      n,
    ) {
      for (var i = 0; i < n; i++) {
        sink += dartSievePrimes(sieveLimit).toDouble();
      }
    });

    if (rawSieve != null) {
      await latencyCase('raw_ffi_sieve', 'Raw FFI + sieve work', config.asyncIters, (
        n,
      ) {
        for (var i = 0; i < n; i++) {
          sink += rawSieve(sieveLimit).toDouble();
        }
      });
    }

    await latencyCase('nitro_cpp_sieve', 'Nitro C++ + sieve work', config.asyncIters, (
      n,
    ) {
      for (var i = 0; i < n; i++) {
        sink += cpp.sievePrimes(sieveLimit).toDouble();
      }
    });

    await latencyCase(
      'nitro_platform_sieve',
      '$platformBridgeLabel + sieve work',
      config.asyncIters,
      (n) {
        for (var i = 0; i < n; i++) {
          sink += platformBridge.sievePrimes(sieveLimit).toDouble();
        }
      },
    );

    await latencyCase(
      'channel_sieve',
      'MethodChannel + sieve work',
      config.asyncIters,
      (n) async {
        for (var i = 0; i < n; i++) {
          final v = await _channel.invokeMethod<int>('sievePrimes', {
            'limit': sieveLimit,
          });
          sink += (v ?? 0).toDouble();
        }
      },
    );

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
        results.add(
          BenchResult(
            id: id,
            label: label,
            kind: BenchKind.throughput,
            iterations: config.bufferIters,
            stats: stats,
            bytesPerOp: config.bufferBytes,
          ),
        );
      } catch (e) {
        results.add(
          BenchResult.skipped(
            id: id,
            label: label,
            kind: BenchKind.throughput,
            reason: '${e.runtimeType}: $e'.split('\n').first,
          ),
        );
      }
    }

    await throughputCase('channel_buffer', 'MethodChannel buffer copy', (
      n,
    ) async {
      for (var i = 0; i < n; i++) {
        await _channel.invokeMethod<int>('sendLargeBuffer', buffer);
      }
    });

    // The "vanilla dart:ffi" way to send a Dart buffer: manually copy it into
    // arena-allocated native memory, call, free. The copy is the real cost of
    // hand-written FFI here — Nitro's pinned path below skips it entirely.
    final rawBufferSend = rawBufferSendProbe(buffer);
    if (rawBufferSend != null) {
      await throughputCase('raw_ffi_buffer', 'Raw FFI (manual copy)', (n) {
        for (var i = 0; i < n; i++) {
          sink += rawBufferSend().toDouble();
        }
      });
    }

    await throughputCase('nitro_buffer_pinned', 'Nitro pinned buffer (leaf)', (
      n,
    ) {
      for (var i = 0; i < n; i++) {
        sink += cpp.sendLargeBufferNoopFast(buffer).toDouble();
      }
    });

    final unsafeBuf = allocUnsafeBuffer(config.bufferBytes);
    if (unsafeBuf != null) {
      try {
        await throughputCase('nitro_buffer_unsafe', 'Nitro unsafe pointer', (
          n,
        ) {
          for (var i = 0; i < n; i++) {
            sink += cpp
                .sendLargeBufferUnsafe(unsafeBuf.ptr as dynamic, config.bufferBytes)
                .toDouble();
          }
        });
      } finally {
        unsafeBuf.free();
      }
    }

    // Publish the sink so the whole run is observably side-effecting.
    debugPrint('[BenchHarness] checksum: ${sink.toStringAsFixed(1)}');

    // Identify the hardware this run executed on. The platform host answers
    // `deviceInfo` with model/manufacturer (Build.* on Android, UIDevice +
    // utsname on iOS, sysctl hw.model on macOS); desktop hosts without a
    // handler fall back to what Dart alone can see.
    var device = hostDeviceInfo();
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
        'deviceInfo',
      );
      if (info != null) device = {...info, ...device};
    } catch (_) {}

    return BenchReport(
      platform: harnessOperatingSystem,
      buildMode: _buildMode,
      config: config,
      results: results,
      timestamp: DateTime.now(),
      device: device,
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
