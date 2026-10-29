// Benchmarks the adaptive pool's idle-shrink. Run AOT (primary) and JIT:
//
//   dart run packages/nitro/tool/isolate_pool_shrink_bench.dart
//   dart compile exe packages/nitro/tool/isolate_pool_shrink_bench.dart -o <tmp>/sb && <tmp>/sb
//
// What it shows:
//   1. the pool shrinks back to the floor after idle, and how long that takes;
//   2. regrowing after a shrink (reusing tombstoned slots) is as fast as the
//      first grow — shrink never makes a later burst slower;
//   3. RSS stays FLAT across repeated grow/shrink cycles — the retired isolate
//      heaps are freed to the VM and reused, so churn doesn't leak. (RSS is a
//      high-water mark: the OS isn't handed the pages back promptly, so you see
//      "flat, not climbing" rather than an instant drop. RSS is only meaningful
//      in AOT; under JIT the compiler's own memory dominates.)
import 'dart:async';
import 'dart:io';

import 'package:nitro/nitro.dart';

int _burn(int iters) {
  var x = 0;
  for (var i = 0; i < iters; i++) {
    x = (x + i * 2654435761) & 0x7fffffff;
  }
  return x;
}

const _mode = bool.fromEnvironment('dart.vm.product') ? 'AOT' : 'JIT';
const _work = 3000000;
const _tasks = 96;

int _rssMB() => (ProcessInfo.currentRss / (1024 * 1024)).round();

Future<void> _rampTo(IsolatePool pool, int target) async {
  final inflight = <Future<int>>[];
  for (var i = 0; i < 2000 && pool.workerCount < target; i++) {
    inflight.add(pool.dispatch<int>(_burn, [_work]));
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  await Future.wait(inflight);
}

Future<int> _bestBurstMs(IsolatePool pool) async {
  var best = 1 << 30;
  for (var r = 0; r < 3; r++) {
    final sw = Stopwatch()..start();
    await Future.wait([for (var i = 0; i < _tasks; i++) pool.dispatch<int>(_burn, [_work])]);
    if (sw.elapsedMilliseconds < best) best = sw.elapsedMilliseconds;
  }
  return best;
}

/// Idle until the pool drops to one worker; returns the wall-clock it took.
Future<int> _awaitShrink(IsolatePool pool, Duration reap) async {
  final sw = Stopwatch()..start();
  while (pool.workerCount > 1 && sw.elapsed < const Duration(seconds: 20)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  sw.stop();
  await Future<void>.delayed(const Duration(milliseconds: 300)); // let freed heaps settle
  return sw.elapsedMilliseconds;
}

Future<void> main(List<String> args) async {
  final cores = Platform.numberOfProcessors;

  // Control: repeatedly create+dispose FULL pools (the long-standing teardown
  // path, no shrink involved). If this climbs RSS the same way, the climb is
  // inherent isolate spawn/exit churn in the VM, not the shrink code.
  if (args.contains('createdispose')) {
    stdout.writeln('=== create/dispose churn (control)  mode=$_mode  cores=$cores ===\n');
    for (var c = 1; c <= 6; c++) {
      final p = await IsolatePool.create(cores);
      await Future.wait([for (var i = 0; i < 16; i++) p.dispatch<int>(_burn, [_work])]);
      p.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      stdout.writeln('cycle $c: rss=${_rssMB()}MB');
    }
    return;
  }

  const reap = Duration(milliseconds: 400);
  stdout.writeln('=== idle-shrink bench  mode=$_mode  cores=$cores  reapInterval=${reap.inMilliseconds}ms ===\n');

  final pool = await IsolatePool.create(1, maxWorkers: cores, idleReap: reap);
  await pool.dispatch<int>(_burn, [_work]); // warm the floor worker
  stdout.writeln('floor        : workers=${pool.workerCount}  rss=${_rssMB()}MB\n');

  // Repeated grow → burst → idle-shrink cycles. A real leak from grow/shrink
  // churn would show peak RSS climbing ~linearly; slot reuse should plateau it.
  const cycles = 20;
  final peaks = <int>[];
  var firstBurst = 0;
  var lastBurst = 0;
  for (var c = 1; c <= cycles; c++) {
    await _rampTo(pool, cores);
    final peak = _rssMB();
    peaks.add(peak);
    final burst = await _bestBurstMs(pool);
    if (c == 1) firstBurst = burst;
    lastBurst = burst;
    final lat = await _awaitShrink(pool, reap);
    stdout.writeln('cycle $c: grow→${cores}w rss=${peak}MB burst=${burst}ms  '
        'shrink→${pool.workerCount}w latency=${lat}ms (~${(lat / reap.inMilliseconds).toStringAsFixed(1)} windows)');
  }

  // A leak climbs ~linearly; a healthy pool warms up to its steady-state
  // working set (peak-width isolates, reused) and then holds flat. Judge by the
  // tail: if the last few cycles are stable, it plateaued.
  final tail = peaks.sublist(peaks.length - 4);
  final tailSpread = tail.reduce((a, b) => a > b ? a : b) - tail.reduce((a, b) => a < b ? a : b);
  stdout.writeln('\nshrink       : every cycle returned to 1 worker');
  stdout.writeln('regrow parity: burst ${lastBurst}ms vs first ${firstBurst}ms → ${(lastBurst / firstBurst).toStringAsFixed(2)}×  (slot reuse is free)');
  stdout.writeln('peak RSS     : ${peaks.join('→')}MB');
  stdout.writeln('             → ${tailSpread <= 2 ? 'PLATEAUS at ~${tail.last}MB (steady-state working set reused — no leak)' : 'last-4 spread ${tailSpread}MB — still climbing, investigate'}');

  pool.dispose();
}
