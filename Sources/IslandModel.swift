import AppKit
import Combine

/// A brief alert: the island stretches sideways for a couple of seconds and shows it beside the notch.
struct IslandAlert: Equatable {
    enum Kind: Equatable {
        case charging(percent: Int)
        case lowBattery(percent: Int)
        case volume(level: Double, muted: Bool)
        case device(name: String, symbol: String)
        case timerDone
        case update(version: String)
    }

    var kind: Kind

    /// Same for events of one kind: volume updates in place instead of reappearing.
    var slot: Int {
        switch kind {
        case .charging: return 0
        case .lowBattery: return 1
        case .volume: return 2
        case .device: return 3
        case .timerDone: return 4
        case .update: return 5
        }
    }

    /// Width of the "ear" — the part of the island beside the notch.
    var earWidth: CGFloat {
        switch kind {
        case .charging: return 82
        case .lowBattery: return 98
        case .volume: return 84
        case .device(let name, _):
            let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            let width = (name as NSString).size(withAttributes: [.font: font]).width
            return min(max(ceil(width), 30), 128) + 18
        case .timerDone: return 76
        case .update: return 96
        }
    }

    var duration: TimeInterval {
        switch kind {
        case .volume: return 1.6
        case .timerDone: return 6
        case .update: return 9
        default: return 3
        }
    }
}

enum Presentation: Equatable {
    case idle
    case compact
    case alert(IslandAlert)
    case expanded
}

struct IslandLayout: Equatable {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    /// Concave transition at the top sides (0 = straight vertical walls).
    var topFillet: CGFloat
    var isExpanded: Bool
}

/// What the island is showing right now and how big it is.
final class IslandModel: ObservableObject {
    static let expandedWidth: CGFloat = 420

    let settings: Settings
    let media: NowPlaying
    let power: PowerMonitor
    let timer: CountdownTimer
    /// Sound level for the visualizer — capture turns on only while something is playing.
    let meter: AudioMeter

    /// Size of the camera cutout on the built-in display.
    @Published var notch = CGSize(width: 179, height: 32)
    /// True when there's no physical cutout and the island sits on a virtual one (invisible at rest).
    @Published var isVirtual = false
    /// Enlargement of the whole island (1 on a real notch).
    @Published var scale: CGFloat = 1
    /// Width of the island's window, to place the island on a whole pixel.
    var canvasWidth: CGFloat = 560
    /// Whether this display currently carries the island (per the "show on" mode).
    @Published private(set) var isShown = true
    @Published private(set) var isExpanded = false
    @Published private(set) var isHovering = false
    @Published private(set) var alert: IslandAlert?

    /// A release the user hasn't opened yet: the expanded island shows a chip for it.
    @Published var pendingUpdate: String?
    /// Opens the release page; set by the app. A tap on an "update available" alert calls it.
    var openUpdate: (() -> Void)?

    private var subscriptions: Set<AnyCancellable> = []
    private var pendingExpansion: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var pendingDismissal: DispatchWorkItem?

    init(settings: Settings, media: NowPlaying, power: PowerMonitor, timer: CountdownTimer, meter: AudioMeter) {
        self.settings = settings
        self.meter = meter
        self.media = media
        self.power = power
        self.timer = timer
        // The island's size depends on both the player and the timer — their changes redraw the whole island.
        for source in [settings.objectWillChange, media.objectWillChange, power.objectWillChange, timer.objectWillChange] {
            source.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        // Keep audio capture on only while a track is actually playing and the visualizer is enabled in settings.
        for source in [media.objectWillChange, settings.objectWillChange] {
            source.sink { [weak self] _ in DispatchQueue.main.async { self?.syncMeter() } }.store(in: &subscriptions)
        }
    }

    private func syncMeter() {
        meter.setActive(settings.reactiveViz && media.track?.isPlaying == true)
    }

    // MARK: - State

    // The island enables sources per settings, so the track already reflects them — no need to re-check.
    var showsMusic: Bool { media.track != nil }
    var musicIsLive: Bool { media.isLive }

    /// How far the island drops below the notch. 0 = flush with it (the straight top already removed the earlier
    /// mismatch), so it blends with the notch at rest and doesn't cover windows in fullscreen.
    static let drop: CGFloat = 0

    var presentation: Presentation {
        if isExpanded { return .expanded }
        if let alert { return .alert(alert) }
        if musicIsLive || timer.isActive { return .compact }
        return .idle
    }

    /// 0 = the island isn't drawn (not on this display, or resting invisibly on a virtual notch), 1 = fully there.
    var visibility: Double {
        guard isShown else { return 0 }
        if isVirtual, settings.virtualStyle == .hidden, presentation == .idle, !isHovering { return 0 }
        return 1
    }

    /// On a "click" pill the island never expands under the cursor.
    private var hoverExpands: Bool {
        settings.expandOnHover && !(isVirtual && settings.virtualStyle == .clickPill)
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if !shown {
            pendingExpansion?.cancel()
            collapse()
        }
    }

    var expandedHeight: CGFloat {
        notch.height + (showsMusic ? MusicPanel.height : ClockPanel.height) + TimerPanel.height
    }

    var layout: IslandLayout {
        // Under the cursor the island grows slightly — like the press response on iPhone.
        let lift: CGFloat = isHovering ? 1 : 0
        let base = notch.height + Self.drop
        switch presentation {
        case .expanded:
            return IslandLayout(width: Self.expandedWidth, height: expandedHeight,
                                bottomRadius: 26, topFillet: 0, isExpanded: true)
        case .alert(let alert):
            return IslandLayout(width: notch.width + 2 * alert.earWidth + 8 * lift, height: base + 3 * lift,
                                bottomRadius: 13, topFillet: 0, isExpanded: false)
        case .compact:
            let ear: CGFloat = timer.isActive ? 54 : 36
            return IslandLayout(width: notch.width + 2 * ear + 8 * lift, height: base + 3 * lift,
                                bottomRadius: 13, topFillet: 0, isExpanded: false)
        case .idle:
            // Exactly the notch width and a touch below it — at rest it blends with the notch.
            return IslandLayout(width: notch.width + 16 * lift, height: base + 4 * lift,
                                bottomRadius: 10, topFillet: 0, isExpanded: false)
        }
    }

    // MARK: - Cursor

    func pointerEntered() {
        guard !isHovering else { return }
        isHovering = true
        pendingCollapse?.cancel()
        guard !isExpanded else { return }
        haptic(.alignment)
        if hoverExpands {
            schedule(&pendingExpansion, after: 0.28) { [weak self] in self?.expand() }
        }
    }

    func pointerExited() {
        guard isHovering else { return }
        isHovering = false
        pendingExpansion?.cancel()
        if isExpanded {
            schedule(&pendingCollapse, after: 0.35) { [weak self] in self?.collapse() }
        }
    }

    /// A tap on the island: an "update" alert opens the release page, anything else expands the island.
    func tapped() {
        if case .update = alert?.kind {
            alert = nil
            pendingDismissal?.cancel()
            openUpdate?()
        } else {
            expand()
        }
    }

    func expand() {
        pendingExpansion?.cancel()
        guard !isExpanded else { return }
        isExpanded = true
        haptic(.levelChange)
    }

    func collapse() {
        pendingCollapse?.cancel()
        isExpanded = false
    }

    // MARK: - Alerts

    func show(_ kind: IslandAlert.Kind) {
        let alert = IslandAlert(kind: kind)
        self.alert = alert
        schedule(&pendingDismissal, after: alert.duration) { [weak self] in self?.alert = nil }
    }

    private func schedule(_ slot: inout DispatchWorkItem?, after delay: TimeInterval, _ action: @escaping () -> Void) {
        slot?.cancel()
        let item = DispatchWorkItem(block: action)
        slot = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard settings.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
