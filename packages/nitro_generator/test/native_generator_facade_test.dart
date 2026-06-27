import 'package:nitro_annotations/nitro_annotations.dart';
import 'package:nitro_generator/src/build_extensions.dart';
import 'package:nitro_generator/src/bridge_spec.dart';
import 'package:nitro_generator/src/generators/native_generator_facade.dart';
import 'package:test/test.dart';

void main() {
  group('NativeGeneratorFacade', () {
    test('maps every generated output path to a generator target', () {
      final facade = NativeGeneratorFacade.defaults();

      expect(facade.targetForOutputPath('lib/src/camera.g.dart'), NativeGeneratorTarget.dartFfi);
      expect(facade.targetForOutputPath('lib/src/generated/kotlin/camera.bridge.g.kt'), NativeGeneratorTarget.kotlin);
      expect(facade.targetForOutputPath('lib/src/generated/swift/camera.bridge.g.swift'), NativeGeneratorTarget.swift);
      expect(facade.targetForOutputPath('lib/src/generated/cpp/camera.bridge.g.h'), NativeGeneratorTarget.cppHeader);
      expect(facade.targetForOutputPath('lib/src/generated/cpp/camera.bridge.g.cpp'), NativeGeneratorTarget.cppBridge);
      expect(facade.targetForOutputPath('lib/src/generated/cmake/camera.CMakeLists.g.txt'), NativeGeneratorTarget.cmake);
      expect(facade.targetForOutputPath('lib/src/generated/cpp/camera.native.g.h'), NativeGeneratorTarget.cppInterface);
      expect(facade.targetForOutputPath('lib/src/generated/cpp/test/camera.mock.g.h'), NativeGeneratorTarget.cppMockHeader);
      expect(facade.targetForOutputPath('lib/src/generated/cpp/test/camera.test.g.cpp'), NativeGeneratorTarget.cppTestStarter);
      // PX18: web bridge
      expect(facade.targetForOutputPath('lib/src/generated/web/camera.web.bridge.g.dart'), NativeGeneratorTarget.webBridge);
      expect(facade.targetForOutputPath('lib/src/camera.txt'), isNull);
    });

    test('can isolate a single language generator with a custom facade', () {
      final facade = NativeGeneratorFacade([
        FunctionNativeCodeGenerator(
          NativeGeneratorTarget.kotlin,
          '.bridge.g.kt',
          (spec) => 'kotlin:${spec.dartClassName}',
        ),
      ]);

      expect(facade.generate(NativeGeneratorTarget.kotlin, _spec()), 'kotlin:Camera');
      expect(
        () => facade.generate(NativeGeneratorTarget.swift, _spec()),
        throwsStateError,
      );
    });

    test('default facade delegates Dart FFI generation without changing output shape', () {
      final facade = NativeGeneratorFacade.defaults();
      final out = facade.generate(NativeGeneratorTarget.dartFfi, _spec());

      expect(out, contains("part of 'camera.native.dart';"));
      expect(out, contains('class _CameraImpl extends Camera'));
    });

    test('routes every canonical builder output through the facade', () {
      final facade = NativeGeneratorFacade.defaults();
      final outputPaths = nitroBuilderExtensions.values.expand((paths) => paths);

      final targets = <NativeGeneratorTarget>{};
      for (final template in outputPaths) {
        final path = template.replaceAll('{{dir}}/', 'src/').replaceAll('{{file}}', 'camera');
        final target = facade.targetForOutputPath(path);
        expect(target, isNotNull, reason: '$template should have a generator facade route');
        targets.add(target!);
      }

      expect(targets, NativeGeneratorTarget.values.toSet());
    });

    test('defaults are separated into language-owned bundles', () {
      final facade = NativeGeneratorFacade.defaults();

      expect(
        facade.bundles.map((bundle) => bundle.language),
        [
          NativeGeneratorLanguage.dart,
          NativeGeneratorLanguage.kotlin,
          NativeGeneratorLanguage.swift,
          NativeGeneratorLanguage.cBridge,
          NativeGeneratorLanguage.cppNative,
          NativeGeneratorLanguage.build,
          NativeGeneratorLanguage.web, // PX18
        ],
      );
      expect(facade.bundleFor(NativeGeneratorLanguage.dart)?.directory, 'dart');
      expect(facade.bundleFor(NativeGeneratorLanguage.cBridge)?.directory, 'c_bridge');
      expect(facade.bundleFor(NativeGeneratorLanguage.cppNative)?.directory, 'cpp_native');
      expect(facade.bundleFor(NativeGeneratorLanguage.build)?.directory, 'cmake');
      expect(
        facade.bundleFor(NativeGeneratorLanguage.cBridge)?.generators.map((generator) => generator.target),
        [NativeGeneratorTarget.cppHeader, NativeGeneratorTarget.cppBridge],
      );
      expect(
        facade.bundleFor(NativeGeneratorLanguage.cppNative)?.generators.map((generator) => generator.target),
        [
          NativeGeneratorTarget.cppInterface,
          NativeGeneratorTarget.cppMockHeader,
          NativeGeneratorTarget.cppTestStarter,
        ],
      );
    });

    test('language bundles expose plug-in command hooks', () {
      final facade = NativeGeneratorFacade.defaults();

      expect(
        facade.commandsFor(NativeGeneratorLanguage.cBridge).map((command) => command.name),
        contains('optimize'),
      );
      expect(
        facade.commandsFor(NativeGeneratorLanguage.cBridge).single.defaultArgs,
        contains('-O2'),
      );
      expect(
        facade.commandsFor(NativeGeneratorLanguage.build).map((command) => command.name),
        contains('configure'),
      );
      expect(facade.commandsFor(NativeGeneratorLanguage.custom), isEmpty);
    });

    test('rejects duplicate target registrations', () {
      expect(
        () => NativeGeneratorFacade([
          FunctionNativeCodeGenerator(NativeGeneratorTarget.kotlin, '.bridge.g.kt', (_) => 'one'),
          FunctionNativeCodeGenerator(NativeGeneratorTarget.kotlin, '.other.g.kt', (_) => 'two'),
        ]),
        throwsStateError,
      );
    });

    test('rejects duplicate output suffix registrations', () {
      expect(
        () => NativeGeneratorFacade([
          FunctionNativeCodeGenerator(NativeGeneratorTarget.kotlin, '.bridge.g.kt', (_) => 'one'),
          FunctionNativeCodeGenerator(NativeGeneratorTarget.swift, '.bridge.g.kt', (_) => 'two'),
        ]),
        throwsStateError,
      );
    });

    test('rejects duplicate language bundle registrations', () {
      NativeGeneratorBundle bundle(String suffix) {
        return NativeGeneratorBundle(
          language: NativeGeneratorLanguage.kotlin,
          directory: 'kotlin',
          generators: [
            FunctionNativeCodeGenerator(NativeGeneratorTarget.kotlin, suffix, (_) => 'kotlin'),
          ],
        );
      }

      expect(
        () => NativeGeneratorFacade.fromBundles([
          bundle('.bridge.g.kt'),
          bundle('.other.g.kt'),
        ]),
        throwsStateError,
      );
    });
  });
}

BridgeSpec _spec() {
  return BridgeSpec(
    dartClassName: 'Camera',
    lib: 'camera',
    namespace: 'camera',
    androidImpl: NativeImpl.kotlin,
    sourceUri: 'camera.native.dart',
    functions: [
      BridgeFunction(
        dartName: 'ping',
        cSymbol: 'camera_ping',
        isAsync: false,
        returnType: BridgeType(name: 'void'),
        params: const [],
      ),
    ],
  );
}
