import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm_unrouter/nocterm_unrouter.dart';
import '../routes.dart';
import '../ui.dart';

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
  Process? _process;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, _start);
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
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
    setState(() {
      _running = true;
      _logs.add('[Info] Starting ${component.executable} ${component.args.join(' ')}...');
    });

    try {
      final process = await Process.start(
        component.executable,
        component.args,
        workingDirectory: component.workingDirectory,
      );
      _process = process;

      // Handle stdout
      process.stdout.transform(const Utf8Decoder()).transform(const LineSplitter()).listen((line) {
        if (!mounted) return;
        setState(() {
          _logs.add(line);
          _scroll.scrollToEnd();
        });
      });

      // Handle stderr
      process.stderr.transform(const Utf8Decoder()).transform(const LineSplitter()).listen((line) {
        if (!mounted) return;
        setState(() {
          _logs.add('[Error] $line');
          _scroll.scrollToEnd();
        });
      });

      final code = await process.exitCode;
      if (!mounted) return;
      // In watch mode SIGTERM (143) / SIGKILL (137) are expected when the user
      // navigates away — treat them as a clean stop.
      final bool watchStopped = component.watchMode && (code == 143 || code == 137 || code == -1);
      final int effectiveCode = watchStopped ? 0 : code;
      setState(() {
        _running = false;
        _done = true;
        _exitCode = effectiveCode;
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
      if (!mounted) return;
      setState(() {
        _running = false;
        _done = true;
        _logs.add('[Fatal] Failed to start process: $e');
      });
    }
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.escape || event.logicalKey == LogicalKey.arrowLeft) {
          context.unrouterAs<NitroRoute>().go(const RootRoute());
          return true;
        }
        // 'c' / 'C' — copy all logs to clipboard
        if (event.character == 'c' || event.character == 'C') {
          copyToClipboard(_logs.join('\n'));
          return true;
        }
        return false;
      },
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, left: 1, right: 1),
            child: Container(
              decoration: BoxDecoration(border: BoxBorder.all(color: _successPulse ? Colors.green : Colors.cyan)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  ' ${component.title} ',
                  style: TextStyle(color: _successPulse ? Colors.green : Colors.magenta, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          const SizedBox(height: 1),
          // Keep the success layout stable even when pulsing to avoid flickering/jumps
          if (_done && _exitCode == 0 && !component.watchMode)
            Container(
              padding: const EdgeInsets.all(1),
              child: Text(
                '  ✨ SUCCESS  ✨  ',
                style: TextStyle(
                  color: _successPulse ? Colors.green : Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                decoration: BoxDecoration(
                  border: BoxBorder.all(
                    color: (_done && _exitCode != null && _exitCode != 0) ? Colors.red : Colors.brightBlack,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: ListView(
                    controller: _scroll,
                    children: _logs.map((l) => Text(l, style: const TextStyle(color: Colors.white))).toList(),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_running)
                  Text(
                    component.watchMode ? '👁 Watching...' : '⚙ Running...',
                    style: const TextStyle(color: Colors.yellow),
                  ),
                if (_done)
                  Text(
                    _exitCode == 0
                        ? (component.watchMode ? '■ Stopped' : '✔ Success')
                        : '✘ Failed (Code $_exitCode)',
                    style: TextStyle(color: _exitCode == 0 ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                  ),
                const SizedBox(width: 2),
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
}
