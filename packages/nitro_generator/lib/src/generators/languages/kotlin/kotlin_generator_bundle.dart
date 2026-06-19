import '../../native_generator_model.dart';
import 'kotlin_generator.dart';

NativeGeneratorBundle kotlinGeneratorBundle() {
  return NativeGeneratorBundle(
    language: NativeGeneratorLanguage.kotlin,
    directory: 'kotlin',
    generators: [
      FunctionNativeCodeGenerator(NativeGeneratorTarget.kotlin, '.bridge.g.kt', KotlinGenerator.generate),
    ],
    commands: const [
      NativeGeneratorCommand(
        name: 'optimize',
        description: 'Apply Kotlin bridge generation optimization options.',
        defaultArgs: ['jvm-inline'],
      ),
    ],
  );
}
