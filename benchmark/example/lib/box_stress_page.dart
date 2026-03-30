import 'dart:math' as math;
import 'package:benchmark/benchmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'models/benchmark_bridge.dart';
import 'controllers/visual_benchmark_controller.dart';

// --- UI LAYER ---

class BoxStressPage extends StatefulWidget {
  const BoxStressPage({super.key});

  @override
  State<BoxStressPage> createState() => _BoxStressPageState();
}

class _BoxStressPageState extends State<BoxStressPage> {
  late final VisualBenchmarkController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VisualBenchmarkController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'NITRO STRESS',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            fontSize: 16,
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(80),
          child: Column(
            children: [
              // 🚀 ROW 2: Engine Config (Checksum vs Noop)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                height: 32,
                child: Row(
                  children: [
                    const Icon(Icons.settings, size: 12, color: Colors.white54),
                    const SizedBox(width: 8),
                    const Text(
                      'CORE:',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.white54,
                        letterSpacing: 1.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Watch(
                        (_) => SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              icon: Icon(Icons.security, size: 14),
                              label: Text('VAL', style: TextStyle(fontSize: 9)),
                            ),
                            ButtonSegment(
                              value: false,
                              icon: Icon(Icons.bolt, size: 14),
                              label: Text(
                                'FLOOR',
                                style: TextStyle(fontSize: 9),
                              ),
                            ),
                          ],
                          selected: {_controller.isChecksumEnabled.value},
                          onSelectionChanged: (v) =>
                              _controller.isChecksumEnabled.value = v.first,
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.delete_sweep,
                        color: Colors.redAccent,
                        size: 18,
                      ),
                      onPressed: () {
                        for (var res in _controller.throughputResults.values) {
                          res.value = null;
                        }
                      },
                      tooltip: 'Clear Results',
                    ),
                  ],
                ),
              ),
              // 🚀 ROW 3: High-Bandwidth & Master Control
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Colors.white.withAlpha(5)),
                  ),
                  color: Colors.white.withAlpha(5),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.speed, size: 14, color: Colors.cyanAccent),
                    const SizedBox(width: 8),
                    const Text(
                      'THROUGHPUT ENGINE',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.cyanAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Watch(
                      (_) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.sd_storage,
                              color: Colors.cyanAccent,
                              size: 20,
                            ),
                            onPressed: _controller.isBusy.value
                                ? null
                                : () async {
                                    _controller.isBusy.value = true;
                                    try {
                                      await _controller.runHighBandwidthTest(1);
                                    } finally {
                                      _controller.isBusy.value = false;
                                    }
                                  },
                            tooltip: 'Run 1MB Throughput Test',
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.analytics_outlined,
                              color: Colors.amberAccent,
                              size: 20,
                            ),
                            onPressed: _controller.isBusy.value
                                ? null
                                : () async {
                                    _controller.isBusy.value = true;
                                    try {
                                      await _controller.runOneOffProfiler();
                                    } finally {
                                      _controller.isBusy.value = false;
                                    }
                                  },
                            tooltip: 'Run Profiler',
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(
                      width: 12,
                      indent: 8,
                      endIndent: 8,
                      color: Colors.white24,
                    ),
                    const Text(
                      'LIVE STRESS',
                      style: TextStyle(
                        fontSize: 9,
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Watch(
                      (_) => Transform.scale(
                        scale: 0.7,
                        child: Switch(
                          value: _controller.isRunning.value,
                          activeThumbColor: Colors.greenAccent,
                          activeTrackColor: Colors.green.withAlpha(100),
                          onChanged: _controller.toggleRunning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Row(
              children: [
                _BridgePanel(
                  controller: _controller,
                  type: BridgeType.methodChannel,
                  title: 'Normal (MethodChannel)',
                  color: Colors.red,
                ),
                _BridgePanel(
                  controller: _controller,
                  type: BridgeType.nitro,
                  title: 'Nitro (Kotlin/Swift)',
                  color: Colors.deepPurple,
                ),
              ],
            ),
            Row(
              children: [
                _BridgePanel(
                  controller: _controller,
                  type: BridgeType.nitroCpp,
                  title: 'Nitro FFI (Dart ↔ C++)',
                  color: Colors.cyan,
                ),
                _BridgePanel(
                  controller: _controller,
                  type: BridgeType.rawFfi,
                  title: 'Raw FFI (Minimal)',
                  color: Colors.green,
                ),
              ],
            ),
            Row(
              children: [
                _BridgePanel(
                  controller: _controller,
                  type: BridgeType.nitroCppStruct,
                  title: 'Nitro (C++ Struct)',
                  color: Colors.teal,
                ),
                _BridgePanel(
                  controller: _controller,
                  type: BridgeType.nitroCppAsync,
                  title: 'Nitro (C++ Async)',
                  color: Colors.lightBlue,
                ),
              ],
            ),
            Row(
              children: [
                _BridgePanel(
                  controller: _controller,
                  type: BridgeType.nitroLeaf,
                  title: 'Nitro (Leaf Call)',
                  color: Colors.orange,
                ),
                _BridgePanel(
                  controller: _controller,
                  type: BridgeType.nitroUnsafe,
                  title: 'Nitro (Unsafe Ptr)',
                  color: Colors.deepOrangeAccent,
                ),
              ],
            ),
            _SummaryPanel(controller: _controller),
          ],
        ),
      ),
    );
  }
}

class _BridgePanel extends StatelessWidget {
  final VisualBenchmarkController controller;
  final BridgeType type;
  final String title;
  final Color color;

  const _BridgePanel({
    required this.controller,
    required this.type,
    required this.title,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fpsSignal = controller.currentFps[type]!;
    final latencySignal = controller.avgPerCallMicros[type]!;
    final tickSignal = controller.tickCounts[type]!;
    final throughputSignal = controller.throughputResults[type]!;

    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(4),
        height: 140,
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          border: Border.all(color: color.withAlpha(50)),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            _BridgeDriver(
              controller: controller,
              type: type,
              onTick: () => tickSignal.value++,
            ),
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  Watch(
                    (_) => Text(
                      '${fpsSignal.value.toStringAsFixed(1)} FPS',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Watch(
                    (_) => Text(
                      'Avg: ${latencySignal.value.toStringAsFixed(3)}µs',
                      style: TextStyle(
                        color: Colors.amber.withAlpha(180),
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Watch(
                    (_) => throughputSignal.value != null
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: color.withAlpha(100),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              throughputSignal.value!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BridgeDriver extends StatefulWidget {
  final VisualBenchmarkController controller;
  final BridgeType type;
  final VoidCallback onTick;

  const _BridgeDriver({
    required this.controller,
    required this.type,
    required this.onTick,
  });

  @override
  State<_BridgeDriver> createState() => _BridgeDriverState();
}

class _BridgeDriverState extends State<_BridgeDriver>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  final _boxSignal = signal<BenchmarkBox?>(null);
  EffectCleanup? _sub;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _sub =
        (widget.controller.isRunning..subscribe((running) {
              if (running) {
                _ticker?.start();
              } else {
                _ticker?.stop();
                _boxSignal.value = null;
              }
            }))
            .call;
  }

  void _onTick(Duration elapsed) {
    if (!widget.controller.isRunning.value) return;

    final double angle = elapsed.inMilliseconds / 200.0;
    final colorVal =
        0xFF000000 |
        ((((math.sin(angle) + 1.0) * 127).toInt() << 16)) |
        ((((math.sin(angle + 2.0) + 1.0) * 127).toInt() << 8)) |
        ((math.sin(angle + 4.0) + 1.0) * 127).toInt();

    final width = 100.0 + math.sin(angle * 0.5) * 50.0;
    final height = 100.0 + math.cos(angle * 0.5) * 50.0;

    if (widget.type == BridgeType.methodChannel) {
      final sw = Stopwatch()..start();
      widget.controller.channel.invokeMethod('add', {'a': 1.0, 'b': 2.0}).then((
        _,
      ) {
        sw.stop();
        widget.controller.recordCallLatency(
          widget.type,
          sw.elapsedMicroseconds.toDouble(),
        );
      });
    } else if (widget.type == BridgeType.nitro) {
      final sw = Stopwatch()..start();
      Benchmark.instance.add(1.0, 2.0);
      sw.stop();
      widget.controller.recordCallLatency(
        widget.type,
        sw.elapsedMicroseconds.toDouble(),
      );
    } else if (widget.type == BridgeType.nitroCpp) {
      final sw = Stopwatch()..start();
      BenchmarkCpp.instance.addFast(1.0, 2.0);
      sw.stop();
      widget.controller.recordCallLatency(
        widget.type,
        sw.elapsedMicroseconds.toDouble(),
      );
    } else if (widget.type == BridgeType.nitroCppStruct) {
      final sw = Stopwatch()..start();
      BenchmarkCpp.instance.scalePoint(BenchmarkPoint(x: 1, y: 2), 1.0);
      sw.stop();
      widget.controller.recordCallLatency(
        widget.type,
        sw.elapsedMicroseconds.toDouble(),
      );
    } else if (widget.type == BridgeType.nitroCppAsync) {
      final sw = Stopwatch()..start();
      BenchmarkCpp.instance.computeStats(1).then((_) {
        sw.stop();
        widget.controller.recordCallLatency(
          widget.type,
          sw.elapsedMicroseconds.toDouble(),
        );
      });
    } else if (widget.type == BridgeType.rawFfi) {
      final sw = Stopwatch()..start();
      widget.controller.rawAdd(1.0, 2.0);
      sw.stop();
      widget.controller.recordCallLatency(
        widget.type,
        sw.elapsedMicroseconds.toDouble(),
      );
    } else if (widget.type == BridgeType.nitroLeaf ||
        widget.type == BridgeType.nitroUnsafe) {
      final sw = Stopwatch()..start();
      BenchmarkCpp.instance.addFast(1.0, 2.0);
      sw.stop();
      widget.controller.recordCallLatency(
        widget.type,
        sw.elapsedMicroseconds.toDouble(),
      );
    }

    _boxSignal.value = BenchmarkBox(
      color: colorVal,
      width: width,
      height: height,
    );
    widget.onTick();
  }

  @override
  void dispose() {
    _sub?.call();
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Watch((_) {
      final box = _boxSignal.value;
      if (box == null) return const SizedBox.shrink();

      return Center(
        child: Container(
          width: box.width,
          height: box.height,
          decoration: BoxDecoration(
            color: Color(box.color),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(color: Color(box.color).withAlpha(100), blurRadius: 20),
            ],
          ),
        ),
      );
    });
  }
}

class _SummaryPanel extends StatelessWidget {
  final VisualBenchmarkController controller;
  const _SummaryPanel({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Watch((_) {
      if (controller.oneOffResults.values.every((s) => s.value == null)) {
        return const SizedBox.shrink();
      }

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          border: Border(top: BorderSide(color: Colors.white.withAlpha(20))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ONE-OFF RESULTS (50 iter)',
                  style: TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                if (controller.winner.value != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: controller.winner.value!.color.withAlpha(100),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'WINNER: ${controller.winner.value!.label.toUpperCase()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: BridgeType.values.map((type) {
                final result = controller.oneOffResults[type]!.value;
                if (result == null) return const SizedBox.shrink();

                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: type.color.withAlpha(20),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: type.color.withAlpha(40)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        type.label,
                        style: TextStyle(
                          color: type.color,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${result.toStringAsFixed(3)}µs',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );
    });
  }
}

class BenchmarkBox {
  final int color;
  final double width;
  final double height;
  BenchmarkBox({
    required this.color,
    required this.width,
    required this.height,
  });
}
