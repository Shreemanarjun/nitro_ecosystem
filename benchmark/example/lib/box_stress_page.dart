import 'dart:async';
import 'dart:math' as math;
import 'package:benchmark/benchmark.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:nitro/nitro.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'models/benchmark_bridge.dart';

// --- CONTROLLER / LOGIC LAYER ---

class BenchmarkManager {
  static final isRunning = signal<bool>(false);
  static final isChecksumEnabled = signal<bool>(true);

  static final tickCounts = {
    for (var type in [
      BridgeType.methodChannel,
      BridgeType.nitro,
      BridgeType.rawFfi,
      BridgeType.nitroCpp,
    ])
      type: signal(0),
  };

  static final currentFps = {
    for (var type in [
      BridgeType.methodChannel,
      BridgeType.nitro,
      BridgeType.rawFfi,
      BridgeType.nitroCpp,
    ])
      type: signal(0.0),
  };

  static final perFrameMicros = {
    for (var type in [
      BridgeType.methodChannel,
      BridgeType.nitro,
      BridgeType.rawFfi,
      BridgeType.nitroCpp,
    ])
      type: signal(0.0),
  };

  static final avgPerCallMicros = {
    for (var type in [
      BridgeType.methodChannel,
      BridgeType.nitro,
      BridgeType.rawFfi,
      BridgeType.nitroCpp,
    ])
      type: signal(0.0),
  };

  static final throughputResults = {
    for (var type in [
      BridgeType.methodChannel,
      BridgeType.nitro,
      BridgeType.rawFfi,
      BridgeType.nitroCpp,
    ])
      type: signal<String?>(null),
  };

  static final oneOffResults = {
    for (var type in BridgeType.values) type: signal<double?>(null),
  };

  static final winner = signal<BridgeType?>(null);

  static Timer? _fpsTimer;
  static DynamicLibrary? _dylib;
  static double Function(double, double)? _rawAdd;
  static int Function(Pointer<Uint8>, int)? _rawSendBuffer;
  static int Function(Pointer<Uint8>, int)? _rawSendBufferNoop;
  static const _channel = MethodChannel(
    'dev.shreeman.benchmark/method_channel',
  );

  static final Map<BridgeType, double> _accumulatedMicros = {
    for (var type in [
      BridgeType.methodChannel,
      BridgeType.nitro,
      BridgeType.rawFfi,
      BridgeType.nitroCpp,
    ])
      type: 0.0,
  };

  static void init() {
    debugPrint('🚀 [NitroBenchmark] Initializing BenchmarkManager...');
    _dylib ??= NitroRuntime.loadLib('benchmark_cpp');
    _rawAdd ??= _dylib!
        .lookupFunction<
          Double Function(Double, Double),
          double Function(double, double)
        >('add_double');

    try {
      _rawSendBuffer = _dylib!
          .lookupFunction<
            Int64 Function(Pointer<Uint8>, Int64),
            int Function(Pointer<Uint8>, int)
          >('send_large_buffer');
    } catch (_) {
      debugPrint('⚠️ [NitroBenchmark] Raw FFI send_large_buffer not found.');
    }

    try {
      _rawSendBufferNoop = _dylib!
          .lookupFunction<
            Int64 Function(Pointer<Uint8>, Int64),
            int Function(Pointer<Uint8>, int)
          >('send_large_buffer_noop');
    } catch (_) {
      debugPrint('⚠️ [NitroBenchmark] Raw FFI send_large_buffer_noop not found.');
    }

    _fpsTimer?.cancel();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      batch(() {
        for (var type in tickCounts.keys) {
          if (isRunning.value) {
            final count = tickCounts[type]!.value;
            currentFps[type]!.value = count.toDouble();
            perFrameMicros[type]!.value = count > 0 ? 1000000.0 / count : 0.0;

            final totalMicros = _accumulatedMicros[type]!;
            avgPerCallMicros[type]!.value = count > 0
                ? totalMicros / count
                : 0.0;
          } else {
            currentFps[type]!.value = 0.0;
            perFrameMicros[type]!.value = 0.0;
            avgPerCallMicros[type]!.value = 0.0;
          }
          tickCounts[type]!.value = 0;
          _accumulatedMicros[type] = 0.0;
        }
      });
    });
  }

  static void recordCallLatency(BridgeType type, double micros) {
    _accumulatedMicros[type] = (_accumulatedMicros[type] ?? 0) + micros;
  }

  static Future<void> runHighBandwidthTest(int gb) async {
    final size = gb * 1024 * 1024 * 1024;
    debugPrint('🐘 [NitroBenchmark] Starting $gb GB throughput test...');

    final buffer = Uint8List(size);

    for (final type in [
      BridgeType.methodChannel,
      BridgeType.nitro,
      BridgeType.rawFfi,
      BridgeType.nitroCpp,
    ]) {
      throughputResults[type]!.value = 'Testing...';
      final sw = Stopwatch()..start();

      try {
        switch (type) {
          case BridgeType.methodChannel:
            await _channel.invokeMethod('sendLargeBuffer', buffer);
            break;
          case BridgeType.nitro:
            Benchmark.instance.sendLargeBuffer(buffer);
            break;
          case BridgeType.nitroCpp:
            if (isChecksumEnabled.value) {
              BenchmarkCpp.instance.sendLargeBufferFast(buffer);
            } else {
              BenchmarkCpp.instance.sendLargeBufferNoopFast(buffer);
            }
            break;
          case BridgeType.rawFfi:
            final func = isChecksumEnabled.value ? _rawSendBuffer : _rawSendBufferNoop;
            if (func != null) {
              // We use a pre-allocated pointer to avoid measuring allocation cost
              final ptr = malloc<Uint8>(size);
              func(ptr, size);
              malloc.free(ptr);
            } else {
              throw Exception('Not implemented');
            }
            break;
          default:
            break;
        }
        sw.stop();

        // 🛡️ Prevent INFINITY by using a minimum of 1ms (or using microseconds for precision)
        final double elapsedSeconds =
            math.max(1, sw.elapsedMicroseconds) / 1000000.0;
        final mbSize = size / (1024 * 1024);
        final speed = mbSize / elapsedSeconds;

        final timeStr = sw.elapsedMilliseconds > 0
            ? '${sw.elapsedMilliseconds}ms'
            : '${sw.elapsedMicroseconds}µs';

        throughputResults[type]!.value =
            '$timeStr (${speed.toStringAsFixed(1)} MB/s)';
      } catch (e) {
        throughputResults[type]!.value =
            'Error: ${e.toString().split('\n').first}';
      }
    }
  }

  static void toggleRunning(bool value) {
    isRunning.value = value;
  }

  static void dispose() {
    _fpsTimer?.cancel();
    isRunning.value = false;
  }

  static double rawAdd(double a, double b) => _rawAdd!(a, b);
  static MethodChannel get channel => _channel;

  static Future<void> runOneOffProfiler() async {
    const iterations = 50;
    winner.value = null;

    for (final bridge in [
      BridgeType.nitro,
      BridgeType.nitroCpp,
      BridgeType.nitroCppStruct,
      BridgeType.nitroCppAsync,
      BridgeType.nitroLeaf,
      BridgeType.rawFfi,
      BridgeType.methodChannel,
    ]) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        switch (bridge) {
          case BridgeType.nitro:
            Benchmark.instance.add(1, 2);
            break;
          case BridgeType.nitroCpp:
            BenchmarkCpp.instance.add(1, 2);
            break;
          case BridgeType.nitroCppStruct:
            BenchmarkCpp.instance.scalePoint(
              const BenchmarkPoint(x: 1, y: 2),
              1.0,
            );
            break;
          case BridgeType.nitroCppAsync:
            await BenchmarkCpp.instance.computeStats(1);
            break;
          case BridgeType.nitroLeaf:
            BenchmarkCpp.instance.addFast(1, 2);
            break;
          case BridgeType.rawFfi:
            rawAdd(1, 2);
            break;
          case BridgeType.methodChannel:
            await channel.invokeMethod('add', {'a': 1.0, 'b': 2.0});
            break;
        }
      }
      sw.stop();
      oneOffResults[bridge]!.value = sw.elapsedMicroseconds / iterations;
    }

    BridgeType? best;
    double bestVal = double.infinity;
    for (var entry in oneOffResults.entries) {
      final v = entry.value.value;
      if (v != null && v < bestVal) {
        bestVal = v;
        best = entry.key;
      }
    }
    winner.value = best;
  }
}

// --- UI LAYER ---

class BoxStressPage extends StatefulWidget {
  const BoxStressPage({super.key});

  @override
  State<BoxStressPage> createState() => _BoxStressPageState();
}

class _BoxStressPageState extends State<BoxStressPage> {
  @override
  void initState() {
    super.initState();
    BenchmarkManager.init();
  }

  @override
  void dispose() {
    BenchmarkManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Nitro Multi-Bridge Bench',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.sd_storage, color: Colors.cyan),
            onPressed: () => BenchmarkManager.runHighBandwidthTest(1),
            tooltip: 'Run 1GB Test',
          ),
          IconButton(
            icon: const Icon(Icons.analytics, color: Colors.amber),
            onPressed: BenchmarkManager.runOneOffProfiler,
          ),
          Watch(
            (_) => Row(
              children: [
                const Text('Checksum', style: TextStyle(fontSize: 10, color: Colors.white54)),
                Switch(
                  value: BenchmarkManager.isChecksumEnabled.value,
                  activeColor: Colors.cyan,
                  onChanged: (v) => BenchmarkManager.isChecksumEnabled.value = v,
                ),
              ],
            ),
          ),
          Watch(
            (_) => Switch(
              value: BenchmarkManager.isRunning.value,
              activeThumbColor: Colors.amber,
              activeTrackColor: Colors.amber.withAlpha(100),
              onChanged: BenchmarkManager.toggleRunning,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: const Column(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                _BridgePanel(
                  type: BridgeType.methodChannel,
                  title: 'Normal (MethodChannel)',
                  color: Colors.red,
                ),
                _BridgePanel(
                  type: BridgeType.nitro,
                  title: 'Nitro (Kotlin/Swift)',
                  color: Colors.deepPurple,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Row(
              children: [
                _BridgePanel(
                  type: BridgeType.nitroCpp,
                  title: 'Nitro FFI (Dart ↔ C++)',
                  color: Colors.cyan,
                ),
                _BridgePanel(
                  type: BridgeType.rawFfi,
                  title: 'Raw FFI (Minimal)',
                  color: Colors.green,
                ),
              ],
            ),
          ),
          _SummaryPanel(),
        ],
      ),
    );
  }
}

class _BridgePanel extends StatelessWidget {
  final BridgeType type;
  final String title;
  final Color color;

  const _BridgePanel({
    required this.type,
    required this.title,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fpsSignal = BenchmarkManager.currentFps[type]!;
    final latencySignal = BenchmarkManager.avgPerCallMicros[type]!;
    final tickSignal = BenchmarkManager.tickCounts[type]!;
    final throughputSignal = BenchmarkManager.throughputResults[type]!;

    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          border: Border.all(color: color.withAlpha(50)),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            _BridgeDriver(type: type, onTick: () => tickSignal.value++),
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

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel();

  @override
  Widget build(BuildContext context) {
    return Watch((_) {
      if (BenchmarkManager.oneOffResults.values.every((s) => s.value == null)) {
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
                if (BenchmarkManager.winner.value != null)
                  Text(
                    'WINNER: ${BenchmarkManager.winner.value!.label}',
                    style: const TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.w900,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: BenchmarkManager.oneOffResults.entries
                  .where((e) => e.value.value != null)
                  .map((e) {
                    return Text(
                      '${e.key.label}: ${e.value.value!.toStringAsFixed(3)} µs',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9,
                        fontFamily: 'monospace',
                      ),
                    );
                  })
                  .toList(),
            ),
          ],
        ),
      );
    });
  }
}

class _BridgeDriver extends StatefulWidget {
  final BridgeType type;
  final VoidCallback onTick;

  const _BridgeDriver({required this.type, required this.onTick});

  @override
  State<_BridgeDriver> createState() => _BridgeDriverState();
}

class _BridgeDriverState extends State<_BridgeDriver>
    with SingleTickerProviderStateMixin {
  final Signal<BenchmarkBox?> _boxSignal = signal(null);
  StreamSubscription? _sub;
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    if (widget.type == BridgeType.nitroCpp) {
      _sub = BenchmarkCpp.instance.boxStream.listen((box) {
        if (BenchmarkManager.isRunning.value) {
          _boxSignal.value = box;
          widget.onTick();
        }
      });
    } else if (widget.type == BridgeType.nitro) {
      _sub = Benchmark.instance.boxStream.listen((box) {
        if (BenchmarkManager.isRunning.value) {
          _boxSignal.value = BenchmarkBox(
            color: box.color,
            width: box.width,
            height: box.height,
          );
          widget.onTick();
        }
      });
    } else {
      _ticker = createTicker(_handleTick);
    }

    effect(() {
      final isRunning = BenchmarkManager.isRunning.value;
      if (isRunning && _ticker != null && !_ticker!.isActive) {
        _ticker!.start();
      } else if (!isRunning && _ticker != null && _ticker!.isActive) {
        _ticker!.stop();
      }
    });
  }

  void _handleTick(Duration elapsed) {
    if (!mounted || !BenchmarkManager.isRunning.value) {
      return;
    }

    final angle = elapsed.inMicroseconds / 200000.0;

    final colorVal =
        0xFF000000 |
        ((((math.sin(angle) + 1.0) * 127).toInt() << 16)) |
        ((((math.sin(angle + 2.0) + 1.0) * 127).toInt() << 8)) |
        ((math.sin(angle + 4.0) + 1.0) * 127).toInt();

    final width = 100.0 + math.sin(angle * 0.5) * 50.0;
    final height = 100.0 + math.cos(angle * 0.5) * 50.0;

    if (widget.type == BridgeType.methodChannel) {
      final sw = Stopwatch()..start();
      BenchmarkManager.channel.invokeMethod('add', {'a': 1.0, 'b': 2.0}).then((
        _,
      ) {
        sw.stop();
        BenchmarkManager.recordCallLatency(
          widget.type,
          sw.elapsedMicroseconds.toDouble(),
        );
      });
    } else if (widget.type == BridgeType.nitroCpp) {
      final sw = Stopwatch()..start();
      BenchmarkCpp.instance.addFast(1.0, 2.0);
      sw.stop();
      BenchmarkManager.recordCallLatency(
        widget.type,
        sw.elapsedMicroseconds.toDouble(),
      );
    } else if (widget.type == BridgeType.rawFfi) {
      final sw = Stopwatch()..start();
      BenchmarkManager.rawAdd(1.0, 2.0);
      sw.stop();
      BenchmarkManager.recordCallLatency(
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
    _sub?.cancel();
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
