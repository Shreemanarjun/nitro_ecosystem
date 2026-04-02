import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'benchmark.g.dart';

/// Packed zero-copy struct — passed as raw C pointer across the FFI boundary.
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

/// Binary-encoded record — complex payload.
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

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin, macos: NativeImpl.swift)
abstract class Benchmark extends HybridObject {
  static final Benchmark instance = _BenchmarkImpl();

  /// Sync primitive — measures Swift/Kotlin bridge overhead (~1-2µs).
  double add(double a, double b);

  /// Fast primitive — minimal overhead path.
  double addFast(double a, double b);

  /// Sync string round-trip — measures string conversion overhead.
  String getGreeting(String name);

  /// Sync struct return — measures value-type pass-through.
  BenchmarkPoint scalePoint(BenchmarkPoint point, double factor);

  /// Async @HybridRecord return — measures Future + binary record serialization.
  @nitroAsync
  Future<BenchmarkStats> computeStats(int iterations);

  /// Stream of zero-copy structs.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<BenchmarkPoint> get dataStream;

  /// Stream of box structs for visual stress test parity.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<BenchmarkBox> get boxStream;

  /// High-bandwidth test — pushes up to 4GB zero-copy buffers.
  int sendLargeBuffer(Uint8List buffer);
}
