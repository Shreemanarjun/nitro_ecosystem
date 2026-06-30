import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
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
        'dry-run',
        negatable: false,
        help: 'Print files and actions that would be generated without writing anything.',
      )
      ..addFlag(
        'check',
        negatable: false,
        help: 'Check whether generated files are up to date. Exits 3 when stale.',
      )
      ..addOption(
        'targets',
        help: 'Comma-separated output targets: dart,kotlin,swift,cpp,cmake,native,test. Platform aliases are also supported.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show per-phase timing breakdown.',
      )
      ..addOption(
        'directory',
        abbr: 'C',
        help: 'Project root directory (default: current directory).',
        hide: true,
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
    final dryRun = argResults!['dry-run'] as bool;
    final check = argResults!['check'] as bool;
    final targets = _parseTargets(argResults!['targets'] as String?);
    if (targets == null) return 1;

    final startDir = argResults!['directory'] as String?;
    final projectDir = findNitroProjectRoot(startDir: startDir);
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

    if (dryRun) {
      _printDryRunPlan(projectDir.path, targets);
      return 0;
    }

    if (check) {
      return _checkGeneratedFiles(projectDir.path, targets);
    }

    final totalStart = DateTime.now();
    final specFiles = _discoverNativeSpecFiles(projectDir.path);
    final incrementalCache = IncrementalGenerationCache(projectDir.path);
    final incrementalPlan = incrementalCache.plan(
      specs: specFiles,
      outputPathsForSpec: (spec) => _generatedOutputsForSpec(projectDir.path, spec, targets),
    );

    if (!incrementalPlan.hasChanges) {
      if (_headless) {
        stdout.writeln('[nitro] no spec changes detected — generation skipped');
      } else {
        stdout.writeln(gray('  › no spec changes detected — generation skipped'));
      }
      _logTiming('total', DateTime.now().difference(totalStart));
      return 0;
    }

    // ── pub get ─────────────────────────────────────────────────────────────
    _log('flutter pub get …');
    final t0 = DateTime.now();
    final pubGetResult = await runStreamingInspected(
      'flutter',
      ['pub', 'get'],
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

    // Delete only the lock file — NOT the entrypoint/ directory.
    // The entrypoint/ directory contains the AOT-compiled builder snapshot; deleting
    // it forces an expensive recompile (~10-15 s) on every run. Keeping the
    // asset graph lets build_runner preserve its own incremental cache while
    // still clearing stale locks from crashed processes.
    deleteBuildRunnerLock(projectDir.path);

    _log('build_runner build …');
    if (!_headless) stdout.writeln('');
    final t1 = DateTime.now();
    final buildArgs = [
      'pub',
      'run',
      'build_runner',
      'build',
      '--delete-conflicting-outputs',
      ...targets.buildFilterArgs(projectDir.path, incrementalPlan.changedSpecs),
    ];
    final buildResult = await runStreamingInspected(
      'flutter',
      buildArgs,
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

    incrementalCache.write(
      specs: specFiles,
      outputPathsForSpec: (spec) => _generatedOutputsForSpec(projectDir.path, spec, targets),
    );

    // ── Post-generation bridge cleanup ───────────────────────────────────────
    // Generated Swift bridges live in lib/src/generated/swift/ and are compiled
    // via the podspec source_files pattern. Remove any stale copies from Classes/
    // to prevent "Invalid redeclaration" Swift compiler errors.
    if (targets.isDartOnly) {
      _logTiming('total', DateTime.now().difference(totalStart));
      if (_headless) {
        stdout.writeln('[nitro] generation complete');
      } else {
        stdout.writeln('');
        stdout.writeln(boldGreen('  ✨ Generation complete!'));
        stdout.writeln('');
      }
      return 0;
    }

    final nitroNativePath = resolveNitroNativePath(projectDir.path);
    createSharedHeaders(nitroNativePath, baseDir: projectDir.path);

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
    // Strip shared preamble from 2nd+ bridge files AFTER linkSwift* copies them
    // to Classes/. linkSwiftPlugin copies without stripping; this pass corrects that.
    _syncSwiftBridgesToClasses(projectDir.path);

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
        'pod',
        ['install'],
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

  void _printDryRunPlan(String projectRoot, _GenerateTargetSelection targets) {
    final specFiles = _discoverNativeSpecFiles(projectRoot);
    final generatedFiles = specFiles.expand((file) => _generatedOutputsForSpec(projectRoot, file, targets)).toList();
    final podfileDirs = findPodfileDirs(projectRoot);

    void line(String msg) {
      if (_headless) {
        stdout.writeln('[nitro:dry-run] $msg');
      } else {
        stdout.writeln(gray('  › dry-run: $msg'));
      }
    }

    void would(String msg) {
      if (_headless) {
        stdout.writeln('[nitro:would] $msg');
      } else {
        stdout.writeln(cyan('  › would $msg'));
      }
    }

    line('project: $projectRoot');
    if (targets.isRestricted) {
      line('targets: ${targets.labels.join(',')}');
    }
    if (specFiles.isEmpty) {
      line('no .native.dart specs found under lib/');
    } else {
      line('specs: ${specFiles.length}');
      for (final spec in specFiles) {
        line('spec: ${p.relative(spec.path, from: projectRoot)}');
      }
    }

    if (generatedFiles.isNotEmpty) {
      line('generated outputs: ${generatedFiles.length}');
      for (final output in generatedFiles) {
        would('write ${p.relative(output, from: projectRoot)}');
      }
    }

    would('run flutter pub get');
    final buildFilters = targets.buildFilterArgs(projectRoot, specFiles);
    final buildCmd = [
      'flutter',
      'pub',
      'run',
      'build_runner',
      'build',
      '--delete-conflicting-outputs',
      ...buildFilters,
    ].join(' ');
    would('run $buildCmd');
    if (!targets.isDartOnly) {
      would('sync generated Swift bridges into ios/macos Classes directories');
      would('run nitrogen link auto-patching');
      if (podfileDirs.isEmpty) {
        line('pod install: no Podfile directories found');
      } else {
        for (final dir in podfileDirs) {
          would('run pod install in ${p.relative(dir, from: projectRoot)}');
        }
      }
    }
    line('no files were written');
  }

  int _checkGeneratedFiles(String projectRoot, _GenerateTargetSelection targets) {
    final specFiles = _discoverNativeSpecFiles(projectRoot);
    final issues = <_GeneratedFileIssue>[];

    for (final spec in specFiles) {
      final specModified = spec.lastModifiedSync();
      for (final outputPath in _generatedOutputsForSpec(projectRoot, spec, targets)) {
        final output = File(outputPath);
        if (!output.existsSync()) {
          issues.add(_GeneratedFileIssue.missing(outputPath));
          continue;
        }
        if (output.lastModifiedSync().isBefore(specModified)) {
          issues.add(_GeneratedFileIssue.stale(outputPath));
        }
      }
    }

    if (issues.isEmpty) {
      if (_headless) {
        stdout.writeln('[nitro] generated files are up to date');
      } else {
        stdout.writeln(green('  ✔ generated files are up to date'));
      }
      return 0;
    }

    if (_headless) {
      stderr.writeln('[nitro:error] generated files are stale');
      for (final issue in issues) {
        stderr.writeln('[nitro:stale] ${issue.kind} ${p.relative(issue.path, from: projectRoot)}');
      }
      stderr.writeln('[nitro:hint] Run: nitrogen generate');
    } else {
      stderr.writeln(boldRed('  ✘ generated files are stale'));
      for (final issue in issues) {
        stderr.writeln(yellow('     ${issue.kind}: ${p.relative(issue.path, from: projectRoot)}'));
      }
      stderr.writeln(gray('     Run: nitrogen generate'));
    }
    return 3;
  }

  List<File> _discoverNativeSpecFiles(String projectRoot) {
    final libDir = Directory(p.join(projectRoot, 'lib'));
    if (!libDir.existsSync()) return const [];
    return libDir.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.native.dart')).toList()..sort((a, b) => a.path.compareTo(b.path));
  }

  List<String> _generatedOutputsForSpec(String projectRoot, File specFile, [_GenerateTargetSelection targets = const _GenerateTargetSelection.all()]) {
    final libDir = p.join(projectRoot, 'lib');
    final relToLib = p.relative(specFile.path, from: libDir);
    final specDir = p.dirname(relToLib) == '.' ? '' : p.dirname(relToLib);
    final fileName = p.basename(relToLib);
    final stem = fileName.substring(0, fileName.length - '.native.dart'.length);
    final specOutputDir = p.join(projectRoot, 'lib', specDir);
    final outputs = [
      p.join(specOutputDir, '$stem.g.dart'),
      p.join(specOutputDir, 'generated', 'kotlin', '$stem.bridge.g.kt'),
      p.join(specOutputDir, 'generated', 'swift', '$stem.bridge.g.swift'),
      p.join(specOutputDir, 'generated', 'cpp', '$stem.bridge.g.h'),
      p.join(specOutputDir, 'generated', 'cpp', '$stem.bridge.g.cpp'),
      p.join(specOutputDir, 'generated', 'cmake', '$stem.CMakeLists.g.txt'),
      p.join(specOutputDir, 'generated', 'cpp', '$stem.native.g.h'),
      p.join(specOutputDir, 'generated', 'cpp', 'test', '$stem.mock.g.h'),
      p.join(specOutputDir, 'generated', 'cpp', 'test', '$stem.test.g.cpp'),
    ];
    return outputs.where(targets.matchesOutput).toList();
  }

  _GenerateTargetSelection? _parseTargets(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const _GenerateTargetSelection.all();
    final labels = <String>{};
    final suffixes = <String>{};
    for (final part in raw.split(',')) {
      final token = part.trim().toLowerCase();
      if (token.isEmpty) continue;
      labels.add(token);
      final mapped = _targetSuffixAliases[token];
      if (mapped == null) {
        _logError('Unknown target "$token". Expected one of: ${_targetSuffixAliases.keys.join(', ')}');
        return null;
      }
      suffixes.addAll(mapped);
    }
    if (suffixes.isEmpty) return const _GenerateTargetSelection.all();
    return _GenerateTargetSelection(Set.unmodifiable(suffixes), Set.unmodifiable(labels));
  }

  /// Copies generated `*.bridge.g.swift` files from `lib/src/generated/swift/`
  /// into `ios/Classes/` and `macos/Classes/`. This ensures Xcode compiles them
  /// in the same module scope as the other Swift plugin files, resolving
  /// "Cannot find X in scope" errors.
  ///
  /// When multiple bridge files exist (multi-spec plugin), the shared type
  /// preamble (NitroEncodable, NitroNullableInt, NitroRecordWriter, etc.) is
  /// stripped from all but the first bridge file to prevent Swift
  /// "invalid redeclaration" errors when all files are compiled into the same
  /// Swift module.
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

    final bridgeFiles = swiftGenDir.listSync().whereType<File>().where((f) => p.basename(f.path).endsWith('.bridge.g.swift')).toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    if (bridgeFiles.isEmpty) {
      _healCppIncludes(projectRoot);
      return;
    }

    final pluginName = _readPluginName(projectRoot);

    for (final platform in ['ios', 'macos']) {
      for (final prefix in ['', 'example/']) {
        final classesDir = Directory(p.join(projectRoot, '$prefix$platform', 'Classes'));
        if (!classesDir.existsSync()) continue;

        // When multiple specs share one module, only the first bridge file gets
        // the full shared-type preamble. Subsequent files have it stripped so
        // the Swift compiler doesn't see duplicate public type declarations.
        for (var i = 0; i < bridgeFiles.length; i++) {
          final bridge = bridgeFiles[i];
          final dest = p.join(classesDir.path, p.basename(bridge.path));
          if (i == 0 || bridgeFiles.length == 1) {
            bridge.copySync(dest);
          } else {
            _copyBridgeSwiftWithoutSharedPreamble(bridge, dest);
          }
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

        // Also sync to SPM Sources/ directory if it exists (Flutter 3.41+ nested layout).
        _syncBridgesToSpmSources(projectRoot, prefix, platform, bridgeFiles);
      }
    }

    _healCppIncludes(projectRoot);
  }

  /// Copies a bridge Swift file to [dest] but omits the shared public type
  /// declarations that are already defined in the first bridge file.
  void _copyBridgeSwiftWithoutSharedPreamble(File source, String dest) {
    File(dest).writeAsStringSync(stripSharedSwiftPreamble(source.readAsStringSync()));
  }

  /// Syncs bridge Swift files into the SPM Sources directory for a platform,
  /// applying the same shared-preamble stripping for files beyond the first.
  void _syncBridgesToSpmSources(
    String projectRoot,
    String prefix,
    String platform,
    List<File> bridgeFiles,
  ) {
    final pluginName = _readPluginName(projectRoot);
    final className = _toPascalCase(pluginName);

    // Support both flat (ios/Sources/<Class>/) and nested (ios/<name>/Sources/<Class>/).
    final platformRoot = p.join(projectRoot, '$prefix$platform');
    final candidates = [
      p.join(platformRoot, pluginName, 'Sources', className),
      p.join(platformRoot, 'Sources', className),
    ];

    for (final dir in candidates) {
      final sourcesDir = Directory(dir);
      if (!sourcesDir.existsSync()) continue;

      for (var i = 0; i < bridgeFiles.length; i++) {
        final bridge = bridgeFiles[i];
        final dest = p.join(dir, p.basename(bridge.path));
        if (i == 0 || bridgeFiles.length == 1) {
          bridge.copySync(dest);
        } else {
          _copyBridgeSwiftWithoutSharedPreamble(bridge, dest);
        }
      }
    }
  }

  static String _toPascalCase(String name) =>
      name.split(RegExp(r'[_\-]')).map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join('');

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

/// Strips the shared public type declarations from a Swift bridge file's content.
///
/// When multiple Nitro specs are compiled into the same Swift module, each
/// generated `*.bridge.g.swift` contains identical declarations for shared
/// types (`NitroEncodable`, `NitroNullableInt`, `NitroRecordWriter`, etc.).
/// Having these in more than one file causes "invalid redeclaration" errors.
///
/// This function keeps the file-private string helpers (lines before
/// `public protocol NitroEncodable`) and the spec-specific protocol + bridge
/// stubs (everything from the first `/**` doc-comment onward), but drops
/// the shared-type block in between.
///
/// The first bridge file in the module should NOT be stripped — it provides
/// the shared types for the entire module. Only 2nd and subsequent files need
/// this treatment.
///
/// Safe to apply when no shared block is present (e.g. already stripped or a
/// file that never had it): returns [content] unchanged.
String stripSharedSwiftPreamble(String content) {
  final lines = content.split('\n');
  final result = <String>[];
  var inSharedBlock = false;

  for (final line in lines) {
    if (!inSharedBlock && line.startsWith('public protocol NitroEncodable')) {
      inSharedBlock = true;
      continue;
    }
    if (inSharedBlock) {
      // Resume at the `/**` doc-comment that precedes the spec-specific protocol.
      if (line.startsWith('/**')) {
        inSharedBlock = false;
        result.add(line);
      }
      continue;
    }
    result.add(line);
  }

  return result.join('\n');
}

class _GeneratedFileIssue {
  const _GeneratedFileIssue(this.kind, this.path);

  factory _GeneratedFileIssue.missing(String path) => _GeneratedFileIssue('missing', path);

  factory _GeneratedFileIssue.stale(String path) => _GeneratedFileIssue('stale', path);

  final String kind;
  final String path;
}

class _GenerateTargetSelection {
  const _GenerateTargetSelection(this.suffixes, this.labels);

  const _GenerateTargetSelection.all() : suffixes = const {}, labels = const {};

  final Set<String> suffixes;
  final Set<String> labels;

  bool get isRestricted => suffixes.isNotEmpty;

  bool get isDartOnly => isRestricted && suffixes.length == 1 && suffixes.contains('.g.dart');

  bool matchesOutput(String path) => !isRestricted || suffixes.any(path.endsWith);

  List<String> buildFilterArgs(String projectRoot, List<File> specs) {
    if (!isRestricted) return const [];
    return specs.expand((spec) => _candidateOutputs(projectRoot, spec).where(matchesOutput)).map((output) => '--build-filter=${p.relative(output, from: projectRoot)}').toList();
  }

  static List<String> _candidateOutputs(String projectRoot, File specFile) {
    final libDir = p.join(projectRoot, 'lib');
    final relToLib = p.relative(specFile.path, from: libDir);
    final specDir = p.dirname(relToLib) == '.' ? '' : p.dirname(relToLib);
    final fileName = p.basename(relToLib);
    final stem = fileName.substring(0, fileName.length - '.native.dart'.length);
    final specOutputDir = p.join(projectRoot, 'lib', specDir);
    return [
      p.join(specOutputDir, '$stem.g.dart'),
      p.join(specOutputDir, 'generated', 'kotlin', '$stem.bridge.g.kt'),
      p.join(specOutputDir, 'generated', 'swift', '$stem.bridge.g.swift'),
      p.join(specOutputDir, 'generated', 'cpp', '$stem.bridge.g.h'),
      p.join(specOutputDir, 'generated', 'cpp', '$stem.bridge.g.cpp'),
      p.join(specOutputDir, 'generated', 'cmake', '$stem.CMakeLists.g.txt'),
      p.join(specOutputDir, 'generated', 'cpp', '$stem.native.g.h'),
      p.join(specOutputDir, 'generated', 'cpp', 'test', '$stem.mock.g.h'),
      p.join(specOutputDir, 'generated', 'cpp', 'test', '$stem.test.g.cpp'),
    ];
  }
}

class IncrementalGenerationPlan {
  const IncrementalGenerationPlan(this.changedSpecs);

  final List<File> changedSpecs;

  bool get hasChanges => changedSpecs.isNotEmpty;
}

bool deleteBuildRunnerLock(String projectRoot) {
  final lockFile = File(p.join(projectRoot, '.dart_tool', 'build', 'lock'));
  if (!lockFile.existsSync()) return false;
  lockFile.deleteSync();
  return true;
}

class IncrementalGenerationCache {
  IncrementalGenerationCache(this.projectRoot);

  static const manifestRelativePath = '.dart_tool/nitro/cache.json';

  final String projectRoot;

  File get manifestFile => File(p.join(projectRoot, manifestRelativePath));

  IncrementalGenerationPlan plan({
    required List<File> specs,
    required List<String> Function(File spec) outputPathsForSpec,
  }) {
    final manifest = _readManifest();
    final changed = <File>[];
    for (final spec in specs) {
      final rel = p.relative(spec.path, from: projectRoot);
      final hash = contentHash(spec);
      final entry = manifest[rel];
      final cachedHash = entry is Map<String, dynamic> ? entry['hash'] as String? : null;
      final outputPaths = outputPathsForSpec(spec);
      final missingOutput = outputPaths.any((path) => !File(path).existsSync());
      if (cachedHash != hash || missingOutput) {
        changed.add(spec);
      }
    }
    return IncrementalGenerationPlan(List.unmodifiable(changed));
  }

  void write({
    required List<File> specs,
    required List<String> Function(File spec) outputPathsForSpec,
  }) {
    final manifest = <String, Object>{};
    for (final spec in specs) {
      final rel = p.relative(spec.path, from: projectRoot);
      manifest[rel] = {
        'hash': contentHash(spec),
        'outputFiles': outputPathsForSpec(spec).map((path) => p.relative(path, from: projectRoot)).toList(),
      };
    }
    manifestFile.parent.createSync(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    manifestFile.writeAsStringSync('${encoder.convert(manifest)}\n');
  }

  Map<String, dynamic> _readManifest() {
    if (!manifestFile.existsSync()) return const {};
    try {
      final decoded = jsonDecode(manifestFile.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return const {};
  }

  static String contentHash(File file) {
    return sha256.convert(file.readAsBytesSync()).toString();
  }
}

const _targetSuffixAliases = <String, Set<String>>{
  'dart': {'.g.dart'},
  'ffi': {'.g.dart'},
  'kotlin': {'.bridge.g.kt'},
  'android': {'.g.dart', '.bridge.g.kt', '.bridge.g.h', '.bridge.g.cpp', '.CMakeLists.g.txt'},
  'swift': {'.bridge.g.swift'},
  'ios': {'.g.dart', '.bridge.g.swift', '.bridge.g.h', '.bridge.g.cpp', '.CMakeLists.g.txt'},
  'macos': {'.g.dart', '.bridge.g.swift', '.bridge.g.h', '.bridge.g.cpp', '.CMakeLists.g.txt'},
  'apple': {'.g.dart', '.bridge.g.swift', '.bridge.g.h', '.bridge.g.cpp', '.CMakeLists.g.txt'},
  'cpp': {'.bridge.g.h', '.bridge.g.cpp', '.native.g.h'},
  'cbridge': {'.bridge.g.h', '.bridge.g.cpp'},
  'c_bridge': {'.bridge.g.h', '.bridge.g.cpp'},
  'bridge': {'.bridge.g.h', '.bridge.g.cpp'},
  'cmake': {'.CMakeLists.g.txt'},
  'build': {'.CMakeLists.g.txt'},
  'native': {'.native.g.h'},
  'cpp_native': {'.native.g.h', '.mock.g.h', '.test.g.cpp'},
  'test': {'.mock.g.h', '.test.g.cpp'},
  'windows': {'.g.dart', '.bridge.g.h', '.bridge.g.cpp', '.CMakeLists.g.txt', '.native.g.h'},
  'linux': {'.g.dart', '.bridge.g.h', '.bridge.g.cpp', '.CMakeLists.g.txt', '.native.g.h'},
  'desktop': {'.g.dart', '.bridge.g.h', '.bridge.g.cpp', '.CMakeLists.g.txt', '.native.g.h'},
};
