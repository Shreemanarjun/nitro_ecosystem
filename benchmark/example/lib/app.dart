import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'features/dashboard/dashboard_screen.dart';
import 'features/harness/harness_screen.dart';
import 'features/micro/micro_bench_screen.dart';

/// Root widget. Five categorized surfaces:
///  • Compare — the rigorous BenchHarness (median/p95, verified workloads)
///  • Live    — the interactive per-call micro-bench
///  • Throughput / Visual Stress — the existing visual demos
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
          ? _StartupErrorScreen(error: startupError!)
          : MainNavigationPage(isWeb: kIsWeb),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Nitro Runtime failed to start',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                error,
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
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
    const HarnessScreen(),
    const BenchmarkPage(),
    const MultiBridgeDashboard(),
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
                      'Web Platform — Nitro C++ via WASM (Emscripten)',
                      style: TextStyle(fontSize: 12, color: Colors.cyan.shade200),
                    ),
                  ],
                ),
              )
            : null,
        body: IndexedStack(index: _selectedIndex, children: _pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (index) =>
              setState(() => _selectedIndex = index),
          backgroundColor: Colors.grey.shade900,
          indicatorColor: Colors.cyan.withAlpha(50),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.compare_arrows),
              label: 'Compare',
            ),
            NavigationDestination(icon: Icon(Icons.analytics), label: 'Live'),
            NavigationDestination(icon: Icon(Icons.speed), label: 'Throughput'),
          ],
        ),
      ),
    );
  }
}
