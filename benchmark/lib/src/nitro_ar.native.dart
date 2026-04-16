import 'package:nitro/nitro.dart';
import 'dart:typed_data';

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

@HybridStruct()
class PackageDimensions {
  final double length; // In centimeters/inches
  final double width; // In centimeters/inches
  final double height; // In centimeters/inches
  final double confidence; // 0.0 to 1.0 (How sure is the ML model?)

  // The 'Pose' helps Flutter render a 3D bounding box exactly on the package
  final Vector3 center;
  final Quaternion rotation;

  double get volume => length * width * height;

  PackageDimensions({
    required this.length,
    required this.width,
    required this.height,
    required this.confidence,
    required this.center,
    required this.rotation,
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
}
