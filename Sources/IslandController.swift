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

/// Keeps a transparent window over the notch and decides when it catches the mouse.
///
/// The window is always one size — with room for the expanded island — and the island draws and animates inside it.
/// Clicks outside the island pass through the window: it accepts the mouse only while the cursor is over the island.
final class IslandController {
    private static let canvas = CGSize(width: 560, height: 320)

    let panel: IslandPanel
    private let model: IslandModel
    private let menu: NSMenu
    private var monitors: [Any] = []
    private var hoverWatch: Timer?

    init(model: IslandModel, menu: NSMenu) {
        self.model = model
        self.menu = menu
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

        let host = IslandHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host

        applyFullscreenBehavior()
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
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if model.settings.showInFullscreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior
    }

    /// Places the window on the screen with the notch; if there's no such screen (lid closed), the island hides.
    private func place() {
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0,
                  let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
                  right.minX > left.maxX else { continue }
            model.notch = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            let centre = (left.maxX + right.minX) / 2
            panel.setFrame(NSRect(x: centre - Self.canvas.width / 2, y: screen.frame.maxY - Self.canvas.height,
                                  width: Self.canvas.width, height: Self.canvas.height), display: true)
            panel.orderFrontRegardless()
            return
        }
        panel.orderOut(nil)
    }

    // MARK: - Mouse

    /// The island's area in screen coordinates, with a small margin so it doesn't collapse on a shaky hand.
    private var islandRect: CGRect {
        let layout = model.layout
        let margin: CGFloat = layout.isExpanded ? 10 : 3
        let frame = panel.frame
        return CGRect(x: frame.midX - layout.width / 2 - margin, y: frame.maxY - layout.height - margin,
                      width: layout.width + 2 * margin, height: layout.height + margin + 4)
    }

    private func pointerMoved() {
        guard panel.isVisible else { return }
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

    private func showMenu(for event: NSEvent) -> Bool {
        guard event.window === panel, let view = panel.contentView else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return true
    }
}
