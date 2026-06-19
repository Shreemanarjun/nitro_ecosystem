import '../../native_generator_model.dart';
import 'swift_generator.dart';

NativeGeneratorBundle swiftGeneratorBundle() {
  return NativeGeneratorBundle(
    language: NativeGeneratorLanguage.swift,
    directory: 'swift',
    generators: [
      FunctionNativeCodeGenerator(NativeGeneratorTarget.swift, '.bridge.g.swift', SwiftGenerator.generate),
    ],
    commands: const [
      NativeGeneratorCommand(
        name: 'optimize',
        description: 'Apply Swift bridge generation optimization options.',
        defaultArgs: ['whole-module'],
      ),
    ],
  );
}
