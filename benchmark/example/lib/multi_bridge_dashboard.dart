import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'models/benchmark_bridge.dart';
import 'controllers/visual_benchmark_controller.dart';

class MultiBridgeDashboard extends StatefulWidget {
  const MultiBridgeDashboard({super.key});

  @override
  State<MultiBridgeDashboard> createState() => _MultiBridgeDashboardState();
}

class _MultiBridgeDashboardState extends State<MultiBridgeDashboard>
    with TickerProviderStateMixin {
  final _iterationSignal = signal<int>(1);
  final _isTestingSignal = signal<bool>(false);
  late final VisualBenchmarkController _controller;

  late final AnimationController _successController;
  late final Animation<double> _successAnimation;

  @override
  void initState() {
    super.initState();
    _controller = VisualBenchmarkController();

    _successController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _successAnimation = CurvedAnimation(
      parent: _successController,
      curve: Curves.elasticOut,
    );
  }

  @override
  void dispose() {
    _successController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _triggerSuccess() {
    _successController.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'NITRO THROUGHPUT',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            fontSize: 16,
          ),
        ),
        backgroundColor: Colors.black,
        actions: [
          Watch(
            (_) => Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(10),
                borderRadius: BorderRadius.circular(20),
              ),
              child: DropdownButton<int>(
                value: _iterationSignal.value,
                dropdownColor: Colors.grey.shade900,
                underline: const SizedBox.shrink(),
                icon: const Icon(
                  Icons.expand_more,
                  size: 14,
                  color: Colors.white54,
                ),
                style: const TextStyle(
                  color: Colors.cyan,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
                items: List.generate(10, (i) => i + 1)
                    .map(
                      (i) => DropdownMenuItem(
                        value: i,
                        child: Text('$i x Samples'),
                      ),
                    )
                    .toList(),
                onChanged: (v) => _iterationSignal.value = v ?? 1,
              ),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Colors.white.withAlpha(10)),
              ),
            ),
            child: Row(
              children: [
                Watch(
                  (_) => SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.psychology, size: 16),
                        label: Text('ACCURATE', style: TextStyle(fontSize: 9)),
                      ),
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.bolt, size: 16),
                        label: Text('FLOOR', style: TextStyle(fontSize: 9)),
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
                const Spacer(),
                IconButton(
                  icon: const Icon(
                    Icons.delete_sweep,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  onPressed: () {
                    for (var res in _controller.throughputResults.values) {
                      res.value = null;
                    }
                  },
                  tooltip: 'Clear Results',
                ),
                Watch(
                  (_) => _isTestingSignal.value
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.cyan,
                            ),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(
                            Icons.bolt,
                            color: Colors.cyanAccent,
                            size: 20,
                          ),
                          onPressed: () async {
                            _isTestingSignal.value = true;
                            final iterations = _iterationSignal.value;
                            final checksumValue =
                                _controller.isChecksumEnabled.value;
                            debugPrint(
                              '🚀 [NitroBenchmark] Starting Multi-Sample Throughput Profile (x$iterations, checksum=$checksumValue)...',
                            );
                            try {
                              for (var i = 0; i < iterations; i++) {
                                if (!mounted) return;
                                await _controller.runHighBandwidthTest(1);
                              }
                              if (mounted) {
                                _triggerSuccess();
                                _logFinalStats(iterations);
                              }
                            } finally {
                              _isTestingSignal.value = false;
                            }
                          },
                          tooltip: 'Run 1GB Test',
                        ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.analytics_outlined,
                    color: Colors.amberAccent,
                    size: 20,
                  ),
                  onPressed: _controller.runOneOffProfiler,
                ),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    _Quadrant(
                      controller: _controller,
                      type: BridgeType.methodChannel,
                      color: Colors.redAccent,
                      title: 'METHOD CHANNEL',
                      description: 'Legacy Binary Messaging',
                    ),
                    _Quadrant(
                      controller: _controller,
                      type: BridgeType.nitro,
                      color: Colors.deepPurpleAccent,
                      title: 'NITRO (SWIFT/KOTLIN)',
                      description: 'Automated Native Bridge',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    _Quadrant(
                      controller: _controller,
                      type: BridgeType.nitroCpp,
                      color: Colors.cyanAccent,
                      title: 'NITRO (DIRECT C++)',
                      description: 'Direct V-Table Dispatch',
                    ),
                    _Quadrant(
                      controller: _controller,
                      type: BridgeType.rawFfi,
                      color: Colors.greenAccent,
                      title: 'RAW FFI (BASELINE)',
                      description: 'Manual Pointer Interop',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    _Quadrant(
                      controller: _controller,
                      type: BridgeType.nitroLeaf,
                      color: Colors.orangeAccent,
                      title: 'NITRO (LEAF CALL)',
                      description: 'Zero-Safety Dispatch',
                    ),
                    _Quadrant(
                      controller: _controller,
                      type: BridgeType.nitroUnsafe,
                      color: Colors.deepOrangeAccent,
                      title: 'NITRO (UNSAFE PTR)',
                      description: 'Direct Memory Access',
                    ),
                  ],
                ),
              ),
              _DashboardStats(controller: _controller),
            ],
          ),
          // Success Overlay Animation
          Center(
            child: ScaleTransition(
              scale: _successAnimation,
              child: FadeTransition(
                opacity: ReverseAnimation(_successAnimation),
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: Colors.cyan.withAlpha(200),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.cyan.withAlpha(100),
                        blurRadius: 40,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 60),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _logFinalStats(int iterations) {
    final checksum = _controller.isChecksumEnabled.value;
    debugPrint(
      '\n📊 [NitroBenchmark] FINAL THROUGHPUT RESULTS (Averages over $iterations iterations, checksum=$checksum):',
    );
    for (var type in BridgeType.values) {
      final res = _controller.throughputResults[type]?.value;
      if (res != null) {
        debugPrint('   • ${type.label.padRight(25)}: $res');
      }
    }
    debugPrint('--------------------------------------------------\n');
  }
}

class _Quadrant extends StatelessWidget {
  final VisualBenchmarkController controller;
  final BridgeType type;
  final Color color;
  final String title;
  final String description;

  const _Quadrant({
    required this.controller,
    required this.type,
    required this.color,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.grey.shade900.withAlpha(200),
          border: Border.all(color: color.withAlpha(100), width: 0.5),
        ),
        child: Stack(
          children: [
            const _VisualPulse(),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                  Text(
                    description,
                    style: TextStyle(
                      color: Colors.white.withAlpha(100),
                      fontSize: 8,
                    ),
                  ),
                  const Spacer(),
                  Watch(
                    (_) => Text(
                      'Avg: ${controller.avgPerCallMicros[type]!.value.toStringAsFixed(3)} µs',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Watch((_) {
                    final res = controller.throughputResults[type]!.value;
                    if (res == null) return const SizedBox.shrink();
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: color.withAlpha(100),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        res,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VisualPulse extends StatefulWidget {
  const _VisualPulse();

  @override
  State<_VisualPulse> createState() => _VisualPulseState();
}

class _VisualPulseState extends State<_VisualPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withAlpha((10 * _controller.value).toInt()),
                Colors.transparent,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DashboardStats extends StatelessWidget {
  final VisualBenchmarkController controller;
  const _DashboardStats({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Watch((_) {
      if (controller.oneOffResults.values.every((s) => s.value == null)) {
        return const SizedBox.shrink();
      }

      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          border: Border(top: BorderSide(color: Colors.white.withAlpha(10))),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'API PERFORMANCE (µs)',
                  style: TextStyle(
                    color: Colors.amber,
                    fontWeight: FontWeight.bold,
                    fontSize: 9,
                  ),
                ),
                if (controller.winner.value != null)
                  Text(
                    'WINNER: ${controller.winner.value!.label}',
                    style: TextStyle(
                      color: controller.winner.value!.color,
                      fontWeight: FontWeight.w900,
                      fontSize: 9,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: BridgeType.values.map((type) {
                  final result = controller.oneOffResults[type]!.value;
                  if (result == null) return const SizedBox.shrink();

                  return Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: type.color.withAlpha(15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: type.color.withAlpha(30)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          type.label,
                          style: TextStyle(
                            color: type.color,
                            fontSize: 7,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${result.toStringAsFixed(2)}µs',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      );
    });
  }
}
