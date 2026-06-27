import 'package:nitro/nitro.dart';

part 'nitro_ar.g.dart';

@HybridStruct()
class Vector3 {
  const Vector3({required this.x, required this.y, required this.z});
  final double x;
  final double y;
  final double z;
}

@HybridStruct()
class Quaternion {
  const Quaternion({
    required this.x,
    required this.y,
    required this.z,
    required this.w,
  });
  final double x;
  final double y;
  final double z;
  final double w;
}

@HybridStruct()
class BoundingBox {
  const BoundingBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
  final double x;
  final double y;
  final double width;
  final double height;
}

@HybridRecord()
class PackageBoxes {
  const PackageBoxes({required this.boxes});
  final List<double> boxes; // [x, y, w, h, ...] flattened for stability
}

@HybridStruct()
class PackageDimensions {
  final double length; // In centimeters/inches
  final double width; // In centimeters/inches
  final double height; // In centimeters/inches
  final double confidence; // 0.0 to 1.0 (How sure is the ML model?)

  // Flattened Vector3 center to bypass nested Struct compiler errors
  final Vector3 vector3;

  // Flattened Quaternion rotation
  final Quaternion quaternion;

  double get volume => length * width * height;

  PackageDimensions({
    required this.length,
    required this.width,
    required this.height,
    required this.confidence,
    required this.vector3,
    required this.quaternion,
  });
}

@HybridStruct(zeroCopy: ['data'])
class RawDepthMap {
  final Uint8List data;
  final int width;
  final int height;
  final int stride;

  RawDepthMap({
    required this.data,
    required this.width,
    required this.height,
    required this.stride,
  });
}

@HybridRecord()
class LiveTrackingUpdate {
  const LiveTrackingUpdate({
    required this.isTracking,
    required this.centerDimensions,
  });
  final bool isTracking;
  final PackageDimensions centerDimensions;
}

@NitroModule(
  ios: NativeImpl.swift,
  android: NativeImpl.kotlin,
  macos: NativeImpl.swift,
)
abstract class NitroAr extends HybridObject {
  static final NitroAr instance = _NitroArImpl();

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);

  bool isDepthSupported();

  PackageDimensions detectPackage(BoundingBox rect);

  RawDepthMap getRawDepthMap();

  double estimateVolume(String anchor);
  @nitroAsync
  Future<bool> checkCameraPermission();

  @nitroAsync
  Future<bool> requestCameraPermission();

  // Lifecycle methods
  @nitroAsync
  Future<void> startSession();

  @nitroAsync
  Future<void> stopSession();

  @nitroAsync
  Future<void> pauseSession();

  @nitroAsync
  Future<void> resumeSession();

  // Status and Control
  bool isTracking();

  void enableFlashlight(bool enable);

  /// Configure the ML object detector parameters.
  void setDetectionOptions(double threshold, int rotation, bool useMock);

  /// Stream of auto-detected packages using ML on the live AR frame.
  /// No manual polling required, updates are pushed directly.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<PackageBoxes> get detectedPackages;

  /// Stream of tracking state and live center dimensions updated every 500ms natively.
  @NitroStream(backpressure: Backpressure.dropLatest)
  Stream<LiveTrackingUpdate> get liveTrackingUpdates;
}
