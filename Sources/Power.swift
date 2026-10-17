import Foundation
import Combine
import IOKit.ps

/// Battery charge and AC power. The system reports changes itself; there's no polling.
final class PowerMonitor: ObservableObject {
    /// Thresholds that, when crossed downward, make the island warn about low battery.
    private static let lowLevels = [20, 10, 5]

    @Published private(set) var percent = 100
    @Published private(set) var isPluggedIn = false
    @Published private(set) var hasBattery = false

    var onAlert: ((IslandAlert.Kind) -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        read(announce: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().read(announce: true)
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    private func read(announce: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for item in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let capacity = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let full = max(info[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let level = min(max(Int((Double(capacity) / Double(full) * 100).rounded()), 0), 100)
            let plugged = info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue

            let (oldLevel, wasPlugged) = (percent, isPluggedIn)
            if percent != level { percent = level }
            if isPluggedIn != plugged { isPluggedIn = plugged }
            if !hasBattery { hasBattery = true }
            guard announce else { return }
            if plugged && !wasPlugged {
                onAlert?(.charging(percent: level))
            } else if !plugged, Self.lowLevels.contains(where: { oldLevel > $0 && level <= $0 }) {
                onAlert?(.lowBattery(percent: level))
            }
            return
        }
    }
}
