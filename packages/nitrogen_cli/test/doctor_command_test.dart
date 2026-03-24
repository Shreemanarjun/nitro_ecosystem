import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/commands/doctor_command.dart';
import 'package:test/test.dart';

// Runs [fn] with the working directory temporarily set to [dir].
T _withDir<T>(Directory dir, T Function() fn) {
  final orig = Directory.current;
  Directory.current = dir;
  try {
    return fn();
  } finally {
    Directory.current = orig;
  }
}

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
  }

  return root;
}

DoctorViewResult _run(Directory root) => _withDir(root, () => DoctorCommand().performChecks());

void main() {
  late Directory tmp;
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ── nitro.h ─────────────────────────────────────────────────────────────────

  group('iOS — nitro.h', () {
    test('ok when nitro.h is present in ios/Classes/', () {
      tmp = _scaffold(withNitroH: true);
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('nitro.h present')),
        isTrue,
      );
    });

    test('error when nitro.h is absent from ios/Classes/', () {
      tmp = _scaffold(withNitroH: false);
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
      tmp = _scaffold(
        cppBridges: [
          'my_plugin.bridge.g.cpp',
          'extra.bridge.g.cpp',
        ],
      );
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
      tmp = _scaffold(mmBridges: ['my_plugin.bridge.g.mm']);
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.error && c.label.contains('Stale .cpp bridge')),
        isFalse,
      );
    });

    test('hint points to nitrogen link for auto-rename', () {
      tmp = _scaffold(cppBridges: ['foo.bridge.g.cpp']);
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
      tmp = _scaffold(mmBridges: ['my_plugin.bridge.g.mm']);
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      expect(
        iosSection.checks.any((c) => c.status == DoctorStatus.ok && c.label.contains('.bridge.g.mm')),
        isTrue,
      );
    });

    test('ok label includes count of .mm bridge files', () {
      tmp = _scaffold(mmBridges: [
        'a.bridge.g.mm',
        'b.bridge.g.mm',
        'c.bridge.g.mm',
      ]);
      final result = _run(tmp);
      final iosSection = result.sections.firstWhere((s) => s.title == 'iOS');
      final check = iosSection.checks.firstWhere((c) => c.status == DoctorStatus.ok && c.label.contains('.bridge.g.mm'));
      expect(check.label, contains('3'));
    });

    test('warning when no .bridge.g.mm files and ios/ exists', () {
      // Create a spec so the "specs.isNotEmpty" condition is met.
      tmp = _scaffold(mmBridges: []);
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
      tmp = _scaffold(mmBridges: []);
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
      tmp = _scaffold(
        withNitroH: true,
        withDartApiDl: true,
        mmBridges: ['my_plugin.bridge.g.mm'],
        cppBridges: [],
      );
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
}
