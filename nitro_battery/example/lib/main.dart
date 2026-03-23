import 'package:flutter/material.dart';
import 'dart:async';

import 'package:nitro_battery/nitro_battery.dart' as nitro_battery;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late int batteryLevel;
  late Future<nitro_battery.BatteryInfo> batteryInfoFuture;

  @override
  void initState() {
    super.initState();
    // Sync call
    batteryLevel = nitro_battery.NitroBattery.instance.getBatteryLevel();
    // Start async call
    batteryInfoFuture = nitro_battery.NitroBattery.instance.getBatteryInfo();
  }

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 20);
    const spacerSmall = SizedBox(height: 10);

    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Nitro Battery Example')),
        body: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Text(
                  'This calls native code through Nitro Modules FFI. '
                  'The native code is built alongside your app.',
                  style: textStyle,
                  textAlign: TextAlign.center,
                ),
                spacerSmall,
                const Divider(),
                spacerSmall,
                Text(
                  'Battery Level (Sync): $batteryLevel%',
                  style: textStyle.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                spacerSmall,
                FutureBuilder<nitro_battery.BatteryInfo>(
                  future: batteryInfoFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const CircularProgressIndicator();
                    }
                    if (snapshot.hasError) {
                      return Text('Error: ${snapshot.error}');
                    }
                    final info = snapshot.data!;
                    return Column(
                      children: [
                        Text('Voltage: ${info.voltage}V', style: textStyle),
                        Text(
                          'Temperature: ${info.temperature}°C',
                          style: textStyle,
                        ),
                      ],
                    );
                  },
                ),
                spacerSmall,
                const Divider(),
                spacerSmall,
                const Text('Real-time updates:', style: textStyle),
                StreamBuilder<int>(
                  stream:
                      nitro_battery.NitroBattery.instance.batteryLevelChanges,
                  builder: (context, snapshot) {
                    final val = snapshot.data ?? batteryLevel;
                    print(val);
                    return Text(
                      'Live Level: $val%',
                      style: textStyle.copyWith(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
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
