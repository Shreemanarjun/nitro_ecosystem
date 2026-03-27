import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:nitro/nitro.dart';
import 'package:benchmark/benchmark.dart' as plugin;
import 'package:fl_chart/fl_chart.dart';

import '../models/benchmark_bridge.dart';
import '../models/benchmark_history.dart';

class BenchmarkController {
  // --- Signals (State) ---
  final isRunning = signal(false);
  final status = signal('Ready');
  final iterationCount = signal(50000);
  final runsCount = signal(10);
  final currentIteration = signal(0);
  final currentRun = signal(0);
  final currentBridge = signal<BridgeType?>(null);
  final history = listSignal<BenchmarkHistoryEntry>([]);

  final sequentialSpots = mapSignal<BridgeType, List<FlSpot>>({
    for (var bridge in BridgeType.values) bridge: [],
  });

  final simultaneousSpots = mapSignal<BridgeType, List<FlSpot>>({
    for (var bridge in BridgeType.values) bridge: [],
  });

  // --- Private Bridge State ---
  static const _channel = MethodChannel(
    'dev.shreeman.benchmark/method_channel',
  );
  late final DynamicLibrary _dylib;
  double Function(double, double)? _rawAdd;

  BenchmarkController() {
    _initFfi();
  }

  void _initFfi() {
    try {
      _dylib = NitroRuntime.loadLib('benchmark');
      _rawAdd = _dylib
          .lookup<NativeFunction<Double Function(Double, Double)>>('add_double')
          .asFunction<double Function(double, double)>();
    } catch (e) {
      debugPrint('Failed to load raw FFI: $e');
    }
  }

  void clear() {
    for (var bridge in BridgeType.values) {
      sequentialSpots[bridge] = [];
      simultaneousSpots[bridge] = [];
    }
    status.value = 'Cleared';
  }

  Future<double> _callBridge(BridgeType bridge, double a, double b) async {
    switch (bridge) {
      case BridgeType.nitro:
        return plugin.Benchmark.instance.add(a, b);

      case BridgeType.nitroCpp:
        // Baseline: sync C++ direct dispatch
        return plugin.BenchmarkCpp.instance.add(a, b);

      case BridgeType.nitroCppStruct:
        // Zero-copy struct param + return — measures struct marshalling overhead
        final pt = plugin.BenchmarkPoint(x: a, y: b);
        final scaled = plugin.BenchmarkCpp.instance.scalePoint(pt, 1.0);
        return scaled.x + scaled.y;

      case BridgeType.nitroCppAsync:
        // Async Future returning a @HybridRecord — measures Future + record overhead
        final stats = await plugin.BenchmarkCpp.instance.computeStats(1);
        return stats.meanUs;

      case BridgeType.nitroLeaf:
        // Absolute best performance: Leaf Call + No Error Check
        return plugin.BenchmarkCpp.instance.addFast(a, b);

      case BridgeType.rawFfi:
        if (_rawAdd == null) throw Exception('Raw FFI bridge not initialized');
        return _rawAdd!(a, b);

      case BridgeType.methodChannel:
        final res = await _channel.invokeMethod<double>('add', {
          'a': a,
          'b': b,
        });
        return res ?? 0.0;
    }
  }

  Future<void> runSequential() async {
    if (isRunning.value) return;
    final count = iterationCount.value;
    final runs = runsCount.value;

    isRunning.value = true;
    clear();

    final allRunsResults = <BridgeType, List<double>>{
      for (var bridge in BridgeType.values) bridge: [],
    };

    for (var r = 0; r < runs; r++) {
      currentRun.value = r + 1;
      status.value = 'Sequential (Run ${r + 1}/$runs, $count iterations)...';

      for (final bridge in BridgeType.values) {
        currentBridge.value = bridge;
        final spots = <FlSpot>[];
        final swTotal = Stopwatch()..start();

        for (var i = 0; i < count; i++) {
          final sw = Stopwatch()..start();
          await _callBridge(bridge, i.toDouble(), i.toDouble());
          sw.stop();

          if (i % 200 == 0) {
            currentIteration.value = i;
            spots.add(FlSpot(i.toDouble(), sw.elapsedMicroseconds.toDouble()));
            sequentialSpots[bridge] = List.from(spots);
            await Future.delayed(Duration.zero);
          }
        }
        swTotal.stop();
        final currentAvg = swTotal.elapsedMicroseconds / count;
        allRunsResults[bridge]!.add(currentAvg);
      }
    }

    final avgResults = <BridgeType, double>{};
    final minResults = <BridgeType, double>{};
    final maxResults = <BridgeType, double>{};

    for (final bridge in BridgeType.values) {
      final runsList = allRunsResults[bridge]!;
      avgResults[bridge] = runsList.reduce((a, b) => a + b) / runsList.length;
      minResults[bridge] = runsList.reduce((a, b) => a < b ? a : b);
      maxResults[bridge] = runsList.reduce((a, b) => a > b ? a : b);
    }

    final winner = avgResults.entries.reduce(
      (a, b) => a.value < b.value ? a : b,
    );

    debugPrint(
      '--- SEQUENTIAL BENCHMARK COMPLETE ($runs runs of $count iterations) ---',
    );
    avgResults.forEach((bridge, avg) {
      debugPrint(
        '${bridge.label}: ${avg.toStringAsFixed(3)} µs/avg [Min: ${minResults[bridge]!.toStringAsFixed(3)}, Max: ${maxResults[bridge]!.toStringAsFixed(3)}]',
      );
    });
    debugPrint('WINNER: ${winner.key.label}');

    status.value =
        'Sequential Avg Winner: ${winner.key.label} (${winner.value.toStringAsFixed(3)} µs)';
    history.add(
      BenchmarkHistoryEntry(
        timestamp: DateTime.now(),
        category: 'Sequential ($runs runs)',
        iterations: count,
        winner: winner.key,
        winnerAvgUs: winner.value,
        avgResults: avgResults,
        minResults: minResults,
        maxResults: maxResults,
      ),
    );

    isRunning.value = false;
    currentBridge.value = null;
    currentIteration.value = 0;
    currentRun.value = 0;
  }

  Future<void> runSimultaneous() async {
    if (isRunning.value) return;
    final count = iterationCount.value;
    final runs = runsCount.value;

    isRunning.value = true;
    clear();

    final allRunsResults = <BridgeType, List<double>>{
      for (var bridge in BridgeType.values) bridge: [],
    };

    for (var r = 0; r < runs; r++) {
      currentRun.value = r + 1;
      status.value = 'Simultaneous (Run ${r + 1}/$runs, $count iterations)...';

      for (final bridge in BridgeType.values) {
        currentBridge.value = bridge;
        final swTotal = Stopwatch()..start();
        final futures = <Future>[];
        for (var i = 0; i < count; i++) {
          futures.add(_callBridge(bridge, i.toDouble(), i.toDouble()));

          if (i % 200 == 199 || i == count - 1) {
            currentIteration.value = i;
            await Future.wait(futures);
            futures.clear();

            final currentUs = swTotal.elapsedMicroseconds.toDouble() / (i + 1);
            simultaneousSpots[bridge] = [
              ...simultaneousSpots[bridge]!,
              FlSpot(i.toDouble(), currentUs),
            ];
            await Future.delayed(Duration.zero);
          }
        }
        swTotal.stop();
        final currentAvg = swTotal.elapsedMicroseconds / count;
        allRunsResults[bridge]!.add(currentAvg);
      }
    }

    final avgResults = <BridgeType, double>{};
    final minResults = <BridgeType, double>{};
    final maxResults = <BridgeType, double>{};

    for (final bridge in BridgeType.values) {
      final runsList = allRunsResults[bridge]!;
      avgResults[bridge] = runsList.reduce((a, b) => a + b) / runsList.length;
      minResults[bridge] = runsList.reduce((a, b) => a < b ? a : b);
      maxResults[bridge] = runsList.reduce((a, b) => a > b ? a : b);
    }

    final winner = avgResults.entries.reduce(
      (a, b) => a.value < b.value ? a : b,
    );

    debugPrint(
      '--- SIMULTANEOUS BENCHMARK COMPLETE ($runs runs of $count iterations) ---',
    );
    avgResults.forEach((bridge, avg) {
      debugPrint(
        '${bridge.label}: ${avg.toStringAsFixed(3)} µs/avg [Min: ${minResults[bridge]!.toStringAsFixed(3)}, Max: ${maxResults[bridge]!.toStringAsFixed(3)}]',
      );
    });
    debugPrint('WINNER: ${winner.key.label}');

    status.value =
        'Simultaneous Avg Winner: ${winner.key.label} (${winner.value.toStringAsFixed(3)} µs)';
    history.add(
      BenchmarkHistoryEntry(
        timestamp: DateTime.now(),
        category: 'Simultaneous ($runs runs)',
        iterations: count,
        winner: winner.key,
        winnerAvgUs: winner.value,
        avgResults: avgResults,
        minResults: minResults,
        maxResults: maxResults,
      ),
    );

    isRunning.value = false;
    currentBridge.value = null;
    currentIteration.value = 0;
    currentRun.value = 0;
  }

  Future<Map<BridgeType, double>> runOneOff() async {
    if (isRunning.value) return {};
    isRunning.value = true;
    status.value = 'Running One-Off Test...';

    final results = <BridgeType, double>{};
    const iterations = 50;

    for (final bridge in BridgeType.values) {
      await _callBridge(bridge, 10.0, 20.0);
      final sw = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        await _callBridge(bridge, 10.0, 20.0);
      }
      sw.stop();
      results[bridge] = sw.elapsedMicroseconds / iterations;
    }

    status.value = 'One-Off Test Complete';
    isRunning.value = false;

    debugPrint('--- ONE-OFF TEST COMPLETE ($iterations iterations) ---');
    results.forEach((bridge, avg) {
      debugPrint('${bridge.label}: ${avg.toStringAsFixed(3)} µs');
    });

    final winner = results.entries.reduce((a, b) => a.value < b.value ? a : b);
    debugPrint('WINNER: ${winner.key.label}');

    history.add(
      BenchmarkHistoryEntry(
        timestamp: DateTime.now(),
        category: 'One-Off',
        iterations: iterations,
        winner: winner.key,
        winnerAvgUs: winner.value,
        avgResults: results,
        minResults: results,
        maxResults: results,
      ),
    );

    return results;
  }
}
