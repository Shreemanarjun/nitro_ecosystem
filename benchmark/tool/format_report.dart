// Formats a benchmark run's JSON report as a markdown table and archives it.
//
// Usage:
//   dart run tool/format_report.dart <integration_response_data.json>
//       [--out-dir <dir>] [--update-baseline <baselines-dir>]
//
// The input is the file written by test_driver/integration_test.dart:
//   {"benchmark_report": { schema, platform, cases, derived, ... }}
//
// --out-dir           also writes the bare report to <dir>/<platform>-<mode>.json
// --update-baseline   also writes it to <dir>/<platform>.json (the gate baseline)

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: format_report.dart <response.json> '
        '[--out-dir DIR] [--update-baseline DIR]');
    exit(64);
  }

  final inputFile = File(args[0]);
  if (!inputFile.existsSync()) {
    stderr.writeln('response file not found: ${args[0]}');
    exit(66);
  }

  String? outDir;
  String? baselineDir;
  for (var i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--out-dir':
        outDir = args[++i];
      case '--update-baseline':
        baselineDir = args[++i];
      default:
        stderr.writeln('unknown option: ${args[i]}');
        exit(64);
    }
  }

  final envelope =
      jsonDecode(inputFile.readAsStringSync()) as Map<String, dynamic>;
  final report = envelope['benchmark_report'] as Map<String, dynamic>?;
  if (report == null) {
    stderr.writeln('no "benchmark_report" key in ${args[0]} — '
        'did the integration test run to completion?');
    exit(65);
  }

  final platform = report['platform'] as String;
  final mode = report['mode'] as String;
  final buildMode = report['buildMode'] as String;
  final cases = report['cases'] as Map<String, dynamic>;
  final derived = report['derived'] as Map<String, dynamic>;

  double? medianOf(String id) =>
      (cases[id] as Map<String, dynamic>?)?['medianUs'] as double?;

  final rawFfi = medianOf('raw_ffi_add');
  final channel = medianOf('method_channel_add');

  final out = StringBuffer()
    ..writeln('## Nitro bridge benchmark — $platform ($buildMode, $mode)')
    ..writeln()
    ..writeln('| Case | Median | vs raw FFI | vs MethodChannel |')
    ..writeln('|---|---|---|---|');

  for (final entry in cases.entries) {
    final c = entry.value as Map<String, dynamic>;
    if (c['kind'] != 'latency') continue;
    final median = (c['medianUs'] as num).toDouble();
    final vsFfi = rawFfi == null || rawFfi == 0
        ? '—'
        : '${(median / rawFfi).toStringAsFixed(2)}×';
    final vsChannel = channel == null || median == 0
        ? '—'
        : '${(channel / median).toStringAsFixed(1)}× faster';
    out.writeln('| ${c['label']} | ${median.toStringAsFixed(3)} µs '
        '| $vsFfi | $vsChannel |');
  }

  final throughputRows = cases.entries
      .where((e) => (e.value as Map<String, dynamic>)['kind'] == 'throughput')
      .toList();
  if (throughputRows.isNotEmpty) {
    out
      ..writeln()
      ..writeln('| Throughput case | MB/s | Payload |')
      ..writeln('|---|---|---|');
    for (final entry in throughputRows) {
      final c = entry.value as Map<String, dynamic>;
      final mb = (c['mbPerSec'] as num).toDouble();
      final payloadMiB =
          ((c['bytesPerOp'] as num) / (1024 * 1024)).toStringAsFixed(0);
      out.writeln('| ${c['label']} | ${mb.toStringAsFixed(0)} '
          '| $payloadMiB MiB |');
    }
  }

  out
    ..writeln()
    ..writeln('Derived ratios (regression-gated): '
        '${derived.entries.map((e) => '${e.key}='
            '${e.value is num ? (e.value as num).toStringAsFixed(2) : '—'}').join(' · ')}');

  stdout.write(out);

  final reportJson =
      const JsonEncoder.withIndent('  ').convert(report);
  if (outDir != null) {
    final f = File('$outDir/$platform-$mode.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('$reportJson\n');
    stderr.writeln('report archived: ${f.path}');
  }
  if (baselineDir != null) {
    final f = File('$baselineDir/$platform.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('$reportJson\n');
    stderr.writeln('baseline updated: ${f.path}');
  }
}
