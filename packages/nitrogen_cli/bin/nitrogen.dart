import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_unrouter/nocterm_unrouter.dart';

import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/clean_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/update_command.dart';
import 'package:nitrogen_cli/commands/open_command.dart';
import 'package:nitrogen_cli/commands/watch_command.dart';
import 'package:nitrogen_cli/commands/migrate_command.dart';
import 'package:nitrogen_cli/commands/spm_utils.dart';
import 'package:nitrogen_cli/version.dart';
import 'package:nitrogen_cli/models.dart';
import 'package:nitrogen_cli/routes.dart';
import 'package:nitrogen_cli/utils.dart';
import 'package:nitrogen_cli/widgets/dashboard.dart';
import 'package:nitrogen_cli/widgets/process_view.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    await _runTui();
    return;
  }

  if (args.length == 1 && (args[0] == '--version' || args[0] == '-v')) {
    stdout.writeln('nitrogen version: $activeVersion');
    return;
  }

  final runner = CommandRunner('nitrogen', 'Nitrogen FFI toolkit')
    ..addCommand(InitCommand())
    ..addCommand(GenerateCommand())
    ..addCommand(CleanCommand())
    ..addCommand(LinkCommand())
    ..addCommand(DoctorCommand())
    ..addCommand(MigrateCommand())
    ..addCommand(UpdateCommand())
    ..addCommand(OpenCommand())
    ..addCommand(WatchCommand());

  try {
    await runner.run(args);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}

Future<void> _runTui() async {
  await runApp(
    NoctermApp(
      title: 'Nitrogen Dashboard',
      child: Unrouter<NitroRoute>(
        routes: [
          route<RootRoute>(
            path: '/',
            parse: (_) => const RootRoute(),
            builder: (context, _) => const NitroDashboard(),
          ),

          // INIT
          route<CommandRoute>(
            path: '/init',
            parse: (_) => const CommandRoute(NitroCommand.init),
            builder: (context, _) => NitrogenInitApp(
              result: InitResult(),
              onExit: () => context.unrouterAs<NitroRoute>().go(const RootRoute()),
            ),
          ),

          // DOCTOR
          route<CommandRoute>(
            path: '/doctor',
            parse: (_) => const CommandRoute(NitroCommand.doctor),
            builder: (context, _) {
              final doctor = DoctorCommand();
              final result = doctor.performChecks();
              return DoctorView(
                pluginName: result.pluginName,
                sections: result.sections,
                errors: result.errors,
                warnings: result.warnings,
                errorMessage: result.errorMessage,
                onExit: () => context.unrouterAs<NitroRoute>().go(const RootRoute()),
              );
            },
          ),

          // LINK
          route<CommandRoute>(
            path: '/link',
            parse: (_) => const CommandRoute(NitroCommand.link),
            builder: (context, _) {
              final info = getProjectInfo();
              final name = info?.name ?? 'unknown';
              return LinkView(
                pluginName: name,
                result: LinkResult(),
                onExit: () => context.unrouterAs<NitroRoute>().go(const RootRoute()),
              );
            },
          ),

          // MIGRATE
          route<CommandRoute>(
            path: '/migrate',
            parse: (_) => const CommandRoute(NitroCommand.migrate),
            builder: (context, _) {
              final info = getProjectInfo();
              final name = info?.name ?? 'unknown';
              final projectPath = info?.directory.path ?? Directory.current.path;
              final spmStatus = detectSpmStatus(projectPath);
              return MigrateView(
                pluginName: name,
                result: MigrationResult(),
                spmStatus: spmStatus,
                onExit: () => context.unrouterAs<NitroRoute>().go(const RootRoute()),
              );
            },
          ),

          // UPDATE
          route<CommandRoute>(
            path: '/update',
            parse: (_) => const CommandRoute(NitroCommand.update),
            builder: (context, _) {
              return UpdateView(
                result: UpdateResult(),
                onExit: () => context.unrouterAs<NitroRoute>().go(const RootRoute()),
              );
            },
          ),

          // GENERATE (Streaming View)
          // 1. Kill any already-running build_runner so the new one never hangs.
          // 2. `flutter pub get || true` tolerates exit 255 (advisory-decode bug).
          // 3. Then run build_runner build.
          route<CommandRoute>(
            path: '/generate',
            parse: (_) => const CommandRoute(NitroCommand.generate),
            builder: (context, _) {
              final info = getProjectInfo();
              return ProcessView(
                title: 'Nitrogen Generate',
                executable: '/bin/sh',
                workingDirectory: info?.directory.path,
                killOnDispose: true,
                args: const [
                  '-c',
                  // 1. Find the PID holding the lock file (most reliable — bypasses
                  //    argv truncation that makes pkill -f miss the dart process).
                  // NOTE: \$ escapes Dart string interpolation; the shell sees $LOCK, $PIDS.
                  r'LOCK=.dart_tool/build/lock; '
                      r'if [ -f "$LOCK" ]; then '
                      r'  PIDS=$(lsof -t "$LOCK" 2>/dev/null); '
                      r'  [ -n "$PIDS" ] && kill -TERM $PIDS 2>/dev/null && sleep 0.7 && kill -KILL $PIDS 2>/dev/null; '
                      r'fi; '
                      // 2. pkill -f as a broad fallback.
                      'pkill -f build_runner 2>/dev/null; sleep 0.5; pkill -9 -f build_runner 2>/dev/null; '
                      // 3. Delete only the lock + asset graph, NOT entrypoint/ (AOT snapshot).
                      //    Deleting entrypoint/ forces an expensive ~15 s recompile every run.
                      'rm -f .dart_tool/build/lock .dart_tool/build/asset_graph.json 2>/dev/null; '
                      'flutter pub run build_runner build',
                ],
              );
            },
          ),
          // WATCH (Streaming View)
          // Same kill-first pattern. killOnDispose ensures the watcher process
          // is terminated when the user presses ESC / Back. watchMode suppresses
          // the success pulse and treats SIGTERM exit as a clean stop.
          route<CommandRoute>(
            path: '/watch',
            parse: (_) => const CommandRoute(NitroCommand.watch),
            builder: (context, _) {
              final info = getProjectInfo();
              return ProcessView(
                title: 'Nitrogen Watch',
                executable: '/bin/sh',
                workingDirectory: info?.directory.path,
                killOnDispose: true,
                watchMode: true,
                args: const [
                  '-c',
                  r'LOCK=.dart_tool/build/lock; '
                      r'if [ -f "$LOCK" ]; then '
                      r'  PIDS=$(lsof -t "$LOCK" 2>/dev/null); '
                      r'  [ -n "$PIDS" ] && kill -TERM $PIDS 2>/dev/null && sleep 0.7 && kill -KILL $PIDS 2>/dev/null; '
                      r'fi; '
                      'pkill -f build_runner 2>/dev/null; sleep 0.5; pkill -9 -f build_runner 2>/dev/null; '
                      'rm -f .dart_tool/build/lock .dart_tool/build/asset_graph.json 2>/dev/null; '
                      'flutter pub get || true; '
                      'flutter pub run build_runner watch --delete-conflicting-outputs',
                ],
              );
            },
          ),
        ],
      ),
    ),
  );
}
