import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import '../ui.dart';

class GenerateCommand extends Command {
  @override
  final String name = 'generate';

  @override
  final String description =
      'Runs the Nitrogen code generator (build_runner) with live output.';

  /// Executes the generation logic and returns the exit code.
  /// Does NOT call exit().
  Future<int> execute() async {
    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      stderr.writeln(red(
          '❌ No Nitro project found in . or its subdirectories (must have nitro dependency in pubspec.yaml).'));
      return 1;
    }

    // If we're not in the project root, let the user know we've found it
    if (projectDir.path != Directory.current.path) {
      stdout.writeln(gray('  📂 Found project in: ${projectDir.path}'));
    }

    stdout.writeln('');
    stdout.writeln(boldCyan('  ╔══════════════════════════╗'));
    stdout.writeln(boldCyan('  ║  nitrogen generate       ║'));
    stdout.writeln(boldCyan('  ╚══════════════════════════╝'));
    stdout.writeln('');

    // ── pub get ─────────────────────────────────────────────────────────────
    stdout.writeln(cyan('  › flutter pub get …'));
    var exitCode = await runStreaming('flutter', ['pub', 'get'],
        workingDirectory: projectDir.path);
    if (exitCode != 0) {
      stderr.writeln(red('  ✘  flutter pub get failed (exit $exitCode)'));
      return exitCode;
    }
    stdout.writeln('');

    // ── build_runner ─────────────────────────────────────────────────────────
    stdout.writeln(cyan('  › build_runner build …'));
    stdout.writeln('');
    exitCode = await runStreaming(
      'flutter',
      [
        'pub',
        'run',
        'build_runner',
        'build',
        '--delete-conflicting-outputs',
      ],
      workingDirectory: projectDir.path,
    );

    stdout.writeln('');
    if (exitCode != 0) {
      stderr.writeln(boldRed('  ✘  build_runner failed (exit $exitCode)'));
      stderr.writeln(gray('     Check the output above for details.'));
      return exitCode;
    }

    // ── Sync generated Swift bridges to ios/Classes/ ─────────────────────────
    _syncSwiftToIosClasses(projectDir.path);

    // ── pod install ──────────────────────────────────────────────────────────
    final podfileDirs = _findPodfileDirs(projectDir.path);
    for (final dir in podfileDirs) {
      stdout.writeln(cyan(
          '  › pod install (${p.relative(dir, from: projectDir.path)}) …'));
      final podExitCode = await runStreaming(
        'pod',
        ['install'],
        workingDirectory: dir,
      );
      if (podExitCode != 0) {
        stderr.writeln(red(
            '  ⚠  pod install failed in $dir (exit $podExitCode) — continuing'));
      }
    }

    stdout.writeln('');
    stdout.writeln(boldGreen('  ✨ Generation complete!'));
    stdout.writeln(
        gray('     Run nitrogen link to wire bridges into the build system.'));
    stdout.writeln('');
    return 0;
  }

  @override
  Future<void> run() async {
    final exitCode = await execute();
    if (exitCode != 0) exit(exitCode);
  }

  /// Copies every *.bridge.g.swift from lib/**/generated/swift/ into
  /// ios/Classes/ so CocoaPods always picks up the freshly generated bridges.
  void _syncSwiftToIosClasses(String projectRoot) {
    final iosClasses = Directory(p.join(projectRoot, 'ios', 'Classes'));
    if (!iosClasses.existsSync()) return;

    final libDir = Directory(p.join(projectRoot, 'lib'));
    if (!libDir.existsSync()) return;

    final bridgeFiles = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.bridge.g.swift'));

    for (final src in bridgeFiles) {
      final dest = File(p.join(iosClasses.path, p.basename(src.path)));
      src.copySync(dest.path);
    }
  }

  /// Returns directories containing a Podfile, searching common locations:
  /// <root>/ios/, <root>/example/ios/, and any direct child */ios/.
  List<String> _findPodfileDirs(String projectRoot) {
    final candidates = [
      p.join(projectRoot, 'ios'),
      p.join(projectRoot, 'example', 'ios'),
    ];

    // Also check any direct subdirectory that has an ios/ with a Podfile.
    try {
      for (final entity in Directory(projectRoot).listSync()) {
        if (entity is Directory) {
          candidates.add(p.join(entity.path, 'ios'));
        }
      }
    } catch (_) {}

    return candidates
        .where((dir) => File(p.join(dir, 'Podfile')).existsSync())
        .toList();
  }
}
