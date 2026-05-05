import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/version.dart';
import 'link_command.dart' show isCppModule, isNativeCppModule;
import 'spm_utils.dart';
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

  /// Serialises the doctor report to plain text for clipboard copy.
  String _reportAsText() {
    final buf = StringBuffer();
    buf.writeln('nitrogen doctor — ${component.pluginName}');
    buf.writeln('');
    for (final section in component.sections) {
      buf.writeln('[${section.title}]');
      for (final check in section.checks) {
        final icon = switch (check.status) {
          DoctorStatus.ok => '✔',
          DoctorStatus.warn => '⚠',
          DoctorStatus.error => '✘',
          DoctorStatus.info => 'ℹ',
        };
        buf.write('  $icon ${check.label}');
        if (check.hint != null) buf.write('  (${check.hint})');
        buf.writeln();
      }
      buf.writeln();
    }
    if (component.errorMessage != null) {
      buf.writeln('ERROR: ${component.errorMessage}');
    } else if (component.errors == 0 && component.warnings == 0) {
      buf.writeln('✨ All checks passed.');
    } else {
      buf.writeln('Summary: ${component.errors} error(s), ${component.warnings} warning(s)');
    }
    return buf.toString();
  }

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
    // 'c' / 'C' — copy the doctor report to clipboard
    if (e.character == 'c' || e.character == 'C') {
      copyToClipboard(_reportAsText());
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
                    CopyButton(getData: _reportAsText),
                    const Text('  •  ', style: TextStyle(color: Colors.brightBlack)),
                    Text(
                      '↑↓ scroll   PgUp/PgDn   c copy   ${component.onExit != null ? 'ESC back' : 'ESC exit'}',
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

    if (pubspec.contains('  macos:')) {
      if (RegExp(r'macos:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:').hasMatch(pubspec)) {
        ok(pubSec, 'macos pluginClass defined');
      } else if (RegExp(r'macos:\s*\n(?:\s+\S[^\n]*\n)*\s+ffiPlugin:\s*true').hasMatch(pubspec)) {
        ok(pubSec, 'macos ffiPlugin: true (pluginClass optional for FFI plugins)');
      } else {
        warn(pubSec, 'macos pluginClass missing', hint: 'Add pluginClass or ffiPlugin: true under flutter.plugin.platforms.macos');
      }
    }

    // ── Apple SPM ──────────────────────────────────────────────────────────────
    final spmStatus = detectSpmStatus(root.path);
    if (Platform.isMacOS) {
      final spmSec = DoctorSection('Apple SPM (Swift Package Manager)');
      sections.add(spmSec);

      if (spmStatus.hasSpm) {
        if (spmStatus.isModern) {
          ok(spmSec, 'SPM-only setup (modern)');
        } else if (spmStatus.isMixed) {
          warn(spmSec, 'Mixed SPM + CocoaPods setup', hint: 'Run: nitrogen migrate  to complete SPM migration');
        }

        if (spmStatus.iosHasSpm) {
          final path = spmStatus.iosPackageSwiftPath!;
          final rel = p.relative(path, from: root.path);
          ok(spmSec, 'iOS: $rel');

          // Detect flat vs nested layout
          final segments = p.split(p.relative(p.dirname(path), from: root.path));
          if (segments.length >= 2 && segments[0] == 'ios') {
            ok(spmSec, 'iOS using Flutter 3.41+ nested SPM layout');
          } else {
            warn(spmSec, 'iOS using flat SPM layout (ios/Package.swift)', hint: 'Run: nitrogen migrate  to upgrade to nested Flutter 3.41+ layout');
          }

          for (final issue in spmStatus.issues.where((i) => i.startsWith('ios'))) {
            err(spmSec, issue, hint: 'Run: nitrogen migrate');
          }
          for (final w in spmStatus.warnings.where((w) => w.startsWith('ios'))) {
            warn(spmSec, w);
          }
        } else {
          info(spmSec, 'iOS SPM not configured');
        }

        if (spmStatus.macosHasSpm) {
          final path = spmStatus.macosPackageSwiftPath!;
          final rel = p.relative(path, from: root.path);
          ok(spmSec, 'macOS: $rel');

          final segments = p.split(p.relative(p.dirname(path), from: root.path));
          if (segments.length >= 2 && segments[0] == 'macos') {
            ok(spmSec, 'macOS using Flutter 3.41+ nested SPM layout');
          } else {
            warn(spmSec, 'macOS using flat SPM layout (macos/Package.swift)', hint: 'Run: nitrogen migrate  to upgrade to nested Flutter 3.41+ layout');
          }

          for (final issue in spmStatus.issues.where((i) => i.startsWith('macos'))) {
            err(spmSec, issue, hint: 'Run: nitrogen migrate');
          }
          for (final w in spmStatus.warnings.where((w) => w.startsWith('macos'))) {
            warn(spmSec, w);
          }
        } else {
          info(spmSec, 'macOS SPM not configured');
        }
      } else if (spmStatus.hasCocoaPods) {
        err(spmSec, 'CocoaPods detected — no SPM configuration found', hint: 'Run: nitrogen migrate  to migrate to Swift Package Manager');
      } else {
        info(spmSec, 'No Apple platform directories found');
      }
    }

    if (specs.isNotEmpty) {
      final genSec = DoctorSection('Generated Files');
      sections.add(genSec);
      for (final spec in specs) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final specMtime = spec.lastModifiedSync();
        final specIsCpp = isCppModule(spec);

        for (final suffix in _generatedSuffixes) {
          // .bridge.g.kt is only needed when Android uses Kotlin (not C++).
          // .bridge.g.swift is only needed when iOS/macOS uses Swift (not C++).
          // Use platform-specific checks instead of the broad isCppModule guard
          // so mixed modules (e.g. windows:cpp + android:kotlin) are correctly handled.
          if (suffix == '.bridge.g.kt' && !_isAndroidKotlinModule(spec)) {
            info(genSec, '${p.basename(spec.path)} → $suffix skipped (android: AndroidNativeImpl.cpp)');
            continue;
          }
          if (suffix == '.bridge.g.swift' && !_isAppleSwiftModule(spec)) {
            info(genSec, '${p.basename(spec.path)} → $suffix skipped (ios/macos: AppleNativeImpl.cpp)');
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

      // Build a lookup: impl file name → whether it's a native-cpp (android/linux)
      // module so we can skip “unlinked source” warnings for files that are
      // intentionally absent from the Android CMakeLists.txt (windows-only cpp).
      final nativeCppImplFiles = <String>{};
      for (final spec in specs) {
        if (!isNativeCppModule(spec)) continue;
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
        final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
        nativeCppImplFiles.add('Hybrid$moduleName.cpp');
      }

      // Check for unlinked source files in src/.
      // Skip HybridXxx.cpp files for modules that are NOT native-cpp (android/linux) —
      // e.g. a module that is only C++ on Windows has its impl in windows/CMakeLists.txt.
      final allSrcFiles = srcDir.listSync().whereType<File>().where((f) => f.path.endsWith('.cpp') || f.path.endsWith('.c')).toList();
      for (final f in allSrcFiles) {
        final name = p.basename(f.path);
        if (name == 'dart_api_dl.c') continue;
        if (name == '$pluginName.cpp' || name == '$pluginName.c') continue;
        // Hybrid impl files for windows-only cpp modules don’t belong in the
        // Android/Linux CMakeLists — skip them to avoid a false-positive warning.
        if (name.startsWith('Hybrid') && name.endsWith('.cpp') && !nativeCppImplFiles.contains(name)) continue;

        if (!cmake.contains('"$name"') && !cmake.contains(' $name ') && !cmake.contains('\n  $name')) {
          warn(cmakeSec, 'Unlinked source: $name', hint: 'File found in src/ but not mentioned in CMakeLists.txt');
        }
      }

      for (final spec in specs) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
        if (cmake.contains('add_library($lib ')) {
          ok(cmakeSec, 'add_library($lib) target present');

          // Verify HybridXxx.cpp is linked for native-cpp (android/linux) modules.
          // Windows-only cpp modules do NOT need this in src/CMakeLists.txt.
          if (isNativeCppModule(spec)) {
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
          // Warn if java.srcDirs also points at the generated kotlin directory.
          // In AGP 8.x this routes .kt files through the Java compiler path and
          // causes "Unresolved reference: XxxJniBridge" compile errors.
          if (RegExp(r'java\.srcDirs\s*\+=.*generated/kotlin').hasMatch(g)) {
            err(
              androidSec,
              'java.srcDirs includes generated/kotlin — causes "Unresolved reference: XxxJniBridge" in AGP 8.x',
              hint: 'Remove the java.srcDirs line; kotlin.srcDirs alone is sufficient',
            );
          }
        } else {
          err(androidSec, 'sourceSets entry for generated/kotlin missing',
              hint: 'Add: kotlin.srcDirs += "\${project.projectDir}/../lib/src/generated/kotlin"');
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

        // Check for stale JniBridge.register() calls for C++ modules.
        // When a module transitions from Kotlin/JNI to NativeImpl.cpp its
        // JniBridge class no longer exists, causing "Unresolved reference" at
        // compile time. nitrogen link auto-removes these, but doctor flags them
        // so users know to re-run link.
        for (final spec in specs.where(isCppModule)) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
          final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
          if (kt.contains('${moduleName}JniBridge.register(')) {
            err(
              androidSec,
              'Stale ${moduleName}JniBridge.register() in Plugin.kt — $moduleName is now NativeImpl.cpp',
              hint: 'Run: nitrogen link  (auto-removes stale registrations for C++ modules)',
            );
          }
        }

        // For each non-cpp Kotlin module, verify the JniBridge import is present.
        // Missing imports cause "Unresolved reference: FooJniBridge" Kotlin errors.
        // nitrogen link auto-injects these imports alongside the register() call.
        for (final spec in specs.where((s) => !isCppModule(s))) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = (_extractLibName(spec) ?? stem).replaceAll('-', '_');
          final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
          final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
          final importLine = 'import nitro.${lib}_module.${moduleName}JniBridge';
          if (!kt.contains(importLine)) {
            err(
              androidSec,
              'Missing import in Plugin.kt: $importLine',
              hint: 'Run: nitrogen link  (auto-adds missing JniBridge imports)',
            );
          } else {
            ok(androidSec, 'import ${moduleName}JniBridge present');
          }
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
        if (pod.contains("s.dependency 'nitro'")) {
          ok(iosSec, "s.dependency 'nitro' in $podName");
        } else {
          err(iosSec, "s.dependency 'nitro' missing in $podName", hint: 'Run: nitrogen link');
        }
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

        // Check source_files points to an existing path.
        // The SPM-first Flutter template generates paths like '<plugin>/Sources/<plugin>/**/*'
        // which are non-existent when CocoaPods is used, causing "No files found" warnings.
        final sourceFilesMatch = RegExp(r"s\.source_files\s*=\s*'([^']+)'").firstMatch(pod);
        if (sourceFilesMatch != null) {
          final sfPath = sourceFilesMatch.group(1)!;
          final firstSegment = sfPath.split('/').first;
          final firstDir = Directory(p.join(iosDir.path, firstSegment));
          if (firstSegment == 'Classes' || firstDir.existsSync()) {
            ok(iosSec, 'source_files path valid: $sfPath');
          } else {
            err(iosSec, 'source_files points to non-existent path: $sfPath',
                hint: "Run: nitrogen link  (fixes to 'Classes/**/*')");
          }
        }
      }

      final classesDir = Directory(p.join(iosDir.path, 'Classes'));
      if (allSpecsCpp) {
        // All C++ modules — no Swift Registry.register() needed.
        info(iosSec, 'All modules use NativeImpl.cpp — Swift bridge (Registry.register) not required');
        // .native.g.h uses C++ types (std::string, classes) and must NOT be placed in
        // ios/Classes/ — CocoaPods includes every header there into the umbrella header
        // which breaks Swift/ObjC compilation. It is reachable via HEADER_SEARCH_PATHS.
        // Verify that HEADER_SEARCH_PATHS includes lib/src/generated/cpp/ instead.
        final podFiles = iosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList();
        if (podFiles.isNotEmpty) {
          final pod = podFiles.first.readAsStringSync();
          if (pod.contains('lib/src/generated/cpp')) {
            ok(iosSec, '*.native.g.h reachable via HEADER_SEARCH_PATHS → lib/src/generated/cpp');
          } else {
            warn(iosSec, 'HEADER_SEARCH_PATHS may not include lib/src/generated/cpp (needed for *.native.g.h)', hint: 'Run: nitrogen link');
          }
        }
      } else {
        final swiftFiles = classesDir.existsSync()
            ? classesDir.listSync().whereType<File>().where((f) => f.path.endsWith('Plugin.swift')).toList()
            : <File>[];
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

          // Check for stale XxxRegistry.register() calls for C++ modules.
          // AppleNativeImpl.cpp modules have no Swift Registry — the call causes
          // "Cannot find 'XxxRegistry' in scope". nitrogen link auto-removes these.
          for (final spec in specs.where(isCppModule)) {
            final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
            final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
            final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
            if (swift.contains('${moduleName}Registry.register(')) {
              err(
                iosSec,
                'Stale ${moduleName}Registry.register() in Plugin.swift — $moduleName is now NativeImpl.cpp',
                hint: 'Run: nitrogen link  (auto-removes stale Swift registry calls for C++ modules)',
              );
            }
          }
        }
      }

      // ── dart_api_dl.c / nitro.h ─────────────────────────────────────────────
      // For SPM builds (Flutter 3.22+) these files live in Sources/<PluginCpp>/,
      // not ios/Classes/. Only check ios/Classes/ when there is no Package.swift.
      if (!spmStatus.iosHasSpm) {
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
      } else if (specs.isNotEmpty && !allSpecsCpp && !spmStatus.iosHasSpm) {
        // For CocoaPods-only builds, warn about missing .mm bridges.
        // For SPM builds, the bridge.g.mm belongs in Sources/<PluginCpp>/, not Classes/.
        warn(iosSec, 'No .bridge.g.mm files in ios/Classes/', hint: 'Run: nitrogen link');
      }

      // ── SPM target completeness ──────────────────────────────────────────────
      // Flutter 3.22+ compiles the plugin via Package.swift. Every file that
      // nitrogen link creates in Sources/<PluginCpp>/ is critical for the build.
      if (spmStatus.iosHasSpm && spmStatus.iosPackageSwiftPath != null) {
        final packageSwiftFile = File(spmStatus.iosPackageSwiftPath!);
        final packageRoot = packageSwiftFile.parent.path;
        final cppTargetName = '${_toPascalCase(pluginName)}Cpp';
        final spmCppDir = Directory(p.join(packageRoot, 'Sources', cppTargetName));

        // Validate Package.swift declares the C++ target with correct settings.
        final pkgSwift = packageSwiftFile.readAsStringSync();
        if (pkgSwift.contains(cppTargetName)) {
          ok(iosSec, 'Package.swift: $cppTargetName target defined');
        } else {
          err(iosSec, 'Package.swift: $cppTargetName target missing',
              hint: 'Run: nitrogen init  (re-creates Package.swift with the correct C++ target)');
        }
        if (pkgSwift.contains('c++17') || pkgSwift.contains('-std=c++17')) {
          ok(iosSec, 'Package.swift: cxxSettings -std=c++17 present');
        } else {
          warn(iosSec, 'Package.swift: -std=c++17 missing in cxxSettings',
              hint: 'Add .unsafeFlags(["-std=c++17"]) to the $cppTargetName cxxSettings');
        }
        if (pkgSwift.contains('publicHeadersPath')) {
          ok(iosSec, 'Package.swift: publicHeadersPath configured for $cppTargetName');
        } else {
          warn(iosSec, 'Package.swift: publicHeadersPath missing for $cppTargetName',
              hint: 'Run: nitrogen init  (sets publicHeadersPath: "include")');
        }

        if (spmCppDir.existsSync()) {
          // dart_api_dl.c — compiled as plain C; provides the Dart FFI bootstrap ABI
          final dartApiDlSpm = File(p.join(spmCppDir.path, 'dart_api_dl.c'));
          if (dartApiDlSpm.existsSync()) {
            ok(iosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c present');
          } else {
            err(iosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c missing',
                hint: 'Run: nitrogen link');
          }

          // <plugin>.cpp — forwarder that pulls in src/<plugin>.cpp via #include
          final pluginCppSpm = File(p.join(spmCppDir.path, '$pluginName.cpp'));
          final pluginCSpm = File(p.join(spmCppDir.path, '$pluginName.c'));
          if (pluginCppSpm.existsSync() || pluginCSpm.existsSync()) {
            ok(iosSec, 'SPM Sources/$cppTargetName/$pluginName.cpp forwarder present');
          } else {
            warn(iosSec, 'SPM Sources/$cppTargetName/$pluginName.cpp forwarder missing',
                hint: 'Run: nitrogen link');
          }

          // include/nitro.h — exposes NITRO_EXPORT and Nitro types to the C++ target
          final nitroHSpm = File(p.join(spmCppDir.path, 'include', 'nitro.h'));
          if (nitroHSpm.existsSync()) {
            ok(iosSec, 'SPM Sources/$cppTargetName/include/nitro.h present');
          } else {
            err(iosSec, 'SPM Sources/$cppTargetName/include/nitro.h missing',
                hint: 'Run: nitrogen link');
          }

          // bridge.g.mm — CRITICAL: compiled as Obj-C++ so that the SPM target
          // links the C symbols defined in bridge.g.cpp (init_dart_api_dl etc.).
          // Without this the plugin crashes at startup with:
          //   "Failed to lookup symbol '${pluginName}_init_dart_api_dl'"
          final spmMmBridges = spmCppDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.bridge.g.mm'))
              .toList();
          if (spmMmBridges.isNotEmpty) {
            ok(iosSec, '${spmMmBridges.length} .bridge.g.mm in SPM Sources/$cppTargetName/');
          } else if (specs.isNotEmpty) {
            err(iosSec, 'Missing .bridge.g.mm in SPM Sources/$cppTargetName/',
                hint: 'Run: nitrogen link  (symbol ${pluginName}_init_dart_api_dl will be missing at runtime)');
          }
        } else if (specs.isNotEmpty) {
          warn(iosSec, 'SPM Sources/$cppTargetName/ directory not found',
              hint: 'Run: nitrogen link  (creates the SPM C++ target with bridge forwarders)');
        }
      }
    }

    final macosSec = DoctorSection('macOS');
    sections.add(macosSec);
    final macosDir = Directory(p.join(root.path, 'macos'));
    if (!macosDir.existsSync()) {
      info(macosSec, 'macos/ directory not present — skipped');
    } else {
      final podFiles = macosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList();
      if (podFiles.isEmpty) {
        err(macosSec, 'No .podspec found in macos/', hint: 'Run: nitrogen init');
      } else {
        final pod = podFiles.first.readAsStringSync();
        final podName = p.basename(podFiles.first.path);
        if (pod.contains("s.dependency 'nitro'")) {
          ok(macosSec, "s.dependency 'nitro' in $podName");
        } else {
          err(macosSec, "s.dependency 'nitro' missing in $podName", hint: 'Run: nitrogen link');
        }
        if (pod.contains('HEADER_SEARCH_PATHS')) {
          ok(macosSec, 'HEADER_SEARCH_PATHS in $podName');
        } else {
          err(macosSec, 'HEADER_SEARCH_PATHS missing in $podName', hint: 'Run: nitrogen link');
        }
        if (pod.contains('c++17')) {
          ok(macosSec, 'CLANG_CXX_LANGUAGE_STANDARD = c++17');
        } else {
          warn(macosSec, 'CLANG_CXX_LANGUAGE_STANDARD not set to c++17', hint: "Set: 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' in pod_target_xcconfig");
        }
        if (pod.contains('lib/src/generated/cpp') && pod.contains('src/native')) {
          ok(macosSec, 'Comprehensive HEADER_SEARCH_PATHS in podspec');
        } else {
          warn(macosSec, 'Incomplete HEADER_SEARCH_PATHS in podspec', hint: 'Run: nitrogen link');
        }

        // Check source_files points to an existing path.
        final sourceFilesMatchMacos = RegExp(r"s\.source_files\s*=\s*'([^']+)'").firstMatch(pod);
        if (sourceFilesMatchMacos != null) {
          final sfPath = sourceFilesMatchMacos.group(1)!;
          final firstSegment = sfPath.split('/').first;
          final firstDir = Directory(p.join(macosDir.path, firstSegment));
          if (firstSegment == 'Classes' || firstDir.existsSync()) {
            ok(macosSec, 'source_files path valid: $sfPath');
          } else {
            err(macosSec, 'source_files points to non-existent path: $sfPath',
                hint: "Run: nitrogen link  (fixes to 'Classes/**/*')");
          }
        }
      }

      final macosClassesDir = Directory(p.join(macosDir.path, 'Classes'));
      if (allSpecsCpp) {
        info(macosSec, 'All modules use NativeImpl.cpp — Swift bridge (Registry.register) not required');
        // .native.g.h uses C++ types and must NOT be placed in macos/Classes/ —
        // CocoaPods includes every header there into the umbrella header, which
        // breaks Swift/ObjC compilation. Check HEADER_SEARCH_PATHS instead (same
        // logic as iOS). If SPM is active the file is also reachable via
        // Sources/NitroVaniCpp/ so the podspec check is advisory only.
        final macosPodFiles = macosDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec')).toList();
        if (macosPodFiles.isNotEmpty) {
          final pod = macosPodFiles.first.readAsStringSync();
          if (pod.contains('lib/src/generated/cpp')) {
            ok(macosSec, '*.native.g.h reachable via HEADER_SEARCH_PATHS → lib/src/generated/cpp');
          } else {
            warn(macosSec, 'HEADER_SEARCH_PATHS may not include lib/src/generated/cpp (needed for *.native.g.h)', hint: 'Run: nitrogen link');
          }
        }
      } else {
        final swiftFiles = macosClassesDir.existsSync() ? macosClassesDir.listSync().whereType<File>().where((f) => f.path.endsWith('Plugin.swift')).toList() : <File>[];
        if (swiftFiles.isEmpty) {
          err(macosSec, 'No *Plugin.swift in macos/Classes/', hint: 'Run: nitrogen init');
        } else {
          final swift = swiftFiles.first.readAsStringSync();
          if (hasAnyNonCppSpec) {
            if (swift.contains('Registry.register(') || swift.contains('.register(')) {
              ok(macosSec, 'Plugin.swift has Registry.register(...)');
            } else {
              warn(macosSec, 'Registry.register(...) not found in Plugin.swift', hint: 'Add: NitroModules.Registry.register(...) in register(with:)');
            }
          } else {
            info(macosSec, 'Registry.register not needed — all modules use NativeImpl.cpp');
          }
        }
      }

      // ── dart_api_dl.c / nitro.h ─────────────────────────────────────────────
      // For SPM builds (Flutter 3.22+) these files live in Sources/<PluginCpp>/,
      // not macos/Classes/. Only check macos/Classes/ when there is no Package.swift.
      if (!spmStatus.macosHasSpm) {
        final dartApiDl = File(p.join(macosDir.path, 'Classes', 'dart_api_dl.c'));
        if (dartApiDl.existsSync()) {
          ok(macosSec, 'macos/Classes/dart_api_dl.c present');
        } else {
          err(macosSec, 'macos/Classes/dart_api_dl.c missing', hint: 'Run: nitrogen link');
        }

        final nitroH = File(p.join(macosDir.path, 'Classes', 'nitro.h'));
        if (nitroH.existsSync()) {
          ok(macosSec, 'macos/Classes/nitro.h present');
        } else {
          err(macosSec, 'macos/Classes/nitro.h missing', hint: 'Run: nitrogen link');
        }
        if (nitroH.existsSync()) {
          final content = nitroH.readAsStringSync();
          if (content.contains('NITRO_EXPORT')) {
            ok(macosSec, 'nitro.h contains NITRO_EXPORT visibility macro');
          } else {
            err(macosSec, 'nitro.h missing NITRO_EXPORT visibility macro', hint: 'Run: nitrogen link');
          }
        }
      }

      final staleCppBridges = macosClassesDir.existsSync() ? macosClassesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.cpp')).toList() : <File>[];
      if (staleCppBridges.isNotEmpty) {
        for (final f in staleCppBridges) {
          err(macosSec, 'Stale .cpp bridge: ${p.basename(f.path)} (must be .mm)', hint: 'Run: nitrogen link (auto-renames .bridge.g.cpp → .bridge.g.mm)');
        }
      }

      final mmBridges = macosClassesDir.existsSync() ? macosClassesDir.listSync().whereType<File>().where((f) => f.path.endsWith('.bridge.g.mm')).toList() : <File>[];
      if (mmBridges.isNotEmpty) {
        ok(macosSec, '${mmBridges.length} .bridge.g.mm file(s) in macos/Classes/');
      } else if (specs.isNotEmpty && !allSpecsCpp && !spmStatus.macosHasSpm) {
        // For CocoaPods-only builds, warn about missing .mm bridges.
        // For SPM builds, the bridge.g.mm belongs in Sources/<PluginCpp>/, not Classes/.
        warn(macosSec, 'No .bridge.g.mm files in macos/Classes/', hint: 'Run: nitrogen link');
      }

      // ── SPM target completeness ──────────────────────────────────────────────
      // Flutter 3.22+ compiles the plugin via Package.swift. Every file that
      // nitrogen link creates in Sources/<PluginCpp>/ is critical for the build.
      if (spmStatus.macosHasSpm && spmStatus.macosPackageSwiftPath != null) {
        final packageSwiftFile = File(spmStatus.macosPackageSwiftPath!);
        final packageRoot = packageSwiftFile.parent.path;
        final cppTargetName = '${_toPascalCase(pluginName)}Cpp';
        final spmCppDir = Directory(p.join(packageRoot, 'Sources', cppTargetName));

        // Validate Package.swift declares the C++ target with correct settings.
        final pkgSwift = packageSwiftFile.readAsStringSync();
        if (pkgSwift.contains(cppTargetName)) {
          ok(macosSec, 'Package.swift: $cppTargetName target defined');
        } else {
          err(macosSec, 'Package.swift: $cppTargetName target missing',
              hint: 'Run: nitrogen init  (re-creates Package.swift with the correct C++ target)');
        }
        if (pkgSwift.contains('c++17') || pkgSwift.contains('-std=c++17')) {
          ok(macosSec, 'Package.swift: cxxSettings -std=c++17 present');
        } else {
          warn(macosSec, 'Package.swift: -std=c++17 missing in cxxSettings',
              hint: 'Add .unsafeFlags(["-std=c++17"]) to the $cppTargetName cxxSettings');
        }
        if (pkgSwift.contains('publicHeadersPath')) {
          ok(macosSec, 'Package.swift: publicHeadersPath configured for $cppTargetName');
        } else {
          warn(macosSec, 'Package.swift: publicHeadersPath missing for $cppTargetName',
              hint: 'Run: nitrogen init  (sets publicHeadersPath: "include")');
        }

        if (spmCppDir.existsSync()) {
          // dart_api_dl.c — compiled as plain C; provides the Dart FFI bootstrap ABI
          final dartApiDlSpm = File(p.join(spmCppDir.path, 'dart_api_dl.c'));
          if (dartApiDlSpm.existsSync()) {
            ok(macosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c present');
          } else {
            err(macosSec, 'SPM Sources/$cppTargetName/dart_api_dl.c missing',
                hint: 'Run: nitrogen link');
          }

          // <plugin>.cpp — forwarder that pulls in src/<plugin>.cpp via #include
          final pluginCppSpm = File(p.join(spmCppDir.path, '$pluginName.cpp'));
          final pluginCSpm = File(p.join(spmCppDir.path, '$pluginName.c'));
          if (pluginCppSpm.existsSync() || pluginCSpm.existsSync()) {
            ok(macosSec, 'SPM Sources/$cppTargetName/$pluginName.cpp forwarder present');
          } else {
            warn(macosSec, 'SPM Sources/$cppTargetName/$pluginName.cpp forwarder missing',
                hint: 'Run: nitrogen link');
          }

          // include/nitro.h — exposes NITRO_EXPORT and Nitro types to the C++ target
          final nitroHSpm = File(p.join(spmCppDir.path, 'include', 'nitro.h'));
          if (nitroHSpm.existsSync()) {
            ok(macosSec, 'SPM Sources/$cppTargetName/include/nitro.h present');
          } else {
            err(macosSec, 'SPM Sources/$cppTargetName/include/nitro.h missing',
                hint: 'Run: nitrogen link');
          }

          // bridge.g.mm — CRITICAL: compiled as Obj-C++ so that the SPM target
          // links the C symbols defined in bridge.g.cpp (init_dart_api_dl etc.).
          // Without this the plugin crashes at startup with:
          //   "Failed to lookup symbol '${pluginName}_init_dart_api_dl'"
          final spmMmBridges = spmCppDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.bridge.g.mm'))
              .toList();
          if (spmMmBridges.isNotEmpty) {
            ok(macosSec, '${spmMmBridges.length} .bridge.g.mm in SPM Sources/$cppTargetName/');
          } else if (specs.isNotEmpty) {
            err(macosSec, 'Missing .bridge.g.mm in SPM Sources/$cppTargetName/',
                hint: 'Run: nitrogen link  (symbol ${pluginName}_init_dart_api_dl will be missing at runtime)');
          }
        } else if (specs.isNotEmpty) {
          warn(macosSec, 'SPM Sources/$cppTargetName/ directory not found',
              hint: 'Run: nitrogen link  (creates the SPM C++ target with bridge forwarders)');
        }
      }
    }

    // ── Windows ──────────────────────────────────────────────────────────────
    // Helper: returns true when [cmake] uses add_subdirectory to the shared
    // src/ directory (Nitro layout). In that case dart_api_dl.c and bridge
    // files are compiled via src/CMakeLists.txt — checking the platform file
    // directly would produce false errors.
    bool usesSharedSrc(String cmake) =>
        cmake.contains('add_subdirectory') &&
        (cmake.contains('"../src"') ||
         cmake.contains(r'"${CMAKE_CURRENT_SOURCE_DIR}/../src"'));

    // When the platform CMakeLists delegates to src/, check src/CMakeLists.txt
    // as the authoritative source of truth for dart_api_dl.c / bridge.g.cpp.
    final srcCmake = File(p.join(root.path, 'src', 'CMakeLists.txt'));
    final srcCmakeContent = srcCmake.existsSync() ? srcCmake.readAsStringSync() : '';

    // ── Windows ───────────────────────────────────────────────────────────────
    final winSec = DoctorSection('Windows');
    sections.add(winSec);
    final winDir = Directory(p.join(root.path, 'windows'));
    if (!winDir.existsSync()) {
      info(winSec, 'windows/ directory not present — skipped');
    } else {
      final cmakeFile = File(p.join(winDir.path, 'CMakeLists.txt'));
      if (!cmakeFile.existsSync()) {
        err(winSec, 'windows/CMakeLists.txt not found', hint: 'Run: nitrogen link');
      } else {
        final cmake = cmakeFile.readAsStringSync();
        final sharedSrc = usesSharedSrc(cmake);
        // For NITRO_NATIVE, check both the platform file and src/CMakeLists.
        if (cmake.contains('NITRO_NATIVE') || (sharedSrc && srcCmakeContent.contains('NITRO_NATIVE'))) {
          ok(winSec, 'NITRO_NATIVE variable defined in windows/CMakeLists.txt');
        } else {
          err(winSec, 'NITRO_NATIVE missing in windows/CMakeLists.txt', hint: 'Run: nitrogen link');
        }
        // dart_api_dl.c: accept if present in platform file OR in src/ (via add_subdirectory).
        if (cmake.contains('dart_api_dl.c') || (sharedSrc && srcCmakeContent.contains('dart_api_dl.c'))) {
          ok(winSec, sharedSrc
              ? 'dart_api_dl.c compiled via src/CMakeLists.txt (add_subdirectory)'
              : 'dart_api_dl.c included in windows/CMakeLists.txt');
        } else {
          err(winSec, 'dart_api_dl.c not included in windows/CMakeLists.txt', hint: 'Run: nitrogen link');
        }
        for (final spec in specs) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
          final bridgeRel = '../lib/src/generated/cpp/$lib.bridge.g.cpp';
          // Accept if the bridge is in the platform file, or in src/CMakeLists (shared build).
          final inSrc = sharedSrc && (srcCmakeContent.contains('$lib.bridge.g.cpp') || srcCmakeContent.contains(bridgeRel));
          if (cmake.contains(bridgeRel) || inSrc) {
            ok(winSec, sharedSrc
                ? '$lib.bridge.g.cpp compiled via src/CMakeLists.txt'
                : '$lib.bridge.g.cpp linked in windows/CMakeLists.txt');
          } else {
            warn(winSec, '$lib.bridge.g.cpp not linked in windows/CMakeLists.txt', hint: 'Run: nitrogen link');
          }
        }
      }
    }

    // ── Linux ─────────────────────────────────────────────────────────────────
    final linuxSec = DoctorSection('Linux');
    sections.add(linuxSec);
    final linuxDir = Directory(p.join(root.path, 'linux'));
    if (!linuxDir.existsSync()) {
      info(linuxSec, 'linux/ directory not present — skipped');
    } else {
      final cmakeFile = File(p.join(linuxDir.path, 'CMakeLists.txt'));
      if (!cmakeFile.existsSync()) {
        err(linuxSec, 'linux/CMakeLists.txt not found', hint: 'Run: nitrogen link');
      } else {
        final cmake = cmakeFile.readAsStringSync();
        final sharedSrc = usesSharedSrc(cmake);
        if (cmake.contains('NITRO_NATIVE') || (sharedSrc && srcCmakeContent.contains('NITRO_NATIVE'))) {
          ok(linuxSec, 'NITRO_NATIVE variable defined in linux/CMakeLists.txt');
        } else {
          err(linuxSec, 'NITRO_NATIVE missing in linux/CMakeLists.txt', hint: 'Run: nitrogen link');
        }
        if (cmake.contains('dart_api_dl.c') || (sharedSrc && srcCmakeContent.contains('dart_api_dl.c'))) {
          ok(linuxSec, sharedSrc
              ? 'dart_api_dl.c compiled via src/CMakeLists.txt (add_subdirectory)'
              : 'dart_api_dl.c included in linux/CMakeLists.txt');
        } else {
          err(linuxSec, 'dart_api_dl.c not included in linux/CMakeLists.txt', hint: 'Run: nitrogen link');
        }
        for (final spec in specs) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
          final bridgeRel = '../lib/src/generated/cpp/$lib.bridge.g.cpp';
          final inSrc = sharedSrc && (srcCmakeContent.contains('$lib.bridge.g.cpp') || srcCmakeContent.contains(bridgeRel));
          if (cmake.contains(bridgeRel) || inSrc) {
            ok(linuxSec, sharedSrc
                ? '$lib.bridge.g.cpp compiled via src/CMakeLists.txt'
                : '$lib.bridge.g.cpp linked in linux/CMakeLists.txt');
          } else {
            warn(linuxSec, '$lib.bridge.g.cpp not linked in linux/CMakeLists.txt', hint: 'Run: nitrogen link');
          }
        }
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

/// Returns true when Android uses a Kotlin JNI bridge (not C++).
/// A .bridge.g.kt file is needed iff Android is NOT using AndroidNativeImpl.cpp.
bool _isAndroidKotlinModule(File specFile) {
  final content = specFile.readAsStringSync();
  final annotationMatch = RegExp(r'@NitroModule\s*\(([^)]+)\)', dotAll: true).firstMatch(content);
  if (annotationMatch == null) return true; // no annotation → assume Kotlin
  final annotation = annotationMatch.group(1)!.replaceAll('\n', ' ');
  // If android is explicitly .cpp, no Kotlin bridge is needed.
  return !RegExp(r'\bandroid\s*:\s*(?:NativeImpl|AndroidNativeImpl)\.cpp\b').hasMatch(annotation);
}

/// Returns true when iOS/macOS use a Swift bridge (not C++).
/// A .bridge.g.swift file is needed iff at least one of ios/macos is Swift.
bool _isAppleSwiftModule(File specFile) {
  final content = specFile.readAsStringSync();
  final annotationMatch = RegExp(r'@NitroModule\s*\(([^)]+)\)', dotAll: true).firstMatch(content);
  if (annotationMatch == null) return true; // no annotation → assume Swift
  final annotation = annotationMatch.group(1)!.replaceAll('\n', ' ');
  // Swift bridge is needed if any Apple platform is NOT .cpp.
  final iosIsCpp = RegExp(r'\bios\s*:\s*(?:NativeImpl|AppleNativeImpl)\.cpp\b').hasMatch(annotation);
  final macosIsCpp = RegExp(r'\bmacos\s*:\s*(?:NativeImpl|AppleNativeImpl)\.cpp\b').hasMatch(annotation);
  // If ios is absent and macos is absent, default to Swift (may not target Apple).
  final hasIos = RegExp(r'\bios\s*:').hasMatch(annotation);
  final hasMacos = RegExp(r'\bmacos\s*:').hasMatch(annotation);
  if (!hasIos && !hasMacos) return false;
  return !iosIsCpp || !macosIsCpp;
}

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
