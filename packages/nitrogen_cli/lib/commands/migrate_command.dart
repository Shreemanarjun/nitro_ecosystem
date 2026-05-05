/// CocoaPods to SPM migration command for nitrogen CLI.
///
/// Provides automatic detection of legacy CocoaPods setup and migration
/// to Swift Package Manager with backup support.
library;

import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import '../ui.dart';
// findNitroProjectRoot is provided by ../ui.dart (already imported below)
import 'spm_utils.dart';
import 'scaffold_templates.dart' show packageSwiftTemplate;

// ── Migration Result ──────────────────────────────────────────────────────────

class MigrationResult {
  bool success = false;
  String? errorMessage;
  List<String> backupPaths = [];
  List<String> migratedPlatforms = [];
}

// ── Migration Step Model ──────────────────────────────────────────────────────

enum MigrationStepState { pending, running, done, failed, skipped }

class MigrationStep {
  final String label;
  MigrationStepState state;
  String? detail;

  MigrationStep(this.label) : state = MigrationStepState.pending;
}

// ── nocterm Progress Component ────────────────────────────────────────────────

class MigrationStepRow extends StatelessComponent {
  const MigrationStepRow(this.step, {super.key});
  final MigrationStep step;

  @override
  Component build(BuildContext context) {
    final String icon;
    final Color color;
    switch (step.state) {
      case MigrationStepState.pending:
        icon = '○';
        color = Colors.gray;
      case MigrationStepState.running:
        icon = '◉';
        color = Colors.cyan;
      case MigrationStepState.done:
        icon = '✔';
        color = Colors.green;
      case MigrationStepState.failed:
        icon = '✘';
        color = Colors.red;
      case MigrationStepState.skipped:
        icon = '–';
        color = Colors.gray;
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
                    color: step.state == MigrationStepState.running ? Colors.cyan : null,
                    fontWeight: step.state == MigrationStepState.running ? FontWeight.bold : null,
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

// ── Migration View ────────────────────────────────────────────────────────────

class MigrateView extends StatefulComponent {
  const MigrateView({
    required this.pluginName,
    required this.result,
    required this.spmStatus,
    this.createBackup = true,
    this.onExit,
    super.key,
  });

  final String pluginName;
  final MigrationResult result;
  final SpmStatus spmStatus;
  final bool createBackup;
  final VoidCallback? onExit;

  @override
  State<MigrateView> createState() => _MigrateViewState();
}

class _MigrateViewState extends State<MigrateView> {
  static const _kStepDetect = 0;
  static const _kStepBackup = 1;
  static const _kStepIosPackage = 2;
  static const _kStepMacosPackage = 3;
  static const _kStepIosSources = 4;
  static const _kStepMacosSources = 5;
  static const _kStepCleanup = 6;
  static const _kStepVerify = 7;

  late final List<MigrationStep> _steps = [
    MigrationStep('Detecting current configuration'),
    MigrationStep('Creating backup'),
    MigrationStep('Creating iOS Package.swift'),
    MigrationStep('Creating macOS Package.swift'),
    MigrationStep('Setting up iOS SPM Sources'),
    MigrationStep('Setting up macOS SPM Sources'),
    MigrationStep('Cleaning up legacy files'),
    MigrationStep('Verifying migration'),
  ];

  bool _finished = false;
  bool _failed = false;
  bool _needsConfirmation = false;
  String? _errorMessage;

  String _stepsAsText() {
    final buf = StringBuffer();
    buf.writeln('nitrogen migrate — ${component.pluginName}');
    buf.writeln('');
    for (final step in _steps) {
      final icon = switch (step.state) {
        MigrationStepState.done => '✔',
        MigrationStepState.skipped => '–',
        MigrationStepState.running => '⚙',
        MigrationStepState.failed => '✘',
        MigrationStepState.pending => '○',
      };
      buf.write('  $icon ${step.label}');
      if (step.detail != null) buf.write('  (${step.detail})');
      buf.writeln();
    }
    if (_errorMessage != null) {
      buf.writeln('\nERROR: $_errorMessage');
    } else if (_finished && !_failed) {
      buf.writeln('\n✨ Migration complete!');
    }
    return buf.toString();
  }

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, _checkAndRun);
  }

  void _setRunning(int i) => setState(() => _steps[i].state = MigrationStepState.running);
  void _setDone(int i, {String? detail}) => setState(() {
    _steps[i].state = MigrationStepState.done;
    _steps[i].detail = detail;
  });
  void _setSkipped(int i, {String? detail}) => setState(() {
    _steps[i].state = MigrationStepState.skipped;
    _steps[i].detail = detail;
  });
  void _setFailed(int i, String msg) => setState(() {
    _steps[i].state = MigrationStepState.failed;
    _steps[i].detail = msg;
    _failed = true;
    _errorMessage = msg;
    _finished = true;
  });

  Future<void> _checkAndRun() async {
    final status = component.spmStatus;

    // Step 0: Detection
    _setRunning(_kStepDetect);
    if (status.isModern) {
      _setDone(_kStepDetect, detail: 'Already using SPM');
      _setSkipped(_kStepBackup, detail: 'No migration needed');
      _setSkipped(_kStepIosPackage, detail: 'Already present');
      _setSkipped(_kStepMacosPackage, detail: 'Already present');
      _setSkipped(_kStepIosSources, detail: 'Already configured');
      _setSkipped(_kStepMacosSources, detail: 'Already configured');
      _setSkipped(_kStepCleanup, detail: 'Nothing to clean');
      _setSkipped(_kStepVerify, detail: 'No changes made');
      component.result.success = true;
      setState(() => _finished = true);
      return;
    }

    if (status.isLegacy) {
      _setDone(_kStepDetect, detail: 'Found CocoaPods setup, ready to migrate');
    } else if (status.isMixed) {
      _setDone(_kStepDetect, detail: 'Mixed setup detected, will complete SPM migration');
    } else {
      _setSkipped(_kStepDetect, detail: 'No Apple platforms found');
      _skipRemaining(1);
      component.result.success = true;
      setState(() => _finished = true);
      return;
    }

    setState(() => _needsConfirmation = true);
  }

  void _skipRemaining(int fromIndex) {
    for (var i = fromIndex; i < _steps.length; i++) {
      _setSkipped(i, detail: 'Skipped');
    }
  }

  Future<void> _runMigration() async {
    setState(() => _needsConfirmation = false);

    final baseDir = Directory.current.path;
    final pluginName = component.pluginName;
    final className = toPascalCase(pluginName);
    final status = component.spmStatus;

    // Step 1: Backup
    _setRunning(_kStepBackup);
    if (component.createBackup) {
      try {
        final backupPaths = await _createBackup(baseDir);
        component.result.backupPaths = backupPaths;
        _setDone(_kStepBackup, detail: '${backupPaths.length} files backed up');
      } catch (e) {
        _setFailed(_kStepBackup, 'Backup failed: $e');
        return;
      }
    } else {
      _setSkipped(_kStepBackup, detail: 'Backup disabled');
    }

    // Step 2: iOS Package.swift
    _setRunning(_kStepIosPackage);
    final iosDir = Directory(p.join(baseDir, 'ios'));
    if (iosDir.existsSync() && !status.iosHasSpm) {
      try {
        _createPackageSwift(iosDir.path, pluginName, className, 'iOS(.v13)');
        component.result.migratedPlatforms.add('ios');
        _setDone(_kStepIosPackage, detail: 'Created ios/$pluginName/Package.swift (nested layout)');
      } catch (e) {
        _setFailed(_kStepIosPackage, 'Failed: $e');
        return;
      }
    } else if (!iosDir.existsSync()) {
      _setSkipped(_kStepIosPackage, detail: 'ios/ not present');
    } else {
      _setSkipped(_kStepIosPackage, detail: 'Already exists');
    }

    // Step 3: macOS Package.swift
    _setRunning(_kStepMacosPackage);
    final macosDir = Directory(p.join(baseDir, 'macos'));
    if (macosDir.existsSync() && !status.macosHasSpm) {
      try {
        _createPackageSwift(macosDir.path, pluginName, className, 'macOS(.v10_15)', isMacos: true);
        component.result.migratedPlatforms.add('macos');
        _setDone(_kStepMacosPackage, detail: 'Created macos/$pluginName/Package.swift (nested layout)');
      } catch (e) {
        _setFailed(_kStepMacosPackage, 'Failed: $e');
        return;
      }
    } else if (!macosDir.existsSync()) {
      _setSkipped(_kStepMacosPackage, detail: 'macos/ not present');
    } else {
      _setSkipped(_kStepMacosPackage, detail: 'Already exists');
    }

    // Step 4: iOS Sources structure
    _setRunning(_kStepIosSources);
    if (iosDir.existsSync()) {
      try {
        createSpmSourcesStructure(baseDir, 'ios', className, pluginName);
        _setDone(_kStepIosSources, detail: 'Sources/$className + ${className}Cpp created');
      } catch (e) {
        _setFailed(_kStepIosSources, 'Failed: $e');
        return;
      }
    } else {
      _setSkipped(_kStepIosSources, detail: 'ios/ not present');
    }

    // Step 5: macOS Sources structure
    _setRunning(_kStepMacosSources);
    if (macosDir.existsSync()) {
      try {
        createSpmSourcesStructure(baseDir, 'macos', className, pluginName);
        _setDone(_kStepMacosSources, detail: 'Sources/$className + ${className}Cpp created');
      } catch (e) {
        _setFailed(_kStepMacosSources, 'Failed: $e');
        return;
      }
    } else {
      _setSkipped(_kStepMacosSources, detail: 'macos/ not present');
    }

    // Step 6: Cleanup legacy files (optional, keep podspecs for compatibility)
    _setRunning(_kStepCleanup);
    // Don't delete podspecs - they can coexist with SPM for backwards compatibility
    // Just remove any Podfile.lock in example/ if present
    final examplePodLock = File(p.join(baseDir, 'example', 'ios', 'Podfile.lock'));
    if (examplePodLock.existsSync()) {
      examplePodLock.deleteSync();
    }
    _setDone(_kStepCleanup, detail: 'Podspecs preserved for compatibility');

    // Step 7: Verify
    _setRunning(_kStepVerify);
    final newStatus = detectSpmStatus(baseDir);
    if (newStatus.hasSpm) {
      _setDone(_kStepVerify, detail: 'SPM setup verified');
      component.result.success = true;
    } else {
      _setFailed(_kStepVerify, 'SPM not detected after migration');
      return;
    }

    setState(() => _finished = true);
  }

  void _createPackageSwift(
    String platformPath,
    String pluginName,
    String className,
    String platformSpec, {
    bool isMacos = false,
  }) {
    // Flutter 3.41+ nested layout: ios/<pluginName>/Package.swift
    // This is auto-detected by Flutter; older flat ios/Package.swift is not.
    final packageDir = Directory(p.join(platformPath, pluginName));
    packageDir.createSync(recursive: true);

    // Create Sources directories inside the nested package dir
    final sourcesDir = Directory(p.join(packageDir.path, 'Sources'));
    final swiftDir = Directory(p.join(sourcesDir.path, className));
    final cppDir = Directory(p.join(sourcesDir.path, '${className}Cpp'));
    swiftDir.createSync(recursive: true);
    cppDir.createSync(recursive: true);

    // Symlinks in Swift target — 3 levels up to reach ios/Classes/
    for (final name in [
      'Swift${className}Plugin.swift',
      '${className}Impl.swift',
      '$pluginName.bridge.g.swift',
    ]) {
      final lnk = Link(p.join(swiftDir.path, name));
      if (!lnk.existsSync()) {
        try { lnk.createSync('../../../Classes/$name'); } catch (_) {}
      }
    }

    // Symlinks in Cpp target
    for (final name in ['$pluginName.cpp', 'dart_api_dl.c']) {
      final lnk = Link(p.join(cppDir.path, name));
      if (!lnk.existsSync()) {
        try { lnk.createSync('../../../Classes/$name'); } catch (_) {}
      }
    }

    // include → Classes/ (public headers)
    final includeLink = Link(p.join(cppDir.path, 'include'));
    if (!includeLink.existsSync()) {
      try { includeLink.createSync('../../../Classes'); } catch (_) {}
    }

    // Write Package.swift
    final packageSwift = File(p.join(packageDir.path, 'Package.swift'));
    packageSwift.writeAsStringSync(packageSwiftTemplate(pluginName, className, platformSpec, isMacos: isMacos));
  }

  Future<List<String>> _createBackup(String baseDir) async {
    final backupDir = Directory(p.join(baseDir, '.nitrogen_backup_${DateTime.now().millisecondsSinceEpoch}'));
    backupDir.createSync();

    final backupPaths = <String>[];

    // Backup iOS podspec and Podfile
    for (final platform in ['ios', 'macos']) {
      final platformDir = Directory(p.join(baseDir, platform));
      if (!platformDir.existsSync()) continue;

      final podspecs = platformDir.listSync().whereType<File>().where((f) => f.path.endsWith('.podspec'));
      for (final podspec in podspecs) {
        final dest = p.join(backupDir.path, platform, p.basename(podspec.path));
        Directory(p.dirname(dest)).createSync(recursive: true);
        podspec.copySync(dest);
        backupPaths.add(dest);
      }
    }

    // Backup example Podfiles
    final exampleIosPodfile = File(p.join(baseDir, 'example', 'ios', 'Podfile'));
    if (exampleIosPodfile.existsSync()) {
      final dest = p.join(backupDir.path, 'example', 'ios', 'Podfile');
      Directory(p.dirname(dest)).createSync(recursive: true);
      exampleIosPodfile.copySync(dest);
      backupPaths.add(dest);
    }

    return backupPaths;
  }

  bool _handleKey(KeyboardEvent e) {
    if (_needsConfirmation) {
      if (e.logicalKey == LogicalKey.keyY) {
        _runMigration();
        return true;
      }
      if (e.logicalKey == LogicalKey.keyN || e.logicalKey == LogicalKey.escape) {
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
    if (e.character == 'c' || e.character == 'C') {
      copyToClipboard(_stepsAsText());
      return true;
    }

    return false;
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
                  ' nitrogen migrate — ${component.pluginName} ',
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
                    const Text(
                      '📦 CocoaPods to SPM Migration',
                      style: TextStyle(color: Colors.yellow, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      component.spmStatus.isLegacy
                          ? 'Found CocoaPods-only setup. Ready to add SPM support.'
                          : 'Mixed setup detected. Will complete SPM configuration.',
                    ),
                    const SizedBox(height: 1),
                    Text(
                      component.createBackup
                          ? 'A backup will be created before migration.'
                          : 'No backup will be created (--no-backup).',
                      style: const TextStyle(color: Colors.gray),
                    ),
                    const SizedBox(height: 1),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('[Y]', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                        Text(' Migrate   '),
                        Text('[N]', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                        Text(' Cancel'),
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
                            Text(_errorMessage!),
                          ],
                        ),
                      )
                    : Container(
                        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.brightBlack)),
                        child: Padding(
                          padding: const EdgeInsets.all(1),
                          child: ListView(
                            children: _steps.map(MigrationStepRow.new).toList(),
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
                        '✘ Migration failed: ${_errorMessage ?? ""}',
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      )
                    : Column(
                        children: [
                          const Text(
                            '✨ Migration complete!',
                            style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                          ),
                          if (component.result.migratedPlatforms.isNotEmpty)
                            Text(
                              'Migrated: ${component.result.migratedPlatforms.join(", ")}',
                              style: const TextStyle(color: Colors.gray),
                            ),
                          const SizedBox(height: 1),
                          const Text(
                            'Run: nitrogen link  to sync generated files',
                            style: TextStyle(color: Colors.gray),
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
                              CopyButton(getData: _stepsAsText),
                              const Text('  •  ', style: TextStyle(color: Colors.brightBlack)),
                              Text(
                                'c copy   ${component.onExit != null ? 'ESC back' : 'ESC exit'}',
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
}

// ── MigrateCommand ────────────────────────────────────────────────────────────

class MigrateCommand extends Command {
  @override
  final String name = 'migrate';

  @override
  final String description = 'Migrates a CocoaPods-based plugin to Swift Package Manager (SPM).';

  MigrateCommand() {
    argParser.addFlag(
      'backup',
      defaultsTo: true,
      help: 'Create a backup before migration',
    );
    argParser.addFlag(
      'dry-run',
      defaultsTo: false,
      help: 'Show what would be migrated without making changes',
    );
  }

  @override
  Future<void> run() async {
    final createBackup = argResults!['backup'] as bool;
    final dryRun = argResults!['dry-run'] as bool;

    final projectDir = findNitroProjectRoot();
    if (projectDir == null) {
      stderr.writeln('❌ No Nitro project found in . or its subdirectories.');
      exit(1);
    }

    final originalCwd = Directory.current;
    Directory.current = projectDir;

    if (projectDir.path != originalCwd.path) {
      stdout.writeln('  \x1B[90m📂 Found project in: ${projectDir.path}\x1B[0m');
    }

    // Read plugin name from pubspec
    final pubspec = File(p.join(projectDir.path, 'pubspec.yaml'));
    String pluginName = 'unknown';
    for (final line in pubspec.readAsLinesSync()) {
      if (line.trim().startsWith('name: ')) {
        pluginName = line.replaceFirst('name: ', '').trim();
        break;
      }
    }

    // Detect current SPM status
    final spmStatus = detectSpmStatus(projectDir.path);

    if (dryRun) {
      _printDryRun(pluginName, spmStatus);
      exit(0);
    }

    final result = MigrationResult();
    await runApp(
      MigrateView(
        pluginName: pluginName,
        result: result,
        spmStatus: spmStatus,
        createBackup: createBackup,
      ),
    );

    if (result.success) {
      if (result.migratedPlatforms.isNotEmpty) {
        stdout.writeln('  \x1B[1;32m✨ Migration complete: ${result.migratedPlatforms.join(", ")}\x1B[0m');
      } else {
        stdout.writeln('  \x1B[1;32m✨ Already using SPM — no migration needed\x1B[0m');
      }
    } else {
      exit(1);
    }
  }

  void _printDryRun(String pluginName, SpmStatus status) {
    stdout.writeln('\n  \x1B[1;36m📦 Migration Dry Run — $pluginName\x1B[0m\n');

    if (status.isModern) {
      stdout.writeln('  ✔ Already using SPM — no migration needed');
      return;
    }

    stdout.writeln('  Current status:');
    stdout.writeln('    iOS:');
    stdout.writeln('      SPM:      ${status.iosHasSpm ? "✔" : "✘"}');
    stdout.writeln('      Podspec:  ${status.iosHasPodspec ? "✔" : "✘"}');
    stdout.writeln('    macOS:');
    stdout.writeln('      SPM:      ${status.macosHasSpm ? "✔" : "✘"}');
    stdout.writeln('      Podspec:  ${status.macosHasPodspec ? "✔" : "✘"}');

    stdout.writeln('\n  Would perform:');
    if (!status.iosHasSpm && status.iosHasPodspec) {
      stdout.writeln('    • Create ios/Package.swift');
      stdout.writeln('    • Create ios/Sources/ structure');
    }
    if (!status.macosHasSpm && status.macosHasPodspec) {
      stdout.writeln('    • Create macos/Package.swift');
      stdout.writeln('    • Create macos/Sources/ structure');
    }

    stdout.writeln('\n  Run without --dry-run to apply changes.\n');
  }
}
