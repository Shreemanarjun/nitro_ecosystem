import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_unrouter/nocterm_unrouter.dart';
import 'package:path/path.dart' as p;

import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/update_command.dart';

// ── Models ───────────────────────────────────────────────────────────────────

enum NitroCommand {
  init(
    'Initialize',
    'Scaffold a new Nitro FFI plugin project.',
    '/init',
    'Creates all necessary boilerplate for your C++/Kotlin/Swift bridges.',
  ),
  generate(
    'Generate',
    'Run the Nitro code generator (build_runner).',
    '/generate',
    'Parses your Dart interfaces and generates the native marshalling code.',
  ),
  link(
    'Link',
    'Wire native bridges into the build system.',
    '/link',
    'Automatically configures CMake, Gradle, and CocoaPods for your bridges.',
  ),
  doctor(
    'Doctor',
    'Check if the plugin is production-ready.',
    '/doctor',
    'Validates your project structure, native dependencies, and environment.',
  ),
  update(
    'Update',
    'Self-update the Nitrogen CLI.',
    '/update',
    'Fetches the latest version of nitrogen from pub.dev.',
  );

  const NitroCommand(this.label, this.description, this.path, this.longInfo);
  final String label;
  final String description;
  final String path;
  final String longInfo;
}

// ── Routes ───────────────────────────────────────────────────────────────────

sealed class NitroRoute implements RouteData {
  const NitroRoute();
}

final class RootRoute extends NitroRoute {
  const RootRoute();
  @override
  Uri toUri() => Uri(path: '/');
}

final class CommandRoute extends NitroRoute {
  const CommandRoute(this.command);
  final NitroCommand command;
  @override
  Uri toUri() => Uri(path: command.path);
}

// ── Entry Point ──────────────────────────────────────────────────────────────

void main(List<String> args) async {
  if (args.isEmpty) {
    await _runTui();
    return;
  }

  final runner = CommandRunner('nitrogen', 'Nitrogen FFI toolkit')
    ..addCommand(InitCommand())
    ..addCommand(GenerateCommand())
    ..addCommand(LinkCommand())
    ..addCommand(DoctorCommand())
    ..addCommand(UpdateCommand());

  try {
    await runner.run(args);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}

// ── TUI App ──────────────────────────────────────────────────────────────────

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
            builder: (context, _) => InitView(
              pluginName: 'my_nitro_plugin', // TODO: Add input modal
              org: 'com.example',
              result: InitResult(),
              onExit: () =>
                  context.unrouterAs<NitroRoute>().go(const RootRoute()),
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
                onExit: () =>
                    context.unrouterAs<NitroRoute>().go(const RootRoute()),
              );
            },
          ),

          // LINK
          route<CommandRoute>(
            path: '/link',
            parse: (_) => const CommandRoute(NitroCommand.link),
            builder: (context, _) {
              final pubspec = File('pubspec.yaml');
              final name =
                  pubspec.existsSync() ? _getPluginName(pubspec) : 'unknown';
              return LinkView(
                pluginName: name,
                result: LinkResult(),
                onExit: () =>
                    context.unrouterAs<NitroRoute>().go(const RootRoute()),
              );
            },
          ),

          // UPDATE
          route<CommandRoute>(
            path: '/update',
            parse: (_) => const CommandRoute(NitroCommand.update),
            builder: (context, _) {
              final scriptPath = Platform.script.toFilePath();
              final repoRoot = _findGitRoot(p.dirname(scriptPath)) ?? '.';
              return UpdateView(
                repoRoot: repoRoot,
                result: UpdateResult(),
                onExit: () =>
                    context.unrouterAs<NitroRoute>().go(const RootRoute()),
              );
            },
          ),

          // GENERATE (Streaming View)
          route<CommandRoute>(
            path: '/generate',
            parse: (_) => const CommandRoute(NitroCommand.generate),
            builder: (context, _) => const ProcessView(
              title: 'Nitrogen Generate',
              executable: 'flutter',
              args: [
                'pub',
                'run',
                'build_runner',
                'build',
                '--delete-conflicting-outputs'
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

String _getPluginName(File pubspec) {
  for (final line in pubspec.readAsLinesSync()) {
    if (line.startsWith('name: ')) {
      return line.replaceFirst('name: ', '').trim();
    }
  }
  return 'unknown';
}

String? _findGitRoot(String startDir) {
  var dir = Directory(startDir);
  while (true) {
    if (Directory(p.join(dir.path, '.git')).existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

// ── Dashboard Component ──────────────────────────────────────────────────────

class NitroDashboard extends StatefulComponent {
  const NitroDashboard({super.key});

  @override
  State<NitroDashboard> createState() => _NitroDashboardState();
}

class _NitroDashboardState extends State<NitroDashboard> {
  int _selectedIndex = 0;

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.arrowDown) {
          setState(() => _selectedIndex =
              (_selectedIndex + 1) % NitroCommand.values.length);
          return true;
        }
        if (event.logicalKey == LogicalKey.arrowUp) {
          setState(() => _selectedIndex =
              (_selectedIndex - 1 + NitroCommand.values.length) %
                  NitroCommand.values.length);
          return true;
        }
        if (event.logicalKey == LogicalKey.enter) {
          context
              .unrouterAs<NitroRoute>()
              .go(CommandRoute(NitroCommand.values[_selectedIndex]));
          return true;
        }
        return false;
      },
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('⚡ Nitrogen CLI',
                style:
                    TextStyle(fontWeight: FontWeight.bold, color: Colors.cyan)),
            const Text('The high-performance FFI toolkit for Flutter',
                style:
                    TextStyle(color: Colors.gray, fontWeight: FontWeight.dim)),
            const SizedBox(height: 1),
            for (var i = 0; i < NitroCommand.values.length; i++)
              _CommandItem(
                command: NitroCommand.values[i],
                selected: i == _selectedIndex,
              ),
            const SizedBox(height: 1),
            const Text('Use arrows and Enter to navigate • Ctrl+C to exit',
                style:
                    TextStyle(color: Colors.gray, fontWeight: FontWeight.dim)),
          ],
        ),
      ),
    );
  }
}

class _CommandItem extends StatelessComponent {
  const _CommandItem(
      {required this.command, required this.selected});
  final NitroCommand command;
  final bool selected;

  @override
  Component build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(selected ? '▶ ' : '  ',
              style: const TextStyle(color: Colors.cyan)),
          SizedBox(
            width: 15,
            child: Text(command.label,
                style: TextStyle(
                    color: selected ? Colors.cyan : Colors.white,
                    fontWeight:
                        selected ? FontWeight.bold : FontWeight.normal)),
          ),
          const SizedBox(width: 2),
          Text(command.description, style: const TextStyle(color: Colors.gray)),
        ],
      ),
    );
  }
}

// ── Process View (for Streaming Output) ──────────────────────────────────────

class ProcessView extends StatefulComponent {
  const ProcessView({
    required this.title,
    required this.executable,
    required this.args,
    super.key,
  });

  final String title;
  final String executable;
  final List<String> args;

  @override
  State<ProcessView> createState() => _ProcessViewState();
}

class _ProcessViewState extends State<ProcessView> {
  final List<String> _logs = [];
  final ScrollController _scroll = ScrollController();
  bool _running = false;
  bool _done = false;
  int? _exitCode;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, _start);
  }

  void _start() async {
    setState(() {
      _running = true;
      _logs.add(
          '[Info] Starting ${component.executable} ${component.args.join(' ')}...');
    });

    try {
      final process = await Process.start(component.executable, component.args);

      // Handle stdout
      process.stdout
          .transform(Utf8Decoder())
          .transform(LineSplitter())
          .listen((line) {
        if (!mounted) return;
        setState(() {
          _logs.add(line);
          _scroll.scrollToEnd();
        });
      });

      // Handle stderr
      process.stderr
          .transform(Utf8Decoder())
          .transform(LineSplitter())
          .listen((line) {
        if (!mounted) return;
        setState(() {
          _logs.add('[Error] $line');
          _scroll.scrollToEnd();
        });
      });

      final code = await process.exitCode;
      if (!mounted) return;
      setState(() {
        _running = false;
        _done = true;
        _exitCode = code;
        _logs.add('[Info] Process exited with code $code');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _done = true;
        _logs.add('[Fatal] Failed to start process: $e');
      });
    }
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape ||
            event.logicalKey == LogicalKey.arrowLeft) {
          context.unrouterAs<NitroRoute>().go(const RootRoute());
          return true;
        }
        return false;
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, left: 1, right: 1),
            child: Container(
              decoration:
                  BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(' ${component.title} ',
                    style: const TextStyle(
                        color: Colors.cyan, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
          const SizedBox(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                decoration: BoxDecoration(
                    border: BoxBorder.all(color: Colors.brightBlack)),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: ListView(
                    controller: _scroll,
                    children: _logs
                        .map((l) =>
                            Text(l, style: const TextStyle(color: Colors.gray)))
                        .toList(),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_running)
                  const Text('⚙ Running...',
                      style: TextStyle(color: Colors.yellow)),
                if (_done)
                  Text(
                    _exitCode == 0 ? '✔ Success' : '✘ Failed (Code $_exitCode)',
                    style: TextStyle(
                        color: _exitCode == 0 ? Colors.green : Colors.red,
                        fontWeight: FontWeight.bold),
                  ),
                const SizedBox(width: 2),
                const Text('[ Press ESC to return ]',
                    style: TextStyle(
                        color: Colors.gray, fontWeight: FontWeight.dim)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
