import 'package:nitro/nitro.dart';

part 'verification.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class VerificationModule extends HybridObject {
  static final VerificationModule instance = _VerificationModuleImpl();

  double multiply(double a, double b);
  String ping(String message);
  @nitroAsync
  Future<String> pingAsync(String message);
}
