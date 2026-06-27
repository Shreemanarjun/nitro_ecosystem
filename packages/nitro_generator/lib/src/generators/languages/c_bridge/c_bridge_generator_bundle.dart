import '../../native_generator_model.dart';
import 'cpp_bridge_generator.dart';
import 'cpp_header_generator.dart';

NativeGeneratorBundle cBridgeGeneratorBundle() {
  return NativeGeneratorBundle(
    language: NativeGeneratorLanguage.cBridge,
    directory: 'c_bridge',
    generators: [
      FunctionNativeCodeGenerator(NativeGeneratorTarget.cppHeader, '.bridge.g.h', CppHeaderGenerator.generate),
      FunctionNativeCodeGenerator(NativeGeneratorTarget.cppBridge, '.bridge.g.cpp', CppBridgeGenerator.generate),
    ],
    commands: const [
      NativeGeneratorCommand(
        name: 'optimize',
        description: 'Apply C bridge compiler optimization flags.',
        defaultArgs: ['-O2', '-fvisibility=hidden'],
      ),
    ],
  );
}
