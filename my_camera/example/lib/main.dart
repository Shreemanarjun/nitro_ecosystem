import 'package:flutter/material.dart';
import 'package:my_camera/my_camera.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  double _result = 0;
  String _greeting = 'Loading...';
  List<CameraDevice> _devices = [];
  bool _isLoadingDevices = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    // Example synchronous call
    try {
      _result = MyCamera.instance.add(10, 20);
    } catch (e) {
      debugPrint('Native implementation may not be loaded yet: $e');
    }

    // Example asynchronous call (String bridge)
    MyCamera.instance.getGreeting('Nitro 0.2.0').then((val) {
      if (mounted) setState(() => _greeting = val);
    }).catchError((e) {
      if (mounted) setState(() => _greeting = 'Error: $e');
    });

    // Example rich record call (Binary bridge)
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
      debugPrint('Error fetching devices: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Nitro Ecosystem 🚀'),
          centerTitle: true,
          elevation: 2,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionTitle('Basic Bridges'),
              _buildCard(
                child: Column(
                  children: [
                    _buildInfoRow('Sync Add (10 + 20)', '$_result'),
                    const Divider(),
                    _buildInfoRow('Async Greeting', _greeting),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _buildSectionTitle('Binary Bridge (@HybridRecord)'),
              if (_isLoadingDevices)
                const Center(child: CircularProgressIndicator())
              else if (_devices.isEmpty)
                const Text('No devices found (or mock native not connected)')
              else
                ..._devices.map((d) => _buildDeviceCard(d)),
              const SizedBox(height: 24),
              _buildSectionTitle('Live Zero-Copy Stream'),
              _buildCard(
                child: StreamBuilder<CameraFrame>(
                  stream: MyCamera.instance.frames,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) return Text('Stream Error: ${snapshot.error}');
                    if (!snapshot.hasData) return const Text('Waiting for frames...');
                    final f = snapshot.data!;
                    return Column(
                      children: [
                        Text('${f.width} × ${f.height}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        Text('Stride: ${f.stride} B  |  ts: ${(f.timestampNs / 1e9).toStringAsFixed(3)} s'),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(value: (f.timestampNs % 1000000000) / 1000000000),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 24),
              _buildSectionTitle('Colored Zero-Copy Stream'),
              _buildCard(
                child: StreamBuilder<CameraFrame>(
                  stream: MyCamera.instance.coloredFrames,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) return Text('Stream Error: ${snapshot.error}');
                    if (!snapshot.hasData) return const Text('Waiting for colored frames...');
                    final f = snapshot.data!;
                    
                    // Note: Native side fills this buffer with changing colors.
                    // We can peek at the first pixel to show the current color.
                    // Android: RGBA, iOS: BGRA
                    final r = f.data[0];
                    final g = f.data[1];
                    final b = f.data[2];
                    
                    return Column(
                      children: [
                        Text('${f.width} × ${f.height}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        Text('Stride: ${f.stride} B'),
                        const SizedBox(height: 12),
                        Container(
                          height: 80,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            // Just a visual representation of the "colored" aspect
                            color: Color.fromARGB(255, r, g, b),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(color: Color.fromARGB(155, r, g, b), blurRadius: 15, spreadRadius: 2),
                            ],
                          ),
                          child: const Center(
                            child: Text(
                              'ZERO-COPY BUFFER',
                              style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 4, color: Colors.white, shadows: [Shadow(color: Colors.black, blurRadius: 4)]),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 40),
              const Center(
                child: Text(
                  'Nitro 0.2.0 • Binary Protocol • Zero-Copy',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurpleAccent)),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildDeviceCard(CameraDevice d) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(d.isFrontFacing ? Icons.camera_front : Icons.camera_rear),
        title: Text(d.name),
        subtitle: Text('${d.resolutions.length} resolutions available'),
        trailing: const Icon(Icons.bolt, color: Colors.amber), // Indicates binary speed
      ),
    );
  }
}
