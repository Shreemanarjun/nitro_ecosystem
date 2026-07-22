import 'package:flutter/material.dart';

/// The customizable-runs control: two segmented steppers (iterations per
/// sample, and number of samples) plus the Run button and a live estimate.
class ConfigPanel extends StatelessWidget {
  const ConfigPanel({
    super.key,
    required this.iterationChoices,
    required this.iterationsIndex,
    required this.onIterations,
    required this.sampleChoices,
    required this.samplesIndex,
    required this.onSamples,
    required this.isRunning,
    required this.onRun,
    required this.currentCaseId,
  });

  final List<int> iterationChoices;
  final int iterationsIndex;
  final ValueChanged<int> onIterations;

  final List<int> sampleChoices;
  final int samplesIndex;
  final ValueChanged<int> onSamples;

  final bool isRunning;
  final VoidCallback onRun;
  final String? currentCaseId;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Stepper(
            label: 'Iterations / sample',
            hint: 'tight-loop count for sub-µs cases',
            choices: iterationChoices,
            selectedIndex: iterationsIndex,
            format: _compact,
            enabled: !isRunning,
            onChanged: onIterations,
          ),
          const SizedBox(height: 14),
          _Stepper(
            label: 'Samples (runs)',
            hint: 'median across independent samples = headline',
            choices: sampleChoices,
            selectedIndex: samplesIndex,
            format: (v) => '$v',
            enabled: !isRunning,
            onChanged: onSamples,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isRunning ? null : onRun,
              icon: isRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(
                isRunning
                    ? 'Running${currentCaseId != null ? '  ·  $currentCaseId' : '…'}'
                    : 'Run full comparison',
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _compact(int v) =>
      v >= 1000 ? '${(v / 1000).toStringAsFixed(v % 1000 == 0 ? 0 : 1)}k' : '$v';
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.hint,
    required this.choices,
    required this.selectedIndex,
    required this.format,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final List<int> choices;
  final int selectedIndex;
  final String Function(int) format;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hint,
                style: const TextStyle(fontSize: 11, color: Colors.white38),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: List.generate(choices.length, (i) {
            final sel = i == selectedIndex;
            return ChoiceChip(
              label: Text(format(choices[i])),
              selected: sel,
              onSelected: enabled ? (_) => onChanged(i) : null,
              labelStyle: TextStyle(
                fontSize: 12,
                fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                color: sel ? Colors.black : Colors.white70,
              ),
              selectedColor: Colors.cyan,
              backgroundColor: Colors.white10,
              showCheckmark: false,
            );
          }),
        ),
      ],
    );
  }
}
