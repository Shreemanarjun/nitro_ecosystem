import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';
import 'package:nitrogen_cli/ui.dart';
import 'package:nitrogen_cli/utils.dart' show syncBridgeFiles, killBuildRunner;

class WatchCommand extends Command {
  WatchCommand() {
    argParser.addFlag(
      'no-ui',
      negatable: false,
      help: 'Plain-text headless output (no ANSI). Auto-enabled when stdout is not a TTY.',
    );
  }

  @override
  final name = 'watch';
  @override
  final description = 'Run the Nitro generator in watch mode.';

  bool get _headless => !stdout.hasTerminal || (argResults!['no-ui'] as bool);

  void _log(String msg) {
    if (_headless) {
      stdout.writeln('[nitro] $msg');
    } else {
      stdout.writeln(cyan('  › $msg'));
    }
  }

  @override
  void run() async {
    final root = findNitroProjectRoot();
    if (root == null) {
      if (_headless) {
        stderr.writeln('[nitro:error] No pubspec.yaml found containing a Nitrogen dependency.');
      } else {
        stderr.writeln(red('No pubspec.yaml found containing a Nitrogen dependency.'));
      }
      exit(1);
    }

    if (_headless) {
      stdout.writeln('[nitro] nitrogen watch');
      stdout.writeln('[nitro] project: ${root.path}');
    } else {
      stdout.writeln(cyan('\n⚡ Starting Nitrogen Watch Mode (build_runner watch)...'));
      stdout.writeln(dim('Project: ${root.path}\n'));
    }

    // 1. Kill any existing build_runner before starting a new one.
    //    build_runner uses a lock file — a second invocation hangs waiting
    //    for the lock. Stopping the old instance (and clearing the lock)
    //    lets the new watch process start immediately without hanging.
    _log('stopping any existing build_runner instance...');
    final killed = await killBuildRunner(workingDirectory: root.path);
    if (killed > 0) {
      _log('stopped previous build_runner.');
    } else {
      _log('no existing build_runner found.');
    }
    if (!_headless) stdout.writeln('');

    // Always clear the build cache so watch starts fresh — same as generate.
    // Without this a stale lock from a previously crashed process blocks startup.
    final buildCache = Directory(p.join(root.path, '.dart_tool', 'build'));
    if (buildCache.existsSync()) {
      try {
        buildCache.deleteSync(recursive: true);
      } catch (_) {}
    }

    // 2. Initial bridge sync to make sure everything is wired
    _log('performing initial bridge sync...');
    syncBridgeFiles(root.path);

    // 3. Start the watcher for .native.dart file additions/removals.
    // build_runner handles content changes, while this debounced backup keeps
    // platform link files in sync when specs are added, removed, or renamed.
    final specDebouncer = NativeSpecChangeDebouncer(
      delay: const Duration(milliseconds: 250),
      onReady: (paths) async {
        _log('native spec change detected — syncing bridge files...');
        try {
          syncBridgeFiles(root.path);
          _log('sync successful.');
        } catch (e) {
          if (_headless) {
            stderr.writeln('[nitro:error] sync failed: $e');
          } else {
            stdout.writeln(red('  ✘ Sync failed: $e'));
          }
        }
      },
      onError: (error, _) {
        if (_headless) {
          stderr.writeln('[nitro:error] sync failed: $error');
        } else {
          stdout.writeln(red('  ✘ Sync failed: $error'));
        }
      },
    );
    final specWatcher = DirectoryWatcher(root.path);
    specWatcher.events.listen((event) {
      specDebouncer.schedule(event.path);
    });

    // 4. Run build_runner watch and pipe output
    final stream = streamProcess('flutter', [
      'pub',
      'run',
      'build_runner',
      'watch',
      '--delete-conflicting-outputs',
    ], workingDirectory: root.path);

    await for (final line in stream) {
      stdout.writeln(_headless ? stripAnsi(line) : line);

      // When build_runner says it finished a build, sync the bridge files to iOS
      if (line.contains('Succeeded after')) {
        _log('generation complete — syncing bridge files...');
        try {
          syncBridgeFiles(root.path);
          _log('sync successful.');
        } catch (e) {
          if (_headless) {
            stderr.writeln('[nitro:error] sync failed: $e');
          } else {
            stdout.writeln(red('  ✘ Sync failed: $e'));
          }
        }
      }

      if (line.contains('Failed after')) {
        if (_headless) {
          stderr.writeln('[nitro:error] generation failed. Fix the errors to continue syncing.');
        } else {
          stdout.writeln(red('  ✘ Generation failed. Fix the errors to continue syncing.'));
        }
      }
    }
  }
}

class NativeSpecChangeDebouncer {
  NativeSpecChangeDebouncer({
    required this.delay,
    required this.onReady,
    this.onError,
  });

  final Duration delay;
  final FutureOr<void> Function(List<String> paths) onReady;
  final void Function(Object error, StackTrace stackTrace)? onError;

  final Set<String> _pendingPaths = <String>{};
  Timer? _timer;

  bool schedule(String path) {
    if (!path.endsWith('.native.dart')) return false;
    _pendingPaths.add(path);
    _timer?.cancel();
    _timer = Timer(delay, _flush);
    return true;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pendingPaths.clear();
  }

  void _flush() {
    final paths = _pendingPaths.toList()..sort();
    _pendingPaths.clear();
    _timer = null;
    Future<void>.sync(() => onReady(paths)).catchError((Object error, StackTrace stackTrace) {
      onError?.call(error, stackTrace);
    });
  }
}
