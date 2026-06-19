import '../bridge_spec.dart';

enum NativeGeneratorTarget {
  dartFfi,
  kotlin,
  swift,
  cppHeader,
  cppBridge,
  cmake,
  cppInterface,
  cppMockHeader,
  cppTestStarter,
}

enum NativeGeneratorLanguage {
  dart,
  kotlin,
  swift,
  cBridge,
  cppNative,
  build,
  custom,
}

final class NativeGeneratorCommand {
  final String name;
  final String description;
  final List<String> defaultArgs;

  const NativeGeneratorCommand({
    required this.name,
    required this.description,
    this.defaultArgs = const [],
  });
}

abstract interface class NativeCodeGenerator {
  NativeGeneratorTarget get target;
  String get outputSuffix;
  String generate(BridgeSpec spec);
}

final class FunctionNativeCodeGenerator implements NativeCodeGenerator {
  @override
  final NativeGeneratorTarget target;
  @override
  final String outputSuffix;
  final String Function(BridgeSpec spec) _generate;

  const FunctionNativeCodeGenerator(this.target, this.outputSuffix, this._generate);

  @override
  String generate(BridgeSpec spec) => _generate(spec);
}

final class NativeGeneratorBundle {
  final NativeGeneratorLanguage language;
  final String directory;
  final List<NativeCodeGenerator> generators;
  final List<NativeGeneratorCommand> commands;

  NativeGeneratorBundle({
    required this.language,
    required this.directory,
    required Iterable<NativeCodeGenerator> generators,
    Iterable<NativeGeneratorCommand> commands = const [],
  }) : generators = List.unmodifiable(generators),
       commands = List.unmodifiable(commands);
}
