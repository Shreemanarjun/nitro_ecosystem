import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

// ── Data model ────────────────────────────────────────────────────────────────

enum DoctorStatus { ok, warn, error, info }

class DoctorCheck {
  final DoctorStatus status;
  final String label;
  final String? hint;
  const DoctorCheck(this.status, this.label, {this.hint});
}

class DoctorSection {
  final String title;
  final List<DoctorCheck> checks;
  const DoctorSection(this.title, this.checks);
}

// ── nocterm Components ────────────────────────────────────────────────────────

class CheckRow extends StatelessComponent {
  const CheckRow(this.check, {super.key});
  final DoctorCheck check;

  @override
  Component build(BuildContext context) {
    final Color iconColor;
    final String icon;
    switch (check.status) {
      case DoctorStatus.ok:
        icon = '✔';
        iconColor = Colors.green;
      case DoctorStatus.warn:
        icon = '⚠';
        iconColor = Colors.yellow;
      case DoctorStatus.error:
        icon = '✘';
        iconColor = Colors.red;
      case DoctorStatus.info:
        icon = 'ℹ';
        iconColor = Colors.blue;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 0),
      child: Column(
        children: [
          Row(
            children: [
              Text(icon,
                  style:
                      TextStyle(color: iconColor, fontWeight: FontWeight.bold)),
              const Text(' '),
              Expanded(
                child: Text(
                  check.label,
                  style: TextStyle(
                    color: check.status == DoctorStatus.error
                        ? Colors.red
                        : check.status == DoctorStatus.warn
                            ? Colors.yellow
                            : null,
                  ),
                ),
              ),
            ],
          ),
          if (check.hint != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '→ ${check.hint}',
                style: const TextStyle(
                    color: Colors.gray, fontWeight: FontWeight.dim),
              ),
            ),
        ],
      ),
    );
  }
}

class SectionBox extends StatelessComponent {
  const SectionBox(this.section, {super.key});
  final DoctorSection section;

  @override
  Component build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: Container(
        decoration: BoxDecoration(
          border: BoxBorder.all(color: Colors.brightBlack),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: Column(
            children: [
              Text(
                section.title,
                style: const TextStyle(
                  color: Colors.cyan,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Divider(),
              ...section.checks.map(CheckRow.new),
            ],
          ),
        ),
      ),
    );
  }
}

/// The core Doctor UI component.
class DoctorView extends StatefulComponent {
  const DoctorView({
    required this.pluginName,
    required this.sections,
    required this.errors,
    required this.warnings,
    this.onExit,
    super.key,
  });

  final String pluginName;
  final List<DoctorSection> sections;
  final int errors;
  final int warnings;
  final VoidCallback? onExit;

  @override
  State<DoctorView> createState() => _DoctorViewState();
}

class _DoctorViewState extends State<DoctorView> {
  final _scroll = ScrollController();

  bool _handleKey(KeyboardEvent e) {
    final k = e.logicalKey;
    if (k == LogicalKey.arrowUp) {
      _scroll.scrollUp();
      return true;
    }
    if (k == LogicalKey.arrowDown) {
      _scroll.scrollDown();
      return true;
    }
    if (k == LogicalKey.pageUp) {
      _scroll.pageUp();
      return true;
    }
    if (k == LogicalKey.pageDown) {
      _scroll.pageDown();
      return true;
    }
    if (k == LogicalKey.home) {
      _scroll.scrollToStart();
      return true;
    }
    if (k == LogicalKey.end) {
      _scroll.scrollToEnd();
      return true;
    }

    if (component.onExit != null) {
      component.onExit!();
      return true;
    }

    shutdownApp(component.errors > 0 ? 1 : 0);
    return true;
  }

  @override
  Component build(BuildContext context) {
    final bool healthy = component.errors == 0 && component.warnings == 0;

    final summary = Text(
      healthy
          ? '✨ All checks passed.'
          : component.errors > 0
              ? '✘  ${component.errors} error(s)'
                  '${component.warnings > 0 ? ', ${component.warnings} warning(s)' : ''}.'
              : '⚠  ${component.warnings} warning(s).',
      style: TextStyle(
        fontWeight: FontWeight.bold,
        color: healthy
            ? Colors.green
            : component.errors > 0
                ? Colors.red
                : Colors.yellow,
      ),
    );

    return Focusable(
      focused: true,
      onKeyEvent: _handleKey,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, left: 1, right: 1),
            child: Container(
              decoration:
                  BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  ' nitrogen doctor — ${component.pluginName} ',
                  style: const TextStyle(
                      color: Colors.cyan, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          const Padding(padding: EdgeInsets.only(bottom: 1), child: Text('')),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: ListView(
                controller: _scroll,
                children: component.sections.map(SectionBox.new).toList(),
              ),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.only(top: 1, bottom: 1, left: 1, right: 1),
            child: Column(
              children: [
                summary,
                const Text(
                  '  ↑↓ scroll   PgUp/PgDn page   ESC/Enter/q exit',
                  style:
                      TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── DoctorCommand ─────────────────────────────────────────────────────────────

class DoctorCommand extends Command {
  @override
  final String name = 'doctor';

  @override
  final String description =
      'Checks that a Nitrogen plugin is production-ready: generated files, '
      'build system wiring (CMake, Kotlin, Swift), pubspec, and native configs.';

  static const _generatedSuffixes = [
    '.g.dart',
    '.bridge.g.kt',
    '.bridge.g.swift',
    '.bridge.g.h',
    '.bridge.g.cpp',
    '.CMakeLists.g.txt',
  ];

  static const _generatedSubdir = {
    '.bridge.g.kt': 'kotlin',
    '.bridge.g.swift': 'swift',
    '.bridge.g.h': 'cpp',
    '.bridge.g.cpp': 'cpp',
    '.CMakeLists.g.txt': 'cmake',
  };

  /// Runs the doctor check logic without launching the UI.
  DoctorViewResult performChecks() {
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      throw StateError(
          'No pubspec.yaml found. Run from the root of a Flutter plugin.');
    }

    final pluginName = _pluginName(pubspecFile);
    final specs = _findSpecs();
    final sections = <DoctorSection>[];
    int errors = 0;
    int warnings = 0;

    void err(DoctorSection s, String label, {String? hint}) {
      s.checks.add(DoctorCheck(DoctorStatus.error, label, hint: hint));
      errors++;
    }

    void warn(DoctorSection s, String label, {String? hint}) {
      s.checks.add(DoctorCheck(DoctorStatus.warn, label, hint: hint));
      warnings++;
    }

    void ok(DoctorSection s, String label) {
      s.checks.add(DoctorCheck(DoctorStatus.ok, label));
    }

    void info(DoctorSection s, String label) {
      s.checks.add(DoctorCheck(DoctorStatus.info, label));
    }

    // ── pubspec.yaml ───────────────────────────────────────────────────────
    final pubSec = DoctorSection('pubspec.yaml', []);
    sections.add(pubSec);
    final pubspec = pubspecFile.readAsStringSync();

    if (pubspec.contains('nitro:')) {
      ok(pubSec, 'nitro dependency present');
    } else {
      err(pubSec, 'nitro dependency missing',
          hint: 'Add: nitro: { path: ../packages/nitro }');
    }

    if (pubspec.contains('build_runner:')) {
      ok(pubSec, 'build_runner dev dependency present');
    } else {
      err(pubSec, 'build_runner dev dependency missing',
          hint: 'Add to dev_dependencies: build_runner: ^2.4.0');
    }

    if (pubspec.contains('nitrogen:')) {
      ok(pubSec, 'nitrogen dev dependency present');
    } else {
      err(pubSec, 'nitrogen dev dependency missing',
          hint:
              'Add to dev_dependencies: nitrogen: { path: ../packages/nitrogen }');
    }

    if (RegExp(r'android:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:')
        .hasMatch(pubspec)) {
      ok(pubSec, 'android pluginClass defined');
    } else {
      err(pubSec, 'android pluginClass missing',
          hint: 'Add pluginClass under flutter.plugin.platforms.android');
    }

    if (RegExp(r'android:\s*\n(?:\s+\S[^\n]*\n)*\s+package:')
        .hasMatch(pubspec)) {
      ok(pubSec, 'android package defined');
    } else {
      err(pubSec, 'android package missing',
          hint: 'Add package under flutter.plugin.platforms.android');
    }

    if (RegExp(r'ios:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:')
        .hasMatch(pubspec)) {
      ok(pubSec, 'ios pluginClass defined');
    } else {
      err(pubSec, 'ios pluginClass missing',
          hint: 'Add pluginClass under flutter.plugin.platforms.ios');
    }

    // ── Generated files ────────────────────────────────────────────────────
    if (specs.isNotEmpty) {
      final genSec = DoctorSection('Generated Files', []);
      sections.add(genSec);
      for (final spec in specs) {
        final stem =
            p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final specMtime = spec.lastModifiedSync();
        for (final suffix in _generatedSuffixes) {
          final genPath = _generatedPath(spec.path, stem, suffix);
          final genFile = File(genPath);
          final relPath = p.relative(genPath);
          if (!genFile.existsSync()) {
            err(genSec, 'MISSING  $relPath', hint: 'Run: nitrogen generate');
          } else if (specMtime.isAfter(genFile.lastModifiedSync())) {
            warn(genSec, 'STALE    $relPath', hint: 'Run: nitrogen generate');
          } else {
            ok(genSec, relPath);
          }
        }
      }
    } else {
      final genSec = DoctorSection('Generated Files', []);
      sections.add(genSec);
      warn(genSec, 'No *.native.dart specs found under lib/',
          hint: 'Create lib/src/<name>.native.dart');
    }

    // ── CMakeLists.txt ─────────────────────────────────────────────────────
    final cmakeSec = DoctorSection('CMakeLists.txt', []);
    sections.add(cmakeSec);
    final cmakeFile = File(p.join('src', 'CMakeLists.txt'));
    if (!cmakeFile.existsSync()) {
      err(cmakeSec, 'src/CMakeLists.txt not found', hint: 'Run: nitrogen link');
    } else {
      final cmake = cmakeFile.readAsStringSync();
      if (cmake.contains('NITRO_NATIVE')) {
        ok(cmakeSec, 'NITRO_NATIVE variable defined');
      } else {
        warn(cmakeSec,
            'NITRO_NATIVE variable missing (incorrect dart_api_dl.c path)',
            hint: 'Run: nitrogen link');
      }
      if (cmake.contains('dart_api_dl.c')) {
        ok(cmakeSec, 'dart_api_dl.c included');
      } else {
        err(cmakeSec, 'dart_api_dl.c not included', hint: 'Run: nitrogen link');
      }
      for (final spec in specs) {
        final stem =
            p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
        if (cmake.contains('add_library($lib ')) {
          ok(cmakeSec, 'add_library($lib) target present');
        } else {
          err(cmakeSec, 'add_library($lib) missing',
              hint: 'Run: nitrogen link');
        }
      }
    }

    // ── Android ────────────────────────────────────────────────────────────
    final androidSec = DoctorSection('Android', []);
    sections.add(androidSec);
    if (!Directory('android').existsSync()) {
      info(androidSec, 'android/ directory not present — skipped');
    } else {
      final gradle = File(p.join('android', 'build.gradle'));
      if (!gradle.existsSync()) {
        err(androidSec, 'android/build.gradle not found');
      } else {
        final g = gradle.readAsStringSync();
        if (g.contains('"kotlin-android"') || g.contains("'kotlin-android'")) {
          ok(androidSec, 'kotlin-android plugin applied');
        } else {
          err(androidSec, 'kotlin-android plugin missing',
              hint: 'Add: apply plugin: "kotlin-android"');
        }
        if (g.contains('kotlinOptions')) {
          ok(androidSec, 'kotlinOptions block present');
        } else {
          err(androidSec, 'kotlinOptions block missing',
              hint: 'Add: kotlinOptions { jvmTarget = "17" }');
        }
        if (g.contains('generated/kotlin')) {
          ok(androidSec, 'generated/kotlin sourceSets entry present');
        } else {
          err(androidSec, 'sourceSets entry for generated/kotlin missing');
        }
        if (g.contains('kotlinx-coroutines')) {
          ok(androidSec, 'kotlinx-coroutines dependency present');
        } else {
          err(androidSec, 'kotlinx-coroutines missing in dependencies');
        }
      }

      final kotlinDir = Directory(p.join('android', 'src', 'main', 'kotlin'));
      final pluginFiles = kotlinDir.existsSync()
          ? kotlinDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('Plugin.kt'))
              .toList()
          : <File>[];
      if (pluginFiles.isEmpty) {
        err(androidSec, 'No Plugin.kt found', hint: 'Run: nitrogen init');
      } else {
        final kt = pluginFiles.first.readAsStringSync();
        for (final spec in specs) {
          final stem =
              p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
          if (kt.contains('System.loadLibrary("$lib")')) {
            ok(androidSec, 'System.loadLibrary("$lib") in Plugin.kt');
          } else {
            err(androidSec, 'System.loadLibrary("$lib") missing',
                hint: 'Run: nitrogen link');
          }
        }
        if (kt.contains('JniBridge.register(')) {
          ok(androidSec, 'JniBridge.register(...) call present');
        } else {
          warn(androidSec, 'JniBridge.register(...) not found in Plugin.kt',
              hint: 'Add register call in onAttachedToEngine');
        }
      }
    }

    // ── iOS ────────────────────────────────────────────────────────────────
    final iosSec = DoctorSection('iOS', []);
    sections.add(iosSec);
    if (!Directory('ios').existsSync()) {
      info(iosSec, 'ios/ directory not present — skipped');
    } else {
      final podFiles = Directory('ios')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.podspec'))
          .toList();
      if (podFiles.isEmpty) {
        err(iosSec, 'No .podspec found in ios/', hint: 'Run: nitrogen init');
      } else {
        final pod = podFiles.first.readAsStringSync();
        final podName = p.basename(podFiles.first.path);
        if (pod.contains('HEADER_SEARCH_PATHS')) {
          ok(iosSec, 'HEADER_SEARCH_PATHS in $podName');
        } else {
          err(iosSec, 'HEADER_SEARCH_PATHS missing in $podName',
              hint: 'Run: nitrogen link');
        }
        if (pod.contains('c++17')) {
          ok(iosSec, 'CLANG_CXX_LANGUAGE_STANDARD = c++17');
        } else {
          warn(iosSec, 'CLANG_CXX_LANGUAGE_STANDARD not set to c++17',
              hint:
                  "Set: 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' in pod_target_xcconfig");
        }
        if (pod.contains("swift_version = '5.9'") ||
            pod.contains("swift_version = '6")) {
          ok(iosSec, 'swift_version ≥ 5.9');
        } else {
          warn(iosSec, 'swift_version may be too old',
              hint: "Set: s.swift_version = '5.9'");
        }
      }

      final classesDir = Directory(p.join('ios', 'Classes'));
      final swiftFiles = classesDir.existsSync()
          ? classesDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('Plugin.swift'))
              .toList()
          : <File>[];
      if (swiftFiles.isEmpty) {
        err(iosSec, 'No *Plugin.swift in ios/Classes/',
            hint: 'Run: nitrogen init');
      } else {
        final swift = swiftFiles.first.readAsStringSync();
        if (swift.contains('Registry.register(')) {
          ok(iosSec,
              'Registry.register(...) in ${p.basename(swiftFiles.first.path)}');
        } else {
          warn(iosSec, 'Registry.register(...) not found in Swift plugin',
              hint: 'Add register call in register(with:)');
        }
      }

      final dartApiDl = File(p.join('ios', 'Classes', 'dart_api_dl.cpp'));
      if (dartApiDl.existsSync()) {
        ok(iosSec, 'ios/Classes/dart_api_dl.cpp present');
      } else {
        err(iosSec, 'ios/Classes/dart_api_dl.cpp missing',
            hint: 'Run: nitrogen link');
      }
    }

    return DoctorViewResult(
      pluginName: pluginName,
      sections: sections,
      errors: errors,
      warnings: warnings,
    );
  }

  @override
  Future<void> run() async {
    final result = performChecks();

    await runApp(DoctorView(
      pluginName: result.pluginName,
      sections: result.sections,
      errors: result.errors,
      warnings: result.warnings,
    ));

    // Print persistent one-liner after TUI exits
    if (result.errors == 0 && result.warnings == 0) {
      stdout.writeln(
          '  \x1B[1;32m✨ ${result.pluginName} — all checks passed\x1B[0m');
    } else if (result.errors > 0) {
      stdout.writeln(
          '  \x1B[1;31m✘  ${result.pluginName} — ${result.errors} error(s)'
          '${result.warnings > 0 ? ", ${result.warnings}" : ""}\x1B[0m');
    } else {
      stdout.writeln(
          '  \x1B[1;33m⚠  ${result.pluginName} — ${result.warnings} warning(s)\x1B[0m');
    }
    stdout.writeln('');

    exit(result.errors > 0 ? 1 : 0);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  List<File> _findSpecs() {
    final libDir = Directory('lib');
    if (!libDir.existsSync()) return [];
    return libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.native.dart'))
        .toList();
  }

  String _generatedPath(String specPath, String stem, String suffix) {
    final specDir = p.dirname(specPath);
    if (suffix == '.g.dart') return p.join(specDir, '$stem$suffix');
    return p.join(
        specDir, 'generated', _generatedSubdir[suffix]!, '$stem$suffix');
  }

  String? _extractLibName(File specFile) {
    final content = specFile.readAsStringSync();
    final match =
        RegExp(r'''@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]''')
            .firstMatch(content);
    return match?.group(1);
  }

  String _pluginName(File pubspec) {
    for (final line in pubspec.readAsLinesSync()) {
      if (line.startsWith('name: '))
        return line.replaceFirst('name: ', '').trim();
    }
    return 'unknown';
  }
}

class DoctorViewResult {
  final String pluginName;
  final List<DoctorSection> sections;
  final int errors;
  final int warnings;
  const DoctorViewResult({
    required this.pluginName,
    required this.sections,
    required this.errors,
    required this.warnings,
  });
}
