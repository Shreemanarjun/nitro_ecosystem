/// Shared terminal UI helpers for the Nitrogen CLI.
///
/// All output goes through these helpers so every command has a consistent
/// look.  ANSI codes are stripped automatically on Windows or when stdout is
/// not a TTY.
library nitrogen_cli.ui;

import 'dart:io';

// ── ANSI helpers ─────────────────────────────────────────────────────────────

final _isTty = stdout.hasTerminal;

String _ansi(String code, String text) =>
    _isTty ? '\x1B[${code}m$text\x1B[0m' : text;

String bold(String t) => _ansi('1', t);
String dim(String t) => _ansi('2', t);
String green(String t) => _ansi('32', t);
String yellow(String t) => _ansi('33', t);
String red(String t) => _ansi('31', t);
String cyan(String t) => _ansi('36', t);
String blue(String t) => _ansi('34', t);
String magenta(String t) => _ansi('35', t);

// ── Layout ───────────────────────────────────────────────────────────────────

/// Prints a prominent banner, e.g. at the start of a command.
void printBanner(String title) {
  final line = '─' * (title.length + 4);
  stdout.writeln('');
  stdout.writeln(bold(cyan('  $line')));
  stdout.writeln(bold(cyan('  ║ $title ║')));
  stdout.writeln(bold(cyan('  $line')));
  stdout.writeln('');
}

/// Prints a section heading (e.g. "Checking generated files").
void printSection(String title) {
  stdout.writeln('');
  stdout.writeln(bold('  ${cyan("▸")} $title'));
}

// ── Status lines ─────────────────────────────────────────────────────────────

void printOk(String label) =>
    stdout.writeln('    ${green("✔")}  $label');

void printWarn(String label, {String? hint}) {
  stdout.writeln('    ${yellow("⚠")}  ${yellow(label)}');
  if (hint != null) stdout.writeln('       ${dim("→")} ${dim(hint)}');
}

void printError(String label, {String? hint}) {
  stderr.writeln('    ${red("✘")}  ${red(label)}');
  if (hint != null) stderr.writeln('       ${dim("→")} ${dim(hint)}');
}

void printInfo(String label) =>
    stdout.writeln('    ${blue("ℹ")}  ${dim(label)}');

/// Prints a step that is starting (no trailing newline → call [printDone]).
void printStep(String label) {
  stdout.write('    ${cyan("›")}  $label … ');
}

void printDone([String msg = 'done']) {
  stdout.writeln(green(msg));
}

// ── Spinner (for long async waits) ───────────────────────────────────────────

const _spinFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

/// Runs [fn] while showing an animated spinner with [label].
/// Returns whatever [fn] returns.
Future<T> withSpinner<T>(String label, Future<T> Function() fn) async {
  if (!_isTty) {
    stdout.writeln('    › $label …');
    return fn();
  }

  var frame = 0;
  var done = false;
  void spin() async {
    while (!done) {
      stdout.write('\r    ${cyan(_spinFrames[frame % _spinFrames.length])}  $label … ');
      frame++;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  spin();
  try {
    final result = await fn();
    done = true;
    stdout.write('\r    ${green("✔")}  $label          \n');
    return result;
  } catch (e) {
    done = true;
    stdout.write('\r    ${red("✘")}  $label          \n');
    rethrow;
  }
}

// ── Summary ──────────────────────────────────────────────────────────────────

void printSummary({required int errors, required int warnings, required String subject}) {
  stdout.writeln('');
  if (errors == 0 && warnings == 0) {
    stdout.writeln(bold(green('  ✨ $subject — all checks passed.')));
  } else {
    if (errors > 0) {
      stderr.writeln(bold(red('  ✘  $errors error(s) found in $subject.')));
    }
    if (warnings > 0) {
      stdout.writeln(bold(yellow('  ⚠  $warnings warning(s) found in $subject.')));
    }
  }
  stdout.writeln('');
}

// ── Process streaming ─────────────────────────────────────────────────────────

/// Runs a process and streams its stdout/stderr to the terminal in real time.
/// Returns the exit code.
Future<int> runStreaming(String executable, List<String> args,
    {String? workingDirectory}) async {
  final process = await Process.start(executable, args,
      workingDirectory: workingDirectory);
  await Future.wait([
    process.stdout.pipe(stdout),
    process.stderr.pipe(stderr),
  ]);
  return process.exitCode;
}
