import 'package:nitro/nitro.dart';

part 'sensor.g.dart';

// ── Enums ─────────────────────────────────────────────────────────────────────
@HybridEnum(startValue: 0)
enum SensorStatus { offline, connecting, online, error }

// ── Struct: compact numeric reading (packed, no string fields) ─────────────────
@HybridStruct(packed: true)
class SensorReading {
  double temperature;
  double humidity;
  int timestampMs;
}

// ── Record: richer calibration data (has string sensorId) ─────────────────────
@HybridRecord
class CalibrationData {
  double offsetTemp;
  double offsetHumidity;
  String sensorId;
}

// ── Sensor module spec ─────────────────────────────────────────────────────────
@NitroModule(ios: AppleNativeImpl.swift, android: AndroidNativeImpl.kotlin)
abstract class Sensor extends HybridObject {
  static final Sensor instance = _SensorImpl();

  // ── Sync nullable reads (struct or primitive may not be available yet) ─────
  double? getTemperature();
  double? getHumidity();
  int? getLastTimestamp();
  SensorStatus getStatus();

  // ── Async ops ─────────────────────────────────────────────────────────────
  Future<SensorReading> snapshot();
  Future<void> calibrate({CalibrationData? data});

  // ── Nullable record return ─────────────────────────────────────────────────
  CalibrationData? getCalibration();

  // ── Properties ────────────────────────────────────────────────────────────
  bool get isConnected;
  String get sensorId;

  // ── Multiple streams (different item types) ────────────────────────────────
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<double> get temperature;

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<double> get humidity;

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorReading> get readings;

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorStatus> get status;
}
