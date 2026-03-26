import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/benchmark_bridge.dart';
import '../models/benchmark_history.dart';

class BenchmarkHistory extends StatelessWidget {
  final List<BenchmarkHistoryEntry> history;

  const BenchmarkHistory({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(Icons.history_rounded, size: 48, color: Colors.grey),
              SizedBox(height: 12),
              Text('No history yet.', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(
            'Run History',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        const SizedBox(height: 12),
        ...history.reversed.map((entry) => _buildEntry(context, entry)),
      ],
    );
  }

  Widget _buildEntry(BuildContext context, BenchmarkHistoryEntry entry) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: ExpansionTile(
        title: Text(
          '${entry.category} (${entry.iterations} Iterations)',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: Row(
          children: [
            Text(
              DateFormat('HH:mm:ss').format(entry.timestamp),
              style: TextStyle(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withAlpha(150),
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: entry.winner.color.withAlpha(40),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: entry.winner.color.withAlpha(100)),
              ),
              child: Text(
                'Winner: ${entry.winner.label}',
                style: TextStyle(
                  color: entry.winner.color,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: entry.avgResults.entries.map((res) {
                final isWinner = res.key == entry.winner;
                final min = entry.minResults[res.key]!;
                final max = entry.maxResults[res.key]!;
                
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: res.key.color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                res.key.label,
                                style: TextStyle(
                                  fontWeight: isWinner
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '${res.value.toStringAsFixed(3)} µs/avg',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              color: isWinner ? Colors.amber : Colors.grey[400],
                              fontWeight: isWinner
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 16, top: 2),
                        child: Text(
                          'Range: ${min.toStringAsFixed(3)} - ${max.toStringAsFixed(3)} µs',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey[600],
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
