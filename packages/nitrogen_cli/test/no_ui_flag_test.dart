import 'package:args/command_runner.dart';
import 'package:nitrogen_cli/commands/clean_command.dart';
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/generate_command.dart';
import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/commands/migrate_command.dart';
import 'package:nitrogen_cli/commands/open_command.dart';
import 'package:nitrogen_cli/commands/update_command.dart';
import 'package:nitrogen_cli/commands/watch_command.dart';
import 'package:test/test.dart';

// All commands that must support --no-ui.
List<Command> _allCommands() => [
      CleanCommand(),
      DoctorCommand(),
      GenerateCommand(),
      InitCommand(),
      LinkCommand(),
      MigrateCommand(),
      OpenCommand(),
      UpdateCommand(),
      WatchCommand(),
    ];

void main() {
  // ── Flag registration ──────────────────────────────────────────────────────

  group('--no-ui flag registration', () {
    for (final cmd in _allCommands()) {
      final name = cmd.name;
      test('$name has --no-ui flag', () {
        expect(
          cmd.argParser.options.containsKey('no-ui'),
          isTrue,
          reason: '$name is missing --no-ui flag',
        );
      });
    }
  });

  // ── Flag properties ────────────────────────────────────────────────────────

  group('--no-ui flag properties', () {
    for (final cmd in _allCommands()) {
      final name = cmd.name;

      test('$name --no-ui defaults to false', () {
        final results = cmd.argParser.parse([]);
        expect(results['no-ui'], isFalse, reason: '$name --no-ui should default to false');
      });

      test('$name --no-ui is true when passed', () {
        final results = cmd.argParser.parse(['--no-ui']);
        expect(results['no-ui'], isTrue);
      });

      test('$name has no --ui negation (negatable: false)', () {
        // negatable: false means --ui is not a valid flag.
        expect(
          () => cmd.argParser.parse(['--ui']),
          throwsFormatException,
          reason: '$name should not accept --ui (negatable: false)',
        );
      });
    }
  });

  // ── init-specific arg parsing ──────────────────────────────────────────────

  group('InitCommand --no-ui arg parsing', () {
    test('--no-ui --name=foo parses both flags correctly', () {
      final cmd = InitCommand();
      final r = cmd.argParser.parse(['--no-ui', '--name', 'my_plugin']);
      expect(r['no-ui'], isTrue);
      expect(r['name'], equals('my_plugin'));
    });

    test('--no-ui without --name leaves name null', () {
      final cmd = InitCommand();
      final r = cmd.argParser.parse(['--no-ui']);
      expect(r['no-ui'], isTrue);
      expect(r['name'], isNull);
    });

    test('--no-ui --name --platforms parses platform list', () {
      final cmd = InitCommand();
      final r = cmd.argParser.parse(['--no-ui', '--name', 'foo', '--platforms', 'android,ios']);
      expect(r['no-ui'], isTrue);
      expect(r['platforms'], equals('android,ios'));
    });

    test('--no-ui --name --org --dir all parse together', () {
      final cmd = InitCommand();
      final r = cmd.argParser.parse([
        '--no-ui',
        '--name', 'my_pkg',
        '--org', 'com.example',
        '--dir', '/tmp',
      ]);
      expect(r['no-ui'], isTrue);
      expect(r['name'], equals('my_pkg'));
      expect(r['org'], equals('com.example'));
      expect(r['dir'], equals('/tmp'));
    });

    test('default platforms value is set when --platforms omitted', () {
      final cmd = InitCommand();
      final r = cmd.argParser.parse(['--no-ui', '--name', 'foo']);
      // Default is all five platforms
      final platforms = r['platforms'] as String;
      expect(platforms, contains('android'));
      expect(platforms, contains('ios'));
      expect(platforms, contains('macos'));
    });
  });

  // ── link-specific arg parsing ──────────────────────────────────────────────

  group('LinkCommand --no-ui arg parsing', () {
    test('link has --yes flag alongside --no-ui', () {
      final cmd = LinkCommand();
      expect(cmd.argParser.options.containsKey('yes'), isTrue);
    });

    test('--no-ui and --yes can be combined', () {
      final cmd = LinkCommand();
      final r = cmd.argParser.parse(['--no-ui', '--yes']);
      expect(r['no-ui'], isTrue);
      expect(r['yes'], isTrue);
    });

    test('--no-ui alone parses without --yes', () {
      final cmd = LinkCommand();
      final r = cmd.argParser.parse(['--no-ui']);
      expect(r['no-ui'], isTrue);
      expect(r['yes'], isFalse);
    });
  });

  // ── migrate-specific arg parsing ───────────────────────────────────────────

  group('MigrateCommand --no-ui arg parsing', () {
    test('--no-ui alongside --backup and --dry-run', () {
      final cmd = MigrateCommand();
      final r = cmd.argParser.parse(['--no-ui', '--backup', '--dry-run']);
      expect(r['no-ui'], isTrue);
      expect(r['backup'], isTrue);
      expect(r['dry-run'], isTrue);
    });

    test('--no-ui alone keeps --backup default (true) and --dry-run default (false)', () {
      final cmd = MigrateCommand();
      final r = cmd.argParser.parse(['--no-ui']);
      expect(r['no-ui'], isTrue);
      expect(r['backup'], isTrue);   // backup defaults to true
      expect(r['dry-run'], isFalse); // dry-run defaults to false
    });
  });

  // ── updateCMakeNitroNative — pure function ─────────────────────────────────

  group('updateCMakeNitroNative', () {
    test('replaces NITRO_NATIVE path', () {
      const content = 'set(NITRO_NATIVE "old/path")\nother content';
      final result = updateCMakeNitroNative(content, 'new/path');
      expect(result, contains('set(NITRO_NATIVE "new/path")'));
      expect(result, isNot(contains('"old/path"')));
      expect(result, contains('other content'));
    });

    test('returns content unchanged when no NITRO_NATIVE line exists', () {
      const content = 'add_library(my_plugin SHARED main.cpp)\n';
      final result = updateCMakeNitroNative(content, 'any/path');
      expect(result, equals(content));
    });

    test('is idempotent — applying twice gives the same result', () {
      const content = 'set(NITRO_NATIVE "orig/path")\nfoo = bar';
      const newPath = 'my/resolved/path';
      final once = updateCMakeNitroNative(content, newPath);
      final twice = updateCMakeNitroNative(once, newPath);
      expect(twice, equals(once));
    });

    test('handles absolute paths with spaces', () {
      const content = 'set(NITRO_NATIVE "old")\n';
      final result = updateCMakeNitroNative(content, '/Users/me/path with spaces/native');
      expect(result, contains('set(NITRO_NATIVE "/Users/me/path with spaces/native")'));
    });

    test('replaces only the first occurrence', () {
      const content =
          'set(NITRO_NATIVE "first")\n'
          '# comment: set(NITRO_NATIVE "second")\n';
      final result = updateCMakeNitroNative(content, 'replaced');
      expect(result, contains('set(NITRO_NATIVE "replaced")'));
      // The comment line must still have "second" (replaceFirst semantics).
      expect(result, contains('"second"'));
    });

    test('handles empty path replacement', () {
      const content = 'set(NITRO_NATIVE "non-empty")\n';
      final result = updateCMakeNitroNative(content, '');
      expect(result, contains('set(NITRO_NATIVE "")'));
    });
  });

  // ── cross-command consistency ──────────────────────────────────────────────

  group('--no-ui cross-command consistency', () {
    test('every command name is non-empty', () {
      for (final cmd in _allCommands()) {
        expect(cmd.name, isNotEmpty);
      }
    });

    test('--no-ui help text is present on every command', () {
      for (final cmd in _allCommands()) {
        final opt = cmd.argParser.options['no-ui']!;
        expect(
          opt.help,
          isNotEmpty,
          reason: '${cmd.name} --no-ui has no help text',
        );
      }
    });

    test('all commands can be registered in a CommandRunner without conflict', () {
      expect(
        () => CommandRunner<void>('nitrogen', 'test')
          ..addCommand(CleanCommand())
          ..addCommand(DoctorCommand())
          ..addCommand(GenerateCommand())
          ..addCommand(InitCommand())
          ..addCommand(LinkCommand())
          ..addCommand(MigrateCommand())
          ..addCommand(OpenCommand())
          ..addCommand(UpdateCommand())
          ..addCommand(WatchCommand()),
        returnsNormally,
      );
    });
  });
}
