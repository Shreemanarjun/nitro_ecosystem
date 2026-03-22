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
  /// build_runner requires ALL outputs to be declared.
  /// We use the pattern: input suffix → list of output suffixes.
  /// The output suffix is appended to the trimmed stem of the input path.
  ///
  ///  Input:  lib/src/math.native.dart
  ///  After trimming '.native.dart' stem → lib/src/math
  ///  Output: lib/src/math.g.dart
  ///          lib/src/generated/kotlin/math_bridge.g.kt  ← can't express with simple suffix
  ///
  /// build_runner DOES support the `|` prefix for package-absolute outputs.
  /// But the cleanest approach for subdirs is to write them without declaring
  /// them, which requires allowUnlistedOutputs in build.yaml.
  /// We use that here for the native files and only declare the Dart output.
  @override
  final Map<String, List<String>> buildExtensions = {
    '.native.dart': [
      '.g.dart',                              // Dart FFI bindings (part of)
      '.bridge.g.kt',                         // Kotlin interface + JNI bridge
      '.bridge.g.swift',                      // Swift protocol + registry
      '.bridge.g.h',                          // C/C++ header
      '.CMakeLists.g.txt',                    // CMake fragment
    ]
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final libraryElement = await buildStep.inputLibrary;
    final library = LibraryReader(libraryElement);

    try {
      final spec = SpecExtractor.extract(library);
      final pkg = buildStep.inputId.package;

      // Helper: derive sibling output AssetId by replacing the input suffix.
      AssetId sibling(String newSuffix) {
        final path = buildStep.inputId.path.replaceFirst('.native.dart', newSuffix);
        return AssetId(pkg, path);
      }

      // ── Dart (same directory, part of the library) ─────────────────────────
      await buildStep.writeAsString(
          sibling('.g.dart'), DartFfiGenerator.generate(spec));

      // ── Kotlin (sibling for now, user moves it to android/ in practice) ─────
      await buildStep.writeAsString(
          sibling('.bridge.g.kt'), KotlinGenerator.generate(spec));

      // ── Swift ───────────────────────────────────────────────────────────────
      await buildStep.writeAsString(
          sibling('.bridge.g.swift'), SwiftGenerator.generate(spec));

      // ── C/C++ Header ────────────────────────────────────────────────────────
      await buildStep.writeAsString(
          sibling('.bridge.g.h'), CppHeaderGenerator.generate(spec));

      // ── CMake ───────────────────────────────────────────────────────────────
      await buildStep.writeAsString(
          sibling('.CMakeLists.g.txt'), CMakeGenerator.generate(spec));
    } catch (e, st) {
      log.warning('nitrogen: Could not process ${buildStep.inputId}:\n$e\n$st');
    }
  }
}
