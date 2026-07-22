import 'package:flutter/material.dart';

class RunsSelector extends StatelessWidget {
  final int count;
  final ValueChanged<int> onChanged;

  const RunsSelector({super.key, required this.count, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Number of Runs',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withAlpha(50),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$count runs',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: count.toDouble(),
          min: 1,
          max: 1000,
          divisions: 999,
          label: count.toString(),
          onChanged: (val) => onChanged(val.toInt()),
        ),
        const Text(
          'Runs the benchmark multiple times and calculates the average to reduce noise.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }
}
