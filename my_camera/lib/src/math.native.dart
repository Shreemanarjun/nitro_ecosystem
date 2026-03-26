import 'package:nitro/nitro.dart';

part 'math.g.dart';

@NitroModule(ios: NativeImpl.cpp, android: NativeImpl.cpp, lib: 'my_camera')
abstract class MathModule extends HybridObject {
  static final MathModule instance = _MathModuleImpl();

  double add(double a, double b);
  double subtract(double a, double b);
}
