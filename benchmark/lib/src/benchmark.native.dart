import 'package:nitro/nitro.dart';

part 'benchmark.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Benchmark extends HybridObject {
  static final Benchmark instance = _BenchmarkImpl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
