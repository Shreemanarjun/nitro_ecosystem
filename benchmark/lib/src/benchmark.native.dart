import 'package:nitro/nitro.dart';

part 'benchmark.g.dart';

/// Swift/Kotlin platform-bridge benchmark module.
///
/// Deliberately minimal: it exists to measure the Swift (`@_cdecl`) and
/// Kotlin (JNI) dispatch tiers against the raw-FFI / C++ / MethodChannel
/// tiers. Struct, record, and stream benchmarks live in `BenchmarkCpp`
/// (`benchmark_cpp.native.dart`) — do NOT redeclare its types here: both
/// specs compile into ONE Swift module, so same-named public types collide
/// with "'X' is ambiguous for type lookup".
@NitroModule(
  ios: AppleNativeImpl.swift,
  android: AndroidNativeImpl.kotlin,
  macos: AppleNativeImpl.swift,
  windows: WindowsNativeImpl.cpp,
  linux: LinuxNativeImpl.cpp,
)
abstract class Benchmark extends HybridObject {
  static final Benchmark instance = _BenchmarkImpl();

  /// Sync primitive — measures Swift/Kotlin bridge overhead (~1-2µs).
  double add(double a, double b);

  /// Fast primitive — minimal overhead path.
  double addFast(double a, double b);

  /// Sync string round-trip — measures string conversion overhead.
  String getGreeting(String name);

  /// Reference workload: FNV-1a 64-bit hash (see `src/nitro_workload.h`),
  /// implemented in the SAME platform language as the MethodChannel handler
  /// (Kotlin on Android, Swift on Apple, C++ on desktop). Comparing this
  /// against the channel's `hashBuffer` isolates pure bridge cost with the
  /// implementation language held constant.
  int hashBuffer(Uint8List data, int rounds);

  /// High-bandwidth test — pushes up to 4GB zero-copy buffers.
  int sendLargeBuffer(Uint8List buffer);
}
