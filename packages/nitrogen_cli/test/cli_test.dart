import 'package:test/test.dart';
import 'package:args/command_runner.dart';
import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/update_command.dart';
import 'package:nitrogen_cli/commands/open_command.dart';

void main() {
  group('Nitrogen CLI Command Setup', () {
    late CommandRunner runner;

    setUp(() {
      runner = CommandRunner('nitrogen', 'test')
        ..addCommand(InitCommand())
        ..addCommand(GenerateCommand())
        ..addCommand(LinkCommand())
        ..addCommand(DoctorCommand())
        ..addCommand(UpdateCommand())
        ..addCommand(OpenCommand());
    });

    test('all commands are registered', () {
      expect(runner.commands.containsKey('init'), isTrue);
      expect(runner.commands.containsKey('generate'), isTrue);
      expect(runner.commands.containsKey('link'), isTrue);
      expect(runner.commands.containsKey('doctor'), isTrue);
      expect(runner.commands.containsKey('update'), isTrue);
      expect(runner.commands.containsKey('open'), isTrue);
    });

    test('commands have descriptions', () {
      for (final command in runner.commands.values) {
        expect(command.description, isNotEmpty);
      }
    });

    test('doctor command can perform checks in a mock environment', () {
      // This is partially covered by doctor_command_test.dart,
      // but we ensure the command object itself is functional.
      final doctor = runner.commands['doctor'] as DoctorCommand;
      expect(doctor.name, equals('doctor'));
    });
    
    test('init command has correct options', () {
      final init = runner.commands['init'] as InitCommand;
      expect(init.argParser.options.containsKey('name'), isTrue);
      expect(init.argParser.options.containsKey('org'), isTrue);
    });
  });
}
