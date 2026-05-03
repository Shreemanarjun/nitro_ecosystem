import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_camera/my_camera.dart';

void main() {
  // ── Pure-Dart tests (no native library required) ────────────────────────────

  test('CameraFrame factory constructs with correct fields', () {
    final frame = CameraFrame(
      data: Uint8List(0),
      width: 1920,
      height: 1080,
      stride: 1920,
      timestampNs: 123456789,
    );
    expect(frame.width, 1920);
    expect(frame.height, 1080);
    expect(frame.stride, 1920);
    expect(frame.timestampNs, 123456789);
  });

  test('CameraFrame data field is a Uint8List', () {
    final frame = CameraFrame(
      data: Uint8List.fromList([1, 2, 3]),
      width: 4,
      height: 4,
      stride: 4,
      timestampNs: 0,
    );
    expect(frame.data, isA<Uint8List>());
    expect(frame.data.length, 3);
  });

  test('CameraFrame zero-length data is valid', () {
    final frame = CameraFrame(
      data: Uint8List(0),
      width: 0,
      height: 0,
      stride: 0,
      timestampNs: 0,
    );
    expect(frame.data.isEmpty, isTrue);
  });
}
