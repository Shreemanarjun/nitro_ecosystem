import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/version.dart';
import 'link_command.dart' show isCppModule;
import '../ui.dart';

// ── Data model ────────────────────────────────────────────────────────────────

enum DoctorStatus { ok, warn, error, info }

class DoctorCheck {
  final DoctorStatus status;
  final String label;
  final String? hint;
  DoctorCheck(this.status, this.label, {this.hint});
}

class DoctorSection {
  final String title;
  final List<DoctorCheck> checks;
  DoctorSection(this.title, [List<DoctorCheck>? checks]) : checks = (checks ?? <DoctorCheck>[]).toList();
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
              Text(
                icon,
                style: TextStyle(color: iconColor, fontWeight: FontWeight.bold),
              ),
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
                style: const TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
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
    this.errorMessage,
    this.onExit,
    super.key,
  });

  final String pluginName;
  final List<DoctorSection> sections;
  final int errors;
  final int warnings;
  final String? errorMessage;
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

    if (k == LogicalKey.escape && component.onExit != null) {
      component.onExit!();
      return true;
    } else if (k == LogicalKey.escape) {
      shutdownApp(component.errors > 0 ? 1 : 0);
      return true;
    }

    return false; // Key not handled
  }

  @override
  Component build(BuildContext context) {
    final bool healthy = component.errors == 0 && component.warnings == 0 && component.errorMessage == null;

    final summary = Text(
      component.errorMessage != null
          ? '✘  Project discovery failed.'
          : healthy
          ? '✨ All checks passed.'
          : component.errors > 0
          ? '✘  ${component.errors} error(s)'
                '${component.warnings > 0 ? ', ${component.warnings} warning(s)' : ''}.'
          : '⚠  ${component.warnings} warning(s).',
      style: TextStyle(
        fontWeight: FontWeight.bold,
        color: component.errorMessage != null || component.errors > 0
            ? Colors.red
            : healthy
            ? Colors.green
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
              decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  ' nitrogen doctor v$activeVersion — ${component.pluginName} ',
                  style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          const Padding(padding: EdgeInsets.only(bottom: 1), child: Text('')),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: component.errorMessage != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                            decoration: BoxDecoration(
                              border: BoxBorder.all(color: Colors.red),
                            ),
                            child: const Text(
                              ' ✘  ERROR ',
                              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(component.errorMessage!, style: const TextStyle(color: Colors.white)),
                          const SizedBox(height: 1),
                          Text(
                            'Hint: Make sure you are in a Flutter plugin project root.',
                            style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      controller: _scroll,
                      children: component.sections.map(SectionBox.new).toList(),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 1, bottom: 1, left: 1, right: 1),
            child: Column(
              children: [
                summary,
                const SizedBox(height: 1),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (component.onExit != null) ...[
                      HoverButton(
                        label: '‹ Back',
                        onTap: component.onExit!,
                        color: Colors.cyan,
                      ),
                      const Text('  •  ', style: TextStyle(color: Colors.brightBlack)),
                    ],
                    Text(
                      '↑↓ scroll   PgUp/PgDn   ${component.onExit != null ? 'ESC back' : 'ESC exit'}',
                      style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
                    ),
                  ],
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

  // Core generated files — always expected for every .native.dart spec.
  static const _generatedSuffixes = [
    '.g.dart',
    '.bridge.g.kt',
    '.bridge.g.swift',
    '.bridge.g.h',
    '.bridge.g.cpp',
    '.CMakeLists.g.txt',
  ];

  // Extra files generated only for NativeImpl.cpp modules.
  static const _cppGeneratedSuffixes = [
    '.native.g.h',
    '.mock.g.h',
    '.test.g.cpp',
  ];

  static const _generatedSubdir = {
    '.bridge.g.kt': 'kotlin',
    '.bridge.g.swift': 'swift',
    '.bridge.g.h': 'cpp',
    '.bridge.g.cpp': 'cpp',
    '.CMakeLists.g.txt': 'cmake',
    // cpp-mode outputs
    '.native.g.h': 'cpp',
    '.mock.g.h': 'cpp/test',
    '.test.g.cpp': 'cpp/test',
  };

  /// Runs the doctor check logic without launching the UI.
  DoctorViewResult performChecks({Directory? root}) {
    root ??= Directory.current;
    final pubspecFile = File(p.join(root.path, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      return DoctorViewResult(
        pluginName: 'unknown',
        sections: [],
        errors: 0,
        warnings: 0,
        errorMessage: 'No pubspec.yaml found. Run from the root of a Flutter plugin.',
      );
    }

    final pluginName = _pluginName(pubspecFile);
    final specs = _findSpecs(root: root);
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

    // ── System Toolchain ────────────────────────────────────────────────────────
    final sysSec = DoctorSection('System Toolchain');
    sections.add(sysSec);

    // 1. C++ Compiler
    try {
      final clangResult = Process.runSync('clang++', ['--version']);
      if (clangResult.exitCode == 0) {
        ok(sysSec, 'clang++ found: ${clangResult.stdout.toString().split('\n').first}');
      } else {
        warn(sysSec, 'clang++ not found', hint: 'Install build-essential or Xcode Command Line Tools');
      }
    } catch (_) {
      warn(sysSec, 'clang++ not found', hint: 'Install build-essential or Xcode Command Line Tools');
    }

    // 2. Xcode (on Mac)
    if (Platform.isMacOS) {
      try {
        final xcodeResult = Process.runSync('xcode-select', ['-p']);
        if (xcodeResult.exitCode == 0) {
          ok(sysSec, 'Xcode at ${xcodeResult.stdout.toString().trim()}');
        } else {
          err(sysSec, 'Xcode not found', hint: 'Run: xcode-select --install');
        }
      } catch (_) {
        err(sysSec, 'Xcode select failed', hint: 'Run: xcode-select --install');
      }
    }

    // 3. Android NDK
    final ndkPath = Platform.environment['ANDROID_NDK_HOME'] ?? Platform.environment['NDK_HOME'];
    if (ndkPath != null && Directory(ndkPath).existsSync()) {
      ok(sysSec, 'Android NDK: ${p.basename(ndkPath)}');
    } else {
      // Check local.properties if in an android project, though we are in a plugin...
      // Usually users set ANDROID_NDK_HOME globally.
      warn(sysSec, 'ANDROID_NDK_HOME not set', hint: 'Set ANDROID_NDK_HOME in your environment');
    }

    // 4. Java
    try {
      final javaResult = Process.runSync('java', ['-version']);
      // java -version writes to stderr
      final javaOut = javaResult.stderr.toString();
      if (javaOut.contains('version')) {
        ok(sysSec, 'Java: ${javaOut.split('\n').first}');
      } else {
        warn(sysSec, 'Java not found', hint: 'Install JDK 17+');
      }
    } catch (_) {
      warn(sysSec, 'Java not found', hint: 'Install JDK 17+');
    }

    final pubSec = DoctorSection('pubspec.yaml');
    sections.add(pubSec);
    final pubspec = pubspecFile.readAsStringSync();

    if (pubspec.contains('nitro:')) {
      ok(pubSec, 'nitro dependency present');
    } else {
      err(pubSec, 'nitro dependency missing', hint: 'Add: nitro: { path: ../packages/nitro }');
    }

    if (pubspec.contains('build_runner:')) {
      ok(pubSec, 'build_runner dev dependency present');
    } else {
      err(pubSec, 'build_runner dev dependency missing', hint: 'Add to dev_dependencies: build_runner: ^2.4.0');
    }

    if (pubspec.contains('nitro_generator:')) {
      ok(pubSec, 'nitro_generator dev dependency present');
    } else {
      err(pubSec, 'nitro_generator dev dependency missing', hint: 'Add to dev_dependencies: nitro_generator: { path: ../packages/nitro_generator }');
    }

    if (RegExp(r'android:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:').hasMatch(pubspec)) {
      ok(pubSec, 'android pluginClass defined');
    } else {
      err(pubSec, 'android pluginClass missing', hint: 'Add pluginClass under flutter.plugin.platforms.android');
    }

    if (RegExp(r'android:\s*\n(?:\s+\S[^\n]*\n)*\s+package:').hasMatch(pubspec)) {
      ok(pubSec, 'android package defined');
    } else {
      err(pubSec, 'android package missing', hint: 'Add package under flutter.plugin.platforms.android');
    }

    if (RegExp(r'ios:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:').hasMatch(pubspec)) {
      ok(pubSec, 'ios pluginClass defined');
    } else if (RegExp(r'ios:\s*\n(?:\s+\S[^\n]*\n)*\s+ffiPlugin:\s*true').hasMatch(pubspec)) {
      ok(pubSec, 'ios ffiPlugin: true (pluginClass optional for FFI plugins)');
    } else {
      err(pubSec, 'ios pluginClass missing', hint: 'Add pluginClass under flutter.plugin.platforms.ios');
    }

    if (specs.isNotEmpty) {
      final genSec = DoctorSection('Generated Files');
      sections.add(genSec);
      for (final spec in specs) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final specMtime = spec.lastModifiedSync();
        final specIsCpp = isCppModule(spec);

        for (final suffix in _generatedSuffixes) {
          // For NativeImpl.cpp modules the .bridge.g.kt and .bridge.g.swift
          // outputs contain only a "Not applicable" placeholder — treat as info.
          if (specIsCpp && (suffix == '.bridge.g.kt' || suffix == '.bridge.g.swift')) {
            info(genSec, '${p.basename(spec.path)} → $suffix skipped (NativeImpl.cpp)');
            continue;
          }
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

        // Check cpp-only outputs for NativeImpl.cpp modules.
        if (specIsCpp) {
          for (final suffix in _cppGeneratedSuffixes) {
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
      }
    } else {
      final genSec = DoctorSection('Generated Files');
      sections.add(genSec);
      warn(genSec, 'No *.native.dart specs found under lib/', hint: 'Create lib/src/<name>.native.dart');
    }

    final cmakeSec = DoctorSection('CMakeLists.txt');
    sections.add(cmakeSec);
    final cmakeFile = File(p.join(root.path, 'src', 'CMakeLists.txt'));
    if (!cmakeFile.existsSync()) {
      err(cmakeSec, 'src/CMakeLists.txt not found', hint: 'Run: nitrogen link');
    } else {
      final cmake = cmakeFile.readAsStringSync();
      // Check for redundant includes in nearby C++ files
      final srcDir = Directory(p.join(root.path, 'src'));
      final cppFiles = srcDir.listSync().whereType<File>().where((f) => f.path.endsWith('.cpp') || f.path.endsWith('.c')).toList();
      for (final f in cppFiles) {
        final c = f.readAsStringSync();
        if (c.contains('.bridge.g.cpp') || c.contains('.bridge.g.c')) {
          err(cmakeSec, 'Redundant bridge include in ${p.basename(f.path)}', hint: 'Remove #include "...bridge.g.cpp" from your source file');
        }
      }

      if (cmake.contains('NITRO_NATIVE')) {
        ok(cmakeSec, 'NITRO_NATIVE variable defined');
      } else {
        warn(cmakeSec, 'NITRO_NATIVE variable missing (incorrect dart_api_dl.c path)', hint: 'Run: nitrogen link');
      }
      if (cmake.contains('dart_api_dl.c')) {
        ok(cmakeSec, 'dart_api_dl.c included');
      } else {
        err(cmakeSec, 'dart_api_dl.c not included', hint: 'Run: nitrogen link');
      }

      // Check for unlinked source files in src/
      final allSrcFiles = srcDir.listSync().whereType<File>().where((f) => f.path.endsWith('.cpp') || f.path.endsWith('.c')).toList();
      for (final f in allSrcFiles) {
        final name = p.basename(f.path);
        if (name == 'dart_api_dl.c') continue;
        if (name == '$pluginName.cpp' || name == '$pluginName.c') continue; // Handled by primary target checks

        if (!cmake.contains('"$name"') && !cmake.contains(' $name ') && !cmake.contains('\n  $name')) {
          warn(cmakeSec, 'Unlinked source: $name', hint: 'File found in src/ but not mentioned in CMakeLists.txt');
        }
      }

      for (final spec in specs) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
        if (cmake.contains('add_library($lib ')) {
          ok(cmakeSec, 'add_library($lib) target present');

          // Verify implementation file is linked for C++ modules
          if (isCppModule(spec)) {
            final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
            final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
            final implName = 'Hybrid$moduleName.cpp';
            if (!cmake.contains('"$implName"') && !cmake.contains(' $implName ') && !cmake.contains('\n  $implName')) {
              err(cmakeSec, '$lib: $implName not linked in target', hint: 'Add "$implName" to add_library($lib ...)');
            }
          }
        } else {
          err(cmakeSec, 'add_library($lib) missing', hint: 'Run: nitrogen link');
        }
      }
    }

    // Whether any / all specs use NativeImpl.cpp — used below to skip irrelevant checks.
    final allSpecsCpp = specs.isNotEmpty && specs.every(isCppModule);
    final hasAnyCppSpec = specs.any(isCppModule);
    final hasAnyNonCppSpec = specs.any((s) => !isCppModule(s));

    final androidSec = DoctorSection('Android');
    sections.add(androidSec);
    final androidDir = Directory(p.join(root.path, 'android'));
    if (!androidDir.existsSync()) {
      info(androidSec, 'android/ directory not present — skipped');
    } else if (allSpecsCpp) {
      // Pure C++ plugin — no Kotlin bridge needed.
      info(androidSec, 'All modules use NativeImpl.cpp — Kotlin JNI bridge not required');
      // Still check that the NDK can build the shared library.
      final gradle = File(p.join(androidDir.path, 'build.gradle'));
      if (gradle.existsSync() && gradle.readAsStringSync().contains('externalNativeBuild')) {
        ok(androidSec, 'externalNativeBuild configured (NDK build)');
      } else {
        info(androidSec, 'Add externalNativeBuild to android/build.gradle if using CMake directly');
      }
    } else {
      final gradle = File(p.join(androidDir.path, 'build.gradle'));
      if (!gradle.existsSync()) {
        err(androidSec, 'android/build.gradle not found');
      } else {
        final g = gradle.readAsStringSync();
        if (g.contains('"kotlin-android"') || g.contains("'kotlin-android'")) {
          ok(androidSec, 'kotlin-android plugin applied');
        } else {
          err(androidSec, 'kotlin-android plugin missing', hint: 'Add: apply plugin: "kotlin-android"');
        }
        if (g.contains('kotlinOptions')) {
          ok(androidSec, 'kotlinOptions block present');
        } else {
          err(androidSec, 'kotlinOptions block missing', hint: 'Add: kotlinOptions { jvmTarget = "17" }');
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

      final ktDir = Directory(p.join(androidDir.path, 'src', 'main', 'kotlin'));
      final pluginFiles = ktDir.existsSync() ? ktDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('Plugin.kt')).toList() : <File>[];
      if (pluginFiles.isEmpty) {
        err(androidSec, 'No Plugin.kt found', hint: 'Run: nitrogen init');
      } else {
        final kt = pluginFiles.first.readAsStringSync();
        // Only check System.loadLibrary for non-cpp specs (cpp libs are also loaded but that's fine)
        for (final spec in specs) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
          if (kt.contains('System.loadLibrary("$lib")')) {
            ok(androidSec, 'System.loadLibrary("$lib") in Plugin.kt');
          } else {
            err(androidSec, 'System.loadLibrary("$lib") missing', hint: 'Run: nitrogen link');
          }
        }
        // JniBridge.register only needed for non-cpp specs
        if (hasAnyNonCppSpec) {
          if (kt.contains('JniBridge.register(')) {
            ok(androidSec, 'JniBridge.register(...) call present');
          } else {
            warn(androidSec, 'JniBridge.register(...) not found in Plugin.kt', hint: 'Add register call in onAttachedToEngine');
          }
        } else {
          info(androidSec, 'JniBridge.register not needed — all modules use NativeImpl.cpp');
        }
      }
    }

    final iosSec = DoctorSection('iOS');
    sections.add(iosSec);
    final iosDir = Directory(p.join(root.path, 'ios'));
    if (!iosDir.existsSync()) {
      info(iosSec, 'ios/ directory not present — skipped');
    } else {
      final podFiles = iosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList();
      if (podFiles.isEmpty) {
        err(iosSec, 'No .podspec found in ios/', hint: 'Run: nitrogen init');
      } else {
        final pod = podFiles.first.readAsStringSync();
        final podName = p.basename(podFiles.first.path);
        if (pod.contains('HEADER_SEARCH_PATHS')) {
          ok(iosSec, 'HEADER_SEARCH_PATHS in $podName');
        } else {
          err(iosSec, 'HEADER_SEARCH_PATHS missing in $podName', hint: 'Run: nitrogen link');
        }
        if (pod.contains('c++17')) {
          ok(iosSec, 'CLANG_CXX_LANGUAGE_STANDARD = c++17');
        } else {
          warn(iosSec, 'CLANG_CXX_LANGUAGE_STANDARD not set to c++17', hint: "Set: 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' in pod_target_xcconfig");
        }
        if (!allSpecsCpp) {
          // swift_version only relevant when Swift bridges are used
          if (pod.contains("swift_version = '5.9'") || pod.contains("swift_version = '6")) {
            ok(iosSec, 'swift_version ≥ 5.9');
          } else {
            warn(iosSec, 'swift_version may be too old', hint: "Set: s.swift_version = '5.9'");
          }
        }

        // Check for complete HEADER_SEARCH_PATHS
        if (pod.contains('lib/src/generated/cpp') && pod.contains('src/native')) {
          ok(iosSec, 'Comprehensive HEADER_SEARCH_PATHS in podspec');
        } else {
          warn(iosSec, 'Incomplete HEADER_SEARCH_PATHS in podspec', hint: 'Run: nitrogen link');
        }
      }

      final classesDir = Directory(p.join(iosDir.path, 'Classes'));
      if (allSpecsCpp) {
        // No Swift bridge needed — check that the C++ interface headers were synced
        info(iosSec, 'All modules use NativeImpl.cpp — Swift bridge (Registry.register) not required');
        final cppHeaders = classesDir.existsSync() ? classesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.native.g.h')).toList() : <File>[];
        if (cppHeaders.isNotEmpty) {
          ok(iosSec, '${cppHeaders.length} *.native.g.h header(s) synced to ios/Classes/');
        } else if (hasAnyCppSpec) {
          warn(iosSec, 'No *.native.g.h in ios/Classes/', hint: 'Run: nitrogen generate && nitrogen link');
        }
      } else {
        final swiftFiles = classesDir.existsSync() ? classesDir.listSync().whereType<File>().where((f) => f.path.endsWith('Plugin.swift')).toList() : <File>[];
        if (swiftFiles.isEmpty) {
          err(iosSec, 'No *Plugin.swift in ios/Classes/', hint: 'Run: nitrogen init');
        } else {
          final swift = swiftFiles.first.readAsStringSync();
          if (hasAnyNonCppSpec) {
            if (swift.contains('Registry.register(') || swift.contains('.register(')) {
              ok(iosSec, 'Plugin.swift has Registry.register(...)');
            } else {
              warn(iosSec, 'Registry.register(...) not found in Plugin.swift', hint: 'Add: NitroModules.Registry.register(...) in register(with:)');
            }
          } else {
            info(iosSec, 'Registry.register not needed — all modules use NativeImpl.cpp');
          }
        }
      }

      final dartApiDl = File(p.join(iosDir.path, 'Classes', 'dart_api_dl.c'));
      if (dartApiDl.existsSync()) {
        ok(iosSec, 'ios/Classes/dart_api_dl.c present');
      } else {
        err(iosSec, 'ios/Classes/dart_api_dl.c missing', hint: 'Run: nitrogen link');
      }

      final nitroH = File(p.join(iosDir.path, 'Classes', 'nitro.h'));
      if (nitroH.existsSync()) {
        ok(iosSec, 'ios/Classes/nitro.h present');
      } else {
        err(iosSec, 'ios/Classes/nitro.h missing', hint: 'Run: nitrogen link');
      }

      if (nitroH.existsSync()) {
        final content = nitroH.readAsStringSync();
        if (content.contains('NITRO_EXPORT')) {
          ok(iosSec, 'nitro.h contains NITRO_EXPORT visibility macro');
        } else {
          err(iosSec, 'nitro.h missing NITRO_EXPORT visibility macro', hint: 'Run: nitrogen link');
        }
      }

      // Bridge files must use .mm (Objective-C++) not .cpp (pure C++).
      // .cpp files cause __OBJC__ to be undefined, making @try/@catch dead
      // code — NSException from Swift propagates uncaught and crashes the app.
      final staleCppBridges = classesDir.existsSync() ? classesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.cpp')).toList() : <File>[];
      if (staleCppBridges.isNotEmpty) {
        for (final f in staleCppBridges) {
          err(iosSec, 'Stale .cpp bridge: ${p.basename(f.path)} (must be .mm)', hint: 'Run: nitrogen link (auto-renames .bridge.g.cpp → .bridge.g.mm)');
        }
      }

      final mmBridges = classesDir.existsSync() ? classesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.mm')).toList() : <File>[];
      if (mmBridges.isNotEmpty) {
        ok(iosSec, '${mmBridges.length} .bridge.g.mm file(s) in ios/Classes/');
      } else if (specs.isNotEmpty && !allSpecsCpp) {
        // Only warn about missing .mm bridges for non-cpp modules
        warn(iosSec, 'No .bridge.g.mm files in ios/Classes/', hint: 'Run: nitrogen link');
      }
    }

    // ── NativeImpl.cpp Direct Implementation ────────────────────────────────
    if (hasAnyCppSpec) {
      final cppSec = DoctorSection('NativeImpl.cpp Direct Implementation');
      sections.add(cppSec);

      for (final spec in specs.where(isCppModule)) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
        final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
        final parsedSegments = stem.split('_').where((w) => w.isNotEmpty).toList();
        final fallbackName = parsedSegments.isNotEmpty ? parsedSegments.map((w) => w[0].toUpperCase() + w.substring(1)).join('') : lib;
        final moduleName = moduleMatch?.group(1) ?? fallbackName;

        // Check if user has a C++ impl file in src/ (anything that isn't generated or dart_api_dl)
        final srcDir = Directory(p.join(root.path, 'src'));
        final cppImplFiles = srcDir.existsSync()
            ? srcDir
                  .listSync()
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.cpp') && !f.path.contains('.bridge.g.') && !f.path.contains('.test.g.') && !f.path.contains('dart_api_dl'))
                  .toList()
            : <File>[];

        if (cppImplFiles.isNotEmpty) {
          // Check if any impl file registers the implementation
          final anyRegisters = cppImplFiles.any((f) => f.readAsStringSync().contains('${lib}_register_impl'));
          if (anyRegisters) {
            ok(cppSec, '$lib: ${lib}_register_impl() wired up in user impl');
          } else {
            warn(cppSec, '$lib: ${lib}_register_impl(&impl) not found in src/', hint: 'Call ${lib}_register_impl(&impl) at startup before first Dart use');
          }
        } else {
          info(cppSec, '$lib: Create src/Hybrid$moduleName.cpp, subclass Hybrid$moduleName, then call ${lib}_register_impl(&impl)');
        }

        // Check .clangd includes the test/ directory (for GoogleMock IDE support)
        final clangdFile = File(p.join(root.path, '.clangd'));
        if (clangdFile.existsSync() && clangdFile.readAsStringSync().contains('generated/cpp/test')) {
          ok(cppSec, '.clangd includes generated/cpp/test/ (GoogleMock IDE support)');
        } else {
          info(cppSec, 'Run: nitrogen link (adds generated/cpp/test/ to .clangd for IDE mock support)');
        }
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
    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      stderr.writeln('❌ No Nitro project found in . or its subdirectories (must have nitro dependency in pubspec.yaml).');
      exit(1);
    }

    // Change working directory so that doctor checks (File('ios'), etc) work correctly.
    final originalCwd = Directory.current;
    Directory.current = projectDir;

    if (projectDir.path != originalCwd.path) {
      stdout.writeln('  \x1B[90m📂 Found project in: ${projectDir.path}\x1B[0m');
    }

    final result = performChecks(root: projectDir);

    await runApp(
      DoctorView(
        pluginName: result.pluginName,
        sections: result.sections,
        errors: result.errors,
        warnings: result.warnings,
        errorMessage: result.errorMessage,
      ),
    );

    // Print persistent one-liner after TUI exits
    if (result.errorMessage == null) {
      if (result.errors == 0 && result.warnings == 0) {
        stdout.writeln('  \x1B[1;32m✨ ${result.pluginName} — all checks passed\x1B[0m');
      } else if (result.errors > 0) {
        stdout.writeln(
          '  \x1B[1;31m✘  ${result.pluginName} — ${result.errors} error(s)'
          '${result.warnings > 0 ? ", ${result.warnings} warning(s)" : ""}\x1B[0m',
        );
      } else {
        stdout.writeln('  \x1B[1;33m⚠  ${result.pluginName} — ${result.warnings} warning(s)\x1B[0m');
      }
      stdout.writeln('');
    }

    exit(result.errors > 0 ? 1 : 0);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  List<File> _findSpecs({Directory? root}) {
    root ??= Directory.current;
    final libDir = Directory(p.join(root.path, 'lib'));
    if (!libDir.existsSync()) return [];
    return libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList();
  }

  String _generatedPath(String specPath, String stem, String suffix) {
    final specDir = p.dirname(specPath);
    if (suffix == '.g.dart') return p.join(specDir, '$stem$suffix');
    return p.join(specDir, 'generated', _generatedSubdir[suffix]!, '$stem$suffix');
  }

  String? _extractLibName(File specFile) {
    final content = specFile.readAsStringSync();
    final match = RegExp(r'''@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]''').firstMatch(content);
    return match?.group(1);
  }

  String _pluginName(File pubspec) {
    for (final line in pubspec.readAsLinesSync()) {
      if (line.trim().startsWith('name: ')) {
        return line.replaceFirst('name: ', '').trim();
      }
    }
    return 'unknown';
  }
}

String _toPascalCase(String lib) => lib.split(RegExp(r'[_\-]')).map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');

class DoctorViewResult {
  final String pluginName;
  final List<DoctorSection> sections;
  final int errors;
  final int warnings;
  final String? errorMessage;
  DoctorViewResult({
    required this.pluginName,
    required this.sections,
    required this.errors,
    required this.warnings,
    this.errorMessage,
  });
}
