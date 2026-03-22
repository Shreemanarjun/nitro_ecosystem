import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

class LinkCommand extends Command {
  @override
  final String name = 'link';

  @override
  final String description =
      'Wires all Nitrogen-generated native bridges into the plugin build system '
      '(CMake, Podspec, Kotlin plugin class). Scans every *.native.dart in lib/ '
      'and ensures each module\'s .so / dylib is built and loaded automatically.';

  @override
  void run() {
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      stderr.writeln(
          '❌ No pubspec.yaml found. Run this from the root of a Flutter plugin.');
      exit(1);
    }

    final pluginName = _getPluginName(pubspecFile);
    stdout.writeln('🔗 Linking $pluginName...');

    final moduleLibs = _discoverModuleLibs(pluginName);
    stdout.writeln('   Found ${moduleLibs.length} module(s): ${moduleLibs.join(', ')}');

    _linkCMake(pluginName, moduleLibs);
    _linkPodspec(pluginName, moduleLibs);
    _linkKotlinPlugin(pluginName, moduleLibs);
    _linkClangd(pluginName);

    stdout.writeln('\n✨ $pluginName linked successfully!');
    stdout.writeln('');
    stdout.writeln('Next steps:');
    stdout.writeln('  • Run: dart run build_runner build --delete-conflicting-outputs');
    stdout.writeln('  • Implement the generated Hybrid*Spec interfaces in Kotlin/Swift');
  }

  // ── Discovery ────────────────────────────────────────────────────────────────

  /// Scans lib/ for *.native.dart files and extracts the lib name for each spec.
  /// Falls back to the file stem when no `lib:` annotation is present.
  List<String> _discoverModuleLibs(String pluginName) {
    final libDir = Directory('lib');
    if (!libDir.existsSync()) return [pluginName];

    final specs = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.native.dart'))
        .toList();

    if (specs.isEmpty) return [pluginName];

    final libs = <String>[];
    for (final spec in specs) {
      // Strip the full ".native.dart" double-extension, not just ".dart"
      final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      final libName = _extractLibName(spec) ?? stem.replaceAll('-', '_');
      if (!libs.contains(libName)) libs.add(libName);
    }
    return libs.isEmpty ? [pluginName] : libs;
  }

  /// Extracts `lib: 'name'` from a *.native.dart spec file, returns null if absent.
  String? _extractLibName(File specFile) {
    final content = specFile.readAsStringSync();
    final match = RegExp(r'''@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]''')
        .firstMatch(content);
    return match?.group(1);
  }

  // ── CMake ─────────────────────────────────────────────────────────────────────

  void _linkCMake(String pluginName, List<String> moduleLibs) {
    final cmakeFile = File(p.join('src', 'CMakeLists.txt'));
    if (!cmakeFile.existsSync()) {
      _generateCMake(pluginName, moduleLibs);
      return;
    }

    var content = cmakeFile.readAsStringSync();
    bool modified = false;

    final nitroNativePath =
        '"\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native"';
    final nitroNativeVar =
        'set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")';

    // Ensure NITRO_NATIVE variable is defined
    if (!content.contains('NITRO_NATIVE')) {
      content = '$nitroNativeVar\n\n$content';
      modified = true;
    }

    // Add include path if missing
    if (!content.contains('packages/nitro/src/native')) {
      content = content.replaceFirst(
        'target_include_directories($pluginName PRIVATE',
        'target_include_directories($pluginName PRIVATE\n  $nitroNativePath',
      );
      modified = true;
    }

    // Ensure dart_api_dl.c is compiled for the main library
    final dartApiDl = '"\${NITRO_NATIVE}/dart_api_dl.c"';
    if (!content.contains('dart_api_dl.c')) {
      content = content.replaceFirst(
        'add_library($pluginName SHARED',
        'add_library($pluginName SHARED\n  $dartApiDl',
      );
      modified = true;
    }

    // Add missing module library targets
    for (final lib in moduleLibs) {
      if (lib == pluginName) continue; // main lib already exists
      if (!content.contains('add_library($lib ')) {
        content += _cmakeModuleTarget(lib);
        modified = true;
        stdout.writeln('  ✅ Added CMake target for lib $lib');
      }
    }

    if (modified) {
      cmakeFile.writeAsStringSync(content);
      stdout.writeln('  ✅ Updated src/CMakeLists.txt');
    } else {
      stdout.writeln('  ✔  src/CMakeLists.txt already up to date');
    }
  }

  /// Generates a complete CMakeLists.txt when none exists.
  void _generateCMake(String pluginName, List<String> moduleLibs) {
    Directory('src').createSync(recursive: true);
    final cmakeFile = File(p.join('src', 'CMakeLists.txt'));
    final sb = StringBuffer();
    sb.writeln('cmake_minimum_required(VERSION 3.10)');
    sb.writeln('project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)');
    sb.writeln();
    sb.writeln('set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")');
    sb.writeln();
    sb.writeln('# ── $pluginName (main plugin entry point) ─────────────────────────');
    sb.writeln('add_library($pluginName SHARED');
    sb.writeln('  "$pluginName.cpp"');
    sb.writeln('  "\${NITRO_NATIVE}/dart_api_dl.c"');
    sb.writeln(')');
    sb.writeln('target_include_directories($pluginName PRIVATE');
    sb.writeln('  "\${CMAKE_CURRENT_SOURCE_DIR}"');
    sb.writeln('  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"');
    sb.writeln('  "\${NITRO_NATIVE}"');
    sb.writeln(')');
    sb.writeln('set_target_properties($pluginName PROPERTIES OUTPUT_NAME "$pluginName")');
    sb.writeln('target_compile_definitions($pluginName PUBLIC DART_SHARED_LIB)');
    sb.writeln('if(ANDROID)');
    sb.writeln('  target_link_libraries($pluginName PRIVATE android log)');
    sb.writeln('  target_link_options($pluginName PRIVATE "-Wl,-z,max-page-size=16384")');
    sb.writeln('endif()');

    for (final lib in moduleLibs) {
      if (lib == pluginName) continue;
      sb.write(_cmakeModuleTarget(lib));
    }

    cmakeFile.writeAsStringSync(sb.toString());
    stdout.writeln('  ✅ Generated src/CMakeLists.txt');
  }

  String _cmakeModuleTarget(String lib) {
    return '''

# ── $lib module ───────────────────────────────────────────────────────────────
add_library($lib SHARED
  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/$lib.bridge.g.cpp"
  "\${NITRO_NATIVE}/dart_api_dl.c"
)
target_include_directories($lib PRIVATE
  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "\${NITRO_NATIVE}"
)
set_target_properties($lib PROPERTIES OUTPUT_NAME "$lib")
target_compile_definitions($lib PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries($lib PRIVATE android log)
  target_link_options($lib PRIVATE "-Wl,-z,max-page-size=16384")
endif()
''';
  }

  // ── Podspec (iOS) ─────────────────────────────────────────────────────────────

  void _linkPodspec(String pluginName, List<String> moduleLibs) {
    final podspecPath = p.join('ios', '$pluginName.podspec');
    final podspecFile = File(podspecPath);
    if (!podspecFile.existsSync()) return;

    var content = podspecFile.readAsStringSync();
    bool modified = false;

    if (!content.contains("s.swift_version = '5.9'")) {
      content = content.replaceFirst(
          RegExp(r"s\.swift_version = '.+?'"), "s.swift_version = '5.9'");
      modified = true;
    }
    if (!content.contains("s.platform = :ios, '13.0'")) {
      content = content.replaceFirst(
          RegExp(r"s\.platform = :ios, '.+?'"), "s.platform = :ios, '13.0'");
      modified = true;
    }

    const searchPathEntry =
        "'HEADER_SEARCH_PATHS' => '\$(inherited) \"\${PODS_TARGET_SRCROOT}/../../../packages/nitro/src/native\"'";
    if (!content.contains('HEADER_SEARCH_PATHS')) {
      content = content.replaceFirst(
          's.pod_target_xcconfig = {',
          's.pod_target_xcconfig = {\n    $searchPathEntry,');
      modified = true;
    }

    if (modified) {
      podspecFile.writeAsStringSync(content);
      stdout.writeln('  ✅ Updated ios/$pluginName.podspec');
    } else {
      stdout.writeln('  ✔  ios/$pluginName.podspec already up to date');
    }

    // Ensure dart_api_dl forwarder exists for iOS
    final iosClassesDir = Directory(p.join('ios', 'Classes'));
    final dartApiDlForwarder =
        File(p.join(iosClassesDir.path, 'dart_api_dl.cpp'));
    if (!dartApiDlForwarder.existsSync()) {
      dartApiDlForwarder.createSync(recursive: true);
      dartApiDlForwarder.writeAsStringSync(
          '// Forwarder for Nitro/FFI Dart DL API\n'
          '#include "../../../packages/nitro/src/native/dart_api_dl.c"\n');
      stdout.writeln('  ✅ Created ios/Classes/dart_api_dl.cpp');
    }
  }

  // ── Kotlin plugin class ───────────────────────────────────────────────────────

  void _linkKotlinPlugin(String pluginName, List<String> moduleLibs) {
    final kotlinDir = Directory(p.join('android', 'src', 'main', 'kotlin'));
    if (!kotlinDir.existsSync()) return;

    final pluginFiles = kotlinDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('Plugin.kt'))
        .toList();

    if (pluginFiles.isEmpty) return;

    final pluginFile = pluginFiles.first;
    var content = pluginFile.readAsStringSync();
    bool modified = false;

    // Check which libraries are already loaded
    final missingLibs = moduleLibs
        .where((lib) => !content.contains('System.loadLibrary("$lib")'))
        .toList();

    if (missingLibs.isNotEmpty) {
      if (!content.contains('System.loadLibrary')) {
        // No companion object yet — inject one
        final className = p.basenameWithoutExtension(pluginFile.path);
        final loadLines =
            moduleLibs.map((l) => '      System.loadLibrary("$l")').join('\n');
        content = content.replaceFirst(
          'class $className: FlutterPlugin {',
          'class $className: FlutterPlugin {\n'
          '  companion object {\n'
          '    init {\n'
          '$loadLines\n'
          '    }\n'
          '  }\n',
        );
      } else {
        // companion object exists — append missing loadLibrary calls inside init {}
        for (final lib in missingLibs) {
          content = content.replaceFirst(
            'System.loadLibrary("$pluginName")',
            'System.loadLibrary("$pluginName")\n            System.loadLibrary("$lib")',
          );
        }
      }
      modified = true;
      stdout.writeln('  ✅ Added System.loadLibrary for: ${missingLibs.join(', ')}');
    } else {
      stdout.writeln('  ✔  All libraries already loaded in Plugin.kt');
    }

    if (modified) pluginFile.writeAsStringSync(content);
  }

  // ── Clangd IDE support ───────────────────────────────────────────────────────

  void _linkClangd(String pluginName) {
    final clangdFile = File('.clangd');
    final content = '''CompileFlags:
  Add:
    - -I\${PWD}/src
    - -I\${PWD}/lib/src/generated/cpp
    - -I\${PWD}/../packages/nitro/src/native
''';
    if (!clangdFile.existsSync() ||
        clangdFile.readAsStringSync() != content) {
      clangdFile.writeAsStringSync(content);
      stdout.writeln('  ✅ Updated .clangd for IDE header discovery');
    } else {
      stdout.writeln('  ✔  .clangd already up to date');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  String _getPluginName(File pubspec) {
    for (final line in pubspec.readAsLinesSync()) {
      if (line.startsWith('name: ')) return line.replaceFirst('name: ', '').trim();
    }
    return 'unknown';
  }
}
