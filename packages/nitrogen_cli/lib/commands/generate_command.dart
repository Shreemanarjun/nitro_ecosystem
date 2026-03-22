import 'dart:io';
import 'package:args/command_runner.dart';
import '../ui.dart';

class GenerateCommand extends Command {
  @override
  final String name = 'generate';

  @override
  final String description =
      'Runs the Nitrogen code generator (build_runner) and streams output in real time.';

  @override
  Future<void> run() async {
    printBanner('nitrogen generate');

    // Ensure pubspec is present
    if (!File('pubspec.yaml').existsSync()) {
      printError('No pubspec.yaml found.',
          hint: 'Run nitrogen generate from the root of a Flutter plugin.');
      exit(1);
    }

    printSection('Running flutter pub get');
    var exitCode = await runStreaming('flutter', ['pub', 'get']);
    if (exitCode != 0) {
      printError('flutter pub get failed (exit $exitCode)');
      exit(exitCode);
    }

    printSection('Running build_runner build');
    exitCode = await runStreaming('flutter', [
      'pub',
      'run',
      'build_runner',
      'build',
      '--delete-conflicting-outputs',
    ]);

    if (exitCode != 0) {
      printError('build_runner failed (exit $exitCode)',
          hint: 'Check the output above for details.');
      exit(exitCode);
    }

    stdout.writeln('');
    stdout.writeln(bold(green('  ✨ Generation complete!')));
    stdout.writeln(dim('     Run nitrogen link to wire generated bridges into the build system.'));
    stdout.writeln('');
  }
}
