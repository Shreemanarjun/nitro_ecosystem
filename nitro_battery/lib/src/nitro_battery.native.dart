import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:nitro/nitro.dart';

part 'nitro_battery.g.dart';

/// The charging state of the battery.
@HybridEnum(startValue: 0)
enum ChargingState { unknown, charging, discharging, full }

/// Detailed battery information snapshot.
@HybridStruct()
class BatteryInfo {
  final int level;           // 0-100
  final int chargingState;   // ChargingState.nativeValue
  final double voltage;      // volts (e.g. 4.15)
  final double temperature;  // celsius (e.g. 28.5)

  const BatteryInfo({
    required this.level,
    required this.chargingState,
    required this.voltage,
    required this.temperature,
  });
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class NitroBattery extends HybridObject {
  static final NitroBattery instance = _NitroBatteryImpl();

  // Synchronous — direct FFI, < 1 µs
  int getBatteryLevel();
  bool isCharging();
  ChargingState getChargingState();

  // Async — dispatched on background isolate
  @nitroAsync
  Future<BatteryInfo> getBatteryInfo();

  // Stream — native battery level events pushed to Dart
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<int> get batteryLevelChanges;

  // Properties
  int get lowPowerThreshold;
  set lowPowerThreshold(int percent);
}
