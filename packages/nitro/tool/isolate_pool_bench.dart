// Microbenchmark comparing IsolatePool sizing APPROACHES, built for an
// apples-to-apples JIT-vs-AOT comparison. Each result is emitted as a
// `RESULT<TAB>name<TAB>value<TAB>unit` line so a driver can merge the two modes
// into one table (see bench_pool_compare.sh).
//
//   dart run packages/nitro/tool/isolate_pool_bench.dart              # JIT
//   dart compile exe … -o /tmp/pb && /tmp/pb                          # AOT
//
// Approaches:
//   fixed-1     create(1)                 — the old default (one worker)
//   adaptive    create(1, maxWorkers:N)   — automatic: start at 1, grow to demand
//   fixed-N     create(N)                 — hand-tuned, pre-warmed to the CPU count
//
// Dimensions chosen to expose any COMPROMISE:
//   startup     cost to create+ready the pool      (fixed-N pre-spawns N isolates)
//   dispatch    per-call latency, no concurrency   (adaptive must equal fixed-1)
//   cold burst  first concurrent burst on a fresh pool (lazy start pays here)
//   warm burst  concurrent burst at steady state   (adaptive must equal fixed-N)
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:nitro/nitro.dart';

int _burn(int iters) {
  var x = 0;
  for (var i = 0; i < iters; i++) {
    x = (x + i * 2654435761) & 0x7fffffff;
  }
  return x;
}

int _noop(int x) => x;
int _tiny() => 1;

const _mode = bool.fromEnvironment('dart.vm.product') ? 'AOT' : 'JIT';

const _tasks = 96;
const _workIters = 3000000;

void _record(String name, double value, String unit) {
  stdout.writeln('  ${name.padRight(32)} ${value.toStringAsFixed(3).padLeft(10)} $unit');
  stdout.writeln('RESULT\t$name\t${value.toStringAsFixed(4)}\t$unit');
}

Future<double> _bestUs(int reps, Future<void> Function() body) async {
  var best = double.infinity;
  for (var r = 0; r < reps; r++) {
    final sw = Stopwatch()..start();
    await body();
    final us = sw.elapsedMicroseconds.toDouble();
    if (us < best) best = us;
  }
  return best;
}

Future<void> _burst(IsolatePool pool) =>
    Future.wait([for (var i = 0; i < _tasks; i++) pool.dispatch<int>(_burn, [_workIters])]);

/// Sustained stream until the pool ramps to [target] workers.
Future<void> _rampTo(IsolatePool pool, int target) async {
  final inflight = <Future<int>>[];
  for (var i = 0; i < 2000 && pool.workerCount < target; i++) {
    inflight.add(pool.dispatch<int>(_burn, [_workIters]));
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  await Future.wait(inflight);
}

Future<void> main() async {
  final cores = Platform.numberOfProcessors;
  stdout.writeln('=== IsolatePool approaches  mode=$_mode  cores=$cores  '
      'tasks=$_tasks  work=$_workIters ===\n');

  // ── Startup: cost to create + ready the pool ───────────────────────────────
  stdout.writeln('startup (create → ready):');
  {
    final t = await _bestUs(3, () async => (await IsolatePool.create(1)).dispose());
    _record('startup fixed-1 / adaptive', t / 1000, 'ms');
    final tN = await _bestUs(3, () async => (await IsolatePool.create(cores)).dispose());
    _record('startup fixed-$cores (pre-warm)', tN / 1000, 'ms');
  }

  // ── Per-call latency (sequential, no concurrency): adaptive must equal fixed-1
  stdout.writeln('\nper-call latency (sequential):');
  const seqN = 20000, seqWarm = 4000;
  for (final adaptive in [false, true]) {
    final pool = adaptive ? await IsolatePool.create(1, maxWorkers: cores) : await IsolatePool.create(1);
    for (var i = 0; i < seqWarm; i++) {
      await pool.dispatch<int>(_noop, [i]);
    }
    final us = await _bestUs(3, () async {
      for (var i = 0; i < seqN; i++) {
        await pool.dispatch<int>(_noop, [i]);
      }
    });
    _record(adaptive ? 'dispatch adaptive (1 worker)' : 'dispatch fixed-1', us / seqN, 'us/call');
    pool.dispose();
  }
  {
    const n = 300, warm = 20;
    for (var i = 0; i < warm; i++) {
      await Isolate.run(_tiny);
    }
    final us = await _bestUs(2, () async {
      for (var i = 0; i < n; i++) {
        await Isolate.run(_tiny);
      }
    });
    _record('dispatch legacy Isolate.run', us / n, 'us/call');
  }

  // ── Cold first burst: one concurrent burst on a FRESH pool ──────────────────
  // Lazy-start approaches (fixed-1, adaptive) have only 1 worker here, so the
  // burst's calls are all routed before any growth completes — the inherent
  // cost of not pre-warming. fixed-N pre-spawned its workers in create().
  stdout.writeln('\ncold first burst ($_tasks tasks on a fresh pool):');
  Future<double> coldBurst(Future<IsolatePool> Function() make) => _bestUs(2, () async {
        final pool = await make();
        await _burst(pool);
        pool.dispose();
      });
  _record('cold fixed-1', await coldBurst(() => IsolatePool.create(1)) / 1000, 'ms');
  _record('cold adaptive', await coldBurst(() => IsolatePool.create(1, maxWorkers: cores)) / 1000, 'ms');
  _record('cold fixed-$cores', await coldBurst(() => IsolatePool.create(cores)) / 1000, 'ms');

  // ── Warm/steady burst: concurrent burst after the pool has reached width ────
  // adaptive must match fixed-N here — that's the "no compromise under load".
  stdout.writeln('\nwarm/steady burst ($_tasks tasks):');
  {
    final pool = await IsolatePool.create(1);
    await _burst(pool); // warm JIT
    _record('warm fixed-1', await _bestUs(3, () => _burst(pool)) / 1000, 'ms');
    pool.dispose();
  }
  {
    final pool = await IsolatePool.create(1, maxWorkers: cores);
    await _rampTo(pool, cores);
    await _burst(pool);
    _record('warm adaptive', await _bestUs(3, () => _burst(pool)) / 1000, 'ms');
    stdout.writeln('    adaptive reached ${pool.workerCount} workers (cap $cores)');
    pool.dispose();
  }
  {
    final pool = await IsolatePool.create(cores);
    await _burst(pool);
    _record('warm fixed-$cores', await _bestUs(3, () => _burst(pool)) / 1000, 'ms');
    pool.dispose();
  }
}
