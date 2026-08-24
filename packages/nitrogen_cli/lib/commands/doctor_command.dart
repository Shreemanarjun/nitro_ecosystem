import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import 'package:nitrogen_cli/version.dart';
import 'link_command.dart' show PlatformTargetAnalyzer, isCppModule, isNativeCppModule, readBridgeChecksum, stampedBridgeChecksums, webSpecificImplPath, webUsesSpecificImpl;
import 'spm_utils.dart';
import '../ui.dart';
import '../templates/build_versions.dart';

part 'doctor/toolchain.dart';
part 'doctor/cmake.dart';
part 'doctor/android.dart';
part 'doctor/apple.dart';
part 'doctor/desktop.dart';
part 'doctor/generated.dart';
part 'doctor/web.dart';

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

// ── Doctor check context ──────────────────────────────────────────────────────

/// Shared, mutable state threaded through every `_check*` method of
/// [DoctorCommand.performChecks].
class _DoctorCtx {
  _DoctorCtx(this.root, this.pluginName, this.specs);
  final Directory root;
  final String pluginName;
  final List<File> specs;
  final List<DoctorSection> sections = [];
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

  void checkFilePermissions(
    DoctorSection section,
    FileSystemEntity entity,
    String label, {
    bool requireRead = true,
    bool requireWrite = true,
  }) {
    try {
      final stat = entity.statSync();
      const readBits = 0x124; // owner/group/other read: 0400 | 0040 | 0004
      const writeBits = 0x92; // owner/group/other write: 0200 | 0020 | 0002
      if (requireRead && (stat.mode & readBits) == 0) {
        warn(
          section,
          '$label is not readable',
          hint: 'Fix permissions before running nitrogen link/doctor: chmod u+r ${p.relative(entity.path, from: root.path)}',
        );
      }
      if (requireWrite && (stat.mode & writeBits) == 0) {
        warn(
          section,
          '$label is not writable',
          hint: 'Fix permissions before running nitrogen link: chmod u+w ${p.relative(entity.path, from: root.path)}',
        );
      }
    } on FileSystemException catch (e) {
      warn(
        section,
        'Could not inspect permissions for $label',
        hint: e.message,
      );
    }
  }
}

// ── DoctorCommand ─────────────────────────────────────────────────────────────

class DoctorCommand extends Command {
  DoctorCommand() {
    argParser.addFlag(
      'no-ui',
      negatable: false,
      help: 'Plain-text headless output (no ANSI). Auto-enabled when stdout is not a TTY.',
    );
  }

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

    final ctx = _DoctorCtx(root, _pluginName(pubspecFile), _findSpecs(root: root));

    _checkSystemToolchain(ctx);
    _checkPubspec(ctx);

    // ── Apple SPM ──────────────────────────────────────────────────────────────
    final spmStatus = detectSpmStatus(root.path);
    _checkAppleSpm(ctx, spmStatus);

    _checkGeneratedFiles(ctx);
    _checkCmake(ctx);

    // Whether any / all specs use NativeImpl.cpp — used below to skip irrelevant checks.
    final allSpecsCpp = ctx.specs.isNotEmpty && ctx.specs.every(isCppModule);
    final hasAnyCppSpec = ctx.specs.any(isCppModule);
    final hasAnyNonCppSpec = ctx.specs.any((s) => !isCppModule(s));

    _checkAndroid(ctx, allSpecsCpp, hasAnyNonCppSpec);
    _checkIos(ctx, spmStatus, allSpecsCpp, hasAnyNonCppSpec);
    _checkMacos(ctx, spmStatus, allSpecsCpp, hasAnyNonCppSpec);

    // When the platform CMakeLists delegates to src/, check src/CMakeLists.txt
    // as the authoritative source of truth for dart_api_dl.c / bridge.g.cpp.
    final srcCmake = File(p.join(root.path, 'src', 'CMakeLists.txt'));
    final srcCmakeContent = srcCmake.existsSync() ? srcCmake.readAsStringSync() : '';
    _checkWindows(ctx, srcCmakeContent);
    _checkLinux(ctx, srcCmakeContent);
    _checkDesktopImplParity(ctx);
    _checkWeb(ctx);

    if (hasAnyCppSpec) _checkCppDirect(ctx);
    _checkCocoaPodsPermissions(ctx);
    _checkExampleApp(ctx);
    _checkBuildRunnerHazard(ctx);

    return DoctorViewResult(
      pluginName: ctx.pluginName,
      sections: ctx.sections,
      errors: ctx.errors,
      warnings: ctx.warnings,
    );
  }

  bool get _headless => !stdout.hasTerminal || (argResults!['no-ui'] as bool);

  @override
  Future<void> run() async {
    final headless = _headless;

    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      if (headless) {
        stderr.writeln('[nitro:error] No Nitro project found in . or its subdirectories (must have nitro dependency in pubspec.yaml).');
      } else {
        stderr.writeln('❌ No Nitro project found in . or its subdirectories (must have nitro dependency in pubspec.yaml).');
      }
      exit(1);
    }

    // Change working directory so that doctor checks (File('ios'), etc) work correctly.
    final originalCwd = Directory.current;
    Directory.current = projectDir;

    if (projectDir.path != originalCwd.path) {
      if (headless) {
        stdout.writeln('[nitro] project: ${projectDir.path}');
      } else {
        stdout.writeln('  \x1B[90m📂 Found project in: ${projectDir.path}\x1B[0m');
      }
    }

    final result = performChecks(root: projectDir);

    if (headless) {
      _printHeadless(result);
    } else {
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
    }

    exit(result.errors > 0 ? 1 : 0);
  }

  void _printHeadless(DoctorViewResult result) {
    stdout.writeln('[nitro] nitrogen doctor — ${result.pluginName}');
    if (result.errorMessage != null) {
      stderr.writeln('[nitro:error] ${result.errorMessage}');
      return;
    }
    for (final section in result.sections) {
      stdout.writeln('[nitro:section] ${section.title}');
      for (final check in section.checks) {
        final prefix = switch (check.status) {
          DoctorStatus.ok => '[nitro:ok]',
          DoctorStatus.warn => '[nitro:warn]',
          DoctorStatus.error => '[nitro:error]',
          DoctorStatus.info => '[nitro:info]',
        };
        final out = check.status == DoctorStatus.error || check.status == DoctorStatus.warn ? stderr : stdout;
        out.writeln('$prefix ${check.label}');
        if (check.hint != null) out.writeln('[nitro:hint]   → ${check.hint}');
      }
    }
    if (result.errors == 0 && result.warnings == 0) {
      stdout.writeln('[nitro] all checks passed');
    } else {
      final out = result.errors > 0 ? stderr : stdout;
      out.writeln('[nitro:summary] ${result.errors} error(s), ${result.warnings} warning(s)');
    }
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

// ── Windows/Linux CMake helpers ──────────────────────────────────────────────

/// Returns true when [cmake] uses add_subdirectory to the shared src/ directory
/// (Nitro layout). dart_api_dl.c and bridge files are then compiled via
/// src/CMakeLists.txt, so checking the platform file directly would be a false error.
bool _usesSharedSrc(String cmake) => cmake.contains('add_subdirectory') && (cmake.contains('"../src"') || cmake.contains(r'"${CMAKE_CURRENT_SOURCE_DIR}/../src"'));

/// Returns true when the platform CMakeLists declares its own `<pkg>_plugin`
/// registrant target (multi-spec plugin shape).
bool _hasOwnPluginTarget(String cmake) => RegExp(r'add_library\(\s*\$\{PLUGIN_NAME\}').hasMatch(cmake);

// ── PX15 helpers ───────────────────────────────────────────────────────────

/// Returns the full path of [exe] if it is on PATH, null otherwise.
String? _findOnPath(String exe) {
  try {
    final r = Process.runSync('where', [exe]);
    if (r.exitCode == 0) {
      return r.stdout.toString().trim().split('\n').first.trim();
    }
  } catch (_) {}
  return null;
}

/// Runs [exe] --version and returns the first line of stdout/stderr, or null.
String? _runVersionCheck(String exe) {
  try {
    final r = Process.runSync(exe, ['--version']);
    if (r.exitCode == 0) {
      final out = r.stdout.toString().trim();
      final err = r.stderr.toString().trim();
      final text = out.isNotEmpty ? out : err;
      return text.split('\n').first.trim();
    }
  } catch (_) {}
  return null;
}

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
