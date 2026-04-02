import FlutterMacOS
import Foundation

public class BenchmarkPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    BenchmarkRegistry.register(BenchmarkImpl())
    // benchmark_cpp auto-registers via __attribute__((constructor)) in HybridBenchmarkCpp.cpp

    let channel = FlutterMethodChannel(name: "dev.shreeman.benchmark/method_channel", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(BenchmarkPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "add" {
      let args = call.arguments as? [String: Any]
      let a = args?["a"] as? Double ?? 0.0
      let b = args?["b"] as? Double ?? 0.0
      result(a + b)
    } else if call.method == "sendLargeBuffer" {
      guard let bufferArray = call.arguments as? FlutterStandardTypedData else {
        print("❌ [NitroBenchmark] MethodChannel Error: Invalid buffer data")
        result(FlutterError(code: "ERR", message: "Invalid buffer", details: nil))
        return
      }
      result(Int64(bufferArray.data.count))
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}
