// Automated cross-bridge benchmark with a regression gate.
//
// Run via the driver (saves the JSON report to build/):
//   flutter drive --profile \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/benchmark_regression_test.dart -d macos
//
// Or use the wrapper which also formats the report and manages baselines:
//   ../tool/bench.sh -d macos --mode quick
//
// Tuning (all via --dart-define):
//   NITRO_BENCH_MODE=quick|full     iteration scale            (default quick)
//   NITRO_BENCH_GATE=relative|all|none                         (default relative)
//     relative — enforce cross-bridge ratios only (machine-independent; CI-safe)
//     all      — also enforce absolute µs vs the checked-in platform baseline
//     none     — measure and report, never fail
//   NITRO_BENCH_TOLERANCE_PCT=35    baseline drift allowed in 'all' mode

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:benchmark_example/harness/bench_harness.dart';
// Conditional so the SAME gate runs on web, where startup must first
// instantiate the benchmark_cpp WASM module. Mirrors main.dart's import.
import 'package:benchmark_example/core/nitro_init.dart'
    if (dart.library.io) 'package:benchmark_example/core/nitro_init_native.dart';

const _mode = String.fromEnvironment('NITRO_BENCH_MODE', defaultValue: 'quick');
const _gate = String.fromEnvironment(
  'NITRO_BENCH_GATE',
  defaultValue: 'relative',
);
const _tolerancePct = int.fromEnvironment(
  'NITRO_BENCH_TOLERANCE_PCT',
  defaultValue: 35,
);

// Cross-bridge invariants. Deliberately generous (typical measured values are
// far better) so shared-runner noise never flakes the gate — these only trip
// on a real architectural regression (lost isLeaf, extra allocation in the
// call path, accidental async hop, …).
//
// The raw-FFI floor is ~15ns on Apple Silicon, so a pure ratio would explode
// (Nitro's fixed ~0.3µs dispatch overhead is 20× a 15ns floor while being
// perfectly healthy). The gate is therefore ratio + an absolute overhead
// budget: `nitro ≤ rawFfi × ratio + budgetUs`. A regression of the classes we
// care about (accidental malloc/arena in the hot path, lost isLeaf, an async
// hop) adds ≥1µs and still trips it on any machine.
//
// The gate reads `minUs`, not `medianUs`. A shared CI runner deschedules the
// benchmark isolate mid-sample, which inflates the median but cannot make a
// call *faster* than it really is — so the minimum is the estimator that
// tracks true per-call cost. With the median, a GitHub macOS runner measured
// the leaf call at 1.055µs against a 1.054µs budget and failed by 0.65ns,
// while the identical commit had passed hours earlier: noise, not a
// regression, and 1500× below the ≥1µs this gate exists to catch.
const _maxLeafOverRawFfi = 2.5; //   ratio term
// Handle-parameter tier (GH #51/#52): raw_ffi_touch is a hand-rolled isLeaf
// binding taking Pointer<Void>. nitro_fast_handle is the bare leaf body and
// should sit on the floor; nitro_leaf_handle keeps the callSync closure but
// is isLeaf, so it gets the same allowance as the scalar leaf tier.
const _maxFastHandleOverRawFfi = 2.5;
const _maxLeafHandleOverRawFfi = 2.5;
const _handleOverheadBudgetUs = 0.05; // checked calls no longer time themselves: ~25 ns
// @nitroFast @nitroNativeAsync completes inline (no port, no wake): the port
// post path must stay several times slower, or the fast tier stopped working.
const _minPostOverFastInline = 4.0;

/// Coalesced batch stream ÷ per-item stream on a 256-item burst (native only).
const _maxStreamBatchedOverPerItem = 0.5;
const _leafOverheadBudgetUs = 1.0; // absolute per-call overhead budget
const _maxCppOverRawFfi = 3.0;
const _cppOverheadBudgetUs = 0.05; // checked C++ call ≈ 30 ns after 0.7.6 (was 270 ns)
const _minChannelOverCpp = 5.0; //   typical 50–100×

// @nitroAsync / @nitroNativeAsync vs MethodChannel. Generous on purpose —
// current measured ratio is ≈1.0 on macOS (isolate-pool dispatch is at
// parity with a channel round-trip); this only trips on a real regression
// class (the persistent IsolatePool reverting to per-call ReceivePort /
// Isolate.spawn, an accidental extra allocation, or a lost fast path).
const _maxAsyncOverChannel = 3.0; //   ratio term
const _asyncOverheadBudgetUs = 50.0; // absolute budget — async has more
//                                      scheduler/GC jitter than a sync call

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'cross-bridge benchmark: FFI vs Nitro vs MethodChannel',
    (tester) async {
      await initNitroRuntime();
      expect(
        startupError,
        isNull,
        reason: 'NitroRuntime failed to initialise: $startupError',
      );

      final report = await BenchHarness.run(
        config: BenchConfig.fromMode(_mode),
        onCaseStart: (id) => debugPrint('[BenchHarness] running: $id'),
      );

      // Hand the full report to the driver (written to
      // build/integration_response_data.json by test_driver/integration_test.dart).
      binding.reportData = {'benchmark_report': report.toJson()};
      report.toTableLines().forEach(debugPrint);

      if (_gate == 'none') return;

      // ── Relative gate: machine-independent bridge-tier invariants ────────
      // Core Nitro cases are mandatory on every platform — a skipped core
      // case means the bridge itself is broken there. Optional tiers
      // (MethodChannel handler, platform bridge) may be absent per platform;
      // their gates auto-skip.
      double requiredMin(String id) {
        final r = report.caseById(id);
        expect(r, isNotNull, reason: 'benchmark case $id did not run');
        expect(
          r!.skipReason,
          isNull,
          reason: 'core case $id was skipped: ${r.skipReason}',
        );
        // See the header: min, not median — deschedule noise inflates the
        // median but can never make a call faster than it truly is.
        return r.stats!.minUs;
      }

      double? optionalMin(String id) => report.caseById(id)?.stats?.minUs;

      // The raw-FFI floor is the yardstick for the ratio gates, but it only
      // exists where dart:ffi does. On web there is no raw-FFI tier (and no
      // MethodChannel), so those comparisons are skipped rather than failed —
      // the core Nitro cases below still have to run everywhere.
      final rawFfi = optionalMin('raw_ffi_add');
      final rawTouch = optionalMin('raw_ffi_touch');
      final leafHandle = optionalMin('nitro_leaf_handle');
      final asyncPost = optionalMin('nitro_native_async_scalar');
      final asyncInline = optionalMin('nitro_native_async_inline');
      // Web has no ports: native-async completes on the same thread there, so
      // there is no isolate wake for inline completion to remove.
      if (!kIsWeb && asyncPost != null && asyncInline != null) {
        expect(
          asyncPost / asyncInline,
          greaterThanOrEqualTo(_minPostOverFastInline),
          reason: '@nitroFast @nitroNativeAsync should complete inline, well under the port post '
              '(inline=${asyncInline.toStringAsFixed(3)}µs, post=${asyncPost.toStringAsFixed(3)}µs).',
        );
      }
      // Coalesced batch streams: a 256-item burst must cost well under the
      // per-item post path (one message per Dart wake instead of one per item).
      final streamPerItem = optionalMin('nitro_stream_struct_burst256_percall');
      final streamBatched = optionalMin('nitro_stream_struct_burst256_batched');
      if (!kIsWeb && streamPerItem != null && streamBatched != null) {
        expect(
          streamBatched / streamPerItem,
          lessThanOrEqualTo(_maxStreamBatchedOverPerItem),
          reason: 'Backpressure.batch on an all-C++ spec should coalesce a burst '
              '(batched=${streamBatched.toStringAsFixed(1)}µs, per-item=${streamPerItem.toStringAsFixed(1)}µs per 256 items).',
        );
      }
      final fastHandle = optionalMin('nitro_fast_handle');
      final leaf = requiredMin('nitro_leaf_add');
      final cpp = requiredMin('nitro_cpp_add');
      final channel = optionalMin('method_channel_add');

      expect(leaf, greaterThan(0), reason: 'Nitro leaf call measured as 0 µs');
      expect(cpp, greaterThan(0), reason: 'Nitro C++ call measured as 0 µs');

      if (rawTouch != null && leafHandle != null && fastHandle != null) {
        expect(
          fastHandle,
          lessThanOrEqualTo(rawTouch * _maxFastHandleOverRawFfi + _handleOverheadBudgetUs),
          reason: 'Fast handle-param call drifted from the raw pointer floor '
              '(fast=${fastHandle.toStringAsFixed(3)}µs, raw=${rawTouch.toStringAsFixed(3)}µs). '
              'Did the Fast body regain the callSync closure or lose isLeaf?',
        );
        expect(
          leafHandle,
          lessThanOrEqualTo(rawTouch * _maxLeafHandleOverRawFfi + _handleOverheadBudgetUs),
          reason: 'Plain handle-param call drifted from the raw pointer floor '
              '(leaf=${leafHandle.toStringAsFixed(3)}µs, raw=${rawTouch.toStringAsFixed(3)}µs). '
              'Did NativeHandle params stop counting as leaf-eligible?',
        );
      }
      if (rawFfi == null) {
        debugPrint(
          '[BenchGate] no raw-FFI tier on this platform — ratio gates skipped; '
          'core Nitro cases verified.',
        );
      } else {
        expect(
          rawFfi,
          greaterThan(0),
          reason: 'raw FFI floor measured as 0 µs',
        );
        expect(
          leaf,
          lessThanOrEqualTo(
            rawFfi * _maxLeafOverRawFfi + _leafOverheadBudgetUs,
          ),
          reason:
              'Nitro leaf call drifted from the raw FFI floor '
              '(leaf=${leaf.toStringAsFixed(3)}µs, '
              'rawFfi=${rawFfi.toStringAsFixed(3)}µs). '
              'Did a binding lose isLeaf or gain an allocation?',
        );
        expect(
          cpp,
          lessThanOrEqualTo(rawFfi * _maxCppOverRawFfi + _cppOverheadBudgetUs),
          reason:
              'Nitro checked call overhead vs raw FFI regressed '
              '(cpp=${cpp.toStringAsFixed(3)}µs, '
              'rawFfi=${rawFfi.toStringAsFixed(3)}µs).',
        );
        if (channel != null) {
          expect(
            channel / cpp,
            greaterThanOrEqualTo(_minChannelOverCpp),
            reason:
                'Nitro should be ≥${_minChannelOverCpp.toStringAsFixed(0)}× '
                'faster than MethodChannel but measured only '
                '${(channel / cpp).toStringAsFixed(1)}× '
                '(cpp=${cpp.toStringAsFixed(3)}µs, '
                'channel=${channel.toStringAsFixed(3)}µs).',
          );

          final asyncRecord = optionalMin('nitro_async_record');
          if (asyncRecord != null) {
            expect(
              asyncRecord,
              lessThanOrEqualTo(
                channel * _maxAsyncOverChannel + _asyncOverheadBudgetUs,
              ),
              reason:
                  '@nitroAsync dispatch overhead regressed vs MethodChannel '
                  '(async=${asyncRecord.toStringAsFixed(1)}µs, '
                  'channel=${channel.toStringAsFixed(1)}µs). Did the persistent '
                  'IsolatePool regress to per-call ReceivePort/Isolate.spawn?',
            );
          }

          // Sieve workload (second algorithm): the bridge adds a fixed
          // ~sub-µs cost to a multi-µs compute body, so every native tier must
          // stay within a small factor of the raw-FFI sieve — a blowout means
          // the bridge started copying/allocating per call. Budget absorbs
          // shared-runner noise on the µs scale.
          final ffiSieve = optionalMin('raw_ffi_sieve');
          final cppSieve = optionalMin('nitro_cpp_sieve');
          if (ffiSieve != null && cppSieve != null) {
            expect(
              cppSieve,
              lessThanOrEqualTo(ffiSieve * 2 + 2.0),
              reason:
                  'Nitro C++ sieve drifted from the raw-FFI sieve '
                  '(cpp=${cppSieve.toStringAsFixed(2)}µs, '
                  'ffi=${ffiSieve.toStringAsFixed(2)}µs) — bridge overhead on an '
                  'int-only signature should be fixed and small.',
            );
          }
          final chanSieve = optionalMin('channel_sieve');
          if (chanSieve != null && cppSieve != null) {
            expect(
              chanSieve,
              greaterThanOrEqualTo(cppSieve),
              reason:
                  'MethodChannel sieve should never beat the Nitro C++ sieve '
                  '(channel=${chanSieve.toStringAsFixed(2)}µs, '
                  'cpp=${cppSieve.toStringAsFixed(2)}µs).',
            );
          }

          final nativeAsyncRecord = optionalMin('nitro_native_async_record');
          if (nativeAsyncRecord != null) {
            expect(
              nativeAsyncRecord,
              lessThanOrEqualTo(
                channel * _maxAsyncOverChannel + _asyncOverheadBudgetUs,
              ),
              reason:
                  '@nitroNativeAsync dispatch overhead regressed vs '
                  'MethodChannel (nativeAsync=${nativeAsyncRecord.toStringAsFixed(1)}µs, '
                  'channel=${channel.toStringAsFixed(1)}µs).',
            );
          }
        }
      } // end raw-FFI ratio gates

      // ── Absolute gate: compare vs the checked-in platform baseline ───────
      if (_gate == 'all') {
        final baseline = await _loadBaseline(report.platform);
        if (baseline == null) {
          debugPrint(
            '[BenchHarness] no baseline for ${report.platform} — '
            'absolute gate skipped. Seed one with: '
            'tool/bench.sh --update-baseline',
          );
          return;
        }
        final baseCases = baseline['cases'] as Map<String, dynamic>;
        final factor = 1 + _tolerancePct / 100;
        for (final r in report.results.where(
          (r) => r.kind == BenchKind.latency,
        )) {
          final stats = r.stats;
          if (stats == null) continue; // skipped on this platform
          final base = baseCases[r.id] as Map<String, dynamic>?;
          final baseMedian = (base?['medianUs'] as num?)?.toDouble();
          if (baseMedian == null) continue; // new/skipped case in baseline
          expect(
            stats.medianUs,
            // +0.05µs cushion so near-zero cases aren't gated on timer noise.
            lessThanOrEqualTo(baseMedian * factor + 0.05),
            reason:
                '${r.id} regressed vs baseline: '
                '${stats.medianUs.toStringAsFixed(3)}µs > '
                '${baseMedian.toStringAsFixed(3)}µs '
                '+$_tolerancePct% tolerance',
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

Future<Map<String, dynamic>?> _loadBaseline(String platform) async {
  try {
    final raw = await rootBundle.loadString('assets/baselines/$platform.json');
    return jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
