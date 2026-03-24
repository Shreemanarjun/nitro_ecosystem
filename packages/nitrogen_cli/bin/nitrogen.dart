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
import 'package:nitrogen_cli/commands/open_command.dart';
import 'package:nitrogen_cli/version.dart';
import 'package:nitrogen_cli/ui.dart';

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
  ),
  openCode(
    'Open in VS Code',
    'Open project in VS Code.',
    '/',
    'Launches standard VS Code for development.',
  ),
  openAntigravity(
    'Open in Antigravity',
    'Open project in Antigravity.',
    '/',
    'Launches the Antigravity editor for AI-first development.',
  ),
  exit(
    'Exit',
    'Close the Nitrogen CLI.',
    '/exit',
    'Quits the interactive dashboard session.',
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
    ..addCommand(UpdateCommand())
    ..addCommand(OpenCommand());

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
            builder: (context, _) {
              final info = _getProjectInfo();
              return ProcessView(
                title: 'Nitrogen Generate',
                executable: 'flutter',
                workingDirectory: info?.directory.path,
                args: const [
                  'pub',
                  'run',
                  'build_runner',
                  'build',
                  '--delete-conflicting-outputs'
                ],
              );
            },
          ),
        ],
      ),
    ),
  );
}

class ProjectInfo {
  final String name;
  final String version;
  final Directory directory;
  const ProjectInfo(this.name, this.version, this.directory);
}

ProjectInfo? _getProjectInfo() {
  try {
    // 1. Check current directory
    final rootInfo = _parsePubspec(Directory.current);
    if (rootInfo != null) return rootInfo;

    // 2. Check direct subdirectories (common for monorepos or just-after-init)
    for (final entity in Directory.current.listSync()) {
      if (entity is Directory) {
        final info = _parsePubspec(entity);
        if (info != null) return info;
      }
    }
  } catch (_) {}
  return null;
}

ProjectInfo? _parsePubspec(Directory dir) {
  final pubspecFile = File('${dir.path}/pubspec.yaml');
  if (!pubspecFile.existsSync()) return null;

  final content = pubspecFile.readAsStringSync();
  // Ensure it's a Nitro project (has dependency or generator)
  if (!content.contains('nitro:') && !content.contains('nitro_generator:')) {
    return null;
  }

  String name = 'unknown';
  String version = 'unknown';
  for (final line in content.split('\n')) {
    if (line.trim().startsWith('name: ')) {
      name = line.replaceFirst('name: ', '').trim();
    }
    if (line.trim().startsWith('version: ')) {
      version = line.replaceFirst('version: ', '').trim();
    }
  }
  return ProjectInfo(name, version, dir);
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

  Future<void> _openEditor(String editor) async {
    if (_project == null) return;
    await openInEditor(editor, _project!.directory.path);
  }

  @override
  Component build(BuildContext context) {
    final menuCommands = NitroCommand.values
        .where((c) =>
            c != NitroCommand.openCode && c != NitroCommand.openAntigravity)
        .toList();

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.arrowDown) {
          setState(() {
            _selectedIndex = (_selectedIndex + 1) % menuCommands.length;
          });
          return true;
        }
        if (event.logicalKey == LogicalKey.arrowUp) {
          setState(() {
            _selectedIndex = (_selectedIndex - 1 + menuCommands.length) %
                menuCommands.length;
          });
          return true;
        }
        if (event.logicalKey == LogicalKey.enter) {
          final command = menuCommands[_selectedIndex];
          if (command == NitroCommand.exit) {
            exit(0);
          } else {
            context.unrouterAs<NitroRoute>().go(CommandRoute(command));
          }
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
                  Padding(
                    padding: const EdgeInsets.only(right: 1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Active: ${_project!.name} (v${_project!.version})',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Text(' • ',
                            style: TextStyle(color: Colors.brightBlack)),
                        _EditorOption(
                          label: 'Code',
                          color: Colors.blue,
                          onTap: () => _openEditor('code'),
                        ),
                        const Text(' • ',
                            style: TextStyle(color: Colors.brightBlack)),
                        _EditorOption(
                          label: 'Antigravity',
                          color: Colors.magenta,
                          onTap: () => _openEditor('antigravity'),
                        ),
                      ],
                    ),
                  ),
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
                        for (var i = 0; i < menuCommands.length; i++)
                          _CommandItem(
                            command: menuCommands[i],
                            selected: i == _selectedIndex,
                            onSelected: () =>
                                setState(() => _selectedIndex = i),
                            onTap: () {
                              final cmd = menuCommands[i];
                              if (cmd == NitroCommand.exit) {
                                exit(0);
                              } else {
                                context
                                    .unrouterAs<NitroRoute>()
                                    .go(CommandRoute(cmd));
                              }
                            },
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
    this.workingDirectory,
    super.key,
  });

  final String title;
  final String executable;
  final List<String> args;
  final String? workingDirectory;

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
      final process = await Process.start(
        component.executable,
        component.args,
        workingDirectory: component.workingDirectory,
      );

      // Handle stdout
      process.stdout
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen((line) {
        if (!mounted) return;
        setState(() {
          _logs.add(line);
          _scroll.scrollToEnd();
        });
      });

      // Handle stderr
      process.stderr
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
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
          // Keep the success layout stable even when pulsing to avoid flickering/jumps
          if (_done && _exitCode == 0)
            Container(
              padding: const EdgeInsets.all(1),
              child: Text(
                '  ✨ SUCCESS  ✨  ',
                style: TextStyle(
                  color: _successPulse ? Colors.green : Colors.black,
                  fontWeight: FontWeight.bold,
                ),
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
                HoverButton(
                  label: '‹ Back',
                  onTap: () =>
                      context.unrouterAs<NitroRoute>().go(const RootRoute()),
                  color: Colors.cyan,
                ),
                const SizedBox(width: 2),
                const Text('[ ESC ]',
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

class _EditorOption extends StatelessComponent {
  const _EditorOption({
    required this.label,
    required this.onTap,
    this.color = Colors.blue,
  });

  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Component build(BuildContext context) {
    return HoverButton(
      label: label,
      onTap: onTap,
      color: color,
    );
  }
}
