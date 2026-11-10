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
    private let meter = AudioMeter()
    private let updates = UpdateChecker()
    private let settingsWindow = SettingsWindowController()
    private let installer = SelfUpdater()
    private var lastShownPercent = -1

    private let menu = NSMenu()
    private var controller: IslandController?
    private var statusItem: NSStatusItem?
    private var settingsWatch: AnyCancellable?

    private let toggles: [(title: String, key: ReferenceWritableKeyPath<Settings, Bool>)] = [
        (L("Music (Music, Spotify)"), \.music),
        (L("Music from browser (Safari, Chrome, Brave, Edge, Arc)"), \.web),
        (L("Now Playing from any app (experimental)"), \.anyApp),
        (L("Sound visualizer (screen recording)"), \.reactiveViz),
        (L("Charging & low battery"), \.power),
        (L("Volume"), \.volume),
        (L("Audio devices"), \.devices),
        (L("Expand on hover"), \.expandOnHover),
        (L("Trackpad haptics"), \.haptics),
        (L("Show in fullscreen"), \.showInFullscreen),
        (L("Island on displays without a notch"), \.virtualIsland),
        (L("Check for updates automatically"), \.updateCheck),
        (L("Menu bar icon"), \.menuBarIcon),
    ]
    /// How many leading toggles concern the island's content; the rest concern its behavior.
    private static let contentToggles = 7

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        let controller = IslandController(settings: settings, menu: menu) { [self] in
            let model = IslandModel(settings: settings, media: media, power: power, timer: timer, meter: meter)
            model.openUpdate = { [weak self] in self?.installUpdate() }
            return model
        }
        self.controller = controller

        if let dir = ProcessInfo.processInfo.environment["ISLAND_SNAPSHOT_DIR"] {
            if let primary = controller.primary {
                Snapshots.run(model: primary.model, panel: primary.panel, into: dir)
            }
            return
        }

        timer.onFinish = { [weak self] in self?.controller?.show(.timerDone) }
        power.onAlert = { [weak self] kind in
            guard let self, self.settings.power else { return }
            self.controller?.show(kind)
        }
        audio.onAlert = { [weak self] kind in
            guard let self else { return }
            if case .device = kind {
                if self.settings.devices { self.controller?.show(kind) }
            } else if self.settings.volume {
                self.controller?.show(kind)
            }
        }
        power.start()
        audio.start()
        updates.onPendingChange = { [weak self] release in
            self?.controller?.setPendingUpdate(release?.version)
            self?.updateBadge(release != nil)
        }
        installer.onPhase = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .downloading(let fraction):
                let percent = Int(fraction * 100)
                guard percent != self.lastShownPercent else { return }
                self.lastShownPercent = percent
                self.controller?.show(.updating(percent: percent))
            case .verifying, .installing:
                self.controller?.show(.updating(percent: nil))
            }
        }
        installer.onFailure = { [weak self] message in
            self?.lastShownPercent = -1
            self?.offerReleasePage(title: L("Couldn't install the update"), detail: message)
        }
        updates.onNewVersion = { [weak self] release in
            self?.controller?.show(.update(version: release.version))
            if ProcessInfo.processInfo.environment["ISLAND_TEST_AUTO_INSTALL"] != nil { self?.installUpdate() }
        }

        if ProcessInfo.processInfo.environment["ISLAND_OPEN_SETTINGS"] != nil { openSettings() }

        applySettings()
        settingsWatch = settings.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.applySettings()
        }
    }

    private func applySettings() {
        media.configure(localPlayers: settings.music, web: settings.web, anyApp: settings.anyApp)
        controller?.applyFullscreenBehavior()
        controller?.place()
        settings.updateCheck ? updates.start() : updates.stop()

        if settings.menuBarIcon, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = ["platter.filled.top.iphone", "rectangle.topthird.inset.filled", "capsule.fill"]
                .lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "DynamicIsland") }.first
            item.menu = menu
            statusItem = item
            badge = nil
            updateBadge(hasBadge)
        } else if !settings.menuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: L("Show in the island")))
        for (index, toggle) in toggles.enumerated() {
            if index == Self.contentToggles { menu.addItem(.separator()) }
            let item = NSMenuItem(title: toggle.title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = settings[keyPath: toggle.key] ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let preferences = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(.separator())
        menu.addItem(displaysItem())
        menu.addItem(virtualStyleItem())
        menu.addItem(virtualSizeItem())
        if let release = updates.available {
            let item = NSMenuItem(title: String(format: L("Update available: v%@ — install…"), release.version),
                                  action: #selector(installUpdate), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            let notes = NSMenuItem(title: L("Release notes…"), action: #selector(openUpdate), keyEquivalent: "")
            notes.target = self
            menu.insertItem(notes, at: 1)
            menu.insertItem(.separator(), at: 2)
        }
        let check = NSMenuItem(title: L("Check for updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let login = NSMenuItem(title: L("Launch at login"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit DynamicIsland"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// A green dot on the menu bar icon while there's an update the user hasn't looked at. It's a separate view over
    /// the (template) icon, so the icon itself still follows the menu bar's light/dark appearance.
    private var hasBadge = false
    private var badge: NSView?
    private func updateBadge(_ on: Bool) {
        hasBadge = on
        guard let button = statusItem?.button else { return }
        if badge == nil {
            let dot = NSView(frame: NSRect(x: button.bounds.maxX - 9, y: button.bounds.maxY - 9, width: 7, height: 7))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.layer?.cornerRadius = 3.5
            dot.autoresizingMask = [.minXMargin, .minYMargin]
            button.addSubview(dot)
            badge = dot
        }
        badge?.isHidden = !on
    }

    @objc private func openSettings() {
        settingsWindow.show(settings: settings) { [weak self] in self?.checkForUpdates() }
    }

    @objc private func openUpdate() { updates.openReleasePage() }

    /// Asks, then downloads and installs the new version over this one and restarts.
    @objc private func installUpdate() {
        guard let release = updates.available, !installer.isBusy else { return }
        if let reason = SelfUpdater.blocker(for: release) {
            return offerReleasePage(title: String(format: L("DynamicIsland v%@ is available"), release.version), detail: reason)
        }
        // Test hook: install without asking (used to try the whole update on a copy of the app).
        if ProcessInfo.processInfo.environment["ISLAND_TEST_AUTO_INSTALL"] != nil {
            lastShownPercent = -1
            return installer.install(release)
        }
        let alert = NSAlert()
        alert.messageText = String(format: L("Install DynamicIsland v%@?"), release.version)
        alert.informativeText = L("The update is downloaded from GitHub, checked against its published checksum and replaces this copy; the app then restarts. Your settings are kept. macOS may ask for some permissions again.")
        alert.addButton(withTitle: L("Install and restart"))
        alert.addButton(withTitle: L("Release notes"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            updates.acknowledge()
            lastShownPercent = -1
            installer.install(release)
        case .alertSecondButtonReturn:
            updates.openReleasePage()
        default:
            break
        }
    }

    private func offerReleasePage(title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L("Open release page"))
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { updates.openReleasePage() }
    }

    @objc private func checkForUpdates() {
        updates.check(userInitiated: true) { [weak self] result in
            switch result {
            case .success(.some): self?.installUpdate()    // the island announces it too
            case .success(.none):
                self?.report(L("You're up to date"),
                             String(format: L("DynamicIsland %@ is the latest version."), UpdateChecker.currentVersion))
            case .failure(let error):
                self?.report(L("Couldn't check for updates"), error.localizedDescription)
            }
        }
    }

    private func report(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Displays

    private func displaysItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Show on"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let modes: [(DisplayMode, String)] = [(.auto, L("Automatic (notch display)")),
                                              (.follow, L("Follow the cursor")), (.all, L("All displays"))]
        for (mode, title) in modes {
            let entry = NSMenuItem(title: title, action: #selector(chooseDisplayMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = settings.displayMode == mode ? .on : .off
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        sub.addItem(.sectionHeader(title: L("Only on")))
        for screen in NSScreen.screens {
            let entry = NSMenuItem(title: screen.localizedName, action: #selector(pinDisplay(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = screen.uuid
            entry.state = settings.displayMode == .pinned && settings.pinnedDisplay == screen.uuid ? .on : .off
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    private func virtualStyleItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Without a notch"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let styles: [(VirtualStyle, String)] = [(.hidden, L("Hidden until needed")), (.pill, L("Always visible")),
                                                (.clickPill, L("Always visible, expand on click"))]
        for (style, title) in styles {
            let entry = NSMenuItem(title: title, action: #selector(chooseVirtualStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = style.rawValue
            entry.state = settings.virtualStyle == style ? .on : .off
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    private func virtualSizeItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Size without a notch"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (scale, title) in [(0.0, L("Automatic")), (1.0, "100 %"), (1.25, "125 %"), (1.5, "150 %"), (1.75, "175 %"), (2.0, "200 %")] {
            let entry = NSMenuItem(title: title, action: #selector(chooseVirtualScale(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = scale
            entry.state = settings.virtualScale == scale ? .on : .off
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    @objc private func chooseVirtualScale(_ sender: NSMenuItem) {
        if let scale = sender.representedObject as? Double { settings.virtualScale = scale }
    }

    @objc private func chooseDisplayMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) { settings.displayMode = mode }
    }

    @objc private func pinDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        settings.pinnedDisplay = uuid
        settings.displayMode = .pinned
    }

    @objc private func chooseVirtualStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = VirtualStyle(rawValue: raw) { settings.virtualStyle = style }
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
            alert.messageText = L("Couldn't change launch-at-login")
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
