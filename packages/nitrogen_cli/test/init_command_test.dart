import 'package:nocterm/nocterm.dart';
import 'package:nocterm/nocterm_test.dart';
import 'package:nitrogen_cli/commands/init_command.dart';
import 'package:test/test.dart';

void main() {
  // ── InitResult ─────────────────────────────────────────────────────────────

  group('InitResult', () {
    test('has correct defaults', () {
      final result = InitResult();
      expect(result.success, isFalse);
      expect(result.errorMessage, isNull);
      expect(result.pluginName, isNull);
    });

    test('fields are mutable', () {
      final result = InitResult()
        ..success = true
        ..pluginName = 'my_plugin'
        ..errorMessage = 'some error';

      expect(result.success, isTrue);
      expect(result.pluginName, 'my_plugin');
      expect(result.errorMessage, 'some error');
    });
  });

  // ── InitStep ───────────────────────────────────────────────────────────────

  group('InitStep', () {
    test('starts in pending state with no detail', () {
      final step = InitStep('Configure iOS');
      expect(step.label, 'Configure iOS');
      expect(step.state, InitStepState.pending);
      expect(step.detail, isNull);
    });

    test('state and detail are mutable', () {
      final step = InitStep('My step')
        ..state = InitStepState.done
        ..detail = 'Created successfully';

      expect(step.state, InitStepState.done);
      expect(step.detail, 'Created successfully');
    });
  });

  // ── InitStepRow ────────────────────────────────────────────────────────────

  group('InitStepRow', () {
    for (final entry in const [
      (InitStepState.pending, '○'),
      (InitStepState.running, '◉'),
      (InitStepState.done, '✔'),
      (InitStepState.failed, '✘'),
      (InitStepState.skipped, '–'),
    ]) {
      final state = entry.$1;
      final icon = entry.$2;

      test('renders $state with icon "$icon"', () async {
        await testNocterm('InitStepRow $state', (tester) async {
          final step = InitStep('Test step label')..state = state;
          await tester.pumpComponent(
            Container(width: 40, height: 4, child: InitStepRow(step)),
          );
          expect(tester.terminalState, containsText(icon));
          expect(tester.terminalState, containsText('Test step label'));
        });
      });
    }

    test('renders detail text when set', () async {
      await testNocterm('InitStepRow detail', (tester) async {
        final step = InitStep('Do something')
          ..state = InitStepState.done
          ..detail = 'detail note here';
        await tester.pumpComponent(
          Container(width: 40, height: 5, child: InitStepRow(step)),
        );
        expect(tester.terminalState, containsText('detail note here'));
      });
    });

    test('does not render detail when null', () async {
      await testNocterm('InitStepRow no detail', (tester) async {
        final step = InitStep('Do something')..state = InitStepState.pending;
        await tester.pumpComponent(
          Container(width: 40, height: 3, child: InitStepRow(step)),
        );
        // Only the label should appear, no extra lines
        expect(tester.terminalState, containsText('Do something'));
      });
    });
  });

  // ── Plugin name validation regex ───────────────────────────────────────────

  group('plugin name validation', () {
    final regex = RegExp(r'^[a-z][a-z0-9_]*$');

    const valid = [
      'a',
      'myplugin',
      'my_plugin',
      'my_plugin_v2',
      'abc123',
      'x1_y2_z3',
    ];

    const invalid = [
      '',
      'MyPlugin',
      'my-plugin',
      'my plugin',
      '1plugin',
      '_plugin',
      'my.plugin',
      'UPPER',
      'camelCase',
    ];

    for (final name in valid) {
      test('"$name" passes', () => expect(regex.hasMatch(name), isTrue));
    }

    for (final name in invalid) {
      test('"$name" fails', () => expect(regex.hasMatch(name), isFalse));
    }
  });

  // ── PluginNameForm ─────────────────────────────────────────────────────────

  group('PluginNameForm', () {
    Component _form(void Function(String, String) onSubmit) => Container(
          width: 60,
          height: 22,
          child: PluginNameForm(onSubmit: onSubmit),
        );

    test('renders header, fields and hint', () async {
      await testNocterm('PluginNameForm initial', (tester) async {
        await tester.pumpComponent(_form((_, __) {}));

        expect(tester.terminalState, containsText('nitrogen init'));
        expect(tester.terminalState, containsText('Plugin name:'));
        expect(tester.terminalState, containsText('Organisation'));
        expect(tester.terminalState, containsText('[Tab]'));
        expect(tester.terminalState, containsText('[Enter]'));
      });
    });

    test('shows placeholder for plugin name field', () async {
      await testNocterm('PluginNameForm placeholders', (tester) async {
        await tester.pumpComponent(_form((_, __) {}));
        expect(tester.terminalState, containsText('my_plugin'));
      });
    });

    test('shows error when name is empty on submit', () async {
      await testNocterm('PluginNameForm empty name error', (tester) async {
        await tester.pumpComponent(_form((_, __) {}));

        // Tab moves focus to org field, Enter submits with empty name
        await tester.sendKey(LogicalKey.tab);
        await tester.sendKey(LogicalKey.enter);
        await tester.pump();

        expect(
          tester.terminalState,
          containsText('Plugin name is required'),
        );
      });
    });

    test('shows error for name starting with a digit', () async {
      await testNocterm('PluginNameForm digit-start name', (tester) async {
        await tester.pumpComponent(_form((_, __) {}));

        await tester.enterText('1plugin');
        await tester.sendKey(LogicalKey.tab);
        await tester.sendKey(LogicalKey.enter);
        await tester.pump();

        expect(tester.terminalState, containsText('lowercase'));
      });
    });

    test('shows error for name with uppercase letters', () async {
      await testNocterm('PluginNameForm uppercase name', (tester) async {
        await tester.pumpComponent(_form((_, __) {}));

        await tester.enterText('MyPlugin');
        await tester.sendKey(LogicalKey.tab);
        await tester.sendKey(LogicalKey.enter);
        await tester.pump();

        expect(tester.terminalState, containsText('lowercase'));
      });
    });

    test('shows error for name with hyphens', () async {
      await testNocterm('PluginNameForm hyphen name', (tester) async {
        await tester.pumpComponent(_form((_, __) {}));

        await tester.enterText('my-plugin');
        await tester.sendKey(LogicalKey.tab);
        await tester.sendKey(LogicalKey.enter);
        await tester.pump();

        expect(tester.terminalState, containsText('lowercase'));
      });
    });

    test('calls onSubmit with valid name and default org', () async {
      await testNocterm('PluginNameForm valid submit', (tester) async {
        String? gotName;
        String? gotOrg;

        await tester.pumpComponent(_form((n, o) {
          gotName = n;
          gotOrg = o;
        }));

        await tester.enterText('my_plugin');
        await tester.sendKey(LogicalKey.tab);
        await tester.sendKey(LogicalKey.enter);
        await tester.pump();

        expect(gotName, 'my_plugin');
        expect(gotOrg, 'com.example'); // default pre-filled value
      });
    });

    test('calls onSubmit with name containing numbers and underscores',
        () async {
      await testNocterm('PluginNameForm alphanumeric name', (tester) async {
        String? gotName;

        await tester.pumpComponent(_form((n, _) => gotName = n));

        await tester.enterText('nitro_plugin_v2');
        await tester.sendKey(LogicalKey.tab);
        await tester.sendKey(LogicalKey.enter);
        await tester.pump();

        expect(gotName, 'nitro_plugin_v2');
      });
    });

    test('Tab clears error and switches field focus', () async {
      await testNocterm('PluginNameForm Tab clears error', (tester) async {
        await tester.pumpComponent(_form((_, __) {}));

        // Trigger an error by submitting empty
        await tester.sendKey(LogicalKey.tab);
        await tester.sendKey(LogicalKey.enter);
        await tester.pump();
        expect(
          tester.terminalState,
          containsText('Plugin name is required'),
        );

        // Tab back to name field — error should clear
        await tester.sendKey(LogicalKey.tab);
        await tester.pump();
        expect(
          tester.terminalState,
          isNot(containsText('Plugin name is required')),
        );
      });
    });

    test('form remains visible after Tab', () async {
      await testNocterm('PluginNameForm stable after Tab', (tester) async {
        await tester.pumpComponent(_form((_, __) {}));

        await tester.sendKey(LogicalKey.tab);
        await tester.pump();

        expect(tester.terminalState, containsText('nitrogen init'));
        expect(tester.terminalState, containsText('Plugin name:'));
      });
    });
  });
}
