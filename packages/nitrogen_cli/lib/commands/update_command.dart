import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

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
              Text(icon, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              const Text(' '),
              Expanded(
                child: Text(
                  step.label,
                  style: TextStyle(
                    color: step.state == UpdateStepState.running ? Colors.cyan : null,
                    fontWeight:
                        step.state == UpdateStepState.running ? FontWeight.bold : null,
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

class UpdateResult {
  bool success = false;
  String? errorMessage;
  String? pullSummary;
}

// ── nocterm Update component ──────────────────────────────────────────────────

class UpdateView extends StatefulComponent {
  const UpdateView({
    required this.repoRoot,
    required this.result,
    this.onExit,
    super.key,
  });
  final String repoRoot;
  final UpdateResult result;
  final VoidCallback? onExit;

  @override
  State<UpdateView> createState() => _UpdateViewState();
}

class _UpdateViewState extends State<UpdateView> {
  late final List<UpdateStep> _steps = [
    UpdateStep('Checking current version'),
    UpdateStep('Pulling latest changes'),
    UpdateStep('Updating dependencies'),
  ];

  bool _finished = false;
  bool _failed = false;

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
        _steps[i].state = UpdateStepState.failed;
        _steps[i].detail = msg;
        _failed = true;
      });

  Future<void> _run() async {
    final repoRoot = component.repoRoot;
    final pkgDir = p.join(repoRoot, 'packages', 'nitrogen_cli');

    // Step 0 — current commit
    _setRunning(0);
    final logResult = await Process.run(
      'git', ['log', '--oneline', '-1'],
      workingDirectory: repoRoot,
    );
    final currentCommit = (logResult.stdout as String).trim();
    _setDone(0, detail: currentCommit.isEmpty ? 'unknown' : currentCommit);

    // Step 1 — git pull
    _setRunning(1);
    final pullResult = await Process.run(
      'git', ['pull', '--ff-only'],
      workingDirectory: repoRoot,
    );
    if (pullResult.exitCode != 0) {
      _setFailed(1, (pullResult.stderr as String).trim().split('\n').first);
      _fail('git pull failed');
      return;
    }
    final pullOut = (pullResult.stdout as String).trim();
    if (pullOut.contains('Already up to date')) {
      _setDone(1, detail: 'Already up to date');
      component.result.pullSummary = 'Already up to date';
    } else {
      final lines = pullOut.split('\n');
      final summary = lines.lastWhere((l) => l.trim().isNotEmpty,
          orElse: () => pullOut);
      _setDone(1, detail: summary);
      component.result.pullSummary = summary;
    }

    // Step 2 — dart pub get
    _setRunning(2);
    final pubResult = await Process.run(
      'dart', ['pub', 'get'],
      workingDirectory: pkgDir,
    );
    if (pubResult.exitCode != 0) {
      _setFailed(2, (pubResult.stderr as String).trim().split('\n').first);
      _fail('dart pub get failed');
      return;
    }
    _setDone(2, detail: 'Dependencies resolved');

    component.result.success = true;
    setState(() => _finished = true);
  }

  void _fail(String msg) {
    component.result.errorMessage = msg;
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
              decoration: BoxDecoration(border: BoxBorder.all(color: Colors.cyan)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  ' nitrogen update ',
                  style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          const Padding(padding: EdgeInsets.only(bottom: 1), child: Text('')),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
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
                      ? Text(
                          '✘  ${component.result.errorMessage ?? "Update failed"}',
                          style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                        )
                      : const Text(
                          '✨ nitrogen is up to date!',
                          style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
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
}

// ── UpdateCommand ─────────────────────────────────────────────────────────────

class UpdateCommand extends Command {
  @override
  final String name = 'update';

  @override
  final String description =
      'Self-updates the nitrogen CLI by pulling the latest git changes '
      'and refreshing dependencies.';

  @override
  Future<void> run() async {
    final scriptPath = Platform.script.toFilePath();
    final scriptDir = p.dirname(scriptPath);
    String? repoRoot = _findGitRoot(scriptDir);
    if (repoRoot == null) {
      stderr.writeln('Could not find git repository root from $scriptDir');
      exit(1);
    }

    final result = UpdateResult();
    await runApp(UpdateView(repoRoot: repoRoot, result: result));

    if (result.success) {
      stdout.writeln('');
      stdout.writeln('  \x1B[1;32m✨ nitrogen updated\x1B[0m'
          '${result.pullSummary != null && result.pullSummary != "Already up to date" ? " — ${result.pullSummary}" : ""}');
      stdout.writeln('');
    } else {
      stderr.writeln('  \x1B[1;31m✘  Update failed: ${result.errorMessage ?? ""}\x1B[0m');
      exit(1);
    }
  }

  String? _findGitRoot(String startDir) {
    var dir = Directory(startDir);
    while (true) {
      if (Directory(p.join(dir.path, '.git')).existsSync()) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }
}
