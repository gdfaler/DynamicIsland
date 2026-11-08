import AppKit
import SwiftUI

/// The island window doesn't take focus away from the app the user is working with.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Don't let the system push the window out from under the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class IslandHostingView: NSHostingView<IslandView> {
    // The island's buttons work on the first click even though the app isn't active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One island on one display: a transparent window over the notch that decides when it catches the mouse.
///
/// The window is always one size — with room for the expanded island — and the island draws and animates inside it.
/// Clicks outside the island pass through the window: it accepts the mouse only while the cursor is over the island.
final class IslandWindow {
    private static let canvas = CGSize(width: 560, height: 320)
    private var canvas: CGSize { CGSize(width: Self.canvas.width * model.scale, height: Self.canvas.height * model.scale) }

    let panel: IslandPanel
    let model: IslandModel
    let displayID: CGDirectDisplayID
    private let host: IslandHostingView
    private var hoverWatch: Timer?

    init(model: IslandModel, displayID: CGDirectDisplayID) {
        self.model = model
        self.displayID = displayID
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.canvas),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        // Above the menu bar and its icons, but below drop-down menus.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

        host = IslandHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host
    }

    func applyFullscreenBehavior() {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if model.settings.showInFullscreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior
    }

    /// Fits the island to this display's notch — measured, so it follows the real size and display scaling —
    /// or to a virtual one on a display without a cutout.
    func place(on screen: NSScreen) {
        let centre: CGFloat
        if let notch = screen.notch {
            model.isVirtual = false
            model.scale = 1
            model.notch = notch.size
            centre = notch.centre
        } else {
            model.isVirtual = true
            model.scale = model.settings.virtualScale > 0 ? CGFloat(model.settings.virtualScale) : screen.autoScale
            model.notch = screen.virtualNotch
            centre = screen.frame.midX
        }
        let frame = NSRect(x: centre - canvas.width / 2, y: screen.frame.maxY - canvas.height,
                           width: canvas.width, height: canvas.height)
        model.canvasWidth = frame.width
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func close() {
        hoverWatch?.invalidate()
        panel.orderOut(nil)
        panel.close()
    }

    // MARK: - Mouse

    /// The island's area in screen coordinates, with a small margin so it doesn't collapse on a shaky hand.
    private var islandRect: CGRect {
        let layout = model.layout
        let scale = model.scale
        let margin: CGFloat = layout.isExpanded ? 10 : 3
        let frame = panel.frame
        let width = layout.width * scale, height = layout.height * scale
        return CGRect(x: frame.midX - width / 2 - margin, y: frame.maxY - height - margin,
                      width: width + 2 * margin, height: height + margin + 4)
    }

    func pointerMoved() {
        guard panel.isVisible else { return }
        // A display that doesn't carry the island lets everything through.
        guard model.isShown else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            if model.isHovering { model.pointerExited() }
            return
        }
        let inside = islandRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        guard inside != model.isHovering else { return }
        if inside {
            model.pointerEntered()
            watchHover()
        } else {
            model.pointerExited()
        }
    }

    /// The island also resizes under a still cursor, with no mouse events then — while it's under the cursor
    /// or expanded, the position is re-checked on a timer.
    private func watchHover() {
        guard hoverWatch == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.pointerMoved()
            if !self.model.isHovering && !self.model.isExpanded {
                timer.invalidate()
                self.hoverWatch = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverWatch = timer
    }
}

/// Keeps an island window on every display and decides which of them carries the island, per the "show on" mode:
/// the notch display (or the main one), the display under the cursor, every display, or a pinned one.
/// Windows of displays that don't carry it are invisible; the island grows out of the notch on the one that does.
final class IslandController {
    private let settings: Settings
    private let makeModel: () -> IslandModel
    private let menu: NSMenu
    private var windows: [CGDirectDisplayID: IslandWindow] = [:]
    private var monitors: [Any] = []
    /// The display the island follows in `.follow` mode, and the one it's about to move to.
    private var followed: CGDirectDisplayID?
    private var pendingFollow: (id: CGDirectDisplayID, work: DispatchWorkItem)?

    /// The window to show in snapshots: the one carrying the island.
    var primary: IslandWindow? { windows.values.first { $0.model.isShown } ?? windows.values.first }

    init(settings: Settings, menu: NSMenu, makeModel: @escaping () -> IslandModel) {
        self.settings = settings
        self.menu = menu
        self.makeModel = makeModel

        place()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.place() }

        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // While the app isn't active, mouse movements only reach the global monitor.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            self?.pointerMoved()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved()
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] event in
            self?.showMenu(for: event) == true ? nil : event
        }) { monitors.append(monitor) }
    }

    func applyFullscreenBehavior() {
        windows.values.forEach { $0.applyFullscreenBehavior() }
    }

    /// An alert goes to every display's island; only the visible ones show it.
    func show(_ kind: IslandAlert.Kind) {
        windows.values.forEach { $0.model.show(kind) }
    }

    /// Matches the windows to the connected displays, fits each to its notch and re-decides which carries the island.
    func place() {
        let screens = NSScreen.screens
        let present = Set(screens.map(\.displayID))
        for id in windows.keys where !present.contains(id) {
            windows.removeValue(forKey: id)?.close()
        }
        for screen in screens {
            let window = windows[screen.displayID] ?? {
                let window = IslandWindow(model: makeModel(), displayID: screen.displayID)
                window.applyFullscreenBehavior()
                windows[screen.displayID] = window
                return window
            }()
            window.place(on: screen)
        }
        refreshActive()
    }

    private func refreshActive() {
        let active = activeDisplays()
        for (id, window) in windows { window.model.setShown(active.contains(id)) }
    }

    private func activeDisplays() -> Set<CGDirectDisplayID> {
        let screens = NSScreen.screens.filter { $0.notch != nil || settings.virtualIsland }
        guard !screens.isEmpty else { return [] }
        let usual = (screens.first { $0.notch != nil } ?? screens[0]).displayID
        switch settings.displayMode {
        case .auto:
            return [usual]
        case .all:
            return Set(screens.map(\.displayID))
        case .pinned:
            return [screens.first { $0.uuid == settings.pinnedDisplay }?.displayID ?? usual]
        case .follow:
            let ids = Set(screens.map(\.displayID))
            if let followed, ids.contains(followed) { return [followed] }
            let underCursor = Self.screenUnderCursor()?.displayID
            followed = underCursor.flatMap { ids.contains($0) ? $0 : nil } ?? usual
            return [followed!]
        }
    }

    private static func screenUnderCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }

    // MARK: - Mouse

    private func pointerMoved() {
        windows.values.forEach { $0.pointerMoved() }
        followCursor()
    }

    /// In `.follow` mode the island moves to the display the cursor has settled on — after a short pause, so a
    /// pass across a display doesn't drag it along, and never while it's expanded or showing an alert.
    private func followCursor() {
        guard settings.displayMode == .follow, let target = Self.screenUnderCursor() else { return }
        let id = target.displayID
        guard id != followed, target.notch != nil || settings.virtualIsland else {
            pendingFollow?.work.cancel()
            pendingFollow = nil
            return
        }
        guard pendingFollow?.id != id else { return }
        pendingFollow?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFollow = nil
            let busy = self.windows.values.contains { $0.model.isExpanded || $0.model.alert != nil }
            guard !busy, Self.screenUnderCursor()?.displayID == id else { return }
            self.followed = id
            self.refreshActive()
        }
        pendingFollow = (id, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func showMenu(for event: NSEvent) -> Bool {
        guard let window = windows.values.first(where: { $0.panel === event.window }),
              let view = window.panel.contentView else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return true
    }
}
