// Formats a benchmark run's JSON report as a markdown analysis and archives it.
//
// Usage:
//   dart run tool/format_report.dart <integration_response_data.json>
//       [--out-dir <dir>] [--update-baseline <baselines-dir>]
//       [--baseline <file>] [--compare-dir <dir>]
//
// The input is the file written by test_driver/integration_test.dart:
//   {"benchmark_report": { schema, platform, cases, derived, ... }}
//
// --out-dir           also writes the bare report to <dir>/<platform>-<mode>.json
// --update-baseline   also writes it to <dir>/<platform>.json (the gate baseline)
// --baseline          compare against this baseline report (Δ column + drift table)
// --compare-dir       scan for other <platform>-<mode>.json reports and emit a
//                     cross-platform comparison matrix

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: format_report.dart <response.json> '
        '[--out-dir DIR] [--update-baseline DIR] '
        '[--baseline FILE] [--compare-dir DIR]');
    exit(64);
  }

  final inputFile = File(args[0]);
  if (!inputFile.existsSync()) {
    stderr.writeln('response file not found: ${args[0]}');
    exit(66);
  }

  String? outDir;
  String? baselineDir;
  String? baselinePath;
  String? baselinesDir;
  String? compareDir;
  for (var i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--out-dir':
        outDir = args[++i];
      case '--update-baseline':
        baselineDir = args[++i];
      case '--baseline':
        baselinePath = args[++i];
      case '--baselines-dir':
        baselinesDir = args[++i];
      case '--compare-dir':
        compareDir = args[++i];
      default:
        stderr.writeln('unknown option: ${args[i]}');
        exit(64);
    }
  }

  final envelope =
      jsonDecode(inputFile.readAsStringSync()) as Map<String, dynamic>;
  final report = envelope['benchmark_report'] as Map<String, dynamic>? ??
      // Allow passing a bare report file (e.g. an archived results JSON).
      (envelope.containsKey('cases') ? envelope : null);
  if (report == null) {
    stderr.writeln('no "benchmark_report" key in ${args[0]} — '
        'did the integration test run to completion?');
    exit(65);
  }

  final platform = report['platform'] as String;
  final mode = report['mode'] as String;
  final buildMode = report['buildMode'] as String;
  final cases = report['cases'] as Map<String, dynamic>;

  // --baseline takes precedence; otherwise resolve <baselines-dir>/<platform>.json.
  baselinePath ??=
      baselinesDir == null ? null : '$baselinesDir/$platform.json';
  Map<String, dynamic>? baseline;
  if (baselinePath != null && File(baselinePath).existsSync()) {
    baseline =
        jsonDecode(File(baselinePath).readAsStringSync()) as Map<String, dynamic>;
  }
  final baseCases = baseline?['cases'] as Map<String, dynamic>?;

  double? medianOf(Map<String, dynamic> caseMap, String id) =>
      ((caseMap[id] as Map<String, dynamic>?)?['medianUs'] as num?)?.toDouble();

  final rawFfi = medianOf(cases, 'raw_ffi_add');
  final channel = medianOf(cases, 'method_channel_add');

  String deltaCell(String id, double median) {
    if (baseCases == null) return '';
    final base = medianOf(baseCases, id);
    if (base == null || base == 0) return ' — |';
    final pct = (median - base) / base * 100;
    final arrow = pct.abs() < 3 ? '≈' : (pct > 0 ? '▲' : '▼');
    return ' $arrow ${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(0)}% |';
  }

  // 60 fps leaves 16.7ms per frame; how many bridge calls fit in ONE frame
  // is the most tangible "can I call this in a hot loop" number.
  String callsPerFrame(double medianUs) {
    final calls = 16667 / medianUs;
    if (calls >= 1000000) return '${(calls / 1000000).toStringAsFixed(1)}M';
    if (calls >= 1000) return '${(calls / 1000).toStringAsFixed(0)}k';
    return calls.toStringAsFixed(0);
  }

  final out = StringBuffer()
    ..writeln('## Nitro bridge benchmark — $platform ($buildMode, $mode)')
    ..writeln()
    ..writeln('### Latency')
    ..writeln()
    ..write('| Case | Median | Overhead vs raw FFI | vs MethodChannel '
        '| Calls per 16.7ms frame |')
    ..writeln(baseCases != null ? ' Δ vs baseline |' : '')
    ..write('|---|---|---|---|---|')
    ..writeln(baseCases != null ? '---|' : '');

  for (final entry in cases.entries) {
    final c = entry.value as Map<String, dynamic>;
    if (c['kind'] != 'latency') continue;
    final skipped = c['skipped'] as String?;
    if (skipped != null) {
      out
        ..write('| ${c['label']} | _skipped_ | — | — | — |')
        ..writeln(baseCases != null ? ' — |' : '');
      continue;
    }
    final median = (c['medianUs'] as num).toDouble();
    final overhead = rawFfi == null
        ? '—'
        : entry.key == 'raw_ffi_add'
            ? '— (floor)'
            : '+${(median - rawFfi).toStringAsFixed(3)} µs';
    final vsChannel = channel == null || median == 0
        ? '—'
        : '${(channel / median).toStringAsFixed(1)}× faster';
    out
      ..write('| ${c['label']} | ${median.toStringAsFixed(3)} µs '
          '| $overhead | $vsChannel | ${callsPerFrame(median)} |')
      ..writeln(baseCases != null ? deltaCell(entry.key, median) : '');
  }

  final throughputRows = cases.entries
      .where((e) => (e.value as Map<String, dynamic>)['kind'] == 'throughput')
      .toList();
  if (throughputRows.isNotEmpty) {
    out
      ..writeln()
      ..writeln('### Throughput')
      ..writeln()
      ..writeln('| Case | Bandwidth | Payload | vs MethodChannel copy |')
      ..writeln('|---|---|---|---|');
    final channelMb =
        ((cases['channel_buffer'] as Map<String, dynamic>?)?['mbPerSec'] as num?)
            ?.toDouble();
    for (final entry in throughputRows) {
      final c = entry.value as Map<String, dynamic>;
      final skipped = c['skipped'] as String?;
      if (skipped != null) {
        out.writeln('| ${c['label']} | _skipped_ | — | — |');
        continue;
      }
      final mb = (c['mbPerSec'] as num).toDouble();
      final payloadMiB =
          ((c['bytesPerOp'] as num) / (1024 * 1024)).toStringAsFixed(0);
      final vsCopy = channelMb == null || entry.key == 'channel_buffer'
          ? '—'
          : '${(mb / channelMb).toStringAsFixed(1)}× bandwidth';
      out.writeln('| ${c['label']} | ${mb.toStringAsFixed(0)} MB/s '
          '| $payloadMiB MiB | $vsCopy |');
    }
  }

  // ── Workload equivalence proof ─────────────────────────────────────────────
  final verification = report['verification'] as Map<String, dynamic>?;
  if (verification != null) {
    final agree = verification['allTiersAgree'] == true;
    final tiers = verification['tiersVerified'];
    out
      ..writeln()
      ..writeln('### Workload verification')
      ..writeln()
      ..writeln(agree
          ? '✅ All $tiers bridge tiers returned the **identical** 64-bit '
              'FNV-1a hash for the same payload '
              '(`${verification['workload']}`) — the `+ FNV-1a work` rows '
              'above compare the exact same computation; only the bridge '
              'differs.'
          : '❌ Bridge tiers disagreed on the workload hash — the comparison '
              'is INVALID: `$verification`');
  }

  // ── Practical interpretation — what the numbers mean for real apps ────────
  out
    ..writeln()
    ..writeln('### What this means in practice')
    ..writeln();

  final leaf = medianOf(cases, 'nitro_leaf_add');
  final cpp = medianOf(cases, 'nitro_cpp_add');
  final asyncRec = medianOf(cases, 'nitro_async_record');
  final struct = medianOf(cases, 'nitro_struct_roundtrip');

  if (cpp != null && channel != null) {
    out.writeln(
        '- **Hot loops:** one frame at 60 fps fits ~${callsPerFrame(cpp)} '
        'Nitro calls vs ~${callsPerFrame(channel)} MethodChannel calls — '
        '${(channel / cpp).toStringAsFixed(0)}× more headroom for '
        'per-frame native work (sensors, codecs, game state, tickers).');
  }
  if (leaf != null && rawFfi != null) {
    out.writeln(
        '- **Bridge tax:** Nitro adds ${(leaf - rawFfi).toStringAsFixed(3)} µs '
        'over a bare `dart:ffi` leaf call — that is the entire cost of '
        'codegen safety (instance registry, error slot, typed marshalling).');
  }
  if (asyncRec != null && channel != null) {
    final ratio = asyncRec / channel;
    out.writeln(
        '- **Sync vs async:** `@nitroAsync` (${asyncRec.toStringAsFixed(1)} µs) '
        'costs about ${ratio.toStringAsFixed(1)}× a MethodChannel round-trip — '
        'the isolate hop dominates. Prefer sync calls or `@NitroNativeAsync` '
        'for latency-critical paths; reserve `@nitroAsync` for work that '
        'genuinely blocks.');
  }
  if (struct != null && channel != null) {
    out.writeln(
        '- **Structured data:** a zero-copy struct round-trip '
        '(${struct.toStringAsFixed(3)} µs) stays '
        '${(channel / struct).toStringAsFixed(0)}× faster than a channel call '
        'that would have to serialize the same fields.');
  }
  final ffiHash = medianOf(cases, 'raw_ffi_hash');
  final nitroHash = medianOf(cases, 'nitro_cpp_hash');
  final chanHash = medianOf(cases, 'channel_hash');
  if (ffiHash != null && nitroHash != null && chanHash != null) {
    out.writeln(
        '- **Real work, same algorithm:** running the verified FNV-1a '
        'workload, raw FFI takes ${ffiHash.toStringAsFixed(1)} µs, Nitro '
        '${nitroHash.toStringAsFixed(1)} µs '
        '(+${(nitroHash - ffiHash).toStringAsFixed(2)} µs bridge cost), and '
        'MethodChannel ${chanHash.toStringAsFixed(1)} µs '
        '(+${(chanHash - ffiHash).toStringAsFixed(1)} µs). The channel tax '
        'persists even when calls do real work — it is overhead, not '
        'amortization.');
  }
  final pinnedMb =
      ((cases['nitro_buffer_pinned'] as Map<String, dynamic>?)?['mbPerSec'] as num?)
          ?.toDouble();
  final copyMb =
      ((cases['channel_buffer'] as Map<String, dynamic>?)?['mbPerSec'] as num?)
          ?.toDouble();
  final rawCopyMb =
      ((cases['raw_ffi_buffer'] as Map<String, dynamic>?)?['mbPerSec'] as num?)
          ?.toDouble();
  if (pinnedMb != null && copyMb != null) {
    final rawFfiClause = rawCopyMb == null
        ? ''
        : ' Hand-written FFI with a manual arena copy reaches '
            '${rawCopyMb.toStringAsFixed(0)} MB/s — Nitro is '
            '${(pinnedMb / rawCopyMb).toStringAsFixed(1)}× that without the '
            'unsafe boilerplate, because pinning skips the copy entirely.';
    out.writeln(
        '- **Large payloads:** MethodChannel copies every byte '
        '(${copyMb.toStringAsFixed(0)} MB/s); Nitro pins the Dart buffer for '
        'zero-copy access (${pinnedMb.toStringAsFixed(0)} MB/s — '
        '${(pinnedMb / copyMb).toStringAsFixed(1)}× the bandwidth).'
        '$rawFfiClause For camera/audio-sized frames the channel copy alone '
        'can blow a frame budget.');
  }

  // ── Baseline drift ─────────────────────────────────────────────────────────
  if (baseCases != null) {
    final drifts = <String>[];
    for (final entry in cases.entries) {
      final c = entry.value as Map<String, dynamic>;
      if (c['kind'] != 'latency' || c['skipped'] != null) continue;
      final median = (c['medianUs'] as num).toDouble();
      final base = medianOf(baseCases, entry.key);
      if (base == null || base == 0) continue;
      final pct = (median - base) / base * 100;
      if (pct.abs() >= 10) {
        drifts.add('`${entry.key}` ${pct > 0 ? 'slower' : 'faster'} by '
            '${pct.abs().toStringAsFixed(0)}% '
            '(${base.toStringAsFixed(3)} → ${median.toStringAsFixed(3)} µs)');
      }
    }
    out
      ..writeln()
      ..writeln('### Baseline drift')
      ..writeln();
    if (drifts.isEmpty) {
      out.writeln('All latency cases within ±10% of the recorded '
          '$platform baseline.');
    } else {
      out.writeln('Cases drifting ≥10% vs the recorded baseline '
          '(shared-runner noise or a real change — check the trend '
          'across runs):');
      for (final d in drifts) {
        out.writeln('- $d');
      }
    }
  }

  // ── Cross-platform matrix ──────────────────────────────────────────────────
  if (compareDir != null && Directory(compareDir).existsSync()) {
    final others = <String, Map<String, dynamic>>{}; // platform → cases
    for (final f in Directory(compareDir).listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final r = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final p = r['platform'] as String?;
        final c = r['cases'] as Map<String, dynamic>?;
        if (p != null && c != null) others[p] = c;
      } catch (_) {}
    }
    others[platform] = cases; // current run wins for its own platform
    if (others.length > 1) {
      final platforms = others.keys.toList()..sort();
      final caseIds = <String>{
        for (final c in others.values) ...c.keys,
      }.where((id) {
        // Latency cases only — throughput MB/s columns don't align well.
        return others.values.any((c) =>
            (c[id] as Map<String, dynamic>?)?['kind'] == 'latency');
      });
      out
        ..writeln()
        ..writeln('### Cross-platform comparison (median µs)')
        ..writeln()
        ..writeln('| Case | ${platforms.join(' | ')} |')
        ..writeln('|---|${'---|' * platforms.length}');
      for (final id in caseIds) {
        final label = (others.values
            .map((c) => (c[id] as Map<String, dynamic>?)?['label'] as String?)
            .firstWhere((l) => l != null, orElse: () => id))!;
        final row = platforms.map((p) {
          final m = medianOf(others[p]!, id);
          return m == null ? '—' : m.toStringAsFixed(3);
        }).join(' | ');
        out.writeln('| $label | $row |');
      }
      out.writeln();
      out.writeln('_Numbers from the most recent archived run per platform '
          '— different hardware, compare tiers within a column, not across._');
    }
  }

  stdout.write(out);

  final reportJson = const JsonEncoder.withIndent('  ').convert(report);
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
