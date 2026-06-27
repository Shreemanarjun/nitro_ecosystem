import '../../native_generator_model.dart';
import 'cmake_generator.dart';

NativeGeneratorBundle cmakeGeneratorBundle() {
  return NativeGeneratorBundle(
    language: NativeGeneratorLanguage.build,
    directory: 'cmake',
    generators: [
      FunctionNativeCodeGenerator(NativeGeneratorTarget.cmake, '.CMakeLists.g.txt', CMakeGenerator.generate),
    ],
    commands: const [
      NativeGeneratorCommand(
        name: 'configure',
        description: 'Configure native build-system generation options.',
        defaultArgs: ['cmake'],
      ),
    ],
  );
}
