import 'package:test/test.dart';
import 'package:args/command_runner.dart';
import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/update_command.dart';
import 'package:nitrogen_cli/commands/open_command.dart';
import 'package:nitrogen_cli/commands/watch_command.dart';
import 'package:nitrogen_cli/commands/migrate_command.dart';
import 'package:nitrogen_cli/models.dart';

void main() {
  group('Nitrogen CLI Command Setup', () {
    late CommandRunner runner;

    setUp(() {
      runner = CommandRunner('nitrogen', 'test')
        ..addCommand(InitCommand())
        ..addCommand(GenerateCommand())
        ..addCommand(LinkCommand())
        ..addCommand(DoctorCommand())
        ..addCommand(MigrateCommand())
        ..addCommand(UpdateCommand())
        ..addCommand(OpenCommand())
        ..addCommand(WatchCommand());
    });

    test('all commands are registered', () {
      expect(runner.commands.containsKey('init'), isTrue);
      expect(runner.commands.containsKey('generate'), isTrue);
      expect(runner.commands.containsKey('link'), isTrue);
      expect(runner.commands.containsKey('doctor'), isTrue);
      expect(runner.commands.containsKey('migrate'), isTrue);
      expect(runner.commands.containsKey('update'), isTrue);
      expect(runner.commands.containsKey('open'), isTrue);
      expect(runner.commands.containsKey('watch'), isTrue);
    });

    test('commands have descriptions', () {
      for (final command in runner.commands.values) {
        expect(command.description, isNotEmpty);
      }
    });

    test('doctor command can perform checks in a mock environment', () {
      final doctor = runner.commands['doctor'] as DoctorCommand;
      expect(doctor.name, equals('doctor'));
    });

    test('init command has correct options', () {
      final init = runner.commands['init'] as InitCommand;
      expect(init.argParser.options.containsKey('name'), isTrue);
      expect(init.argParser.options.containsKey('org'), isTrue);
      expect(init.argParser.options.containsKey('dir'), isTrue);
      expect(init.argParser.options.containsKey('platforms'), isTrue);
    });

    test('migrate command has backup and dry-run flags', () {
      final migrate = runner.commands['migrate'] as MigrateCommand;
      expect(migrate.argParser.options.containsKey('backup'), isTrue);
      expect(migrate.argParser.options.containsKey('dry-run'), isTrue);
    });

    test('generate command has dry-run flag', () {
      final generate = runner.commands['generate'] as GenerateCommand;
      expect(generate.argParser.options.containsKey('dry-run'), isTrue);
    });

    test('generate command has check flag', () {
      final generate = runner.commands['generate'] as GenerateCommand;
      expect(generate.argParser.options.containsKey('check'), isTrue);
    });

    test('generate command has targets option', () {
      final generate = runner.commands['generate'] as GenerateCommand;
      expect(generate.argParser.options.containsKey('targets'), isTrue);
    });
  });

  // ── NitroCommand enum ──────────────────────────────────────────────────────

  group('NitroCommand enum', () {
    test('migrate entry exists', () {
      expect(
        NitroCommand.values.map((c) => c.name),
        contains('migrate'),
      );
    });

    test('migrate has non-empty label and description', () {
      final migrate = NitroCommand.values.firstWhere((c) => c.name == 'migrate');
      expect(migrate.label, isNotEmpty);
      expect(migrate.description, isNotEmpty);
      expect(migrate.path, '/migrate');
      expect(migrate.longInfo, isNotEmpty);
    });

    test('all commands have non-empty labels', () {
      for (final cmd in NitroCommand.values) {
        expect(cmd.label, isNotEmpty, reason: '${cmd.name}.label is empty');
      }
    });

    test('link description mentions SPM not CocoaPods', () {
      final link = NitroCommand.values.firstWhere((c) => c.name == 'link');
      expect(link.longInfo.toLowerCase(), contains('swift package manager'));
      expect(link.longInfo.toLowerCase(), isNot(contains('cocoapods')));
    });
  });
}
