import 'package:flutter/material.dart';

/// One tier's row in a category: colored label, a bar whose length is
/// proportional to the value (normalized to the category max), the value in
/// its unit, and a "×" comparison against the category baseline.
class ComparisonBar extends StatelessWidget {
  const ComparisonBar({
    super.key,
    required this.label,
    required this.color,
    required this.value,
    required this.unit,
    required this.fraction,
    required this.ratioText,
    this.isBaseline = false,
    this.isBest = false,
    this.p95,
  });

  /// Tier display name.
  final String label;
  final Color color;

  /// The value in [unit] (µs or MB/s), or null when skipped.
  final double? value;
  final String unit;

  /// Bar length in 0..1 relative to the category's largest bar.
  final double fraction;

  /// e.g. "1.0× (baseline)", "17.9× slower", "3.4× faster".
  final String ratioText;
  final bool isBaseline;
  final bool isBest;
  final double? p95;

  @override
  Widget build(BuildContext context) {
    final skipped = value == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: isBest ? FontWeight.bold : FontWeight.w500,
                    color: isBest ? color : Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isBest)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(Icons.emoji_events, size: 13, color: Colors.amber),
                ),
              Text(
                skipped
                    ? 'n/a'
                    : '${_fmt(value!)} $unit',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  color: Colors.amberAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    children: [
                      Container(height: 8, color: Colors.white10),
                      FractionallySizedBox(
                        widthFactor: skipped ? 0 : fraction.clamp(0.0, 1.0),
                        child: Container(
                          height: 8,
                          decoration: BoxDecoration(
                            color: color.withAlpha(isBaseline ? 160 : 220),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 96,
                child: Text(
                  ratioText,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: isBaseline ? Colors.white54 : Colors.white70,
                  ),
                ),
              ),
            ],
          ),
          if (p95 != null && !skipped)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                'p95 ${_fmt(p95!)} $unit',
                style: const TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ),
        ],
      ),
    );
  }

  static String _fmt(double v) {
    if (v >= 1000) return v.toStringAsFixed(0);
    if (v >= 100) return v.toStringAsFixed(1);
    if (v >= 1) return v.toStringAsFixed(2);
    return v.toStringAsFixed(3);
  }
}
