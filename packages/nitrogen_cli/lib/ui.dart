/// Shared ANSI color/style utilities using nocterm's TextStyle + Colors.
///
/// These helpers write directly to stdout (plain terminal output, not a TUI
/// runApp session), so the output persists in the scrollback buffer.
library nitrogen_cli.ui;

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
  await Future.wait([
    process.stdout.pipe(stdout),
    process.stderr.pipe(stderr),
  ]);
  return process.exitCode;
}

/// Runs [executable] and returns a stream of its interleaved stdout/stderr.
Stream<String> streamProcess(String executable, List<String> args, {String? workingDirectory}) async* {
  final process = await Process.start(executable, args, workingDirectory: workingDirectory);

  yield* _interleave(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()),
  );
}

Stream<String> _interleave(Stream<String> a, Stream<String> b) {
  final controller = StreamController<String>();
  int active = 2;
  void handle(String s) => controller.add(s);
  void done() {
    active--;
    if (active == 0) controller.close();
  }

  a.listen(handle, onDone: done, onError: controller.addError);
  b.listen(handle, onDone: done, onError: controller.addError);
  return controller.stream;
}
