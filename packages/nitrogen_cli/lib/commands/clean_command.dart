import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../ui.dart';

class CleanCommand extends Command {
  CleanCommand() {
    argParser.addFlag(
      'no-ui',
      negatable: false,
      help: 'Plain-text headless output (no ANSI). Auto-enabled when stdout is not a TTY.',
    );
  }

  @override
  final String name = 'clean';

  @override
  final String description = 'Deletes all Nitrogen-generated files and the build_runner cache.';

  bool get _headless => !stdout.hasTerminal || (argResults!['no-ui'] as bool);

  @override
  Future<void> run() async {
    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      stderr.writeln('No Nitro project found in . or its subdirectories.');
      exit(1);
    }

    final headless = _headless;
    var deleted = 0;

    // Patterns that identify Nitrogen-generated files.
    bool isGenerated(String path) {
      final base = p.basename(path);
      return base.endsWith('.g.dart') ||
          base.endsWith('.bridge.g.swift') ||
          base.endsWith('.bridge.g.kt') ||
          base.endsWith('.bridge.g.h') ||
          (base.startsWith('Hybrid') && (base.endsWith('.hpp') || base.endsWith('.cpp')));
    }

    // Walk the project tree and delete generated files.
    // Skip .dart_tool and hidden dirs except when explicitly targeting them.
    void walk(Directory dir) {
      try {
        for (final entity in dir.listSync()) {
          final name = p.basename(entity.path);
          if (name.startsWith('.') || name == 'build') continue;
          if (entity is Directory) {
            walk(entity);
          } else if (entity is File && isGenerated(entity.path)) {
            final rel = p.relative(entity.path, from: projectDir.path);
            entity.deleteSync();
            if (headless) {
              stdout.writeln('[nitro:clean] deleted $rel');
            } else {
              stdout.writeln('  ${red('−')} $rel');
            }
            deleted++;
          }
        }
      } catch (_) {}
    }

    if (!headless) {
      stdout.writeln('');
      stdout.writeln(boldCyan('  ╔══════════════════════════╗'));
      stdout.writeln(boldCyan('  ║  nitrogen clean          ║'));
      stdout.writeln(boldCyan('  ╚══════════════════════════╝'));
      stdout.writeln('');
    }

    walk(projectDir);

    // Also delete build_runner lock + asset graph so the next run starts fresh.
    final buildDir = Directory(p.join(projectDir.path, '.dart_tool', 'build'));
    for (final name in ['lock', 'asset_graph.json']) {
      final f = File(p.join(buildDir.path, name));
      if (f.existsSync()) {
        f.deleteSync();
        final rel = p.relative(f.path, from: projectDir.path);
        if (headless) {
          stdout.writeln('[nitro:clean] deleted $rel');
        } else {
          stdout.writeln('  ${red('−')} $rel');
        }
      }
    }

    if (headless) {
      stdout.writeln('[nitro] $deleted generated file(s) removed');
    } else {
      stdout.writeln('');
      if (deleted == 0) {
        stdout.writeln(gray('  Nothing to clean — no generated files found.'));
      } else {
        stdout.writeln(boldGreen('  ✓ $deleted generated file(s) removed.'));
      }
      stdout.writeln('');
    }
  }
}
