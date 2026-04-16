// Web stub — NitroRuntime requires dart:ffi which is not available on web.
// The runtime is simply skipped; the web-stub Benchmark/BenchmarkCpp
// implementations work entirely in Dart without a runtime.
//
// Conditionally imported by main.dart via:
//   import 'nitro_init.dart' if (dart.library.io) 'nitro_init_native.dart';

String? startupError;

Future<void> initNitroRuntime() async {
  // No-op on web.
}
