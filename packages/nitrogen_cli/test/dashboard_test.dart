import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:nitrogen_cli/widgets/dashboard.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('NitroDashboard', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('nitro_dashboard_test_');
      resetDashboardState();
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    void scaffoldMonorepo() {
      // root/
      //  packages/
      //    one/ (nitro)
      //    two/ (nitro)
      final pkg = Directory(p.join(temp.path, 'packages'))..createSync();
      final p1 = Directory(p.join(pkg.path, 'one'))..createSync();
      final p2 = Directory(p.join(pkg.path, 'two'))..createSync();

      File(p.join(p1.path, 'pubspec.yaml')).writeAsStringSync('name: one\ndependencies:\n  nitro: any');
      File(p.join(p2.path, 'pubspec.yaml')).writeAsStringSync('name: two\ndependencies:\n  nitro: any');
    }

    test('renders sidebar when multiple projects are found', () async {
      scaffoldMonorepo();

      final prevDir = Directory.current;
      Directory.current = temp;

      try {
        await testNocterm('Dashboard sidebar', (tester) async {
          await tester.pumpComponent(
            const Container(width: 80, height: 24, child: NitroDashboard()),
          );
          await tester.pump();

          // Header should mention project
          expect(tester.terminalState, containsText('Active: one'));
          // Sidebar should be present
          expect(tester.terminalState, containsText('PROJECTS'));
          expect(tester.terminalState, containsText('one'));
          expect(tester.terminalState, containsText('two'));
        });
      } finally {
        Directory.current = prevDir;
      }
    });

    test('switching projects via arrows updates header', () async {
      scaffoldMonorepo();

      final prevDir = Directory.current;
      Directory.current = temp;

      try {
        await testNocterm('Dashboard switch via arrows', (tester) async {
          await tester.pumpComponent(
            const Container(width: 80, height: 24, child: NitroDashboard()),
          );

          expect(tester.terminalState, containsText('Active: one'));

          // Switch focus to sidebar (Tab or Left)
          await tester.sendKey(LogicalKey.arrowLeft);
          await tester.pump();

          // Down to second project
          await tester.sendKey(LogicalKey.arrowDown);
          await tester.pump();

          // Sidebar 'two' should be selected (chevron)
          expect(tester.terminalState, containsText('❯ two'));

          // Header should update
          expect(tester.terminalState, containsText('Active: two'));
        });
      } finally {
        Directory.current = prevDir;
      }
    });

    test('tab cycles focus between Projects and Menu', () async {
      scaffoldMonorepo();

      final prevDir = Directory.current;
      Directory.current = temp;

      try {
        await testNocterm('Dashboard Tab focus', (tester) async {
          await tester.pumpComponent(
            const Container(width: 80, height: 24, child: NitroDashboard()),
          );

          // Initially focus is on Menu (Right side)
          // Command 'Initialize' should have chevron
          expect(tester.terminalState, containsText('❯ Initialize'));

          // Tab to Sidebar
          await tester.sendKey(LogicalKey.tab);
          await tester.pump();

          // Sidebar project 'one' should have chevron
          // Menu command 'Initialize' should now have simple space or dot
          expect(tester.terminalState, containsText('❯ one'));
          expect(tester.terminalState, isNot(containsText('❯ Initialize')));

          // Tab back to Menu
          await tester.sendKey(LogicalKey.tab);
          await tester.pump();

          expect(tester.terminalState, containsText('❯ Initialize'));
        });
      } finally {
        Directory.current = prevDir;
      }
    });

    test('renders Watch menu item', () async {
      await testNocterm('Dashboard Watch menu', (tester) async {
        await tester.pumpComponent(
          const Container(width: 80, height: 24, child: NitroDashboard()),
        );
        expect(tester.terminalState, containsText('Watch'));
        // The description column is narrow — only the first ~18 chars fit before
        // the right edge.  Check a prefix that is always visible.
        expect(tester.terminalState, containsText('Run the Nitro gen'));
      });
    });
  });
}
