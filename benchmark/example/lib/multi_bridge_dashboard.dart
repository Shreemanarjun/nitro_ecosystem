import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'box_stress_page.dart';
import 'models/benchmark_bridge.dart';

class MultiBridgeDashboard extends StatefulWidget {
  const MultiBridgeDashboard({super.key});

  @override
  State<MultiBridgeDashboard> createState() => _MultiBridgeDashboardState();
}

class _MultiBridgeDashboardState extends State<MultiBridgeDashboard>
    with TickerProviderStateMixin {
  final _iterationSignal = signal<int>(1);
  final _isTestingSignal = signal<bool>(false);

  late final AnimationController _successController;
  late final Animation<double> _successAnimation;

  @override
  void initState() {
    super.initState();
    BenchmarkManager.init();

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
    BenchmarkManager.dispose();
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
                    selected: {BenchmarkManager.isChecksumEnabled.value},
                    onSelectionChanged: (v) =>
                        BenchmarkManager.isChecksumEnabled.value = v.first,
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
                    for (var res in BenchmarkManager.throughputResults.values) {
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
                                BenchmarkManager.isChecksumEnabled.value;
                            debugPrint(
                              '🚀 [NitroBenchmark] Starting Multi-Sample Throughput Profile (x$iterations, checksum=$checksumValue)...',
                            );
                            try {
                              for (var i = 0; i < iterations; i++) {
                                if (!mounted) return;
                                await BenchmarkManager.runHighBandwidthTest(1);
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
                  onPressed: BenchmarkManager.runOneOffProfiler,
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
                      type: BridgeType.methodChannel,
                      color: Colors.redAccent,
                      title: 'METHOD CHANNEL',
                      description: 'Legacy Binary Messaging',
                    ),
                    _Quadrant(
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
                      type: BridgeType.nitroCpp,
                      color: Colors.cyanAccent,
                      title: 'NITRO (DIRECT C++)',
                      description: 'Direct V-Table Dispatch',
                    ),
                    _Quadrant(
                      type: BridgeType.rawFfi,
                      color: Colors.greenAccent,
                      title: 'RAW FFI (BASELINE)',
                      description: 'Manual Pointer Interop',
                    ),
                  ],
                ),
              ),
              const _DashboardStats(),
            ],
          ),
          // Success Overlay Animation
          Center(
            child: ScaleTransition(
              scale: _successAnimation,
              child: FadeTransition(
                opacity: ReverseAnimation(_successAnimation),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.green.withAlpha(200),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green.withAlpha(100),
                        blurRadius: 40,
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, color: Colors.white),
                      SizedBox(width: 12),
                      Text(
                        'SUCCESS',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _logFinalStats(int iterations) {
    final checksum = BenchmarkManager.isChecksumEnabled.value;
    debugPrint(
      '\n📊 [NitroBenchmark] FINAL THROUGHPUT RESULTS (Averages over $iterations iterations, checksum=$checksum):',
    );
    for (var type in BridgeType.values) {
      final res = BenchmarkManager.throughputResults[type]?.value;
      if (res != null) {
        debugPrint('   • ${type.label.padRight(25)}: $res');
      }
    }
    debugPrint('--------------------------------------------------\n');
  }
}

class _Quadrant extends StatelessWidget {
  final BridgeType type;
  final Color color;
  final String title;
  final String description;

  const _Quadrant({
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
                      'Avg: ${BenchmarkManager.avgPerCallMicros[type]!.value.toStringAsFixed(3)} µs',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Watch((_) {
                    final res = BenchmarkManager.throughputResults[type]!.value;
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

class _VisualPulse extends StatelessWidget {
  const _VisualPulse();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Opacity(
        opacity: 0.2,
        child: const Icon(Icons.speed, size: 80, color: Colors.white10),
      ),
    );
  }
}

class _DashboardStats extends StatelessWidget {
  const _DashboardStats();

  @override
  Widget build(BuildContext context) {
    return Watch((_) {
      final winner = BenchmarkManager.winner.value;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          border: const Border(top: BorderSide(color: Colors.white10)),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'THROUGHPUT DIAGNOSTICS',
                  style: TextStyle(
                    color: Colors.white54,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                ),
                if (winner != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withAlpha(100),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'WINNER: ${winner.label}',
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.w900,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _GlobalMetric(label: 'ZERO-COPY', value: '4.0 GB+'),
                _GlobalMetric(label: 'OVERHEAD', value: '< 1µs'),
                _GlobalMetric(label: 'FFI GEN', value: 'v0.2.5'),
              ],
            ),
          ],
        ),
      );
    });
  }
}

class _GlobalMetric extends StatelessWidget {
  final String label;
  final String value;
  const _GlobalMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white24,
            fontSize: 8,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
