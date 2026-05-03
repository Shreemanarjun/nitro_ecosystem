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
        guard level >= 0 else {
#if targetEnvironment(simulator)
            return _simulatedLevel
#else
            return -1
#endif
        }
        return Int64(level * 100)
    }

    public func isCharging() -> Bool {
        let state = UIDevice.current.batteryState
        guard state != .unknown else {
#if targetEnvironment(simulator)
            return false
#else
            return false
#endif
        }
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

#if targetEnvironment(simulator)
    // Simulate a slowly draining battery on the simulator for demo purposes.
    private var _simulatedLevel: Int64 = 85

    private func _startSimulatorTimer() {
        guard _timer == nil else { return }
        _timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self._simulatedLevel = max(0, self._simulatedLevel - 1)
            self._levelSubject.send(self._simulatedLevel)
        }
        // Emit initial value immediately
        _levelSubject.send(_simulatedLevel)
    }
#endif

    public var batteryLevelChanges: AnyPublisher<Int64, Never> {
#if targetEnvironment(simulator)
        _startSimulatorTimer()
#else
        if _timer == nil {
            _timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self._levelSubject.send(self.getBatteryLevel())
            }
            NotificationCenter.default.addObserver(
                forName: UIDevice.batteryLevelDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?._levelSubject.send(self?.getBatteryLevel() ?? -1)
            }
        }
#endif
        return _levelSubject.eraseToAnyPublisher()
    }

    // ── Properties ───────────────────────────────────────────────────────────

    public var lowPowerThreshold: Int64 = 20
}
