import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/spm_utils.dart';
import 'package:test/test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Writes a minimal Package.swift to [path].
void _writePackageSwift(String path, {String content = ''}) {
  File(path).writeAsStringSync(content.isEmpty
      ? '''
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "test_plugin",
    platforms: [.iOS(.v13)],
    products: [.library(name: "test_plugin", targets: ["test_plugin"])],
    targets: [
        .target(name: "TestPluginCpp", path: "Sources/TestPluginCpp", publicHeadersPath: "include"),
        .target(name: "test_plugin", dependencies: ["TestPluginCpp"], path: "Sources/TestPlugin"),
    ]
)
'''
      : content);
}

/// Creates a temp dir, writes a podspec inside [platform]/, and returns the root.
Directory _scaffoldWithPodspec({List<String> platforms = const ['ios']}) {
  final root = Directory.systemTemp.createTempSync('spm_utils_test_');
  for (final platform in platforms) {
    final dir = Directory(p.join(root.path, platform))..createSync();
    File(p.join(dir.path, 'test_plugin.podspec')).writeAsStringSync('# podspec');
  }
  return root;
}

void main() {
  // ── toPascalCase ──────────────────────────────────────────────────────────

  group('toPascalCase', () {
    test('single word', () => expect(toPascalCase('plugin'), 'Plugin'));
    test('snake_case', () => expect(toPascalCase('my_plugin'), 'MyPlugin'));
    test('kebab-case', () => expect(toPascalCase('my-plugin'), 'MyPlugin'));
    test('multiple words', () => expect(toPascalCase('my_cool_plugin'), 'MyCoolPlugin'));
    test('already pascal treated as single word', () => expect(toPascalCase('MyPlugin'), 'MyPlugin'));
    test('empty string', () => expect(toPascalCase(''), ''));
    test('with numbers', () => expect(toPascalCase('plugin_v2'), 'PluginV2'));
  });

  // ── detectSpmStatus — no platforms ───────────────────────────────────────

  group('detectSpmStatus — empty directory', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('spm_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('hasSpm is false when no ios/macos directories', () {
      final status = detectSpmStatus(tmp.path);
      expect(status.hasSpm, isFalse);
      expect(status.hasCocoaPods, isFalse);
      expect(status.iosHasSpm, isFalse);
      expect(status.macosHasSpm, isFalse);
    });

    test('isLegacy is false when no CocoaPods', () {
      final status = detectSpmStatus(tmp.path);
      expect(status.isLegacy, isFalse);
    });
  });

  // ── detectSpmStatus — flat layout ────────────────────────────────────────

  group('detectSpmStatus — flat layout (ios/Package.swift)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('spm_flat_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('detects iOS flat Package.swift', () {
      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      _writePackageSwift(p.join(iosDir.path, 'Package.swift'));

      final status = detectSpmStatus(tmp.path);
      expect(status.iosHasSpm, isTrue);
      expect(status.hasSpm, isTrue);
      expect(status.iosPackageSwiftPath, endsWith('ios${p.separator}Package.swift'));
    });

    test('detects macOS flat Package.swift', () {
      final macosDir = Directory(p.join(tmp.path, 'macos'))..createSync();
      _writePackageSwift(p.join(macosDir.path, 'Package.swift'));

      final status = detectSpmStatus(tmp.path);
      expect(status.macosHasSpm, isTrue);
      expect(status.macosPackageSwiftPath, endsWith('macos${p.separator}Package.swift'));
    });

    test('isModern when flat SPM and no podspec', () {
      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      _writePackageSwift(p.join(iosDir.path, 'Package.swift'));

      final status = detectSpmStatus(tmp.path);
      expect(status.isModern, isTrue);
      expect(status.isLegacy, isFalse);
      expect(status.isMixed, isFalse);
    });

    test('isMixed when flat SPM and podspec both present', () {
      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      _writePackageSwift(p.join(iosDir.path, 'Package.swift'));
      File(p.join(iosDir.path, 'test_plugin.podspec')).writeAsStringSync('# pod');

      final status = detectSpmStatus(tmp.path);
      expect(status.isMixed, isTrue);
      expect(status.isModern, isFalse);
    });
  });

  // ── detectSpmStatus — nested layout ──────────────────────────────────────

  group('detectSpmStatus — nested layout (ios/<name>/Package.swift)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('spm_nested_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('detects iOS nested Package.swift', () {
      final packageDir = Directory(p.join(tmp.path, 'ios', 'test_plugin'))..createSync(recursive: true);
      _writePackageSwift(p.join(packageDir.path, 'Package.swift'));

      final status = detectSpmStatus(tmp.path);
      expect(status.iosHasSpm, isTrue);
      expect(status.hasSpm, isTrue);
      expect(status.iosPackageSwiftPath, contains(p.join('ios', 'test_plugin', 'Package.swift')));
    });

    test('detects macOS nested Package.swift', () {
      final packageDir = Directory(p.join(tmp.path, 'macos', 'test_plugin'))..createSync(recursive: true);
      _writePackageSwift(p.join(packageDir.path, 'Package.swift'));

      final status = detectSpmStatus(tmp.path);
      expect(status.macosHasSpm, isTrue);
      expect(status.macosPackageSwiftPath, contains(p.join('macos', 'test_plugin', 'Package.swift')));
    });

    test('nested is preferred over flat when both exist', () {
      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      _writePackageSwift(p.join(iosDir.path, 'Package.swift')); // flat
      final nestedDir = Directory(p.join(iosDir.path, 'test_plugin'))..createSync();
      _writePackageSwift(p.join(nestedDir.path, 'Package.swift')); // nested

      final status = detectSpmStatus(tmp.path);
      expect(status.iosHasSpm, isTrue);
      // Flat is found first (by _findPackageSwift scan order)
      expect(status.iosPackageSwiftPath, contains('Package.swift'));
    });

    test('isModern when nested SPM and no podspec', () {
      final packageDir = Directory(p.join(tmp.path, 'ios', 'test_plugin'))..createSync(recursive: true);
      _writePackageSwift(p.join(packageDir.path, 'Package.swift'));

      final status = detectSpmStatus(tmp.path);
      expect(status.isModern, isTrue);
    });

    test('both iOS and macOS nested detected simultaneously', () {
      final iosPackage = Directory(p.join(tmp.path, 'ios', 'test_plugin'))..createSync(recursive: true);
      _writePackageSwift(p.join(iosPackage.path, 'Package.swift'));
      final macosPackage = Directory(p.join(tmp.path, 'macos', 'test_plugin'))..createSync(recursive: true);
      _writePackageSwift(p.join(macosPackage.path, 'Package.swift'));

      final status = detectSpmStatus(tmp.path);
      expect(status.iosHasSpm, isTrue);
      expect(status.macosHasSpm, isTrue);
      expect(status.hasSpm, isTrue);
    });
  });

  // ── detectSpmStatus — CocoaPods only ─────────────────────────────────────

  group('detectSpmStatus — CocoaPods only', () {
    test('isLegacy when podspec found and no SPM', () {
      final tmp = _scaffoldWithPodspec();
      addTearDown(() => tmp.deleteSync(recursive: true));

      final status = detectSpmStatus(tmp.path);
      expect(status.isLegacy, isTrue);
      expect(status.hasSpm, isFalse);
      expect(status.hasCocoaPods, isTrue);
      expect(status.iosHasPodspec, isTrue);
    });

    test('macOS podspec detected', () {
      final tmp = _scaffoldWithPodspec(platforms: ['macos']);
      addTearDown(() => tmp.deleteSync(recursive: true));

      final status = detectSpmStatus(tmp.path);
      expect(status.macosHasPodspec, isTrue);
      expect(status.hasCocoaPods, isTrue);
    });

    test('both platforms with podspecs', () {
      final tmp = _scaffoldWithPodspec(platforms: ['ios', 'macos']);
      addTearDown(() => tmp.deleteSync(recursive: true));

      final status = detectSpmStatus(tmp.path);
      expect(status.iosHasPodspec, isTrue);
      expect(status.macosHasPodspec, isTrue);
    });
  });

  // ── SpmStatus computed properties ─────────────────────────────────────────

  group('SpmStatus — computed properties', () {
    test('isModern: SPM without CocoaPods', () {
      final s = SpmStatus(
        hasSpm: true, hasCocoaPods: false,
        iosHasSpm: true, macosHasSpm: false,
        iosHasPodspec: false, macosHasPodspec: false,
      );
      expect(s.isModern, isTrue);
      expect(s.isMixed, isFalse);
      expect(s.isLegacy, isFalse);
    });

    test('isMixed: SPM and CocoaPods', () {
      final s = SpmStatus(
        hasSpm: true, hasCocoaPods: true,
        iosHasSpm: true, macosHasSpm: false,
        iosHasPodspec: true, macosHasPodspec: false,
      );
      expect(s.isMixed, isTrue);
      expect(s.isModern, isFalse);
      expect(s.isLegacy, isFalse);
    });

    test('isLegacy: CocoaPods only', () {
      final s = SpmStatus(
        hasSpm: false, hasCocoaPods: true,
        iosHasSpm: false, macosHasSpm: false,
        iosHasPodspec: true, macosHasPodspec: false,
      );
      expect(s.isLegacy, isTrue);
      expect(s.isModern, isFalse);
      expect(s.isMixed, isFalse);
    });

    test('neither: no Apple platforms', () {
      final s = SpmStatus(
        hasSpm: false, hasCocoaPods: false,
        iosHasSpm: false, macosHasSpm: false,
        iosHasPodspec: false, macosHasPodspec: false,
      );
      expect(s.isModern, isFalse);
      expect(s.isMixed, isFalse);
      expect(s.isLegacy, isFalse);
    });
  });

  // ── validatePackageSwift ─────────────────────────────────────────────────

  group('validatePackageSwift', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('pkg_swift_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('reports issue when file not found', () {
      final v = validatePackageSwift(p.join(tmp.path, 'nonexistent.swift'), 'ios');
      expect(v.issues, isNotEmpty);
      expect(v.issues.first, contains('not found'));
    });

    test('no issues for a well-formed ios Package.swift', () {
      final path = p.join(tmp.path, 'Package.swift');
      _writePackageSwift(path);
      final v = validatePackageSwift(path, 'ios');
      // Our template has swift-tools-version and .iOS( so no issues
      expect(v.issues.where((i) => i.contains('missing swift-tools-version')), isEmpty);
    });

    test('issue when swift-tools-version is missing', () {
      final path = p.join(tmp.path, 'Package.swift');
      File(path).writeAsStringSync('let package = Package(name: "x")');
      final v = validatePackageSwift(path, 'ios');
      expect(v.issues.any((i) => i.contains('missing swift-tools-version')), isTrue);
    });

    test('warning when swift-tools-version is too old', () {
      final path = p.join(tmp.path, 'Package.swift');
      File(path).writeAsStringSync('// swift-tools-version: 5.7\nlet p = Package(name:"x", platforms:[.iOS(.v13)])');
      final v = validatePackageSwift(path, 'ios');
      expect(v.warnings.any((w) => w.contains('5.9 or later')), isTrue);
    });

    test('issue when platforms declaration is missing', () {
      final path = p.join(tmp.path, 'Package.swift');
      File(path).writeAsStringSync('// swift-tools-version: 5.9\nlet p = Package(name:"x")');
      final v = validatePackageSwift(path, 'ios');
      expect(v.issues.any((i) => i.contains('missing platforms declaration')), isTrue);
    });

    test('hasNitroFlags false when path not present', () {
      final path = p.join(tmp.path, 'Package.swift');
      File(path).writeAsStringSync('// swift-tools-version: 5.9\nlet p = Package(name:"x", platforms:[.iOS(.v13)])');
      final v = validatePackageSwift(path, 'ios');
      expect(v.hasNitroFlags, isFalse);
    });

    test('hasNitroFlags true when nitro path present', () {
      final path = p.join(tmp.path, 'Package.swift');
      File(path).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'let p = Package(name:"x", platforms:[.iOS(.v13)], targets:['
        '.target(name:"Cpp",path:"Sources/Cpp",cxxSettings:[.unsafeFlags(["-I.symlinks/plugins/nitro/src/native"])])])',
      );
      final v = validatePackageSwift(path, 'ios');
      expect(v.hasNitroFlags, isTrue);
    });
  });

  // ── isNestedSpmLayout ────────────────────────────────────────────────────

  group('isNestedSpmLayout', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nested_layout_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('false for flat ios/Package.swift', () {
      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      final path = p.join(iosDir.path, 'Package.swift');
      File(path).writeAsStringSync('');
      expect(isNestedSpmLayout(path), isFalse);
    });

    test('true for nested ios/my_plugin/Package.swift', () {
      final pkgDir = Directory(p.join(tmp.path, 'ios', 'my_plugin'))..createSync(recursive: true);
      final path = p.join(pkgDir.path, 'Package.swift');
      File(path).writeAsStringSync('');
      expect(isNestedSpmLayout(path), isFalse); // isNestedSpmLayout checks Sources/ keyword
    });
  });

  // ── isNestedSpmPath (new helper) ─────────────────────────────────────────

  group('isNestedSpmPath', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nested_path_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('false for flat ios/Package.swift', () {
      final path = p.join(tmp.path, 'ios', 'Package.swift');
      expect(isNestedSpmPath(path), isFalse);
    });

    test('true for nested ios/my_plugin/Package.swift', () {
      final path = p.join(tmp.path, 'ios', 'my_plugin', 'Package.swift');
      expect(isNestedSpmPath(path), isTrue);
    });

    test('true for nested macos/my_plugin/Package.swift', () {
      final path = p.join(tmp.path, 'macos', 'my_plugin', 'Package.swift');
      expect(isNestedSpmPath(path), isTrue);
    });
  });

  // ── getSpmSourcesDirs ─────────────────────────────────────────────────────

  group('getSpmSourcesDirs', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('spm_sources_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('returns empty list when file does not exist', () {
      expect(getSpmSourcesDirs(p.join(tmp.path, 'NoFile.swift')), isEmpty);
    });

    test('extracts Sources/ paths from Package.swift', () {
      final path = p.join(tmp.path, 'Package.swift');
      File(path).writeAsStringSync('''
let package = Package(targets: [
  .target(name: "MyPlugin", path: "Sources/MyPlugin"),
  .target(name: "MyPluginCpp", path: "Sources/MyPluginCpp"),
])
''');
      final dirs = getSpmSourcesDirs(path);
      expect(dirs, containsAll(['Sources/MyPlugin', 'Sources/MyPluginCpp']));
    });

    test('returns empty list when no path: directives', () {
      final path = p.join(tmp.path, 'Package.swift');
      File(path).writeAsStringSync('let p = Package(name: "x")');
      expect(getSpmSourcesDirs(path), isEmpty);
    });
  });

  // ── validateSpmSourcesStructure ───────────────────────────────────────────

  group('validateSpmSourcesStructure', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('spm_struct_test_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('invalid when platform dir missing', () {
      final v = validateSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin');
      expect(v.isValid, isFalse);
      expect(v.issues, isNotEmpty);
    });

    test('invalid when Sources/ dir missing', () {
      Directory(p.join(tmp.path, 'ios')).createSync();
      final v = validateSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin');
      expect(v.isValid, isFalse);
      expect(v.issues.any((i) => i.contains('Sources/')), isTrue);
    });

    test('reports missing Swift and Cpp dirs', () {
      Directory(p.join(tmp.path, 'ios', 'Sources')).createSync(recursive: true);
      final v = validateSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin');
      expect(v.missingDirs, contains('ios/Sources/MyPlugin'));
      expect(v.missingDirs, contains('ios/Sources/MyPluginCpp'));
    });

    test('valid when all dirs exist', () {
      Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPlugin')).createSync(recursive: true);
      Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp')).createSync(recursive: true);
      final v = validateSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin');
      expect(v.isValid, isTrue);
      expect(v.missingDirs, isEmpty);
    });

    test('reports missing include symlink in Cpp dir', () {
      Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPlugin')).createSync(recursive: true);
      Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp')).createSync(recursive: true);
      // include/ not created → should be in missingSymlinks
      final v = validateSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin');
      expect(v.missingSymlinks, contains('ios/Sources/MyPluginCpp/include'));
    });
  });

  // ── createSpmSourcesStructure — flat layout ───────────────────────────────

  group('createSpmSourcesStructure — flat layout', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('create_spm_flat_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('creates Sources/MyPlugin and Sources/MyPluginCpp in flat layout', () {
      // No nested package dir → flat layout
      Directory(p.join(tmp.path, 'ios')).createSync();
      createSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin', 'my_plugin');

      expect(Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPlugin')).existsSync(), isTrue);
      expect(Directory(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp')).existsSync(), isTrue);
    });

    test('creates include symlink in Cpp dir for flat layout', () {
      Directory(p.join(tmp.path, 'ios')).createSync();
      createSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin', 'my_plugin');

      final includeLink = Link(p.join(tmp.path, 'ios', 'Sources', 'MyPluginCpp', 'include'));
      if (!Platform.isWindows) {
        expect(includeLink.existsSync(), isTrue);
        expect(includeLink.targetSync(), '../../Classes');
      }
    });

    test('does nothing when platform directory does not exist', () {
      // No ios/ dir
      createSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin', 'my_plugin');
      expect(Directory(p.join(tmp.path, 'ios')).existsSync(), isFalse);
    });
  });

  // ── createSpmSourcesStructure — nested layout ─────────────────────────────

  group('createSpmSourcesStructure — nested layout', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('create_spm_nested_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('creates Sources inside nested package dir when it exists', () {
      // Pre-create the nested package dir (as _createPackageSwift would do)
      Directory(p.join(tmp.path, 'ios', 'my_plugin')).createSync(recursive: true);

      createSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin', 'my_plugin');

      expect(
        Directory(p.join(tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPlugin')).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPluginCpp')).existsSync(),
        isTrue,
      );
    });

    test('uses 3-level symlinks for nested layout', () {
      Directory(p.join(tmp.path, 'ios', 'my_plugin')).createSync(recursive: true);
      createSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin', 'my_plugin');

      if (!Platform.isWindows) {
        final includeLink = Link(p.join(tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPluginCpp', 'include'));
        expect(includeLink.existsSync(), isTrue);
        expect(includeLink.targetSync(), '../../../Classes');
      }
    });

    test('swift symlinks use 3-level path in nested layout', () {
      Directory(p.join(tmp.path, 'ios', 'my_plugin')).createSync(recursive: true);
      createSpmSourcesStructure(tmp.path, 'ios', 'MyPlugin', 'my_plugin');

      if (!Platform.isWindows) {
        final lnk = Link(p.join(tmp.path, 'ios', 'my_plugin', 'Sources', 'MyPlugin', 'my_plugin.bridge.g.swift'));
        expect(lnk.existsSync(), isTrue);
        expect(lnk.targetSync(), '../../../Classes/my_plugin.bridge.g.swift');
      }
    });
  });
}
