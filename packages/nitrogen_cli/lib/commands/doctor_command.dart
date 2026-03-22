import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import '../ui.dart';

class DoctorCommand extends Command {
  @override
  final String name = 'doctor';

  @override
  final String description =
      'Checks that a Nitrogen plugin is production-ready: generated files, '
      'build system wiring (CMake, Kotlin, Swift), pubspec, and native configs.';

  // Generated file extensions produced for each *.native.dart spec
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

  @override
  void run() {
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      printError('No pubspec.yaml found.',
          hint: 'Run nitrogen doctor from the root of a Flutter plugin.');
      exit(1);
    }

    final pluginName = _pluginName(pubspecFile);
    printBanner('nitrogen doctor — $pluginName');

    final specs = _findSpecs();
    if (specs.isEmpty) {
      printWarn('No *.native.dart specs found under lib/.',
          hint: 'Create lib/src/$pluginName.native.dart and run nitrogen generate.');
    }

    int errors = 0;
    int warnings = 0;

    void err(String label, {String? hint}) {
      printError(label, hint: hint);
      errors++;
    }

    void warn(String label, {String? hint}) {
      printWarn(label, hint: hint);
      warnings++;
    }

    // ── 1. pubspec.yaml ─────────────────────────────────────────────────────
    printSection('pubspec.yaml');
    final pubspecContent = pubspecFile.readAsStringSync();

    if (pubspecContent.contains('nitro:')) {
      printOk('nitro dependency present');
    } else {
      err('nitro dependency missing',
          hint: 'Add: nitro: { path: ../packages/nitro }  (or pub.dev version)');
    }

    if (pubspecContent.contains('build_runner:')) {
      printOk('build_runner dev dependency present');
    } else {
      err('build_runner dev dependency missing',
          hint: 'Add to dev_dependencies: build_runner: ^2.4.0');
    }

    if (pubspecContent.contains('nitrogen:')) {
      printOk('nitrogen dev dependency present');
    } else {
      err('nitrogen dev dependency missing',
          hint: 'Add to dev_dependencies: nitrogen: { path: ../packages/nitrogen }');
    }

    final hasAndroidPluginClass =
        RegExp(r'android:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:')
            .hasMatch(pubspecContent);
    if (hasAndroidPluginClass) {
      printOk('android pluginClass defined in pubspec');
    } else {
      err('android pluginClass missing in pubspec flutter.plugin.platforms',
          hint: 'Run: nitrogen init or add pluginClass/package under flutter.plugin.platforms.android');
    }

    final hasAndroidPackage =
        RegExp(r'android:\s*\n(?:\s+\S[^\n]*\n)*\s+package:').hasMatch(pubspecContent);
    if (hasAndroidPackage) {
      printOk('android package defined in pubspec');
    } else {
      err('android package missing in pubspec flutter.plugin.platforms',
          hint: 'Add: package: <org>.<pluginName> under flutter.plugin.platforms.android');
    }

    final hasIosPluginClass =
        RegExp(r'ios:\s*\n(?:\s+\S[^\n]*\n)*\s+pluginClass:').hasMatch(pubspecContent);
    if (hasIosPluginClass) {
      printOk('ios pluginClass defined in pubspec');
    } else {
      err('ios pluginClass missing in pubspec flutter.plugin.platforms',
          hint: 'Add: pluginClass: Swift${_toClassName(pluginName)}Plugin under flutter.plugin.platforms.ios');
    }

    // ── 2. Generated files ──────────────────────────────────────────────────
    printSection('Generated files');
    for (final spec in specs) {
      final stem =
          p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      final specMtime = spec.lastModifiedSync();
      stdout.writeln('    ${dim(stem + ".native.dart")}');

      for (final suffix in _generatedSuffixes) {
        final genPath = _generatedPath(spec.path, stem, suffix);
        final genFile = File(genPath);
        final relPath = p.relative(genPath);

        if (!genFile.existsSync()) {
          err('MISSING  $relPath',
              hint: 'Run: nitrogen generate');
        } else if (specMtime.isAfter(genFile.lastModifiedSync())) {
          warn('STALE    $relPath',
              hint: 'Spec is newer than output — run: nitrogen generate');
        } else {
          printOk(relPath);
        }
      }
    }

    // ── 3. src/CMakeLists.txt ───────────────────────────────────────────────
    printSection('CMakeLists.txt');
    final cmakeFile = File(p.join('src', 'CMakeLists.txt'));
    if (!cmakeFile.existsSync()) {
      err('src/CMakeLists.txt not found',
          hint: 'Run: nitrogen link');
    } else {
      final cmake = cmakeFile.readAsStringSync();

      if (cmake.contains('NITRO_NATIVE')) {
        printOk('NITRO_NATIVE variable defined (correct dart_api_dl.c path)');
      } else {
        warn('NITRO_NATIVE variable missing — dart_api_dl.c path may be wrong',
            hint: 'Run: nitrogen link  or add: set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")');
      }

      if (cmake.contains('dart_api_dl.c')) {
        printOk('dart_api_dl.c included');
      } else {
        err('dart_api_dl.c not included in CMakeLists.txt',
            hint: 'Add: "\${NITRO_NATIVE}/dart_api_dl.c" to add_library(...)');
      }

      for (final spec in specs) {
        final stem =
            p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
        final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
        if (cmake.contains('add_library($lib ')) {
          printOk('add_library($lib) target present');
        } else {
          err('add_library($lib ...) missing in src/CMakeLists.txt',
              hint: 'Run: nitrogen link');
        }
      }
    }

    // ── 4. Android ──────────────────────────────────────────────────────────
    printSection('Android');
    final androidDir = Directory('android');
    if (!androidDir.existsSync()) {
      printInfo('android/ directory not found — skipping Android checks');
    } else {
      // build.gradle
      final buildGradle = File(p.join('android', 'build.gradle'));
      if (!buildGradle.existsSync()) {
        err('android/build.gradle not found');
      } else {
        final gradle = buildGradle.readAsStringSync();

        if (gradle.contains('"kotlin-android"') ||
            gradle.contains("'kotlin-android'")) {
          printOk('kotlin-android plugin applied in build.gradle');
        } else {
          err('kotlin-android plugin missing in android/build.gradle',
              hint: 'Add: apply plugin: "kotlin-android"');
        }

        if (gradle.contains('kotlinOptions')) {
          printOk('kotlinOptions block present in build.gradle');
        } else {
          err('kotlinOptions block missing in android/build.gradle',
              hint: 'Add: kotlinOptions { jvmTarget = "17" }');
        }

        if (gradle.contains('generated/kotlin')) {
          printOk('generated/kotlin sourceSets entry present');
        } else {
          err('sourceSets entry for generated/kotlin missing in android/build.gradle',
              hint: 'Add: sourceSets { main { kotlin.srcDirs += ".../lib/src/generated/kotlin" } }');
        }

        if (gradle.contains('kotlinx-coroutines')) {
          printOk('kotlinx-coroutines dependency present');
        } else {
          err('kotlinx-coroutines missing in android/build.gradle dependencies',
              hint: 'Add: implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3"');
        }
      }

      // Plugin.kt
      final kotlinDir =
          Directory(p.join('android', 'src', 'main', 'kotlin'));
      final pluginFiles = kotlinDir.existsSync()
          ? kotlinDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('Plugin.kt'))
              .toList()
          : <File>[];

      if (pluginFiles.isEmpty) {
        err('No Plugin.kt found under android/src/main/kotlin/',
            hint: 'Run: nitrogen init  or create ${_toClassName(pluginName)}Plugin.kt');
      } else {
        final kt = pluginFiles.first.readAsStringSync();
        final relPath = p.relative(pluginFiles.first.path);

        for (final spec in specs) {
          final stem =
              p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
          final lib = _extractLibName(spec) ?? stem.replaceAll('-', '_');
          if (kt.contains('System.loadLibrary("$lib")')) {
            printOk('System.loadLibrary("$lib") in $relPath');
          } else {
            err('System.loadLibrary("$lib") missing in $relPath',
                hint: 'Run: nitrogen link');
          }
        }

        if (kt.contains('JniBridge.register(')) {
          printOk('JniBridge.register(...) call present in Plugin.kt');
        } else {
          warn('JniBridge.register(...) call not found in Plugin.kt',
              hint:
                  'Add: ${_toClassName(pluginName)}JniBridge.register(${_toClassName(pluginName)}Impl(binding.applicationContext)) in onAttachedToEngine');
        }
      }
    }

    // ── 5. iOS ──────────────────────────────────────────────────────────────
    printSection('iOS');
    final iosDir = Directory('ios');
    if (!iosDir.existsSync()) {
      printInfo('ios/ directory not found — skipping iOS checks');
    } else {
      // Podspec
      final podspecFiles = iosDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.podspec'))
          .toList();

      if (podspecFiles.isEmpty) {
        err('No .podspec found in ios/',
            hint: 'Run: nitrogen init');
      } else {
        final pod = podspecFiles.first.readAsStringSync();
        final podName = p.basename(podspecFiles.first.path);

        if (pod.contains('HEADER_SEARCH_PATHS')) {
          printOk('HEADER_SEARCH_PATHS in $podName');
        } else {
          err('HEADER_SEARCH_PATHS missing in $podName',
              hint: 'Run: nitrogen link');
        }

        if (pod.contains('c++17')) {
          printOk('CLANG_CXX_LANGUAGE_STANDARD = c++17 in $podName');
        } else {
          warn('CLANG_CXX_LANGUAGE_STANDARD not set to c++17 in $podName',
              hint: "Add: 'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17' in pod_target_xcconfig");
        }

        if (pod.contains("s.swift_version = '5.9'") ||
            pod.contains("s.swift_version = '6")) {
          printOk("swift_version ≥ 5.9 in $podName");
        } else {
          warn("swift_version may be too old in $podName",
              hint: "Set: s.swift_version = '5.9'");
        }
      }

      // Swift plugin class
      final classesDir = Directory(p.join('ios', 'Classes'));
      final swiftPluginFiles = classesDir.existsSync()
          ? classesDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('Plugin.swift'))
              .toList()
          : <File>[];

      if (swiftPluginFiles.isEmpty) {
        err('No *Plugin.swift found in ios/Classes/',
            hint: 'Run: nitrogen init  or create Swift${_toClassName(pluginName)}Plugin.swift');
      } else {
        final swiftContent = swiftPluginFiles.first.readAsStringSync();
        final swiftName = p.basename(swiftPluginFiles.first.path);

        if (swiftContent.contains('Registry.register(')) {
          printOk('Registry.register(...) call present in $swiftName');
        } else {
          warn('Registry.register(...) call not found in $swiftName',
              hint:
                  'Add: ${_toClassName(pluginName)}Registry.register(${_toClassName(pluginName)}Impl()) in register(with:)');
        }
      }

      // dart_api_dl forwarder
      final dartApiDl =
          File(p.join('ios', 'Classes', 'dart_api_dl.cpp'));
      if (dartApiDl.existsSync()) {
        printOk('ios/Classes/dart_api_dl.cpp present');
      } else {
        err('ios/Classes/dart_api_dl.cpp missing',
            hint: 'Run: nitrogen link');
      }
    }

    // ── Summary ──────────────────────────────────────────────────────────────
    printSummary(errors: errors, warnings: warnings, subject: pluginName);
    if (errors > 0) exit(1);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

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
    final subdir = _generatedSubdir[suffix]!;
    return p.join(specDir, 'generated', subdir, '$stem$suffix');
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
      if (line.startsWith('name: ')) return line.replaceFirst('name: ', '').trim();
    }
    return 'unknown';
  }

  String _toClassName(String pluginName) => pluginName
      .split('_')
      .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
      .join('');
}
