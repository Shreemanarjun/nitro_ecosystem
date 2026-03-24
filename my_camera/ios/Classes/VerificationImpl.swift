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
        let count = inputs.count
        // Allocate a C-owned float* buffer and copy the doubled values in.
        // The caller (Dart side, via ZeroCopyFloat32Buffer) reads this pointer
        // zero-copy via asTypedList(); memory is owned by this buffer until
        // the FloatBuffer struct is freed by the C bridge.
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
        for (i, v) in inputs.enumerated() {
            ptr[i] = v * 2.0
        }
        return FloatBuffer(data: ptr, length: Int64(count))
    }
}
