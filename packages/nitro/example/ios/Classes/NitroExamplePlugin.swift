import Flutter
import UIKit

public class NitroExamplePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
        MathRegistry.register(MathModuleImpl())
    // Nitro registration will be injected here by nitrogen link.
  }
}
