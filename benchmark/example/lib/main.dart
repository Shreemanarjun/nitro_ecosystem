import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'multi_bridge_dashboard.dart';
import 'box_stress_page.dart';
import 'benchmark_page.dart';
// NitroRuntime init is skipped on web (no dart:ffi); the web stub is a no-op.
import 'nitro_init.dart' if (dart.library.io) 'nitro_init_native.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable(); // Keep screen awake during benchmarks
  SignalsObserver.instance = null;

  await initNitroRuntime();

  runApp(NitroBenchmarkApp(startupError: startupError));
}

class NitroBenchmarkApp extends StatelessWidget {
  const NitroBenchmarkApp({super.key, this.startupError});
  final String? startupError;

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
      home: startupError != null
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
                        startupError!,
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
          : MainNavigationPage(isWeb: kIsWeb),
    );
  }
}

class MainNavigationPage extends StatefulWidget {
  const MainNavigationPage({super.key, this.isWeb = false});
  final bool isWeb;

  @override
  State<MainNavigationPage> createState() => _MainNavigationPageState();
}

class _MainNavigationPageState extends State<MainNavigationPage> {
  int _selectedIndex = 0;

  late final List<Widget> _pages = [
    const MultiBridgeDashboard(),
    const BoxStressPage(),
    const BenchmarkPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: widget.isWeb
            ? AppBar(
                backgroundColor: Colors.grey.shade900,
                title: Row(
                  children: [
                    const Icon(Icons.language, color: Colors.cyan, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      'Web Platform — Pure Dart baseline (no native bridge)',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.cyan.shade200,
                      ),
                    ),
                  ],
                ),
              )
            : null,
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
            NavigationDestination(icon: Icon(Icons.speed), label: 'Throughput'),
            NavigationDestination(
              icon: Icon(Icons.flash_on),
              label: 'Visual Stress',
            ),
            NavigationDestination(
              icon: Icon(Icons.analytics),
              label: 'API Bench',
            ),
          ],
        ),
      ),
    );
  }
}
