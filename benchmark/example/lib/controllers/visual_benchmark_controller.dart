import 'dart:async';
import 'dart:math' as math;
import 'package:benchmark/benchmark.dart';
import 'package:flutter/services.dart';
import 'package:nitro/nitro.dart';
import 'package:signals_flutter/signals_flutter.dart';
import '../models/benchmark_bridge.dart';

class VisualBenchmarkController {
  final isRunning = signal<bool>(false);
  final isChecksumEnabled = signal<bool>(true);

  final tickCounts = {
    for (var type in BridgeType.values) type: signal(0),
  };

  final currentFps = {
    for (var type in BridgeType.values) type: signal(0.0),
  };

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
  static DynamicLibrary? _dylib;
  static double Function(double, double)? _rawAdd;
  static int Function(Pointer<Uint8>, int)? _rawSendBuffer;
  static int Function(Pointer<Uint8>, int)? _rawSendBufferNoop;
  static const _channel = MethodChannel(
    'dev.shreeman.benchmark/method_channel',
  );

  final Map<BridgeType, double> _accumulatedMicros = {
    for (var type in BridgeType.values) type: 0.0,
  };

  VisualBenchmarkController() {
    _init();
  }

  void _init() {
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
    } catch (_) {}

    try {
      _rawSendBufferNoop = _dylib!
          .lookupFunction<
            Int64 Function(Pointer<Uint8>, Int64),
            int Function(Pointer<Uint8>, int)
          >('send_large_buffer_noop');
    } catch (_) {}

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

  void recordCallLatency(BridgeType type, double micros) {
    _accumulatedMicros[type] = (_accumulatedMicros[type] ?? 0) + micros;
  }

  Future<void> runHighBandwidthTest(int gb) async {
    final byteSize = gb * 1024 * 1024 * 1024;
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
            final ptr = malloc<Uint8>(byteSize);
            BenchmarkCpp.instance.sendLargeBufferUnsafe(ptr, byteSize);
            malloc.free(ptr);
            break;
          case BridgeType.rawFfi:
            final func = isChecksumEnabled.value
                ? _rawSendBuffer
                : _rawSendBufferNoop;
            if (func != null) {
              final ptr = malloc<Uint8>(byteSize);
              func(ptr, byteSize);
              malloc.free(ptr);
            }
            break;
          default:
            break;
        }
        sw.stop();

        final double elapsedSeconds = math.max(1, sw.elapsedMicroseconds) / 1000000.0;
        final mbSizeCalc = byteSize / (1024 * 1024);
        final speed = mbSizeCalc / elapsedSeconds;
        final timeStr = sw.elapsedMilliseconds > 0
            ? '${sw.elapsedMilliseconds}ms'
            : '${sw.elapsedMicroseconds}µs';

        throughputResults[type]!.value = '$timeStr (${speed.toStringAsFixed(1)} MB/s)';
      } catch (e) {
        throughputResults[type]!.value = 'Error: ${e.toString().split('\n').first}';
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

  double rawAdd(double a, double b) => _rawAdd!(a, b);
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
            BenchmarkCpp.instance.scalePoint(BenchmarkPoint(x: 1, y: 2), 1.0);
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
            rawAdd(1.0, 2.0);
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
