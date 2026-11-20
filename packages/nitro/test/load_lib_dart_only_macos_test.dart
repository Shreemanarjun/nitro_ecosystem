// A Dart-only macOS process (`dart run`, `dart test`, `dart compile exe`) has
// no app binary with the bridge linked in, so NitroRuntime.loadLib must open
// the plugin's dylib from the loader's search path. This builds a one-symbol
// dylib with clang and loads it from a real `dart` subprocess.
@TestOn('mac-os')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  test('loadLib opens lib<name>.dylib when the process does not hold the bridge', () async {
    final tmp = Directory.systemTemp.createTempSync('nitro_dylib_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // `<lib>_init_dart_api_dl` is the first symbol a generated bridge looks up.
    File('${tmp.path}/probe.c').writeAsStringSync('long nitro_probe_init_dart_api_dl(void* data) { return 42; }\n');
    final cc = Process.runSync('clang', ['-dynamiclib', '${tmp.path}/probe.c', '-o', '${tmp.path}/libnitro_probe.dylib']);
    expect(cc.exitCode, 0, reason: '${cc.stderr}');

    File('${tmp.path}/probe.dart').writeAsStringSync('''
import 'dart:ffi';
import 'package:nitro/nitro.dart';

void main() {
  final lib = NitroRuntime.loadLib('nitro_probe');
  final init = lib.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('nitro_probe_init_dart_api_dl');
  print('probe=\${init(nullptr)}');
}
''');
    final packages = (await Isolate.packageConfig)!.toFilePath();

    ProcessResult run(Map<String, String> environment) =>
        Process.runSync(Platform.resolvedExecutable, ['--packages=$packages', '${tmp.path}/probe.dart'], environment: environment);

    final found = run({'DYLD_LIBRARY_PATH': tmp.path});
    expect(found.stdout, contains('probe=42'), reason: '${found.stderr}');

    // Without the dylib the process() handle is kept, so the failure still
    // names the missing symbol (what a Flutter app with a stripped export sees).
    final missing = run({});
    expect(missing.exitCode, isNot(0));
    expect(missing.stderr, contains("Failed to lookup symbol 'nitro_probe_init_dart_api_dl'"));
  });

  test('a library that is nowhere still loads lazily, as before', () {
    expect(() => NitroRuntime.loadLib('nitro_no_such_library'), returnsNormally);
    NitroRuntime.releaseLib('nitro_no_such_library');
  });
}
