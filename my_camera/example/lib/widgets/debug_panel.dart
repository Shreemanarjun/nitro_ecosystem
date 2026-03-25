import 'package:flutter/material.dart';
import 'package:nitro/nitro.dart';

class DebugPanel extends StatefulWidget {
  final int poolSize;
  final Function(int) onPoolSizeChanged;
  const DebugPanel({
    super.key,
    required this.poolSize,
    required this.onPoolSizeChanged,
  });

  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<DebugPanel> {
  @override
  Widget build(BuildContext context) {
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
            'Worker Isolate Pool Size: ${widget.poolSize}',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          Slider(
            min: 0,
            max: 8,
            divisions: 8,
            value: widget.poolSize.toDouble(),
            onChanged: (v) => widget.onPoolSizeChanged(v.round()),
          ),
        ],
      ),
    );
  }
}
