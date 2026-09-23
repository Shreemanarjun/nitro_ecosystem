import FlutterMacOS
import Foundation

public class NitroBatteryPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    NitroBatteryRegistry.register(NitroBatteryModuleImpl())
    // Nitro registration will be injected here by nitrogen link.
  }
}
