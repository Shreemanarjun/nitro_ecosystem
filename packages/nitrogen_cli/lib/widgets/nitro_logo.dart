import 'dart:io';
import 'package:nocterm/nocterm.dart' hide BoxFit;
import 'fitted_box.dart';

// Width of the full 6-line block-letter logo in terminal columns.
const _kLogoFullWidth = 42;

const _nitroLogoLines = [
  '███╗   ██╗██╗████████╗██████╗  ██████╗ ',
  '████╗  ██║██║╚══██╔══╝██╔══██╗██╔═══██╗',
  '██╔██╗ ██║██║   ██║   ██████╔╝██║   ██║',
  '██║╚██╗██║██║   ██║   ██╔══██╗██║   ██║',
  '██║ ╚████║██║   ██║   ██║  ██║╚██████╔╝',
  '╚═╝  ╚═══╝╚═╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝',
];

// Compact single-line fallback for very narrow terminals.
const _nitroLogoCompact = '⚡ N I T R O ⚡';

/// A responsive logo widget for Nitro.
///
/// The full block-letter art is wrapped in [FittedBox] with [BoxFit.scaleDown]
/// so it is never scaled up and never overflows its allocated area.
///
/// Width is read from [stdout.terminalColumns] at build time — safe because
/// nocterm already triggers a full rebuild whenever the terminal is resized,
/// so no SIGWINCH listener or polling timer is needed.
class NitroLogo extends StatelessComponent {
  const NitroLogo({required this.color, super.key});

  final Color color;

  /// Safely reads the terminal column count, defaulting to 80 when stdout
  /// is not a terminal (e.g. piped output).
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
    final style = TextStyle(color: color, fontWeight: FontWeight.bold);
    final int cols = _terminalColumns();

    if (cols < _kLogoFullWidth) {
      // Terminal too narrow — show compact single-line fallback.
      return Text(_nitroLogoCompact, style: style);
    }

    // Wrap the full logo in FittedBox so nocterm's layout pass constrains it
    // correctly without any intermediary LayoutBuilder rebuild quirks.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.center,
      child: Column(
        children: _nitroLogoLines
            .map((line) => Text(line, style: style))
            .toList(),
      ),
    );
  }
}
