// GitHub #61: the vendored `dart_api_dl.c` is copied into every nitro plugin,
// so an iOS/macOS SPM app that links two or more plugins links their object
// files together. Each `Dart_*_DL` symbol must be WEAK or the second copy is a
// duplicate definition. This compiles the real vendored file as several
// translation units and links the actual multi-plugin scenarios, with a
// derived "strong" variant as the control that proves the test detects the bug.
//
// Needs a C/C++ compiler; skips cleanly when clang is absent so pure-Dart CI
// stays green.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final hasClang = Process.runSync('which', ['clang']).exitCode == 0;

  group('dart_api_dl.c multi-plugin link (#61)', () {
    late Directory tmp;
    const inc = 'src/native'; // cwd is packages/nitro under `dart test`
    late String weakC;
    late String strongC;
    late String mainO;

    setUpAll(() {
      final weakSrc = File('$inc/dart_api_dl.c').readAsStringSync();
      tmp = Directory.systemTemp.createTempSync('dldl_');
      weakC = '${tmp.path}/weak.c';
      File(weakC).writeAsStringSync(weakSrc);

      // Strong control: neuter the weak macro's active definition, so every
      // symbol is strong again — exactly what two pre-fix plugins each shipped.
      strongC = '${tmp.path}/strong.c';
      final strongSrc = weakSrc.replaceAll(
        '#define NITRO_DL_WEAK __attribute__((weak))',
        '#define NITRO_DL_WEAK /* strong (test control) */',
      );
      // Guard: the neutering must have actually changed the file.
      if (strongSrc == weakSrc) {
        fail('could not derive a strong control — the weak macro definition changed shape');
      }
      File(strongC).writeAsStringSync(strongSrc);

      final mainC = '${tmp.path}/main.c';
      File(mainC).writeAsStringSync(
        'extern int Dart_InitializeApiDL(void*);\n'
        'int main(void) { return Dart_InitializeApiDL((void*)0) ? 1 : 0; }\n',
      );
      mainO = '${tmp.path}/main.o';
      final r = Process.runSync('clang', ['-c', mainC, '-o', mainO]);
      if (r.exitCode != 0) fail('main compile failed: ${r.stderr}');
    });

    tearDownAll(() => tmp.deleteSync(recursive: true));

    String obj(String src, {required bool cpp, required String tag}) {
      final o = '${tmp.path}/$tag.o';
      final r = Process.runSync(cpp ? 'clang++' : 'clang', [
        if (cpp) ...['-x', 'c++'],
        '-I', inc, '-c', src, '-o', o,
      ]);
      if (r.exitCode != 0) fail('compile $tag failed: ${r.stderr}');
      return o;
    }

    ProcessResult link(List<String> objs, {bool cpp = false}) =>
        Process.runSync(cpp ? 'clang++' : 'clang', [...objs, mainO, '-o', '${tmp.path}/out']);

    test('two weak plugins coalesce and link', () {
      final r = link([obj(weakC, cpp: false, tag: 'w1'), obj(weakC, cpp: false, tag: 'w2')]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    test('three weak plugins link', () {
      final r = link([
        obj(weakC, cpp: false, tag: 'wa'),
        obj(weakC, cpp: false, tag: 'wb'),
        obj(weakC, cpp: false, tag: 'wc'),
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    test('control: two STRONG plugins fail with a duplicate-definition error', () {
      final r = link([obj(strongC, cpp: false, tag: 's1'), obj(strongC, cpp: false, tag: 's2')]);
      expect(r.exitCode, isNot(0));
      final err = '${r.stderr}'.toLowerCase();
      expect(err, anyOf(contains('duplicate symbol'), contains('multiple definition')),
          reason: 'expected a dup-symbol error, got: $err');
    });

    test('partial upgrade: one strong + one weak still links (weak yields to strong)', () {
      final r = link([obj(strongC, cpp: false, tag: 'ps'), obj(weakC, cpp: false, tag: 'pw')]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    test('two weak plugins compiled as C++ (the @Native path) link', () {
      final r = link([obj(weakC, cpp: true, tag: 'cpp1'), obj(weakC, cpp: true, tag: 'cpp2')], cpp: true);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    test('runtime: Dart_InitializeApiDL populates the weak globals and version-checks', () {
      final itC = '${tmp.path}/it.c';
      File(itC).writeAsStringSync('''
#include "dart_api_dl.h"
#include "dart_version.h"
#include "internal/dart_api_dl_impl.h"
static void fake_post(void) {}
int main(void) {
  static const DartApiEntry e[] = { { "Dart_PostCObject", fake_post }, { 0, 0 } };
  const DartApi api = { DART_API_DL_MAJOR_VERSION, 0, e };
  if (Dart_InitializeApiDL((void*)&api) != 0) return 1;
  if (Dart_PostCObject_DL != (Dart_PostCObject_Type)(void*)fake_post) return 2;
  const DartApi bad = { DART_API_DL_MAJOR_VERSION + 1, 0, e };
  if (Dart_InitializeApiDL((void*)&bad) != -1) return 3;
  return 0;
}
''');
      final itO = '${tmp.path}/it.o';
      final c = Process.runSync('clang', ['-I', inc, '-c', itC, '-o', itO]);
      if (c.exitCode != 0) fail('init-test compile failed: ${c.stderr}');
      // Link against two weak copies so the shared (coalesced) globals are exercised.
      final exe = '${tmp.path}/it_exe';
      final l = Process.runSync('clang', [itO, obj(weakC, cpp: false, tag: 'rt'), '-o', exe]);
      expect(l.exitCode, 0, reason: '${l.stderr}');
      final run = Process.runSync(exe, []);
      expect(run.exitCode, 0, reason: 'init runtime check failed with code ${run.exitCode}');
    });
  }, skip: hasClang ? false : 'clang not on PATH');
}
