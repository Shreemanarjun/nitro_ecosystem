// Web implementation of the NitroRuntime startup sequence: instantiate the
// benchmark_cpp WASM module (asynchronous in the browser) before any bridge
// instance is constructed.
//
// Conditionally imported by main.dart via:
//   import 'nitro_init.dart' if (dart.library.io) 'nitro_init_native.dart';
import 'package:benchmark/benchmark.dart';
import 'package:flutter/foundation.dart';

String? startupError;

Future<void> initNitroRuntime() async {
  try {
    await ensureBenchmarkCppReady();
  } catch (e) {
    debugPrint('[NitroBenchmark] WASM module load failed: $e');
    startupError = e.toString();
  }
}
