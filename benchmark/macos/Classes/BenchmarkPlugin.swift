import FlutterMacOS
import Foundation

public class BenchmarkPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    NitroArRegistry.register(NitroArModuleImpl())
    BenchmarkRegistry.register(BenchmarkImpl())
    // BenchmarkCpp (NativeImpl.cpp) auto-registers via __attribute__((constructor))
    // in HybridBenchmarkCpp.cpp on library load — no Swift-side registration needed.

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
    } else if call.method == "deviceInfo" {
      // Hardware identity for the benchmark report.
      var size = 0
      sysctlbyname("hw.model", nil, &size, nil, 0)
      var model = [CChar](repeating: 0, count: size)
      sysctlbyname("hw.model", &model, &size, nil, 0)
      let os = ProcessInfo.processInfo.operatingSystemVersionString
      result([
        "model": String(cString: model),
        "socOs": "macOS \(os)",
      ])
    } else if call.method == "sievePrimes" {
      // Second reference workload: sieve of Eratosthenes — identical to
      // src/nitro_workload.h; every tier must return the same prime count.
      let args = call.arguments as? [String: Any]
      let limit = args?["limit"] as? Int ?? 0
      if limit < 2 { result(Int64(0)); return }
      var composite = [Bool](repeating: false, count: limit)
      var count: Int64 = 0
      var i = 2
      while i < limit {
        if !composite[i] {
          count += 1
          var j = i * i
          while j < limit {
            composite[j] = true
            j += i
          }
        }
        i += 1
      }
      result(count)
    } else if call.method == "hashBuffer" {
      // Reference workload: FNV-1a 64-bit — identical to
      // src/nitro_workload.h; &* wraps mod 2^64, matching C uint64_t.
      let args = call.arguments as? [String: Any]
      let data = (args?["data"] as? FlutterStandardTypedData)?.data ?? Data()
      let rounds = args?["rounds"] as? Int ?? 1
      var hash: UInt64 = 0xcbf29ce484222325
      data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        let bytes = ptr.bindMemory(to: UInt8.self)
        for _ in 0..<rounds {
          for i in 0..<bytes.count {
            hash ^= UInt64(bytes[i])
            hash = hash &* 0x100000001b3
          }
        }
      }
      result(Int64(bitPattern: hash))
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}
