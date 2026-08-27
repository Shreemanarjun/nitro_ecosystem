// Threaded-vs-unthreaded web comparison. Driven twice against the two builds:
//   ./web/build_web.sh                      (inline on the main thread)
//   NITRO_WEB_THREADS=1 ./web/build_web.sh  (persistent std::thread worker)
// Prints wall-clock for a CPU-bound native-async burst plus a main-thread
// responsiveness probe (timer ticks observed DURING the burst).
import 'dart:async';

import 'package:benchmark/benchmark.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late BenchmarkCpp api;

  setUpAll(() async {
    await ensureBenchmarkCppReady();
    api = BenchmarkCpp.instance;
  });

  test('CPU-bound native-async burst', () async {
    // Calibrate so one call is ~meaningful work on this machine.
    var sw = Stopwatch()..start();
    await api.computeStatsNative(500000);
    sw.stop();
    final oneCallMs = sw.elapsedMilliseconds;
    print('PERF calibration: computeStatsNative(500k) = $oneCallMs ms');

    var ticks = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 5), (_) => ticks++);

    sw = Stopwatch()..start();
    await Future.wait([for (var i = 0; i < 4; i++) api.computeStatsNative(2000000)]);
    sw.stop();
    ticker.cancel();

    print('PERF burst 4× computeStatsNative(2M): ${sw.elapsedMilliseconds} ms wall');
    print('PERF main-thread ticks during burst:  $ticks (5 ms timer — higher = main thread stayed responsive)');
    // Web drive does not forward prints; the driver writes this to
    // build/integration_response_data.json.
    binding.reportData = {
      'calibration_500k_ms': oneCallMs,
      'burst_4x2M_wall_ms': sw.elapsedMilliseconds,
      'main_thread_ticks': ticks,
    };
    expect(ticks, greaterThanOrEqualTo(0));
  });
}
