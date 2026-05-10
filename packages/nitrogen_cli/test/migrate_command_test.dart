import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:nitrogen_cli/commands/migrate_command.dart';
import 'package:nitrogen_cli/commands/spm_utils.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Creates a minimal CocoaPods-only plugin scaffold.
Directory _scaffoldLegacy({bool withIos = true, bool withMacos = false}) {
  final root = Directory.systemTemp.createTempSync('migrate_test_');
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: my_plugin\n');

  if (withIos) {
    final iosDir = Directory(p.join(root.path, 'ios'))..createSync();
    File(p.join(iosDir.path, 'my_plugin.podspec')).writeAsStringSync('# podspec');
    Directory(p.join(iosDir.path, 'Classes')).createSync();
  }
  if (withMacos) {
    final macosDir = Directory(p.join(root.path, 'macos'))..createSync();
    File(p.join(macosDir.path, 'my_plugin.podspec')).writeAsStringSync('# podspec');
    Directory(p.join(macosDir.path, 'Classes')).createSync();
  }
  return root;
}

/// Creates a minimal modern SPM-only plugin scaffold.
Directory _scaffoldModern({bool withIos = true, bool withMacos = false}) {
  final root = Directory.systemTemp.createTempSync('migrate_modern_test_');
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: my_plugin\n');

  if (withIos) {
    final pkgDir = Directory(p.join(root.path, 'ios', 'my_plugin'))..createSync(recursive: true);
    File(p.join(pkgDir.path, 'Package.swift')).writeAsStringSync('// swift-tools-version: 5.9');
  }
  if (withMacos) {
    final pkgDir = Directory(p.join(root.path, 'macos', 'my_plugin'))..createSync(recursive: true);
    File(p.join(pkgDir.path, 'Package.swift')).writeAsStringSync('// swift-tools-version: 5.9');
  }
  return root;
}

void main() {
  // ── MigrationResult ────────────────────────────────────────────────────────

  group('MigrationResult', () {
    test('defaults: success is false, lists are empty', () {
      final r = MigrationResult();
      expect(r.success, isFalse);
      expect(r.errorMessage, isNull);
      expect(r.backupPaths, isEmpty);
      expect(r.migratedPlatforms, isEmpty);
    });

    test('fields are mutable', () {
      final r = MigrationResult()
        ..success = true
        ..errorMessage = 'oops'
        ..backupPaths = ['a', 'b']
        ..migratedPlatforms = ['ios'];

      expect(r.success, isTrue);
      expect(r.errorMessage, 'oops');
      expect(r.backupPaths, ['a', 'b']);
      expect(r.migratedPlatforms, ['ios']);
    });
  });

  // ── MigrationStep ─────────────────────────────────────────────────────────

  group('MigrationStep', () {
    test('starts in pending state', () {
      final step = MigrationStep('Backup');
      expect(step.label, 'Backup');
      expect(step.state, MigrationStepState.pending);
      expect(step.detail, isNull);
    });

    test('all states are reachable', () {
      final step = MigrationStep('Test');
      for (final state in MigrationStepState.values) {
        step.state = state;
        expect(step.state, state);
      }
    });

    test('detail can be set', () {
      final step = MigrationStep('Step')..detail = 'some info';
      expect(step.detail, 'some info');
    });
  });

  // ── MigrationStepState ────────────────────────────────────────────────────

  group('MigrationStepState values', () {
    test('all expected states exist', () {
      expect(
        MigrationStepState.values.map((s) => s.name),
        containsAll(['pending', 'running', 'done', 'failed', 'skipped']),
      );
    });
  });

  // ── MigrationStepRow component ────────────────────────────────────────────

  group('MigrationStepRow', () {
    Component row(MigrationStepState state, {String? detail}) {
      final step = MigrationStep('My step')
        ..state = state
        ..detail = detail;
      return Container(
        width: 40,
        height: 4,
        child: MigrationStepRow(step),
      );
    }

    test('pending renders ○', () async {
      await testNocterm('MigrationStepRow pending', (tester) async {
        await tester.pumpComponent(row(MigrationStepState.pending));
        expect(tester.terminalState, containsText('○'));
        expect(tester.terminalState, containsText('My step'));
      });
    });

    test('running renders ◉', () async {
      await testNocterm('MigrationStepRow running', (tester) async {
        await tester.pumpComponent(row(MigrationStepState.running));
        expect(tester.terminalState, containsText('◉'));
      });
    });

    test('done renders ✔', () async {
      await testNocterm('MigrationStepRow done', (tester) async {
        await tester.pumpComponent(row(MigrationStepState.done));
        expect(tester.terminalState, containsText('✔'));
      });
    });

    test('failed renders ✘', () async {
      await testNocterm('MigrationStepRow failed', (tester) async {
        await tester.pumpComponent(row(MigrationStepState.failed));
        expect(tester.terminalState, containsText('✘'));
      });
    });

    test('skipped renders –', () async {
      await testNocterm('MigrationStepRow skipped', (tester) async {
        await tester.pumpComponent(row(MigrationStepState.skipped));
        expect(tester.terminalState, containsText('–'));
      });
    });

    test('detail text is shown when set', () async {
      await testNocterm('MigrationStepRow detail', (tester) async {
        await tester.pumpComponent(row(MigrationStepState.done, detail: 'file backed up'));
        expect(tester.terminalState, containsText('file backed up'));
      });
    });

    test('no detail shown when null', () async {
      await testNocterm('MigrationStepRow no detail', (tester) async {
        await tester.pumpComponent(row(MigrationStepState.pending));
        expect(tester.terminalState, isNot(containsText('backed up')));
      });
    });
  });

  // ── MigrateView — already modern ─────────────────────────────────────────

  group('MigrateView — already modern (SPM-only)', () {
    test('shows skipped steps when plugin is already SPM-only', () async {
      final tmp = _scaffoldModern(withIos: true);
      addTearDown(() => tmp.deleteSync(recursive: true));

      final spmStatus = detectSpmStatus(tmp.path);
      expect(spmStatus.isModern, isTrue);

      final result = MigrationResult();
      await testNocterm('MigrateView modern', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 20,
            child: MigrateView(
              pluginName: 'my_plugin',
              result: result,
              spmStatus: spmStatus,
              onExit: () {},
            ),
          ),
        );

        await tester.pump(); // allow initState Future to run
        await tester.pump();

        expect(tester.terminalState, containsText('nitrogen migrate'));
      });
      expect(result.success, isTrue);
    });
  });

  // ── MigrateView — legacy (CocoaPods only) confirmation prompt ─────────────

  group('MigrateView — legacy plugin requires confirmation', () {
    test('shows confirmation prompt for CocoaPods-only plugin', () async {
      final tmp = _scaffoldLegacy(withIos: true);
      addTearDown(() => tmp.deleteSync(recursive: true));

      final spmStatus = detectSpmStatus(tmp.path);
      expect(spmStatus.isLegacy, isTrue);

      await testNocterm('MigrateView legacy confirm', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 70,
            height: 20,
            child: MigrateView(
              pluginName: 'my_plugin',
              result: MigrationResult(),
              spmStatus: spmStatus,
              onExit: () {},
            ),
          ),
        );

        await tester.pump();
        await tester.pump();

        // Should show the confirmation prompt
        expect(tester.terminalState, containsText('[Y]'));
        expect(tester.terminalState, containsText('[N]'));
      });
    });

    test('ESC / N cancels migration from confirmation', () async {
      final tmp = _scaffoldLegacy(withIos: true);
      addTearDown(() => tmp.deleteSync(recursive: true));

      final spmStatus = detectSpmStatus(tmp.path);
      var exited = false;

      await testNocterm('MigrateView cancel', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 70,
            height: 20,
            child: MigrateView(
              pluginName: 'my_plugin',
              result: MigrationResult(),
              spmStatus: spmStatus,
              onExit: () => exited = true,
            ),
          ),
        );

        await tester.pump();
        await tester.pump();

        await tester.sendKey(LogicalKey.keyN);
        await tester.pump();

        expect(exited, isTrue);
      });
    });
  });

  // ── MigrateView — ESC exits after completion ──────────────────────────────

  group('MigrateView — ESC handling', () {
    test('ESC calls onExit when already modern', () async {
      final tmp = _scaffoldModern(withIos: true);
      addTearDown(() => tmp.deleteSync(recursive: true));

      final spmStatus = detectSpmStatus(tmp.path);
      var exited = false;

      await testNocterm('MigrateView ESC modern', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 20,
            child: MigrateView(
              pluginName: 'my_plugin',
              result: MigrationResult(),
              spmStatus: spmStatus,
              onExit: () => exited = true,
            ),
          ),
        );

        await tester.pump();
        await tester.pump();

        await tester.sendKey(LogicalKey.escape);
        await tester.pump();

        expect(exited, isTrue);
      });
    });
  });

  // ── MigrateCommand ────────────────────────────────────────────────────────

  group('MigrateCommand', () {
    test('name is "migrate"', () {
      expect(MigrateCommand().name, 'migrate');
    });

    test('description is not empty', () {
      expect(MigrateCommand().description, isNotEmpty);
    });

    test('has --backup flag defaulting to true', () {
      final cmd = MigrateCommand();
      expect(cmd.argParser.options.containsKey('backup'), isTrue);
      expect(cmd.argParser.options['backup']!.defaultsTo, isTrue);
    });

    test('has --dry-run flag defaulting to false', () {
      final cmd = MigrateCommand();
      expect(cmd.argParser.options.containsKey('dry-run'), isTrue);
      expect(cmd.argParser.options['dry-run']!.defaultsTo, isFalse);
    });
  });

  // ── _createPackageSwift via migration ─────────────────────────────────────
  // We test the filesystem outcomes produced by running a migration on a
  // temporary CocoaPods-only scaffold.

  group('migration filesystem outcomes — nested layout', () {
    late Directory tmp;
    late Directory originalDir;

    setUp(() {
      originalDir = Directory.current;
      tmp = _scaffoldLegacy(withIos: true);
    });

    tearDown(() {
      Directory.current = originalDir;
      tmp.deleteSync(recursive: true);
    });

    test('creates ios/<pluginName>/Package.swift in nested layout', () async {
      Directory.current = tmp;

      final spmStatus = detectSpmStatus(tmp.path);
      final result = MigrationResult();

      await testNocterm('migration nested layout', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 70,
            height: 24,
            child: MigrateView(
              pluginName: 'my_plugin',
              result: result,
              spmStatus: spmStatus,
              createBackup: false, // skip backup for speed
              onExit: () {},
            ),
          ),
        );

        await tester.pump();
        await tester.pump(); // state: confirmation shown

        // Confirm migration
        await tester.sendKey(LogicalKey.keyY);
        await tester.pump();
        await tester.pump();
        await tester.pump();
      });

      // Package.swift should be at nested path
      expect(
        File(p.join(tmp.path, 'ios', 'my_plugin', 'Package.swift')).existsSync(),
        isTrue,
        reason: 'ios/my_plugin/Package.swift should exist after migration',
      );

      // NOT at flat path
      expect(
        File(p.join(tmp.path, 'ios', 'Package.swift')).existsSync(),
        isFalse,
        reason: 'ios/Package.swift (flat) should NOT exist after migration',
      );
    });

    test('creates Sources directory structure inside nested package dir', () async {
      Directory.current = tmp;

      final spmStatus = detectSpmStatus(tmp.path);

      await testNocterm('migration sources', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 70,
            height: 24,
            child: MigrateView(
              pluginName: 'my_plugin',
              result: MigrationResult(),
              spmStatus: spmStatus,
              createBackup: false,
              onExit: () {},
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.sendKey(LogicalKey.keyY);
        await tester.pump();
        await tester.pump();
        await tester.pump();
      });

      expect(
        Directory(p.join(tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPlugin')).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPluginCpp')).existsSync(),
        isTrue,
      );
    });

    test('result.migratedPlatforms contains "ios" after migration', () async {
      Directory.current = tmp;

      final spmStatus = detectSpmStatus(tmp.path);
      final result = MigrationResult();

      await testNocterm('migration platforms', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 70,
            height: 24,
            child: MigrateView(
              pluginName: 'my_plugin',
              result: result,
              spmStatus: spmStatus,
              createBackup: false,
              onExit: () {},
            ),
          ),
        );

        await tester.pump();
        await tester.pump();
        await tester.sendKey(LogicalKey.keyY);
        await tester.pump();
        await tester.pump();
        await tester.pump();
      });

      expect(result.migratedPlatforms, contains('ios'));
      expect(result.success, isTrue);
    });
  });
}
