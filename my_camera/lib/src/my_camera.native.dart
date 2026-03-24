import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'my_camera.g.dart';

@HybridStruct(zeroCopy: ['data'])
class CameraFrame {
  final Uint8List data;
  final int width;
  final int height;
  final int stride; // bytes per row — used as zero-copy byte length
  final int timestampNs; // capture timestamp in nanoseconds

  const CameraFrame({
    required this.data,
    required this.width,
    required this.height,
    required this.stride,
    required this.timestampNs,
  });
}

// ── @HybridRecord: complex/nested types ──────────────────────────────────────
// These are bridged as UTF-8 JSON — use for infrequent calls (device discovery,
// config). For hot-path data use @HybridStruct + ZeroCopy instead.

@HybridRecord()
class Resolution {
  final int width;
  final int height;
  const Resolution({required this.width, required this.height});
}

@HybridRecord()
class CameraDevice {
  final String id;
  final String name;
  final List<Resolution> resolutions;
  final bool isFrontFacing;

  const CameraDevice({
    required this.id,
    required this.name,
    required this.resolutions,
    required this.isFrontFacing,
  });
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class MyCamera extends HybridObject {
  static final MyCamera instance = _MyCameraImpl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);

  /// Returns all available camera devices as rich records.
  /// Native side serialises to JSON; Dart side auto-decodes to `List<CameraDevice>`.
  @nitroAsync
  Future<List<CameraDevice>> getAvailableDevices();

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<CameraFrame> get frames;
}
