import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

class InitCommand extends Command {
  @override
  final String name = 'init';
  
  @override
  final String description = 'Scaffolds a new Nitrogen FFI plugin project with optimized native configs.';

  InitCommand() {
    argParser.addOption('org',
        defaultsTo: 'com.example',
        help: 'The organization (e.g., com.mycompany) for the plugin.');
  }

  @override
  void run() async {
    if (argResults!.rest.isEmpty) {
      stderr.writeln('❌ Please provide a plugin name: nitrogen init <plugin_name>');
      exit(1);
    }

    final pluginName = argResults!.rest.first;
    final org = argResults!['org'];
    final dir = Directory(pluginName);

    if (dir.existsSync()) {
      stderr.writeln('❌ Directory $pluginName already exists.');
      exit(1);
    }

    stdout.writeln('📦 Running flutter create for $pluginName...');
    final createResult = Process.runSync('flutter', [
      'create',
      '--template=plugin_ffi',
      '--platforms=android,ios',
      '--org=$org',
      pluginName,
    ]);

    if (createResult.exitCode != 0) {
      stderr.writeln(createResult.stderr);
      exit(createResult.exitCode);
    }

    final className = _capitalize(pluginName);

    // ── 1. Optimized Native Setup (src/) ────────────────────────────────────
    stdout.writeln('🛠️ Optimizing native project structure...');
    final srcDir = Directory(p.join(pluginName, 'src'));
    if (!srcDir.existsSync()) srcDir.createSync(recursive: true);

    // Create main C++ entry point
    final cppEntry = File(p.join(srcDir.path, '$pluginName.cpp'));
    cppEntry.writeAsStringSync('''
#include <stdint.h>
#include <stdbool.h>

// The Generated Nitrogen bridge header
#include "../lib/src/generated/cpp/$pluginName.bridge.g.h"

// The Generated Nitrogen bridge source
#include "../lib/src/generated/cpp/$pluginName.bridge.g.cpp"

extern "C" {
    // Add manual non-Nitrogen FFI functions here.
}
''');

    // Create src/CMakeLists.txt
    final srcCmake = File(p.join(srcDir.path, 'CMakeLists.txt'));
    srcCmake.writeAsStringSync('''
cmake_minimum_required(VERSION 3.10)
project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)

set(BRIDGE_CPP "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/$pluginName.bridge.g.cpp")
set(BRIDGE_H   "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/$pluginName.bridge.g.h")

add_library($pluginName SHARED "$pluginName.cpp")

target_include_directories($pluginName PRIVATE
  "\${CMAKE_CURRENT_SOURCE_DIR}"
  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
)

target_compile_definitions($pluginName PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries($pluginName PRIVATE android log)
  target_link_options($pluginName PRIVATE "-Wl,-z,max-page-size=16384")
endif()
''');

    // ── 2. iOS/macOS Configuration (podspec + Classes/cpp) ────────────────────
    stdout.writeln('🍎 Configuring iOS podspec and forwarders...');
    final iosClassesDir = Directory(p.join(pluginName, 'ios', 'Classes'));
    if (!iosClassesDir.existsSync()) iosClassesDir.createSync(recursive: true);

    // Remove the default .c file and replace with our .cpp forwarder
    final oldCFile = File(p.join(iosClassesDir.path, '$pluginName.c'));
    if (oldCFile.existsSync()) oldCFile.deleteSync();
    
    final iosCppForwarder = File(p.join(iosClassesDir.path, '$pluginName.cpp'));
    iosCppForwarder.writeAsStringSync('#include "../../src/$pluginName.cpp"\n');

    // Update podspec
    final podspecFile = File(p.join(pluginName, 'ios', '$pluginName.podspec'));
    if (podspecFile.existsSync()) {
      var content = podspecFile.readAsStringSync();
      content = content.replaceFirst(
        RegExp(r"s\.platform = :ios, '(\d+\.\d+)'"),
        "s.platform = :ios, '13.0'"
      );
      content = content.replaceFirst(
        's.swift_version = \'5.0\'',
        "s.swift_version = '5.9'"
      );
      // Add C++17 flags
      if (!content.contains('CLANG_CXX_LANGUAGE_STANDARD')) {
        content = content.replaceFirst(
          's.pod_target_xcconfig = { ',
          "s.pod_target_xcconfig = { \n    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',\n    'CLANG_CXX_LIBRARY' => 'libc++',\n    "
        );
      }
      podspecFile.writeAsStringSync(content);
    }

    // ── 3. Pubspec & Bridge spec initialization ──────────────────────────────
    stdout.writeln('📝 Finalizing Pubspec and Bridge Spec...');
    final pubspecFile = File(p.join(pluginName, 'pubspec.yaml'));
    var pubspec = pubspecFile.readAsStringSync();
    
    // Set ffiPlugin: true for Android CMake integration
    if (!pubspec.contains('ffiPlugin: true')) {
      pubspec = pubspec.replaceFirst(
        '      pluginClass: ${className}Plugin',
        "      pluginClass: ${className}Plugin\n      ffiPlugin: true"
      );
    }
    
    // Dependencies (Local paths for this monorepo, versioned for real usage)
    pubspec = pubspec.replaceFirst(
        'dependencies:\n  flutter:\n    sdk: flutter',
        "dependencies:\n  flutter:\n    sdk: flutter\n  nitro: { path: ../packages/nitro }"
    );
    pubspec = pubspec.replaceFirst(
        '  flutter_lints: ^3.0.0',
        "  flutter_lints: ^3.0.0\n  build_runner: ^2.4.0\n  nitrogen: { path: ../packages/nitrogen }"
    );
    pubspecFile.writeAsStringSync(pubspec);

    // Create the Nitrogen Bridge spec
    final libSrcDir = Directory(p.join(pluginName, 'lib', 'src'));
    libSrcDir.createSync(recursive: true);
    final specFile = File(p.join(libSrcDir.path, '$pluginName.native.dart'));
    specFile.writeAsStringSync('''
import 'package:nitro/nitro.dart';

part '$pluginName.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class $className extends HybridObject {
  static final $className instance = _\${className}Impl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
''');

    // Export spec
    final mainLib = File(p.join(pluginName, 'lib', '$pluginName.dart'));
    mainLib.writeAsStringSync("export 'src/$pluginName.native.dart';\n");

    stdout.writeln('✨ $pluginName has been scaffolded for Nitrogen with Zero-Friction native builds!');
    stdout.writeln('Next steps:');
    stdout.writeln('  cd $pluginName');
    stdout.writeln('  nitrogen generate');
  }

  String _capitalize(String name) {
    if (name.isEmpty) return name;
    return name.split('_').map((w) => w.substring(0, 1).toUpperCase() + w.substring(1)).join('');
  }
}
