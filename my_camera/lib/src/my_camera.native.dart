import 'package:nitro/nitro.dart';

part 'my_camera.g.dart';

@NitroModule(ios: NativeImpl.swift, android: NativeImpl.kotlin)
abstract class MyCamera extends HybridObject {
  static final MyCamera instance = _MyCameraImpl(NitroRuntime.loadLib('my_camera'));

  double add(double a, double b);

  @nitroAsync
  Future<String> getGreeting(String name);
}
