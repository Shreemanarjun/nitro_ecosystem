import 'package:flutter/material.dart';

class StatusCard extends StatelessWidget {
  final bool isRunning;
  final String status;
  final int? currentIteration;
  final int? totalIterations;
  final String? bridgeLabel;
  final int? currentRun;
  final int? totalRuns;

  const StatusCard({
    super.key,
    required this.isRunning,
    required this.status,
    this.currentIteration,
    this.totalIterations,
    this.bridgeLabel,
    this.currentRun,
    this.totalRuns,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withAlpha(50),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withAlpha(100),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          if (isRunning)
            const Padding(
              padding: EdgeInsets.only(right: 16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isRunning && currentRun != null && totalRuns != null
                          ? 'RUN $currentRun / $totalRuns'
                          : 'STATUS',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    if (isRunning &&
                        currentIteration != null &&
                        totalIterations != null)
                      Text(
                        '${((currentIteration! / totalIterations!) * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  status,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                if (isRunning && bridgeLabel != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.secondary.withAlpha(40),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          bridgeLabel!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.secondary,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LinearProgressIndicator(
                          value:
                              (currentIteration ?? 0) / (totalIterations ?? 1),
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surface,
                          borderRadius: BorderRadius.circular(10),
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$currentIteration / $totalIterations',
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
