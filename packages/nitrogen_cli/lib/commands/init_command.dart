import 'dart:convert';
import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import '../ui.dart';
import 'link_command.dart' show resolveNitroNativePath, dartApiDlForwarderContent, createSharedHeaders;

// ── CMakeLists.txt updater ────────────────────────────────────────────────────

/// Replaces the `set(NITRO_NATIVE "...")` line in [content] with [newPath].
/// Returns the updated content. If no such line exists, returns [content] unchanged.
/// Idempotent — running twice produces the same result, no duplicates.
String updateCMakeNitroNative(String content, String newPath) {
  return content.replaceFirst(
    RegExp(r'set\(NITRO_NATIVE "[^"]*"\)'),
    'set(NITRO_NATIVE "$newPath")',
  );
}

// ── pub.dev version resolver ──────────────────────────────────────────────────

Future<String> _fetchPubVersion(String package) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('https://pub.dev/api/packages/$package'));
    request.headers.set('Accept', 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    return json['latest']['version'] as String;
  } finally {
    client.close();
  }
}

// ── Result holder ──────────────────────────────────────────────────────────

class InitResult {
  bool success = false;
  String? errorMessage;
  String? pluginName;
}

// ── Progress model ────────────────────────────────────────────────────────────

enum InitStepState { pending, running, done, failed, skipped }

class InitStep {
  final String label;
  InitStepState state;
  String? detail;

  InitStep(this.label) : state = InitStepState.pending;
}

// ── nocterm Progress component ────────────────────────────────────────────────

class InitStepRow extends StatelessComponent {
  const InitStepRow(this.step, {super.key});
  final InitStep step;

  @override
  Component build(BuildContext context) {
    final String icon;
    final Color color;
    switch (step.state) {
      case InitStepState.pending:
        icon = '○';
        color = Colors.gray;
      case InitStepState.running:
        icon = '◉';
        color = Colors.cyan;
      case InitStepState.done:
        icon = '✔';
        color = Colors.green;
      case InitStepState.failed:
        icon = '✘';
        color = Colors.red;
      case InitStepState.skipped:
        icon = '–';
        color = Colors.gray;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 0),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                icon,
                style: TextStyle(color: color, fontWeight: FontWeight.bold),
              ),
              const Text(' '),
              Expanded(
                child: Text(
                  step.label,
                  style: TextStyle(
                    color: step.state == InitStepState.running ? Colors.cyan : null,
                    fontWeight: step.state == InitStepState.running ? FontWeight.bold : null,
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

class InitView extends StatefulComponent {
  const InitView({
    required this.pluginName,
    required this.org,
    required this.result,
    this.onExit,
    super.key,
  });
  final String pluginName;
  final String org;
  final InitResult result;
  final VoidCallback? onExit;

  @override
  State<InitView> createState() => _InitViewState();
}

class _InitViewState extends State<InitView> {
  late final List<InitStep> _steps = [
    InitStep('Checking environment and target'),
    InitStep('Running flutter create'),
    InitStep('Setting up src/ directory'),
    InitStep('Configuring iOS'),
    InitStep('Configuring Android'),
    InitStep('Updating pubspec.yaml'),
    InitStep('Writing bridge spec'),
  ];

  bool _finished = false;
  bool _failed = false;
  bool _needsConfirmation = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, _run);
  }

  void _setRunning(int i) => setState(() => _steps[i].state = InitStepState.running);
  void _setDone(int i, {String? detail}) => setState(() {
    _steps[i].state = InitStepState.done;
    _steps[i].detail = detail;
  });
  void _setFailed(int i, String msg) => setState(() {
    _steps[i].state = InitStepState.failed;
    _steps[i].detail = msg;
    _failed = true;
    _errorMessage = msg;
    _finished = true;
  });

  Future<void> _run({bool force = false}) async {
    setState(() => _needsConfirmation = false);
    final pluginName = component.pluginName;

    // Step 0 — Check existing
    _setRunning(0);
    final dir = Directory(pluginName);
    if (!force && dir.existsSync()) {
      _setDone(0, detail: 'Target directory already exists');
      setState(() => _needsConfirmation = true);
      return;
    }
    _setDone(0, detail: 'Target area ready');

    final org = component.org;
    final className = _toClassName(pluginName);

    // Step 1 — flutter create
    _setRunning(1);
    final createResult = await Process.run('flutter', [
      'create',
      '--template=plugin_ffi',
      '--platforms=android,ios',
      '--org=$org',
      pluginName,
    ]);
    if (createResult.exitCode != 0) {
      _setFailed(1, 'flutter create failed: ${createResult.stderr}');
      setState(() => _finished = true);
      return;
    }
    _setDone(1, detail: 'Created $pluginName/');

    // Step 2 — src/
    _setRunning(2);
    _setupSrc(pluginName);
    _setDone(2, detail: 'src/CMakeLists.txt created');

    // Step 3 — iOS
    _setRunning(3);
    _configureIos(pluginName, className);
    _setDone(3, detail: 'podspec + Swift${className}Plugin.swift');

    // Step 4 — Android
    _setRunning(4);
    _configureAndroid(pluginName, className, org);
    _setDone(4, detail: 'build.gradle + ${className}Plugin.kt');

    // Step 5 — pubspec (fetch latest versions from pub.dev)
    _setRunning(5);
    String? nitroVersion;
    String? nitroGeneratorVersion;
    bool usePubAdd = false;
    try {
      final versions = await Future.wait([
        _fetchPubVersion('nitro'),
        _fetchPubVersion('nitro_generator'),
      ]);
      nitroVersion = versions[0];
      nitroGeneratorVersion = versions[1];
    } catch (_) {
      usePubAdd = true;
    }
    _updatePubspec(pluginName, className, org, nitroVersion: nitroVersion, nitroGeneratorVersion: nitroGeneratorVersion);
    if (usePubAdd) {
      await Process.run('flutter', ['pub', 'add', 'nitro'], workingDirectory: pluginName);
      await Process.run('flutter', ['pub', 'add', '--dev', 'nitro_generator'], workingDirectory: pluginName);
      _setDone(5, detail: 'nitro, nitro_generator added via flutter pub add');
    } else {
      // pubspec was updated without running pub add — run pub get so
      // .dart_tool/package_config.json is created before path resolution.
      await Process.run('flutter', ['pub', 'get'], workingDirectory: pluginName);
      _setDone(5, detail: 'nitro $nitroVersion, nitro_generator $nitroGeneratorVersion added');
    }

    // Resolve the actual installed nitro path from package_config.json and
    // overwrite src/dart_api_dl.c + the NITRO_NATIVE variable in
    // src/CMakeLists.txt so they point to the correct pub-cache location
    // instead of the monorepo placeholder written in Step 2.
    _resolveSrcPaths(pluginName);

    // Step 6 — bridge spec + example main.dart
    _setRunning(6);
    _writeBridgeSpec(pluginName, className);
    _writeExampleMain(pluginName, className);
    _setDone(6, detail: 'lib/src/$pluginName.native.dart + example/lib/main.dart');

    component.result.success = true;
    component.result.pluginName = pluginName;
    setState(() => _finished = true);
  }

  bool _handleKey(KeyboardEvent e) {
    if (_needsConfirmation) {
      if (e.logicalKey == LogicalKey.keyY) {
        _run(force: true);
        return true;
      }
      if (e.logicalKey == LogicalKey.keyN) {
        if (component.onExit != null) {
          component.onExit!();
        } else {
          shutdownApp(0);
        }
        return true;
      }
      return false;
    }

    if (e.logicalKey == LogicalKey.escape) {
      if (component.onExit != null) {
        component.onExit!();
        return true;
      }
      shutdownApp(_failed ? 1 : 0);
      return true;
    }

    if (!_finished) return false;
    return false; // Do not exit on arbitrary key press if finished.
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _handleKey,
      child: Column(
        children: [
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
          const SizedBox(height: 1),
          if (_needsConfirmation)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '⚠ Directory "${component.pluginName}" already exists.',
                      style: const TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 1),
                    const Text('Force initialize and overwrite existing files?'),
                    const SizedBox(height: 1),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '[Y]',
                          style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                        ),
                        Text(' Yes, Overwrite   '),
                        Text(
                          '[N]',
                          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                        ),
                        Text(' No, Cancel'),
                      ],
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: _errorMessage != null && _finished
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                              decoration: BoxDecoration(border: BoxBorder.all(color: Colors.red)),
                              child: const Text(
                                ' ✘  ERROR ',
                                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(_errorMessage!, style: const TextStyle(color: Colors.white)),
                            const SizedBox(height: 1),
                            const Text(
                              'Hint: Verify your Flutter/Dart installation and directory permissions.',
                              style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
                            ),
                          ],
                        ),
                      )
                    : Container(
                        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.brightBlack)),
                        child: Padding(
                          padding: const EdgeInsets.all(1),
                          child: ListView(
                            children: _steps.map(InitStepRow.new).toList(),
                          ),
                        ),
                      ),
              ),
            ),
            if (_finished)
              Padding(
                padding: const EdgeInsets.all(1),
                child: _failed
                    ? Text(
                        '✘ Scaffolding failed: ${_errorMessage ?? ""}',
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      )
                    : Column(
                        children: [
                          const Text(
                            '✨ Done! Next steps:',
                            style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '  1. Edit lib/src/${component.pluginName}.native.dart\n'
                            '  2. Run: nitrogen generate\n'
                            '  3. Run: nitrogen link\n'
                            '  4. Implement Hybrid${_toClassName(component.pluginName)}Spec in Kotlin & Swift',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.gray),
                          ),
                          const SizedBox(height: 1),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (component.onExit != null) ...[
                                HoverButton(
                                  label: '‹ Back',
                                  onTap: component.onExit!,
                                  color: Colors.cyan,
                                ),
                                const Text('  •  ', style: TextStyle(color: Colors.brightBlack)),
                              ],
                              Text(
                                component.onExit != null ? 'ESC back' : 'ESC exit',
                                style: const TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
          ],
        ],
      ),
    );
  }

  String _toClassName(String pluginName) {
    return pluginName.split('_').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');
  }

  /// Resolves the installed `nitro` package path from `.dart_tool/package_config.json`
  /// inside [pluginName]/ and overwrites:
  ///   - `src/dart_api_dl.c` — forwarder to the real pub-cache `.c` file
  ///   - `src/CMakeLists.txt` — absolute NITRO_NATIVE variable
  void _resolveSrcPaths(String pluginName) {
    final pluginAbsPath = p.join(Directory.current.path, pluginName);
    final nitroNativePath = resolveNitroNativePath(pluginAbsPath);

    // Overwrite src/dart_api_dl.c with the resolved absolute include path.
    File(p.join(pluginName, 'src', 'dart_api_dl.c')).writeAsStringSync(dartApiDlForwarderContent(nitroNativePath));

    // Copy nitro.h to src and ios/Classes
    createSharedHeaders(nitroNativePath, baseDir: pluginName);

    // Replace the NITRO_NATIVE cmake variable with the resolved absolute path.
    final cmakeFile = File(p.join(pluginName, 'src', 'CMakeLists.txt'));
    if (cmakeFile.existsSync()) {
      cmakeFile.writeAsStringSync(
        updateCMakeNitroNative(cmakeFile.readAsStringSync(), nitroNativePath),
      );
    }
  }

  void _setupSrc(String pluginName) {
    final srcDir = Directory(p.join(pluginName, 'src'));
    if (!srcDir.existsSync()) srcDir.createSync(recursive: true);

    File(p.join(srcDir.path, '$pluginName.cpp')).writeAsStringSync('''
#include <stdint.h>
#include <stdbool.h>
#include "nitro.h"

#include "../lib/src/generated/cpp/$pluginName.bridge.g.h"

extern "C" {
}
''');

    // dart_api_dl.c is created as a local forwarder by `nitrogen link` (after
    // `flutter pub get` resolves the nitro package path).  We create a
    // placeholder here pointing at the monorepo default; running
    // `nitrogen link` will update it to the correct installed path.
    File(p.join(srcDir.path, 'dart_api_dl.c')).writeAsStringSync(
      '// Generated by nitrogen — do not edit.\n'
      '// Run `nitrogen link` to update this path after `flutter pub get`.\n'
      '#include "../../packages/nitro/src/native/dart_api_dl.c"\n',
    );

    File(p.join(srcDir.path, 'CMakeLists.txt')).writeAsStringSync('''
cmake_minimum_required(VERSION 3.10)
project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")
set(GENERATED_CPP "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library($pluginName SHARED
  "$pluginName.cpp"
  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/$pluginName.bridge.g.cpp"
  "dart_api_dl.c"
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
    final iosDir = Directory(p.join(pluginName, 'ios'));
    final classesDir = Directory(p.join(iosDir.path, 'Classes'));
    if (!classesDir.existsSync()) classesDir.createSync(recursive: true);

    final oldC = File(p.join(classesDir.path, '$pluginName.c'));
    if (oldC.existsSync()) oldC.deleteSync();

    for (final f in classesDir.listSync().whereType<File>()) {
      if (f.path.endsWith('Plugin.swift')) f.deleteSync();
    }

    File(p.join(classesDir.path, '$pluginName.cpp')).writeAsStringSync('#include "../../src/$pluginName.cpp"\n');

    // Must be a .c file (not .cpp) so the compiler treats dart_api_dl content
    // as C, not C++. C++ rejects the void*/function-pointer cast inside it.
    // Forwards through ../../src/dart_api_dl.c (created by `nitrogen link`)
    // so both Android CMake and iOS CocoaPods/SPM share one resolved path.
    File(p.join(classesDir.path, 'dart_api_dl.c')).writeAsStringSync(
      '// Forwarder — compiled by CocoaPods/SPM so the Dart DL API is\n'
      '// available in the dylib. Kept as .c so it compiles as C, not C++.\n'
      '#include "../../src/dart_api_dl.c"\n',
    );

    File(p.join(classesDir.path, 'Swift${className}Plugin.swift')).writeAsStringSync('''import Flutter
import UIKit

public class Swift${className}Plugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        ${className}Registry.register(${className}Impl())
    }
}
''');

    // Starter implementation — developers replace the placeholder logic with
    // real native code. The protocol is generated by `nitrogen generate`.
    final implFile = File(p.join(classesDir.path, '${className}Impl.swift'));
    if (!implFile.existsSync()) {
      implFile.writeAsStringSync('''import Foundation

/// Native implementation of Hybrid${className}Protocol.
/// This file is yours to edit — the protocol is generated by `nitrogen generate`.
public class ${className}Impl: NSObject, Hybrid${className}Protocol {

    public func add(a: Double, b: Double) -> Double {
        return a + b
    }

    public func getGreeting(name: String) async throws -> String {
        return "Hello, \\(name)!"
    }
}
''');
    }

    // Symlink so CocoaPods (Classes/**/*) picks up the generated Swift bridge
    // without needing a path outside the pod root. The target file is created
    // later by `nitrogen generate`; a dangling symlink here is intentional.
    final symlinkPath = p.join(classesDir.path, '$pluginName.bridge.g.swift');
    final symlinkTarget = '../../lib/src/generated/swift/$pluginName.bridge.g.swift';
    final link = Link(symlinkPath);
    if (link.existsSync()) link.deleteSync();
    link.createSync(symlinkTarget);

    final podspecFile = File(p.join(iosDir.path, '$pluginName.podspec'));
    if (podspecFile.existsSync()) {
      var content = podspecFile.readAsStringSync();
      content = content.replaceFirst(RegExp(r"s\.platform = :ios, '[\d.]+'"), "s.platform = :ios, '13.0'");
      content = content.replaceFirst(RegExp(r"s\.swift_version = '[\d.]+'"), "s.swift_version = '5.9'");
      // HEADER_SEARCH_PATHS uses ${PODS_ROOT}/../.symlinks/plugins/nitro/src/native
      // so it works whether `nitro` is a local path dep or from pub.dev.
      const xcconfig = r"""s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_ROOT}/../.symlinks/plugins/nitro/src/native"'
  }""";
      content = content.replaceFirst(RegExp(r's\.pod_target_xcconfig\s*=\s*\{[^}]*\}'), xcconfig);
      podspecFile.writeAsStringSync(content);
    }

    // Package.swift — enables SPM distribution alongside CocoaPods.
    // Uses separate targets because SPM cannot mix Swift + C++ in one target.
    _writeIosPackageSwift(iosDir.path, pluginName, className);
  }

  void _writeIosPackageSwift(String iosPath, String pluginName, String className) {
    // SPM Sources layout (separate dirs required for mixed Swift/C++ targets):
    //   Sources/<ClassName>/     — Swift files (symlinks to Classes/*.swift)
    //   Sources/<ClassName>Cpp/  — C/C++ files (symlinks to Classes/*.cpp/.c)
    final swiftSrcDir = Directory(p.join(iosPath, 'Sources', className));
    final cppSrcDir = Directory(p.join(iosPath, 'Sources', '${className}Cpp'));
    swiftSrcDir.createSync(recursive: true);
    cppSrcDir.createSync(recursive: true);

    // Swift symlinks
    for (final name in [
      'Swift${className}Plugin.swift',
      '${className}Impl.swift',
      '$pluginName.bridge.g.swift',
    ]) {
      final lnk = Link(p.join(swiftSrcDir.path, name));
      if (!lnk.existsSync()) {
        lnk.createSync('../../Classes/$name');
      }
    }

    // C/C++ symlinks
    for (final name in ['$pluginName.cpp', 'dart_api_dl.c']) {
      final lnk = Link(p.join(cppSrcDir.path, name));
      if (!lnk.existsSync()) {
        lnk.createSync('../../Classes/$name');
      }
    }
    // Public headers dir — symlink to Classes/ so SPM can find .h files
    final includeLink = Link(p.join(cppSrcDir.path, 'include'));
    if (!includeLink.existsSync()) {
      includeLink.createSync('../../Classes');
    }

    File(p.join(iosPath, 'Package.swift')).writeAsStringSync('''// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "$pluginName",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "$pluginName", targets: ["$pluginName"]),
    ],
    targets: [
        // C/C++ bridge — SPM requires Swift and C++ in separate targets.
        .target(
            name: "${className}Cpp",
            path: "Sources/${className}Cpp",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags([
                    "-std=c++17",
                    // nitro's dart_api_dl.h — resolved via Flutter's symlink
                    // so this works for both local path and pub.dev references.
                    "-I../../.symlinks/plugins/nitro/src/native",
                ])
            ]
        ),
        // Swift implementation + generated bridge.
        .target(
            name: "$pluginName",
            dependencies: ["${className}Cpp"],
            path: "Sources/$className"
        ),
    ]
)
''');
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
    final kotlinDir = Directory(p.join(pluginName, 'android', 'src', 'main', 'kotlin', orgPath, pluginName));
    if (!kotlinDir.existsSync()) kotlinDir.createSync(recursive: true);

    File(p.join(kotlinDir.path, '${className}Plugin.kt')).writeAsStringSync('''
package $org.$pluginName

import io.flutter.embedding.engine.plugins.FlutterPlugin
import nitro.$moduleName.${className}JniBridge

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
}''');

    // Starter implementation — developers replace the placeholder logic.
    // The Hybrid${className}Spec interface is generated by `nitrogen generate`.
    final implFile = File(p.join(kotlinDir.path, '${className}Impl.kt'));
    if (!implFile.existsSync()) {
      implFile.writeAsStringSync('''
package $org.$pluginName

import android.content.Context
import nitro.$moduleName.Hybrid${className}Spec

/// Native implementation of Hybrid${className}Spec.
/// This file is yours to edit — the interface is generated by `nitrogen generate`.
class ${className}Impl(private val context: Context) : Hybrid${className}Spec {

    override fun add(a: Double, b: Double): Double = a + b

    override suspend fun getGreeting(name: String): String = "Hello, \$name!"
}
''');
    }
  }

  void _updatePubspec(
    String pluginName,
    String className,
    String org, {
    String? nitroVersion,
    String? nitroGeneratorVersion,
  }) {
    final pubspecFile = File(p.join(pluginName, 'pubspec.yaml'));
    var pubspec = pubspecFile.readAsStringSync();

    if (nitroVersion != null) {
      pubspec = pubspec.replaceFirst('dependencies:\n  flutter:\n    sdk: flutter', 'dependencies:\n  flutter:\n    sdk: flutter\n  nitro: ^$nitroVersion');
    }

    // Remove ffigen (plugin_ffi template includes it; Nitrogen uses nitro_generator instead).
    pubspec = pubspec.replaceFirst(RegExp(r'\n  ffi: \^\S+'), '');
    pubspec = pubspec.replaceFirst(RegExp(r'\n  ffigen: \^\S+'), '');

    if (nitroGeneratorVersion != null) {
      pubspec = pubspec.replaceFirst(
        RegExp(r'  flutter_lints: \^\S+'),
        '  flutter_lints: ^6.0.0\n'
        '  build_runner: ^2.4.0\n'
        '  nitro_generator: ^$nitroGeneratorVersion',
      );
    } else {
      pubspec = pubspec.replaceFirst(
        RegExp(r'  flutter_lints: \^\S+'),
        '  flutter_lints: ^6.0.0\n'
        '  build_runner: ^2.4.0',
      );
    }

    pubspec = pubspec.replaceFirst(
      RegExp(
        r'    platforms:\s*\n'
        r'      android:\s*\n'
        r'        ffiPlugin: true\s*\n'
        r'      ios:\s*\n'
        r'        ffiPlugin: true',
      ),
      '    platforms:\n'
      '      android:\n'
      '        pluginClass: ${className}Plugin\n'
      '        package: $org.$pluginName\n'
      '        ffiPlugin: true\n'
      '      ios:\n'
      '        pluginClass: Swift${className}Plugin\n'
      '        ffiPlugin: true',
    );

    pubspecFile.writeAsStringSync(pubspec);
  }

  void _writeBridgeSpec(String pluginName, String className) {
    final libSrcDir = Directory(p.join(pluginName, 'lib', 'src'));
    libSrcDir.createSync(recursive: true);

    File(p.join(libSrcDir.path, '$pluginName.native.dart')).writeAsStringSync('''import 'package:nitro/nitro.dart';

part '$pluginName.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class $className extends HybridObject {
  static final $className instance = _${className}Impl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
''');

    File(p.join(pluginName, 'lib', '$pluginName.dart')).writeAsStringSync("export 'src/$pluginName.native.dart';\n");
  }

  /// Overwrites the flutter-create template's example/lib/main.dart with a
  /// Nitro-aware version that has error handling, async support, and dispose.
  void _writeExampleMain(String pluginName, String className) {
    final exampleLibDir = Directory(p.join(pluginName, 'example', 'lib'));
    exampleLibDir.createSync(recursive: true);

    File(p.join(exampleLibDir.path, 'main.dart')).writeAsStringSync('''import 'dart:async';

import 'package:flutter/material.dart';
import 'package:$pluginName/$pluginName.dart' as plugin;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '$className Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: const _DemoPage(),
    );
  }
}

class _DemoPage extends StatefulWidget {
  const _DemoPage();
  @override
  State<_DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<_DemoPage> {
  String _addResult = '—';
  Future<String>? _greetingFuture;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    try {
      _addResult = '\${plugin.$className.instance.add(1.0, 2.0)}';
      _greetingFuture = plugin.$className.instance.getGreeting('World');
    } catch (e) {
      setState(() => _initError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('$className Demo')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                const Text('Failed to load native library',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(_initError!,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('$className Demo'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.bolt, size: 36, color: Colors.amber),
              const SizedBox(width: 8),
              Text(
                '$className',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Nitro FFI module — edit lib/src/$pluginName.native.dart to add methods.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          _FeatureCard(
            label: 'Sync method',
            code: '$className.instance.add(1.0, 2.0)',
            result: _addResult,
          ),
          const SizedBox(height: 12),
          FutureBuilder<String>(
            future: _greetingFuture,
            builder: (context, snapshot) => _FeatureCard(
              label: 'Async method  (@nitroAsync)',
              code: 'await $className.instance.getGreeting("World")',
              result: snapshot.hasData
                  ? snapshot.data!
                  : snapshot.hasError
                      ? 'Error: \${snapshot.error}'
                      : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.label,
    required this.code,
    required this.result,
  });
  final String label;
  final String code;
  final String? result; // null = loading

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(code,
                      style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 11,
                          fontFamily: 'monospace')),
                ],
              ),
            ),
            const SizedBox(width: 12),
            result == null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    result!,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple),
                  ),
          ],
        ),
      ),
    );
  }
}
''');
  }
}

// ── PluginNameForm ────────────────────────────────────────────────────────────

class PluginNameForm extends StatefulComponent {
  const PluginNameForm({required this.onSubmit, this.onExit, super.key});
  final void Function(String pluginName, String org) onSubmit;
  final VoidCallback? onExit;

  @override
  State<PluginNameForm> createState() => _PluginNameFormState();
}

class _PluginNameFormState extends State<PluginNameForm> {
  final _nameController = TextEditingController();
  final _orgController = TextEditingController(text: 'com.example');
  bool _nameHasFocus = true;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _orgController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final org = _orgController.text.trim().isEmpty ? 'com.example' : _orgController.text.trim();

    if (name.isEmpty) {
      setState(() => _error = 'Plugin name is required');
      return;
    }
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
      setState(() => _error = 'Use only lowercase letters, numbers, and underscores');
      return;
    }
    component.onSubmit(name, org);
  }

  bool _handleKey(KeyboardEvent e) {
    if (e.logicalKey == LogicalKey.escape) {
      component.onExit?.call();
      return true;
    }
    if (e.logicalKey == LogicalKey.tab) {
      setState(() {
        _nameHasFocus = !_nameHasFocus;
        _error = null;
      });
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _handleKey,
      child: Center(
        child: SizedBox(
          width: 52,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: Container(
                  decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      ' nitrogen init ',
                      style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 1),
              const Text('Plugin name:', style: TextStyle(color: Colors.white)),
              Row(
                children: [
                  const Text(
                    '› ',
                    style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(
                    width: 44,
                    child: TextField(
                      controller: _nameController,
                      focused: _nameHasFocus,
                      placeholder: 'my_plugin',
                      onSubmitted: (_) => setState(() {
                        _nameHasFocus = false;
                        _error = null;
                      }),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              const Text('Organisation (--org):', style: TextStyle(color: Colors.white)),
              Row(
                children: [
                  const Text(
                    '› ',
                    style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(
                    width: 44,
                    child: TextField(
                      controller: _orgController,
                      focused: !_nameHasFocus,
                      placeholder: 'com.example',
                      onSubmitted: (_) => _submit(),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 1),
                Text(
                  '⚠ $_error',
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 1),
              Row(
                children: [
                  HoverButton(
                    label: '✔ Confirm',
                    onTap: _submit,
                    color: Colors.green,
                  ),
                  const Text('  ', style: TextStyle(color: Colors.brightBlack)),
                  if (component.onExit != null) ...[
                    HoverButton(
                      label: '‹ Back',
                      onTap: component.onExit!,
                      color: Colors.cyan,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 1),
              const Text(
                '[Tab] switch field   [Enter] confirm   [ESC] back',
                style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── NitrogenInitApp ───────────────────────────────────────────────────────────

class NitrogenInitApp extends StatefulComponent {
  const NitrogenInitApp({
    required this.result,
    this.initialOrg,
    this.onExit,
    super.key,
  });
  final InitResult result;
  final String? initialOrg;
  final VoidCallback? onExit;

  @override
  State<NitrogenInitApp> createState() => _NitrogenInitAppState();
}

class _NitrogenInitAppState extends State<NitrogenInitApp> {
  String? _pluginName;
  String? _org;

  @override
  Component build(BuildContext context) {
    if (_pluginName != null) {
      return InitView(
        pluginName: _pluginName!,
        org: _org ?? component.initialOrg ?? 'com.example',
        result: component.result,
        onExit: component.onExit,
      );
    }
    return PluginNameForm(
      onSubmit: (name, org) => setState(() {
        _pluginName = name;
        _org = org;
      }),
      onExit: component.onExit,
    );
  }
}

// ── InitCommand ───────────────────────────────────────────────────────────────

class InitCommand extends Command {
  @override
  final String name = 'init';

  @override
  final String description = 'Scaffolds a new Nitrogen FFI plugin.';

  InitCommand() {
    argParser.addOption('org', defaultsTo: 'com.example');
    argParser.addOption(
      'name',
      abbr: 'n',
      help: 'Plugin name (skips interactive form; useful for scripts/CI).',
    );
  }

  @override
  Future<void> run() async {
    final org = argResults!['org'] as String;
    final nameArg = argResults!['name'] as String?;

    // Non-interactive path: --name was supplied, run directly without TUI.
    if (nameArg != null && nameArg.isNotEmpty) {
      final pluginName = nameArg.trim();
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(pluginName)) {
        stderr.writeln('❌ Invalid plugin name "$pluginName". Use only lowercase letters, numbers, and underscores.');
        exit(1);
      }
      final result = InitResult();
      await runApp(
        InitView(
          pluginName: pluginName,
          org: org,
          result: result,
        ),
      );
      if (result.success) {
        stdout.writeln('  \x1B[1;32m✨ $pluginName created\x1B[0m');
      } else {
        exit(1);
      }
      return;
    }

    // Interactive path: show the TUI name form.
    final result = InitResult();
    await runApp(NitrogenInitApp(result: result, initialOrg: org));
    if (result.success) {
      stdout.writeln('  \x1B[1;32m✨ ${result.pluginName ?? ''} created\x1B[0m');
    } else {
      exit(1);
    }
  }
}
