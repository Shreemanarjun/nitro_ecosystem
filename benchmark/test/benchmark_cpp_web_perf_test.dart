// Informational web-bridge microbenchmarks (unthreaded default build).
// Numbers print to the test output; assertions are sanity-only so timing
// noise can never fail CI. Run under both compilers:
//   flutter pub run test test/benchmark_cpp_web_perf_test.dart -p chrome
//   flutter pub run test test/benchmark_cpp_web_perf_test.dart -p chrome -c dart2wasm
@TestOn('browser')
@Timeout(Duration(minutes: 3))
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:benchmark/benchmark.dart';

void main() {
  late BenchmarkCpp api;

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    final port = ((await channel.stream.first)! as num).toInt();
    await ensureBenchmarkCppReady(jsUrl: 'http://localhost:$port/benchmark_cpp.js');
    api = BenchmarkCpp.instance;
  });

  test('microbench', () async {
    // Warm-up.
    for (var i = 0; i < 5000; i++) {
      api.add(i.toDouble(), 1);
    }

    const n1 = 200000;
    var sw = Stopwatch()..start();
    var acc = 0.0;
    for (var i = 0; i < n1; i++) {
      acc += api.add(i.toDouble(), 1);
    }
    sw.stop();
    print('PERF callSync add:        ${(sw.elapsedMicroseconds * 1000 / n1).toStringAsFixed(0)} ns/op ($n1 ops, acc=$acc)');

    const n2 = 20000;
    sw = Stopwatch()..start();
    for (var i = 0; i < n2; i++) {
      api.getGreeting('web');
    }
    sw.stop();
    print('PERF string round-trip:   ${(sw.elapsedMicroseconds / n2).toStringAsFixed(2)} µs/op ($n2 ops)');

    final buf = Uint8List(64 * 1024);
    for (var i = 0; i < buf.length; i++) {
      buf[i] = i & 0xff;
    }
    const n3 = 500;
    sw = Stopwatch()..start();
    for (var i = 0; i < n3; i++) {
      api.hashBuffer(buf, 1);
    }
    sw.stop();
    final mbps = 64 * n3 / 1024 / (sw.elapsedMicroseconds / 1e6);
    print('PERF 64KB buffer hash:    ${(sw.elapsedMicroseconds / n3).toStringAsFixed(1)} µs/op → ${mbps.toStringAsFixed(0)} MB/s in-bound');

    sw = Stopwatch()..start();
    final primes = api.sievePrimes(1000000);
    sw.stop();
    print('PERF sievePrimes(1M):     ${sw.elapsedMilliseconds} ms (found $primes)');

    const n4 = 2000;
    sw = Stopwatch()..start();
    for (var i = 0; i < n4; i++) {
      await api.nativeAsyncEcho(i);
    }
    sw.stop();
    print('PERF nativeAsync latency: ${(sw.elapsedMicroseconds / n4).toStringAsFixed(1)} µs round-trip ($n4 serial)');

    expect(primes, greaterThan(0));
  });
}
