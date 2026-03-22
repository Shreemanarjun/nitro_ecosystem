import Flutter
import UIKit

// 1. Conform to our Generated Nitrogen Protocol!
public class MyCameraImpl: NSObject, HybridMyCameraProtocol {
    
    // Synchronous execution handler
    public func add(a: Double, b: Double) -> Double {
        return a + b
    }
    
    // Asynchronous execution handler
    public func getGreeting(name: String) async throws -> String {
        // Simulate some async native work (e.g. warming up a camera)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return "Hello \$name, from Swift-land!"
    }
}

// 2. Map this implementation exactly when the FlutterPlugin creates
public class SwiftMyCameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        // We do NOT use MethodChannels here. We directly register our Implementation 
        // class inside the Generated Nitrogen registry singleton.
        MyCameraRegistry.register(MyCameraImpl())
    }
}
