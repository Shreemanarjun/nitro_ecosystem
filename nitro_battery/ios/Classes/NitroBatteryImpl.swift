import UIKit
import Combine

public class NitroBatteryImpl: NSObject, HybridNitroBatteryProtocol {

    // Enable battery monitoring on init
    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    deinit {
        UIDevice.current.isBatteryMonitoringEnabled = false
        _timer?.invalidate()
    }

    // ── Synchronous ──────────────────────────────────────────────────────────

    public func getBatteryLevel() -> Int64 {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return -1 }
        return Int64(level * 100)
    }

    public func isCharging() -> Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }

    public func getChargingState() -> Int64 {
        switch UIDevice.current.batteryState {
        case .charging:    return 1 // ChargingState.charging
        case .full:        return 3 // ChargingState.full
        case .unplugged:   return 2 // ChargingState.discharging
        default:           return 0 // ChargingState.unknown
        }
    }

    // ── Async ────────────────────────────────────────────────────────────────

    public func getBatteryInfo() async throws -> BatteryInfo {
        let level = getBatteryLevel()
        let state = getChargingState()
        // UIDevice doesn't expose voltage/temp; use sentinel values
        return BatteryInfo(level: level, chargingState: state, voltage: 0.0, temperature: 0.0)
    }

    // ── Stream ───────────────────────────────────────────────────────────────

    private let _levelSubject = PassthroughSubject<Int64, Never>()
    private var _timer: Timer?

    public var batteryLevelChanges: AnyPublisher<Int64, Never> {
        if _timer == nil {
            _timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self._levelSubject.send(self.getBatteryLevel())
            }
            // Also emit immediately on subscribe via NotificationCenter
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?._levelSubject.send(self?.getBatteryLevel() ?? -1)
            }
        }
        return _levelSubject.eraseToAnyPublisher()
    }

    // ── Properties ───────────────────────────────────────────────────────────

    public var lowPowerThreshold: Int64 = 20
}
