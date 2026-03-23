import 'package:flutter/material.dart';
import 'src/math.native.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late double sumResult;
  late Future<double> multiplyFuture;

  @override
  void initState() {
    super.initState();
    // Use the generated Nitro Module singleton
    sumResult = Math.instance.add(10.5, 20.5);
    multiplyFuture = Math.instance.multiply(5.0, 4.0);
  }

  @override
  Widget build(BuildContext context) {
    const spacer = SizedBox(height: 20);

    return MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Nitro Modules Demo'),
          centerTitle: true,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.bolt, size: 80, color: Colors.amber),
                const Text(
                  'Nitro Modules in Flutter',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                spacer,
                _ResultCard(
                  title: 'Synchronous Call',
                  subtitle: 'Math.instance.add(10.5, 20.5)',
                  result: '$sumResult',
                ),
                spacer,
                FutureBuilder<double>(
                  future: multiplyFuture,
                  builder: (context, snapshot) {
                    return _ResultCard(
                      title: 'Asynchronous (@nitro_async)',
                      subtitle: 'await Math.instance.multiply(5.0, 4.0)',
                      result: snapshot.hasData
                          ? '${snapshot.data}'
                          : 'Waiting...',
                      isLoading: !snapshot.hasData,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String result;
  final bool isLoading;

  const _ResultCard({
    required this.title,
    required this.subtitle,
    required this.result,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const Divider(),
            if (isLoading)
              const CircularProgressIndicator()
            else
              Text(
                result,
                style: const TextStyle(
                  fontSize: 24,
                  color: Colors.deepPurple,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
