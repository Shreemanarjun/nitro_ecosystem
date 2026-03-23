import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'src/math.native.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nitro Modules Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
      ),
      home: const _DemoPage(),
    );
  }
}

class _DemoPage extends StatefulWidget {
  const _DemoPage();

  @override
  State<_DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<_DemoPage> {
  // ── sync results ──────────────────────────────────────────────────────────
  String _addResult = '—';
  String _scaleFactorResult = '—';
  String _precisionResult = '—';
  String _bufferResult = '—';

  // ── async ─────────────────────────────────────────────────────────────────
  Future<double>? _multiplyFuture;

  // ── stream ────────────────────────────────────────────────────────────────
  StreamSubscription<double>? _updatesSub;
  final List<String> _streamEvents = [];

  // ── property state ────────────────────────────────────────────────────────
  int _precision = 2;

  // ── error ─────────────────────────────────────────────────────────────────
  String? _initError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    try {
      final math = Math.instance;

      // Sync method
      _addResult = '${math.add(10.5, 20.5)}';

      // Async method
      _multiplyFuture = math.multiply(5.0, 4.0);

      // Read-only property
      _scaleFactorResult = '${math.scaleFactor}';

      // Read-write property — read initial value
      _precision = math.precision;
      _precisionResult = '$_precision';

      // Zero-copy buffer
      final buf = Uint8List.fromList(List.generate(64, (i) => i & 0xFF));
      math.processBuffer(buf);
      _bufferResult = 'Sent ${buf.lengthInBytes} bytes ✓';

      // Stream
      _updatesSub = math.updates.listen(
        (value) {
          if (mounted) {
            setState(() {
              if (_streamEvents.length >= 5) _streamEvents.removeAt(0);
              _streamEvents.add(value.toStringAsFixed(4));
            });
          }
        },
        onError: (_) {},
      );
    } catch (e) {
      _initError = e.toString();
    }
  }

  void _setPrecision(int value) {
    try {
      Math.instance.precision = value;
      setState(() {
        _precision = value;
        _precisionResult = '$value';
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _updatesSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Nitro Modules Demo')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                const Text('Failed to load native library',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(_initError!,
                    style: const TextStyle(
                        color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nitro Modules Demo'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Hero ───────────────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.bolt, size: 36, color: Colors.amber),
              const SizedBox(width: 8),
              Text(
                'Nitro Modules',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'One .native.dart spec → native FFI. No boilerplate.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // ── Sync method ────────────────────────────────────────────────────
          _FeatureCard(
            label: 'Sync method',
            code: 'Math.instance.add(10.5, 20.5)',
            result: _addResult,
          ),
          const SizedBox(height: 12),

          // ── Async method ───────────────────────────────────────────────────
          FutureBuilder<double>(
            future: _multiplyFuture,
            builder: (context, snapshot) => _FeatureCard(
              label: 'Async method  (@nitroAsync)',
              code: 'await Math.instance.multiply(5.0, 4.0)',
              result: snapshot.hasData
                  ? '${snapshot.data}'
                  : snapshot.hasError
                      ? 'Error'
                      : null,
            ),
          ),
          const SizedBox(height: 12),

          // ── Read-only property ─────────────────────────────────────────────
          _FeatureCard(
            label: 'Read-only property',
            code: 'Math.instance.scaleFactor',
            result: _scaleFactorResult,
          ),
          const SizedBox(height: 12),

          // ── Read-write property ────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _FeatureLabel(
                    label: 'Read-write property',
                    code: 'Math.instance.precision = $_precision',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        _precisionResult,
                        style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.deepPurple),
                      ),
                      const Spacer(),
                      IconButton.filled(
                        icon: const Icon(Icons.remove),
                        onPressed: _precision > 0
                            ? () => _setPrecision(_precision - 1)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        icon: const Icon(Icons.add),
                        onPressed: _precision < 10
                            ? () => _setPrecision(_precision + 1)
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Zero-copy buffer ───────────────────────────────────────────────
          _FeatureCard(
            label: 'Zero-copy buffer  (@zeroCopy)',
            code: 'Math.instance.processBuffer(Uint8List(64))',
            result: _bufferResult,
          ),
          const SizedBox(height: 12),

          // ── Hybrid enum ────────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _FeatureLabel(
                    label: 'Hybrid enum  (@HybridEnum)',
                    code: 'Rounding.values',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: Rounding.values
                        .map((r) =>
                            Chip(label: Text('${r.name}  (${r.nativeValue})')))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Stream ─────────────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _FeatureLabel(
                    label: 'Native stream  (@NitroStream)',
                    code: 'Math.instance.updates.listen(...)',
                  ),
                  const SizedBox(height: 8),
                  _streamEvents.isEmpty
                      ? const Text('Waiting for events…',
                          style: TextStyle(color: Colors.grey))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _streamEvents.reversed
                              .map((e) => Text('→ $e',
                                  style: const TextStyle(
                                      fontFamily: 'monospace')))
                              .toList(),
                        ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── Reusable widgets ───────────────────────────────────────────────────────────

class _FeatureLabel extends StatelessWidget {
  const _FeatureLabel({required this.label, required this.code});
  final String label;
  final String code;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 2),
        Text(code,
            style: const TextStyle(
                color: Colors.grey, fontSize: 11, fontFamily: 'monospace')),
      ],
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.label,
    required this.code,
    required this.result,
  });
  final String label;
  final String code;
  final String? result; // null = still loading

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(child: _FeatureLabel(label: label, code: code)),
            const SizedBox(width: 12),
            result == null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    result!,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple),
                  ),
          ],
        ),
      ),
    );
  }
}
