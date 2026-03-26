import 'benchmark_bridge.dart';

class BenchmarkHistoryEntry {
  final DateTime timestamp;
  final String category;
  final int iterations;
  final BridgeType winner;
  final double winnerAvgUs;
  final Map<BridgeType, double> avgResults;
  final Map<BridgeType, double> minResults;
  final Map<BridgeType, double> maxResults;

  BenchmarkHistoryEntry({
    required this.timestamp,
    required this.category,
    required this.iterations,
    required this.winner,
    required this.winnerAvgUs,
    required this.avgResults,
    required this.minResults,
    required this.maxResults,
  });
}
