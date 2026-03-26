import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import '../ui.dart';

class UpdateCommand extends Command {
  @override
  final String name = 'update';
  @override
  final String description = 'Self-update the Nitrogen CLI.';

  @override
  Future<void> run() async {
    final result = UpdateResult();
    await runApp(UpdateView(result: result));

    if (result.success) {
      stdout.writeln(green('✨ nitrogen is up to date!'));
    } else {
      stderr.writeln(red('❌ Update failed. Try running: dart pub global activate nitrogen_cli'));
      exit(1);
    }
  }
}

class UpdateStep {
  final String label;
  UpdateStepState state = UpdateStepState.idle;
  String? detail;
  UpdateStep(this.label);
}

enum UpdateStepState { idle, running, done, skipped }

class UpdateStepRow extends StatelessComponent {
  const UpdateStepRow(this.step, {super.key});
  final UpdateStep step;

  @override
  Component build(BuildContext context) {
    final icon = switch (step.state) {
      UpdateStepState.idle => '○',
      UpdateStepState.running => '●',
      UpdateStepState.done => '✔',
      UpdateStepState.skipped => '⊖',
    };
    final color = switch (step.state) {
      UpdateStepState.idle => Colors.gray,
      UpdateStepState.running => Colors.cyan,
      UpdateStepState.done => Colors.green,
      UpdateStepState.skipped => Colors.yellow,
    };

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
                    color: step.state == UpdateStepState.running ? Colors.cyan : null,
                    fontWeight: step.state == UpdateStepState.running ? FontWeight.bold : null,
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

class UpdateResult {
  bool success = false;
}

class UpdateView extends StatefulComponent {
  const UpdateView({
    required this.result,
    this.onExit,
    super.key,
  });
  final UpdateResult result;
  final VoidCallback? onExit;

  @override
  State<UpdateView> createState() => _UpdateViewState();
}

class _UpdateViewState extends State<UpdateView> {
  final List<UpdateStep> _steps = [
    UpdateStep('Check current activation'),
    UpdateStep('Check for updates on pub.dev'),
    UpdateStep('Running update'),
  ];

  bool _finished = false;
  bool _failed = false;
  String? _errorMessage;
  String? _currentVersion;
  String? _latestVersion;
  bool _isPathActivated = false;
  String? _repoRoot;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration.zero, _run);
  }

  void _setRunning(int i) => setState(() => _steps[i].state = UpdateStepState.running);
  void _setDone(int i, {String? detail}) => setState(() {
        _steps[i].state = UpdateStepState.done;
        _steps[i].detail = detail;
      });
  void _setFailed(int i, String msg) => setState(() {
        _errorMessage ??= msg;
        _steps[i].state = UpdateStepState.done;
        _steps[i].detail = msg;
        _failed = true;
      });
  void _setSkipped(int i, {String? detail}) => setState(() {
        _steps[i].state = UpdateStepState.skipped;
        _steps[i].detail = detail;
      });

  Future<String?> _fetchLatestVersion() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('https://pub.dev/api/packages/nitrogen_cli')).timeout(const Duration(seconds: 5));
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body);
        return json['latest']['version'];
      }
    } catch (_) {}
    return null;
  }

  Future<void> _run() async {
    try {
      // Step 0 — Check activation
      _setRunning(0);
      final listResult = await Process.run('dart', ['pub', 'global', 'list']);
      final listOut = listResult.stdout as String;
      final lines = listOut.split('\n');
      final nitroLine = lines.firstWhere((l) => l.contains('nitrogen_cli'), orElse: () => '');

      if (nitroLine.contains('at path')) {
        _isPathActivated = true;
        _repoRoot = nitroLine.split('"')[1];
        _setDone(0, detail: 'Path activated: $_repoRoot');
      } else {
        _isPathActivated = false;
        final versionMatch = RegExp(r'nitrogen_cli (\d+\.\d+\.\d+)').firstMatch(nitroLine);
        _currentVersion = versionMatch?.group(1) ?? 'unknown';
        _setDone(0, detail: 'Hosted: v$_currentVersion');
      }

      // Step 1 — Check pub.dev
      _setRunning(1);
      _latestVersion = await _fetchLatestVersion();
      if (_latestVersion != null) {
        _setDone(1, detail: 'Latest: v$_latestVersion');
      } else {
        _setFailed(1, 'Failed to fetch latest version from pub.dev');
        setState(() => _finished = true);
        return;
      }

      if (_currentVersion != null && _latestVersion != null && _currentVersion == _latestVersion) {
        _setSkipped(2, detail: 'Already up to date');
        component.result.success = true;
        setState(() => _finished = true);
        return;
      }

      // Step 2 — Update
      _setRunning(2);
      if (_isPathActivated && _repoRoot != null) {
        // Git pull if path activated
        final pullResult = await Process.run('git', ['pull', '--ff-only'], workingDirectory: _repoRoot);
        if (pullResult.exitCode == 0) {
          _setDone(2, detail: 'Git pulled in $_repoRoot');
        } else {
          _setFailed(2, 'Git pull failed: ${pullResult.stderr}');
        }
      } else {
        // Global activate if hosted
        final activateResult = await Process.run('dart', ['pub', 'global', 'activate', 'nitrogen_cli']);
        if (activateResult.exitCode == 0) {
          _setDone(2, detail: 'Activated v${_latestVersion ?? "latest"} from pub.dev');
        } else {
          _setFailed(2, 'Activation failed: ${activateResult.stderr}');
        }
      }
    } catch (e) {
      setState(() {
        _failed = true;
        _errorMessage = e.toString();
      });
    }

    component.result.success = !_failed;
    setState(() => _finished = true);
  }

  bool _handleKey(KeyboardEvent e) {
    if (e.logicalKey == LogicalKey.escape) {
      if (component.onExit != null) {
        component.onExit!();
        return true;
      }
      shutdownApp(_failed ? 1 : 0);
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
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Text(' nitrogen update ', style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
          const Padding(padding: EdgeInsets.only(bottom: 1), child: Text('')),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: _errorMessage != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                            decoration: BoxDecoration(border: BoxBorder.all(color: Colors.red)),
                            child: const Text(' ✘  ERROR ', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(height: 1),
                          Text(_errorMessage!, style: const TextStyle(color: Colors.white)),
                          const SizedBox(height: 1),
                          const Text('Hint: Verify your internet connection or pub.dev reachability.', style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim)),
                        ],
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(border: BoxBorder.all(color: Colors.brightBlack)),
                      child: Padding(
                        padding: const EdgeInsets.all(1),
                        child: ListView(
                          children: _steps.map(UpdateStepRow.new).toList(),
                        ),
                      ),
                    ),
            ),
          ),
          if (_finished)
            Padding(
              padding: const EdgeInsets.only(top: 1, bottom: 1, left: 1, right: 1),
              child: Column(
                children: [
                  _failed
                      ? const Text('✘ Update failed', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold))
                      : const Text('✨ nitrogen is up to date!', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
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
      ),
    );
  }
}
