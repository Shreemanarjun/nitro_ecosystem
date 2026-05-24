import 'dart:io';
import 'package:args/command_runner.dart';
import '../ui.dart';

class OpenCommand extends Command {
  @override
  final String name = 'open';

  @override
  final String description = 'Opens the Nitrogen project in an editor.';

  OpenCommand() {
    argParser
      ..addOption(
        'editor',
        abbr: 'e',
        help: 'The editor to use.',
        allowed: ['code', 'antigravity'],
        defaultsTo: 'code',
      )
      ..addFlag(
        'no-ui',
        negatable: false,
        help: 'Plain-text headless output (no ANSI). Auto-enabled when stdout is not a TTY.',
      );
  }

  bool get _headless => !stdout.hasTerminal || (argResults!['no-ui'] as bool);

  @override
  Future<void> run() async {
    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      if (_headless) {
        stderr.writeln('[nitro:error] No Nitro project found in . or its subdirectories.');
      } else {
        stderr.writeln(red('❌ No Nitro project found in . or its subdirectories.'));
      }
      exit(1);
    }

    final editor = argResults?['editor'] as String;
    await openInEditor(editor, projectDir.path, headless: _headless);
  }
}

Future<void> openInEditor(String editor, String path, {bool headless = false}) async {
  String command;
  switch (editor) {
    case 'code':
      command = 'code';
    case 'antigravity':
      command = 'antigravity';
    default:
      command = 'code';
  }

  try {
    if (headless) {
      stdout.writeln('[nitro] opening $editor: $path');
    } else {
      stdout.writeln(gray('  🚀 Opening in $editor...'));
    }
    final result = await Process.run(command, [path]);
    if (result.exitCode != 0) {
      if (headless) {
        stderr.writeln('[nitro:error] failed to open $editor (exit ${result.exitCode})');
        if (editor == 'code') stderr.writeln('[nitro:hint] make sure the "code" command is in your PATH.');
      } else {
        stderr.writeln(red('  ✘ Failed to open $editor (exit ${result.exitCode})'));
        if (editor == 'code') stderr.writeln(gray('    Make sure the "code" command is in your PATH.'));
      }
    }
  } catch (e) {
    if (headless) {
      stderr.writeln('[nitro:error] error launching $editor: $e');
    } else {
      stderr.writeln(red('  ✘ Error launching $editor: $e'));
    }
  }
}
