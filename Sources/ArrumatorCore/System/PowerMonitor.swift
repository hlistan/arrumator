import Foundation
import IOKit.ps

public struct PowerState: Sendable, Hashable, Codable {
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool

    public static func current() -> PowerState {
        var onBattery = false
        var percent: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMBatteryPowerKey
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for source in sources {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                percent = current * 100 / max
            }
        }
        return PowerState(onBattery: onBattery, batteryPercent: percent, thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
                          lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Reason to postpone background work, or nil to proceed.
    public func pauseReason(settings: AppSettings, config: PowerConfig) -> String? {
        if thermal.rank >= config.pauseAtThermalState.rank { return "thermal state \(thermal.rawValue)" }
        if settings.pauseOnBattery, onBattery, let p = batteryPercent, p < config.pauseBelowBatteryPercent {
            return "battery at \(p)%"
        }
        return nil
    }
}
