import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_camera/my_camera.dart';

void main() {
  test('MyCamera instance can be accessed', () {
    expect(MyCamera.instance, isNotNull);
  });

  test('CameraFrame factory', () {
    final frame = CameraFrame(
      data: Uint8List(0),
      width: 1920,
      height: 1080,
      stride: 1920,
      timestampNs: 123456789,
    );
    expect(frame.width, 1920);
  });
}
