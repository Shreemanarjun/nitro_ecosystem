import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
// NitroRuntime init is skipped on web (no dart:ffi); the web stub is a no-op.
import 'core/nitro_init.dart' if (dart.library.io) 'core/nitro_init_native.dart';
import 'harness/bench_autorun.dart'
    if (dart.library.js_interop) 'harness/bench_autorun_web.dart';

/// Headless autorun for RELEASE-mode measurement: `flutter test` cannot build
/// release, so `flutter run --release --dart-define=BENCH_AUTORUN=quick`
/// launches the app, runs the same BenchHarness the integration test uses,
/// prints the table + report JSON to the device log (plain `print` — visible
/// in release, unlike debugPrint), and exits.
const String _benchAutorun = String.fromEnvironment('BENCH_AUTORUN');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable(); // Keep screen awake during benchmarks
  SignalsObserver.instance = null;

  await initNitroRuntime();

  if (!kIsWeb && _benchAutorun.isNotEmpty) {
    await runBenchAutorun(_benchAutorun);
    return;
  }

  runApp(NitroBenchmarkApp(startupError: startupError));
}
