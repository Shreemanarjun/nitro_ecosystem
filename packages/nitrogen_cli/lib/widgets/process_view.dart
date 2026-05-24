import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_unrouter/nocterm_unrouter.dart';
import '../routes.dart';
import '../ui.dart';

// Braille-dots spinner — 10 frames at 100 ms each gives a smooth crawl.
const _spinnerFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

class ProcessView extends StatefulComponent {
  const ProcessView({
    required this.title,
    required this.executable,
    required this.args,
    this.workingDirectory,

    /// When true the underlying process is sent SIGTERM on dispose (e.g. watch
    /// mode so the process doesn't keep running after the user navigates back).
    this.killOnDispose = false,

    /// When true the view shows "Watching…" instead of "Running…", and treats
    /// SIGTERM / SIGKILL exit codes (143, 137) as normal "Stopped" rather than
    /// "Failed".
    this.watchMode = false,
    super.key,
  });

  final String title;
  final String executable;
  final List<String> args;
  final String? workingDirectory;
  final bool killOnDispose;
  final bool watchMode;

  @override
  State<ProcessView> createState() => _ProcessViewState();
}

class _ProcessViewState extends State<ProcessView> {
  final List<String> _logs = [];
  final ScrollController _scroll = ScrollController();
  bool _running = false;
  bool _done = false;
  int? _exitCode;
  bool _successPulse = false;
  Timer? _pulseTimer;
  Timer? _spinnerTimer;
  int _spinnerFrame = 0;
  DateTime? _startTime;
  Duration _elapsed = Duration.zero;
  Process? _process;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, _start);
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _spinnerTimer?.cancel();
    if (component.killOnDispose && _process != null) {
      // Terminate the process group so child processes (e.g. build_runner) are
      // also killed. Fall back to plain kill() if ProcessSignal is unavailable.
      try {
        _process!.kill(ProcessSignal.sigterm);
      } catch (_) {
        _process!.kill();
      }
    }
    super.dispose();
  }

  void _start() async {
    _startTime = DateTime.now();
    setState(() {
      _running = true;
      _logs.add('[Info] Starting ${component.executable} ${component.args.join(' ')}...');
    });

    // Spinner ticks every 100 ms — advances frame + refreshes elapsed time.
    _spinnerTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted && _running) {
        setState(() {
          _spinnerFrame = (_spinnerFrame + 1) % _spinnerFrames.length;
          _elapsed = DateTime.now().difference(_startTime!);
        });
      }
    });

    try {
      final process = await Process.start(
        component.executable,
        component.args,
        workingDirectory: component.workingDirectory,
      );
      _process = process;

      process.stdout.transform(const Utf8Decoder()).transform(const LineSplitter()).listen((line) {
        if (!mounted) return;
        setState(() {
          _logs.add(line);
          _scroll.scrollToEnd();
        });
      });

      process.stderr.transform(const Utf8Decoder()).transform(const LineSplitter()).listen((line) {
        if (!mounted) return;
        setState(() {
          _logs.add('[Error] $line');
          _scroll.scrollToEnd();
        });
      });

      final code = await process.exitCode;
      if (!mounted) return;

      final bool watchStopped = component.watchMode && (code == 143 || code == 137 || code == -1);
      final int effectiveCode = watchStopped ? 0 : code;

      _spinnerTimer?.cancel();
      _spinnerTimer = null;

      setState(() {
        _running = false;
        _done = true;
        _exitCode = effectiveCode;
        _elapsed = DateTime.now().difference(_startTime!);
        if (watchStopped) {
          _logs.add('[Info] Watcher stopped.');
        } else {
          _logs.add('[Info] Process exited with code $code');
        }
        if (effectiveCode == 0 && !component.watchMode) {
          _pulseTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
            if (mounted) setState(() => _successPulse = !_successPulse);
          });
        }
      });
    } catch (e) {
      _spinnerTimer?.cancel();
      _spinnerTimer = null;
      if (!mounted) return;
      setState(() {
        _running = false;
        _done = true;
        _elapsed = DateTime.now().difference(_startTime ?? DateTime.now());
        _logs.add('[Fatal] Failed to start process: $e');
      });
    }
  }

  /// Elapsed time formatted as `4.2s` or `1m 03s`.
  String _formatElapsed(Duration d) {
    if (d.inMinutes > 0) {
      final m = d.inMinutes;
      final s = d.inSeconds % 60;
      return '${m}m ${s.toString().padLeft(2, '0')}s';
    }
    final secs = d.inMilliseconds / 1000.0;
    return '${secs.toStringAsFixed(1)}s';
  }

  /// Colour-codes a log line for easier scanning.
  TextStyle _styleForLine(String line) {
    if (line.startsWith('[Fatal]') || line.startsWith('[SEVERE]')) {
      return const TextStyle(color: Colors.red, fontWeight: FontWeight.bold);
    }
    if (line.startsWith('[Error]') || line.contains('[ERROR]') || line.contains('ERROR')) {
      return const TextStyle(color: Colors.red);
    }
    if (line.startsWith('[Warning]') || line.contains('[WARNING]') || line.contains('WARNING')) {
      return const TextStyle(color: Colors.yellow);
    }
    if (line.startsWith('[Info]')) {
      return const TextStyle(color: Colors.gray, fontWeight: FontWeight.dim);
    }
    if (line.startsWith('[FINE]') || line.startsWith('[FINER]')) {
      return const TextStyle(color: Colors.brightBlack);
    }
    return const TextStyle(color: Colors.white);
  }

  @override
  Component build(BuildContext context) {
    final spinnerChar = _spinnerFrames[_spinnerFrame % _spinnerFrames.length];
    final elapsedStr = _formatElapsed(_elapsed);
    final lineCount = _logs.length;

    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape || event.logicalKey == LogicalKey.arrowLeft) {
          context.unrouterAs<NitroRoute>().go(const RootRoute());
          return true;
        }
        if (event.character == 'c' || event.character == 'C') {
          copyToClipboard(_logs.join('\n'));
          return true;
        }
        return false;
      },
      child: Column(
        children: [
          // ── Title bar ─────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(top: 1, left: 1, right: 1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: BoxBorder.all(color: _successPulse ? Colors.green : Colors.cyan),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        ' ${component.title} ',
                        style: TextStyle(
                          color: _successPulse ? Colors.green : Colors.magenta,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                // Line-count badge
                Padding(
                  padding: const EdgeInsets.only(left: 1),
                  child: Text(
                    '$lineCount lines',
                    style: const TextStyle(color: Colors.brightBlack, fontWeight: FontWeight.dim),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 1),

          // ── Success banner (stable height, prevents layout jumps) ─────────
          if (_done && _exitCode == 0 && !component.watchMode)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                '  ✨ SUCCESS — $_elapsedStr  ✨  ',
                style: TextStyle(
                  color: _successPulse ? Colors.green : Colors.brightGreen,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

          // ── Log viewport ─────────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                decoration: BoxDecoration(
                  border: BoxBorder.all(
                    color: (_done && _exitCode != null && _exitCode != 0) ? Colors.red : (_running ? Colors.cyan : Colors.brightBlack),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: ListView(
                    controller: _scroll,
                    children: _logs.map((l) => Text(l, style: _styleForLine(l))).toList(),
                  ),
                ),
              ),
            ),
          ),

          // ── Status bar ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(1),
            child: Row(
              children: [
                // Spinner + status
                if (_running) ...[
                  Text(
                    '$spinnerChar ',
                    style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    component.watchMode ? 'Watching…' : 'Running…',
                    style: const TextStyle(color: Colors.yellow),
                  ),
                  const SizedBox(width: 1),
                  Text(
                    elapsedStr,
                    style: const TextStyle(color: Colors.brightBlack),
                  ),
                ],
                if (_done)
                  Text(
                    _exitCode == 0 ? (component.watchMode ? '■ Stopped' : '✔ Done in $elapsedStr') : '✘ Failed (code $_exitCode) — $elapsedStr',
                    style: TextStyle(
                      color: _exitCode == 0 ? Colors.green : Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                Expanded(child: const SizedBox()),
                HoverButton(
                  label: '‹ Back',
                  onTap: () => context.unrouterAs<NitroRoute>().go(const RootRoute()),
                  color: Colors.cyan,
                ),
                const SizedBox(width: 2),
                CopyButton(getData: () => _logs.join('\n')),
                const SizedBox(width: 2),
                const Text(
                  'ESC back • c copy',
                  style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Convenience getter so the build method can use `$_elapsedStr` directly.
  String get _elapsedStr => _formatElapsed(_elapsed);
}
