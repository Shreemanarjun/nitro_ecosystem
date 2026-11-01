// Proves, through the real DynamicLibrary marshalling expression the generator
// emits for a @zeroCopy TypedData param, that a nitro native-backed view
// reaches native BY POINTER (no copy) while a Dart-heap list still copies.
import 'dart:io';

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

const _c = r'''
#include <stdint.h>
int64_t zc_echo_addr(const uint8_t* p, int64_t n) { (void)n; return (int64_t)(intptr_t)p; }
''';
typedef _N = Int64 Function(Pointer<Uint8>, Int64);
typedef _D = int Function(Pointer<Uint8>, int);

void main() {
  final hasClang = Process.runSync('which', ['clang']).exitCode == 0;

  group('@zeroCopy param pass-through (dylib path, real native call)', () {
    late Directory tmp;
    late _D echo;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('zc_pass_');
      File('${tmp.path}/zc.c').writeAsStringSync(_c);
      final lib = '${tmp.path}/${Platform.isMacOS ? 'libzc.dylib' : 'libzc.so'}';
      final r = Process.runSync('clang', ['-O2', '-shared', '-fPIC', '${tmp.path}/zc.c', '-o', lib]);
      if (r.exitCode != 0) fail('clang failed: ${r.stderr}');
      echo = DynamicLibrary.open(lib).lookupFunction<_N, _D>('zc_echo_addr', isLeaf: true);
    });
    tearDownAll(() => tmp.deleteSync(recursive: true));

    // Exactly what the generator emits for `@zeroCopy Uint8List data` on the
    // DynamicLibrary path.
    int callAsGenerated(Uint8List data) => withArena((arena) => echo(nitroZeroCopyPtr(data)?.cast<Uint8>() ?? data.toPointer(arena), data.length));

    test('a NitroBuffer view reaches native by pointer — zero copy', () {
      final buf = NitroBuffer(4 << 20);
      try {
        expect(callAsGenerated(buf.bytes), buf.pointer.address);
        expect(callAsGenerated(buf.view(1000)), buf.pointer.address);
      } finally {
        buf.dispose();
      }
    });

    test('a native-owned view like a @zeroCopy return produces also passes through', () {
      final p = malloc<Uint8>(256);
      try {
        final view = nitroRegisterZeroCopyView(p.asTypedList(256), p.cast());
        expect(callAsGenerated(view), p.address);
      } finally {
        malloc.free(p);
      }
    });

    test('a Dart-heap list still takes the copy path', () {
      final heap = Uint8List(4096)..[7] = 9;
      expect(nitroZeroCopyPtr(heap), isNull);
      final seen = callAsGenerated(heap);
      expect(seen, isNot(0));
      // Native saw an arena copy, not any address we registered.
      final buf = NitroBuffer(16);
      try {
        expect(seen, isNot(buf.pointer.address));
      } finally {
        buf.dispose();
      }
    });
  }, skip: hasClang ? false : 'clang not on PATH');
}
