import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_camera/my_camera.dart';

void main() {
  // ── MyCamera.instance ───────────────────────────────────────────────────────
  //
  // This test requires the compiled native library (my_camera.so / my_camera.dylib)
  // to be available at runtime.  On a CI host that only runs Dart unit tests
  // (no simulator / physical device), loading the dynamic library fails with
  // "symbol not found: InitDartApiDL".
  //
  // We catch that specific error and mark the test as skipped instead of
  // failing, so the suite stays green in pure-Dart environments.
  test('MyCamera instance can be accessed (requires native library)', () {
    try {
      expect(MyCamera.instance, isNotNull);
    } on ArgumentError catch (e) {
      if (e.message.toString().contains('InitDartApiDL') ||
          e.message.toString().contains('symbol not found') ||
          e.message.toString().contains('Failed to lookup')) {
        markTestSkipped(
          'Native library not available in this test environment: $e',
        );
        return;
      }
      rethrow;
    } on UnsupportedError catch (e) {
      markTestSkipped('Platform not supported in this test environment: $e');
      return;
    }
  });

  // ── Pure-Dart tests (always run) ────────────────────────────────────────────

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
}
