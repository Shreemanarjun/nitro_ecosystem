import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_unrouter/nocterm_unrouter.dart';

import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/update_command.dart';
import 'package:nitrogen_cli/version.dart';

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

  if (args.length == 1 && (args[0] == '--version' || args[0] == '-v')) {
    stdout.writeln('nitrogen version: $activeVersion');
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
            builder: (context, _) => NitrogenInitApp(
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
              final info = _getProjectInfo();
              final name = info?.name ?? 'unknown';
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
              return UpdateView(
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

class ProjectInfo {
  final String name;
  final String version;
  const ProjectInfo(this.name, this.version);
}

ProjectInfo? _getProjectInfo() {
  try {
    final pubspec = File('pubspec.yaml');
    if (pubspec.existsSync()) {
      String name = 'unknown';
      String version = 'unknown';
      for (final line in pubspec.readAsLinesSync()) {
        if (line.startsWith('name: '))
          name = line.replaceFirst('name: ', '').trim();
        if (line.startsWith('version: '))
          version = line.replaceFirst('version: ', '').trim();
      }
      return ProjectInfo(name, version);
    }
  } catch (_) {}
  return null;
}

Future<String> _getGitBranch() async {
  try {
    final result = await Process.run('git', ['branch', '--show-current']);
    if (result.exitCode == 0) return result.stdout.toString().trim();
  } catch (_) {}
  return 'no git';
}

// ── Dashboard Component ──────────────────────────────────────────────────────

// ── Utility ──────────────────────────────────────────────────────────────────

void _launchUrl(String url) {
  if (Platform.isMacOS) {
    Process.run('open', [url]);
  } else if (Platform.isLinux) {
    Process.run('xdg-open', [url]);
  } else if (Platform.isWindows) {
    Process.run('powershell', ['Start-Process', '"$url"']);
  }
}

class NitroDashboard extends StatefulComponent {
  const NitroDashboard({super.key});

  @override
  State<NitroDashboard> createState() => _NitroDashboardState();
}

class _NitroDashboardState extends State<NitroDashboard> {
  int _selectedIndex = 0;
  bool _pulse = false;
  Timer? _timer;
  ProjectInfo? _project;
  String _branch = 'loading...';
  final String _dartVersion = Platform.version.split(' ').first;

  @override
  void initState() {
    super.initState();
    _project = _getProjectInfo();
    _getGitBranch().then((b) {
      if (mounted) setState(() => _branch = b);
    });
    // Subtle pulse animation for the header
    _timer = Timer.periodic(const Duration(milliseconds: 800), (t) {
      if (mounted) setState(() => _pulse = !_pulse);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

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
      child: Column(
        children: [
          // ── Header/Top Bar ──────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
            decoration: const BoxDecoration(
              border: BoxBorder(bottom: BorderSide(color: Colors.brightBlack)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                    '${_pulse ? '⚡' : '🔥'} Nitrogen CLI v$activeVersion by Shreeman Arjun',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _pulse ? Colors.magenta : Colors.cyan)),
                if (_project != null)
                  Text(
                      'Active Project: ${_project!.name} (v${_project!.version})',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),

          // ── Centered Navigation ──────────────────────────────────────────
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('The high-performance FFI toolkit for Flutter',
                      style: TextStyle(
                          color: Colors.brightBlack,
                          fontWeight: FontWeight.dim)),
                  const SizedBox(height: 1),
                  // Centered block for aligned commands
                  SizedBox(
                    width: 60, // Fixed width for consistent alignment
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < NitroCommand.values.length; i++)
                          _CommandItem(
                            command: NitroCommand.values[i],
                            selected: i == _selectedIndex,
                            onSelected: () =>
                                setState(() => _selectedIndex = i),
                            onTap: () => context
                                .unrouterAs<NitroRoute>()
                                .go(CommandRoute(NitroCommand.values[i])),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 1),
                  const Text(
                      'Use arrows and Enter to navigate • Ctrl+C to exit',
                      style: TextStyle(
                          color: Colors.brightBlack,
                          fontWeight: FontWeight.dim)),
                  const SizedBox(height: 1),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      HoverButton(
                        label: 'Docs: nitro.shreeman.dev',
                        onTap: () => _launchUrl('https://nitro.shreeman.dev/'),
                        color: Colors.blue,
                      ),
                      const Text(' • ',
                          style: TextStyle(color: Colors.brightBlack)),
                      HoverButton(
                        label: 'Other plugins: shreeman.dev',
                        onTap: () => _launchUrl('https://www.shreeman.dev'),
                        color: Colors.blue,
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Inspired by ',
                          style: TextStyle(
                              color: Colors.brightBlack,
                              fontWeight: FontWeight.dim)),
                      HoverButton(
                        label: 'Marc Rousavy (@mrousavy)',
                        onTap: () => _launchUrl('https://x.com/mrousavy'),
                        color: Colors.yellow,
                      ),
                      const Text(' — Creator of ',
                          style: TextStyle(
                              color: Colors.brightBlack,
                              fontWeight: FontWeight.dim)),
                      const Text('VisionCamera',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      const Text(' & ',
                          style: TextStyle(
                              color: Colors.brightBlack,
                              fontWeight: FontWeight.dim)),
                      const Text('Nitro Modules',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ── Fixed Bottom Status Bar ──────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
            decoration: const BoxDecoration(
              border: BoxBorder(top: BorderSide(color: Colors.brightBlack)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Dart: $_dartVersion',
                    style: const TextStyle(color: Colors.gray)),
                Text('Branch: $_branch',
                    style: const TextStyle(color: Colors.magenta)),
                const Text('Nitro Modules • Ready',
                    style: TextStyle(color: Colors.cyan)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class HoverButton extends StatefulComponent {
  const HoverButton({
    required this.label,
    required this.onTap,
    this.color = Colors.cyan,
  });

  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  State<HoverButton> createState() => _HoverButtonState();
}

class _HoverButtonState extends State<HoverButton> {
  bool _isHovering = false;

  @override
  Component build(BuildContext context) {
    return GestureDetector(
      onTap: component.onTap,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        child: Container(
          decoration: BoxDecoration(
            color: _isHovering ? Colors.brightBlack : null,
          ),
          child: Text(
            component.label,
            style: TextStyle(
              color: _isHovering ? Colors.magenta : component.color,
              fontWeight: _isHovering ? FontWeight.bold : FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandItem extends StatefulComponent {
  const _CommandItem({
    required this.command,
    required this.selected,
    required this.onSelected,
    required this.onTap,
  });

  final NitroCommand command;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback onTap;

  @override
  State<_CommandItem> createState() => _CommandItemState();
}

class _CommandItemState extends State<_CommandItem> {
  bool _isHovering = false;

  @override
  Component build(BuildContext context) {
    // Combine hover and keyboard "selected" states for the background color
    final bool active = component.selected || _isHovering;

    return GestureDetector(
      onTap: component.onTap,
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _isHovering = true);
          component.onSelected();
        },
        onExit: (_) => setState(() => _isHovering = false),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Container(
            decoration: BoxDecoration(
              // Add a subtle background highlight for better hover feedback
              color: _isHovering ? Colors.brightBlack : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Text(active ? '❯ ' : '  ',
                    style: TextStyle(
                        color: active ? Colors.magenta : Colors.white,
                        fontWeight: FontWeight.bold)),
                SizedBox(
                  width: 12, // Slightly smaller label width for tighter fit
                  child: Text(component.command.label,
                      style: TextStyle(
                          color: active ? Colors.magenta : Colors.white,
                          fontWeight:
                              active ? FontWeight.bold : FontWeight.normal)),
                ),
                const SizedBox(width: 1),
                Text(component.command.description,
                    style: const TextStyle(color: Colors.gray)),
              ],
            ),
          ),
        ),
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
  bool _successPulse = false;
  Timer? _pulseTimer;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, _start);
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
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
        if (code == 0) {
          _pulseTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
            if (mounted) setState(() => _successPulse = !_successPulse);
          });
        }
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
              decoration: BoxDecoration(
                  border: BoxBorder.all(
                      color: _successPulse ? Colors.green : Colors.cyan)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(' ${component.title} ',
                    style: TextStyle(
                        color: _successPulse ? Colors.green : Colors.magenta,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          ),
          const SizedBox(height: 1),
          if (_successPulse)
            Container(
              padding: const EdgeInsets.all(1),
              child: const Text(
                '  ✨ SUCCESS  ✨  ',
                style:
                    TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
              ),
            ),
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
                        .map((l) => Text(l,
                            style: const TextStyle(color: Colors.white)))
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
