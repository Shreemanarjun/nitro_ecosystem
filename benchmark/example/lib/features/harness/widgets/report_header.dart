import 'package:flutter/material.dart';

import '../../../harness/bench_harness.dart';

/// Device / platform / build-mode banner plus the cross-tier verification
/// badge — the "this comparison is trustworthy" summary for a report.
class ReportHeader extends StatelessWidget {
  const ReportHeader({super.key, required this.report, required this.elapsed});

  final BenchReport report;
  final String elapsed;

  @override
  Widget build(BuildContext context) {
    final d = report.device;
    final model = (d['model'] ?? d['name'] ?? '?').toString();
    final os = (d['socOs'] ?? d['os'] ?? '').toString();
    final v = report.verification ?? const {};
    final fnvOk = v['allTiersAgree'] == true;
    final sieveOk = v['sieveTiersAgree'] == true;
    final allOk = fnvOk && sieveOk;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.cyan.withAlpha(30), Colors.transparent],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.cyan.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory, size: 18, color: Colors.cyan),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  model,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _pill(
                '${report.platform} · ${report.buildMode}',
                report.buildMode == 'release'
                    ? Colors.green
                    : (report.buildMode == 'profile'
                          ? Colors.amber
                          : Colors.redAccent),
              ),
            ],
          ),
          if (os.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(
                os,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                allOk ? Icons.verified : Icons.warning_amber,
                size: 15,
                color: allOk ? Colors.greenAccent : Colors.orangeAccent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  allOk
                      ? 'All tiers returned identical results for both workloads — comparison is valid.'
                      : 'Tier results disagree — comparison may not measure identical work.',
                  style: TextStyle(
                    fontSize: 11,
                    color: allOk ? Colors.greenAccent : Colors.orangeAccent,
                  ),
                ),
              ),
              if (elapsed.isNotEmpty)
                Text(
                  elapsed,
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: c.withAlpha(40),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: c.withAlpha(110)),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10.5, color: c, fontWeight: FontWeight.w600),
    ),
  );
}
