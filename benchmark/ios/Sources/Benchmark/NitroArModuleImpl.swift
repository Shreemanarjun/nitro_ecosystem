import Combine
import Foundation

public class NitroArModuleImpl: NSObject, HybridNitroArProtocol {
    public override init() { super.init() }

    public func add(a: Double, b: Double) -> Double { a + b }
    public func getGreeting(name: String) async throws -> String { "Hello, \(name)!" }
    public func isDepthSupported() -> Bool { false }
    public func detectPackage(rect: BoundingBox) -> PackageDimensions {
        PackageDimensions(
            length: 0, width: 0, height: 0, confidence: 0,
            vector3: Vector3(x: 0, y: 0, z: 0),
            quaternion: Quaternion(x: 0, y: 0, z: 0, w: 1)
        )
    }
    public func getRawDepthMap() -> RawDepthMap {
        RawDepthMap(data: nil, width: 0, height: 0, stride: 0)
    }
    public func estimateVolume(anchor: String) -> Double { 0 }
    public func checkCameraPermission() async throws -> Bool { false }
    public func requestCameraPermission() async throws -> Bool { false }
    public func startSession() async throws {}
    public func stopSession() async throws {}
    public func pauseSession() async throws {}
    public func resumeSession() async throws {}
    public func isTracking() -> Bool { false }
    public func enableFlashlight(enable: Bool) {}
    public func setDetectionOptions(threshold: Double, rotation: Int64, useMock: Bool) {}

    private let _detectedPackagesSubject = PassthroughSubject<PackageBoxes, Never>()
    private let _liveTrackingSubject = PassthroughSubject<LiveTrackingUpdate, Never>()

    public var detectedPackages: AnyPublisher<PackageBoxes, Never> {
        _detectedPackagesSubject.eraseToAnyPublisher()
    }
    public var liveTrackingUpdates: AnyPublisher<LiveTrackingUpdate, Never> {
        _liveTrackingSubject.eraseToAnyPublisher()
    }
}
