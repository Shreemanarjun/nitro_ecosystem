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
            ],
          ),
        ),
      ),
    );
  }
}
