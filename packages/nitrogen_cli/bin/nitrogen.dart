import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';

void main(List<String> args) async {
  final runner = CommandRunner('nitrogen', 'CLI for scaffolding and generating Nitrogen FFI plugins.')
    ..addCommand(InitCommand())
    ..addCommand(GenerateCommand())
    ..addCommand(LinkCommand())
    ..addCommand(DoctorCommand());

  try {
    await runner.run(args);
  } catch (e) {
    stderr.writeln(e);
    exit(1);
  }
}
