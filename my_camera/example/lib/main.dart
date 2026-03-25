import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:my_camera/my_camera.dart';
import 'package:nitro/nitro.dart';

/// Configure the Nitro runtime BEFORE any plugin is accessed.
Future<void> _configureNitro() async {
  if (kDebugMode) {
    NitroConfig.instance.enable(slowCallThresholdMs: 16);
  } else {
    NitroConfig.instance.disable();
  }
  await NitroRuntime.init(isolatePoolSize: 2);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureNitro();
  runApp(const MyApp());
}

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

  bool _debugPanelOpen = false;
  int _poolSize = NitroConfig.instance.isolatePoolSize;

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

    MyCamera.instance
        .getGreeting('Nitro 0.2.2')
        .then((val) {
          if (mounted) setState(() => _greeting = val);
        })
        .catchError((Object e) {
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

  void _applyPoolSize(int size) async {
    await NitroRuntime.dispose();
    NitroConfig.instance.isolatePoolSize = size;
    await NitroRuntime.init(isolatePoolSize: size);
    if (mounted) setState(() => _poolSize = size);
  }

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
              color: NitroConfig.instance.logLevel != NitroLogLevel.none
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
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: _debugPanelOpen
                    ? _buildDebugPanel()
                    : const SizedBox.shrink(),
              ),

              _sectionTitle('Basic Bridges'),
              _card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoRow('Sync Add (10 + 20)', '$_result'),
                    const Divider(),
                    Row(
                      children: [
                        const Text(
                          'Async Greeting',
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                        const Spacer(),
                        if (_greeting == 'Refreshing...' ||
                            _greeting == 'Loading...')
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _greeting,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                        color: Colors.amberAccent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              _sectionTitle('Binary Bridge (@HybridRecord)'),
              if (_isLoadingDevices)
                const Center(child: CircularProgressIndicator())
              else if (_devices.isEmpty)
                _card(
                  const Text(
                    'No devices found.',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                ..._devices.map(_deviceCard),
              const SizedBox(height: 20),

              _sectionTitle('Live Zero-Copy Streams'),
              Row(
                children: [
                  Expanded(
                    child: _card(
                      Column(
                        children: [
                          const Text(
                            'GRAYSCALE',
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          StreamBuilder<CameraFrame>(
                            key: ValueKey('frames_$_refreshCount'),
                            stream: MyCamera.instance.frames,
                            builder: (ctx, snap) {
                              if (snap.hasError) {
                                return _streamError(snap.error!);
                              }
                              if (!snap.hasData) return _waiting('frames');
                              return _frameInfo(snap.data!);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: StreamBuilder<CameraFrame>(
                      key: ValueKey('colored_frames_$_refreshCount'),
                      stream: MyCamera.instance.coloredFrames,
                      builder: (ctx, snap) {
                        final frame = snap.data;
                        final color = (frame != null && frame.data.length >= 4)
                            ? Color.fromARGB(
                                255,
                                frame.data[2], // R (Swift sent R)
                                frame.data[1], // G (Swift sent G)
                                frame.data[0], // B (Swift sent B)
                              ).withOpacity(0.2)
                            : null;

                        return _card(
                          color: color,
                          Column(
                            children: [
                              const Text(
                                'COLORED',
                                style: TextStyle(
                                  color: Colors.amberAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (snap.hasError)
                                _streamError(snap.error!)
                              else if (frame == null)
                                _waiting('coloredFrames')
                              else
                                _frameInfo(frame),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              _sectionTitle('Native Verification (Errors & Zero-Copy)'),
              _card(_VerificationTestPanel()),
              const SizedBox(height: 40),

              Center(
                child: Text(
                  'nitro 0.2.2 • pool=$_poolSize workers',
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
          Row(
            children: [
              const Icon(Icons.tune, color: Colors.amberAccent, size: 18),
              const SizedBox(width: 8),
              const Text(
                'NitroConfig',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.amberAccent,
                ),
              ),
              const Spacer(),
              Switch(
                value: NitroConfig.instance.logLevel != NitroLogLevel.none,
                onChanged: (on) {
                  if (on) {
                    NitroConfig.instance.enable();
                  } else {
                    NitroConfig.instance.disable();
                  }
                  setState(() {});
                },
              ),
            ],
          ),
          const Divider(),
          Text(
            'Worker Isolate Pool Size: $_poolSize',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          Slider(
            min: 0,
            max: 8,
            divisions: 8,
            value: _poolSize.toDouble(),
            onChanged: (v) => _applyPoolSize(v.round()),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      t,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: Colors.deepPurpleAccent,
      ),
    ),
  );

  Widget _card(Widget child, {Color? color}) => Card(
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      color: color,
      padding: const EdgeInsets.all(14),
      child: child,
    ),
  );

  Widget _infoRow(String label, String value) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: const TextStyle(color: Colors.grey)),
      Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
    ],
  );

  Widget _frameInfo(CameraFrame f) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '${f.width} × ${f.height}',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      Text(
        '${(f.data.lengthInBytes / 1024 / 1024).toStringAsFixed(2)} MB • ${f.stride} B',
        style: const TextStyle(color: Colors.grey, fontSize: 11),
      ),
    ],
  );

  Widget _streamError(Object err) =>
      Text('Error: $err', style: const TextStyle(color: Colors.redAccent));

  Widget _waiting(String label) =>
      Text('Waiting for $label…', style: const TextStyle(color: Colors.grey));

  Widget _deviceCard(CameraDevice d) => ListTile(
    leading: Icon(d.isFrontFacing ? Icons.camera_front : Icons.camera_rear),
    title: Text(d.name),
    subtitle: Text('id: ${d.id}'),
  );
}

class _VerificationTestPanel extends StatefulWidget {
  @override
  State<_VerificationTestPanel> createState() => _VerificationTestPanelState();
}

class _VerificationTestPanelState extends State<_VerificationTestPanel> {
  String _errorMsg = 'N/A';
  String _floatResult = 'N/A';

  Future<void> _testError() async {
    try {
      VerificationModule.instance.throwError('Nitrogen Native Error Test');
      if (mounted) setState(() => _errorMsg = 'Failed: Error not thrown!');
    } catch (e) {
      if (mounted) setState(() => _errorMsg = e.toString());
    }
  }

  Future<void> _testFloats() async {
    try {
      final inputs = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);
      final result = VerificationModule.instance.processFloats(inputs);
      if (mounted) setState(() => _floatResult = '${result.data.toList()}');
    } catch (e) {
      if (mounted) setState(() => _floatResult = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: const Text('Typed Error'),
          subtitle: Text(_errorMsg),
          trailing: ElevatedButton(
            onPressed: _testError,
            child: const Text('Test'),
          ),
        ),
        ListTile(
          title: const Text('Float32 Zero-Copy'),
          subtitle: Text(_floatResult),
          trailing: ElevatedButton(
            onPressed: _testFloats,
            child: const Text('Test'),
          ),
        ),
      ],
    );
  }
}
