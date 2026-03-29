import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'benchmark_cpp.g.dart';

/// Packed zero-copy struct — passed as raw C pointer across the FFI boundary.
/// Use this for hot-path data that must avoid heap allocation.
@HybridStruct(packed: true)
class BenchmarkPoint {
  final double x;
  final double y;
  const BenchmarkPoint({required this.x, required this.y});
}

/// Packed zero-copy box — for streaming visual stress tests.
@HybridStruct(packed: true)
class BenchmarkBox {
  final int color; // ARGB
  final double width;
  final double height;
  const BenchmarkBox({
    required this.color,
    required this.width,
    required this.height,
  });
}

/// Binary-encoded record — complex payload with string field.
/// Bridged as a compact binary protocol with a single allocation per call.
@HybridRecord()
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

/// NativeImpl.cpp module — direct C++ virtual dispatch, no JNI or Swift bridge.
/// Benchmarks: sync primitives, sync strings, zero-copy structs,
/// async Future with @HybridRecord return, and `Stream<struct>` emit throughput.
@NitroModule(lib: 'benchmark_cpp', ios: NativeImpl.cpp, android: NativeImpl.cpp)
abstract class BenchmarkCpp extends HybridObject {
  static final BenchmarkCpp instance = _BenchmarkCppImpl();

  /// Sync primitive — baseline direct C++ dispatch overhead (~1µs).
  double add(double a, double b);

  /// Ultra-fast primitive — used for benchmarking absolute minimum overhead.
  /// (Implementation will use Leaf calls and skip error checking).
  double addFast(double a, double b);

  /// Sync string round-trip — measures string heap allocation overhead.
  String getGreeting(String name);

  /// Sync zero-copy struct param + return — measures struct pass-by-value overhead.
  BenchmarkPoint scalePoint(BenchmarkPoint point, double factor);

  /// Async returning a @HybridRecord — measures Future + binary-record overhead.
  @nitroAsync
  Future<BenchmarkStats> computeStats(int iterations);

  /// Stream of zero-copy structs — measures C++ → Dart emit throughput.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<BenchmarkPoint> get dataStream;

  /// Stream of box structs for visual stress test.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<BenchmarkBox> get boxStream;

  /// High-bandwidth test — pushes up to 4GB zero-copy buffers.
  int sendLargeBufferFast(Uint8List buffer);
}
