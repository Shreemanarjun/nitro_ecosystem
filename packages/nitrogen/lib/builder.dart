import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'src/spec_extractor.dart';
import 'src/generators/dart_ffi_generator.dart';
import 'src/generators/cpp_header_generator.dart';
import 'src/generators/kotlin_generator.dart';
import 'src/generators/swift_generator.dart';
import 'src/generators/cmake_generator.dart';

Builder nitrogenBuilder(BuilderOptions options) {
  return NitrogenBuilder();
}

class NitrogenBuilder implements Builder {
  @override
  final Map<String, List<String>> buildExtensions = {
    '.native.dart': ['.g.dart', '_bridge.g.kt', '_bridge.g.swift', '_bridge.g.h', '_CMakeLists.g.txt']
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final libraryElement = await buildStep.inputLibrary;
    final library = LibraryReader(libraryElement);
    
    try {
      final spec = SpecExtractor.extract(library);
      
      // Dart
      final dartOutput = DartFfiGenerator.generate(spec);
      final dartId = buildStep.inputId.path.replaceFirst('.native.dart', '.g.dart');
      await buildStep.writeAsString(AssetId(buildStep.inputId.package, dartId), dartOutput);

      // Kotlin
      final kotlinOutput = KotlinGenerator.generate(spec);
      final kotlinId = buildStep.inputId.path.replaceFirst('.native.dart', '_bridge.g.kt');
      await buildStep.writeAsString(AssetId(buildStep.inputId.package, kotlinId), kotlinOutput);

      // Swift
      final swiftOutput = SwiftGenerator.generate(spec);
      final swiftId = buildStep.inputId.path.replaceFirst('.native.dart', '_bridge.g.swift');
      await buildStep.writeAsString(AssetId(buildStep.inputId.package, swiftId), swiftOutput);

      // C Header
      final cppOutput = CppHeaderGenerator.generate(spec);
      final cppId = buildStep.inputId.path.replaceFirst('.native.dart', '_bridge.g.h');
      await buildStep.writeAsString(AssetId(buildStep.inputId.package, cppId), cppOutput);

      // CMake
      final cmakeOutput = CMakeGenerator.generate(spec);
      final cmakeId = buildStep.inputId.path.replaceFirst('.native.dart', '_CMakeLists.g.txt');
      await buildStep.writeAsString(AssetId(buildStep.inputId.package, cmakeId), cmakeOutput);
      
    } catch (e) {
      log.warning('Could not process ${buildStep.inputId}: $e');
    }
  }
}
