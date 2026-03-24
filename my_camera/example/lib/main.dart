import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:my_camera/my_camera.dart';
import 'package:nitro/nitro.dart';

/// Configure the Nitro runtime BEFORE any plugin is accessed.
///
/// In production builds all logging is disabled by default.
/// Toggle the debug panel inside the app to enable it at runtime.
Future<void> _configureNitro() async {
  if (kDebugMode) {
    // Show warnings + slow-call alerts in debug builds.
    // Tap the ⚙ icon in the app to go verbose or fully disable at runtime.
    NitroConfig.instance.enable(slowCallThresholdMs: 16);
  } else {
    // Production: zero logging overhead.
    NitroConfig.instance.disable();
  }
  // Pre-warm 2 persistent worker isolates — eliminates Isolate.spawn latency.
  await NitroRuntime.init(isolatePoolSize: 2);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureNitro();
  runApp(const MyApp());
}

// ── App ─────────────────────────────────────────────────────────────────────

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nitro Ecosystem',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      home: const _HomePage(),
    );
  }
}

// ── Home ─────────────────────────────────────────────────────────────────────

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  double _result = 0;
  String _greeting = 'Loading...';
  List<CameraDevice> _devices = [];
  bool _isLoadingDevices = true;
  int _refreshCount = 0;

  // ── Debug panel state (mirrors NitroConfig live) ──────────────────────────
  bool _debugPanelOpen = false;
  NitroLogLevel _logLevel = NitroConfig.instance.logLevel;
  int _poolSize = NitroConfig.instance.isolatePoolSize;
  int _slowThresholdMs =
      (NitroConfig.instance.slowCallThresholdUs / 1000).round();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    if (mounted) {
      setState(() {
        _isLoadingDevices = true;
        _greeting = 'Refreshing...';
        _refreshCount++;
      });
    }

    try {
      final result = MyCamera.instance.add(10, 20);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      debugPrint('[my_camera] add failed: $e');
    }

    MyCamera.instance.getGreeting('Nitro 0.2.2').then((val) {
      if (mounted) setState(() => _greeting = val);
    }).catchError((Object e) {
      if (mounted) setState(() => _greeting = 'Error: $e');
    });

    try {
      final devices = await MyCamera.instance.getAvailableDevices();
      if (mounted) {
        setState(() {
          _devices = devices;
          _isLoadingDevices = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingDevices = false);
      debugPrint('[my_camera] getAvailableDevices failed: $e');
    }
  }

  // ── Debug config helpers ──────────────────────────────────────────────────

  void _applyLogLevel(NitroLogLevel level) {
    NitroConfig.instance.logLevel = level;
    setState(() => _logLevel = level);
  }

  void _applyPoolSize(int size) async {
    // Resize pool — requires dispose+reinit.
    await NitroRuntime.dispose();
    NitroConfig.instance.isolatePoolSize = size;
    await NitroRuntime.init(isolatePoolSize: size);
    if (mounted) setState(() => _poolSize = size);
  }

  void _applySlowThreshold(int ms) {
    NitroConfig.instance.slowCallThresholdUs = ms * 1000;
    setState(() => _slowThresholdMs = ms);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nitro Ecosystem 🚀'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Refresh All',
            icon: const Icon(Icons.refresh),
            onPressed: _loadAll,
          ),
          IconButton(
            tooltip: 'Nitro Debug Settings',
            icon: Icon(
              Icons.tune,
              color: _logLevel != NitroLogLevel.none
                  ? Colors.amberAccent
                  : Colors.grey,
            ),
            onPressed: () => setState(() => _debugPanelOpen = !_debugPanelOpen),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Debug panel ────────────────────────────────────────────────
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: _debugPanelOpen ? _buildDebugPanel() : const SizedBox.shrink(),
            ),

            // ── Basic bridges ──────────────────────────────────────────────
            _sectionTitle('Basic Bridges'),
            _card(Column(children: [
              _infoRow('Sync Add (10 + 20)', '$_result'),
              const Divider(),
              _infoRow('Async Greeting', _greeting),
            ])),
            const SizedBox(height: 20),

            // ── Binary bridge ──────────────────────────────────────────────
            _sectionTitle('Binary Bridge (@HybridRecord)'),
            if (_isLoadingDevices)
              const Center(child: CircularProgressIndicator())
            else if (_devices.isEmpty)
              _card(const Text(
                'No devices found — native library may not be linked.',
                style: TextStyle(color: Colors.grey),
              ))
            else
              ..._devices.map(_deviceCard),
            const SizedBox(height: 20),

            // ── frames stream ──────────────────────────────────────────────
            _sectionTitle('Live Zero-Copy Stream (frames)'),
            _card(StreamBuilder<CameraFrame>(
              key: ValueKey('frames_$_refreshCount'),
              // debugLabel wires into NitroRuntime.openStream logging
              stream: MyCamera.instance.frames,
              builder: (ctx, snap) {
                if (snap.hasError) {
                  return _streamError(snap.error!);
                }
                if (!snap.hasData) return _waiting('frames');
                final f = snap.data!;
                return _frameInfo(f);
              },
            )),
            const SizedBox(height: 20),

            // ── coloredFrames stream ───────────────────────────────────────
            _sectionTitle('Colored Zero-Copy Stream (coloredFrames)'),
            _card(StreamBuilder<CameraFrame>(
              key: ValueKey('colored_$_refreshCount'),
              stream: MyCamera.instance.coloredFrames,
              builder: (ctx, snap) {
                if (snap.hasError) return _streamError(snap.error!);
                if (!snap.hasData) return _waiting('coloredFrames');
                final f = snap.data!;
                final r = f.data.isNotEmpty ? f.data[0] : 128;
                final g = f.data.length > 1 ? f.data[1] : 128;
                final b = f.data.length > 2 ? f.data[2] : 128;
                final color = Color.fromARGB(255, r, g, b);
                return Column(children: [
                  Text(
                    '${f.width} × ${f.height}',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    height: 80,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                            color: color.withAlpha(160),
                            blurRadius: 16,
                            spreadRadius: 2),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        'ZERO-COPY BUFFER',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4,
                          color: Colors.white,
                          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                        ),
                      ),
                    ),
                  ),
                ]);
              },
            )),

            const SizedBox(height: 40),
            Center(
              child: Text(
                'nitro 0.2.2 • pool=$_poolSize workers • ${_logLevel.name} log',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

  // ── Debug panel ───────────────────────────────────────────────────────────

  Widget _buildDebugPanel() {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.amberAccent.withAlpha(120)),
        borderRadius: BorderRadius.circular(14),
        color: Colors.amber.withAlpha(15),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.tune, color: Colors.amberAccent, size: 18),
            const SizedBox(width: 8),
            const Text(
              'NitroConfig — Runtime Settings',
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.amberAccent),
            ),
            const Spacer(),
            // Quick enable / disable toggle
            Row(children: [
              Text(
                _logLevel == NitroLogLevel.none ? 'disabled' : 'enabled',
                style: TextStyle(
                  fontSize: 12,
                  color: _logLevel == NitroLogLevel.none
                      ? Colors.grey
                      : Colors.greenAccent,
                ),
              ),
              Switch(
                value: _logLevel != NitroLogLevel.none,
                activeThumbColor: Colors.greenAccent,
                onChanged: (on) {
                  if (on) {
                    NitroConfig.instance.enable(slowCallThresholdMs: 16);
                    setState(() {
                      _logLevel = NitroConfig.instance.logLevel;
                      _slowThresholdMs = 16;
                    });
                  } else {
                    NitroConfig.instance.disable();
                    setState(() {
                      _logLevel = NitroLogLevel.none;
                      _slowThresholdMs = 0;
                    });
                  }
                },
              ),
            ]),
          ]),
          const Divider(),

          // ── Log level ──────────────────────────────────────────────────
          const Text('Log level', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 6),
          SegmentedButton<NitroLogLevel>(
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: Colors.deepPurple.withAlpha(180),
            ),
            segments: [
              ButtonSegment(value: NitroLogLevel.none, label: Text('none')),
              ButtonSegment(value: NitroLogLevel.error, label: Text('error')),
              ButtonSegment(
                  value: NitroLogLevel.warning, label: Text('warning')),
              ButtonSegment(
                  value: NitroLogLevel.verbose, label: Text('verbose')),
            ],
            selected: {_logLevel},
            onSelectionChanged: (s) => _applyLogLevel(s.first),
          ),
          const SizedBox(height: 14),

          // ── Slow-call threshold ────────────────────────────────────────
          Row(children: [
            const Text('Slow-call warn > ',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
            Text(
              _slowThresholdMs == 0 ? 'disabled' : '$_slowThresholdMs ms',
              style: TextStyle(
                color:
                    _slowThresholdMs == 0 ? Colors.grey : Colors.amberAccent,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ]),
          Slider(
            min: 0,
            max: 100,
            divisions: 20,
            value: _slowThresholdMs.toDouble(),
            onChanged: (v) => _applySlowThreshold(v.round()),
            activeColor: Colors.amberAccent,
          ),

          // ── Isolate pool size ──────────────────────────────────────────
          Row(children: [
            const Text('Isolate pool size  ',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
            Text(
              _poolSize == 0 ? '0 (Isolate.run per call)' : '$_poolSize workers',
              style: TextStyle(
                color: _poolSize == 0 ? Colors.grey : Colors.greenAccent,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ]),
          Slider(
            min: 0,
            max: 8,
            divisions: 8,
            value: _poolSize.toDouble(),
            onChanged: (v) => _applyPoolSize(v.round()),
            activeColor: Colors.greenAccent,
          ),

          const Text(
            '⚠️  Changing pool size disposes & reinitialises the runtime.',
            style: TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(t,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurpleAccent)),
      );

  Widget _card(Widget child) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      );

  Widget _infoRow(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      );

  Widget _frameInfo(CameraFrame f) => Column(children: [
        Text('${f.width} × ${f.height}',
            style:
                const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        Text(
            'Stride: ${f.stride} B  |  ts: ${(f.timestampNs / 1e9).toStringAsFixed(3)} s'),
        const SizedBox(height: 8),
        LinearProgressIndicator(
            value: (f.timestampNs % 1000000000) / 1000000000),
      ]);

  Widget _streamError(Object err) => Row(children: [
        const Icon(Icons.error_outline, color: Colors.redAccent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Stream error: $err',
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      ]);

  Widget _waiting(String label) => Row(children: [
        const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text('Waiting for $label…',
            style: const TextStyle(color: Colors.grey)),
      ]);

  Widget _deviceCard(CameraDevice d) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          leading:
              Icon(d.isFrontFacing ? Icons.camera_front : Icons.camera_rear),
          title: Text(d.name),
          subtitle: Text('${d.resolutions.length} resolutions  •  id: ${d.id}'),
          trailing: const Icon(Icons.bolt, color: Colors.amber),
        ),
      );
}
