import 'package:flutter/material.dart';
import 'package:my_camera/my_camera.dart';
import 'common.dart';

class BasicView extends StatefulWidget {
  final int refreshCount;
  const BasicView({super.key, required this.refreshCount});

  @override
  State<BasicView> createState() => _BasicViewState();
}

class _BasicViewState extends State<BasicView> {
  double _result = 0;
  String _greeting = 'Loading...';
  List<CameraDevice> _devices = [];
  bool _isLoadingDevices = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void didUpdateWidget(BasicView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshCount != widget.refreshCount) {
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    if (mounted) {
      setState(() {
        _isLoadingDevices = true;
        _greeting = 'Refreshing...';
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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('Basic Bridges'),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoRow(label: 'Sync Add (10 + 20)', value: '$_result'),
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

          const SectionTitle('Binary Bridge (@HybridRecord)'),
          if (_isLoadingDevices)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(20.0),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_devices.isEmpty)
            const InfoCard(
              child: Text(
                'No devices found.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            ..._devices.map(_deviceCard),
        ],
      ),
    );
  }

  Widget _deviceCard(CameraDevice d) => ListTile(
    leading: Icon(d.isFrontFacing ? Icons.camera_front : Icons.camera_rear),
    title: Text(d.name),
    subtitle: Text('id: ${d.id}'),
  );
}
