import '../../native_generator_model.dart';
import 'web_bridge_generator.dart';

NativeGeneratorBundle webGeneratorBundle() {
  return NativeGeneratorBundle(
    language: NativeGeneratorLanguage.web,
    directory: 'web',
    generators: [
      FunctionNativeCodeGenerator(
        NativeGeneratorTarget.webBridge,
        '.web.bridge.g.dart',
        WebBridgeGenerator.generate,
      ),
    ],
  );
}
