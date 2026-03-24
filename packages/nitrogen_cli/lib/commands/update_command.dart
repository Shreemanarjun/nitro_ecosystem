import 'dart:io';
import 'dart:convert';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';

// ── Step model ────────────────────────────────────────────────────────────────

enum UpdateStepState { pending, running, done, failed, skipped }

class UpdateStep {
  final String label;
  UpdateStepState state;
  String? detail;

  UpdateStep(this.label) : state = UpdateStepState.pending;
}

class UpdateStepRow extends StatelessComponent {
  const UpdateStepRow(this.step, {super.key});
  final UpdateStep step;

  @override
  Component build(BuildContext context) {
    final String icon;
    final Color color;
    switch (step.state) {
      case UpdateStepState.pending:
        icon = '○';
        color = Colors.gray;
      case UpdateStepState.running:
        icon = '◉';
        color = Colors.cyan;
      case UpdateStepState.done:
        icon = '✔';
        color = Colors.green;
      case UpdateStepState.failed:
        icon = '✘';
        color = Colors.red;
      case UpdateStepState.skipped:
        icon = '–';
        color = Colors.gray;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Column(
        children: [
          Row(
            children: [
              Text(icon,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              const Text(' '),
              Expanded(
                child: Text(
                  step.label,
                  style: TextStyle(
                    color: step.state == UpdateStepState.running
                        ? Colors.cyan
                        : null,
                    fontWeight: step.state == UpdateStepState.running
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
                style: const TextStyle(
                    color: Colors.gray, fontWeight: FontWeight.dim),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Result holder ─────────────────────────────────────────────────────────────

class UpdateResult {
  bool success = false;
  String? errorMessage;
}

// ── nocterm Update component ──────────────────────────────────────────────────

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
  late final List<UpdateStep> _steps = [
    UpdateStep('Checking current activation'),
    UpdateStep('Checking pub.dev for updates'),
    UpdateStep('Syncing local / Pulling from pub.dev'),
  ];

  bool _finished = false;
  bool _failed = false;
  String? _currentVersion;
  String? _latestVersion;
  bool _isPathActivated = false;
  String? _repoRoot;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration.zero, _run);
  }

  void _setRunning(int i) =>
      setState(() => _steps[i].state = UpdateStepState.running);
  void _setDone(int i, {String? detail}) => setState(() {
        _steps[i].state = UpdateStepState.done;
        _steps[i].detail = detail;
      });
  void _setFailed(int i, String msg) => setState(() {
        _steps[i].state = UpdateStepState.failed;
        _steps[i].detail = msg;
        _failed = true;
      });

  Future<void> _run() async {
    // Step 0 — Check activation
    _setRunning(0);
    final listResult = await Process.run('dart', ['pub', 'global', 'list']);
    final listOut = listResult.stdout as String;
    final lines = listOut.split('\n');
    final nitroLine =
        lines.firstWhere((l) => l.contains('nitrogen_cli'), orElse: () => '');

    if (nitroLine.contains('at path')) {
      _isPathActivated = true;
      _repoRoot = nitroLine.split('"')[1];
      _setDone(0, detail: 'Path activated: $_repoRoot');
    } else {
      _isPathActivated = false;
      final versionMatch =
          RegExp(r'nitrogen_cli (\d+\.\d+\.\d+)').firstMatch(nitroLine);
      _currentVersion = versionMatch?.group(1) ?? 'unknown';
      _setDone(0, detail: 'Hosted: v$_currentVersion');
    }

    // Step 1 — Check pub.dev
    _setRunning(1);
    try {
      final client = HttpClient();
      final request = await client
          .getUrl(Uri.parse('https://pub.dev/api/packages/nitrogen_cli'));
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body);
        _latestVersion = json['latest']['version'];
        _setDone(1, detail: 'Latest: v$_latestVersion');
      } else {
        _setDone(1, detail: 'Skipped: pub.dev unreachable');
      }
    } catch (e) {
      _setDone(1, detail: 'Skipped: $e');
    }

    // Step 2 — Update
    _setRunning(2);
    if (_isPathActivated && _repoRoot != null) {
      // Git pull if path activated
      final pullResult = await Process.run('git', ['pull', '--ff-only'],
          workingDirectory: _repoRoot);
      if (pullResult.exitCode == 0) {
        _setDone(2, detail: 'Git pulled in $_repoRoot');
      } else {
        _setFailed(2, 'Git pull failed: ${pullResult.stderr}');
      }
    } else {
      // Global activate if hosted
      final activateResult = await Process.run(
          'dart', ['pub', 'global', 'activate', 'nitrogen_cli']);
      if (activateResult.exitCode == 0) {
        _setDone(2,
            detail: 'Activated v${_latestVersion ?? "latest"} from pub.dev');
      } else {
        _setFailed(2, 'Activation failed: ${activateResult.stderr}');
      }
    }

    component.result.success = !_failed;
    setState(() => _finished = true);
  }

  bool _handleKey(KeyboardEvent e) {
    if (!_finished) return false;
    if (component.onExit != null) {
      component.onExit!();
      return true;
    }
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
          Padding(
            padding: const EdgeInsets.only(top: 1, left: 1, right: 1),
            child: Container(
              decoration:
                  BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Text(' nitrogen update ',
                    style: TextStyle(
                        color: Colors.cyan, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
          const Padding(padding: EdgeInsets.only(bottom: 1), child: Text('')),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                decoration: BoxDecoration(
                    border: BoxBorder.all(color: Colors.brightBlack)),
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
              padding: const EdgeInsets.all(1),
              child: Column(
                children: [
                  _failed
                      ? const Text('✘ Update failed',
                          style: TextStyle(
                              color: Colors.red, fontWeight: FontWeight.bold))
                      : const Text('✨ nitrogen is up to date!',
                          style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold)),
                  const Text('Press any key to exit',
                      style: TextStyle(
                          color: Colors.gray, fontWeight: FontWeight.dim)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── UpdateCommand ─────────────────────────────────────────────────────────────

class UpdateCommand extends Command {
  @override
  final String name = 'update';

  @override
  final String description =
      'Checks for updates and refreshes the Nitrogen CLI.';

  @override
  Future<void> run() async {
    final result = UpdateResult();
    await runApp(UpdateView(result: result));
    if (result.success) {
      stdout.writeln('  \x1B[1;32m✨ nitrogen updated\x1B[0m');
    } else {
      stderr.writeln('  \x1B[1;31m✘  Update failed\x1B[0m');
      exit(1);
    }
  }
}
