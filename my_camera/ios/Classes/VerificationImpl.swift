import Foundation
import Combine

public class VerificationModuleImpl: NSObject, HybridVerificationModuleProtocol {
    public func multiply(a: Double, b: Double) -> Double {
        return a * b
    }

    public func ping(message: String) -> String {
        return "Pong: \(message)"
    }

    public func pingAsync(message: String) async throws -> String {
        try await Task.sleep(nanoseconds: 500_000_000)
        return "Async Pong: \(message)"
    }

    public func throwError(message: String) {
        NSException.raise(.genericException, format: "%@", arguments: getVaList([message]))
    }

    public func processFloats(inputs: [Float]) -> FloatBuffer {
        let result = inputs.map { $0 * 2.0 }
        // We need to pass the count.
        // Since my bridge will toNative() this FloatBuffer.
        return FloatBuffer(data: result, length: Int64(result.count))
    }
}
