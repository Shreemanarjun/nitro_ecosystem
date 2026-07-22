import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'harness_controller.dart';
import 'models/bench_category.dart';
import 'widgets/category_section.dart';
import 'widgets/config_panel.dart';
import 'widgets/report_header.dart';

/// "Compare" tab — the rigorous cross-bridge comparison, driven by the same
/// [BenchHarness] as CI and the release autorun (warmup, median/p95, verified
/// workloads) with the run counts customizable in-app and results grouped by
/// category.
class HarnessScreen extends StatefulWidget {
  const HarnessScreen({super.key});

  @override
  State<HarnessScreen> createState() => _HarnessScreenState();
}

class _HarnessScreenState extends State<HarnessScreen> {
  final _c = HarnessController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Bridge Comparison',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: Watch((context) {
        final report = _c.report.value;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList.list(
                children: [
                  ConfigPanel(
                    iterationChoices: HarnessController.iterationChoices,
                    iterationsIndex: _c.iterationsIndex.value,
                    onIterations: (i) => _c.iterationsIndex.value = i,
                    sampleChoices: HarnessController.sampleChoices,
                    samplesIndex: _c.samplesIndex.value,
                    onSamples: (i) => _c.samplesIndex.value = i,
                    isRunning: _c.isRunning.value,
                    onRun: _c.run,
                    currentCaseId: _c.currentCaseId.value,
                  ),
                  const SizedBox(height: 16),
                  if (report == null && !_c.isRunning.value)
                    const _EmptyState()
                  else if (report == null)
                    const _RunningState()
                  else ...[
                    ReportHeader(report: report, elapsed: _c.elapsedLabel.value),
                    const SizedBox(height: 16),
                    for (final cat in kBenchCategories)
                      CategorySection(category: cat, report: report),
                    const _Legend(),
                    const SizedBox(height: 32),
                  ],
                ],
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      alignment: Alignment.center,
      child: Column(
        children: [
          Icon(Icons.insights, size: 56, color: Colors.cyan.withAlpha(120)),
          const SizedBox(height: 16),
          const Text(
            'Compare every bridge, head to head',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 8),
          const Text(
            'Raw FFI (C) · Nitro C++ · Nitro Swift/Kotlin · MethodChannel\n'
            'across two verified workloads. Pick your run counts above and '
            'hit Run — the harness verifies every tier produces identical '
            'results before timing.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Colors.white54, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _RunningState extends StatelessWidget {
  const _RunningState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'Warming up and timing each tier…',
              style: TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'Bars are normalized within each category (latency: longer = slower; '
        'throughput: longer = faster). "×" is relative to that category\'s '
        'baseline. Median over N samples is the headline; p95 shown below each '
        'latency bar. Numbers reflect this device and build mode — see '
        'benchmark/RESULTS.md for the cross-platform matrix.',
        style: TextStyle(fontSize: 11, color: Colors.white38, height: 1.5),
      ),
    );
  }
}
