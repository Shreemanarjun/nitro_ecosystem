// `pkill -f build_runner` matched EVERY build_runner on the machine — another
// checkout, a teammate on a shared box, a sibling job on the same CI runner.
// The kill is now scoped to processes whose working directory is inside the
// project being generated.
import 'dart:io';

import 'package:nitrogen_cli/utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory other;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nitro_kill_scope_mine_');
    other = Directory.systemTemp.createTempSync('nitro_kill_scope_other_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (other.existsSync()) other.deleteSync(recursive: true);
  });

  test('a process in ANOTHER project is never selected', () {
    final pids = selectProjectBuildRunnerPids({'111': other.path}, root.path);
    expect(pids, isEmpty, reason: 'that build_runner belongs to a different checkout');
  });

  test('a process in the project itself is selected', () {
    expect(selectProjectBuildRunnerPids({'222': root.path}, root.path), ['222']);
  });

  test('a process in a SUBDIRECTORY of the project is selected', () {
    final nested = Directory(p.join(root.path, 'example'))..createSync();
    expect(selectProjectBuildRunnerPids({'333': nested.path}, root.path), ['333']);
  });

  test('a sibling directory sharing a name prefix is NOT selected', () {
    // `/tmp/proj` must not match `/tmp/proj2` — a plain startsWith would.
    final sibling = Directory('${root.path}2')..createSync();
    addTearDown(() => sibling.deleteSync(recursive: true));
    expect(selectProjectBuildRunnerPids({'444': sibling.path}, root.path), isEmpty);
  });

  test('a process whose cwd could not be read is not selected', () {
    expect(selectProjectBuildRunnerPids({'555': ''}, root.path), isEmpty);
  });

  test('only the matching pids come back from a mixed set', () {
    final nested = Directory(p.join(root.path, 'sub'))..createSync();
    final pids = selectProjectBuildRunnerPids({
      '1': other.path,
      '2': root.path,
      '3': nested.path,
      '4': '',
    }, root.path);
    expect(pids, ['2', '3']);
  });

  test('killBuildRunner without a project directory kills nothing', () async {
    // No project to scope to — the old code would have pkill-ed system-wide.
    expect(await killBuildRunner(), 0);
  });
}
