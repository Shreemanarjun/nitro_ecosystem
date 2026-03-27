import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nitro/nitro.dart';
import 'package:signals_flutter/signals_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'benchmark_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable(); // Keep screen awake during benchmarks
  SignalsObserver.instance = null;
  NitroConfig.instance.isolatePoolSize = Platform.numberOfProcessors;
  await NitroRuntime.init();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nitro Benchmark',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      home: const BenchmarkPage(),
    );
  }
}
