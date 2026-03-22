import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/update_command.dart';
import 'package:nitrogen_cli/ui.dart';

// ── Help screen (plain ANSI — stays in scroll buffer) ─────────────────────────

void _printHelp() {
  stdout.writeln('');
  stdout.writeln(boldCyan('  ╔═════════════════════════════════════════════╗'));
  stdout.writeln(boldCyan('  ║  ⚡ nitrogen — Nitrogen FFI plugin toolkit  ║'));
  stdout.writeln(boldCyan('  ╚═════════════════════════════════════════════╝'));
  stdout.writeln('');
  stdout.writeln('  ${bold("Commands")}');
  stdout.writeln('  ─────────────────────────────────────────────────');
  stdout.writeln('  ${green("init   <name>")}   Scaffold a new Nitrogen FFI plugin');
  stdout.writeln('  ${yellow("generate    ")}   Run code generator (build_runner)');
  stdout.writeln('  ${blue("link        ")}   Wire bridges into the build system');
  stdout.writeln('  ${magenta("doctor      ")}   Check plugin is production-ready');
  stdout.writeln('  ${cyan("update      ")}   Self-update the nitrogen CLI');
  stdout.writeln('');
  stdout.writeln(gray('  Usage: nitrogen <command> [arguments]'));
  stdout.writeln(gray('         nitrogen help <command>'));
  stdout.writeln('');
}

// ── Entry point ───────────────────────────────────────────────────────────────

void main(List<String> args) async {
  final showHelp = args.isEmpty ||
      args.first == '--help' ||
      args.first == '-h' ||
      args.first == 'help' && args.length == 1;

  if (showHelp) {
    _printHelp();
    return;
  }

  final runner =
      CommandRunner('nitrogen', 'CLI for scaffolding and generating Nitrogen FFI plugins.')
        ..addCommand(InitCommand())
        ..addCommand(GenerateCommand())
        ..addCommand(LinkCommand())
        ..addCommand(DoctorCommand())
        ..addCommand(UpdateCommand());

  try {
    await runner.run(args);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}
