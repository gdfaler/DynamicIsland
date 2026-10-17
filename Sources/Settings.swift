import Foundation
import Combine

/// Settings from the island's menu. Stored in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var music: Bool { didSet { defaults.set(music, forKey: "music") } }
    @Published var web: Bool { didSet { defaults.set(web, forKey: "web") } }
    @Published var reactiveViz: Bool { didSet { defaults.set(reactiveViz, forKey: "reactiveViz") } }
    @Published var power: Bool { didSet { defaults.set(power, forKey: "power") } }
    @Published var volume: Bool { didSet { defaults.set(volume, forKey: "volume") } }
    @Published var devices: Bool { didSet { defaults.set(devices, forKey: "devices") } }
    @Published var expandOnHover: Bool { didSet { defaults.set(expandOnHover, forKey: "expandOnHover") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var showInFullscreen: Bool { didSet { defaults.set(showInFullscreen, forKey: "showInFullscreen") } }
    @Published var menuBarIcon: Bool { didSet { defaults.set(menuBarIcon, forKey: "menuBarIcon") } }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "music": true, "web": true, "reactiveViz": true, "power": true, "volume": true, "devices": true,
            "expandOnHover": true, "haptics": true, "showInFullscreen": true, "menuBarIcon": true,
        ])
        music = defaults.bool(forKey: "music")
        web = defaults.bool(forKey: "web")
        reactiveViz = defaults.bool(forKey: "reactiveViz")
        power = defaults.bool(forKey: "power")
        volume = defaults.bool(forKey: "volume")
        devices = defaults.bool(forKey: "devices")
        expandOnHover = defaults.bool(forKey: "expandOnHover")
        haptics = defaults.bool(forKey: "haptics")
        showInFullscreen = defaults.bool(forKey: "showInFullscreen")
        menuBarIcon = defaults.bool(forKey: "menuBarIcon")
    }
}
