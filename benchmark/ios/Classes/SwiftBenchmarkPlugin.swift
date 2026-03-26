import Flutter
import UIKit

public class SwiftBenchmarkPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        BenchmarkRegistry.register(BenchmarkImpl())

        let channel = FlutterMethodChannel(name: "dev.shreeman.benchmark/method_channel", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SwiftBenchmarkPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "add" {
            let args = call.arguments as? [String: Any]
            let a = args?["a"] as? Double ?? 0.0
            let b = args?["b"] as? Double ?? 0.0
            result(a + b)
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
}
