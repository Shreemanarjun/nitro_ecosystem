import Foundation
import Combine

public class ComplexModuleImpl: NSObject, HybridComplexModuleProtocol {
    public func calculate(seed: Int64, factor: Double, enabled: Bool) -> Int64 {
        return enabled ? Int64(Double(seed) * factor) : seed
    }

    public func fetchMetadata(url: String) async throws -> String {
        return "Metadata for \(url)"
    }

    public func getStatus() -> DeviceStatus {
        return .idle
    }

    public func updateSensors(data: SensorData) {
        print("Updated sensors: \(data.temperature)°C")
    }

    public func generatePacket(type: Int64) async throws -> Packet {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 10)
        return Packet(sequence: 1, buffer: buf, size: 10)
    }

    public var batteryLevel: Double { return 0.85 }
    public var config: String { 
        get { return "default" }
        set { print("Config set: \(newValue)") }
    }

    private let sensorSubject = PassthroughSubject<SensorData, Never>()
    public var sensorStream: AnyPublisher<SensorData, Never> {
        return sensorSubject.eraseToAnyPublisher()
    }

    private let dataSubject = PassthroughSubject<Packet, Never>()
    public var dataStream: AnyPublisher<Packet, Never> {
        return dataSubject.eraseToAnyPublisher()
    }
}
