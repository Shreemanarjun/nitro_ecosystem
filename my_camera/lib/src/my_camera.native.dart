import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'my_camera.g.dart';

@HybridStruct(zeroCopy: ['data'])
class CameraFrame {
  final Uint8List data;
  final int width;
  final int height;
  final int stride;        // bytes per row — used as zero-copy byte length
  final int timestampNs;  // capture timestamp in nanoseconds

  CameraFrame(this.data, this.width, this.height, this.stride, this.timestampNs);
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class MyCamera extends HybridObject {
  static final MyCamera instance = _MyCameraImpl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);

  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<CameraFrame> get frames;
}
