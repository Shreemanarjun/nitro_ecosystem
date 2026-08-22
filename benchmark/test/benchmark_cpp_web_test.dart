// Browser tests for the benchmark module's WASM bridge.
//
// The benchmark app reports numbers; these assert the CORRECTNESS of the same
// calls it times, so a web-only marshalling bug can't quietly turn into a
// flattering measurement. Every method here is one the benchmark harness runs.
//
// Build the module first, then run under BOTH compilers — they diverge at the
// js_interop boundary, so green under one says nothing about the other:
//   web/build_web.sh
//   flutter pub run test test/benchmark_cpp_web_test.dart -p chrome
//   flutter pub run test test/benchmark_cpp_web_test.dart -p chrome -c dart2wasm
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:test/test.dart';

// The barrel re-exports the platform shim, so ensureBenchmarkCppReady and the
// class both come from here.
import 'package:benchmark/benchmark.dart';

void main() {
  late BenchmarkCpp api;

  setUpAll(() async {
    final channel = spawnHybridUri('asset_server.dart');
    // dart2wasm hands JS numbers over as double — never cast with `as int`.
    final port = ((await channel.stream.first)! as num).toInt();
    await ensureBenchmarkCppReady(jsUrl: 'http://localhost:$port/benchmark_cpp.js');
    api = BenchmarkCpp.instance;
  });

  group('scalar dispatch (the callSync hot path)', () {
    test('add / addFast agree and handle sign and zero', () {
      expect(api.add(1.5, 2.25), 3.75);
      expect(api.add(-1.5, 1.5), 0.0);
      expect(api.addFast(1.5, 2.25), 3.75);
      // addFast skips the error out-param; it must still agree with add.
      expect(api.addFast(-0.125, 0.0625), api.add(-0.125, 0.0625));
    });

    test('sievePrimes returns the real count, not a truncated one', () {
      // Known values — a 32-bit truncation or a BigInt mix-up would show here.
      expect(api.sievePrimes(10), 4); // 2 3 5 7
      expect(api.sievePrimes(100), 25);
      expect(api.sievePrimes(1000), 168);
    });
  });

  group('string marshalling', () {
    test('round-trips through UTF-8, including multi-byte and empty', () {
      expect(api.getGreeting('world'), contains('world'));
      expect(api.getGreeting(''), isNotNull);
      // The string crosses as UTF-8 bytes, not UTF-16 units.
      expect(api.getGreeting('日本語'), contains('日本語'));
    });
  });

  group('buffer marshalling (@zeroCopy)', () {
    test('hashBuffer is stable and content-sensitive', () {
      final a = Uint8List.fromList(List.generate(256, (i) => i));
      final b = Uint8List.fromList(List.generate(256, (i) => i))..[128] = 0;

      final ha = api.hashBuffer(a, 1);
      expect(api.hashBuffer(a, 1), ha, reason: 'same input must hash the same');
      expect(api.hashBuffer(b, 1), isNot(ha), reason: 'one changed byte must change the hash');
    });

    test('large buffers report the byte count they were given', () {
      // A wrong length argument would surface here as a mismatch rather than
      // as a suspiciously fast benchmark number.
      for (final size in [0, 1, 4096, 65536]) {
        final buf = Uint8List(size);
        // The noop variants return buffer_length verbatim.
        expect(api.sendLargeBufferNoop(buf), size, reason: 'noop · $size');
        expect(api.sendLargeBufferNoopFast(buf), size, reason: 'noopFast · $size');
        // The sampling variant returns length, or length+1 when its page
        // checksum is non-zero — a deliberate guard against the compiler
        // eliminating the sampling loop. Both are in-contract.
        expect(
          api.sendLargeBufferFast(buf),
          size == 0 ? 0 : anyOf(equals(size), equals(size + 1)),
          reason: 'fast · $size',
        );
      }
    });
  });
}
