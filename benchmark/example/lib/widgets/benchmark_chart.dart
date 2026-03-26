import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/benchmark_bridge.dart';

class BenchmarkChart extends StatelessWidget {
  final String title;
  final String subtitle;
  final Map<BridgeType, List<FlSpot>> spotsMap;

  const BenchmarkChart({
    super.key,
    required this.title,
    required this.subtitle,
    required this.spotsMap,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = spotsMap.values.any((s) => s.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        AspectRatio(
          aspectRatio: 1.7,
          child: Container(
            padding: const EdgeInsets.only(right: 16, top: 12, bottom: 0),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withAlpha(50),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Theme.of(context).colorScheme.outline.withAlpha(50),
              ),
            ),
            child: hasData
                ? LineChart(_createChartData(context))
                : const Center(
                    child: Text(
                      'No data. Run a benchmark.',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        _Legend(context: context),
      ],
    );
  }

  LineChartData _createChartData(BuildContext context) {
    return LineChartData(
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        getDrawingHorizontalLine: (value) => FlLine(
          color: Theme.of(context).colorScheme.outline.withAlpha(30),
          strokeWidth: 1,
        ),
      ),
      titlesData: FlTitlesData(
        show: true,
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 30,
            interval: 500,
            getTitlesWidget: (value, meta) {
              return SideTitleWidget(
                meta: meta,
                child: Text(
                  value.toInt().toString(),
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.secondary.withAlpha(150),
                    fontSize: 10,
                  ),
                ),
              );
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            getTitlesWidget: (value, meta) {
              return SideTitleWidget(
                meta: meta,
                child: Text(
                  value.toInt().toString(),
                  style: TextStyle(
                    color: Theme.of(
                      context,
                    ).colorScheme.secondary.withAlpha(150),
                    fontSize: 10,
                  ),
                ),
              );
            },
          ),
        ),
      ),
      borderData: FlBorderData(show: false),
      lineBarsData: BridgeType.values.map((bridge) {
        return _createLine(spotsMap[bridge]!, bridge.color);
      }).toList(),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (spot) =>
              Theme.of(context).colorScheme.tertiaryContainer.withAlpha(200),
          getTooltipItems: (touchedSpots) {
            return touchedSpots.map((spot) {
              return LineTooltipItem(
                '${spot.y.toStringAsFixed(2)} µs',
                const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              );
            }).toList();
          },
        ),
      ),
    );
  }

  LineChartBarData _createLine(List<FlSpot> spots, Color color) {
    return LineChartBarData(
      spots: spots,
      isCurved: true,
      color: color,
      barWidth: 3,
      isStrokeCapRound: true,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withAlpha(50), color.withAlpha(0)],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final BuildContext context;
  const _Legend({required this.context});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: BridgeType.values.map((bridge) => _legendItem(bridge)).toList(),
    );
  }

  Widget _legendItem(BridgeType bridge) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: bridge.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: bridge.color.withAlpha(100),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          bridge.label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
