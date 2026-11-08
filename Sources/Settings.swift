import Foundation
import Combine

/// Which display(s) show the island.
enum DisplayMode: String, CaseIterable {
    case auto, follow, all, pinned
}

/// How the island looks on a display without a notch.
enum VirtualStyle: String, CaseIterable {
    /// Invisible at rest; appears with activity or when the cursor comes near. Expands on hover.
    case hidden
    /// A pill that's always there. Expands on hover.
    case pill
    /// A pill that's always there. Expands only on click.
    case clickPill
}

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
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") } }
    /// UUID of the display the island is pinned to (`DisplayMode.pinned`).
    @Published var pinnedDisplay: String { didSet { defaults.set(pinnedDisplay, forKey: "pinnedDisplay") } }
    @Published var virtualStyle: VirtualStyle { didSet { defaults.set(virtualStyle.rawValue, forKey: "virtualStyle") } }
    /// Size of the island on displays without a notch; 0 = automatic, by the display's width.
    @Published var virtualScale: Double { didSet { defaults.set(virtualScale, forKey: "virtualScale") } }
    @Published var virtualIsland: Bool { didSet { defaults.set(virtualIsland, forKey: "virtualIsland") } }
    @Published var menuBarIcon: Bool { didSet { defaults.set(menuBarIcon, forKey: "menuBarIcon") } }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "music": true, "web": true, "reactiveViz": true, "power": true, "volume": true, "devices": true,
            "expandOnHover": true, "haptics": true, "showInFullscreen": true, "menuBarIcon": true, "virtualIsland": true,
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
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .auto
        pinnedDisplay = defaults.string(forKey: "pinnedDisplay") ?? ""
        virtualStyle = VirtualStyle(rawValue: defaults.string(forKey: "virtualStyle") ?? "") ?? .hidden
        virtualScale = defaults.double(forKey: "virtualScale")
        virtualIsland = defaults.bool(forKey: "virtualIsland")
        menuBarIcon = defaults.bool(forKey: "menuBarIcon")
    }
}
