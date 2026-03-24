import 'dart:typed_data';
import 'package:nitro/nitro.dart';

part 'verification.g.dart';

@HybridStruct()
class FloatBuffer {
  final Float32List data;
  final int length;
  const FloatBuffer({required this.data, required this.length});
}

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class VerificationModule extends HybridObject {
  static final VerificationModule instance = _VerificationModuleImpl();

  double multiply(double a, double b);
  String ping(String message);
  @nitroAsync
  Future<String> pingAsync(String message);

  void throwError(String message);

  @ZeroCopy()
  FloatBuffer processFloats(@ZeroCopy() Float32List inputs);
}
