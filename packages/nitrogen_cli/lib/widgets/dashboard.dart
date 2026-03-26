import 'dart:io';
import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_unrouter/nocterm_unrouter.dart';
import '../models.dart';
import '../routes.dart';
import '../utils.dart';
import '../ui.dart';
import '../version.dart';
import '../commands/open_command.dart';

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
    _project = getProjectInfo();
    getGitBranch().then((b) {
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
    final menuCommands = NitroCommand.values.where((c) => c != NitroCommand.openCode && c != NitroCommand.openAntigravity).toList();

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
            _selectedIndex = (_selectedIndex - 1 + menuCommands.length) % menuCommands.length;
          });
          return true;
        }
        if (event.logicalKey == LogicalKey.enter) {
          final command = menuCommands[_selectedIndex];
          if (command == NitroCommand.exit) {
            shutdownApp(0);
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
                Text('${_pulse ? '⚡' : '🔥'} Nitrogen CLI v$activeVersion by Shreeman Arjun',
                    style: TextStyle(fontWeight: FontWeight.bold, color: _pulse ? Colors.magenta : Colors.cyan)),
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
                        const Text(' • ', style: TextStyle(color: Colors.brightBlack)),
                        _EditorOption(
                          label: 'Code',
                          color: Colors.blue,
                          onTap: () => _openEditor('code'),
                        ),
                        const Text(' • ', style: TextStyle(color: Colors.brightBlack)),
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
                  const Text('The high-performance FFI toolkit for Flutter', style: TextStyle(color: Colors.brightBlack, fontWeight: FontWeight.dim)),
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
                            onSelected: () => setState(() => _selectedIndex = i),
                            onTap: () {
                              final cmd = menuCommands[i];
                              if (cmd == NitroCommand.exit) {
                                shutdownApp(0);
                              } else {
                                context.unrouterAs<NitroRoute>().go(CommandRoute(cmd));
                              }
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 1),
                  const Text('Use arrows and Enter to navigate • Ctrl+C to exit', style: TextStyle(color: Colors.brightBlack, fontWeight: FontWeight.dim)),
                  const SizedBox(height: 1),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      HoverButton(
                        label: 'Docs: nitro.shreeman.dev',
                        onTap: () => launchUrl('https://nitro.shreeman.dev/'),
                        color: Colors.blue,
                      ),
                      const Text(' • ', style: TextStyle(color: Colors.brightBlack)),
                      HoverButton(
                        label: 'Other plugins: shreeman.dev',
                        onTap: () => launchUrl('https://www.shreeman.dev'),
                        color: Colors.blue,
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Inspired by ', style: TextStyle(color: Colors.brightBlack, fontWeight: FontWeight.dim)),
                      HoverButton(
                        label: 'Marc Rousavy (@mrousavy)',
                        onTap: () => launchUrl('https://x.com/mrousavy'),
                        color: Colors.yellow,
                      ),
                      const Text(' — Creator of ', style: TextStyle(color: Colors.brightBlack, fontWeight: FontWeight.dim)),
                      const Text('VisionCamera', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      const Text(' & ', style: TextStyle(color: Colors.brightBlack, fontWeight: FontWeight.dim)),
                      const Text('Nitro Modules', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                Text('Dart: $_dartVersion', style: const TextStyle(color: Colors.gray)),
                Text('Branch: $_branch', style: const TextStyle(color: Colors.magenta)),
                const Text('Nitro Modules • Ready', style: TextStyle(color: Colors.cyan)),
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
                Text(active ? '❯ ' : '  ', style: TextStyle(color: active ? Colors.magenta : Colors.white, fontWeight: FontWeight.bold)),
                SizedBox(
                  width: 12, // Slightly smaller label width for tighter fit
                  child: Text(component.command.label, style: TextStyle(color: active ? Colors.magenta : Colors.white, fontWeight: active ? FontWeight.bold : FontWeight.normal)),
                ),
                const SizedBox(width: 1),
                Text(component.command.description, style: const TextStyle(color: Colors.gray)),
              ],
            ),
          ),
        ),
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
