// Guards the release-consistency invariants that a coordinated version bump
// must preserve across the four nitro packages. These are easy to get wrong by
// hand (bump a pubspec but forget the version constant, or the CHANGELOG entry,
// or an intra-repo dependency constraint), so pin them:
//   1. all package versions are identical (lockstep release)
//   2. each package's CHANGELOG top heading matches its pubspec version
//   3. the embedded version constants match their package's pubspec version
//   4. intra-repo caret dependencies point at the current (lockstep) version
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _packages = ['nitro', 'nitro_annotations', 'nitro_generator', 'nitrogen_cli'];

Directory _packagesDir() {
  for (final c in [Directory.current.parent, Directory('packages'), Directory.current]) {
    if (Directory(p.join(c.path, 'nitro')).existsSync() && Directory(p.join(c.path, 'nitrogen_cli')).existsSync()) {
      return c;
    }
  }
  fail('could not locate the packages/ directory from ${Directory.current.path}');
}

String _pubspecVersion(String pkgDir) {
  final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(File(p.join(pkgDir, 'pubspec.yaml')).readAsStringSync());
  return (m?.group(1)) ?? fail('no version: in $pkgDir/pubspec.yaml');
}

String _changelogTop(String pkgDir) {
  final m = RegExp(r'^##\s+(\S+)', multiLine: true).firstMatch(File(p.join(pkgDir, 'CHANGELOG.md')).readAsStringSync());
  return (m?.group(1)) ?? fail('no "## <version>" heading in $pkgDir/CHANGELOG.md');
}

void main() {
  final root = _packagesDir().path;
  final dirs = {for (final n in _packages) n: p.join(root, n)};
  final versions = {for (final e in dirs.entries) e.key: _pubspecVersion(e.value)};

  test('all four packages share one lockstep version', () {
    final distinct = versions.values.toSet();
    expect(distinct, hasLength(1), reason: 'versions differ: $versions');
  });

  final expected = versions['nitro']!;

  for (final n in _packages) {
    test('$n: CHANGELOG top heading matches pubspec version ($expected)', () {
      expect(_changelogTop(dirs[n]!), expected,
          reason: '$n pubspec is ${versions[n]} but its CHANGELOG top is ${_changelogTop(dirs[n]!)}');
    });
  }

  test('nitroGeneratorVersion constant matches nitro_generator pubspec', () {
    final c = File(p.join(dirs['nitro_generator']!, 'lib/src/generators/generator_metadata.dart')).readAsStringSync();
    final m = RegExp(r"nitroGeneratorVersion\s*=\s*'([^']+)'").firstMatch(c);
    expect(m?.group(1), expected);
  });

  test('nitrogenVersion constant matches nitrogen_cli pubspec', () {
    final c = File(p.join(dirs['nitrogen_cli']!, 'lib/version.dart')).readAsStringSync();
    final m = RegExp(r"nitrogenVersion\s*=\s*'([^']+)'").firstMatch(c);
    expect(m?.group(1), expected);
  });

  test('intra-repo caret dependencies point at the current version', () {
    final caretDep = RegExp(r'^\s+(' + _packages.join('|') + r'):\s*\^(\S+)', multiLine: true);
    for (final n in _packages) {
      final pubspec = File(p.join(dirs[n]!, 'pubspec.yaml')).readAsStringSync();
      for (final m in caretDep.allMatches(pubspec)) {
        expect(m.group(2), expected,
            reason: '$n depends on ${m.group(1)}: ^${m.group(2)} but the release is $expected');
      }
    }
  });
}
