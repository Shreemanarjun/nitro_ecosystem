import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:my_camera/my_camera.dart';
import 'common.dart';

class PerformanceView extends StatelessWidget {
  final int refreshCount;
  const PerformanceView({super.key, required this.refreshCount});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('Live Zero-Copy Streams'),
          Row(
            children: [
              Expanded(
                child: InfoCard(
                  child: Column(
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
                        key: ValueKey('frames_$refreshCount'),
                        stream: MyCamera.instance.frames,
                        builder: (ctx, snap) {
                          if (snap.hasError) return _streamError(snap.error!);
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
                  key: ValueKey('colored_frames_$refreshCount'),
                  stream: MyCamera.instance.coloredFrames,
                  builder: (ctx, snap) {
                    final frame = snap.data;
                    final color = (frame != null && frame.data.length >= 4)
                        ? Color.fromARGB(
                            255,
                            frame.data[2], // R (Swift sent R)
                            frame.data[1], // G (Swift sent G)
                            frame.data[0], // B (Swift sent B)
                          ).withValues(alpha: 0.2)
                        : null;

                    return InfoCard(
                      color: color,
                      child: Column(
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

          const SectionTitle('Native Verification (Errors & Zero-Copy)'),
          InfoCard(child: _VerificationPanel()),
        ],
      ),
    );
  }

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
}

class _VerificationPanel extends StatefulWidget {
  @override
  State<_VerificationPanel> createState() => _VerificationPanelState();
}

class _VerificationPanelState extends State<_VerificationPanel> {
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
          contentPadding: EdgeInsets.zero,
          title: const Text('Typed Error', style: TextStyle(fontSize: 14)),
          subtitle: Text(_errorMsg, style: const TextStyle(fontSize: 11)),
          trailing: ElevatedButton(
            onPressed: _testError,
            child: const Text('Test'),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Float32 Zero-Copy',
            style: TextStyle(fontSize: 14),
          ),
          subtitle: Text(_floatResult, style: const TextStyle(fontSize: 11)),
          trailing: ElevatedButton(
            onPressed: _testFloats,
            child: const Text('Test'),
          ),
        ),
      ],
    );
  }
}
