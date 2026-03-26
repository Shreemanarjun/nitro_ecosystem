import 'package:flutter/material.dart';

class BenchmarkControls extends StatelessWidget {
  final bool isRunning;
  final VoidCallback onRunSequential;
  final VoidCallback onRunSimultaneous;
  final VoidCallback onRunOneOff;

  const BenchmarkControls({
    super.key,
    required this.isRunning,
    required this.onRunSequential,
    required this.onRunSimultaneous,
    required this.onRunOneOff,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shadowColor: Theme.of(context).colorScheme.shadow.withAlpha(50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.surface,
              Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withAlpha(100),
            ],
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.bolt, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                const Text(
                  'Performance Controls',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildButton(
              context: context,
              label: 'SEQUENTIAL BENCHMARK',
              icon: Icons.play_arrow_rounded,
              onPressed: isRunning ? null : onRunSequential,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            _buildButton(
              context: context,
              label: 'SIMULTANEOUS BENCHMARK',
              icon: Icons.rocket_launch_rounded,
              onPressed: isRunning ? null : onRunSimultaneous,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            _buildButton(
              context: context,
              label: 'ONE-OFF TEST',
              icon: Icons.flash_on_rounded,
              onPressed: isRunning ? null : onRunOneOff,
              color: Colors.amber,
              outline: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton({
    required BuildContext context,
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    required Color color,
    bool outline = false,
  }) {
    if (outline) {
      return SizedBox(
        width: double.infinity,
        height: 50,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          label: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: color,
            side: BorderSide(color: color.withAlpha(200), width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20, color: Colors.white),
        label: Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
            color: Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
        ),
      ),
    );
  }
}
