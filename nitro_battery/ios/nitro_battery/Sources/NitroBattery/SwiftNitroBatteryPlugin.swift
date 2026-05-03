import Flutter
import UIKit

public class SwiftNitroBatteryPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        NitroBatteryRegistry.register(NitroBatteryImpl())
    }
}
