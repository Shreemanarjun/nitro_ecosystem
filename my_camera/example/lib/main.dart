import 'package:flutter/material.dart';
import 'package:my_camera/my_camera.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  double _result = 0;
  String _greeting = 'Loading...';

  @override
  void initState() {
    super.initState();
    // Example synchronous call
    try {
      _result = MyCamera.instance.add(10, 20);
    } catch (e) {
      print('Native implementation may not be loaded yet: $e');
    }

    // Example asynchronous call
    MyCamera.instance.getGreeting('Flutter').then((val) {
      if (mounted) setState(() => _greeting = val);
    }).catchError((e) {
      if (mounted) setState(() => _greeting = 'Error: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Nitrogen Plugin Example')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sync Result: 10 + 20 = $_result'),
              const SizedBox(height: 16),
              Text('Async Result: $_greeting'),
              const SizedBox(height: 32),
              const Text('Stream Yields:', style: TextStyle(fontWeight: FontWeight.bold)),
              StreamBuilder<CameraFrame>(
                stream: MyCamera.instance.frames,
                builder: (context, snapshot) {
                  if (snapshot.hasError) return Text('Error: ${snapshot.error}');
                  if (!snapshot.hasData) return const CircularProgressIndicator();
                  final f = snapshot.data!;
                  return Column(
                    children: [
                      Text(
                        '${f.width} × ${f.height}  stride=${f.stride}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'ts=${(f.timestampNs / 1e9).toStringAsFixed(3)} s',
                        style: const TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                      Text(
                        '${(f.stride * f.height / 1024).toStringAsFixed(1)} KB  (zero-copy)',
                        style: const TextStyle(fontSize: 14, color: Colors.blueAccent),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
