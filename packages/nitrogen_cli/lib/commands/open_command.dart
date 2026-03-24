import 'dart:io';
import 'package:args/command_runner.dart';
import '../ui.dart';

class OpenCommand extends Command {
  @override
  final String name = 'open';

  @override
  final String description = 'Opens the Nitrogen project in an editor.';

  OpenCommand() {
    argParser.addOption(
      'editor',
      abbr: 'e',
      help: 'The editor to use.',
      allowed: ['code', 'antigravity'],
      defaultsTo: 'code',
    );
  }

  @override
  Future<void> run() async {
    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      stderr.writeln(red('❌ No Nitro project found in . or its subdirectories.'));
      exit(1);
    }

    final editor = argResults?['editor'] as String;
    await openInEditor(editor, projectDir.path);
  }
}

Future<void> openInEditor(String editor, String path) async {
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
    stdout.writeln(gray('  🚀 Opening in $editor...'));
    final result = await Process.run(command, [path]);
    if (result.exitCode != 0) {
      stderr.writeln(red('  ✘ Failed to open $editor (exit ${result.exitCode})'));
      if (editor == 'code') {
        stderr.writeln(gray('    Make sure the "code" command is in your PATH.'));
      }
    }
  } catch (e) {
    stderr.writeln(red('  ✘ Error launching $editor: $e'));
  }
}
