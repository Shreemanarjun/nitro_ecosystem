// Regression coverage for `_syncSwiftBridgesToSpmSources` (GitHub #62).
//
// `nitrogen link` copies the generated `*.bridge.g.swift` into the SPM Swift
// target under ios/Sources/. The bug: it wrote into EVERY folder not named
// `*Cpp`, and `listSync()` followed symlinks — so a C/C++ target with another
// name, a header-only support folder, and a symlinked vendored target all got a
// Swift file (SPM rejects mixed-language targets; the symlink write escaped the
// package). These tests pin the correct placement so the whole class can't
// regress: the bridge lands ONLY in real Swift targets, and never through a
// directory symlink.
import 'dart:io';

import 'package:nitrogen_cli/commands/link_command.dart' show syncSwiftBridgesToSpmSourcesForTest;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SPM Swift-bridge placement (#62)', () {
    late Directory tmp;
    late String sources;
    late String external;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('spm_swift_');

      // The generated bridge that link copies out.
      final gen = Directory(p.join(tmp.path, 'lib', 'src', 'generated', 'swift'))..createSync(recursive: true);
      File(p.join(gen.path, 'myplugin.bridge.g.swift')).writeAsStringSync(
        '// Generated\npublic protocol NitroEncodable {}\npublic func mypluginBridge() {}\n',
      );

      // Flat ios/Package.swift → detectSpmStatus resolves ios/Sources/.
      final ios = Directory(p.join(tmp.path, 'ios'))..createSync(recursive: true);
      File(p.join(ios.path, 'Package.swift')).writeAsStringSync('// swift-tools-version: 5.9\n');
      sources = p.join(ios.path, 'Sources');
      Directory(sources).createSync();

      // A real Swift target (plugin's own .swift) — SHOULD receive the bridge.
      Directory(p.join(sources, 'MyPlugin')).createSync();
      File(p.join(sources, 'MyPlugin', 'MyPluginPlugin.swift')).writeAsStringSync('// swift');

      // The generated C++ target (name ends in Cpp) — must NOT.
      Directory(p.join(sources, 'MyPluginCpp')).createSync();
      File(p.join(sources, 'MyPluginCpp', 'bridge.cpp')).writeAsStringSync('// cpp');

      // A C/C++ target NOT named *Cpp (the #62 headline) — must NOT.
      Directory(p.join(sources, 'ExtraCore')).createSync();
      File(p.join(sources, 'ExtraCore', 'core.cpp')).writeAsStringSync('// cpp');
      File(p.join(sources, 'ExtraCore', 'core.h')).writeAsStringSync('// h');

      // A header-only support folder (not a target) — must NOT.
      Directory(p.join(sources, 'ExtraConfig')).createSync();
      File(p.join(sources, 'ExtraConfig', 'Version.h')).writeAsStringSync('// h');

      // A SYMLINKED target aliasing a vendored source tree — must NOT be
      // followed, so nothing is written into the external tree.
      external = p.join(tmp.path, 'external_core');
      Directory(external).createSync(recursive: true);
      File(p.join(external, 'ext.cpp')).writeAsStringSync('// external cpp');
      Link(p.join(sources, 'VendoredLink')).createSync(external);

      // A Swift target whose only Swift file is a SYMLINK (the repro: the bridge
      // is a symlink to Classes/) — SHOULD still be recognized as Swift.
      final realSwift = File(p.join(tmp.path, 'real_plugin.swift'))..writeAsStringSync('// real swift');
      Directory(p.join(sources, 'SwiftViaSymlink')).createSync();
      Link(p.join(sources, 'SwiftViaSymlink', 'Plugin.swift')).createSync(realSwift.path);

      syncSwiftBridgesToSpmSourcesForTest(tmp.path);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    bool bridgeIn(String folder) => File(p.join(sources, folder, 'myplugin.bridge.g.swift')).existsSync();

    test('writes the bridge into a real Swift target', () {
      expect(bridgeIn('MyPlugin'), isTrue);
    });

    test('recognizes a Swift target whose only .swift is a symlink', () {
      expect(bridgeIn('SwiftViaSymlink'), isTrue);
    });

    test('does NOT write into the *Cpp C++ target', () {
      expect(bridgeIn('MyPluginCpp'), isFalse);
    });

    test('does NOT write into a C/C++ target with a non-Cpp name (#62)', () {
      expect(bridgeIn('ExtraCore'), isFalse, reason: 'mixed-language target would break the SPM build');
    });

    test('does NOT write into a header-only support folder (#62)', () {
      expect(bridgeIn('ExtraConfig'), isFalse);
    });

    test('does NOT follow a directory symlink into an external source tree (#62)', () {
      // Neither through the link nor in the real external directory.
      expect(bridgeIn('VendoredLink'), isFalse);
      expect(File(p.join(external, 'myplugin.bridge.g.swift')).existsSync(), isFalse,
          reason: 'link must not write outside the package');
    });
  });
}
