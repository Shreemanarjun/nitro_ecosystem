import 'dart:io';
import 'dart:math' as math;
import 'package:nocterm/nocterm.dart';

/// A fun animation showing a rocket blasting off at "FFI speed".
///
/// Uses nocterm's [AnimationController] and [AnimatedBuilder] to animate
/// a racing comparison between Method Channels and Nitro FFI.
class RocketAnimation extends StatefulComponent {
  const RocketAnimation({super.key});

  @override
  State<RocketAnimation> createState() => _RocketAnimationState();
}

class _RocketAnimationState extends State<RocketAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // A 3.5-second animation divided into two phases: slow and fast.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _formatOps(int ops) {
    final str = ops.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < str.length; i++) {
      if (i > 0 && (str.length - i) % 3 == 0) buffer.write(',');
      buffer.write(str[i]);
    }
    return '${buffer.toString().padLeft(9)} op/s';
  }

  /// Safely reads the terminal column count.
  static int _terminalColumns() {
    try {
      final cols = stdout.terminalColumns;
      return cols > 0 ? cols : 80;
    } catch (_) {
      return 80;
    }
  }

  @override
  Component build(BuildContext context) {
    // Determine target width
    final totalWidth = (_terminalColumns() - 45).clamp(20, 200).toDouble();
    // Track width = total - left label (~18) - right stats (~18)
    final trackWidth = totalWidth - 36.0;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // --- Method Channel (Slow & Clunky) ---
        final mcProgress = _controller.value;
        final mcX = (trackWidth * 0.25) * mcProgress;
        final mcPadding = mcX.round().clamp(0, trackWidth.toInt());
        
        final mcTrail = '·' * mcPadding;
        final mcSmoke = (mcProgress * 15).floor().isEven ? '☁️ ' : '💨';
        final mcText = '$mcTrail$mcSmoke🐌';
        
        // From README: Method channel ~107µs latency = ~9,300 ops/s
        final mcOps = (mcProgress * 9300).toInt();

        // --- Nitro FFI (Blazing Fast) ---
        var baseProgress = (_controller.value * 2.5).clamp(0.0, 1.0);
        final nitroProgress = math.pow(baseProgress, 4).toDouble();
        
        final nitroEndX = trackWidth - 10.0;
        final nitroX = nitroEndX * nitroProgress;
        final nitroPadding = nitroX.round().clamp(0, trackWidth.toInt());
        
        final isNitroDone = nitroProgress >= 1.0;
        final nitroEffect = isNitroDone ? '✨' : ((nitroProgress * 30).floor().isEven ? '🔥' : '⚡');
        
        final nitroTrail = '≡' * nitroPadding;
        final nitroText = '$nitroTrail$nitroEffect🚀';

        // From README: Nitro Unsafe Ptr ~1.5µs latency = ~660,000 ops/s
        final nitroOps = (nitroProgress * 660000).toInt();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TrackRow(
              label: 'Method Channel',
              labelColor: Colors.gray,
              trackText: mcText,
              trackColor: Colors.gray,
              trackWidth: trackWidth,
              statsText: _formatOps(mcOps),
            ),
            const SizedBox(height: 1),
            _TrackRow(
              label: 'Nitro FFI',
              labelColor: Colors.cyan,
              trackText: nitroText,
              trackColor: Colors.cyan,
              trackWidth: trackWidth,
              statsText: _formatOps(nitroOps),
            ),
          ],
        );
      },
    );
  }
}

class _TrackRow extends StatelessComponent {
  const _TrackRow({
    required this.label,
    required this.labelColor,
    required this.trackText,
    required this.trackColor,
    required this.trackWidth,
    required this.statsText,
  });

  final String label;
  final Color labelColor;
  final String trackText;
  final Color trackColor;
  final double trackWidth;
  final String statsText;

  @override
  Component build(BuildContext context) {
    final paddedLabel = label.padLeft(14);
    
    return Row(
      children: [
        Text(paddedLabel, style: TextStyle(color: labelColor, fontWeight: FontWeight.bold)),
        const Text(' ┆ ', style: TextStyle(color: Colors.brightBlack)),
        SizedBox(
          width: trackWidth,
          child: Text(
            trackText,
            style: TextStyle(color: trackColor, fontWeight: FontWeight.bold),
            overflow: TextOverflow.clip,
            maxLines: 1,
          ),
        ),
        const Text(' ┆ ', style: TextStyle(color: Colors.brightBlack)),
        Text(statsText, style: TextStyle(color: trackColor, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
