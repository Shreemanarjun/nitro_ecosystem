import 'package:flutter/material.dart';
import 'package:my_camera/my_camera.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Nitro Verifier')),
        body: const VerificationPage(),
      ),
    );
  }
}

class VerificationPage extends StatefulWidget {
  const VerificationPage({super.key});

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  String _pingResult = 'Not started';
  String _asyncPingResult = 'Not started';
  double _multResult = 0.0;

  @override
  void initState() {
    super.initState();
    _runTests();
  }

  Future<void> _runTests() async {
    final module = VerificationModule.instance;
    setState(() {
      _multResult = module.multiply(5.0, 7.0);
      _pingResult = module.ping('Verification Challenge');
    });

    final res = await module.pingAsync('Async Verification');
    setState(() {
      _asyncPingResult = res;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Multiply (5*7): $_multResult',
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 20),
          Text('Ping: $_pingResult'),
          const SizedBox(height: 20),
          Text('Async Ping: $_asyncPingResult'),
        ],
      ),
    );
  }
}
