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
    super.key,
  });

  final String title;
  final String executable;
  final List<String> args;
  final String? workingDirectory;

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

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, _start);
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
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
      setState(() {
        _running = false;
        _done = true;
        _exitCode = code;
        _logs.add('[Info] Process exited with code $code');
        if (code == 0) {
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
                child: Text(' ${component.title} ', style: TextStyle(color: _successPulse ? Colors.green : Colors.magenta, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
          const SizedBox(height: 1),
          // Keep the success layout stable even when pulsing to avoid flickering/jumps
          if (_done && _exitCode == 0)
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
                decoration: BoxDecoration(border: BoxBorder.all(color: (_done && _exitCode != 0 && _exitCode != null) ? Colors.red : Colors.brightBlack)),
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
                if (_running) const Text('⚙ Running...', style: TextStyle(color: Colors.yellow)),
                if (_done)
                  Text(
                    _exitCode == 0 ? '✔ Success' : '✘ Failed (Code $_exitCode)',
                    style: TextStyle(color: _exitCode == 0 ? Colors.green : Colors.red, fontWeight: FontWeight.bold),
                  ),
                const SizedBox(width: 2),
                HoverButton(
                  label: '‹ Back',
                  onTap: () => context.unrouterAs<NitroRoute>().go(const RootRoute()),
                  color: Colors.cyan,
                ),
                const SizedBox(width: 2),
                const Text('ESC back', style: TextStyle(color: Colors.gray, fontWeight: FontWeight.dim)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
