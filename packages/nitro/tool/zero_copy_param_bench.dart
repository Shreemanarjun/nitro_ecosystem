// Before/after for the @zeroCopy TypedData PARAMETER change, through nitro's real
// runtime (withArena + the zero-copy registry) and a real leaf native call, at
// frame sizes. Run AOT (primary) and JIT:
//   dart run packages/nitro/tool/zero_copy_param_bench.dart
//   dart compile exe packages/nitro/tool/zero_copy_param_bench.dart -o <tmp>/zcp && <tmp>/zcp
//
// Three arms, each the exact expression a generator emits for `@zeroCopy Uint8List data`:
//   OLD   (0.8.3): data.toPointer(arena)                               — always malloc+memcpy
//   NEW   (0.8.4): nitroZeroCopyPtr(data)?.cast<Uint8>() ?? toPointer  — pointer pass-through
//                  measured on a NitroBuffer view (native-backed → no copy)
//   NEW-heap     : same NEW expression on a plain Uint8List            — registry miss → copies,
//                  i.e. unchanged from OLD (non-NitroBuffer lists keep the copy)
import 'dart:io';

import 'package:nitro/nitro.dart';

const _c = r'''
#include <stdint.h>
int64_t zc_touch(const uint8_t* p, int64_t n){ int64_t s=0; for(int64_t i=0;i<n;i+=4096) s+=p[i]; return s; }
''';
typedef _N = Int64 Function(Pointer<Uint8>, Int64);
typedef _D = int Function(Pointer<Uint8>, int);

const _mode = bool.fromEnvironment('dart.vm.product') ? 'AOT' : 'JIT';
int _median(List<int> xs) { xs.sort(); return xs[xs.length ~/ 2]; }
String _us(int ns) => (ns / 1000).toStringAsFixed(2);

void main() {
  final tmp = Directory.systemTemp.createTempSync('zcp_');
  File('${tmp.path}/zc.c').writeAsStringSync(_c);
  final lib = '${tmp.path}/${Platform.isMacOS ? 'libzc.dylib' : 'libzc.so'}';
  final r = Process.runSync('clang', ['-O2', '-shared', '-fPIC', '${tmp.path}/zc.c', '-o', lib]);
  if (r.exitCode != 0) { stderr.writeln(r.stderr); exit(1); }
  final touch = DynamicLibrary.open(lib).lookupFunction<_N, _D>('zc_touch', isLeaf: true);

  // The two emissions, byte-for-byte what the generator produces.
  int oldEmit(Uint8List d) => withArena((a) => touch(d.toPointer(a), d.length));
  int newEmit(Uint8List d) => withArena((a) => touch(nitroZeroCopyPtr(d)?.cast<Uint8>() ?? d.toPointer(a), d.length));

  int best(int Function() op) {
    for (var i = 0; i < 12; i++) { op(); }
    return _median([for (var s = 0; s < 9; s++) () { final n = _reps; final sw = Stopwatch()..start(); for (var i = 0; i < n; i++) { op(); } return sw.elapsedMicroseconds * 1000 ~/ n; }()]);
  }

  stdout.writeln('mode=$_mode   @zeroCopy Uint8List param — µs/call (median), real runtime + real native call\n');
  stdout.writeln('frame    OLD 0.8.3 (copy)   NEW 0.8.4 NitroBuffer   speedup   NEW on heap list (=OLD)');
  stdout.writeln('--------------------------------------------------------------------------------------');
  for (final mb in [1, 2, 4, 8]) {
    final n = mb << 20;
    _reps = mb <= 2 ? 500 : 150;
    final heap = Uint8List(n);
    for (var i = 0; i < n; i += 97) { heap[i] = i & 0xff; }
    final buf = NitroBuffer(n)..bytes.setAll(0, heap);

    final oldUs = best(() => oldEmit(buf.bytes));   // 0.8.3: even a NitroBuffer view was copied
    final newUs = best(() => newEmit(buf.bytes));   // 0.8.4: pass-through
    final newHeap = best(() => newEmit(heap));      // 0.8.4 on a heap list: still copies
    buf.dispose();
    final sp = (oldUs / (newUs < 1 ? 1 : newUs)).toStringAsFixed(0);
    stdout.writeln('${mb.toString().padLeft(3)} MB   ${_us(oldUs).padLeft(13)} µs   ${_us(newUs).padLeft(17)} µs   ${'${sp}x'.padLeft(7)}   ${_us(newHeap).padLeft(16)} µs');
  }
  tmp.deleteSync(recursive: true);
}

int _reps = 500;
