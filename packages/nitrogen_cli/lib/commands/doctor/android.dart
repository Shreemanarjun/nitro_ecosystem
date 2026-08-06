part of '../doctor_command.dart';

extension _DoctorAndroidChecks on DoctorCommand {
  void _checkAndroid(_DoctorCtx ctx, bool allSpecsCpp, bool hasAnyNonCppSpec) {
    final androidSec = DoctorSection('Android');
    ctx.sections.add(androidSec);
    final androidDir = Directory(p.join(ctx.root.path, 'android'));
    if (!androidDir.existsSync()) {
      ctx.info(androidSec, 'android/ directory not present — skipped');
      return;
    }
    if (allSpecsCpp) {
      // Pure C++ plugin — no Kotlin bridge needed.
      ctx.info(androidSec, 'All modules use NativeImpl.cpp — Kotlin JNI bridge not required');
      // Still check that the NDK can build the shared library.
      final gradle = File(p.join(androidDir.path, 'build.gradle'));
      if (gradle.existsSync() && gradle.readAsStringSync().contains('externalNativeBuild')) {
        ctx.ok(androidSec, 'externalNativeBuild configured (NDK build)');
      } else {
        ctx.info(androidSec, 'Add externalNativeBuild to android/build.gradle if using CMake directly');
      }
      return;
    }
    _checkAndroidGradle(ctx, androidSec, androidDir);
    _checkAndroidPluginKt(ctx, androidSec, androidDir, hasAnyNonCppSpec);
  }

  void _checkAndroidGradle(_DoctorCtx ctx, DoctorSection androidSec, Directory androidDir) {
    final gradle = File(p.join(androidDir.path, 'build.gradle'));
    if (!gradle.existsSync()) {
      ctx.err(androidSec, 'android/build.gradle not found');
    } else {
      final g = gradle.readAsStringSync();
      // Accept either the classic apply-plugin syntax or the modern approach
      // where Flutter's build infrastructure provides KGP automatically.
      // The modern approach is preferred since Flutter 3.x deprecated explicit
      // KGP in plugin build files (produces a Flutter deprecation warning).
      if (g.contains('"kotlin-android"') || g.contains("'kotlin-android'")) {
        ctx.ok(androidSec, 'kotlin-android plugin applied');
      } else if (g.contains('kotlinOptions') || g.contains('kotlin.srcDirs')) {
        // Flutter's built-in KGP is active — Kotlin is configured without the
        // explicit apply plugin line (intentional per Flutter migration guide).
        ctx.ok(androidSec, 'Kotlin configured via Flutter built-in KGP (modern approach)');
      } else {
        ctx.err(androidSec, 'kotlin-android plugin missing', hint: 'Add: apply plugin: "kotlin-android"  or use Flutter built-in KGP (kotlinOptions block)');
      }
      if (g.contains('kotlinOptions')) {
        ctx.ok(androidSec, 'kotlinOptions block present');
      } else {
        ctx.err(androidSec, 'kotlinOptions block missing', hint: 'Add: kotlinOptions { jvmTarget = "${BuildVersions.androidJvmTarget}" }');
      }
      if (g.contains('generated/kotlin')) {
        ctx.ok(androidSec, 'generated/kotlin sourceSets entry present');
        // Warn if java.srcDirs also points at the generated kotlin directory.
        // In AGP 8.x this routes .kt files through the Java compiler path and
        // causes "Unresolved reference: XxxJniBridge" compile errors.
        if (RegExp(r'java\.srcDirs\s*\+=.*generated/kotlin').hasMatch(g)) {
          ctx.err(
            androidSec,
            'java.srcDirs includes generated/kotlin — causes "Unresolved reference: XxxJniBridge" in AGP 8.x',
            hint: 'Remove the java.srcDirs line; kotlin.srcDirs alone is sufficient',
          );
        }
      } else {
        ctx.err(androidSec, 'sourceSets entry for generated/kotlin missing', hint: 'Add: kotlin.srcDirs += "\${project.projectDir}/../lib/src/generated/kotlin"');
      }
      if (g.contains('kotlinx-coroutines')) {
        ctx.ok(androidSec, 'kotlinx-coroutines dependency present');
      } else {
        ctx.err(androidSec, 'kotlinx-coroutines missing in dependencies');
      }
    }
  }

  void _checkAndroidPluginKt(_DoctorCtx ctx, DoctorSection androidSec, Directory androidDir, bool hasAnyNonCppSpec) {
    final ktDir = Directory(p.join(androidDir.path, 'src', 'main', 'kotlin'));
    final pluginFiles = ktDir.existsSync() ? ktDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('Plugin.kt')).toList() : <File>[];
    if (pluginFiles.isEmpty) {
      ctx.err(androidSec, 'No Plugin.kt found', hint: 'Run: nitrogen init');
    } else {
      ctx.checkFilePermissions(
        androidSec,
        pluginFiles.first,
        p.relative(pluginFiles.first.path, from: ctx.root.path),
      );
      final kt = pluginFiles.first.readAsStringSync();
      // Only check System.loadLibrary for non-cpp specs (cpp libs are also loaded but that's fine)
      for (final spec in ctx.specs) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
        if (kt.contains('System.loadLibrary("$lib")')) {
          ctx.ok(androidSec, 'System.loadLibrary("$lib") in Plugin.kt');
        } else {
          ctx.err(androidSec, 'System.loadLibrary("$lib") missing', hint: 'Run: nitrogen link');
        }
      }
      // JniBridge.register / registerFactory only needed for non-cpp ctx.specs.
      // Accept both forms:
      //   register(impl)           — simple single-instance pattern
      //   registerFactory({...})   — factory pattern for multi-instance support
      if (hasAnyNonCppSpec) {
        if (kt.contains('JniBridge.register(') || kt.contains('JniBridge.registerFactory(')) {
          ctx.ok(androidSec, 'JniBridge.register(...) call present');
        } else {
          ctx.warn(androidSec, 'JniBridge.register(...) not found in Plugin.kt', hint: 'Add register call in onAttachedToEngine');
        }
      } else {
        ctx.info(androidSec, 'JniBridge.register not needed — all modules use NativeImpl.cpp');
      }

      // Check for stale JniBridge.register() calls for C++ modules.
      // When a module transitions from Kotlin/JNI to NativeImpl.cpp its
      // JniBridge class no longer exists, causing "Unresolved reference" at
      // compile time. nitrogen link auto-removes these, but doctor flags them
      // so users know to re-run link.
      for (final spec in ctx.specs.where(isCppModule)) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
        final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
        if (kt.contains('${moduleName}JniBridge.register(')) {
          ctx.err(
            androidSec,
            'Stale ${moduleName}JniBridge.register() in Plugin.kt — $moduleName is now NativeImpl.cpp',
            hint: 'Run: nitrogen link  (auto-removes stale registrations for C++ modules)',
          );
        }
      }

      // For each non-cpp Kotlin module, verify the JniBridge import is present.
      // Missing imports cause "Unresolved reference: FooJniBridge" Kotlin errors.
      // nitrogen link auto-injects these imports alongside the register() call.
      for (final spec in ctx.specs.where((s) => !isCppModule(s))) {
        final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = (_extractLibName(spec) ?? stem).replaceAll('-', '_');
        final moduleMatch = RegExp(r'abstract class (\w+) extends HybridObject').firstMatch(spec.readAsStringSync());
        final moduleName = moduleMatch?.group(1) ?? _toPascalCase(stem);
        final importLine = 'import nitro.${lib}_module.${moduleName}JniBridge';
        if (!kt.contains(importLine)) {
          ctx.err(
            androidSec,
            'Missing import in Plugin.kt: $importLine',
            hint: 'Run: nitrogen link  (auto-adds missing JniBridge imports)',
          );
        } else {
          ctx.ok(androidSec, 'import ${moduleName}JniBridge present');
        }
      }
    }
  }
}
