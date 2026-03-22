import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

// ── Progress model (shared Step/StepRow pattern) ──────────────────────────────

enum _StepState { pending, running, done, failed, skipped }

class _Step {
  final String label;
  _StepState state;
  String? detail;

  _Step(this.label) : state = _StepState.pending;
}

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
      case _StepState.skipped:
        icon = '–';
        color = Colors.gray;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 2),
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
                    fontWeight:
                        step.state == _StepState.running ? FontWeight.bold : null,
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

// ── Result holder ─────────────────────────────────────────────────────────────

class _LinkResult {
  bool success = false;
}

// ── nocterm Link component ────────────────────────────────────────────────────

class _LinkApp extends StatefulComponent {
  const _LinkApp({required this.pluginName, required this.result});
  final String pluginName;
  final _LinkResult result;

  @override
  State<_LinkApp> createState() => _LinkAppState();
}

class _LinkAppState extends State<_LinkApp> {
  late final List<_Step> _steps = [
    _Step('Discovering modules'),
    _Step('Updating src/CMakeLists.txt'),
    _Step('Updating iOS podspec'),
    _Step('Updating Kotlin Plugin.kt'),
    _Step('Updating .clangd'),
  ];

  bool _finished = false;
  bool _failed = false;
  final List<String> _nextSteps = [];

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

  Future<void> _setSkipped(int i, {String? detail}) async {
    setState(() {
      _steps[i].state = _StepState.skipped;
      _steps[i].detail = detail;
    });
  }

  Future<void> _run() async {
    final pluginName = component.pluginName;

    // Step 0 — discover modules
    await _setRunning(0);
    final moduleLibs = _discoverModuleLibs(pluginName);
    await _setDone(0, detail: '${moduleLibs.length} module(s): ${moduleLibs.join(', ')}');

    // Step 1 — CMake
    await _setRunning(1);
    _linkCMake(pluginName, moduleLibs);
    await _setDone(1);

    // Step 2 — Podspec
    await _setRunning(2);
    if (Directory('ios').existsSync()) {
      _linkPodspec(pluginName, moduleLibs);
      await _setDone(2);
    } else {
      await _setSkipped(2, detail: 'ios/ not present');
    }

    // Step 3 — Kotlin Plugin
    await _setRunning(3);
    if (Directory('android').existsSync()) {
      _linkKotlinPlugin(pluginName, moduleLibs);
      await _setDone(3);
    } else {
      await _setSkipped(3, detail: 'android/ not present');
    }

    // Step 4 — .clangd
    await _setRunning(4);
    _linkClangd(pluginName);
    await _setDone(4);

    _nextSteps.addAll([
      'flutter pub get',
      'flutter pub run build_runner build --delete-conflicting-outputs',
      'Implement generated Hybrid*Spec interfaces in Kotlin/Swift',
    ]);

    component.result.success = !_failed;
    setState(() => _finished = true);
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: _finished,
      onKeyEvent: (_) {
        shutdownApp(_failed ? 1 : 0);
        return true;
      },
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Column(
          children: [
            Container(
              decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  ' nitrogen link — ${component.pluginName} ',
                  style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const Padding(padding: EdgeInsets.only(bottom: 1), child: Text('')),
            Container(
              decoration: BoxDecoration(border: BoxBorder.all(color: Colors.brightBlack)),
              child: Padding(
                padding: const EdgeInsets.all(1),
                child: Column(children: _steps.map(_StepRow.new).toList()),
              ),
            ),
            if (_finished && !_failed)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Column(
                  children: [
                    const Text('✨ Linked! Next steps:',
                        style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                    ..._nextSteps.asMap().entries.map(
                          (e) => Text(
                            '  ${e.key + 1}. ${e.value}',
                            style: const TextStyle(color: Colors.gray),
                          ),
                        ),
                  ],
                ),
              ),
            if (_finished)
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Text(
                  'Press any key to exit',
                  style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Link logic (same as original LinkCommand, inlined) ────────────────────

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
      final stem = p.basename(spec.path).replaceAll(RegExp(r'\.native\.dart$'), '');
      final libName = _extractLibName(spec) ?? stem.replaceAll('-', '_');
      if (!libs.contains(libName)) libs.add(libName);
    }
    return libs.isEmpty ? [pluginName] : libs;
  }

  String? _extractLibName(File specFile) {
    final content = specFile.readAsStringSync();
    final match =
        RegExp(r'''@NitroModule\s*\([^)]*lib\s*:\s*['"]([^'"]+)['"]''')
            .firstMatch(content);
    return match?.group(1);
  }

  void _linkCMake(String pluginName, List<String> moduleLibs) {
    final cmakeFile = File(p.join('src', 'CMakeLists.txt'));
    if (!cmakeFile.existsSync()) {
      _generateCMake(pluginName, moduleLibs);
      return;
    }
    var content = cmakeFile.readAsStringSync();
    bool modified = false;
    const nitroNativeVar =
        'set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")';
    const nitroNativePath =
        '"\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native"';

    if (!content.contains('NITRO_NATIVE')) {
      content = '$nitroNativeVar\n\n$content';
      modified = true;
    }
    if (!content.contains('packages/nitro/src/native')) {
      content = content.replaceFirst(
        'target_include_directories($pluginName PRIVATE',
        'target_include_directories($pluginName PRIVATE\n  $nitroNativePath',
      );
      modified = true;
    }
    final dartApiDl = '"\${NITRO_NATIVE}/dart_api_dl.c"';
    if (!content.contains('dart_api_dl.c')) {
      content = content.replaceFirst(
        'add_library($pluginName SHARED',
        'add_library($pluginName SHARED\n  $dartApiDl',
      );
      modified = true;
    }
    for (final lib in moduleLibs) {
      if (lib == pluginName) continue;
      if (!content.contains('add_library($lib ')) {
        content += _cmakeModuleTarget(lib);
        modified = true;
      }
    }
    if (modified) cmakeFile.writeAsStringSync(content);
  }

  void _generateCMake(String pluginName, List<String> moduleLibs) {
    Directory('src').createSync(recursive: true);
    final sb = StringBuffer()
      ..writeln('cmake_minimum_required(VERSION 3.10)')
      ..writeln('project(${pluginName}_library VERSION 0.0.1 LANGUAGES C CXX)')
      ..writeln()
      ..writeln('set(NITRO_NATIVE "\${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")')
      ..writeln()
      ..writeln('add_library($pluginName SHARED')
      ..writeln('  "$pluginName.cpp"')
      ..writeln('  "\${NITRO_NATIVE}/dart_api_dl.c"')
      ..writeln(')')
      ..writeln('target_include_directories($pluginName PRIVATE')
      ..writeln('  "\${CMAKE_CURRENT_SOURCE_DIR}"')
      ..writeln('  "\${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"')
      ..writeln('  "\${NITRO_NATIVE}"')
      ..writeln(')')
      ..writeln('target_compile_definitions($pluginName PUBLIC DART_SHARED_LIB)')
      ..writeln('if(ANDROID)')
      ..writeln('  target_link_libraries($pluginName PRIVATE android log)')
      ..writeln('  target_link_options($pluginName PRIVATE "-Wl,-z,max-page-size=16384")')
      ..writeln('endif()');
    for (final lib in moduleLibs) {
      if (lib != pluginName) sb.write(_cmakeModuleTarget(lib));
    }
    File(p.join('src', 'CMakeLists.txt')).writeAsStringSync(sb.toString());
  }

  String _cmakeModuleTarget(String lib) => '''

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

  void _linkPodspec(String pluginName, List<String> moduleLibs) {
    final podspecFile = File(p.join('ios', '$pluginName.podspec'));
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
        's.pod_target_xcconfig = {\n    $searchPathEntry,',
      );
      modified = true;
    }
    if (modified) podspecFile.writeAsStringSync(content);

    final dartApiDl = File(p.join('ios', 'Classes', 'dart_api_dl.cpp'));
    if (!dartApiDl.existsSync()) {
      dartApiDl.createSync(recursive: true);
      dartApiDl.writeAsStringSync(
          '// Forwarder for Nitro/FFI Dart DL API\n'
          '#include "../../../packages/nitro/src/native/dart_api_dl.c"\n');
    }
  }

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

    final missingLibs =
        moduleLibs.where((l) => !content.contains('System.loadLibrary("$l")')).toList();
    if (missingLibs.isNotEmpty) {
      if (!content.contains('System.loadLibrary')) {
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
        for (final lib in missingLibs) {
          content = content.replaceFirst(
            'System.loadLibrary("$pluginName")',
            'System.loadLibrary("$pluginName")\n      System.loadLibrary("$lib")',
          );
        }
      }
      modified = true;
    }
    if (modified) pluginFile.writeAsStringSync(content);
  }

  void _linkClangd(String pluginName) {
    File('.clangd').writeAsStringSync('''CompileFlags:
  Add:
    - -I\${PWD}/src
    - -I\${PWD}/lib/src/generated/cpp
    - -I\${PWD}/../packages/nitro/src/native
''');
  }
}

// ── LinkCommand ───────────────────────────────────────────────────────────────

class LinkCommand extends Command {
  @override
  final String name = 'link';

  @override
  final String description =
      'Wires all Nitrogen-generated native bridges into the build system '
      '(CMake, Podspec, Kotlin plugin class).';

  @override
  Future<void> run() async {
    final pubspecFile = File('pubspec.yaml');
    if (!pubspecFile.existsSync()) {
      stderr.writeln(
          '❌ No pubspec.yaml found. Run this from the root of a Flutter plugin.');
      exit(1);
    }
    final pluginName = _getPluginName(pubspecFile);
    final result = _LinkResult();
    await runApp(_LinkApp(pluginName: pluginName, result: result));

    if (result.success) {
      stdout.writeln('');
      stdout.writeln('  \x1B[1;32m✨ $pluginName linked\x1B[0m  — run: flutter pub get && nitrogen generate');
      stdout.writeln('');
    }
  }

  String _getPluginName(File pubspec) {
    for (final line in pubspec.readAsLinesSync()) {
      if (line.startsWith('name: ')) return line.replaceFirst('name: ', '').trim();
    }
    return 'unknown';
  }
}
