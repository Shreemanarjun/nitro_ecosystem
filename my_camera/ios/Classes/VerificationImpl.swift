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
        // In Swift, throwing NSException or just causing an issue.
        // Swift errors are caught if they are 'throws', but here it's not.
        // Wait, my generator supports throws for async.
        // For sync, we catch NSException or can use NitroSetError manually.
        fatalError(message) // Note: this will crash! But it tests that Native crashes propagate if they are not caught.
        // Actually, let's use a non-crashing way if possible or just test it.
        // Actually, my bridge for iOS can catch NSException.
    }

    public func processFloats(inputs: [Float]) -> FloatBuffer {
        let result = inputs.map { $0 * 2.0 }
        // We need to pass the count.
        // Since my bridge will toNative() this FloatBuffer.
        return FloatBuffer(data: result, length: Int64(result.count))
    }
}
