import '../../native_generator_model.dart';
import 'dart_ffi_generator.dart';

NativeGeneratorBundle dartGeneratorBundle() {
  return NativeGeneratorBundle(
    language: NativeGeneratorLanguage.dart,
    directory: 'dart',
    generators: [
      FunctionNativeCodeGenerator(NativeGeneratorTarget.dartFfi, '.g.dart', DartFfiGenerator.generate),
    ],
    commands: const [
      NativeGeneratorCommand(
        name: 'format',
        description: 'Format generated Dart FFI output.',
        defaultArgs: ['dart', 'format'],
      ),
    ],
  );
}
