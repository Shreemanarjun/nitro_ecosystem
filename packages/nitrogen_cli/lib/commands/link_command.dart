import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

class LinkCommand extends Command {
  @override
  final String name = 'link';

  @override
  final String description =
      'Ensures the native build files (CMake, Podspec, Clangd) are correctly linked to Nitrogen generated code and Nitro runtime.';

  @override
  void run() async {
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      stderr.writeln(
          '❌ Error: No pubspec.yaml found in current directory. Are you in the root of a Flutter plugin?');
      exit(1);
    }

    final pluginName = _getPluginName(pubspecFile);
    stdout.writeln('🔗 Linking $pluginName native build system...');

    _linkCMake(pluginName);
    _linkPodspec(pluginName);
    _linkKotlinPlugin(pluginName);
    _linkClangd(pluginName);

    stdout.writeln('\n✨ $pluginName linked successfully!');
  }

  void _linkCMake(String pluginName) {
    final srcCmakeFile = File(p.join('src', 'CMakeLists.txt'));
    if (!srcCmakeFile.existsSync()) return;

    var content = srcCmakeFile.readAsStringSync();
    bool modified = false;

    final searchPath = '"\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native"';
    if (!content.contains(searchPath)) {
      content = content.replaceFirst(
        'target_include_directories($pluginName PRIVATE',
        'target_include_directories($pluginName PRIVATE\n  $searchPath',
      );
      modified = true;
    }

    final dartApiDl = '"../packages/nitro/src/native/dart_api_dl.c"';
    if (!content.contains(dartApiDl) && !content.contains('dart_api_dl.c')) {
      content = content.replaceFirst(
        'add_library($pluginName SHARED',
        'add_library($pluginName SHARED\n  $dartApiDl',
      );
      modified = true;
    }

    if (modified) srcCmakeFile.writeAsStringSync(content);
  }

  void _linkPodspec(String pluginName) {
    final podspecPath = p.join('ios', '$pluginName.podspec');
    final podspecFile = File(podspecPath);
    if (!podspecFile.existsSync()) return;

    var content = podspecFile.readAsStringSync();
    bool modified = false;

    // Adjust Swift and Platform
    if (!content.contains("s.swift_version = '5.9'")) {
      content = content.replaceFirst(RegExp(r"s\.swift_version = '.+?'"), "s.swift_version = '5.9'");
      modified = true;
    }
    if (!content.contains("s.platform = :ios, '13.0'")) {
      content = content.replaceFirst(RegExp(r"s\.platform = :ios, '.+?'"), "s.platform = :ios, '13.0'");
      modified = true;
    }

    final searchPath = '\'HEADER_SEARCH_PATHS\' => \'\$(inherited) "\${PODS_TARGET_SRCROOT}/../../../packages/nitro/src/native"\'';
    if (!content.contains('HEADER_SEARCH_PATHS')) {
      content = content.replaceFirst('s.pod_target_xcconfig = {', 's.pod_target_xcconfig = {\n    $searchPath,');
      modified = true;
    }

    if (modified) podspecFile.writeAsStringSync(content);

    final iosClassesDir = Directory(p.join('ios', 'Classes'));
    final dartApiDlForwarder = File(p.join(iosClassesDir.path, 'dart_api_dl.cpp'));
    if (!dartApiDlForwarder.existsSync()) {
      dartApiDlForwarder.createSync(recursive: true);
      dartApiDlForwarder.writeAsStringSync('// Forwarder for Nitro/FFI Dart DL API\n#include "../../../packages/nitro/src/native/dart_api_dl.c"\n');
    }
  }

  void _linkKotlinPlugin(String pluginName) {
    final kotlinDir = Directory(p.join('android', 'src', 'main', 'kotlin'));
    if (!kotlinDir.existsSync()) return;

    final files = kotlinDir.listSync(recursive: true);
    for (final file in files) {
      if (file is File && file.path.endsWith('Plugin.kt')) {
        var content = file.readAsStringSync();
        if (!content.contains('System.loadLibrary')) {
          final className = p.basenameWithoutExtension(file.path);
          content = content.replaceFirst('class $className: FlutterPlugin {', 'class $className: FlutterPlugin {\n  companion object {\n    init {\n      System.loadLibrary("$pluginName")\n    }\n  }\n');
          file.writeAsStringSync(content);
        }
        return;
      }
    }
  }

  void _linkClangd(String pluginName) {
    final clangdFile = File('.clangd');
    final content = '''
CompileFlags:
  Add:
    - -I\${PWD}/src
    - -I\${PWD}/lib/src/generated/cpp
    - -I\${PWD}/../packages/nitro/src/native
''';
    clangdFile.writeAsStringSync(content);
    stdout.writeln('✅ Generated .clangd for IDE support (Header discovery).');
  }

  String _getPluginName(File pubspec) {
    final lines = pubspec.readAsLinesSync();
    for (final line in lines) {
      if (line.startsWith('name: ')) return line.replaceFirst('name: ', '').trim();
    }
    return 'unknown';
  }
}
