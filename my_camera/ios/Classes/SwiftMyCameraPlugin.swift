import Flutter

public class SwiftMyCameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        MyCameraRegistry.register(MyCameraImpl())
    }
}
