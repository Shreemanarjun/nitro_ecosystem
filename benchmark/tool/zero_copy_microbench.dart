// Microbenchmark for the per-call cost zero-copy TypedData eliminates. True
// `.address` needs the @Native build pipeline, so this measures the delta:
//   path A: a leaf call on a buffer already in native memory (≈ zero-copy cost).
//   path B: malloc + memcpy + leaf call + free, per call (the _dylib copy path).
// B − A is the overhead `.address` removes — ~0 for tiny buffers, growing with
// size. Usage: dart run tool/zero_copy_microbench.dart (needs clang on PATH).
// Exits non-zero if B isn't slower than A at >=256 KiB (the ratio gate).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

const _c = r'''
#include <stdint.h>
#include <stdlib.h>
int64_t zc_sum_bytes(const uint8_t* p, int64_t n) {
  int64_t s = 0;
  for (int64_t i = 0; i < n; i++) s += p[i];
  return s;
}
uint8_t* zc_alloc(int64_t n) { return (uint8_t*)malloc((size_t)n); }
void zc_free(uint8_t* p) { free(p); }
''';

typedef _NSum = Int64 Function(Pointer<Uint8>, Int64);
typedef _DSum = int Function(Pointer<Uint8>, int);
typedef _NAlloc = Pointer<Uint8> Function(Int64);
typedef _DAlloc = Pointer<Uint8> Function(int);
typedef _NFree = Void Function(Pointer<Uint8>);
typedef _DFree = void Function(Pointer<Uint8>);

int _median(List<int> xs) {
  xs.sort();
  return xs[xs.length ~/ 2];
}

void main() {
  final tmp = Directory.systemTemp.createTempSync('zc_bench_');
  try {
    File('${tmp.path}/zc.c').writeAsStringSync(_c);
    final libName = Platform.isMacOS ? 'libzc.dylib' : (Platform.isWindows ? 'zc.dll' : 'libzc.so');
    final lib = '${tmp.path}/$libName';
    final cc = Platform.environment['CC'] ?? 'clang';
    final r = Process.runSync(cc, ['-O2', '-shared', '-fPIC', '${tmp.path}/zc.c', '-o', lib]);
    if (r.exitCode != 0) {
      stderr.writeln('$cc failed:\n${r.stdout}\n${r.stderr}');
      exit(1);
    }
    final dl = DynamicLibrary.open(lib);
    final sum = dl.lookup<NativeFunction<_NSum>>('zc_sum_bytes').asFunction<_DSum>(isLeaf: true);
    final alloc = dl.lookup<NativeFunction<_NAlloc>>('zc_alloc').asFunction<_DAlloc>(isLeaf: true);
    final free = dl.lookup<NativeFunction<_NFree>>('zc_free').asFunction<_DFree>(isLeaf: true);

    const sizes = [64, 1024, 16 * 1024, 256 * 1024, 1024 * 1024];
    const samples = 7;
    stdout.writeln('buffer       A: call-only   B: copy+call   B−A saved   B/A   (ns/op)');
    stdout.writeln('----------------------------------------------------------------------');

    var gateChecked = false;
    for (final n in sizes) {
      final data = Uint8List(n);
      for (var i = 0; i < n; i++) {
        data[i] = i & 0xff;
      }
      final iters = n <= 16 * 1024 ? 20000 : 4000;

      // Path A: buffer already native (persistent) — just the leaf call.
      final persistent = alloc(n);
      persistent.asTypedList(n).setAll(0, data);
      for (var i = 0; i < 2000; i++) {
        sum(persistent, n); // warmup
      }
      final aNs = _median([
        for (var s = 0; s < samples; s++)
          () {
            final sw = Stopwatch()..start();
            for (var i = 0; i < iters; i++) {
              if (sum(persistent, n) < 0) throw StateError('neg');
            }
            sw.stop();
            return sw.elapsedMicroseconds * 1000 ~/ iters;
          }(),
      ]);
      free(persistent);

      // Path B: the _dylib marshalling — malloc + memcpy + call + free each time.
      final bNs = _median([
        for (var s = 0; s < samples; s++)
          () {
            final sw = Stopwatch()..start();
            for (var i = 0; i < iters; i++) {
              final p = alloc(n);
              p.asTypedList(n).setAll(0, data); // memcpy
              try {
                if (sum(p, n) < 0) throw StateError('neg');
              } finally {
                free(p);
              }
            }
            sw.stop();
            return sw.elapsedMicroseconds * 1000 ~/ iters;
          }(),
      ]);

      final saved = bNs - aNs;
      final ratio = bNs / (aNs == 0 ? 1 : aNs);
      stdout.writeln('${_fmt(n).padRight(11)} '
          '${aNs.toString().padLeft(10)}    ${bNs.toString().padLeft(10)}    '
          '${saved.toString().padLeft(8)}   ${ratio.toStringAsFixed(2).padLeft(5)}');

      if (n >= 256 * 1024) {
        gateChecked = true;
        if (bNs <= aNs) {
          stderr.writeln('GATE FAIL: at ${_fmt(n)} the copy path (B=$bNs ns) was not '
              'slower than call-only (A=$aNs ns) — the measured zero-copy saving vanished.');
          exit(1);
        }
      }
    }
    if (!gateChecked) {
      stderr.writeln('GATE FAIL: no large-buffer sample ran.');
      exit(1);
    }
    stdout.writeln('\nOK: the malloc+memcpy+free that `.address` eliminates grows with buffer '
        'size (B−A). On the @Native path a leaf TypedData param pays only column A.');
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

String _fmt(int n) {
  if (n >= 1024 * 1024) return '${n ~/ (1024 * 1024)} MiB';
  if (n >= 1024) return '${n ~/ 1024} KiB';
  return '$n B';
}
