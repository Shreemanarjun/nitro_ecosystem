import 'package:signals_flutter/signals_flutter.dart';

import '../../harness/bench_harness.dart';

/// Drives the rigorous [BenchHarness] (the exact engine CI and the release
/// autorun use — warmup, median/p95 over N samples, cross-tier result
/// verification, both workloads) from the UI, with the iteration and sample
/// counts made customizable in-app.
class HarnessController {
  // ── Customizable knobs ────────────────────────────────────────────────
  /// Iterations per sample for tight sub-µs sync loops.
  static const iterationChoices = [5000, 10000, 20000, 50000, 100000];

  /// Independent samples per case; the median across them is the headline.
  static const sampleChoices = [3, 5, 10, 20];

  final iterationsIndex = signal(2); // 20,000
  final samplesIndex = signal(1); // 5

  int get iterations => iterationChoices[iterationsIndex.value];
  int get samples => sampleChoices[samplesIndex.value];

  // ── Run state ─────────────────────────────────────────────────────────
  final isRunning = signal(false);
  final currentCaseId = signal<String?>(null);
  final report = signal<BenchReport?>(null);
  final elapsedLabel = signal('');

  /// Async/channel cases run far fewer iterations than the sync fast paths
  /// (they are µs–ms each) — scale down so a 100k sync run doesn't spend
  /// minutes on the channel loop.
  int get _asyncIters => (iterations ~/ 40).clamp(200, 2000);

  BenchConfig get _config => BenchConfig(
    mode: 'custom',
    syncIters: iterations,
    asyncIters: _asyncIters,
    samples: samples,
    bufferBytes: 16 * 1024 * 1024,
    bufferIters: 3,
  );

  Future<void> run() async {
    if (isRunning.value) return;
    isRunning.value = true;
    currentCaseId.value = null;
    final sw = Stopwatch()..start();
    try {
      final r = await BenchHarness.run(
        config: _config,
        onCaseStart: (id) => currentCaseId.value = id,
      );
      report.value = r;
      elapsedLabel.value = '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';
    } finally {
      isRunning.value = false;
      currentCaseId.value = null;
    }
  }

  void dispose() {
    iterationsIndex.dispose();
    samplesIndex.dispose();
    isRunning.dispose();
    currentCaseId.dispose();
    report.dispose();
    elapsedLabel.dispose();
  }
}
