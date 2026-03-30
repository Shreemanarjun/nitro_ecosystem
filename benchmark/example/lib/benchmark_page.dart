import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'controllers/benchmark_controller.dart';
import 'models/benchmark_bridge.dart';
import 'widgets/benchmark_chart.dart';
import 'widgets/benchmark_controls.dart';
import 'widgets/benchmark_history.dart';
import 'widgets/iteration_selector.dart';
import 'widgets/runs_selector.dart';
import 'widgets/status_card.dart';
import 'box_stress_page.dart';

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  final _controller = BenchmarkController();

  void _showOneOffResults(
    BuildContext context,
    Map<BridgeType, double> results,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('One-Off Test Results (µs)'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: results.entries.map((e) {
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 6.0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: e.key.color.withAlpha(20),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: e.key.color.withAlpha(50)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: e.key.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            e.key.label,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${e.value.toStringAsFixed(3)} µs',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      color: Colors.amber,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Nitro Benchmark',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const BoxStressPage()),
            ),
            icon: const Icon(Icons.flash_on, color: Colors.amber),
            tooltip: 'Stress Test',
          ),
          IconButton(
            onPressed: () => _controller.clear(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Clear',
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Iteration Selector
                Watch(
                  (context) => IterationSelector(
                    count: _controller.iterationCount.value,
                    onChanged: (val) => _controller.iterationCount.value = val,
                  ),
                ),
                const SizedBox(height: 12),

                // Runs Selector
                Watch(
                  (context) => RunsSelector(
                    count: _controller.runsCount.value,
                    onChanged: (val) => _controller.runsCount.value = val,
                  ),
                ),
                const SizedBox(height: 12),

                // Benchmark Controls
                Watch(
                  (context) => BenchmarkControls(
                    isRunning: _controller.isRunning.value,
                    onRunSequential: () => _controller.runSequential(),
                    onRunSimultaneous: () => _controller.runSimultaneous(),
                    onRunOneOff: () async {
                      final results = await _controller.runOneOff();
                      if (results.isNotEmpty && context.mounted) {
                        _showOneOffResults(context, results);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 24),

                // Status Card
                Watch(
                  (context) => StatusCard(
                    isRunning: _controller.isRunning.value,
                    status: _controller.status.value,
                    currentIteration: _controller.currentIteration.value,
                    totalIterations: _controller.iterationCount.value,
                    bridgeLabel: _controller.currentBridge.value?.label,
                    currentRun: _controller.currentRun.value,
                    totalRuns: _controller.runsCount.value,
                  ),
                ),
                const SizedBox(height: 32),

                // Sequential Latency Chart
                Watch(
                  (context) => BenchmarkChart(
                    title: 'Sequential latency',
                    subtitle: 'Latency per call (Smaller is better)',
                    spotsMap: _controller.sequentialSpots.value,
                  ),
                ),
                const SizedBox(height: 48),

                // Simultaneous Throughput Chart
                Watch(
                  (context) => BenchmarkChart(
                    title: 'Simultaneous throughput',
                    subtitle:
                        'Average time per call in batch (Smaller is better)',
                    spotsMap: _controller.simultaneousSpots.value,
                  ),
                ),
                const SizedBox(height: 48),

                // History List
                Watch(
                  (context) =>
                      BenchmarkHistory(history: _controller.history.value),
                ),
                const SizedBox(height: 48),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
