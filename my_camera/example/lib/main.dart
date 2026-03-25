import 'package:flutter/material.dart';
import 'package:nitro/nitro.dart';

import 'widgets/basic_view.dart';
import 'widgets/performance_view.dart';
import 'widgets/stress_view.dart';
import 'widgets/debug_panel.dart';

/// Configure the Nitro runtime BEFORE any plugin is accessed.
Future<void> _configureNitro() async {
  NitroConfig.instance.enable(slowCallThresholdMs: 16);
  await NitroRuntime.init(isolatePoolSize: 6);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureNitro();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nitro Ecosystem',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
          surface: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  int _refreshCount = 0;
  bool _debugPanelOpen = false;
  int _poolSize = NitroConfig.instance.isolatePoolSize;

  void _applyPoolSize(int size) async {
    await NitroRuntime.dispose();
    NitroConfig.instance.isolatePoolSize = size;
    await NitroRuntime.init(isolatePoolSize: size);
    if (mounted) setState(() => _poolSize = size);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('Nitro Ecosystem 🚀'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'Refresh Views',
              icon: const Icon(Icons.refresh),
              onPressed: () => setState(() => _refreshCount++),
            ),
            IconButton(
              tooltip: 'Nitro Debug Settings',
              icon: Icon(
                Icons.tune,
                color: NitroConfig.instance.logLevel != NitroLogLevel.none
                    ? Colors.amberAccent
                    : Colors.grey,
              ),
              onPressed: () => setState(() => _debugPanelOpen = !_debugPanelOpen),
            ),
          ],
          bottom: const TabBar(
            dividerColor: Colors.transparent,
            indicatorColor: Colors.deepPurpleAccent,
            labelColor: Colors.deepPurpleAccent,
            unselectedLabelColor: Colors.grey,
            tabs: [
              Tab(icon: Icon(Icons.home_outlined), text: 'Basic'),
              Tab(icon: Icon(Icons.speed_outlined), text: 'Performance'),
              Tab(icon: Icon(Icons.bolt_outlined), text: 'Stress'),
            ],
          ),
        ),
        body: Column(
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: _debugPanelOpen
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20.0),
                      child: DebugPanel(
                        poolSize: _poolSize,
                        onPoolSizeChanged: _applyPoolSize,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  BasicView(refreshCount: _refreshCount),
                  PerformanceView(refreshCount: _refreshCount),
                  const StressView(),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: Container(
          padding: const EdgeInsets.all(12),
          color: Colors.black,
          child: Text(
            'nitro 0.2.2 • pool=$_poolSize workers',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ),
      ),
    );
  }
}
