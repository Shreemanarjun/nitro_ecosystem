import 'dart:io';
import 'package:args/command_runner.dart';
import '../ui.dart';

class GenerateCommand extends Command {
  @override
  final String name = 'generate';

  @override
  final String description =
      'Runs the Nitrogen code generator (build_runner) with live output.';

  @override
  Future<void> run() async {
    // Generate streams build_runner output directly to the terminal — we keep
    // this as plain stdout so the verbose output (file paths, errors) persists
    // in the scrollback buffer. We use the shared ANSI helpers for the
    // header/footer only.
    if (!File('pubspec.yaml').existsSync()) {
      stderr.writeln(red('❌ No pubspec.yaml found.'));
      exit(1);
    }

    stdout.writeln('');
    stdout.writeln(boldCyan('  ╔══════════════════════════╗'));
    stdout.writeln(boldCyan('  ║  nitrogen generate       ║'));
    stdout.writeln(boldCyan('  ╚══════════════════════════╝'));
    stdout.writeln('');

    // ── pub get ─────────────────────────────────────────────────────────────
    stdout.writeln(cyan('  › flutter pub get …'));
    var exitCode = await runStreaming('flutter', ['pub', 'get']);
    if (exitCode != 0) {
      stderr.writeln(red('  ✘  flutter pub get failed (exit $exitCode)'));
      exit(exitCode);
    }
    stdout.writeln('');

    // ── build_runner ─────────────────────────────────────────────────────────
    stdout.writeln(cyan('  › build_runner build …'));
    stdout.writeln('');
    exitCode = await runStreaming('flutter', [
      'pub', 'run', 'build_runner', 'build', '--delete-conflicting-outputs',
    ]);

    stdout.writeln('');
    if (exitCode != 0) {
      stderr.writeln(boldRed('  ✘  build_runner failed (exit $exitCode)'));
      stderr.writeln(gray('     Check the output above for details.'));
      exit(exitCode);
    }

    stdout.writeln(boldGreen('  ✨ Generation complete!'));
    stdout.writeln(gray('     Run nitrogen link to wire bridges into the build system.'));
    stdout.writeln('');
  }
}
