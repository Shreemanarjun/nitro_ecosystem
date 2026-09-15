import 'dart:io';

import 'package:nitrogen_cli/utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // Directory.listSync() order is filesystem-specific (alphabetical on APFS,
  // hash order on ext4): discovery must sort so the dashboard's "active"
  // project and sidebar order are the same on every platform (CI on Linux
  // caught this).
  test('projects are discovered in path order regardless of filesystem order', () {
    final tmp = Directory.systemTemp.createTempSync('nitro_discovery_order_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    for (final rel in ['zeta', 'alpha', 'packages/mid']) {
      final dir = Directory(p.join(tmp.path, rel))..createSync(recursive: true);
      File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('name: ${p.basename(rel)}\ndependencies:\n  nitro: any\n');
    }
    expect(getAllProjects(baseDir: tmp).map((info) => info.name).toList(), ['alpha', 'mid', 'zeta']);
  });
}
