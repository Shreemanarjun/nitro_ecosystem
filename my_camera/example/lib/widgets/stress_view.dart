import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:my_camera/my_camera.dart';
import 'common.dart';

class StressView extends StatefulWidget {
  const StressView({super.key});

  @override
  State<StressView> createState() => _StressViewState();
}

class _StressViewState extends State<StressView> {
  bool _burstRunning = false;
  int _burstCompleted = 0;
  int _burstFailed = 0;
  String _burstDuration = '0ms';

  bool _concurrencyRunning = false;
  int _concurrencyTotal = 0;
  int _concurrencyFailed = 0;

  bool _bufferStressRunning = false;
  String _bufferStatus = 'Idle';

  Timer? _concurrencyTimer;

  @override
  void dispose() {
    _concurrencyTimer?.cancel();
    super.dispose();
  }

  Future<void> _runBurstTest() async {
    if (_burstRunning) return;
    setState(() {
      _burstRunning = true;
      _burstCompleted = 0;
      _burstFailed = 0;
      _burstDuration = 'Starting...';
    });

    final sw = Stopwatch()..start();
    const count = 50;

    final futures = List.generate(count, (i) {
      return MyCamera.instance
          .getGreeting('Burst #$i')
          .then((_) {
            if (mounted) setState(() => _burstCompleted++);
          })
          .catchError((_) {
            if (mounted) setState(() => _burstFailed++);
          });
    });

    await Future.wait(futures);
    sw.stop();

    if (mounted) {
      setState(() {
        _burstRunning = false;
        _burstDuration = '${sw.elapsedMilliseconds}ms';
      });
    }
  }

  void _toggleConcurrencyTest() {
    if (_concurrencyRunning) {
      _concurrencyTimer?.cancel();
      setState(() => _concurrencyRunning = false);
    } else {
      setState(() {
        _concurrencyRunning = true;
        _concurrencyTotal = 0;
        _concurrencyFailed = 0;
      });

      _concurrencyTimer = Timer.periodic(const Duration(milliseconds: 50), (t) {
        if (!_concurrencyRunning) return;
        _concurrencyTotal++;
        MyCamera.instance
            .getAvailableDevices()
            .then((_) {
              if (mounted && _concurrencyRunning) setState(() {});
            })
            .catchError((_) {
              if (mounted && _concurrencyRunning)
                setState(() => _concurrencyFailed++);
            });
      });
    }
  }

  Future<void> _runBufferStress() async {
    if (_bufferStressRunning) return;
    setState(() {
      _bufferStressRunning = true;
      _bufferStatus = 'Allocating...';
    });

    try {
      final sizes = [1, 5, 10]; // 1MB, 5MB, 10MB
      for (final mb in sizes) {
        if (!mounted) break;
        setState(() => _bufferStatus = 'Processing ${mb}MB...');

        final length = (1024 * 1024 / 4).floor() * mb;
        final data = Float32List(length);
        for (int i = 0; i < length; i++) {
          data[i] = i.toDouble();
        }

        final result = VerificationModule.instance.processFloats(data);
        if (result.data.length != length) throw Exception('Length mismatch');
      }
      if (mounted) setState(() => _bufferStatus = 'Completed ✅');
    } catch (e) {
      if (mounted) setState(() => _bufferStatus = 'Failed: $e ❌');
    } finally {
      if (mounted) setState(() => _bufferStressRunning = false);
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
          const SectionTitle('🚀 Stress Test Suite'),
          InfoCard(
            child: Column(
              children: [
                _StressItem(
                  icon: Icons.bolt,
                  title: 'Async Burst (50 calls)',
                  subtitle:
                      '$_burstCompleted success, $_burstFailed failed in $_burstDuration',
                  onPressed: _runBurstTest,
                  running: _burstRunning,
                ),
                const Divider(height: 1),
                _StressItem(
                  icon: Icons.repeat,
                  title: 'Continuous Concurrency',
                  subtitle:
                      '$_concurrencyTotal calls fired, $_concurrencyFailed failed',
                  onPressed: _toggleConcurrencyTest,
                  running: _concurrencyRunning,
                  toggle: true,
                ),
                const Divider(height: 1),
                _StressItem(
                  icon: Icons.memory,
                  title: 'Zero-Copy Buffer Pressure',
                  subtitle: _bufferStatus,
                  onPressed: _runBufferStress,
                  running: _bufferStressRunning,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StressItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onPressed;
  final bool running;
  final bool toggle;

  const _StressItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
    this.running = false,
    this.toggle = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: running ? Colors.amberAccent : Colors.grey),
      title: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      trailing: ElevatedButton(
        style: ElevatedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: onPressed,
        child: Text(
          toggle ? (running ? 'Stop' : 'Start') : (running ? '...' : 'Run'),
        ),
      ),
    );
  }
}
