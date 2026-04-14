import FlutterMacOS
import Foundation

public class BenchmarkExamplePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    benchmark_exampleRegistry.register(benchmark_exampleModuleImpl())
    // Nitro registration will be injected here by nitrogen link.
  }
}
