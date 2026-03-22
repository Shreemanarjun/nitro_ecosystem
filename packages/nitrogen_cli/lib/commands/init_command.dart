import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

// ── Result holder (survives runApp) ──────────────────────────────────────────

class _InitResult {
  bool success = false;
  String? errorMessage;
}

// ── Progress model ────────────────────────────────────────────────────────────

enum _StepState { pending, running, done, failed }

class _Step {
  final String label;
  _StepState state;
  String? detail;

  _Step(this.label) : state = _StepState.pending;
}

// ── nocterm Progress component ────────────────────────────────────────────────

class _StepRow extends StatelessComponent {
  const _StepRow(this.step);
  final _Step step;

  @override
  Component build(BuildContext context) {
    final String icon;
    final Color color;
    switch (step.state) {
      case _StepState.pending:
        icon = '○';
        color = Colors.gray;
      case _StepState.running:
        icon = '◉';
        color = Colors.cyan;
      case _StepState.done:
        icon = '✔';
        color = Colors.green;
      case _StepState.failed:
        icon = '✘';
        color = Colors.red;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 0),
      child: Column(
        children: [
          Row(
            children: [
              Text(icon, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              const Text(' '),
              Expanded(
                child: Text(
                  step.label,
                  style: TextStyle(
                    color: step.state == _StepState.running ? Colors.cyan : null,
                    fontWeight: step.state == _StepState.running
                        ? FontWeight.bold
                        : null,
                  ),
                ),
              ),
            ],
          ),
          if (step.detail != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                step.detail!,
                style: const TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
              ),
            ),
        ],
      ),
    );
  }
}

class _InitApp extends StatefulComponent {
  const _InitApp({required this.pluginName, required this.org, required this.result});
  final String pluginName;
  final String org;
  final _InitResult result;

  @override
  State<_InitApp> createState() => _InitAppState();
}

class _InitAppState extends State<_InitApp> {
  late final List<_Step> _steps = [
    _Step('Running flutter create'),
    _Step('Setting up src/ directory'),
    _Step('Configuring iOS'),
    _Step('Configuring Android'),
    _Step('Updating pubspec.yaml'),
    _Step('Writing bridge spec'),
  ];

  bool _finished = false;
  bool _failed = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration.zero, _run);
  }

  Future<void> _setRunning(int i) async {
    setState(() => _steps[i].state = _StepState.running);
  }

  Future<void> _setDone(int i, {String? detail}) async {
    setState(() {
      _steps[i].state = _StepState.done;
      _steps[i].detail = detail;
    });
  }

  Future<void> _setFailed(int i, String msg) async {
    setState(() {
      _steps[i].state = _StepState.failed;
      _steps[i].detail = msg;
      _failed = true;
      _errorMessage = msg;
    });
  }

  Future<void> _run() async {
    final pluginName = component.pluginName;
    final org = component.org;
    final className = _toClassName(pluginName);

    // Step 0 — flutter create
    await _setRunning(0);
    final createResult = await Process.run('flutter', [
      'create',
      '--template=plugin_ffi',
      '--platforms=android,ios',
      '--org=$org',
      pluginName,
    ]);
    if (createResult.exitCode != 0) {
      await _setFailed(0, 'flutter create failed: ${createResult.stderr}');
      setState(() => _finished = true);
      return;
    }
    await _setDone(0, detail: 'Created $pluginName/');

    // Step 1 — src/
    await _setRunning(1);
    _setupSrc(pluginName);
    await _setDone(1, detail: 'src/CMakeLists.txt created');

    // Step 2 — iOS
    await _setRunning(2);
    _configureIos(pluginName, className);
    await _setDone(2, detail: 'podspec + Swift${className}Plugin.swift');

    // Step 3 — Android
    await _setRunning(3);
    _configureAndroid(pluginName, className, org);
    await _setDone(3, detail: 'build.gradle + ${className}Plugin.kt');

    // Step 4 — pubspec
    await _setRunning(4);
    _updatePubspec(pluginName, className, org);
    await _setDone(4, detail: 'nitro, pluginClass entries added');

    // Step 5 — bridge spec
    await _setRunning(5);
    _writeBridgeSpec(pluginName, className);
    await _setDone(5, detail: 'lib/src/$pluginName.native.dart');

    component.result.success = true;
    setState(() => _finished = true);
  }

  bool _handleKey(KeyboardEvent e) {
    if (!_finished) return false;
    shutdownApp(_failed ? 1 : 0);
    return true;
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _handleKey,
      child: Column(
        children: [
          // ── Header (fixed) ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 1, left: 1, right: 1),
            child: Container(
              decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  ' nitrogen init — ${component.pluginName} ',
                  style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          const Padding(padding: EdgeInsets.only(bottom: 1), child: Text('')),

          // ── Steps (scrollable) ──────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                decoration: BoxDecoration(border: BoxBorder.all(color: Colors.brightBlack)),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: ListView(
                    children: _steps.map(_StepRow.new).toList(),
                  ),
                ),
              ),
            ),
          ),

          // ── Footer (fixed) ──────────────────────────────────────────
          if (_finished)
            Padding(
              padding: const EdgeInsets.only(top: 1, bottom: 1, left: 1, right: 1),
              child: _failed
                  ? Text('✘ Scaffolding failed: ${_errorMessage ?? ""}',
                      style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))
                  : Column(
                      children: [
                        const Text('✨ Done! Next steps:',
                            style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                        Text(
                          '  1. Edit lib/src/${component.pluginName}.native.dart\n'
                          '  2. Run: nitrogen generate\n'
                          '  3. Run: nitrogen link\n'
                          '  4. Implement Hybrid${_toClassName(component.pluginName)}Spec in Kotlin & Swift\n'
                          '  5. Run: nitrogen doctor',
                          style: const TextStyle(color: Colors.gray),
                        ),
                        const Text(
                          'Press any key to exit',
                          style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }

  // ── Setup helpers (same logic as before) ─────────────────────────────────

  void _setupSrc(String pluginName) {
    final srcDir = Directory(p.join(pluginName, 'src'));
    if (!srcDir.existsSync()) srcDir.createSync(recursive: true);

    File(p.join(srcDir.path, '$pluginName.cpp')).writeAsStringSync('''
#include <stdint.h>
#include <stdbool.h>

#include "../lib/src/generated/cpp/$pluginName.bridge.g.h"
#include "../lib/src/generated/cpp/$pluginName.bridge.g.cpp"

extern "C" {
    // Add manual non-Nitrogen FFI functions here.
}
''');

    File(p.join(srcDir.path, 'CMakeLists.txt')).writeAsStringSync('''
cmake_minimum_required(VERSION 3.10)
project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")
set(GENERATED_CPP "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library($pluginName SHARED
  "$pluginName.cpp"
  "\${NITRO_NATIVE}/dart_api_dl.c"
)

target_include_directories($pluginName PRIVATE
  "\${CMAKE_CURRENT_SOURCE_DIR}"
  "\${GENERATED_CPP}"
  "\${NITRO_NATIVE}"
)

target_compile_definitions($pluginName PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries($pluginName PRIVATE android log)
  target_link_options($pluginName PRIVATE "-Wl,-z,max-page-size=16384")
endif()
''');
  }

  void _configureIos(String pluginName, String className) {
    final classesDir = Directory(p.join(pluginName, 'ios', 'Classes'));
    if (!classesDir.existsSync()) classesDir.createSync(recursive: true);

    final oldC = File(p.join(classesDir.path, '$pluginName.c'));
    if (oldC.existsSync()) oldC.deleteSync();

    for (final f in classesDir.listSync().whereType<File>()) {
      if (f.path.endsWith('Plugin.swift')) f.deleteSync();
    }

    File(p.join(classesDir.path, '$pluginName.cpp'))
        .writeAsStringSync('#include "../../src/$pluginName.cpp"\n');

    File(p.join(classesDir.path, 'dart_api_dl.cpp')).writeAsStringSync(
        '// Forwarder — compiled by CocoaPods so Dart DL API is available in the dylib.\n'
        '#include "../../../packages/nitro/src/native/dart_api_dl.c"\n');

    File(p.join(classesDir.path, 'Swift${className}Plugin.swift'))
        .writeAsStringSync('''import Flutter
import UIKit

public class Swift${className}Plugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        ${className}Registry.register(${className}Impl())
    }
}
''');

    final podspecFile = File(p.join(pluginName, 'ios', '$pluginName.podspec'));
    if (podspecFile.existsSync()) {
      var content = podspecFile.readAsStringSync();
      content = content.replaceFirst(
          RegExp(r"s\.platform = :ios, '[\d.]+'"), "s.platform = :ios, '13.0'");
      content = content.replaceFirst(
          RegExp(r"s\.swift_version = '[\d.]+'"), "s.swift_version = '5.9'");
      const xcconfig = '''s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '\$(inherited) "\${PODS_TARGET_SRCROOT}/../../../packages/nitro/src/native"'
  }''';
      content = content.replaceFirst(
          RegExp(r's\.pod_target_xcconfig\s*=\s*\{[^}]*\}'), xcconfig);
      podspecFile.writeAsStringSync(content);
    }
  }

  void _configureAndroid(String pluginName, String className, String org) {
    File(p.join(pluginName, 'android', 'build.gradle')).writeAsStringSync('''
group = "$org.$pluginName"
version = "1.0"

buildscript {
    repositories { google(); mavenCentral() }
    dependencies { classpath("com.android.tools.build:gradle:8.11.1") }
}

rootProject.allprojects {
    repositories { google(); mavenCentral() }
}

apply plugin: "com.android.library"
apply plugin: "kotlin-android"

android {
    namespace = "$org.$pluginName"
    compileSdk = 36
    ndkVersion = android.ndkVersion

    externalNativeBuild {
        cmake { path = "../src/CMakeLists.txt" }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    defaultConfig { minSdk = 24 }

    sourceSets {
        main {
            kotlin.srcDirs += "\${project.projectDir}/../lib/src/generated/kotlin"
            java.srcDirs += "\${project.projectDir}/../lib/src/generated/kotlin"
        }
    }
}

dependencies {
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3"
    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3"
}
''');

    final moduleName = '${pluginName}_module';
    final orgPath = org.replaceAll('.', p.separator);
    final kotlinDir = Directory(
        p.join(pluginName, 'android', 'src', 'main', 'kotlin', orgPath, pluginName));
    if (!kotlinDir.existsSync()) kotlinDir.createSync(recursive: true);

    File(p.join(kotlinDir.path, '${className}Plugin.kt')).writeAsStringSync('''
package $org.$pluginName

import io.flutter.embedding.engine.plugins.FlutterPlugin
import nitro.${moduleName}.${className}JniBridge

class ${className}Plugin : FlutterPlugin {

    companion object {
        init { System.loadLibrary("$pluginName") }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ${className}JniBridge.register(
            ${className}Impl(binding.applicationContext)
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
''');
  }

  void _updatePubspec(String pluginName, String className, String org) {
    final pubspecFile = File(p.join(pluginName, 'pubspec.yaml'));
    var pubspec = pubspecFile.readAsStringSync();

    pubspec = pubspec.replaceFirst(
        'dependencies:\n  flutter:\n    sdk: flutter',
        'dependencies:\n  flutter:\n    sdk: flutter\n  nitro: { path: ../packages/nitro }');

    pubspec = pubspec.replaceFirst(
        RegExp(r'  flutter_lints: \^\S+'),
        '  flutter_lints: ^6.0.0\n'
        '  build_runner: ^2.4.0\n'
        '  nitrogen: { path: ../packages/nitrogen }');

    pubspec = pubspec.replaceFirst(
        RegExp(
            r'    platforms:\s*\n'
            r'      android:\s*\n'
            r'        ffiPlugin: true\s*\n'
            r'      ios:\s*\n'
            r'        ffiPlugin: true'),
        '    platforms:\n'
        '      android:\n'
        '        pluginClass: ${className}Plugin\n'
        '        package: $org.$pluginName\n'
        '        ffiPlugin: true\n'
        '      ios:\n'
        '        pluginClass: Swift${className}Plugin\n'
        '        ffiPlugin: true');

    pubspecFile.writeAsStringSync(pubspec);
  }

  void _writeBridgeSpec(String pluginName, String className) {
    final libSrcDir = Directory(p.join(pluginName, 'lib', 'src'));
    libSrcDir.createSync(recursive: true);

    File(p.join(libSrcDir.path, '$pluginName.native.dart'))
        .writeAsStringSync('''import 'package:nitro/nitro.dart';

part '${pluginName}.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class $className extends HybridObject {
  static final $className instance = _${className}Impl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
''');

    File(p.join(pluginName, 'lib', '$pluginName.dart'))
        .writeAsStringSync("export 'src/$pluginName.native.dart';\n");
  }

  String _toClassName(String pluginName) {
    return pluginName
        .split('_')
        .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
        .join('');
  }
}

// ── InitCommand ───────────────────────────────────────────────────────────────

class InitCommand extends Command {
  @override
  final String name = 'init';

  @override
  final String description =
      'Scaffolds a new Nitrogen FFI plugin with full native wiring '
      '(build.gradle, Plugin.kt, Swift plugin, podspec, pubspec).';

  InitCommand() {
    argParser.addOption('org',
        defaultsTo: 'com.example',
        help: 'The organization (e.g., com.mycompany) for the plugin.');
  }

  @override
  Future<void> run() async {
    if (argResults!.rest.isEmpty) {
      stderr.writeln('❌ Please provide a plugin name: nitrogen init <plugin_name>');
      exit(1);
    }

    final pluginName = argResults!.rest.first;
    final org = argResults!['org'] as String;

    if (Directory(pluginName).existsSync()) {
      stderr.writeln('❌ Directory $pluginName already exists.');
      exit(1);
    }

    final result = _InitResult();
    await runApp(_InitApp(pluginName: pluginName, org: org, result: result));

    if (result.success) {
      stdout.writeln('');
      stdout.writeln('  \x1B[1;32m✨ ${pluginName} created\x1B[0m  — cd $pluginName && nitrogen generate');
      stdout.writeln('');
    } else if (result.errorMessage != null) {
      stderr.writeln('  \x1B[1;31m✘  ${result.errorMessage}\x1B[0m');
      exit(1);
    }
  }
}
