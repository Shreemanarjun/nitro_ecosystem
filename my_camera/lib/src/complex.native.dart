import 'dart:typed_data';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:nitro/nitro.dart';

part 'complex.g.dart';

@HybridEnum(startValue: 0)
enum DeviceStatus { idle, busy, error, fatal }

@HybridStruct(packed: true)
class SensorData {
  final double temperature;
  final double humidity;
  final int lastUpdate;
  const SensorData({
    required this.temperature,
    required this.humidity,
    required this.lastUpdate,
  });
}

@HybridStruct(zeroCopy: ['buffer'])
class Packet {
  final int sequence;
  final Uint8List buffer;
  final int size; // Byte length of buffer
  const Packet({
    required this.sequence,
    required this.buffer,
    required this.size,
  });
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class ComplexModule extends HybridObject {
  static final ComplexModule instance = _ComplexModuleImpl();

  // ─── Primitive Methods ───────────────────────────────────────────────────────
  int calculate(int seed, double factor, bool enabled);
  
  @nitroAsync
  Future<String> fetchMetadata(String url);

  // ─── Struct & Enum Methods ───────────────────────────────────────────────────
  DeviceStatus getStatus();
  void updateSensors(SensorData data);
  
  @nitroAsync
  Future<Packet> generatePacket(int type);

  // ─── Properties ──────────────────────────────────────────────────────────────
  double get batteryLevel;
  set config(String value);

  // ─── Streams ─────────────────────────────────────────────────────────────────
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<SensorData> get sensorStream;

  @NitroStream(backpressure: Backpressure.bufferDrop)
  Stream<Packet> get dataStream;
}
