import 'package:nitro/nitro.dart';

part 'math.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class Math extends HybridObject {
  static final Math instance = _MathImpl(NitroRuntime.loadLib('nitro'));

  double add(double a, double b);
  
  @nitroAsync
  Future<double> multiply(double a, double b);
}
