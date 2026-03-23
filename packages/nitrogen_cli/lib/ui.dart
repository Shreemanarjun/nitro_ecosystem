/// Shared ANSI color/style utilities using nocterm's TextStyle + Colors.
///
/// These helpers write directly to stdout (plain terminal output, not a TUI
/// runApp session), so the output persists in the scrollback buffer.
library nitrogen_cli.ui;

import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:nocterm/nocterm.dart';

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
String boldCyan(String t) =>
    _s(t, const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold));
String boldGreen(String t) =>
    _s(t, const TextStyle(color: Colors.green, fontWeight: FontWeight.bold));
String boldRed(String t) =>
    _s(t, const TextStyle(color: Colors.red, fontWeight: FontWeight.bold));
String blue(String t) => _s(t, const TextStyle(color: Colors.blue));
String magenta(String t) => _s(t, const TextStyle(color: Colors.magenta));

// ── Process streaming ─────────────────────────────────────────────────────────

/// Runs [executable] and streams its stdout/stderr to the terminal in real time.
/// Returns the exit code.
Future<int> runStreaming(String executable, List<String> args,
    {String? workingDirectory}) async {
  final process =
      await Process.start(executable, args, workingDirectory: workingDirectory);
  await Future.wait([
    process.stdout.pipe(stdout),
    process.stderr.pipe(stderr),
  ]);
  return process.exitCode;
}

/// Runs [executable] and returns a stream of its interleaved stdout/stderr.
Stream<String> streamProcess(String executable, List<String> args,
    {String? workingDirectory}) async* {
  final process =
      await Process.start(executable, args, workingDirectory: workingDirectory);

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
