import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/doctor_command.dart';
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

    test('ok when .native.g.h headers are synced to ios/Classes/', () {
      final tmp = _scaffold(
        specs: [(name: 'math', isCpp: true)],
        nativeGHeaders: ['math.native.g.h'],
      );
      addTearDown(() => tmp.deleteSync(recursive: true));
      final result = _run(tmp);
      final iosSec = result.sections.firstWhere((s) => s.title == 'iOS');

      expect(
        iosSec.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('.native.g.h')),
        isTrue,
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
}
