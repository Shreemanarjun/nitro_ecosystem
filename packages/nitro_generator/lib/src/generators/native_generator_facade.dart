import '../bridge_spec.dart';
import 'languages/c_bridge/c_bridge_generator_bundle.dart';
import 'languages/cmake/cmake_generator_bundle.dart';
import 'languages/cpp_native/cpp_native_generator_bundle.dart';
import 'languages/dart/dart_generator_bundle.dart';
import 'languages/kotlin/kotlin_generator_bundle.dart';
import 'languages/swift/swift_generator_bundle.dart';
import 'native_generator_model.dart';

export 'native_generator_model.dart';

final class NativeGeneratorFacade {
  final List<NativeGeneratorBundle> bundles;
  final List<NativeCodeGenerator> _orderedGenerators;
  final Map<NativeGeneratorTarget, NativeCodeGenerator> _generators;

  NativeGeneratorFacade(Iterable<NativeCodeGenerator> generators)
    : this.fromBundles([
        NativeGeneratorBundle(
          language: NativeGeneratorLanguage.custom,
          directory: 'custom',
          generators: generators,
        ),
      ]);

  NativeGeneratorFacade.fromBundles(Iterable<NativeGeneratorBundle> bundles) : this._(List.unmodifiable(bundles));

  NativeGeneratorFacade._(this.bundles) : _orderedGenerators = List.unmodifiable(bundles.expand((bundle) => bundle.generators)), _generators = _indexByTarget(bundles);

  factory NativeGeneratorFacade.defaults() {
    return NativeGeneratorFacade.fromBundles(defaultNativeGeneratorBundles());
  }

  String generate(NativeGeneratorTarget target, BridgeSpec spec) {
    final generator = _generators[target];
    if (generator == null) {
      throw StateError('No native generator registered for $target.');
    }
    return generator.generate(spec);
  }

  NativeGeneratorTarget? targetForOutputPath(String path) {
    for (final generator in _orderedGenerators) {
      if (path.endsWith(generator.outputSuffix)) return generator.target;
    }
    return null;
  }

  NativeGeneratorBundle? bundleFor(NativeGeneratorLanguage language) {
    for (final bundle in bundles) {
      if (bundle.language == language) return bundle;
    }
    return null;
  }

  List<NativeGeneratorCommand> commandsFor(NativeGeneratorLanguage language) {
    return bundleFor(language)?.commands ?? const [];
  }

  static Map<NativeGeneratorTarget, NativeCodeGenerator> _indexByTarget(Iterable<NativeGeneratorBundle> bundles) {
    final byTarget = <NativeGeneratorTarget, NativeCodeGenerator>{};
    final suffixes = <String>{};
    final languages = <NativeGeneratorLanguage>{};

    for (final bundle in bundles) {
      if (!languages.add(bundle.language)) {
        throw StateError('Duplicate native generator bundle registered for ${bundle.language}.');
      }
      for (final generator in bundle.generators) {
        if (byTarget.containsKey(generator.target)) {
          throw StateError('Duplicate native generator registered for ${generator.target}.');
        }
        if (!suffixes.add(generator.outputSuffix)) {
          throw StateError('Duplicate native generator output suffix ${generator.outputSuffix}.');
        }
        byTarget[generator.target] = generator;
      }
    }
    return byTarget;
  }
}

List<NativeGeneratorBundle> defaultNativeGeneratorBundles() {
  return [
    dartGeneratorBundle(),
    kotlinGeneratorBundle(),
    swiftGeneratorBundle(),
    cBridgeGeneratorBundle(),
    cppNativeGeneratorBundle(),
    cmakeGeneratorBundle(),
  ];
}
