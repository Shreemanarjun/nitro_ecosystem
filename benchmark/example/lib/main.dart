import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nitro/nitro.dart';
import 'package:signals_flutter/signals_core.dart';
import 'benchmark_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SignalsObserver.instance = null;
  NitroConfig.instance.isolatePoolSize = Platform.numberOfProcessors;

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
