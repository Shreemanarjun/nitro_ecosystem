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

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:benchmark_example/harness/bench_harness.dart';
import 'package:benchmark_example/nitro_init_native.dart';

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
const _maxLeafOverRawFfi = 2.5; //   ratio term
const _leafOverheadBudgetUs = 1.0; // absolute per-call overhead budget
const _maxCppOverRawFfi = 4.0;
const _cppOverheadBudgetUs = 1.5;
const _minChannelOverCpp = 5.0; //   typical 50–100×

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
      double requiredMedian(String id) {
        final r = report.caseById(id);
        expect(r, isNotNull, reason: 'benchmark case $id did not run');
        expect(
          r!.skipReason,
          isNull,
          reason: 'core case $id was skipped: ${r.skipReason}',
        );
        return r.stats!.medianUs;
      }

      double? optionalMedian(String id) => report.caseById(id)?.stats?.medianUs;

      final rawFfi = requiredMedian('raw_ffi_add');
      final leaf = requiredMedian('nitro_leaf_add');
      final cpp = requiredMedian('nitro_cpp_add');
      final channel = optionalMedian('method_channel_add');

      expect(rawFfi, greaterThan(0), reason: 'raw FFI floor measured as 0 µs');
      expect(
        leaf,
        lessThanOrEqualTo(rawFfi * _maxLeafOverRawFfi + _leafOverheadBudgetUs),
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
      }

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
