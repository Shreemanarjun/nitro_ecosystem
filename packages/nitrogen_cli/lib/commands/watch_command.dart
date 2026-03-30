import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:watcher/watcher.dart';
import 'package:nitrogen_cli/ui.dart';
import 'package:nitrogen_cli/utils.dart';

class WatchCommand extends Command {
  @override
  final name = 'watch';
  @override
  final description = 'Run the Nitro generator in watch mode.';

  @override
  void run() async {
    final root = findNitroProjectRoot();
    if (root == null) {
      stderr.writeln(red('No pubspec.yaml found containing a Nitrogen dependency.'));
      exit(1);
    }

    // Attempt to parse project info for name

    stdout.writeln(cyan('\n⚡ Starting Nitrogen Watch Mode (build_runner watch)...'));
    stdout.writeln(dim('Project: ${root.path}\n'));

    // 1. Initial link to make sure everything is wired
    stdout.writeln(gray('  - Performing initial bridge sync...'));
    syncBridgeFiles(root.path);

    // 2. Start the watcher for .native.dart file additions/removals
    // (This acts as a backup, but build_runner handles the generation itself)
    final specWatcher = DirectoryWatcher(root.path);
    specWatcher.events.listen((event) {
      // Just logging or reacting to file-system level changes
    });

    // 3. Run build_runner watch and pipe output
    final stream = streamProcess('flutter', [
      'pub',
      'run',
      'build_runner',
      'watch',
      '--delete-conflicting-outputs',
    ], workingDirectory: root.path);

    await for (final line in stream) {
      stdout.writeln(line);

      // When build_runner says it finished a build, sync the bridge files to iOS
      if (line.contains('Succeeded after')) {
        stdout.writeln(green('  ✨ Generation complete. Syncing bridge files to iOS...'));
        try {
          syncBridgeFiles(root.path);
          stdout.writeln(dim('  ✔ Sync successful.\n'));
        } catch (e) {
          stdout.writeln(red('  ✘ Sync failed: $e'));
        }
      }

      if (line.contains('Failed after')) {
        stdout.writeln(red('  ✘ Generation failed. Fix the errors to continue syncing.'));
      }
    }
  }
}
