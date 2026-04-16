import 'dart:async';
import 'dart:math' as math;
import 'package:benchmark/benchmark.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';
import '../models/benchmark_bridge.dart';
// Raw FFI helpers — web stub returns pure-Dart results; native loads the lib.
import 'raw_ffi_service.dart' if (dart.library.io) 'raw_ffi_service_native.dart';

class VisualBenchmarkController {
  final isRunning = signal<bool>(false);
  final isChecksumEnabled = signal<bool>(true);
  final isBusy = signal<bool>(false);

  final tickCounts = {for (var type in BridgeType.values) type: signal(0)};

  final currentFps = {for (var type in BridgeType.values) type: signal(0.0)};

  final perFrameMicros = {
    for (var type in BridgeType.values) type: signal(0.0),
  };

  final avgPerCallMicros = {
    for (var type in BridgeType.values) type: signal(0.0),
  };

  final throughputResults = {
    for (var type in BridgeType.values) type: signal<String?>(null),
  };

  final oneOffResults = {
    for (var type in BridgeType.values) type: signal<double?>(null),
  };

  final winner = signal<BridgeType?>(null);

  Timer? _fpsTimer;
  static const _channel = MethodChannel(
    'dev.shreeman.benchmark/method_channel',
  );

  final Map<BridgeType, double> _accumulatedMicros = {
    for (var type in BridgeType.values) type: 0.0,
  };

  VisualBenchmarkController() {
    _startFpsTimer();
  }

  void _startFpsTimer() {
    _fpsTimer?.cancel();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      batch(() {
        for (var type in tickCounts.keys) {
          if (isRunning.value) {
            final count = tickCounts[type]!.value;
            currentFps[type]!.value = count.toDouble();
            perFrameMicros[type]!.value = count > 0 ? 1000000.0 / count : 0.0;
            final totalMicros = _accumulatedMicros[type]!;
            avgPerCallMicros[type]!.value =
                count > 0 ? totalMicros / count : 0.0;
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

  void recordCallLatency(BridgeType type, double micros) {
    _accumulatedMicros[type] = (_accumulatedMicros[type] ?? 0) + micros;
  }

  Future<void> runHighBandwidthTest(int mb) async {
    if (mb <= 0 || mb > 2048) {
      for (final type in BridgeType.values) {
        throughputResults[type]!.value =
            'Error: invalid size ${mb}MB (must be 1–2048)';
      }
      return;
    }
    final byteSize = mb * 1024 * 1024;
    final buffer = Uint8List(byteSize);

    for (final type in [
      BridgeType.methodChannel,
      BridgeType.nitro,
      BridgeType.rawFfi,
      BridgeType.nitroCpp,
      BridgeType.nitroLeaf,
      BridgeType.nitroUnsafe,
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
          case BridgeType.nitroLeaf:
            BenchmarkCpp.instance.sendLargeBufferNoopFast(buffer);
            break;
          case BridgeType.nitroUnsafe:
            // Uses RawFfiService to keep Pointer<Uint8> out of this file,
            // allowing the same source to compile on web.
            RawFfiService.instance.sendBufferUnsafe(byteSize);
            break;
          case BridgeType.rawFfi:
            if (isChecksumEnabled.value) {
              RawFfiService.instance.sendBuffer(buffer);
            } else {
              RawFfiService.instance.sendBufferNoop(buffer);
            }
            break;
          default:
            break;
        }
        sw.stop();

        final double elapsedSeconds =
            math.max(1, sw.elapsedMicroseconds) / 1000000.0;
        final mbSizeCalc = byteSize / (1024 * 1024);
        final speed = mbSizeCalc / elapsedSeconds;
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

  void toggleRunning(bool value) {
    isRunning.value = value;
  }

  void dispose() {
    _fpsTimer?.cancel();
    isRunning.value = false;
  }

  double rawAdd(double a, double b) =>
      RawFfiService.instance.rawAddCpp(a, b);

  MethodChannel get channel => _channel;

  Future<void> runOneOffProfiler() async {
    const iterations = 50;
    winner.value = null;

    for (final bridge in [
      BridgeType.nitro,
      BridgeType.nitroCpp,
      BridgeType.nitroCppStruct,
      BridgeType.nitroCppAsync,
      BridgeType.nitroLeaf,
      BridgeType.nitroUnsafe,
      BridgeType.rawFfi,
      BridgeType.methodChannel,
    ]) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < iterations; i++) {
        switch (bridge) {
          case BridgeType.nitro:
            Benchmark.instance.add(1.0, 2.0);
            break;
          case BridgeType.nitroCpp:
            BenchmarkCpp.instance.add(1.0, 2.0);
            break;
          case BridgeType.nitroCppStruct:
            BenchmarkCpp.instance
                .scalePoint(BenchmarkPoint(x: 1, y: 2), 1.0);
            break;
          case BridgeType.nitroCppAsync:
            await BenchmarkCpp.instance.computeStats(1);
            break;
          case BridgeType.nitroLeaf:
            BenchmarkCpp.instance.addFast(1.0, 2.0);
            break;
          case BridgeType.nitroUnsafe:
            BenchmarkCpp.instance.addFast(1.0, 2.0);
            break;
          case BridgeType.rawFfi:
            RawFfiService.instance.rawAddCpp(1.0, 2.0);
            break;
          case BridgeType.methodChannel:
            await _channel.invokeMethod('add', {'a': 1.0, 'b': 2.0});
            break;
        }
      }
      sw.stop();
      oneOffResults[bridge]!.value = sw.elapsedMicroseconds / iterations;
    }

    BridgeType? best;
    double min = double.infinity;
    for (var entry in oneOffResults.entries) {
      if (entry.value.value != null && entry.value.value! < min) {
        min = entry.value.value!;
        best = entry.key;
      }
    }
    winner.value = best;
  }
}
