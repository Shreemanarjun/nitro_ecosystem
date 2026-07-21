// Headless harness runner for RELEASE-mode measurement.
//
// `flutter test` cannot build --release, so the app itself runs the exact
// same BenchHarness when launched with --dart-define=BENCH_AUTORUN=<mode>
// and prints results to the device log with a `BENCH|` prefix (plain `print`
// — debugPrint output is not reliable in release). The process exits when
// done so the caller's `flutter run --release` terminates on its own.
import 'dart:convert';
import 'dart:io';

import 'bench_harness.dart';

Future<void> runBenchAutorun(String mode) async {
  // iOS release has no host-visible stdout — leave a breadcrumb trail in the
  // app container instead (pullable via devicectl appDataContainer copy).
  final home = Platform.environment['HOME'];
  final docs = home != null ? Directory('$home/Documents') : null;
  try {
    docs?.createSync(recursive: true);
    File('${docs!.path}/bench_started.txt').writeAsStringSync('mode=$mode ${DateTime.now()}');
  } catch (_) {}
  try {
    final report = await BenchHarness.run(
      config: BenchConfig.fromMode(mode == 'full' ? 'full' : 'quick'),
      // ignore: avoid_print
      onCaseStart: (id) => print('BENCH|running: $id'),
    );
    for (final line in report.toTableLines()) {
      // ignore: avoid_print
      print('BENCH|$line');
    }
    // Logcat truncates long lines (~1-4 KB), so the report JSON is emitted
    // in ordered chunks and reassembled by tool/bench.sh.
    final encoded = jsonEncode(report.toJson());
    const chunk = 700;
    var n = 0;
    for (var i = 0; i < encoded.length; i += chunk) {
      final end = (i + chunk < encoded.length) ? i + chunk : encoded.length;
      // ignore: avoid_print
      print('BENCH|J#${n.toString().padLeft(4, '0')}|${encoded.substring(i, end)}');
      n++;
    }
    // ignore: avoid_print
    print('BENCH|JEND|$n');
    // iOS release: print() never reaches any host-visible log, so ALSO write
    // the report into the app container — pullable via
    //   xcrun devicectl device copy from --domain-type appDataContainer
    // ($HOME inside the sandbox is the container root).
    try {
      final home = Platform.environment['HOME'];
      if (home != null) {
        final f = File('$home/Documents/bench_report.json');
        await f.writeAsString(encoded);
        // ignore: avoid_print
        print('BENCH|FILE|${f.path}');
      }
    } catch (_) {}
    // ignore: avoid_print
    print('BENCH|DONE');
  } catch (e, st) {
    // ignore: avoid_print
    print('BENCH|ERROR|$e\n$st');
    try {
      File('${docs!.path}/bench_error.txt').writeAsStringSync('$e\n$st');
    } catch (_) {}
  }
  // Give the log a moment to flush before killing the process.
  await Future<void>.delayed(const Duration(seconds: 2));
  exit(0);
}
