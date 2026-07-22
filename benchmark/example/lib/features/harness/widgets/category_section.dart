import 'package:flutter/material.dart';

import '../../../harness/bench_harness.dart';
import '../models/bench_category.dart';
import 'comparison_bar.dart';

/// Renders one [BenchCategory]: a titled card of [ComparisonBar]s, each tier
/// normalized against the category's slowest/highest bar and annotated with a
/// "×" ratio versus the category baseline.
class CategorySection extends StatelessWidget {
  const CategorySection({
    super.key,
    required this.category,
    required this.report,
  });

  final BenchCategory category;
  final BenchReport report;

  @override
  Widget build(BuildContext context) {
    // Resolve (id -> result) preserving the category's declared order.
    final rows = <(String, BenchResult?)>[
      for (final id in category.caseIds) (id, report.caseById(id)),
    ];

    final values = <String, double?>{
      for (final (id, r) in rows) id: r == null ? null : category.valueOf(r),
    };
    final present = values.values.whereType<double>().toList();
    if (present.isEmpty) return const SizedBox.shrink();

    final maxVal = present.reduce((a, b) => a > b ? a : b);
    final baseline = values[category.baselineId];
    final best = category.higherIsBetter
        ? present.reduce((a, b) => a > b ? a : b)
        : present.reduce((a, b) => a < b ? a : b);

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: Colors.grey.shade900.withAlpha(120),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            category.title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5),
          ),
          const SizedBox(height: 2),
          Text(
            category.subtitle,
            style: const TextStyle(fontSize: 11.5, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          for (final (id, r) in rows)
            ComparisonBar(
              label: r?.label ?? id,
              color: colorForCaseId(id),
              value: values[id],
              unit: category.unit,
              fraction: values[id] == null || maxVal == 0
                  ? 0
                  : values[id]! / maxVal,
              isBaseline: id == category.baselineId,
              isBest: values[id] != null && values[id] == best,
              p95: category.higherIsBetter ? null : r?.stats?.p95Us,
              ratioText: _ratio(values[id], baseline, id),
            ),
        ],
      ),
    );
  }

  String _ratio(double? value, double? baseline, String id) {
    if (value == null) return '';
    if (id == category.baselineId) return '1.0× baseline';
    if (baseline == null || baseline == 0) return '';
    final r = value / baseline;
    if (category.higherIsBetter) {
      return '${r.toStringAsFixed(r >= 10 ? 0 : 1)}× FFI';
    }
    if (r > 1.02) return '${r.toStringAsFixed(r >= 10 ? 0 : 1)}× slower';
    if (r < 0.98) return '${(1 / r).toStringAsFixed(1)}× faster';
    return '≈ baseline';
  }
}
