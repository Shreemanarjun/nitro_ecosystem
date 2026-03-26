import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'src/spec_extractor.dart';
import 'src/spec_validator.dart';
import 'src/generators/dart/dart_ffi_generator.dart';
import 'src/generators/cpp/cpp_header_generator.dart';
import 'src/generators/cpp/cpp_bridge_generator.dart';
import 'src/generators/cpp/cpp_class_generator.dart';
import 'src/generators/android/kotlin_generator.dart';
import 'src/generators/ios/swift_generator.dart';
import 'src/generators/build/cmake_generator.dart';

Builder nitroGeneratorBuilder(BuilderOptions options) {
  return NitroGeneratorBuilder();
}

class NitroGeneratorBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
    '^lib/{{dir}}/{{file}}.native.dart': [
      'lib/{{dir}}/{{file}}.g.dart',
      'lib/{{dir}}/generated/kotlin/{{file}}.bridge.g.kt',
      'lib/{{dir}}/generated/swift/{{file}}.bridge.g.swift',
      'lib/{{dir}}/generated/cpp/{{file}}.bridge.g.h',
      'lib/{{dir}}/generated/cpp/{{file}}.bridge.g.cpp',
      'lib/{{dir}}/generated/cpp/{{file}}.g.hpp',
      'lib/{{dir}}/generated/cmake/{{file}}.CMakeLists.g.txt',
    ],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final libraryElement = await buildStep.inputLibrary;
    final library = LibraryReader(libraryElement);

    try {
      final spec = SpecExtractor.extract(library);

      final issues = SpecValidator.validate(spec);
      for (final issue in issues) {
        if (issue.isError) {
          log.severe('nitrogen: ${buildStep.inputId.path}\n  $issue');
        } else {
          log.warning('nitrogen: ${buildStep.inputId.path}\n  $issue');
        }
      }
      if (issues.any((i) => i.isError)) {
        return;
      }

      final outputs = buildStep.allowedOutputs;

      for (final outId in outputs) {
        if (outId.path.endsWith('.g.dart')) {
          await buildStep.writeAsString(outId, DartFfiGenerator.generate(spec));
        } else if (outId.path.endsWith('.bridge.g.kt')) {
          await buildStep.writeAsString(outId, KotlinGenerator.generate(spec));
        } else if (outId.path.endsWith('.bridge.g.swift')) {
          await buildStep.writeAsString(outId, SwiftGenerator.generate(spec));
        } else if (outId.path.endsWith('.bridge.g.h')) {
          await buildStep.writeAsString(outId, CppHeaderGenerator.generate(spec));
        } else if (outId.path.endsWith('.bridge.g.cpp')) {
          await buildStep.writeAsString(outId, CppBridgeGenerator.generate(spec));
        } else if (outId.path.endsWith('.g.hpp')) {
          await buildStep.writeAsString(outId, CppClassGenerator.generate(spec));
        } else if (outId.path.endsWith('.CMakeLists.g.txt')) {
          await buildStep.writeAsString(outId, CMakeGenerator.generate(spec));
        }
      }
    } catch (e, st) {
      log.warning('nitrogen: Could not process ${buildStep.inputId}:\n$e\n$st');
    }
  }
}
