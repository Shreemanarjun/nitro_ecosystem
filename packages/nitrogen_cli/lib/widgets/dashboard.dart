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

// Global state persisted across navigation within the same session
List<ProjectInfo> _projects = [];
int _selectedProjectIndex = 0;
bool _focusMenu = true;

/// Resets the global dashboard state. Internal use only (for tests).
void resetDashboardState() {
  _projects = [];
  _selectedProjectIndex = 0;
  _focusMenu = true;
}

class _NitroDashboardState extends State<NitroDashboard> {
  int _selectedIndex = 0;
  bool _pulse = false;
  Timer? _timer;
  String _branch = 'loading...';
  final String _dartVersion = Platform.version.split(' ').first;

  ProjectInfo? get _project => _projects.isNotEmpty ? _projects[_selectedProjectIndex] : null;

  @override
  void initState() {
    super.initState();
    if (_projects.isEmpty) {
      _projects = getAllProjects();
    }
    if (_project != null) {
      Directory.current = _project!.directory;
    }
    _updateBranch();
    // Subtle pulse animation for the header
    _timer = Timer.periodic(const Duration(milliseconds: 800), (t) {
      if (mounted) setState(() => _pulse = !_pulse);
    });
  }

  void _updateBranch() {
    if (_project == null) return;
    getGitBranch(_project!.directory.path).then((b) {
      if (mounted) setState(() => _branch = b);
    });
  }

  // Syncs the current project context (e.g. for git branch display)
  void _syncProject() {
    if (_project == null) return;
    Directory.current = _project!.directory;
    _updateBranch();
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
            if (_focusMenu) {
              _selectedIndex = (_selectedIndex + 1) % menuCommands.length;
            } else if (_projects.length > 1) {
              _selectedProjectIndex = (_selectedProjectIndex + 1) % _projects.length;
              _syncProject();
            }
          });
          return true;
        }
        if (event.logicalKey == LogicalKey.arrowUp) {
          setState(() {
            if (_focusMenu) {
              _selectedIndex = (_selectedIndex - 1 + menuCommands.length) % menuCommands.length;
            } else if (_projects.length > 1) {
              _selectedProjectIndex = (_selectedProjectIndex - 1 + _projects.length) % _projects.length;
              _syncProject();
            }
          });
          return true;
        }
        if (event.logicalKey == LogicalKey.arrowRight && !_focusMenu) {
          setState(() => _focusMenu = true);
          return true;
        }
        if (event.logicalKey == LogicalKey.arrowLeft && _focusMenu && _projects.length > 1) {
          setState(() => _focusMenu = false);
          return true;
        }
        if (event.logicalKey == LogicalKey.tab && _projects.length > 1) {
          setState(() => _focusMenu = !_focusMenu);
          return true;
        }
        if (event.logicalKey == LogicalKey.enter) {
          if (!_focusMenu) {
            setState(() => _focusMenu = true);
            return true;
          }
          final command = menuCommands[_selectedIndex];
          if (command == NitroCommand.exit) {
            shutdownApp(0);
          } else {
            context.unrouterAs<NitroRoute>().go(CommandRoute(command));
          }
          return true;
        }
        if (event.logicalKey == LogicalKey.escape) {
          shutdownApp(0);
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
                        if (_projects.length > 1) const Text(' [Tab] ', style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim)),
                        Text(
                          'Active: ${_project!.name} (v${_project!.version})',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_projects.length > 1) Text(' (${_selectedProjectIndex + 1}/${_projects.length})', style: const TextStyle(color: Colors.gray)),
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
            child: Row(
              children: [
                // ── Left Side: Project List Sidebar ──────────────────────────
                if (_projects.length > 1)
                  Container(
                    width: 45,
                    decoration: const BoxDecoration(
                      border: BoxBorder(right: BorderSide(color: Colors.brightBlack)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                          child: Text(
                            ' PROJECTS ',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              backgroundColor: !_focusMenu ? Colors.brightBlack : null,
                            ),
                          ),
                        ),
                        const Divider(color: Colors.brightBlack),
                        Expanded(
                          child: ListView(
                            children: [
                              for (var i = 0; i < _projects.length; i++)
                                _ProjectItem(
                                  project: _projects[i],
                                  selected: i == _selectedProjectIndex,
                                  focused: !_focusMenu && i == _selectedProjectIndex,
                                  onSelected: () => setState(() {
                                    _selectedProjectIndex = i;
                                    _focusMenu = false;
                                    _syncProject();
                                  }),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                // ── Right Side: Main Dashboard Content ───────────────────────
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('The high-performance FFI toolkit for Flutter', style: TextStyle(color: Colors.brightBlack, fontWeight: FontWeight.dim)),
                        const SizedBox(height: 1),
                        // Centered block for aligned commands
                        SizedBox(
                          width: 60,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < menuCommands.length; i++)
                                _CommandItem(
                                  command: menuCommands[i],
                                  selected: i == _selectedIndex,
                                  focused: _focusMenu && i == _selectedIndex,
                                  onSelected: () => setState(() {
                                    _selectedIndex = i;
                                    _focusMenu = true;
                                  }),
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
                        Text('Arrows to navigate • Tab to switch areas', style: TextStyle(color: _focusMenu ? Colors.cyan : Colors.gray, fontWeight: FontWeight.dim)),
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
                              label: 'Creator: @mrousavy',
                              onTap: () => launchUrl('https://x.com/mrousavy'),
                              color: Colors.yellow,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
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
                const Text('ESC exit', style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim)),
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

class _ProjectItem extends StatefulComponent {
  const _ProjectItem({
    required this.project,
    required this.selected,
    required this.focused,
    required this.onSelected,
  });

  final ProjectInfo project;
  final bool selected;
  final bool focused;
  final VoidCallback onSelected;

  @override
  State<_ProjectItem> createState() => _ProjectItemState();
}

class _ProjectItemState extends State<_ProjectItem> {
  bool _isHovering = false;

  @override
  Component build(BuildContext context) {
    final bool active = component.selected || _isHovering;
    final bool reallyFocused = component.focused || (active && _isHovering);

    return GestureDetector(
      onTap: component.onSelected,
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _isHovering = true);
          component.onSelected();
        },
        onExit: (_) => setState(() => _isHovering = false),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
          child: Container(
            decoration: BoxDecoration(
              color: _isHovering ? Colors.brightBlack : null,
            ),
            child: Row(
              children: [
                Text(reallyFocused ? '❯ ' : (component.selected ? '• ' : '  '),
                    style: TextStyle(color: reallyFocused ? Colors.cyan : (component.selected ? Colors.white : Colors.gray))),
                Expanded(
                  child: Text(
                    component.project.name,
                    style: TextStyle(
                      color: reallyFocused ? Colors.cyan : (component.selected ? Colors.white : Colors.gray),
                      fontWeight: component.selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ],
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
    required this.focused,
    required this.onSelected,
    required this.onTap,
  });

  final NitroCommand command;
  final bool selected;
  final bool focused;
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
    final bool reallyFocused = component.focused || (active && _isHovering);

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
                Text(reallyFocused ? '❯ ' : '  ', style: TextStyle(color: reallyFocused ? Colors.magenta : Colors.white, fontWeight: FontWeight.bold)),
                SizedBox(
                  width: 12, // Slightly smaller label width for tighter fit
                  child: Text(component.command.label,
                      style: TextStyle(color: reallyFocused ? Colors.magenta : Colors.white, fontWeight: reallyFocused ? FontWeight.bold : FontWeight.normal)),
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
