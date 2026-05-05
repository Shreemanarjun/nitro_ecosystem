/// Shared ANSI color/style utilities using nocterm's TextStyle + Colors.
///
/// These helpers write directly to stdout (plain terminal output, not a TUI
/// runApp session), so the output persists in the scrollback buffer.
library;

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:nocterm/nocterm.dart';

// ── Shared discovery ─────────────────────────────────────────────────────────

/// Searches for a Nitro project root. Checks the current directory first,
/// then direct subdirectories. Returns the Directory if a pubspec.yaml
/// containing 'nitro' is found.
Directory? findNitroProjectRoot() {
  // 1. Check current directory
  if (_isNitroRoot(Directory.current)) return Directory.current;

  // 2. Check direct subdirectories (common in monorepos or after init)
  try {
    for (final entity in Directory.current.listSync()) {
      if (entity is Directory && _isNitroRoot(entity)) {
        return entity;
      }
    }
  } catch (_) {}

  return null;
}

bool _isNitroRoot(Directory dir) {
  final pubspec = File('${dir.path}/pubspec.yaml');
  if (!pubspec.existsSync()) return false;
  final content = pubspec.readAsStringSync();
  return content.contains('nitro:') || content.contains('nitro_generator:');
}

// ── nocterm UI Components ──────────────────────────────────────────────────

// ── Clipboard helpers ─────────────────────────────────────────────────────────

/// Copies [text] to the system clipboard.
/// Returns true on success, false on failure.
Future<bool> copyToClipboard(String text) async {
  try {
    if (Platform.isMacOS) {
      final p = await Process.start('pbcopy', []);
      p.stdin.write(text);
      await p.stdin.close();
      await p.exitCode;
      return true;
    } else if (Platform.isLinux) {
      try {
        final p = await Process.start('xclip', ['-selection', 'clipboard']);
        p.stdin.write(text);
        await p.stdin.close();
        await p.exitCode;
        return true;
      } catch (_) {
        final p = await Process.start('xsel', ['--clipboard', '--input']);
        p.stdin.write(text);
        await p.stdin.close();
        await p.exitCode;
        return true;
      }
    } else if (Platform.isWindows) {
      final p = await Process.start('clip', []);
      p.stdin.write(text);
      await p.stdin.close();
      await p.exitCode;
      return true;
    }
  } catch (_) {}
  return false;
}

/// A button that copies data to the clipboard.
///
/// Pass a [getData] callback that returns the string to copy.
/// The button shows "📋 Copy" → "✔ Copied!" (green) or "✘ Failed" (red)
/// for 2 s, then resets. Fully self-contained — no parent state needed.
class CopyButton extends StatefulComponent {
  const CopyButton({required this.getData, super.key});
  final String Function() getData;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool? _result; // null = idle, true = ok, false = error
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _copy() async {
    final ok = await copyToClipboard(component.getData());
    if (!mounted) return;
    _timer?.cancel();
    setState(() => _result = ok);
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _result = null);
    });
  }

  @override
  Component build(BuildContext context) {
    final label = _result == null ? '📋 Copy' : (_result! ? '✔ Copied!' : '✘ Failed');
    final color = _result == null ? Colors.white : (_result! ? Colors.green : Colors.red);
    return HoverButton(label: label, onTap: _copy, color: color);
  }
}

// ── HoverButton ───────────────────────────────────────────────────────────────

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
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Styled text helpers ──────────────────────────────────────────────────────

String _s(String t, TextStyle style) {
  if (!stdout.hasTerminal) return t;
  return '${style.toAnsi()}$t${TextStyle.reset}';
}

String bold(String t) => _s(t, const TextStyle(fontWeight: FontWeight.bold));
String dim(String t) => _s(t, const TextStyle(fontWeight: FontWeight.dim));
String green(String t) => _s(t, const TextStyle(color: Colors.green));
String yellow(String t) => _s(t, const TextStyle(color: Colors.yellow));
String red(String t) => _s(t, const TextStyle(color: Colors.red));
String cyan(String t) => _s(t, const TextStyle(color: Colors.cyan));
String gray(String t) => _s(t, const TextStyle(color: Colors.gray));
String boldCyan(String t) => _s(t, const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold));
String boldGreen(String t) => _s(t, const TextStyle(color: Colors.green, fontWeight: FontWeight.bold));
String boldRed(String t) => _s(t, const TextStyle(color: Colors.red, fontWeight: FontWeight.bold));
String blue(String t) => _s(t, const TextStyle(color: Colors.blue));
String magenta(String t) => _s(t, const TextStyle(color: Colors.magenta));

// ── Process streaming ─────────────────────────────────────────────────────────

/// Runs [executable] and streams its stdout/stderr to the terminal in real time.
/// Returns the exit code.
Future<int> runStreaming(String executable, List<String> args, {String? workingDirectory}) async {
  final process = await Process.start(executable, args, workingDirectory: workingDirectory);

  // Kill the child process if the parent is interrupted (Ctrl+C).
  // SIGINT/SIGTERM watch is not supported on Windows.
  StreamSubscription? sigintSub;
  StreamSubscription? sigtermSub;
  if (!Platform.isWindows) {
    sigintSub = ProcessSignal.sigint.watch().listen((_) {
      process.kill(ProcessSignal.sigint);
      exit(130); // 128 + SIGINT
    });
    sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
      process.kill(ProcessSignal.sigterm);
      exit(143); // 128 + SIGTERM
    });
  }

  // Use listen().asFuture() instead of pipe() — pipe() closes the sink when
  // the stream ends, which would close nitrogen's own stdout/stderr for all
  // subsequent output.
  await Future.wait([
    process.stdout.listen(stdout.add).asFuture<void>(),
    process.stderr.listen(stderr.add).asFuture<void>(),
  ]);

  await sigintSub?.cancel();
  await sigtermSub?.cancel();

  return process.exitCode;
}

/// Runs [executable] and returns a stream of its interleaved stdout/stderr.
Stream<String> streamProcess(String executable, List<String> args, {String? workingDirectory}) {
  final controller = StreamController<String>();
  Process? process;
  StreamSubscription? sigintSub;
  StreamSubscription? sigtermSub;

  controller.onListen = () async {
    try {
      process = await Process.start(executable, args, workingDirectory: workingDirectory);

      if (!Platform.isWindows) {
        sigintSub = ProcessSignal.sigint.watch().listen((_) {
          process?.kill(ProcessSignal.sigint);
          exit(130);
        });
        sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
          process?.kill(ProcessSignal.sigterm);
          exit(143);
        });
      }

      int active = 2;
      void done() {
        active--;
        if (active == 0) {
          sigintSub?.cancel();
          sigtermSub?.cancel();
          controller.close();
        }
      }

      process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
        controller.add,
        onDone: done,
        onError: controller.addError,
      );
      process!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
        controller.add,
        onDone: done,
        onError: controller.addError,
      );
    } catch (e) {
      controller.addError(e);
      controller.close();
    }
  };

  controller.onCancel = () {
    sigintSub?.cancel();
    sigtermSub?.cancel();
    process?.kill();
  };

  return controller.stream;
}

