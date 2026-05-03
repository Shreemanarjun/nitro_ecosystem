import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Flutter Web plugin registration stub for the benchmark package.
///
/// No actual plugin channel registration is needed — all benchmark API
/// calls go directly through the pure-Dart [Benchmark] and [BenchmarkCpp]
/// instances exported from `benchmark.dart`. This class exists solely to
/// satisfy the Flutter plugin registry contract on web.
class BenchmarkWebPlugin {
  static void registerWith(Registrar registrar) {
    // Nothing to register: the benchmark API is accessed via static `instance`
    // fields on the generated Dart classes, not through a MethodChannel.
  }
}
