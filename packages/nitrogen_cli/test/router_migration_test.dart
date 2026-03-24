import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';
import 'package:unrouter/nocterm.dart';

import '../bin/nitrogen.dart' as app;

void main() {
  test('dashboard renders and init route remains reachable', () async {
    await testNocterm('nitrogen unrouter 0.13 migration', (tester) async {
      await app.router.replace('/');
      final view = Container(
        width: 80,
        height: 28,
        child: RouterView(router: app.router),
      );

      await tester.pumpComponent(view);
      expect(tester.terminalState, containsText('Nitrogen CLI'));

      await app.router.push('/init');
      await tester.pumpComponent(view);
      expect(tester.terminalState, containsText('Plugin name:'));

      await app.router.replace('/');
    });
  });
}
