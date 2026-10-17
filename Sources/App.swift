// DynamicIsland — turns the MacBook notch into an iPhone-style dynamic island.
//
//  At rest the island hides behind the camera cutout. When there is something to show, it stretches sideways:
//    • a track playing in Music — artwork on the left, equalizer on the right;
//    • a running timer — the remaining time;
//    • charger plugged in, battery low, volume or output device changed — a brief alert.
//  Hovering the cursor (or clicking) expands the island into a panel with the player, clock and timer.
//  Settings live in the menu bar icon or the right-click menu on the island.
//
//  Build:  ./build.sh   (requires Command Line Tools: xcode-select --install)
//  Needs no permissions up front, except one: on the first track macOS asks whether it may control Music.

import AppKit
import Combine
import ServiceManagement

@main
enum DynamicIslandApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // No Dock icon and no menu bar of its own.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let media = NowPlaying()
    private let power = PowerMonitor()
    private let audio = AudioMonitor()
    private let timer = CountdownTimer()
    private lazy var model = IslandModel(settings: settings, media: media, power: power, timer: timer)

    private let menu = NSMenu()
    private var controller: IslandController?
    private var statusItem: NSStatusItem?
    private var settingsWatch: AnyCancellable?

    private let toggles: [(title: String, key: ReferenceWritableKeyPath<Settings, Bool>)] = [
        ("Music (Music, Spotify)", \.music),
        ("Music from browser (Safari)", \.web),
        ("Sound visualizer (screen recording)", \.reactiveViz),
        ("Charging & low battery", \.power),
        ("Volume", \.volume),
        ("Audio devices", \.devices),
        ("Expand on hover", \.expandOnHover),
        ("Trackpad haptics", \.haptics),
        ("Show in fullscreen", \.showInFullscreen),
        ("Menu bar icon", \.menuBarIcon),
    ]
    /// How many leading toggles concern the island's content; the rest concern its behavior.
    private static let contentToggles = 6

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        let controller = IslandController(model: model, menu: menu)
        self.controller = controller

        if let dir = ProcessInfo.processInfo.environment["ISLAND_SNAPSHOT_DIR"] {
            Snapshots.run(model: model, panel: controller.panel, into: dir)
            return
        }

        timer.onFinish = { [weak self] in self?.model.show(.timerDone) }
        power.onAlert = { [weak self] kind in
            guard let self, self.settings.power else { return }
            self.model.show(kind)
        }
        audio.onAlert = { [weak self] kind in
            guard let self else { return }
            if case .device = kind {
                if self.settings.devices { self.model.show(kind) }
            } else if self.settings.volume {
                self.model.show(kind)
            }
        }
        power.start()
        audio.start()

        applySettings()
        settingsWatch = settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.applySettings()
        }
    }

    private func applySettings() {
        media.configure(localPlayers: settings.music, web: settings.web)
        controller?.applyFullscreenBehavior()

        if settings.menuBarIcon, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = ["platter.filled.top.iphone", "rectangle.topthird.inset.filled", "capsule.fill"]
                .lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "DynamicIsland") }.first
            item.menu = menu
            statusItem = item
        } else if !settings.menuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Show in the island"))
        for (index, toggle) in toggles.enumerated() {
            if index == Self.contentToggles { menu.addItem(.separator()) }
            let item = NSMenuItem(title: toggle.title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = settings[keyPath: toggle.key] ? .on : .off
            menu.addItem(item)
        }
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DynamicIsland", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        settings[keyPath: toggles[sender.tag].key].toggle()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change launch-at-login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
