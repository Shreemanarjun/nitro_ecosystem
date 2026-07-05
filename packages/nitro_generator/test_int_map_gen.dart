import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/languages/kotlin/kotlin_generator.dart';
import 'package:nitro_generator/src/generators/languages/swift/swift_generator.dart';

void main() {
  final spec = BridgeSpec(
    dartClassName: 'Test',
    lib: 'test',
    namespace: 'test',
    androidImpl: NativeImpl.kotlin,
    iosImpl: NativeImpl.swift,
    sourceUri: 'test.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'echoIntMap',
        cSymbol: 'test_echo_int_map',
        isAsync: false,
        returnType: BridgeType(name: 'Map<int, String>'),
        params: [
          BridgeParam(
            name: 'value',
            type: BridgeType(name: 'Map<int, String>'),
          ),
        ],
      ),
      BridgeFunction(
        dartName: 'echoInt32',
        cSymbol: 'test_echo_int32',
        isAsync: false,
        returnType: BridgeType(name: 'int32'),
        params: [
          BridgeParam(
            name: 'value',
            type: BridgeType(name: 'int32'),
          ),
        ],
      ),
    ],
  );
  print('=== KOTLIN ===');
  final kotlin = KotlinGenerator.generate(spec);
  print(kotlin);
  print('\n=== SWIFT ===');
  final swift = SwiftGenerator.generate(spec);
  print(swift);
}
