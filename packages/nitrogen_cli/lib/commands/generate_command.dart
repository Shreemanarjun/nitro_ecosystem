import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../ui.dart';
import '../utils.dart' show killBuildRunner;
import 'link_command.dart'
    show
        cleanRedundantIncludes,
        createSharedHeaders,
        resolveNitroNativePath,
        isCppModule,
        findPodfileDirs,
        discoverModuleInfos,
        linkCMake,
        linkPodspec,
        linkMacosPodspec,
        linkSwiftPlugin,
        linkMacosSwiftPlugin,
        purgeStaleCppSwiftRegistrations,
        linkKotlinPlugin,
        linkKotlinLoadLibraries,
        purgeStaleCppKotlinRegistrations,
        linkAndroid,
        linkWindows,
        linkLinux,
        linkClangd,
        isAppleCppModule,
        isAndroidCppModule;

class GenerateCommand extends Command {
  GenerateCommand() {
    argParser
      ..addFlag(
        'no-ui',
        negatable: false,
        help: 'Plain-text headless output (no ANSI). Auto-enabled when stdout is not a TTY.',
      )
      ..addFlag(
        'fail-on-warn',
        negatable: false,
        help: 'Exit with code 2 if build_runner emits any [WARNING] lines.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show per-phase timing breakdown.',
      );
  }

  @override
  final String name = 'generate';

  @override
  final String description = 'Runs the Nitrogen code generator (build_runner) with live output.';

  bool get _headless => !stdout.hasTerminal || (argResults!['no-ui'] as bool);
  bool get _verbose => argResults!['verbose'] as bool;

  void _logTiming(String phase, Duration elapsed) {
    if (!_verbose) return;
    final ms = elapsed.inMilliseconds;
    final label = ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)}s' : '${ms}ms';
    if (_headless) {
      stdout.writeln('[nitro:timing] $phase: $label');
    } else {
      stdout.writeln(gray('     ⏱  $phase: $label'));
    }
  }

  void _log(String msg) {
    if (_headless) {
      stdout.writeln('[nitro] $msg');
    } else {
      stdout.writeln(cyan('  › $msg'));
    }
  }

  void _logError(String msg) {
    if (_headless) {
      stderr.writeln('[nitro:error] $msg');
    } else {
      stderr.writeln(boldRed('  ✘  $msg'));
    }
  }

  /// Executes the generation logic and returns the exit code.
  /// Does NOT call exit().
  Future<int> execute() async {
    final failOnWarn = argResults!['fail-on-warn'] as bool;

    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      _logError('No Nitro project found in . or its subdirectories (must have nitro dependency in pubspec.yaml).');
      return 1;
    }

    if (projectDir.path != Directory.current.path) {
      if (_headless) {
        stdout.writeln('[nitro] project: ${projectDir.path}');
      } else {
        stdout.writeln(gray('  📂 Found project in: ${projectDir.path}'));
      }
    }

    if (_headless) {
      stdout.writeln('[nitro] nitrogen generate');
    } else {
      stdout.writeln('');
      stdout.writeln(boldCyan('  ╔══════════════════════════╗'));
      stdout.writeln(boldCyan('  ║  nitrogen generate       ║'));
      stdout.writeln(boldCyan('  ╚══════════════════════════╝'));
      stdout.writeln('');
    }

    final totalStart = DateTime.now();

    // ── pub get ─────────────────────────────────────────────────────────────
    _log('flutter pub get …');
    final t0 = DateTime.now();
    final pubGetResult = await runStreamingInspected(
      'flutter', ['pub', 'get'],
      workingDirectory: projectDir.path,
      headless: _headless,
    );
    _logTiming('pub get', DateTime.now().difference(t0));
    var exitCode = pubGetResult.exitCode;
    // Exit 255 is a known Dart SDK advisory-decode bug (pub.dev API mismatch).
    // Packages are still resolved successfully — do not abort.
    if (exitCode != 0 && exitCode != 255) {
      _logError('flutter pub get failed (exit $exitCode)');
      return exitCode;
    }
    if (!_headless) stdout.writeln('');

    // ── build_runner ─────────────────────────────────────────────────────────
    // Use `flutter pub run` (not `dart run`) because Flutter projects require
    // Flutter's package resolution — `dart run build_runner` fails with
    // "Flutter users should use flutter pub instead of dart pub".
    //
    // Stop any already-running build_runner first. A second invocation hangs
    // indefinitely waiting for the lock file; killing the old process and
    // removing the lock file lets the new one start immediately.
    final existingCount = await killBuildRunner(workingDirectory: projectDir.path);
    if (existingCount > 0) {
      if (_headless) {
        stdout.writeln('[nitro] stopped existing build_runner instance');
      } else {
        stdout.writeln(gray('  › Stopped existing build_runner instance.'));
      }
    }

    // Delete only the lock file and asset graph — NOT the entrypoint/ directory.
    // The entrypoint/ directory contains the AOT-compiled builder snapshot; deleting
    // it forces an expensive recompile (~10-15 s) on every run. Deleting just the
    // lock + asset graph is enough to let build_runner start fresh without
    // triggering the "check for updates → dart pub get → exit 247" failure that
    // occurs in Flutter workspace members on the second run.
    final buildDir = p.join(projectDir.path, '.dart_tool', 'build');
    for (final name in ['lock', 'asset_graph.json']) {
      final f = File(p.join(buildDir, name));
      if (f.existsSync()) f.deleteSync();
    }

    _log('build_runner build …');
    if (!_headless) stdout.writeln('');
    final t1 = DateTime.now();
    final buildResult = await runStreamingInspected(
      'flutter',
      ['pub', 'run', 'build_runner', 'build', '--delete-conflicting-outputs'],
      workingDirectory: projectDir.path,
      headless: _headless,
      scanWarnings: failOnWarn,
    );
    _logTiming('build_runner', DateTime.now().difference(t1));
    exitCode = buildResult.exitCode;

    if (!_headless) stdout.writeln('');
    if (exitCode != 0) {
      _logError('build_runner failed (exit $exitCode)');
      if (!_headless) stderr.writeln(gray('     Check the output above for details.'));
      return exitCode;
    }

    if (failOnWarn && buildResult.hadWarnings) {
      if (_headless) {
        stderr.writeln('[nitro:warn] build_runner emitted warnings — failing due to --fail-on-warn');
      } else {
        stderr.writeln(yellow('  ⚠  Warnings detected. Failing due to --fail-on-warn.'));
      }
      return 2;
    }

    // ── Post-generation bridge cleanup ───────────────────────────────────────
    // Generated Swift bridges live in lib/src/generated/swift/ and are compiled
    // via the podspec source_files pattern. Remove any stale copies from Classes/
    // to prevent "Invalid redeclaration" Swift compiler errors.
    final nitroNativePath = resolveNitroNativePath(projectDir.path);
    createSharedHeaders(nitroNativePath, baseDir: projectDir.path);
    _syncSwiftBridgesToClasses(projectDir.path);

    // ── nitrogen link (auto) ─────────────────────────────────────────────────
    // Automatically run the patching logic (build.gradle, Plugin.kt, etc.)
    // so users don't have to remember to run `nitrogen link` manually.
    _log('nitrogen link (auto-patching) …');
    final pluginName = _readPluginName(projectDir.path);
    final moduleInfos = discoverModuleInfos(pluginName, baseDir: projectDir.path);
    final hasCpp = moduleInfos.any((m) => m.isCpp);
    final hasNonCpp = moduleInfos.any((m) => !m.isCpp);

    // Patch CMake and C++ stubs
    linkCMake(pluginName, moduleInfos.map((m) => m.lib).toList(), nitroNativePath, baseDir: projectDir.path, moduleInfos: moduleInfos);

    // Patch iOS/macOS
    if (Directory(p.join(projectDir.path, 'ios')).existsSync()) {
      linkPodspec(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: projectDir.path, moduleInfos: moduleInfos);
      if (hasNonCpp) {
        final appleCppLibs = moduleInfos.where((m) => isAppleCppModule(File(p.join(projectDir.path, 'lib', 'src', '${m.lib}.native.dart')))).map((m) => m.lib).toSet();
        final swiftModules = moduleInfos.where((m) => !appleCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
        linkSwiftPlugin(pluginName, swiftModules, baseDir: projectDir.path);
        purgeStaleCppSwiftRegistrations(moduleInfos.where((m) => appleCppLibs.contains(m.lib)).toList(), platform: 'ios', baseDir: projectDir.path);
      }
    }
    if (Directory(p.join(projectDir.path, 'macos')).existsSync()) {
      linkMacosPodspec(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: projectDir.path, moduleInfos: moduleInfos);
      if (hasNonCpp) {
        final appleCppLibs = moduleInfos.where((m) => isAppleCppModule(File(p.join(projectDir.path, 'lib', 'src', '${m.lib}.native.dart')))).map((m) => m.lib).toSet();
        final swiftModules = moduleInfos.where((m) => !appleCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
        linkMacosSwiftPlugin(pluginName, swiftModules, baseDir: projectDir.path);
        purgeStaleCppSwiftRegistrations(moduleInfos.where((m) => appleCppLibs.contains(m.lib)).toList(), platform: 'macos', baseDir: projectDir.path);
      }
    }

    // Patch Android
    if (Directory(p.join(projectDir.path, 'android')).existsSync()) {
      // Use isAndroidCppModule (android-only) — NOT isNativeCppModule (android+linux).
      // A module with 'android: NativeImpl.kotlin, linux: NativeImpl.cpp' still needs
      // a Kotlin JniBridge on Android and must not be excluded from kotlinModules.
      final androidCppLibs = moduleInfos.where((m) => isAndroidCppModule(File(p.join(projectDir.path, 'lib', 'src', '${m.lib}.native.dart')))).map((m) => m.lib).toSet();
      final kotlinModules = moduleInfos.where((m) => !androidCppLibs.contains(m.lib)).map((m) => m.toMap()).toList();
      if (kotlinModules.isNotEmpty) {
        linkKotlinPlugin(pluginName, kotlinModules, baseDir: projectDir.path);
      }
      if (hasCpp) {
        linkKotlinLoadLibraries(moduleInfos.where((m) => m.isCpp).map((m) => m.lib).toList(), baseDir: projectDir.path);
      }
      purgeStaleCppKotlinRegistrations(moduleInfos.where((m) => androidCppLibs.contains(m.lib)).toList(), baseDir: projectDir.path);
      linkAndroid(pluginName, moduleInfos.map((m) => m.lib).toList(), baseDir: projectDir.path, moduleInfos: moduleInfos);
    }

    // Patch Desktop
    if (Directory(p.join(projectDir.path, 'windows')).existsSync()) {
      linkWindows(pluginName, moduleInfos.map((m) => m.lib).toList(), nitroNativePath, baseDir: projectDir.path, moduleInfos: moduleInfos);
    }
    if (Directory(p.join(projectDir.path, 'linux')).existsSync()) {
      linkLinux(pluginName, moduleInfos.map((m) => m.lib).toList(), nitroNativePath, baseDir: projectDir.path, moduleInfos: moduleInfos);
    }

    linkClangd(pluginName, moduleInfos: moduleInfos, baseDir: projectDir.path);

    // ── pod install ──────────────────────────────────────────────────────────
    final podfileDirs = findPodfileDirs(projectDir.path);
    for (final dir in podfileDirs) {
      _log('pod install (${p.relative(dir, from: projectDir.path)}) …');
      final podResult = await runStreamingInspected(
        'pod', ['install'],
        workingDirectory: dir,
        headless: _headless,
      );
      if (podResult.exitCode != 0) {
        if (_headless) {
          stderr.writeln('[nitro:warn] pod install failed in $dir (exit ${podResult.exitCode}) — continuing');
        } else {
          stderr.writeln(red('  ⚠  pod install failed in $dir (exit ${podResult.exitCode}) — continuing'));
        }
      }
    }

    // Detect whether any spec uses NativeImpl.cpp to tailor the next-steps hint
    final libDir = Directory(p.join(projectDir.path, 'lib'));
    final hasCppModules = libDir.existsSync() && libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.native.dart')).any(isCppModule);

    _logTiming('total', DateTime.now().difference(totalStart));

    if (_headless) {
      stdout.writeln('[nitro] generation complete');
      if (hasCppModules) {
        final pubspecName = _readPluginName(projectDir.path);
        stdout.writeln('[nitro] C++ modules: subclass Hybrid<Module>, call ${pubspecName}_register_impl(&impl)');
      }
    } else {
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
    }
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

  /// Copies generated `*.bridge.g.swift` files from `lib/src/generated/swift/`
  /// into `ios/Classes/` and `macos/Classes/`. This ensures Xcode compiles them
  /// in the same module scope as the other Swift plugin files, resolving
  /// "Cannot find X in scope" errors.
  ///
  /// Also ensures the podspec `source_files` only uses `'Classes/**/*'` (not
  /// the outer lib glob) to prevent duplicate-symbol errors.
  ///
  /// Also heals any redundant `#include` lines in `src/*.cpp` files.
  void _syncSwiftBridgesToClasses(String projectRoot) {
    final swiftGenDir = Directory(p.join(projectRoot, 'lib', 'src', 'generated', 'swift'));
    if (!swiftGenDir.existsSync()) {
      _healCppIncludes(projectRoot);
      return;
    }

    final bridgeFiles = swiftGenDir.listSync().whereType<File>().where((f) => p.basename(f.path).endsWith('.bridge.g.swift')).toList();
    if (bridgeFiles.isEmpty) {
      _healCppIncludes(projectRoot);
      return;
    }

    final pluginName = _readPluginName(projectRoot);

    for (final platform in ['ios', 'macos']) {
      for (final prefix in ['', 'example/']) {
        final classesDir = Directory(p.join(projectRoot, '$prefix$platform', 'Classes'));
        if (!classesDir.existsSync()) continue;

        // Copy each bridge file into Classes/.
        for (final bridge in bridgeFiles) {
          bridge.copySync(p.join(classesDir.path, p.basename(bridge.path)));
        }

        // Ensure the podspec does NOT have the outer ../lib/src/generated/swift glob
        // (that would cause duplicate-symbol errors since the file is now in Classes/).
        final podspecFile = File(p.join(projectRoot, '$prefix$platform', '$pluginName.podspec'));
        if (podspecFile.existsSync()) {
          var spec = podspecFile.readAsStringSync();
          final fixed = spec
              .replaceAll(", '../lib/src/generated/swift/**/*.swift'", '')
              .replaceAll("'../lib/src/generated/swift/**/*.swift', ", '')
              .replaceAll("'../lib/src/generated/swift/**/*.swift'", "'Classes/**/*'");
          if (fixed != spec) podspecFile.writeAsStringSync(fixed);
        }
      }
    }

    _healCppIncludes(projectRoot);
  }

  /// Heals any redundant `#include` lines in the main `src/` folder.
  void _healCppIncludes(String projectRoot) {
    final srcDir = Directory(p.join(projectRoot, 'src'));
    if (srcDir.existsSync()) {
      for (final f in srcDir.listSync().whereType<File>().where((f) => f.path.endsWith('.cpp') || f.path.endsWith('.c'))) {
        cleanRedundantIncludes(f);
      }
    }
  }
}
