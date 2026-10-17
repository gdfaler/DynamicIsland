import Foundation
import CoreAudio

/// Watches the volume and output-device changes (headphones or a speaker plugged in).
/// CoreAudio reports the changes itself; no permission is needed for this.
final class AudioMonitor {
    /// 'vmvc' — the device's main volume, the one the keys change.
    private static let mainVolume: AudioObjectPropertySelector = 0x766D_7663

    var onAlert: ((IslandAlert.Kind) -> Void)?

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var attached: Set<AudioObjectID> = []
    private var last: (level: Float32, muted: Bool)?
    /// When the device changes the volume "changes" on its own — don't show that event.
    private var quietUntil = Date.distantPast

    func start() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &address, .main) { [weak self] _, _ in self?.attach(announce: true) }
        attach(announce: false)
    }

    private func attach(announce: Bool) {
        let current = read(system, Self.address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(kAudioObjectUnknown))
        guard current != kAudioObjectUnknown, current != device else { return }
        device = current
        // Listeners on previous devices aren't removed — their events are filtered out by comparing to the current device.
        if attached.insert(current).inserted {
            for selector in [Self.mainVolume, kAudioDevicePropertyMute] {
                var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput)
                guard AudioObjectHasProperty(current, &address) else { continue }
                AudioObjectAddPropertyListenerBlock(current, &address, .main) { [weak self] _, _ in
                    self?.volumeChanged(on: current)
                }
            }
        }
        last = volume()
        guard announce else { return }
        quietUntil = Date().addingTimeInterval(1)
        onAlert?(.device(name: name(of: current), symbol: symbol(for: current)))
    }

    private func volumeChanged(on source: AudioObjectID) {
        guard source == device else { return }
        let new = volume()
        guard new.level != last?.level || new.muted != last?.muted else { return }
        last = new
        guard Date() > quietUntil else { return }
        onAlert?(.volume(level: Double(new.level), muted: new.muted || new.level == 0))
    }

    private func volume() -> (level: Float32, muted: Bool) {
        let level = read(device, Self.address(Self.mainVolume, scope: kAudioDevicePropertyScopeOutput), Float32(0))
        let muted = read(device, Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), UInt32(0))
        return (level, muted != 0)
    }

    private func name(of device: AudioObjectID) -> String {
        let name = read(device, Self.address(kAudioObjectPropertyName), Unmanaged<CFString>?.none)
        return name?.takeRetainedValue() as String? ?? "Audio device"
    }

    private func symbol(for device: AudioObjectID) -> String {
        let name = name(of: device).lowercased()
        switch read(device, Self.address(kAudioDevicePropertyTransportType), UInt32(0)) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return name.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        default:
            return "hifispeaker.fill"
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func read<Value>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ fallback: Value) -> Value {
        var address = address
        var size = UInt32(MemoryLayout<Value>.size)
        var value = fallback
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : fallback
    }
}
