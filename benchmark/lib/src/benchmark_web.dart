// Web-platform stubs for the benchmark plugin.
// Replaces dart:ffi-based native implementations with pure-Dart equivalents
// so the benchmark example compiles and runs on Flutter Web.
//
// On web there is no native bridge overhead; every call is a plain Dart
// function dispatch. This makes web results a useful "pure Dart" baseline
// to compare against native bridge numbers.
//
// Conditionally imported by lib/benchmark.dart when dart.library.io is absent.

import 'dart:async';
import 'dart:typed_data';

// ── Shared value types ────────────────────────────────────────────────────────

class BenchmarkPoint {
  final double x;
  final double y;
  const BenchmarkPoint({required this.x, required this.y});
}

class BenchmarkBox {
  final int color;
  final double width;
  final double height;
  const BenchmarkBox({
    required this.color,
    required this.width,
    required this.height,
  });
}

class BenchmarkStats {
  final int count;
  final double meanUs;
  final double minUs;
  final double maxUs;
  const BenchmarkStats({
    required this.count,
    required this.meanUs,
    required this.minUs,
    required this.maxUs,
  });
}

// ── Benchmark (Swift/Kotlin bridge analogue) ──────────────────────────────────

/// Pure-Dart implementation of [Benchmark] used on Flutter Web.
///
/// All methods perform the same work as their native counterparts but
/// entirely in Dart — no JNI or @_cdecl overhead. Benchmark results on
/// web therefore reflect pure Dart dispatch cost, not native bridge cost.
/// Mirrors the trimmed native spec: add/addFast/getGreeting/sendLargeBuffer
/// only — struct/record/stream benchmarks live on [BenchmarkCpp].
abstract class Benchmark {
  static final Benchmark instance = _BenchmarkWebImpl();

  double add(double a, double b);
  double addFast(double a, double b);
  String getGreeting(String name);
  int sendLargeBuffer(Uint8List buffer);

  void dispose() {}
}

class _BenchmarkWebImpl extends Benchmark {
  @override
  double add(double a, double b) => a + b;

  @override
  double addFast(double a, double b) => a + b;

  @override
  String getGreeting(String name) => 'Hello, $name!';

  @override
  int sendLargeBuffer(Uint8List buffer) {
    // Stride walk — mirrors the native checksum implementation.
    var sum = 0;
    for (var i = 0; i < buffer.length; i += 4096) {
      sum += buffer[i];
    }
    return sum;
  }
}

// ── BenchmarkCpp (direct C++ dispatch analogue) ───────────────────────────────

/// Pure-Dart implementation of [BenchmarkCpp] used on Flutter Web.
///
/// Measures pure Dart virtual-dispatch cost. Useful as a reference baseline
/// when comparing web results to native C++ FFI numbers.
abstract class BenchmarkCpp {
  static final BenchmarkCpp instance = _BenchmarkCppWebImpl();

  double add(double a, double b);
  double addFast(double a, double b);
  String getGreeting(String name);
  BenchmarkPoint scalePoint(BenchmarkPoint point, double factor);
  Future<BenchmarkStats> computeStats(int iterations);
  Stream<BenchmarkPoint> get dataStream;
  Stream<BenchmarkBox> get boxStream;
  int sendLargeBufferFast(Uint8List buffer);
  int sendLargeBufferNoop(Uint8List buffer);
  int sendLargeBufferNoopFast(Uint8List buffer);

  void dispose() {}
}

class _BenchmarkCppWebImpl extends BenchmarkCpp {
  @override
  double add(double a, double b) => a + b;

  @override
  double addFast(double a, double b) => a + b;

  @override
  String getGreeting(String name) => 'Hello, $name!';

  @override
  BenchmarkPoint scalePoint(BenchmarkPoint point, double factor) =>
      BenchmarkPoint(x: point.x * factor, y: point.y * factor);

  @override
  Future<BenchmarkStats> computeStats(int iterations) async {
    final times = <double>[];
    for (var i = 0; i < iterations; i++) {
      final sw = Stopwatch()..start();
      add(i.toDouble(), i.toDouble());
      sw.stop();
      times.add(sw.elapsedMicroseconds.toDouble());
    }
    final mean = times.reduce((a, b) => a + b) / times.length;
    return BenchmarkStats(
      count: iterations,
      meanUs: mean,
      minUs: times.reduce((a, b) => a < b ? a : b),
      maxUs: times.reduce((a, b) => a > b ? a : b),
    );
  }

  @override
  Stream<BenchmarkPoint> get dataStream => Stream.periodic(
    const Duration(microseconds: 100),
    (i) => BenchmarkPoint(x: i.toDouble() * 0.001, y: i.toDouble() * 0.001),
  );

  @override
  Stream<BenchmarkBox> get boxStream => Stream.periodic(
    const Duration(microseconds: 100),
    (i) => BenchmarkBox(
      color: 0xFF0000FF + (i % 256),
      width: 50.0 + (i % 100),
      height: 50.0 + (i % 100),
    ),
  );

  @override
  int sendLargeBufferFast(Uint8List buffer) {
    var sum = 0;
    for (var i = 0; i < buffer.length; i += 4096) {
      sum += buffer[i];
    }
    return sum;
  }

  @override
  int sendLargeBufferNoop(Uint8List buffer) => buffer.length;

  @override
  int sendLargeBufferNoopFast(Uint8List buffer) => buffer.length;
}
