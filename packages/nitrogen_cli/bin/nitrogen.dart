import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_unrouter/nocterm_unrouter.dart';

import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/update_command.dart';
import 'package:nitrogen_cli/commands/open_command.dart';
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
    ..addCommand(LinkCommand())
    ..addCommand(DoctorCommand())
    ..addCommand(UpdateCommand())
    ..addCommand(OpenCommand());

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
          route<CommandRoute>(
            path: '/generate',
            parse: (_) => const CommandRoute(NitroCommand.generate),
            builder: (context, _) {
              final info = getProjectInfo();
              return ProcessView(
                title: 'Nitrogen Generate',
                executable: 'flutter',
                workingDirectory: info?.directory.path,
                args: const ['pub', 'run', 'build_runner', 'build', '--delete-conflicting-outputs'],
              );
            },
          ),
        ],
      ),
    ),
  );
}
