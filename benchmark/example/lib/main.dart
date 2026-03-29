import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nitro/nitro.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'multi_bridge_dashboard.dart';
import 'box_stress_page.dart';
import 'benchmark_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable(); // Keep screen awake during benchmarks
  SignalsObserver.instance = null;
  NitroConfig.instance.isolatePoolSize = Platform.numberOfProcessors;
  await NitroRuntime.init();
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
      home: const MainNavigationPage(),
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
