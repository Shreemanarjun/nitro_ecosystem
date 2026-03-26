import 'dart:async';
import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:benchmark/benchmark.dart' as plugin;
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:nitro/nitro.dart';

import 'models/benchmark_bridge.dart';
import 'widgets/benchmark_chart.dart';
import 'widgets/benchmark_controls.dart';
import 'widgets/status_card.dart';

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  static const _channel = MethodChannel(
    'dev.shreeman.benchmark/method_channel',
  );
  late final DynamicLibrary _dylib;
  double Function(double, double)? _rawAdd;

  bool _isRunning = false;
  String _status = 'Ready';

  final Map<BridgeType, List<FlSpot>> _sequentialSpots = {
    for (var bridge in BridgeType.values) bridge: [],
  };

  final Map<BridgeType, List<FlSpot>> _simultaneousSpots = {
    for (var bridge in BridgeType.values) bridge: [],
  };

  @override
  void initState() {
    super.initState();
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

  void _clear() {
    setState(() {
      for (var bridge in BridgeType.values) {
        _sequentialSpots[bridge]!.clear();
        _simultaneousSpots[bridge]!.clear();
      }
      _status = 'Cleared';
    });
  }

  Future<double> _callBridge(BridgeType bridge, double a, double b) async {
    switch (bridge) {
      case BridgeType.nitro:
        return plugin.Benchmark.instance.add(a, b);
      case BridgeType.rawFfi:
        if (_rawAdd == null) {
          throw Exception(
            'Raw FFI bridge not initialized (symbol add_double not found)',
          );
        }
        return _rawAdd!(a, b);
      case BridgeType.methodChannel:
        final res = await _channel.invokeMethod<double>('add', {
          'a': a,
          'b': b,
        });
        return res ?? 0.0;
    }
  }

  Future<void> _runOneOff() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _status = 'Running One-Off Test...';
    });

    final results = <BridgeType, double>{};
    const iterations = 50; // Average of 50 to reduce noise

    for (final bridge in BridgeType.values) {
      // Warm up
      await _callBridge(bridge, 10.0, 20.0);

      final stopWatch = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        await _callBridge(bridge, 10.0, 20.0);
      }
      stopWatch.stop();
      results[bridge] = stopWatch.elapsedMicroseconds / iterations;
    }

    if (!mounted) return;
    setState(() {
      _isRunning = false;
      _status = 'One-Off Test Complete';
    });

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
                  Row(
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
                      Text(
                        e.key.label,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
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

  Future<void> _runSequential(int count) async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _status = 'Running Sequential ($count iterations)...';
      _clear();
    });

    final averages = <BridgeType, double>{};

    for (final bridge in BridgeType.values) {
      final spots = <FlSpot>[];
      final swTotal = Stopwatch()..start();
      
      for (var i = 0; i < count; i++) {
        final sw = Stopwatch()..start();
        await _callBridge(bridge, i.toDouble(), i.toDouble());
        sw.stop();

        if (i % 100 == 0) {
          spots.add(FlSpot(i.toDouble(), sw.elapsedMicroseconds.toDouble()));
          setState(() {
            _sequentialSpots[bridge] = List.from(spots);
          });
          await Future.delayed(Duration.zero);
        }
      }
      swTotal.stop();
      averages[bridge] = swTotal.elapsedMicroseconds / count;
      debugPrint('SEQUENTIAL [${bridge.label}]: ${averages[bridge]!.toStringAsFixed(3)} µs/avg');
    }

    final winner = averages.entries.reduce((a, b) => a.value < b.value ? a : b);
    
    setState(() {
      _isRunning = false;
      _status = 'Sequential Winner: ${winner.key.label} (${winner.value.toStringAsFixed(3)} µs)';
    });
    debugPrint('--- SEQUENTIAL BENCHMARK COMPLETE ---');
    debugPrint('WINNER: ${winner.key.label}');
  }

  Future<void> _runSimultaneous(int count) async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _status = 'Running Simultaneous ($count iterations)...';
      _clear();
    });

    final averages = <BridgeType, double>{};

    for (final bridge in BridgeType.values) {
      final swTotal = Stopwatch()..start();
      final futures = <Future>[];
      for (var i = 0; i < count; i++) {
        futures.add(_callBridge(bridge, i.toDouble(), i.toDouble()));

        if (i % 200 == 199 || i == count - 1) {
          await Future.wait(futures);
          futures.clear();

          final currentUs = swTotal.elapsedMicroseconds.toDouble() / (i + 1);
          setState(() {
            _simultaneousSpots[bridge] = [
              ..._simultaneousSpots[bridge]!,
              FlSpot(i.toDouble(), currentUs),
            ];
          });
          await Future.delayed(Duration.zero);
        }
      }
      swTotal.stop();
      averages[bridge] = swTotal.elapsedMicroseconds / count;
      debugPrint('SIMULTANEOUS [${bridge.label}]: ${averages[bridge]!.toStringAsFixed(3)} µs/avg');
    }

    final winner = averages.entries.reduce((a, b) => a.value < b.value ? a : b);

    setState(() {
      _isRunning = false;
      _status = 'Simultaneous Winner: ${winner.key.label} (${winner.value.toStringAsFixed(3)} µs)';
    });
    debugPrint('--- SIMULTANEOUS BENCHMARK COMPLETE ---');
    debugPrint('WINNER: ${winner.key.label}');
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
            onPressed: _clear,
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
                BenchmarkControls(
                  isRunning: _isRunning,
                  onRunSequential: () => _runSequential(10000),
                  onRunSimultaneous: () => _runSimultaneous(10000),
                  onRunOneOff: _runOneOff,
                ),
                const SizedBox(height: 24),
                StatusCard(isRunning: _isRunning, status: _status),
                const SizedBox(height: 32),
                BenchmarkChart(
                  title: 'Sequential latency',
                  subtitle: 'Latency per call (Smaller is better)',
                  spotsMap: _sequentialSpots,
                ),
                const SizedBox(height: 48),
                BenchmarkChart(
                  title: 'Simultaneous throughput',
                  subtitle:
                      'Average time per call in batch (Smaller is better)',
                  spotsMap: _simultaneousSpots,
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
