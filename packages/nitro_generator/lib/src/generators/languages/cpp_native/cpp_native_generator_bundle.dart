import '../../native_generator_model.dart';
import 'cpp_impl_generator.dart';
import 'cpp_interface_generator.dart';
import 'cpp_mock_generator.dart';

NativeGeneratorBundle cppNativeGeneratorBundle() {
  return NativeGeneratorBundle(
    language: NativeGeneratorLanguage.cppNative,
    directory: 'cpp_native',
    generators: [
      FunctionNativeCodeGenerator(NativeGeneratorTarget.cppInterface, '.native.g.h', CppInterfaceGenerator.generate),
      FunctionNativeCodeGenerator(NativeGeneratorTarget.cppImplStarter, '.impl.g.cpp', CppImplGenerator.generate),
      FunctionNativeCodeGenerator(NativeGeneratorTarget.cppMockHeader, '.mock.g.h', CppMockGenerator.generateMockHeader),
      FunctionNativeCodeGenerator(NativeGeneratorTarget.cppTestStarter, '.test.g.cpp', CppMockGenerator.generateTestStarter),
    ],
    commands: const [
      NativeGeneratorCommand(
        name: 'optimize',
        description: 'Apply native C++ implementation optimization flags.',
        defaultArgs: ['-O2', '-DNITRO_NATIVE_IMPL=1'],
      ),
    ],
  );
}
