part of '../doctor_command.dart';

extension _DoctorGeneratedChecks on DoctorCommand {
  void _checkGeneratedFiles(_DoctorCtx ctx) {
    if (ctx.specs.isNotEmpty) {
      final genSec = DoctorSection('Generated Files');
      ctx.sections.add(genSec);
      for (final spec in ctx.specs) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final specMtime = spec.lastModifiedSync();
        final specIsCpp = isCppModule(spec);

        for (final suffix in DoctorCommand._generatedSuffixes) {
          // .bridge.g.kt is only needed when Android uses Kotlin (not C++).
          // .bridge.g.swift is only needed when iOS/macOS uses Swift (not C++).
          // Use platform-specific checks instead of the broad isCppModule guard
          // so mixed modules (e.g. windows:cpp + android:kotlin) are correctly handled.
          if (suffix == '.bridge.g.kt' && !_isAndroidKotlinModule(spec)) {
            ctx.info(genSec, '${p.basename(spec.path)} → $suffix skipped (android: AndroidNativeImpl.cpp)');
            continue;
          }
          if (suffix == '.bridge.g.swift' && !_isAppleSwiftModule(spec)) {
            ctx.info(genSec, '${p.basename(spec.path)} → $suffix skipped (ios/macos: AppleNativeImpl.cpp)');
            continue;
          }
          final genPath = _generatedPath(spec.path, stem, suffix);
          final genFile = File(genPath);
          final relPath = p.relative(genPath);
          if (!genFile.existsSync()) {
            ctx.err(genSec, 'MISSING  $relPath', hint: 'Run: nitrogen generate');
          } else if (specMtime.isAfter(genFile.lastModifiedSync())) {
            ctx.warn(genSec, 'STALE    $relPath', hint: 'Run: nitrogen generate');
          } else {
            ctx.ok(genSec, relPath);
          }
        }

        // Check cpp-only outputs for NativeImpl.cpp modules.
        if (specIsCpp) {
          for (final suffix in DoctorCommand._cppGeneratedSuffixes) {
            final genPath = _generatedPath(spec.path, stem, suffix);
            final genFile = File(genPath);
            final relPath = p.relative(genPath);
            if (!genFile.existsSync()) {
              ctx.err(genSec, 'MISSING  $relPath', hint: 'Run: nitrogen generate');
            } else if (specMtime.isAfter(genFile.lastModifiedSync())) {
              ctx.warn(genSec, 'STALE    $relPath', hint: 'Run: nitrogen generate');
            } else {
              ctx.ok(genSec, relPath);
            }
          }
        }
      }
    } else {
      final genSec = DoctorSection('Generated Files');
      ctx.sections.add(genSec);
      ctx.warn(genSec, 'No *.native.dart specs found under lib/', hint: 'Create lib/src/<name>.native.dart');
    }
  }

  void _checkBuildRunnerHazard(_DoctorCtx ctx) {
    // ── build_runner symlink-cycle hazard ───────────────────────────────────
    // Once example/'s native platforms have been built, CocoaPods/Flutter
    // leaves example/{ios,macos}/.symlinks/plugins/<name> pointing straight
    // back to the plugin root. `nitrogen generate` cleans this automatically
    // before every run, but `dart run build_runner build`/`watch` invoked
    // directly does not — and build_runner's file-discovery walk follows
    // symlinks with no cycle detection, so it recurses forever with no error
    // and no timeout (confirmed via a stack sample of a hung process: 100% of
    // time in dart:io's AsyncDirectoryLister). Existence alone isn't broken —
    // it's only a problem for direct build_runner invocations — so this is
    // reported as info, not a warning/error.
    {
      final exampleDir = Directory(p.join(ctx.root.path, 'example'));
      const hazardPaths = [
        'ios/.symlinks',
        'ios/Flutter/ephemeral',
        'macos/.symlinks',
        'macos/Flutter/ephemeral',
        'windows/flutter/ephemeral',
        'linux/flutter/ephemeral',
      ];
      final present = exampleDir.existsSync() ? hazardPaths.where((rel) => Directory(p.join(exampleDir.path, rel)).existsSync()).toList() : <String>[];
      if (present.isNotEmpty) {
        final buildSec = DoctorSection('build_runner');
        ctx.sections.add(buildSec);
        // A build.yaml sources.exclude keeps build_runner's walk out of
        // example/ entirely — with it, a direct build_runner run is safe.
        // Without it, the hazard is a silent forever-hang, so escalate to a
        // warning with the one-line fix (issue #20).
        final buildYaml = File(p.join(ctx.root.path, 'build.yaml'));
        final hasSourcesExclude = buildYaml.existsSync() && buildYaml.readAsStringSync().contains('sources:');
        if (hasSourcesExclude) {
          ctx.info(
            buildSec,
            'example/ has built native-platform ephemeral dirs present (${present.join(', ')}) — '
            'harmless: build.yaml sources excludes keep build_runner out of them, and '
            '`nitrogen generate` cleans them each run.',
          );
        } else {
          ctx.warn(
            buildSec,
            'example/ has built native-platform ephemeral dirs (${present.join(', ')}) and build.yaml '
            'has no sources excludes — a direct `dart run build_runner build`/`watch` will hang '
            'FOREVER with no output (its file walk follows the example .symlinks cycle).',
            hint: 'Run: nitrogen link  (adds the build.yaml sources excludes), or delete the dirs — they always regenerate',
          );
        }
      }
    }
  }
}
