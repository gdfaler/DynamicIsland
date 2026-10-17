// What's playing, and playback control — using documented facilities only, without the system's locked-down
// "Now Playing". The island combines several sources:
//   • Music and Spotify — their own AppleScript interfaces (and they post a notification on track change);
//   • Safari — the public "do JavaScript", reading from the tab whatever the page exposes
//     (navigator.mediaSession and <video>/<audio> tags), which catches YouTube and other web audio.
// The one that started playing most recently becomes active. The island never launches an app itself.
// The sources need Automation permission (macOS will ask), and Safari additionally needs
// "Develop → Allow JavaScript from Apple Events".

import AppKit
import Combine

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    /// Position as of `stamp`; from there it is extrapolated from the clock, so the player isn't polled every second.
    var elapsed: TimeInterval
    var stamp: Date
    var isPlaying: Bool
    /// Artwork URL (Spotify, web) — stays empty when the artwork arrives as an image instead.
    var artworkURL: String = ""

    var id: String { [title, artist, album].joined(separator: "\u{1}") }

    func position(at date: Date = Date()) -> TimeInterval {
        let raw = isPlaying ? elapsed + date.timeIntervalSince(stamp) : elapsed
        return duration > 0 ? min(max(raw, 0), duration) : max(raw, 0)
    }
}

/// A single audio source: knows how to report the current track and control itself.
protocol MediaSource: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var icon: NSImage? { get }
    var track: Track? { get }
    /// Whether forward/back buttons make sense (a web player has none).
    var canSkip: Bool { get }
    /// A hint when the source is enabled but something is missing (Automation not granted, etc.).
    var hint: String? { get }
    /// The source calls this whenever its state changes.
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
    func togglePlayPause()
    func next()
    func previous()
    func seek(to position: TimeInterval)
    func activate()
    func loadArtwork(for track: Track, completion: @escaping (NSImage?) -> Void)
}

/// Gathers all the sources and shows the island the one that's currently in charge.
final class NowPlaying: ObservableObject {
    /// How long a paused track stays visible in the collapsed island.
    private static let pauseLinger: TimeInterval = 30

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    /// Equalizer bar color — the average color of the artwork.
    @Published private(set) var accent = NSColor.white
    /// Whether to show the track in the collapsed island.
    @Published private(set) var isLive = false
    /// Name and icon of the app that's currently playing.
    @Published private(set) var activeName = "Music"
    @Published private(set) var activeIcon: NSImage?
    @Published private(set) var canSkip = true
    /// Hint about the current track (e.g. control not permitted).
    @Published private(set) var hint: String?
    /// Setup hint when a source is enabled but not reporting anything yet.
    @Published private(set) var setupHint: String?
    /// Position while the user is dragging the scrubber.
    @Published var scrubPosition: TimeInterval?

    private let music = ScriptablePlayer(.music)
    private let spotify = ScriptablePlayer(.spotify)
    private let browser = BrowserSource()
    private var sources: [MediaSource] = []

    private var active: MediaSource?
    private var startedPlaying: [String: Date] = [:]
    private var wasPlaying: [String: Bool] = [:]
    private var shownTrackID: String?
    private var lingerEnd: DispatchWorkItem?

    init() {
        sources = [music, spotify, browser]
        for source in sources {
            source.onChange = { [weak self] in self?.recompute() }
        }
    }

    /// Enables the desired sources: local players and/or the web.
    func configure(localPlayers: Bool, web: Bool) {
        music.setRunning(localPlayers)
        spotify.setRunning(localPlayers)
        browser.setRunning(web)
        recompute()
    }

    // MARK: - Choosing the active source

    private func recompute() {
        for source in sources {
            let playing = source.track?.isPlaying ?? false
            if playing && !(wasPlaying[source.id] ?? false) { startedPlaying[source.id] = Date() }
            wasPlaying[source.id] = playing
        }
        let playing = sources.filter { $0.track?.isPlaying == true }
        let chosen: MediaSource?
        if let active, active.track?.isPlaying == true {
            // Don't interrupt the current source while it's playing — otherwise the island flickers.
            chosen = active
        } else if !playing.isEmpty {
            // Something new started — show the most recently started one, like on iPhone.
            chosen = playing.max { (startedPlaying[$0.id] ?? .distantPast) < (startedPlaying[$1.id] ?? .distantPast) }
        } else if let active, active.track != nil {
            // Nothing is playing, but the previous source is paused — stay on it.
            chosen = active
        } else {
            chosen = sources.first { $0.track != nil }
        }
        active = chosen

        activeName = chosen?.displayName ?? "Music"
        activeIcon = chosen?.icon
        canSkip = chosen?.canSkip ?? true
        hint = chosen?.track != nil ? chosen?.hint : nil
        setupHint = sources.first { $0.track == nil && $0.hint != nil }?.hint

        let shown = chosen?.track
        if shown?.id != shownTrackID {
            shownTrackID = shown?.id
            if let shown, let chosen {
                if let url = URL(string: shown.artworkURL), !shown.artworkURL.isEmpty {
                    loadRemoteArtwork(url, for: shown.id)
                } else {
                    chosen.loadArtwork(for: shown) { [weak self] image in
                        guard let self, self.shownTrackID == shown.id else { return }
                        self.setArtwork(image)
                    }
                }
            } else {
                setArtwork(nil)
            }
        }
        present(shown)
    }

    // MARK: - State (also used by the layout snapshots)

    func present(_ new: Track?) {
        if new?.id != track?.id { scrubPosition = nil }
        track = new
        lingerEnd?.cancel()
        guard let new else {
            artwork = nil
            shownTrackID = nil
            accent = .white
            isLive = false
            return
        }
        if new.isPlaying {
            isLive = true
        } else if isLive {
            let item = DispatchWorkItem { [weak self] in self?.isLive = false }
            lingerEnd = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseLinger, execute: item)
        }
    }

    func setArtwork(_ image: NSImage?) {
        artwork = image
        accent = image.flatMap(Self.accentColor) ?? .white
    }

    private func loadRemoteArtwork(_ url: URL, for trackID: String) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self, self.shownTrackID == trackID else { return }
                self.setArtwork(image)
            }
        }.resume()
    }

    // MARK: - Control (goes to the active source)

    func togglePlayPause() {
        guard let active, var current = active.track else { return }
        // The button responds immediately, without waiting for the player's reply.
        current.elapsed = current.position()
        current.stamp = Date()
        current.isPlaying.toggle()
        present(current)
        active.togglePlayPause()
    }

    func next() { active?.next() }
    func previous() { active?.previous() }

    func seek(to position: TimeInterval) {
        guard let active, var current = active.track else { return }
        current.elapsed = position
        current.stamp = Date()
        present(current)
        active.seek(to: position)
    }

    func openPlayer() { active?.activate() }

    // MARK: - Artwork color

    private static func accentColor(of image: NSImage) -> NSColor? {
        let side = 12
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        for index in 0..<(side * side) {
            sum.r += Double(pixels[index * 4])
            sum.g += Double(pixels[index * 4 + 1])
            sum.b += Double(pixels[index * 4 + 2])
        }
        let scale = 255.0 * Double(side * side)
        let average = NSColor(srgbRed: sum.r / scale, green: sum.g / scale, blue: sum.b / scale, alpha: 1)
        var (hue, saturation, brightness, alpha) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // A dark color is invisible on the black island — pull the brightness up.
        return NSColor(hue: hue, saturation: min(saturation * 1.25, 0.8), brightness: max(brightness, 0.9), alpha: 1)
    }
}
