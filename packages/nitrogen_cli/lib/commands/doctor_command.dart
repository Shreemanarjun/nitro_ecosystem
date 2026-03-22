import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

class DoctorCommand extends Command {
  @override
  final String name = 'doctor';

  @override
  final String description =
      'Checks that all Nitrogen-generated files are present and up to date, '
      'and that the build system (CMake, Plugin.kt, Podspec) is wired correctly.';

  // Generated file extensions produced for each *.native.dart spec
  static const _generatedSuffixes = [
    '.g.dart',
    '.bridge.g.kt',
    '.bridge.g.swift',
    '.bridge.g.h',
    '.bridge.g.cpp',
    '.CMakeLists.g.txt',
  ];

  // Subdirectory under lib/src/generated/ for each non-dart output
  static const _generatedSubdir = {
    '.bridge.g.kt': 'kotlin',
    '.bridge.g.swift': 'swift',
    '.bridge.g.h': 'cpp',
    '.bridge.g.cpp': 'cpp',
    '.CMakeLists.g.txt': 'cmake',
  };

  @override
  void run() {
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      stderr.writeln('No pubspec.yaml found. Run from the root of a Flutter plugin.');
      exit(1);
    }

    final pluginName = _pluginName(pubspecFile);
    final specs = _findSpecs();

    if (specs.isEmpty) {
      stdout.writeln('No *.native.dart specs found under lib/.');
      return;
    }

    int errors = 0;
    int warnings = 0;

    for (final spec in specs) {
      final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      stdout.writeln('\nChecking $stem...');

      // ── Generated files ──────────────────────────────────────────────────
      final specMtime = spec.lastModifiedSync();
      for (final suffix in _generatedSuffixes) {
        final genPath = _generatedPath(spec.path, stem, suffix);
        final genFile = File(genPath);

        if (!genFile.existsSync()) {
          _printIssue('MISSING', genPath);
          errors++;
        } else {
          final genMtime = genFile.lastModifiedSync();
          if (specMtime.isAfter(genMtime)) {
            _printIssue('STALE ', genPath,
                hint: 'spec is newer than generated file — run build_runner');
            warnings++;
          } else {
            _printOk(p.relative(genPath));
          }
        }
      }
    }

    // ── CMakeLists.txt ───────────────────────────────────────────────────────
    stdout.writeln('\nChecking CMakeLists.txt...');
    final cmakeFile = File(p.join('src', 'CMakeLists.txt'));
    if (!cmakeFile.existsSync()) {
      _printIssue('MISSING', 'src/CMakeLists.txt',
          hint: 'Run: dart run nitrogen_cli link');
      errors++;
    } else {
      final cmakeContent = cmakeFile.readAsStringSync();
      for (final spec in specs) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
        if (!cmakeContent.contains('add_library($lib ')) {
          _printIssue('MISSING', 'add_library($lib ...) in src/CMakeLists.txt',
              hint: 'Run: dart run nitrogen_cli link');
          errors++;
        } else {
          _printOk('add_library($lib) in src/CMakeLists.txt');
        }
      }
    }

    // ── Kotlin Plugin.kt ─────────────────────────────────────────────────────
    stdout.writeln('\nChecking android Plugin.kt...');
    final kotlinDir = Directory(p.join('android', 'src', 'main', 'kotlin'));
    if (kotlinDir.existsSync()) {
      final pluginFiles = kotlinDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('Plugin.kt'))
          .toList();

      if (pluginFiles.isEmpty) {
        _printIssue('MISSING', 'android/.../Plugin.kt');
        warnings++;
      } else {
        final pluginContent = pluginFiles.first.readAsStringSync();
        for (final spec in specs) {
          final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
          if (!pluginContent.contains('System.loadLibrary("$lib")')) {
            _printIssue('MISSING', 'System.loadLibrary("$lib") in Plugin.kt',
                hint: 'Run: dart run nitrogen_cli link');
            errors++;
          } else {
            _printOk('System.loadLibrary("$lib") in Plugin.kt');
          }
        }
      }
    } else {
      _printOk('android/ not present — skipping');
    }

    // ── iOS Podspec ──────────────────────────────────────────────────────────
    stdout.writeln('\nChecking iOS podspec...');
    final podspecFiles = Directory('ios')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.podspec'))
        .toList();
    if (podspecFiles.isEmpty) {
      _printOk('ios/ not present — skipping');
    } else {
      final podContent = podspecFiles.first.readAsStringSync();
      if (!podContent.contains('HEADER_SEARCH_PATHS')) {
        _printIssue('MISSING', 'HEADER_SEARCH_PATHS in ${p.basename(podspecFiles.first.path)}',
            hint: 'Run: dart run nitrogen_cli link');
        errors++;
      } else {
        _printOk('HEADER_SEARCH_PATHS in ${p.basename(podspecFiles.first.path)}');
      }
    }

    // ── Summary ──────────────────────────────────────────────────────────────
    stdout.writeln('');
    if (errors == 0 && warnings == 0) {
      stdout.writeln('$pluginName is healthy — all checks passed.');
    } else {
      if (errors > 0) stderr.writeln('$errors error(s) found.');
      if (warnings > 0) stdout.writeln('$warnings warning(s) found.');
      if (errors > 0) exit(1);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<File> _findSpecs() {
    final libDir = Directory('lib');
    if (!libDir.existsSync()) return [];
    return libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.native.dart'))
        .toList();
  }

  /// Returns the expected path for a generated file given the spec path,
  /// stem (e.g. "my_camera"), and the output suffix (e.g. ".bridge.g.kt").
  String _generatedPath(String specPath, String stem, String suffix) {
    final specDir = p.dirname(specPath); // e.g. lib/src
    if (suffix == '.g.dart') {
      return p.join(specDir, '$stem$suffix');
    }
    final subdir = _generatedSubdir[suffix]!;
    return p.join(specDir, 'generated', subdir, '$stem$suffix');
  }

  String? _extractLibName(File specFile) {
    final content = specFile.readAsStringSync();
    final match = RegExp(r'''@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]''')
        .firstMatch(content);
    return match?.group(1);
  }

  String _pluginName(File pubspec) {
    for (final line in pubspec.readAsLinesSync()) {
      if (line.startsWith('name: ')) return line.replaceFirst('name: ', '').trim();
    }
    return 'unknown';
  }

  void _printOk(String label) => stdout.writeln('  ✔  $label');

  void _printIssue(String kind, String label, {String? hint}) {
    stderr.writeln('  ✘  $kind  $label');
    if (hint != null) stderr.writeln('       → $hint');
  }
}
