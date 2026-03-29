import Flutter
import UIKit

public class SwiftBenchmarkPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        BenchmarkRegistry.register(BenchmarkImpl())
        // benchmark_cpp auto-registers via __attribute__((constructor)) in HybridBenchmarkCpp.cpp

        let channel = FlutterMethodChannel(name: "dev.shreeman.benchmark/method_channel", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SwiftBenchmarkPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "add" {
            let args = call.arguments as? [String: Any]
            let a = args?["a"] as? Double ?? 0.0
            let b = args?["b"] as? Double ?? 0.0
            result(a + b)
        } else if call.method == "sendLargeBuffer" {
            guard let buffer = call.arguments as? FlutterStandardTypedData else {
                print("❌ [NitroBenchmark] MethodChannel Error: Invalid buffer data")
                result(FlutterError(code: "ERR", message: "Invalid buffer", details: nil))
                return
            }
            var sum: UInt8 = 0
            buffer.data.withUnsafeBytes { ptr in
                let bytes = ptr.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: buffer.data.count, by: 4096) {
                    sum = sum &+ bytes[i]
                }
            }
            result(Int64(buffer.data.count))
        } else {
            result(FlutterMethodNotImplemented)
        }
    }
}
