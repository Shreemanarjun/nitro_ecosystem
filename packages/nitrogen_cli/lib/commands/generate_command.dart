import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'link_command.dart' show cleanRedundantIncludes, createSharedHeaders, resolveNitroNativePath, isCppModule;
import '../ui.dart';

class GenerateCommand extends Command {
  @override
  final String name = 'generate';

  @override
  final String description = 'Runs the Nitrogen code generator (build_runner) with live output.';

  /// Executes the generation logic and returns the exit code.
  /// Does NOT call exit().
  Future<int> execute() async {
    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      stderr.writeln(red('❌ No Nitro project found in . or its subdirectories (must have nitro dependency in pubspec.yaml).'));
      return 1;
    }

    // If we're not in the project root, let the user know we've found it
    if (projectDir.path != Directory.current.path) {
      stdout.writeln(gray('  📂 Found project in: ${projectDir.path}'));
    }

    stdout.writeln('');
    stdout.writeln(boldCyan('  ╔══════════════════════════╗'));
    stdout.writeln(boldCyan('  ║  nitrogen generate       ║'));
    stdout.writeln(boldCyan('  ╚══════════════════════════╝'));
    stdout.writeln('');

    // ── pub get ─────────────────────────────────────────────────────────────
    stdout.writeln(cyan('  › flutter pub get …'));
    var exitCode = await runStreaming('flutter', ['pub', 'get'], workingDirectory: projectDir.path);
    if (exitCode != 0) {
      stderr.writeln(red('  ✘  flutter pub get failed (exit $exitCode)'));
      return exitCode;
    }
    stdout.writeln('');

    // ── build_runner ─────────────────────────────────────────────────────────
    stdout.writeln(cyan('  › build_runner build …'));
    stdout.writeln('');
    exitCode = await runStreaming(
      'flutter',
      [
        'pub',
        'run',
        'build_runner',
        'build',
        '--delete-conflicting-outputs',
      ],
      workingDirectory: projectDir.path,
    );

    stdout.writeln('');
    if (exitCode != 0) {
      stderr.writeln(boldRed('  ✘  build_runner failed (exit $exitCode)'));
      stderr.writeln(gray('     Check the output above for details.'));
      return exitCode;
    }

    // ── Sync generated Swift bridges to ios/Classes/ ─────────────────────────
    final nitroNativePath = resolveNitroNativePath(projectDir.path);
    createSharedHeaders(nitroNativePath, baseDir: projectDir.path);
    _syncSwiftToIosClasses(projectDir.path);

    // ── pod install ──────────────────────────────────────────────────────────
    final podfileDirs = _findPodfileDirs(projectDir.path);
    for (final dir in podfileDirs) {
      stdout.writeln(cyan('  › pod install (${p.relative(dir, from: projectDir.path)}) …'));
      final podExitCode = await runStreaming(
        'pod',
        ['install'],
        workingDirectory: dir,
      );
      if (podExitCode != 0) {
        stderr.writeln(red('  ⚠  pod install failed in $dir (exit $podExitCode) — continuing'));
      }
    }

    // Detect whether any spec uses NativeImpl.cpp to tailor the next-steps hint
    final libDir = Directory(p.join(projectDir.path, 'lib'));
    final hasCppModules = libDir.existsSync() &&
        libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).any(isCppModule);

    stdout.writeln('');
    stdout.writeln(boldGreen('  ✨ Generation complete!'));
    if (hasCppModules) {
      final pubspecName = _readPluginName(projectDir.path);
      stdout.writeln(gray('     C++ modules: subclass Hybrid<Module>, call ${pubspecName}_register_impl(&impl).'));
      stdout.writeln(gray('     Run nitrogen link to wire bridges into the build system.'));
    } else {
      stdout.writeln(gray('     Run nitrogen link to wire bridges into the build system.'));
    }
    stdout.writeln('');
    return 0;
  }

  @override
  Future<void> run() async {
    final exitCode = await execute();
    if (exitCode != 0) exit(exitCode);
  }

  String _readPluginName(String projectRoot) {
    final pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return 'my_plugin';
    for (final line in pubspec.readAsLinesSync()) {
      if (line.startsWith('name: ')) return line.replaceFirst('name: ', '').trim();
    }
    return 'my_plugin';
  }

  /// Copies every *.bridge.g.swift from lib/**/generated/swift/ into
  /// ios/Classes/ so CocoaPods always picks up the freshly generated bridges.
  /// Skips files that only contain the "Not applicable" placeholder produced
  /// for NativeImpl.cpp modules (no Swift bridge is needed there).
  void _syncSwiftToIosClasses(String projectRoot) {
    final iosClasses = Directory(p.join(projectRoot, 'ios', 'Classes'));
    if (!iosClasses.existsSync()) return;

    final libDir = Directory(p.join(projectRoot, 'lib'));
    if (!libDir.existsSync()) return;

    final bridgeFiles = libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.bridge.g.swift'));

    for (final src in bridgeFiles) {
      // Skip placeholder files produced for NativeImpl.cpp modules.
      final firstLine = src.readAsLinesSync().firstOrNull ?? '';
      if (firstLine.contains('Not applicable')) continue;
      final dest = File(p.join(iosClasses.path, p.basename(src.path)));
      src.copySync(dest.path);
    }

    // Sync *.native.g.h files for NativeImpl.cpp modules into ios/Classes/
    // so that Xcode / CocoaPods can resolve them during Swift-interop builds.
    _syncCppInterfaceHeaders(projectRoot, iosClasses.path);

    // Also heal any redundant includes in the main src/ folder
    final srcDir = Directory(p.join(projectRoot, 'src'));
    if (srcDir.existsSync()) {
      for (final f in srcDir.listSync().whereType<File>().where((f) => f.path.endsWith('.cpp') || f.path.endsWith('.c'))) {
        cleanRedundantIncludes(f);
      }
    }
  }

  /// Copies *.native.g.h files generated for NativeImpl.cpp modules into
  /// [iosClassesPath] so Clang can resolve them from Swift/ObjC++ files.
  void _syncCppInterfaceHeaders(String projectRoot, String iosClassesPath) {
    final libDir = Directory(p.join(projectRoot, 'lib'));
    if (!libDir.existsSync()) return;

    // Find corresponding .native.dart specs to check isCppModule
    final specs = libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).toList();

    for (final spec in specs) {
      if (!isCppModule(spec)) continue;
      final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      final header = File(p.join(p.dirname(spec.path), 'generated', 'cpp', '$stem.native.g.h'));
      if (!header.existsSync()) continue;
      File(p.join(iosClassesPath, p.basename(header.path))).writeAsStringSync(header.readAsStringSync());
    }
  }

  /// Returns directories containing a Podfile, searching common locations:
  /// `<root>/ios/`, `<root>/example/ios/`, and any direct child `*/ios/`.
  List<String> _findPodfileDirs(String projectRoot) {
    final candidates = [
      p.join(projectRoot, 'ios'),
      p.join(projectRoot, 'example', 'ios'),
    ];

    // Also check any direct subdirectory that has an ios/ with a Podfile.
    try {
      for (final entity in Directory(projectRoot).listSync()) {
        if (entity is Directory) {
          candidates.add(p.join(entity.path, 'ios'));
        }
      }
    } catch (_) {}

    return candidates.where((dir) => File(p.join(dir, 'Podfile')).existsSync()).toList();
  }
}
