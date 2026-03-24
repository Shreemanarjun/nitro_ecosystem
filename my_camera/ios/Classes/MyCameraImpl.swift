import Flutter
import UIKit
import Combine

// 1. Conform to our Generated Nitrogen Protocol!
public class MyCameraModuleImpl: NSObject, HybridMyCameraProtocol {
    
    // Synchronous execution handler
    public func add(a: Double, b: Double) -> Double {
        return a + b
    }
    
    // Asynchronous execution handler
    public func getGreeting(name: String) async throws -> String {
        // Simulate some async native work (e.g. warming up a camera)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return "Hello \(name), from Swift-land!"
    }

    public func getAvailableDevices() async throws -> [CameraDevice] {
        return [
            CameraDevice(id: "ios-back", name: "Apple iSight Back", resolutions: [Resolution(width: 1920, height: 1080)], isFrontFacing: false),
            CameraDevice(id: "ios-front", name: "FaceTime HD", resolutions: [Resolution(width: 1280, height: 720)], isFrontFacing: true)
        ]
    }
    
    // Combine Publisher for zero-overhead background event streaming
    private let framesSubject = PassthroughSubject<CameraFrame, Never>()
    public var frames: AnyPublisher<CameraFrame, Never> {
        return framesSubject.eraseToAnyPublisher()
    }
    
    private let coloredFramesSubject = PassthroughSubject<CameraFrame, Never>()
    public var coloredFrames: AnyPublisher<CameraFrame, Never> {
        return coloredFramesSubject.eraseToAnyPublisher()
    }
    
    override init() {
        super.init()
        let width: Int64 = 1280
        let height: Int64 = 720
        let bytesPerPixel: Int64 = 4  // BGRA
        let stride = width * bytesPerPixel
        let byteCount = Int(stride * height)
        let hardwareBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let tsNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            let frame = CameraFrame(data: hardwareBuffer, width: width, height: height,
                                    stride: stride, timestampNs: tsNs)
            self?.framesSubject.send(frame)
        }

        // Colored frames stream
        let cWidth: Int64 = 640
        let cHeight: Int64 = 480
        let cStride = cWidth * 4
        let cBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(cStride * cHeight))
        var frameCount: Int = 0

        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let r = UInt8((frameCount * 2) % 256)
            let g = UInt8((frameCount * 5) % 256)
            let b = UInt8((frameCount * 10) % 256)
            
            for i in 0..<(Int(cWidth * cHeight)) {
                cBuffer[i*4] = b     // B
                cBuffer[i*4+1] = g   // G
                cBuffer[i*4+2] = r   // R
                cBuffer[i*4+3] = 255 // A
            }

            let tsNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            let frame = CameraFrame(data: cBuffer, width: cWidth, height: cHeight,
                                    stride: cStride, timestampNs: tsNs)
            self?.coloredFramesSubject.send(frame)
            frameCount += 1
        }
    }
}
