import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nitro/nitro.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'multi_bridge_dashboard.dart';
import 'box_stress_page.dart';
import 'benchmark_page.dart';

String? _startupError;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable(); // Keep screen awake during benchmarks
  SignalsObserver.instance = null;
  NitroConfig.instance.isolatePoolSize = Platform.numberOfProcessors;
  try {
    await NitroRuntime.init();
  } catch (e) {
    // IsolatePool.create() can fail on some devices — retry with pool disabled.
    debugPrint(
      '[NitroBenchmark] NitroRuntime.init() failed: $e. Retrying with isolatePoolSize=0.',
    );
    NitroConfig.instance.isolatePoolSize = 0;
    try {
      await NitroRuntime.init();
    } catch (e2) {
      debugPrint(
        '[NitroBenchmark] NitroRuntime.init() failed again: $e2. Running without runtime.',
      );
      _startupError = e2.toString();
    }
  }
  runApp(const NitroBenchmarkApp());
}

class NitroBenchmarkApp extends StatelessWidget {
  const NitroBenchmarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nitro Benchmark',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.cyan,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: _startupError != null
          ? Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.redAccent,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Nitro Runtime failed to start',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _startupError!,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : const MainNavigationPage(),
    );
  }
}

class MainNavigationPage extends StatefulWidget {
  const MainNavigationPage({super.key});

  @override
  State<MainNavigationPage> createState() => _MainNavigationPageState();
}

class _MainNavigationPageState extends State<MainNavigationPage> {
  int _selectedIndex = 0;

  final List<Widget> _pages = [
    const MultiBridgeDashboard(),
    const BoxStressPage(),
    const BenchmarkPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        body: IndexedStack(index: _selectedIndex, children: _pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (index) {
            setState(() {
              _selectedIndex = index;
            });
          },
          backgroundColor: Colors.grey.shade900,
          indicatorColor: Colors.cyan.withAlpha(50),
          destinations: const [
            NavigationRequest(icon: Icon(Icons.speed), label: 'Throughput'),
            NavigationRequest(
              icon: Icon(Icons.flash_on),
              label: 'Visual Stress',
            ),
            NavigationRequest(icon: Icon(Icons.analytics), label: 'API Bench'),
          ],
        ),
      ),
    );
  }
}

class NavigationRequest extends NavigationDestination {
  const NavigationRequest({
    required super.icon,
    required super.label,
    super.key,
  });
}
