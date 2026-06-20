import 'dart:convert';
import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import '../ui.dart';
import 'link_command.dart' show resolveNitroNativePath, createSharedHeaders;
import '../templates/native_headers.dart' show bundledDartApiDlContent;
import '../templates/scaffold_templates.dart';
import '../templates/podspec_templates.dart';
import '../templates/build_versions.dart';
import '../templates/forwarder_templates.dart';

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
    this.targetDir,
    this.platforms = const ['android', 'ios', 'macos'],
    this.onExit,
    super.key,
  });
  final String pluginName;
  final String org;
  final InitResult result;

  /// Parent directory where the plugin folder will be created.
  /// Defaults to [Directory.current] if null.
  final String? targetDir;

  /// Platforms to scaffold. Valid values: android, ios, macos, windows, linux.
  final List<String> platforms;
  final VoidCallback? onExit;

  @override
  State<InitView> createState() => _InitViewState();
}

class _InitViewState extends State<InitView> {
  // Step indices — Windows(6) and Linux(7) are always in the list but may be
  // skipped when the platform is not in component.platforms.
  static const _kStepCheck = 0;
  static const _kStepCreate = 1;
  static const _kStepSrc = 2;
  static const _kStepIos = 3;
  static const _kStepAndroid = 4;
  static const _kStepMacos = 5;
  static const _kStepWindows = 6;
  static const _kStepLinux = 7;
  static const _kStepPubspec = 8;
  static const _kStepBridge = 9;

  late final List<InitStep> _steps = [
    InitStep('Checking environment and target'),
    InitStep('Running flutter create'),
    InitStep('Setting up src/ directory'),
    InitStep('Configuring iOS'),
    InitStep('Configuring Android'),
    InitStep('Configuring macOS'),
    InitStep('Configuring Windows'),
    InitStep('Configuring Linux'),
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
  void _setSkipped(int i, {String? detail}) => setState(() {
    _steps[i].state = InitStepState.skipped;
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

    // Change to target directory before any file operations
    if (component.targetDir != null) {
      try {
        Directory.current = component.targetDir!;
      } catch (e) {
        _setFailed(_kStepCheck, 'Cannot access target directory: ${component.targetDir}');
        return;
      }
    }

    // Step 0 — Check existing
    _setRunning(_kStepCheck);
    final dir = Directory(pluginName);
    if (!force && dir.existsSync()) {
      _setDone(_kStepCheck, detail: 'Target directory already exists');
      setState(() => _needsConfirmation = true);
      return;
    }
    _setDone(_kStepCheck, detail: 'Target area ready');

    final org = component.org;
    final className = _toClassName(pluginName);
    final platforms = component.platforms;

    // Step 1 — flutter create
    _setRunning(_kStepCreate);
    final platformsArg = platforms.join(',');
    final createResult = await Process.run('flutter', [
      'create',
      '--template=plugin_ffi',
      '--platforms=$platformsArg',
      '--org=$org',
      pluginName,
    ]);
    if (createResult.exitCode != 0) {
      _setFailed(_kStepCreate, 'flutter create failed: ${createResult.stderr}');
      setState(() => _finished = true);
      return;
    }
    _setDone(_kStepCreate, detail: 'Created $pluginName/ (platforms: $platformsArg)');

    // Step 2 — src/
    _setRunning(_kStepSrc);
    _setupSrc(pluginName);
    _setDone(_kStepSrc, detail: 'src/CMakeLists.txt created');

    // Step 3 — iOS
    _setRunning(_kStepIos);
    if (platforms.contains('ios')) {
      _configureIos(pluginName, className);
      _setDone(_kStepIos, detail: 'ios/$pluginName/Package.swift + Swift${className}Plugin.swift');
    } else {
      _setSkipped(_kStepIos, detail: 'ios not in selected platforms');
    }

    // Step 4 — Android
    _setRunning(_kStepAndroid);
    if (platforms.contains('android')) {
      _configureAndroid(pluginName, className, org);
      _setDone(_kStepAndroid, detail: 'build.gradle + ${className}Plugin.kt');
    } else {
      _setSkipped(_kStepAndroid, detail: 'android not in selected platforms');
    }

    // Step 5 — macOS
    _setRunning(_kStepMacos);
    if (platforms.contains('macos')) {
      _configureMacos(pluginName, className);
      _setDone(_kStepMacos, detail: 'macos/$pluginName/Package.swift + Swift${className}Plugin.swift');
    } else {
      _setSkipped(_kStepMacos, detail: 'macos not in selected platforms');
    }

    // Step 6 — Windows
    _setRunning(_kStepWindows);
    if (platforms.contains('windows')) {
      _configureWindows(pluginName, className);
      _setDone(_kStepWindows, detail: 'windows/CMakeLists.txt patched');
    } else {
      _setSkipped(_kStepWindows, detail: 'windows not in selected platforms');
    }

    // Step 7 — Linux
    _setRunning(_kStepLinux);
    if (platforms.contains('linux')) {
      _configureLinux(pluginName, className);
      _setDone(_kStepLinux, detail: 'linux/CMakeLists.txt patched');
    } else {
      _setSkipped(_kStepLinux, detail: 'linux not in selected platforms');
    }

    // Step 8 — pubspec (fetch latest versions from pub.dev)
    _setRunning(_kStepPubspec);
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
    _updatePubspec(pluginName, className, org, platforms: platforms, nitroVersion: nitroVersion, nitroGeneratorVersion: nitroGeneratorVersion);
    if (usePubAdd) {
      await Process.run('flutter', ['pub', 'add', 'nitro'], workingDirectory: pluginName);
      await Process.run('flutter', ['pub', 'add', '--dev', 'nitro_generator'], workingDirectory: pluginName);
      _setDone(_kStepPubspec, detail: 'nitro, nitro_generator added via flutter pub add');
    } else {
      // pubspec was updated without running pub add — run pub get so
      // .dart_tool/package_config.json is created before path resolution.
      await Process.run('flutter', ['pub', 'get'], workingDirectory: pluginName);
      _setDone(_kStepPubspec, detail: 'nitro $nitroVersion, nitro_generator $nitroGeneratorVersion added');
    }

    // Resolve the installed nitro path from package_config.json and copy the
    // native headers into the plugin-local src/native directory.
    _resolveSrcPaths(pluginName);

    // Step 9 — bridge spec + example main.dart
    _setRunning(_kStepBridge);
    _writeBridgeSpec(pluginName, className, platforms: platforms);
    _writeExampleMain(pluginName, className);
    _writeBuildYaml(pluginName);
    _setDone(_kStepBridge, detail: 'lib/src/$pluginName.native.dart + build.yaml');

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

  static String _toClassName(String pluginName) {
    return pluginName.split('_').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');
  }

  /// Resolves the installed `nitro` package path from `.dart_tool/package_config.json`
  /// and copies the Dart native headers into the plugin-local `src/native`.
  static void _resolveSrcPaths(String pluginName) {
    final pluginAbsPath = p.join(Directory.current.path, pluginName);
    final nitroNativePath = resolveNitroNativePath(pluginAbsPath);

    // Copy nitro.h and Dart native headers to local project directories.
    createSharedHeaders(nitroNativePath, baseDir: pluginName);

    // Replace legacy absolute/monorepo values with the local generated header path.
    final cmakeFile = File(p.join(pluginName, 'src', 'CMakeLists.txt'));
    if (cmakeFile.existsSync()) {
      cmakeFile.writeAsStringSync(
        updateCMakeNitroNative(cmakeFile.readAsStringSync(), r'${CMAKE_CURRENT_SOURCE_DIR}/native'),
      );
    }
  }

  static void _setupSrc(String pluginName) {
    final srcDir = Directory(p.join(pluginName, 'src'));
    if (!srcDir.existsSync()) srcDir.createSync(recursive: true);

    File(p.join(srcDir.path, '$pluginName.cpp')).writeAsStringSync(pluginCppTemplate(pluginName));

    // `nitrogen link` copies the matching Dart native headers into src/native.
    File(p.join(srcDir.path, 'dart_api_dl.c')).writeAsStringSync(bundledDartApiDlContent);

    File(p.join(srcDir.path, 'CMakeLists.txt')).writeAsStringSync(cmakeListsTemplate(pluginName));
  }

  static void _configureIos(String pluginName, String className) {
    final iosDir = Directory(p.join(pluginName, 'ios'));
    final classesDir = Directory(p.join(iosDir.path, 'Classes'));
    if (!classesDir.existsSync()) classesDir.createSync(recursive: true);

    final oldC = File(p.join(classesDir.path, '$pluginName.c'));
    if (oldC.existsSync()) oldC.deleteSync();

    for (final f in classesDir.listSync().whereType<File>()) {
      if (f.path.endsWith('Plugin.swift')) f.deleteSync();
    }

    File(p.join(classesDir.path, '$pluginName.cpp')).writeAsStringSync(classesCppForwarder(pluginName));
    File(p.join(classesDir.path, 'dart_api_dl.c')).writeAsStringSync(classesIosDartApiDlForwarder);

    File(p.join(classesDir.path, 'Swift${className}Plugin.swift')).writeAsStringSync(iosSwiftPluginTemplate(className));

    // Starter implementation — developers replace the placeholder logic with
    // real native code. The protocol is generated by `nitrogen generate`.
    final implFile = File(p.join(classesDir.path, '${className}Impl.swift'));
    if (!implFile.existsSync()) {
      implFile.writeAsStringSync(iosSwiftImplTemplate(className));
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
      content = content.replaceFirst(RegExp(r"s\.platform = :ios, '[\d.]+'"), "s.platform = :ios, '${BuildVersions.iosDeployment}.0'");
      content = content.replaceFirst(RegExp(r"s\.swift_version = '[\d.]+'"), "s.swift_version = '${BuildVersions.podSwiftVersion}'");
      content = content.replaceFirst(RegExp(r's\.pod_target_xcconfig\s*=\s*\{[^}]*\}'), iosPodTargetXcconfig);
      podspecFile.writeAsStringSync(content);
    }

    // Package.swift — enables SPM distribution alongside CocoaPods.
    // Uses separate targets because SPM cannot mix Swift + C++ in one target.
    _writeIosPackageSwift(iosDir.path, pluginName, className);
  }

  static void _writeIosPackageSwift(String iosPath, String pluginName, String className) {
    _writeApplePackageSwift(iosPath, pluginName, className, BuildVersions.iosPlatformSpec);
  }

  static void _writeMacosPackageSwift(String macosPath, String pluginName, String className) {
    _writeApplePackageSwift(macosPath, pluginName, className, BuildVersions.macosPlatformSpec);
  }

  static void _writeApplePackageSwift(String path, String pluginName, String className, String platformSpec) {
    // Flutter 3.41+ nested SPM layout:
    //   ios/<pluginName>/Package.swift
    //   ios/<pluginName>/Sources/<ClassName>/     — Swift files
    //   ios/<pluginName>/Sources/<ClassName>Cpp/  — C/C++ files
    // Flutter auto-discovers this layout; the old flat ios/Package.swift is not auto-detected.
    final packageDir = Directory(p.join(path, pluginName));
    packageDir.createSync(recursive: true);

    final swiftSrcDir = Directory(p.join(packageDir.path, 'Sources', className));
    final cppSrcDir = Directory(p.join(packageDir.path, 'Sources', '${className}Cpp'));
    swiftSrcDir.createSync(recursive: true);
    cppSrcDir.createSync(recursive: true);

    // Swift target: symlinks to Classes/ (Swift-only target, no mixed-language issue)
    for (final name in [
      'Swift${className}Plugin.swift',
      '${className}Impl.swift',
      '$pluginName.bridge.g.swift',
    ]) {
      final lnk = Link(p.join(swiftSrcDir.path, name));
      if (!lnk.existsSync()) {
        try {
          lnk.createSync('../../../Classes/$name');
        } catch (_) {}
      }
    }

    // C++ target: real forwarder files (NOT symlinks to Classes).
    // Symlinks would expose Swift files via the include/ path and cause SPM
    // "mixed language source files" errors.
    File(p.join(cppSrcDir.path, '$pluginName.cpp')).writeAsStringSync(spmCppClassesForwarder(pluginName));
    File(p.join(cppSrcDir.path, 'dart_api_dl.c')).writeAsStringSync(bundledDartApiDlContent);

    File(p.join(cppSrcDir.path, '$pluginName.bridge.g.mm')).writeAsStringSync(spmBridgeMmForwarder(pluginName));

    // Public headers: real directory populated by `nitrogen link`.
    // Bridge headers (.bridge.g.h) and nitro headers (nitro.h, dart_api_dl.h)
    // are written here by nitrogen link after flutter pub get resolves paths.
    final includeDir = Directory(p.join(cppSrcDir.path, 'include'));
    if (!includeDir.existsSync()) includeDir.createSync();

    File(p.join(packageDir.path, 'Package.swift')).writeAsStringSync(
      packageSwiftTemplate(pluginName, className, platformSpec, isMacos: path.endsWith('macos')),
    );
  }

  static void _configureAndroid(String pluginName, String className, String org) {
    File(p.join(pluginName, 'android', 'build.gradle')).writeAsStringSync(androidBuildGradleTemplate(org, pluginName));

    final moduleName = '${pluginName}_module';
    final orgPath = org.replaceAll('.', p.separator);
    final kotlinDir = Directory(p.join(pluginName, 'android', 'src', 'main', 'kotlin', orgPath, pluginName));
    if (!kotlinDir.existsSync()) kotlinDir.createSync(recursive: true);

    File(p.join(kotlinDir.path, '${className}Plugin.kt')).writeAsStringSync(androidPluginKtTemplate(org, pluginName, className, moduleName));

    // Starter implementation — developers replace the placeholder logic.
    // The Hybrid${className}Spec interface is generated by `nitrogen generate`.
    final implFile = File(p.join(kotlinDir.path, '${className}Impl.kt'));
    if (!implFile.existsSync()) {
      implFile.writeAsStringSync(androidImplKtTemplate(org, pluginName, className, moduleName));
    }
  }

  static void _configureWindows(String pluginName, String className) {
    final winDir = Directory(p.join(pluginName, 'windows'));
    if (!winDir.existsSync()) return;
    _patchDesktopCMake(p.join(winDir.path, 'CMakeLists.txt'), pluginName);
  }

  static void _configureLinux(String pluginName, String className) {
    final linuxDir = Directory(p.join(pluginName, 'linux'));
    if (!linuxDir.existsSync()) return;
    _patchDesktopCMake(p.join(linuxDir.path, 'CMakeLists.txt'), pluginName);
  }

  /// Shared CMake patcher for desktop platforms (windows/ and linux/).
  static void _patchDesktopCMake(String cmakePath, String pluginName) {
    final cmakeFile = File(cmakePath);
    if (!cmakeFile.existsSync()) return;
    var content = cmakeFile.readAsStringSync();
    const addLibLine = 'add_library(\${PLUGIN_NAME} SHARED\n';
    if (!content.contains('NITRO_NATIVE')) {
      content = 'set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../src/native")\n\n$content';
    }
    if (!content.contains('dart_api_dl.c')) {
      content = content.replaceFirst(
        addLibLine,
        '$addLibLine  "\${CMAKE_CURRENT_SOURCE_DIR}/../src/dart_api_dl.c"\n',
      );
    }
    final bridgeRel = '../lib/src/generated/cpp/$pluginName.bridge.g.cpp';
    if (!content.contains(bridgeRel)) {
      content = content.replaceFirst(
        addLibLine,
        '$addLibLine  "\${CMAKE_CURRENT_SOURCE_DIR}/$bridgeRel"\n',
      );
    }
    if (!content.contains(r'${NITRO_NATIVE}')) {
      content +=
          '\ntarget_include_directories(\${PLUGIN_NAME} PRIVATE\n'
          '  "\${NITRO_NATIVE}"\n'
          '  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"\n'
          ')\n';
    }
    cmakeFile.writeAsStringSync(content);
  }

  static void _configureMacos(String pluginName, String className) {
    final macosDir = Directory(p.join(pluginName, 'macos'));
    final classesDir = Directory(p.join(macosDir.path, 'Classes'));
    if (!classesDir.existsSync()) classesDir.createSync(recursive: true);

    final oldC = File(p.join(classesDir.path, '$pluginName.c'));
    if (oldC.existsSync()) oldC.deleteSync();

    for (final f in classesDir.listSync().whereType<File>()) {
      if (f.path.endsWith('Plugin.swift')) f.deleteSync();
    }

    File(p.join(classesDir.path, '$pluginName.cpp')).writeAsStringSync(classesCppForwarder(pluginName));

    File(p.join(classesDir.path, 'dart_api_dl.c')).writeAsStringSync(classesMacosDartApiDlForwarder);

    File(p.join(classesDir.path, 'Swift${className}Plugin.swift')).writeAsStringSync(macosSwiftPluginTemplate(className));

    final implFile = File(p.join(classesDir.path, '${className}Impl.swift'));
    if (!implFile.existsSync()) {
      implFile.writeAsStringSync(macosSwiftImplTemplate(className));
    }

    // Symlink bridge
    final symlinkPath = p.join(classesDir.path, '$pluginName.bridge.g.swift');
    final symlinkTarget = '../../lib/src/generated/swift/$pluginName.bridge.g.swift';
    final link = Link(symlinkPath);
    if (link.existsSync()) link.deleteSync();
    link.createSync(symlinkTarget);

    final podspecFile = File(p.join(macosDir.path, '$pluginName.podspec'));
    if (podspecFile.existsSync()) {
      var content = podspecFile.readAsStringSync();
      content = content.replaceFirst(RegExp(r"s\.platform = :osx, '[\d.]+'"), "s.platform = :osx, '${BuildVersions.macosDeployment.replaceAll('_', '.')}'");
      content = content.replaceFirst(RegExp(r"s\.swift_version = '[\d.]+'"), "s.swift_version = '${BuildVersions.podSwiftVersion}'");
      content = content.replaceFirst(RegExp(r's\.pod_target_xcconfig\s*=\s*\{[^}]*\}'), macosPodTargetXcconfig);
      podspecFile.writeAsStringSync(content);
    }

    _writeMacosPackageSwift(macosDir.path, pluginName, className);
  }

  static void _updatePubspec(
    String pluginName,
    String className,
    String org, {
    List<String> platforms = const ['android', 'ios', 'macos'],
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

    // Build the platforms block dynamically based on selected platforms.
    final platformsBlock = StringBuffer('    platforms:\n');
    if (platforms.contains('android')) {
      platformsBlock
        ..writeln('      android:')
        ..writeln('        pluginClass: ${className}Plugin')
        ..writeln('        package: $org.$pluginName')
        ..write('        ffiPlugin: true');
    }
    if (platforms.contains('ios')) {
      platformsBlock
        ..writeln()
        ..writeln('      ios:')
        ..writeln('        pluginClass: Swift${className}Plugin')
        ..write('        ffiPlugin: true');
    }
    if (platforms.contains('macos')) {
      platformsBlock
        ..writeln()
        ..writeln('      macos:')
        ..writeln('        pluginClass: Swift${className}Plugin')
        ..write('        ffiPlugin: true');
    }
    if (platforms.contains('windows')) {
      platformsBlock
        ..writeln()
        ..writeln('      windows:')
        ..writeln('        pluginClass: ${className}Plugin')
        ..write('        ffiPlugin: true');
    }
    if (platforms.contains('linux')) {
      platformsBlock
        ..writeln()
        ..writeln('      linux:')
        ..writeln('        pluginClass: ${className}Plugin')
        ..write('        ffiPlugin: true');
    }

    // Replace whatever platforms block flutter create generated with ours.
    pubspec = pubspec.replaceFirst(
      RegExp(r'    platforms:\n(?:      \w+:\n(?:        \w+: [^\n]+\n)*)+', multiLine: true),
      platformsBlock.toString(),
    );

    pubspecFile.writeAsStringSync(pubspec);
  }

  static void _writeBridgeSpec(String pluginName, String className, {List<String> platforms = const ['android', 'ios', 'macos']}) {
    final libSrcDir = Directory(p.join(pluginName, 'lib', 'src'));
    libSrcDir.createSync(recursive: true);

    // Build @NitroModule annotation based on selected platforms.
    final args = <String>[];
    if (platforms.contains('ios')) args.add('ios: NativeImpl.swift');
    if (platforms.contains('android')) args.add('android: NativeImpl.kotlin');
    if (platforms.contains('macos')) args.add('macos: NativeImpl.swift');
    if (platforms.contains('windows')) args.add('windows: NativeImpl.cpp');
    if (platforms.contains('linux')) args.add('linux: NativeImpl.cpp');
    final annotation = '@NitroModule(${args.join(', ')})';

    File(p.join(libSrcDir.path, '$pluginName.native.dart')).writeAsStringSync(nativeDartTemplate(pluginName, className, annotation));

    File(p.join(pluginName, 'lib', '$pluginName.dart')).writeAsStringSync("export 'src/$pluginName.native.dart';\n");
  }

  /// Overwrites the flutter-create template's example/lib/main.dart with a
  /// Nitro-aware version that has error handling, async support, and dispose.
  static void _writeExampleMain(String pluginName, String className) {
    final exampleLibDir = Directory(p.join(pluginName, 'example', 'lib'));
    exampleLibDir.createSync(recursive: true);

    File(p.join(exampleLibDir.path, 'main.dart')).writeAsStringSync(exampleMainDartTemplate(pluginName, className));
  }

  static void _writeBuildYaml(String pluginName) {
    File(p.join(pluginName, 'build.yaml')).writeAsStringSync(buildYamlTemplate());
  }
}

// ── PluginNameForm ────────────────────────────────────────────────────────────

class PluginNameForm extends StatefulComponent {
  const PluginNameForm({required this.onSubmit, this.onExit, super.key});
  final void Function(String pluginName, String org, String targetDir) onSubmit;
  final VoidCallback? onExit;

  @override
  State<PluginNameForm> createState() => _PluginNameFormState();
}

class _PluginNameFormState extends State<PluginNameForm> {
  final _nameController = TextEditingController();
  final _orgController = TextEditingController(text: 'com.example');
  late final _dirController = TextEditingController(text: Directory.current.path);
  int _focusIndex = 0; // 0 = name, 1 = org, 2 = dir
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _orgController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    final org = _orgController.text.trim().isEmpty ? 'com.example' : _orgController.text.trim();
    final dir = _dirController.text.trim().isEmpty ? Directory.current.path : _dirController.text.trim();

    if (name.isEmpty) {
      setState(() => _error = 'Plugin name is required');
      return;
    }
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
      setState(() => _error = 'Use only lowercase letters, numbers, and underscores');
      return;
    }
    final targetDir = Directory(dir);
    if (!targetDir.existsSync()) {
      setState(() => _error = 'Directory does not exist: $dir');
      return;
    }
    component.onSubmit(name, org, dir);
  }

  bool _handleKey(KeyboardEvent e) {
    if (e.logicalKey == LogicalKey.escape) {
      component.onExit?.call();
      return true;
    }
    if (e.logicalKey == LogicalKey.tab) {
      setState(() {
        _focusIndex = (_focusIndex + 1) % 3;
        _error = null;
      });
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final pluginName = _nameController.text.trim();
    final targetDir = _dirController.text.trim().isEmpty ? Directory.current.path : _dirController.text.trim();
    final previewPath = pluginName.isEmpty ? targetDir : p.join(targetDir, pluginName);

    return Focusable(
      focused: true,
      onKeyEvent: _handleKey,
      child: Center(
        child: SizedBox(
          width: 60,
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
                    width: 52,
                    child: TextField(
                      controller: _nameController,
                      focused: _focusIndex == 0,
                      placeholder: 'my_plugin',
                      onSubmitted: (_) => setState(() {
                        _focusIndex = 1;
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
                    width: 52,
                    child: TextField(
                      controller: _orgController,
                      focused: _focusIndex == 1,
                      placeholder: 'com.example',
                      onSubmitted: (_) => _submit(),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              const Text('Target directory:', style: TextStyle(color: Colors.white)),
              Row(
                children: [
                  const Text(
                    '› ',
                    style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(
                    width: 52,
                    child: TextField(
                      controller: _dirController,
                      focused: _focusIndex == 2,
                      placeholder: Directory.current.path,
                      onSubmitted: (_) => _submit(),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Row(
                children: [
                  const Text('📂 ', style: TextStyle(color: Colors.cyan)),
                  Expanded(
                    child: Text(
                      'Will create: $previewPath',
                      style: const TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
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
                '[Tab] cycle fields   [Enter] next/confirm   [ESC] back',
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
    this.initialPlatforms = const ['android', 'ios', 'macos', 'windows', 'linux'],
    this.onExit,
    super.key,
  });
  final InitResult result;
  final String? initialOrg;
  final List<String> initialPlatforms;
  final VoidCallback? onExit;

  @override
  State<NitrogenInitApp> createState() => _NitrogenInitAppState();
}

class _NitrogenInitAppState extends State<NitrogenInitApp> {
  String? _pluginName;
  String? _org;
  String? _targetDir;

  @override
  Component build(BuildContext context) {
    if (_pluginName != null) {
      return InitView(
        pluginName: _pluginName!,
        org: _org ?? component.initialOrg ?? 'com.example',
        targetDir: _targetDir ?? Directory.current.path,
        platforms: component.initialPlatforms,
        result: component.result,
        onExit: component.onExit,
      );
    }
    return PluginNameForm(
      onSubmit: (name, org, dir) => setState(() {
        _pluginName = name;
        _org = org;
        _targetDir = dir;
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

  static const _validPlatforms = {'android', 'ios', 'macos', 'windows', 'linux'};
  static const _defaultPlatforms = 'android,ios,macos,windows,linux';

  InitCommand() {
    argParser
      ..addOption('org', defaultsTo: 'com.example')
      ..addOption(
        'name',
        abbr: 'n',
        help: 'Plugin name (skips interactive form; useful for scripts/CI).',
      )
      ..addOption(
        'dir',
        abbr: 'd',
        help: 'Target directory to create the plugin in. Defaults to the current directory.',
      )
      ..addOption(
        'platforms',
        abbr: 'p',
        defaultsTo: _defaultPlatforms,
        help:
            'Comma-separated list of platforms to scaffold. '
            'Valid: android, ios, macos, windows, linux. '
            'Example: --platforms=android,ios,macos,windows',
      )
      ..addFlag(
        'no-ui',
        negatable: false,
        help: 'Plain-text headless output (no ANSI). Auto-enabled when stdout is not a TTY. Requires --name.',
      );
  }

  List<String> _parsePlatforms(String raw) {
    final platforms = raw.split(',').map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toList();
    final invalid = platforms.where((p) => !_validPlatforms.contains(p)).toList();
    if (invalid.isNotEmpty) {
      stderr.writeln('❌ Unknown platform(s): ${invalid.join(', ')}. Valid: ${_validPlatforms.join(', ')}');
      exit(1);
    }
    return platforms;
  }

  bool get _headless => !stdout.hasTerminal || (argResults!['no-ui'] as bool);

  @override
  Future<void> run() async {
    final headless = _headless;
    final org = argResults!['org'] as String;
    final nameArg = argResults!['name'] as String?;
    final dirArg = argResults!['dir'] as String?;
    final platformsArg = argResults!['platforms'] as String;
    final platforms = _parsePlatforms(platformsArg);

    // Validate --dir if provided
    final targetDir = dirArg?.trim();
    if (targetDir != null && !Directory(targetDir).existsSync()) {
      if (headless) {
        stderr.writeln('[nitro:error] Target directory does not exist: $targetDir');
      } else {
        stderr.writeln('❌ Target directory does not exist: $targetDir');
      }
      exit(1);
    }

    if (headless) {
      if (nameArg == null || nameArg.isEmpty) {
        stderr.writeln('[nitro:error] --no-ui requires --name (interactive form is not available in headless mode).');
        exit(1);
      }
      final pluginName = nameArg.trim();
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(pluginName)) {
        stderr.writeln('[nitro:error] Invalid plugin name "$pluginName". Use only lowercase letters, numbers, and underscores.');
        exit(1);
      }
      await _runHeadless(pluginName: pluginName, org: org, targetDir: targetDir, platforms: platforms);
      return;
    }

    if (targetDir != null) {
      stdout.writeln('  \x1B[90m📂 Creating in: $targetDir\x1B[0m');
    } else {
      stdout.writeln('  \x1B[90m📂 Creating in: ${Directory.current.path}\x1B[0m');
    }

    // Non-interactive path: --name was supplied.
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
          targetDir: targetDir,
          platforms: platforms,
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
    await runApp(NitrogenInitApp(result: result, initialOrg: org, initialPlatforms: platforms));
    if (result.success) {
      stdout.writeln('  \x1B[1;32m✨ ${result.pluginName ?? ''} created\x1B[0m');
    } else {
      exit(1);
    }
  }

  Future<void> _runHeadless({
    required String pluginName,
    required String org,
    required String? targetDir,
    required List<String> platforms,
  }) async {
    void log(String msg) => stdout.writeln('[nitro] $msg');
    void logErr(String msg) => stderr.writeln('[nitro:error] $msg');

    log('nitrogen init $pluginName');
    if (targetDir != null) log('creating in: $targetDir');

    // Change to target directory before any file operations.
    if (targetDir != null) {
      try {
        Directory.current = targetDir;
      } catch (e) {
        logErr('cannot access target directory: $targetDir');
        exit(1);
      }
    }

    final dir = Directory(pluginName);
    if (dir.existsSync()) {
      logErr('directory "$pluginName" already exists. Delete it or use --name with a different name.');
      exit(1);
    }

    final className = _toClassName(pluginName);
    final platformsArg = platforms.join(',');

    // Step 1 — flutter create
    log('running flutter create...');
    final createResult = await Process.run('flutter', [
      'create',
      '--template=plugin_ffi',
      '--platforms=$platformsArg',
      '--org=$org',
      pluginName,
    ]);
    if (createResult.exitCode != 0) {
      logErr('flutter create failed: ${createResult.stderr}');
      exit(1);
    }
    log('created $pluginName/ (platforms: $platformsArg)');

    // Steps 2–7: file configuration (reuse the TUI state machine's logic via a
    // temporary view instance — the methods are pure file I/O with no TUI side effects).
    final dummy = _HeadlessInitRunner(
      pluginName: pluginName,
      className: className,
      org: org,
      platforms: platforms,
    );

    log('setting up src/...');
    dummy.setupSrc();

    if (platforms.contains('ios')) {
      log('configuring iOS...');
      dummy.configureIos();
    }
    if (platforms.contains('android')) {
      log('configuring Android...');
      dummy.configureAndroid();
    }
    if (platforms.contains('macos')) {
      log('configuring macOS...');
      dummy.configureMacos();
    }
    if (platforms.contains('windows')) {
      log('configuring Windows...');
      dummy.configureWindows();
    }
    if (platforms.contains('linux')) {
      log('configuring Linux...');
      dummy.configureLinux();
    }

    // Step 8 — pubspec
    log('fetching pub.dev versions...');
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
    dummy.updatePubspec(nitroVersion: nitroVersion, nitroGeneratorVersion: nitroGeneratorVersion);
    if (usePubAdd) {
      await Process.run('flutter', ['pub', 'add', 'nitro'], workingDirectory: pluginName);
      await Process.run('flutter', ['pub', 'add', '--dev', 'nitro_generator'], workingDirectory: pluginName);
      log('nitro, nitro_generator added via flutter pub add');
    } else {
      await Process.run('flutter', ['pub', 'get'], workingDirectory: pluginName);
      log('nitro $nitroVersion, nitro_generator $nitroGeneratorVersion added');
    }

    dummy.resolveSrcPaths();

    // Step 9 — bridge spec
    log('writing bridge spec...');
    dummy.writeBridgeSpec();
    dummy.writeExampleMain();
    dummy.writeBuildYaml();

    log('$pluginName created');
    log('next: edit lib/src/$pluginName.native.dart → nitrogen generate → nitrogen link');
  }

  static String _toClassName(String pluginName) {
    return pluginName.split('_').map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1)).join('');
  }
}

// ── Headless init runner ──────────────────────────────────────────────────────
// Thin wrapper that calls the pure file-operation methods from _InitViewState
// without spinning up the TUI. Declared here (not inside _InitViewState) so it
// can be used by InitCommand._runHeadless without making _InitViewState methods
// public or static.

class _HeadlessInitRunner {
  _HeadlessInitRunner({
    required this.pluginName,
    required this.className,
    required this.org,
    required this.platforms,
  });

  final String pluginName;
  final String className;
  final String org;
  final List<String> platforms;

  void setupSrc() => _InitViewState._setupSrc(pluginName);
  void configureIos() => _InitViewState._configureIos(pluginName, className);
  void configureAndroid() => _InitViewState._configureAndroid(pluginName, className, org);
  void configureMacos() => _InitViewState._configureMacos(pluginName, className);
  void configureWindows() => _InitViewState._configureWindows(pluginName, className);
  void configureLinux() => _InitViewState._configureLinux(pluginName, className);
  void updatePubspec({String? nitroVersion, String? nitroGeneratorVersion}) =>
      _InitViewState._updatePubspec(pluginName, className, org, platforms: platforms, nitroVersion: nitroVersion, nitroGeneratorVersion: nitroGeneratorVersion);
  void resolveSrcPaths() => _InitViewState._resolveSrcPaths(pluginName);
  void writeBridgeSpec() => _InitViewState._writeBridgeSpec(pluginName, className, platforms: platforms);
  void writeExampleMain() => _InitViewState._writeExampleMain(pluginName, className);
  void writeBuildYaml() => _InitViewState._writeBuildYaml(pluginName);
}
