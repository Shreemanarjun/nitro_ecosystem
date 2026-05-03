import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:nitrogen_cli/commands/spm_utils.dart';
import 'package:test/test.dart';

// ── Minimal valid plugin scaffold ─────────────────────────────────────────────

/// Writes the minimum files needed to make DoctorCommand.performChecks()
/// reach the iOS section without unrelated errors.
///
/// Returns the plugin root [Directory].
Directory _scaffold({
  bool withIos = true,
  bool withNitroH = true,
  bool withDartApiDl = true,
  List<String> mmBridges = const [],
  List<String> cppBridges = const [],
  List<String> nativeGHeaders = const [],
  List<({String name, bool isCpp})> specs = const [],
}) {
  final root = Directory.systemTemp.createTempSync('nitro_doctor_test_');

  // pubspec.yaml — satisfies pubspec checks
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: my_plugin
environment:
  sdk: ">=3.0.0 <4.0.0"
dependencies:
  nitro: any
dev_dependencies:
  build_runner: ^2.4.0
  nitro_generator: any
flutter:
  plugin:
    platforms:
      android:
        package: com.example.my_plugin
        pluginClass: MyPlugin
      ios:
        pluginClass: MyPlugin
''');

  // src/CMakeLists.txt — satisfies CMake checks
  final srcDir = Directory(p.join(root.path, 'src'))..createSync();
  File(p.join(srcDir.path, 'CMakeLists.txt')).writeAsStringSync('''
set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../nitro_native")
add_library(my_plugin SHARED dart_api_dl.c)
''');

  // android/ — satisfies Android checks
  final androidDir = Directory(p.join(root.path, 'android'))..createSync();
  File(p.join(androidDir.path, 'build.gradle')).writeAsStringSync('''
apply plugin: "kotlin-android"
android {
  kotlinOptions { jvmTarget = "17" }
  sourceSets { main { kotlin.srcDirs += "src/generated/kotlin" } }
}
dependencies {
  implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.0"
}
''');
  final ktDir = Directory(p.join(androidDir.path, 'src', 'main', 'kotlin', 'com', 'example'))..createSync(recursive: true);
  File(p.join(ktDir.path, 'MyPlugin.kt')).writeAsStringSync('''
class MyPlugin {
  fun onAttachedToEngine() {
    System.loadLibrary("my_plugin")
    MyJniBridge.register(this)
  }
}
''');

  if (withIos) {
    final classesDir = Directory(p.join(root.path, 'ios', 'Classes'))..createSync(recursive: true);

    // podspec
    File(p.join(root.path, 'ios', 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = "my_plugin"
  s.swift_version = '5.9'
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '...',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
  s.source_files = 'Classes/**/*'
end
''');

    // Plugin.swift
    File(p.join(classesDir.path, 'MyPlugin.swift')).writeAsStringSync('MyRegistry.register(impl)');

    if (withDartApiDl) {
      File(p.join(classesDir.path, 'dart_api_dl.c')).writeAsStringSync('// stub');
    }

    if (withNitroH) {
      File(p.join(classesDir.path, 'nitro.h')).writeAsStringSync('// stub');
    }

    for (final name in mmBridges) {
      File(p.join(classesDir.path, name)).writeAsStringSync('// mm bridge');
    }

    for (final name in cppBridges) {
      File(p.join(classesDir.path, name)).writeAsStringSync('// cpp bridge');
    }

    for (final name in nativeGHeaders) {
      File(p.join(classesDir.path, name)).writeAsStringSync('// native g header');
    }
  }

  // Write .native.dart specs under lib/src/
  if (specs.isNotEmpty) {
    final libDir = Directory(p.join(root.path, 'lib', 'src'))..createSync(recursive: true);
    for (final spec in specs) {
      final implLine = spec.isCpp ? 'ios: NativeImpl.cpp, android: NativeImpl.cpp' : 'ios: NativeImpl.swift, android: NativeImpl.kotlin';
      File(p.join(libDir.path, '${spec.name}.native.dart')).writeAsStringSync('''
import 'package:nitro/nitro.dart';
@NitroModule(lib: "${spec.name}", $implLine)
abstract class ${spec.name[0].toUpperCase()}${spec.name.substring(1)} extends HybridObject {}
''');
    }
  }

  return root;
}

DoctorViewResult _run(Directory root) => DoctorCommand().performChecks(root: root);

void main() {
  // ── nitro.h ─────────────────────────────────────────────────────────────────

  group('iOS — nitro.h', () {
    test('generates the System Toolchain section', () {
      final root = _scaffold();
      final doctor = DoctorCommand();
      final result = doctor.performChecks(root: root);

      final sysSec = result.sections.where((s) => s.title == 'System Toolchain').firstOrNull;
      expect(sysSec, isNotNull);
      // It should have several toolchain checks: clang++, Xcode (on Mac), NDK, Java
      expect(sysSec!.checks, isNotEmpty);

      final names = sysSec.checks.map((c) => c.label.toLowerCase()).toList();
      expect(names.any((n) => n.contains('clang++')), isTrue);
      if (Platform.isMacOS) {
        expect(names.any((n) => n.contains('xcode')), isTrue);
      }
      expect(names.any((n) => n.contains('java')), isTrue);
    });

    test('ok when nitro.h is present in ios/Classes/', () {
      final tmp = _scaffold(withNitroH: true);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('nitro.h present')),
        isTrue,
      );
    });

    test('error when nitro.h is absent from ios/Classes/', () {
      final tmp = _scaffold(withNitroH: false);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      final check = iosSection.checks.firstWhere((c) => c.label.contains('nitro.h missing'), orElse: () => throw TestFailure('no nitro.h check found'));
      expect(check.status, equals(DoctorStatus.error));
      expect(check.hint, contains('nitrogen link'));
      expect(result.errors, greaterThan(0));
    });
  });

  // ── stale .bridge.g.cpp ──────────────────────────────────────────────────────

  group('iOS — stale .bridge.g.cpp', () {
    test('error for each stale .bridge.g.cpp file found in ios/Classes/', () {
      final tmp = _scaffold(
        cppBridges: [
          'my_plugin.bridge.g.cpp',
          'extra.bridge.g.cpp',
        ],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');

      final staleChecks = iosSection.checks.where((c) => c.status == DoctorStatus.error && c.label.contains('Stale .cpp bridge')).toList();
      expect(staleChecks, hasLength(2));
      expect(staleChecks.any((c) => c.label.contains('my_plugin.bridge.g.cpp')), isTrue);
      expect(staleChecks.any((c) => c.label.contains('extra.bridge.g.cpp')), isTrue);
      expect(staleChecks.first.hint, contains('bridge.g.mm'));
      expect(result.errors, greaterThan(0));
    });

    test('no stale-cpp error when only .mm bridges are present', () {
      final tmp = _scaffold(mmBridges: ['my_plugin.bridge.g.mm']);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('Stale .cpp bridge')),
        isFalse,
      );
    });

    test('hint points to nitrogen link for auto-rename', () {
      final tmp = _scaffold(cppBridges: ['foo.bridge.g.cpp']);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      final check = iosSection.checks.firstWhere((c) => c.label.contains('Stale .cpp bridge'));
      expect(check.hint, contains('nitrogen link'));
      expect(check.hint, contains('bridge.g.mm'));
    });
  });

  // ── .bridge.g.mm presence ────────────────────────────────────────────────────

  group('iOS — .bridge.g.mm presence', () {
    test('ok when at least one .bridge.g.mm is present', () {
      final tmp = _scaffold(mmBridges: ['my_plugin.bridge.g.mm']);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('.bridge.g.mm')),
        isTrue,
      );
    });

    test('ok label includes count of .mm bridge files', () {
      final tmp = _scaffold(
        mmBridges: [
          'a.bridge.g.mm',
          'b.bridge.g.mm',
          'c.bridge.g.mm',
        ],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      final check = iosSection.checks.firstWhere((c) => c.status == DoctorStatus.ok && c.label.contains('.bridge.g.mm'));
      expect(check.label, contains('3'));
    });

    test('warning when no .bridge.g.mm files and ios/ exists', () {
      // Create a spec so the "specs.isNotEmpty" condition is met.
      final tmp = _scaffold(mmBridges: []);
      addTearDown(() => tmp.deleteSync(recursive: true));
      // Write a .native.dart spec so the warning fires.
      final specDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(specDir.path, 'my_plugin.native.dart')).writeAsStringSync('@NitroModule(lib: "my_plugin")');

      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      final check = iosSection.checks.firstWhere((c) => c.label.contains('No .bridge.g.mm'), orElse: () => throw TestFailure('no .bridge.g.mm warning found'));
      expect(check.status, equals(DoctorStatus.warn));
      expect(check.hint, contains('nitrogen link'));
    });

    test('no .mm warning when no specs exist (nothing to link yet)', () {
      final tmp = _scaffold(mmBridges: []);
      addTearDown(() => tmp.deleteSync(recursive: true));
      // No .native.dart spec written → specs list is empty.
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      expect(
        iosSection.checks.any((c) => c.label.contains('No .bridge.g.mm')),
        isFalse,
      );
    });
  });

  // ── healthy plugin produces no errors ────────────────────────────────────────

  group('iOS — fully linked plugin', () {
    test('all iOS bridge checks pass for a well-linked plugin', () {
      final tmp = _scaffold(
        withNitroH: true,
        withDartApiDl: true,
        mmBridges: ['my_plugin.bridge.g.mm'],
        cppBridges: [],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');

      // No stale-cpp errors
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('Stale .cpp bridge')),
        isFalse,
      );
      // nitro.h ok
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('nitro.h')),
        isTrue,
      );
      // .mm ok
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('.bridge.g.mm')),
        isTrue,
      );
    });
  });

  // ── Project Discovery ────────────────────────────────────────────────────────

  group('Project Discovery', () {
    test('returns error message when pubspec.yaml is missing', () {
      final tmp = Directory.systemTemp.createTempSync('nitro_doctor_empty_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      expect(result.errorMessage, contains('No pubspec.yaml found'));
      expect(result.sections, isEmpty);
    });
  });

  // ── NativeImpl.cpp — Android section ─────────────────────────────────────────

  group('Android — NativeImpl.cpp', () {
    test('shows info and skips Kotlin checks when all specs are cpp', () {
      final tmp = _scaffold(
        specs: [(name: 'math', isCpp: true)],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final androidSec = result.sections.firstWhere((s) => s.title == 'Android');

      expect(
        androidSec.checks.any((c) => c.status == DoctorStatus.info && c.label.contains('NativeImpl.cpp')),
        isTrue,
        reason: 'should show info that Kotlin JNI bridge is not required',
      );
      // kotlin-android / kotlinOptions checks should NOT appear as errors for all-cpp plugins
      expect(
        androidSec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('kotlin-android')),
        isFalse,
      );
    });

    test('shows JniBridge.register info (not error) when all specs are cpp', () {
      final tmp = _scaffold(
        specs: [(name: 'math', isCpp: true)],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final androidSec = result.sections.firstWhere((s) => s.title == 'Android');

      // Must not error on missing JniBridge.register
      expect(
        androidSec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('JniBridge')),
        isFalse,
      );
    });

    test('still checks Kotlin for non-cpp module in mixed project', () {
      final tmp = _scaffold(
        mmBridges: ['utils.bridge.g.mm'],
        specs: [
          (name: 'math', isCpp: true),
          (name: 'utils', isCpp: false),
        ],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final androidSec = result.sections.firstWhere((s) => s.title == 'Android');

      // kotlin-android should be checked (and pass since scaffold has it)
      expect(
        androidSec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('kotlin-android')),
        isTrue,
      );
    });
  });

  // ── NativeImpl.cpp — iOS section ─────────────────────────────────────────────

  group('iOS — NativeImpl.cpp', () {
    test('shows info when all specs are cpp (no Swift bridge required)', () {
      final tmp = _scaffold(
        specs: [(name: 'math', isCpp: true)],
        nativeGHeaders: ['math.native.g.h'],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSec = result.sections.firstWhere((s) => s.title == 'iOS');

      expect(
        iosSec.checks.any((c) => c.status == DoctorStatus.info && c.label.contains('NativeImpl.cpp')),
        isTrue,
      );
    });

    test('ok when HEADER_SEARCH_PATHS covers lib/src/generated/cpp', () {
      final tmp = _scaffold(
        specs: [(name: 'math', isCpp: true)],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      // Overwrite podspec to include lib/src/generated/cpp in HEADER_SEARCH_PATHS.
      // .native.g.h must NOT live in ios/Classes/ (breaks CocoaPods umbrella header);
      // instead it is reachable via HEADER_SEARCH_PATHS pointing at lib/src/generated/cpp.
      File(p.join(tmp.path, 'ios', 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = "my_plugin"
  s.swift_version = '5.9'
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '\${PODS_TARGET_SRCROOT}/../lib/src/generated/cpp \${PODS_TARGET_SRCROOT}/../src/native',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
  s.source_files = 'Classes/**/*'
end
''');
      final result = _run(tmp);
      final iosSec = result.sections.firstWhere((s) => s.title == 'iOS');

      expect(
        iosSec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('.native.g.h')),
        isTrue,
        reason: 'Doctor must confirm *.native.g.h is reachable via HEADER_SEARCH_PATHS when podspec covers lib/src/generated/cpp',
      );
    });

    test('warns when no .native.g.h in ios/Classes/ for cpp spec', () {
      final tmp = _scaffold(
        specs: [(name: 'math', isCpp: true)],
        nativeGHeaders: [],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSec = result.sections.firstWhere((s) => s.title == 'iOS');

      expect(
        iosSec.checks.any((c) => c.status == DoctorStatus.warn && c.label.contains('.native.g.h')),
        isTrue,
      );
    });

    test('no .bridge.g.mm warning for all-cpp plugin', () {
      final tmp = _scaffold(
        specs: [(name: 'math', isCpp: true)],
        mmBridges: [],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSec = result.sections.firstWhere((s) => s.title == 'iOS');

      expect(
        iosSec.checks.any((c) => c.label.contains('No .bridge.g.mm')),
        isFalse,
        reason: 'cpp-only plugins do not need .bridge.g.mm files',
      );
    });

    test('swift_version check skipped for all-cpp plugin', () {
      final tmp = _scaffold(
        specs: [(name: 'math', isCpp: true)],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSec = result.sections.firstWhere((s) => s.title == 'iOS');

      // swift_version warning must not appear for all-cpp
      expect(
        iosSec.checks.any((c) => c.label.toLowerCase().contains('swift_version')),
        isFalse,
      );
    });

    test('Registry.register check still runs for non-cpp module in mixed project', () {
      final tmp = _scaffold(
        mmBridges: ['utils.bridge.g.mm'],
        specs: [
          (name: 'math', isCpp: true),
          (name: 'utils', isCpp: false),
        ],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSec = result.sections.firstWhere((s) => s.title == 'iOS');

      // Registry.register check must appear (passes — scaffold has it)
      expect(
        iosSec.checks.any((c) => c.label.contains('Registry.register')),
        isTrue,
      );
    });
  });

  // ── NativeImpl.cpp — dedicated section ───────────────────────────────────────

  group('NativeImpl.cpp Direct Implementation section', () {
    test('section appears when any spec is cpp', () {
      final tmp = _scaffold(specs: [(name: 'math', isCpp: true)]);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);

      expect(
        result.sections.any((s) => s.title.contains('NativeImpl.cpp')),
        isTrue,
      );
    });

    test('section absent when no cpp specs', () {
      final tmp = _scaffold(specs: [(name: 'math', isCpp: false)]);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);

      expect(
        result.sections.any((s) => s.title.contains('NativeImpl.cpp Direct Implementation')),
        isFalse,
      );
    });

    test('shows info hint when no impl file exists in src/', () {
      final tmp = _scaffold(specs: [(name: 'math', isCpp: true)]);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title.contains('NativeImpl.cpp'));

      expect(
        sec.checks.any((c) => c.status == DoctorStatus.info && c.label.contains('Hybrid')),
        isTrue,
      );
    });

    test('ok when impl file registers the implementation', () {
      final tmp = _scaffold(specs: [(name: 'math', isCpp: true)]);
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Write a user impl file that calls register
      File(p.join(tmp.path, 'src', 'HybridMath.cpp')).writeAsStringSync('''
#include "math.native.g.h"
static HybridMath* s_impl = new HybridMathImpl();
void setup() { math_register_impl(s_impl); }
''');

      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title.contains('NativeImpl.cpp'));

      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('math_register_impl')),
        isTrue,
      );
    });

    test('warns when impl file exists but does not call register', () {
      final tmp = _scaffold(specs: [(name: 'math', isCpp: true)]);
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Write an impl file without the register call
      File(p.join(tmp.path, 'src', 'HybridMath.cpp')).writeAsStringSync('''
#include "math.native.g.h"
// TODO: register impl
''');

      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title.contains('NativeImpl.cpp'));

      expect(
        sec.checks.any((c) => c.status == DoctorStatus.warn && c.label.contains('math_register_impl')),
        isTrue,
      );
    });

    test('clangd info shown when .clangd does not include test dir', () {
      final tmp = _scaffold(specs: [(name: 'math', isCpp: true)]);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title.contains('NativeImpl.cpp'));

      expect(
        sec.checks.any((c) => c.status == DoctorStatus.info && c.label.contains('nitrogen link')),
        isTrue,
      );
    });

    test('clangd ok when .clangd already includes generated/cpp/test', () {
      final tmp = _scaffold(specs: [(name: 'math', isCpp: true)]);
      addTearDown(() => tmp.deleteSync(recursive: true));

      File(p.join(tmp.path, '.clangd')).writeAsStringSync('''
CompileFlags:
  Add: [-I\${PWD}/lib/src/generated/cpp/test]
''');

      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title.contains('NativeImpl.cpp'));

      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('generated/cpp/test')),
        isTrue,
      );
    });
  });

  // ── macOS section ────────────────────────────────────────────────────────────

  group('macOS section', () {
    Directory scaffoldWithMacos({
      bool withPodspec = true,
      bool withDartApiDl = true,
      bool withNitroH = true,
      List<String> mmBridges = const [],
      List<String> cppBridges = const [],
      List<String> nativeGHeaders = const [],
      List<({String name, bool isCpp})> specs = const [],
    }) {
      final root = _scaffold(specs: specs);

      final classesDir = Directory(p.join(root.path, 'macos', 'Classes'))..createSync(recursive: true);

      if (withPodspec) {
        File(p.join(root.path, 'macos', 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = "my_plugin"
  s.swift_version = '5.9'
  s.pod_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '"...", "src/native"',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
end
''');
      }

      if (withDartApiDl) {
        File(p.join(classesDir.path, 'dart_api_dl.c')).writeAsStringSync('// stub');
      }
      if (withNitroH) {
        File(p.join(classesDir.path, 'nitro.h')).writeAsStringSync('#define NITRO_EXPORT __attribute__((visibility("default")))');
      }
      for (final name in mmBridges) {
        File(p.join(classesDir.path, name)).writeAsStringSync('// mm bridge');
      }
      for (final name in cppBridges) {
        File(p.join(classesDir.path, name)).writeAsStringSync('// cpp bridge');
      }
      for (final name in nativeGHeaders) {
        File(p.join(classesDir.path, name)).writeAsStringSync('// native g header');
      }

      return root;
    }

    test('macOS section is info when macos/ directory is not present', () {
      final tmp = _scaffold();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.info && c.label.contains('not present')),
        isTrue,
      );
    });

    test('macOS section error when no .podspec in macos/', () {
      final tmp = scaffoldWithMacos(withPodspec: false);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('podspec')),
        isTrue,
      );
    });

    test('macOS section ok when HEADER_SEARCH_PATHS present in podspec', () {
      final tmp = scaffoldWithMacos();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('HEADER_SEARCH_PATHS')),
        isTrue,
      );
    });

    test('macOS section error when HEADER_SEARCH_PATHS missing from podspec', () {
      final root = _scaffold();
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'macos', 'Classes')).createSync(recursive: true);
      File(p.join(root.path, 'macos', 'my_plugin.podspec')).writeAsStringSync('''
Pod::Spec.new do |s|
  s.name = "my_plugin"
  s.pod_target_xcconfig = { 'OTHER_LDFLAGS' => '-framework AVFoundation' }
end
''');
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('HEADER_SEARCH_PATHS missing')),
        isTrue,
      );
    });

    test('macOS section error when dart_api_dl.c missing from macos/Classes/', () {
      final tmp = scaffoldWithMacos(withDartApiDl: false);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('dart_api_dl.c missing')),
        isTrue,
      );
    });

    test('macOS section ok when dart_api_dl.c present in macos/Classes/', () {
      final tmp = scaffoldWithMacos(withDartApiDl: true);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('dart_api_dl.c present')),
        isTrue,
      );
    });

    test('macOS section error when nitro.h missing from macos/Classes/', () {
      final tmp = scaffoldWithMacos(withNitroH: false);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('nitro.h missing')),
        isTrue,
      );
    });

    test('macOS section ok when nitro.h present and has NITRO_EXPORT', () {
      final tmp = scaffoldWithMacos(withNitroH: true);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('nitro.h present')),
        isTrue,
      );
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('NITRO_EXPORT')),
        isTrue,
      );
    });

    test('macOS section error for each stale .bridge.g.cpp in macos/Classes/', () {
      final tmp = scaffoldWithMacos(cppBridges: ['foo.bridge.g.cpp', 'bar.bridge.g.cpp']);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      final stale = sec.checks.where((c) => c.status == DoctorStatus.error && c.label.contains('Stale .cpp bridge')).toList();
      expect(stale, hasLength(2));
      expect(stale.first.hint, contains('bridge.g.mm'));
    });

    test('macOS section ok count when .bridge.g.mm files present', () {
      final tmp = scaffoldWithMacos(mmBridges: ['foo.bridge.g.mm', 'bar.bridge.g.mm']);
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('2') && c.label.contains('.bridge.g.mm')),
        isTrue,
      );
    });

    test('macOS section info when all specs are NativeImpl.cpp', () {
      final tmp = scaffoldWithMacos(
        nativeGHeaders: ['math.native.g.h'],
        specs: [(name: 'math', isCpp: true)],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.info && c.label.contains('NativeImpl.cpp')),
        isTrue,
      );
    });

    test('macOS section ok when .native.g.h synced and all specs are cpp', () {
      final tmp = scaffoldWithMacos(
        nativeGHeaders: ['math.native.g.h'],
        specs: [(name: 'math', isCpp: true)],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final sec = result.sections.firstWhere((s) => s.title == 'macOS');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('native.g.h')),
        isTrue,
      );
    });
  });

  // ── pubspec macOS platform ────────────────────────────────────────────────────

  group('pubspec — macOS platform', () {
    Directory scaffoldWithMacosPubspec(String macosPlatformEntry) {
      final root = Directory.systemTemp.createTempSync('nitro_doctor_macos_pubspec_');
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: my_plugin
environment:
  sdk: ">=3.0.0 <4.0.0"
dependencies:
  nitro: any
dev_dependencies:
  build_runner: ^2.4.0
  nitro_generator: any
flutter:
  plugin:
    platforms:
      android:
        package: com.example.my_plugin
        pluginClass: MyPlugin
      ios:
        pluginClass: MyPlugin
$macosPlatformEntry
''');
      Directory(p.join(root.path, 'src')).createSync();
      File(p.join(root.path, 'src', 'CMakeLists.txt')).writeAsStringSync(
        'set(NITRO_NATIVE "...")\nadd_library(my_plugin SHARED dart_api_dl.c)\n',
      );
      return root;
    }

    test('ok when macos pluginClass is defined', () {
      final tmp = scaffoldWithMacosPubspec('''      macos:
        pluginClass: MyPlugin''');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final pub = result.sections.firstWhere((s) => s.title == 'pubspec.yaml');
      expect(
        pub.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('macos pluginClass')),
        isTrue,
      );
    });

    test('ok when macos ffiPlugin: true is set', () {
      final tmp = scaffoldWithMacosPubspec('''      macos:
        ffiPlugin: true''');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final pub = result.sections.firstWhere((s) => s.title == 'pubspec.yaml');
      expect(
        pub.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('ffiPlugin')),
        isTrue,
      );
    });

    test('warn when macos section exists but has no pluginClass or ffiPlugin', () {
      final tmp = scaffoldWithMacosPubspec('''      macos:
        dartPluginClass: MyPlugin''');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final pub = result.sections.firstWhere((s) => s.title == 'pubspec.yaml');
      expect(
        pub.checks.any((c) => c.status == DoctorStatus.warn && c.label.contains('macos pluginClass missing')),
        isTrue,
      );
    });

    test('no macOS pubspec check when macos: key is absent entirely', () {
      final tmp = scaffoldWithMacosPubspec('');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final pub = result.sections.firstWhere((s) => s.title == 'pubspec.yaml');
      // Should have no macos-related check at all (macos: not present)
      expect(
        pub.checks.any((c) => c.label.toLowerCase().contains('macos')),
        isFalse,
      );
    });
  });

  // ── Windows section ──────────────────────────────────────────────────────────

  group('Windows section', () {
    Directory scaffoldWithWindows({
      bool hasCmake = true,
      bool hasNitroNative = true,
      bool hasDartApiDl = true,
      bool hasBridgeCpp = true,
      String specName = 'math',
    }) {
      final root = _scaffold(specs: [(name: specName, isCpp: false)]);

      final winDir = Directory(p.join(root.path, 'windows'))..createSync();
      if (hasCmake) {
        final cmakeContent = StringBuffer();
        if (hasNitroNative) cmakeContent.writeln('set(NITRO_NATIVE "/some/path")');
        if (hasDartApiDl) cmakeContent.writeln('add_library(\${PLUGIN_NAME} SHARED dart_api_dl.c)');
        if (hasBridgeCpp) cmakeContent.writeln('../lib/src/generated/cpp/$specName.bridge.g.cpp');
        File(p.join(winDir.path, 'CMakeLists.txt')).writeAsStringSync(cmakeContent.toString());
      }
      return root;
    }

    test('Windows section is info when windows/ directory is not present', () {
      final root = _scaffold();
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Windows');
      expect(sec.checks.first.status, equals(DoctorStatus.info));
      expect(sec.checks.first.label, contains('not present'));
    });

    test('Windows section error when CMakeLists.txt not found', () {
      final root = scaffoldWithWindows(hasCmake: false);
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Windows');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('CMakeLists.txt not found')),
        isTrue,
      );
    });

    test('Windows section ok when NITRO_NATIVE defined in CMakeLists.txt', () {
      final root = scaffoldWithWindows();
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Windows');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('NITRO_NATIVE')),
        isTrue,
      );
    });

    test('Windows section error when NITRO_NATIVE missing', () {
      final root = scaffoldWithWindows(hasNitroNative: false);
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Windows');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('NITRO_NATIVE missing')),
        isTrue,
      );
    });

    test('Windows section ok when dart_api_dl.c present', () {
      final root = scaffoldWithWindows();
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Windows');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('dart_api_dl.c')),
        isTrue,
      );
    });

    test('Windows section error when dart_api_dl.c missing', () {
      final root = scaffoldWithWindows(hasDartApiDl: false);
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Windows');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('dart_api_dl.c not included')),
        isTrue,
      );
    });

    test('Windows section ok when bridge .cpp linked', () {
      final root = scaffoldWithWindows();
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Windows');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('bridge.g.cpp linked')),
        isTrue,
      );
    });

    test('Windows section warn when bridge .cpp not linked', () {
      final root = scaffoldWithWindows(hasBridgeCpp: false);
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Windows');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.warn && c.label.contains('bridge.g.cpp not linked')),
        isTrue,
      );
    });
  });

  // ── Linux section ────────────────────────────────────────────────────────────

  group('Linux section', () {
    Directory scaffoldWithLinux({
      bool hasCmake = true,
      bool hasNitroNative = true,
      bool hasDartApiDl = true,
      bool hasBridgeCpp = true,
      String specName = 'math',
    }) {
      final root = _scaffold(specs: [(name: specName, isCpp: false)]);

      final linuxDir = Directory(p.join(root.path, 'linux'))..createSync();
      if (hasCmake) {
        final cmakeContent = StringBuffer();
        if (hasNitroNative) cmakeContent.writeln('set(NITRO_NATIVE "/some/path")');
        if (hasDartApiDl) cmakeContent.writeln('add_library(\${PLUGIN_NAME} SHARED dart_api_dl.c)');
        if (hasBridgeCpp) cmakeContent.writeln('../lib/src/generated/cpp/$specName.bridge.g.cpp');
        File(p.join(linuxDir.path, 'CMakeLists.txt')).writeAsStringSync(cmakeContent.toString());
      }
      return root;
    }

    test('Linux section is info when linux/ directory is not present', () {
      final root = _scaffold();
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Linux');
      expect(sec.checks.first.status, equals(DoctorStatus.info));
      expect(sec.checks.first.label, contains('not present'));
    });

    test('Linux section error when CMakeLists.txt not found', () {
      final root = scaffoldWithLinux(hasCmake: false);
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Linux');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('CMakeLists.txt not found')),
        isTrue,
      );
    });

    test('Linux section ok when NITRO_NATIVE defined', () {
      final root = scaffoldWithLinux();
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Linux');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('NITRO_NATIVE')),
        isTrue,
      );
    });

    test('Linux section error when NITRO_NATIVE missing', () {
      final root = scaffoldWithLinux(hasNitroNative: false);
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Linux');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('NITRO_NATIVE missing')),
        isTrue,
      );
    });

    test('Linux section error when dart_api_dl.c missing', () {
      final root = scaffoldWithLinux(hasDartApiDl: false);
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Linux');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('dart_api_dl.c not included')),
        isTrue,
      );
    });

    test('Linux section warn when bridge .cpp not linked', () {
      final root = scaffoldWithLinux(hasBridgeCpp: false);
      addTearDown(() => root.deleteSync(recursive: true));
      final result = _run(root);
      final sec = result.sections.firstWhere((s) => s.title == 'Linux');
      expect(
        sec.checks.any((c) => c.status == DoctorStatus.warn && c.label.contains('bridge.g.cpp not linked')),
        isTrue,
      );
    });
  });

  // ── Android — java.srcDirs check (AGP 8.x) ───────────────────────────────────

  group('Android — java.srcDirs check', () {
    test('ok when only kotlin.srcDirs used (no java.srcDirs)', () {
      // Default scaffold already uses kotlin.srcDirs only.
      final tmp = _scaffold();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final androidSec = result.sections.firstWhere((s) => s.title == 'Android');
      expect(
        androidSec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('generated/kotlin sourceSets entry present')),
        isTrue,
      );
      expect(
        androidSec.checks.any((c) => c.label.contains('java.srcDirs')),
        isFalse,
        reason: 'no java.srcDirs check should appear when the bug is not present',
      );
    });

    test('error when java.srcDirs includes generated/kotlin (AGP 8.x "Unresolved reference" bug)', () {
      final tmp = _scaffold();
      addTearDown(() => tmp.deleteSync(recursive: true));
      // Overwrite build.gradle to include the buggy java.srcDirs line.
      File(p.join(tmp.path, 'android', 'build.gradle')).writeAsStringSync('''
apply plugin: "kotlin-android"
android {
  kotlinOptions { jvmTarget = "17" }
  sourceSets {
    main {
      java.srcDirs += "../lib/src/generated/kotlin"
      kotlin.srcDirs += "../lib/src/generated/kotlin"
    }
  }
}
dependencies {
  implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.0"
}
''');
      final result = _run(tmp);
      final androidSec = result.sections.firstWhere((s) => s.title == 'Android');
      final check = androidSec.checks.firstWhere(
        (c) => c.label.contains('java.srcDirs includes generated/kotlin'),
        orElse: () => throw TestFailure('expected java.srcDirs error check not found'),
      );
      expect(check.status, equals(DoctorStatus.error));
      expect(check.hint, contains('kotlin.srcDirs'));
      expect(result.errors, greaterThan(0));
    });

    test('hint points to kotlin.srcDirs as the fix', () {
      final tmp = _scaffold();
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'android', 'build.gradle')).writeAsStringSync('''
apply plugin: "kotlin-android"
android {
  kotlinOptions { jvmTarget = "17" }
  sourceSets { main { java.srcDirs += "../lib/src/generated/kotlin" } }
}
dependencies {
  implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.0"
}
''');
      final result = _run(tmp);
      final androidSec = result.sections.firstWhere((s) => s.title == 'Android');
      final check = androidSec.checks.firstWhere((c) => c.label.contains('java.srcDirs includes generated/kotlin'));
      expect(check.hint, contains('Remove the java.srcDirs line'));
      expect(check.hint, contains('kotlin.srcDirs'));
    });

    test('error when sourceSets entry for generated/kotlin is missing entirely', () {
      final tmp = _scaffold();
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'android', 'build.gradle')).writeAsStringSync('''
apply plugin: "kotlin-android"
android {
  kotlinOptions { jvmTarget = "17" }
}
dependencies {
  implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.0"
}
''');
      final result = _run(tmp);
      final androidSec = result.sections.firstWhere((s) => s.title == 'Android');
      final check = androidSec.checks.firstWhere(
        (c) => c.label.contains('sourceSets entry for generated/kotlin missing'),
        orElse: () => throw TestFailure('expected sourceSets missing error not found'),
      );
      expect(check.status, equals(DoctorStatus.error));
      expect(check.hint, contains('kotlin.srcDirs'));
    });
  });

  // ── Generated Files — platform-specific bridge detection ─────────────────────

  group('Generated Files — platform-specific .bridge.g.kt/.bridge.g.swift detection', () {
    Directory scaffoldWithRawSpec(String specName, String specContent) {
      final tmp = _scaffold();
      final libDir = Directory(p.join(tmp.path, 'lib', 'src'))..createSync(recursive: true);
      File(p.join(libDir.path, '$specName.native.dart')).writeAsStringSync(specContent);
      return tmp;
    }

    test('android:cpp spec shows info that .bridge.g.kt is skipped', () {
      final tmp = scaffoldWithRawSpec('math', '''
import 'package:nitro/nitro.dart';
@NitroModule(lib: "math", windows: WindowsNativeImpl.cpp, android: AndroidNativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final genSec = result.sections.firstWhere((s) => s.title == 'Generated Files');
      expect(
        genSec.checks.any((c) => c.status == DoctorStatus.info && c.label.contains('.bridge.g.kt') && c.label.contains('skipped')),
        isTrue,
        reason: 'android:cpp module should skip .bridge.g.kt check',
      );
      expect(
        genSec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('.bridge.g.kt')),
        isFalse,
        reason: '.bridge.g.kt must not show as error for android:cpp module',
      );
    });

    test('mixed module (windows:cpp + android:kotlin) checks .bridge.g.kt', () {
      // Mixed spec: windows uses C++ but android uses Kotlin — .bridge.g.kt IS needed.
      final tmp = scaffoldWithRawSpec('math', '''
import 'package:nitro/nitro.dart';
@NitroModule(lib: "math", windows: WindowsNativeImpl.cpp, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {}
''');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final genSec = result.sections.firstWhere((s) => s.title == 'Generated Files');
      // Should NOT show the "skipped" info — must check for the .bridge.g.kt file.
      expect(
        genSec.checks.any((c) => c.label.contains('.bridge.g.kt') && c.label.contains('skipped')),
        isFalse,
        reason: 'android:kotlin module must not skip the .bridge.g.kt check',
      );
      expect(
        genSec.checks.any((c) => c.label.contains('.bridge.g.kt')),
        isTrue,
        reason: '.bridge.g.kt check must appear (likely MISSING since nothing is generated)',
      );
    });

    test('apple:cpp (both ios and macos) shows info that .bridge.g.swift is skipped', () {
      final tmp = scaffoldWithRawSpec('math', '''
import 'package:nitro/nitro.dart';
@NitroModule(lib: "math", ios: AppleNativeImpl.cpp, macos: AppleNativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final genSec = result.sections.firstWhere((s) => s.title == 'Generated Files');
      expect(
        genSec.checks.any((c) => c.status == DoctorStatus.info && c.label.contains('.bridge.g.swift') && c.label.contains('skipped')),
        isTrue,
        reason: 'ios:cpp + macos:cpp module should skip .bridge.g.swift check',
      );
      expect(
        genSec.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('.bridge.g.swift')),
        isFalse,
      );
    });

    test('ios:swift + macos:cpp checks .bridge.g.swift (partial Swift still needs bridge)', () {
      // At least one Apple platform is Swift → bridge IS needed.
      final tmp = scaffoldWithRawSpec('math', '''
import 'package:nitro/nitro.dart';
@NitroModule(lib: "math", ios: NativeImpl.swift, macos: AppleNativeImpl.cpp)
abstract class Math extends HybridObject {}
''');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final genSec = result.sections.firstWhere((s) => s.title == 'Generated Files');
      expect(
        genSec.checks.any((c) => c.label.contains('.bridge.g.swift') && c.label.contains('skipped')),
        isFalse,
        reason: 'ios:swift means .bridge.g.swift check must NOT be skipped',
      );
      expect(
        genSec.checks.any((c) => c.label.contains('.bridge.g.swift')),
        isTrue,
      );
    });

    test('no Apple platform in annotation skips .bridge.g.swift (no target = no bridge)', () {
      // @NitroModule with no ios/macos → _isAppleSwiftModule returns false → swift skipped.
      // android with no explicit .cpp annotation → _isAndroidKotlinModule returns true → kt checked.
      final tmp = scaffoldWithRawSpec('math', '''
import 'package:nitro/nitro.dart';
@NitroModule(lib: "math")
abstract class Math extends HybridObject {}
''');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final genSec = result.sections.firstWhere((s) => s.title == 'Generated Files');
      // No ios/macos → swift bridge not needed → check skipped
      expect(
        genSec.checks.any((c) => c.label.contains('.bridge.g.swift') && c.label.contains('skipped')),
        isTrue,
        reason: 'No Apple platform in spec → swift bridge check must be skipped',
      );
      // Android not explicitly cpp → kotlin bridge needed → check NOT skipped
      expect(
        genSec.checks.any((c) => c.label.contains('.bridge.g.kt') && c.label.contains('skipped')),
        isFalse,
        reason: 'No android:cpp in spec → kotlin bridge check must run',
      );
    });
  });

  // ── Apple SPM section ─────────────────────────────────────────────────────

  group('Apple SPM section — macOS only', () {
    // The SPM section is only added on macOS (Platform.isMacOS guard).
    // These tests run on macOS only; on other platforms we verify it's absent.

    test('SPM section present on macOS, absent on other platforms', () {
      final tmp = _scaffold();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final spmSec = result.sections.where((s) => s.title.contains('SPM')).firstOrNull;
      if (Platform.isMacOS) {
        expect(spmSec, isNotNull);
      } else {
        expect(spmSec, isNull);
      }
    });

    // ── SPM absent — CocoaPods only ──

    test('error check when CocoaPods found but no SPM (macOS)', () {
      if (!Platform.isMacOS) return;
      final tmp = _scaffold(withIos: true); // scaffold has podspec, no Package.swift
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);

      final spmSec = result.sections.firstWhere((s) => s.title.contains('SPM'));
      expect(
        spmSec.checks.any((c) =>
            c.status == DoctorStatus.error &&
            c.label.toLowerCase().contains('cocoapods')),
        isTrue,
        reason: 'Should report error when only CocoaPods is present',
      );
      expect(
        spmSec.checks.any((c) => c.hint != null && c.hint!.contains('nitrogen migrate')),
        isTrue,
        reason: 'Hint should suggest nitrogen migrate',
      );
    });

    // ── Nested SPM layout ──

    test('ok checks for nested Flutter 3.41+ layout (macOS)', () {
      if (!Platform.isMacOS) return;
      final tmp = _scaffold(withIos: true);
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Add a nested Package.swift: ios/my_plugin/Package.swift
      final pkgDir = Directory(p.join(tmp.path, 'ios', 'my_plugin'))..createSync(recursive: true);
      File(p.join(pkgDir.path, 'Package.swift')).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'import PackageDescription\n'
        'let package = Package(name:"my_plugin", platforms:[.iOS(.v13)], products:[], targets:[])',
      );

      final result = _run(tmp);
      final spmSec = result.sections.firstWhere((s) => s.title.contains('SPM'));

      // Should show nested layout OK
      expect(
        spmSec.checks.any((c) =>
            c.status == DoctorStatus.ok &&
            c.label.contains('nested')),
        isTrue,
        reason: 'Should detect and report nested Flutter 3.41+ SPM layout',
      );
    });

    // ── Flat SPM layout — warns about upgrade ──

    test('warning for flat SPM layout suggests migration (macOS)', () {
      if (!Platform.isMacOS) return;
      final tmp = _scaffold(withIos: true);
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Flat layout: ios/Package.swift
      final iosDir = Directory(p.join(tmp.path, 'ios'));
      File(p.join(iosDir.path, 'Package.swift')).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'import PackageDescription\n'
        'let package = Package(name:"my_plugin", platforms:[.iOS(.v13)], products:[], targets:[])',
      );

      final result = _run(tmp);
      final spmSec = result.sections.firstWhere((s) => s.title.contains('SPM'));

      expect(
        spmSec.checks.any((c) =>
            c.status == DoctorStatus.warn &&
            c.label.toLowerCase().contains('flat')),
        isTrue,
        reason: 'Flat layout should produce a warning',
      );
      expect(
        spmSec.checks.any((c) =>
            c.hint != null &&
            c.hint!.contains('nitrogen migrate')),
        isTrue,
        reason: 'Warning hint should suggest nitrogen migrate for nested layout upgrade',
      );
    });

    // ── Modern SPM-only ──

    test('ok check for SPM-only (modern) setup (macOS)', () {
      if (!Platform.isMacOS) return;
      final tmp = Directory.systemTemp.createTempSync('doctor_spm_modern_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Minimal pubspec
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('''
name: my_plugin
environment:
  sdk: ">=3.0.0 <4.0.0"
dependencies:
  nitro: any
dev_dependencies:
  build_runner: ^2.4.0
  nitro_generator: any
flutter:
  plugin:
    platforms:
      ios:
        ffiPlugin: true
''');
      final srcDir = Directory(p.join(tmp.path, 'src'))..createSync();
      File(p.join(srcDir.path, 'CMakeLists.txt')).writeAsStringSync(
        'set(NITRO_NATIVE "x")\nadd_library(my_plugin SHARED dart_api_dl.c)\n',
      );

      // Nested SPM — no podspec
      final pkgDir = Directory(p.join(tmp.path, 'ios', 'my_plugin'))..createSync(recursive: true);
      File(p.join(pkgDir.path, 'Package.swift')).writeAsStringSync(
        '// swift-tools-version: 5.9\n'
        'let package = Package(name:"my_plugin", platforms:[.iOS(.v13)], products:[], targets:[])',
      );
      // ios/Classes with minimum files (no podspec)
      final classesDir = Directory(p.join(tmp.path, 'ios', 'Classes'))..createSync(recursive: true);
      File(p.join(classesDir.path, 'dart_api_dl.c')).writeAsStringSync('// stub');
      File(p.join(classesDir.path, 'nitro.h')).writeAsStringSync('// NITRO_EXPORT stub');

      final result = _run(tmp);
      final spmSec = result.sections.firstWhere((s) => s.title.contains('SPM'));

      expect(
        spmSec.checks.any((c) =>
            c.status == DoctorStatus.ok &&
            c.label.toLowerCase().contains('spm-only')),
        isTrue,
        reason: 'Should show ok for SPM-only modern setup',
      );
    });
  });

  // ── SpmStatus integration with DoctorCommand ──────────────────────────────

  group('SpmStatus detectSpmStatus integration', () {
    test('detects nested layout in real filesystem', () {
      final tmp = Directory.systemTemp.createTempSync('spm_detect_test_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final pkgDir = Directory(p.join(tmp.path, 'ios', 'my_plugin'))..createSync(recursive: true);
      File(p.join(pkgDir.path, 'Package.swift')).writeAsStringSync('// swift-tools-version: 5.9\n');

      final status = detectSpmStatus(tmp.path);
      expect(status.iosHasSpm, isTrue);
      expect(status.iosPackageSwiftPath, contains(p.join('ios', 'my_plugin', 'Package.swift')));
    });

    test('detects flat layout', () {
      final tmp = Directory.systemTemp.createTempSync('spm_flat_detect_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      File(p.join(iosDir.path, 'Package.swift')).writeAsStringSync('// swift-tools-version: 5.9\n');

      final status = detectSpmStatus(tmp.path);
      expect(status.iosHasSpm, isTrue);
      expect(status.iosPackageSwiftPath, endsWith('ios${p.separator}Package.swift'));
    });

    test('CocoaPods-only detected correctly', () {
      final tmp = Directory.systemTemp.createTempSync('spm_pods_detect_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final iosDir = Directory(p.join(tmp.path, 'ios'))..createSync();
      File(p.join(iosDir.path, 'my_plugin.podspec')).writeAsStringSync('# pod');

      final status = detectSpmStatus(tmp.path);
      expect(status.hasCocoaPods, isTrue);
      expect(status.hasSpm, isFalse);
      expect(status.isLegacy, isTrue);
    });
  });
}
