// Audio sources: local players through their AppleScript, and Safari through the public "do JavaScript".
// Everything uses documented automation; the system asks for permission once.

import AppKit

/// Runs AppleScript off the main thread and returns the result on the main thread.
/// It works on a single dedicated thread with a live run loop: on a plain GCD queue the app's replies
/// sometimes don't arrive and the call hangs (that was why the island froze on a command to the player).
final class AppleScriptRunner {
    private var compiled: [String: NSAppleScript] = [:]

    /// `code` is the AppleScript error number (nil if there's no error). −1743 = Automation not permitted.
    func run(_ source: String, completion: @escaping (NSAppleEventDescriptor?, Int?) -> Void) {
        ScriptThread.shared.async { [weak self] in
            guard let self else { return }
            let script = self.compiled[source] ?? NSAppleScript(source: source)
            self.compiled[source] = script
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            let code = error?[NSAppleScript.errorNumber] as? Int
            DispatchQueue.main.async { completion(error == nil ? result : nil, code) }
        }
    }
}

/// A thread shared by all sources, with a permanent RunLoop — Apple Events run on it and only on it.
private final class ScriptThread: NSObject {
    static let shared = ScriptThread()
    private var thread: Thread!

    override init() {
        super.init()
        thread = Thread(target: self, selector: #selector(main), object: nil)
        thread.name = "island.applescript"
        thread.start()
    }

    @objc private func main() {
        let loop = RunLoop.current
        // A source is required, otherwise run(mode:before:) doesn't block and the loop spins at 100% of a core.
        loop.add(NSMachPort(), forMode: .default)
        while !Thread.current.isCancelled {
            loop.run(mode: .default, before: .distantFuture)
        }
    }

    func async(_ block: @escaping () -> Void) {
        perform(#selector(execute(_:)), on: thread, with: Holder(block), waitUntilDone: false,
                modes: [RunLoop.Mode.default.rawValue])
    }

    @objc private func execute(_ holder: Holder) { holder.block() }

    private final class Holder: NSObject {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
    }
}

// MARK: - Local players (Music, Spotify)

/// A player with its own AppleScript interface: it posts a notification on track change and gives position and
/// artwork on request.
final class ScriptablePlayer: MediaSource {
    struct Kind {
        var bundleID: String
        var displayName: String
        var notification: String
        /// Duration multiplier: Music reports seconds, Spotify milliseconds.
        var durationScale: Double
        var previousCommand: String
        var artworkIsURL: Bool

        static let music = Kind(bundleID: "com.apple.Music", displayName: "Music",
                                notification: "com.apple.Music.playerInfo", durationScale: 1,
                                previousCommand: "back track", artworkIsURL: false)
        static let spotify = Kind(bundleID: "com.spotify.client", displayName: "Spotify",
                                  notification: "com.spotify.client.PlaybackStateChanged", durationScale: 0.001,
                                  previousCommand: "previous track", artworkIsURL: true)
    }

    let id: String
    let displayName: String
    let icon: NSImage?
    let canSkip = true
    private(set) var track: Track?
    private(set) var hint: String?
    var onChange: (() -> Void)?

    private let kind: Kind
    private let runner = AppleScriptRunner()
    private var enabled = false
    private var teardown: [() -> Void] = []

    init(_ kind: Kind) {
        self.kind = kind
        id = kind.bundleID
        displayName = kind.displayName
        icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    func setRunning(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        on ? start() : stop()
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(forName: Notification.Name(kind.notification), object: nil, queue: .main) {
            [weak self] note in self?.notified(note.userInfo ?? [:])
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == self?.kind.bundleID { self?.update(nil) }
        }
        teardown = [{ distributed.removeObserver(token) }, { workspace.removeObserver(quit) }]
        sync()
    }

    func stop() {
        teardown.forEach { $0() }
        teardown = []
        update(nil)
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleID).isEmpty
    }

    private func update(_ new: Track?) {
        guard new != track else { return }
        track = new
        onChange?()
    }

    private func notified(_ info: [AnyHashable: Any]) {
        let state = info["Player State"] as? String
        guard state == "Playing" || state == "Paused", let title = info["Name"] as? String else {
            update(nil)
            return
        }
        // Show the title from the notification instantly, then refine position and artwork from the player.
        var quick = Track(title: title, artist: info["Artist"] as? String ?? "", album: info["Album"] as? String ?? "",
                          duration: 0, elapsed: 0, stamp: Date(), isPlaying: state == "Playing")
        if let track, track.id == quick.id { quick.duration = track.duration; quick.elapsed = track.position() }
        update(quick)
        sync()
    }

    private func sync() {
        guard enabled, isRunning else { return }
        runner.run(stateScript) { [weak self] result, code in
            guard let self else { return }
            if code == -1743 { self.hint = Self.automationHint(self.kind.displayName) }
            guard let result else { return }
            guard result.numberOfItems >= 6 else { return self.update(nil) }
            self.hint = nil
            var new = Track(title: result.atIndex(1)?.stringValue ?? "",
                            artist: result.atIndex(2)?.stringValue ?? "",
                            album: result.atIndex(3)?.stringValue ?? "",
                            duration: (result.atIndex(4)?.doubleValue ?? 0) * self.kind.durationScale,
                            elapsed: result.atIndex(5)?.doubleValue ?? 0, stamp: Date(),
                            isPlaying: result.atIndex(6)?.booleanValue ?? false)
            if self.kind.artworkIsURL { new.artworkURL = result.atIndex(7)?.stringValue ?? "" }
            self.update(new)
        }
    }

    // MARK: Control

    func togglePlayPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send(kind.previousCommand) }
    func seek(to position: TimeInterval) { send("set player position to " + String(format: "%.2f", position)) }
    func activate() { NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleID).first?.activate() }

    func loadArtwork(for track: Track, completion: @escaping (NSImage?) -> Void) {
        // The island loads URL artwork itself; here it's only the image kind (Music).
        guard !kind.artworkIsURL, enabled, isRunning else { return completion(nil) }
        runner.run(artworkScript) { [weak self] result, _ in
            let image = result.flatMap { $0.descriptorType == typeUnicodeText ? nil : NSImage(data: $0.data) }
            completion(image)
            // Artwork for a catalog track doesn't load right away — try once more.
            guard image == nil, let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.track?.id == track.id else { return }
                self.runner.run(self.artworkScript) { retry, _ in
                    completion(retry.flatMap { $0.descriptorType == typeUnicodeText ? nil : NSImage(data: $0.data) })
                }
            }
        }
    }

    private func send(_ command: String) {
        guard isRunning else { return }
        runner.run("tell application id \"\(kind.bundleID)\" to \(command)") { _, _ in }
    }

    private var stateScript: String {
        let fields = "name of t, artist of t, album of t, duration of t, player position, (player state is playing)"
            + (kind.artworkIsURL ? ", artwork url of t" : "")
        return """
            tell application id "\(kind.bundleID)"
                if player state is stopped then return {}
                try
                    set t to current track
                    return {\(fields)}
                end try
                return {}
            end tell
            """
    }

    private var artworkScript: String {
        """
        tell application id "\(kind.bundleID)"
            try
                return raw data of artwork 1 of current track
            end try
            return ""
        end tell
        """
    }

    static func automationHint(_ name: String) -> String {
        "Let the island control \(name): System Settings → Privacy & Security → Automation"
    }
}

// MARK: - Web (Safari)

/// Reads "now playing" from Safari tabs through the public "do JavaScript": what the page itself exposes in
/// navigator.mediaSession, plus the state of <video>/<audio> tags. This is how YouTube and other audio are seen.
final class BrowserSource: MediaSource {
    let id = "com.apple.Safari"
    let displayName = "Safari"
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }
    let canSkip = true
    private(set) var track: Track?
    private(set) var hint: String?
    var onChange: (() -> Void)?

    // Polling adapts to the situation: very often while playing, often while paused (in case it resumes),
    // rarely when there's nothing, and very rarely when access is blocked.
    private enum Pace: TimeInterval { case playing = 2, paused = 3, idle = 8, blocked = 20 }

    private let runner = AppleScriptRunner()
    private var timer: Timer?
    private var enabled = false
    private var pace: Pace = .idle
    /// Once we've confirmed that do JavaScript works, we no longer run the probe on every empty poll.
    private var jsConfirmed = false
    private var idlePolls = 0

    func setRunning(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        on ? start() : stop()
    }

    func start() {
        jsConfirmed = false
        setPace(.idle)
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        update(nil)
    }

    /// Changes the polling rate, recreating the timer only when the pace actually changes.
    private func setPace(_ new: Pace) {
        guard new != pace || timer == nil else { return }
        pace = new
        timer?.invalidate()
        let timer = Timer(timeInterval: new.rawValue, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = new.rawValue * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private func poll() {
        guard enabled else { return }
        guard isRunning else {
            hint = nil
            update(nil)
            setPace(.idle)
            return
        }
        runner.run(Self.queryScript) { [weak self] result, _ in
            guard let self else { return }
            if let best = self.pickTrack(from: result) {
                self.hint = nil
                self.jsConfirmed = true
                self.update(self.merged(best))
                // While paused keep polling often — otherwise a resume in Safari wouldn't be noticed right away.
                self.setPace(best.isPlaying ? .playing : .paused)
            } else {
                self.update(nil)
                // Access is already confirmed — an empty reply means "nothing is playing"; run the probe only
                // occasionally, in case the user turned the permission off.
                if self.jsConfirmed {
                    self.hint = nil
                    self.setPace(.idle)
                    self.idlePolls += 1
                    if self.idlePolls >= 8 { self.idlePolls = 0; self.classifyEmpty() }
                } else {
                    self.classifyEmpty()
                }
            }
        }
    }

    /// Parses the list of JSON strings from the tabs and picks a playing one (or the first active one if none play).
    private func pickTrack(from result: NSAppleEventDescriptor?) -> Track? {
        guard let result, result.numberOfItems > 0 else { return nil }
        var candidates: [Track] = []
        for index in 1...result.numberOfItems {
            guard let json = result.atIndex(index)?.stringValue,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let title = object["t"] as? String ?? ""
            guard !title.isEmpty else { continue }
            candidates.append(Track(title: title, artist: object["a"] as? String ?? "",
                                    album: object["al"] as? String ?? "",
                                    duration: object["dur"] as? Double ?? 0, elapsed: object["cur"] as? Double ?? 0,
                                    stamp: Date(), isPlaying: object["playing"] as? Bool ?? false,
                                    artworkURL: object["art"] as? String ?? ""))
        }
        return candidates.first { $0.isPlaying } ?? candidates.first
    }

    /// Keeps the previous position reference when it's the same track — otherwise the scrubber would jump each poll.
    private func merged(_ new: Track) -> Track {
        guard let old = track, old.id == new.id, old.isPlaying == new.isPlaying else { return new }
        var merged = new
        let drift = abs(old.position() - new.elapsed)
        // A big gap means a seek; otherwise keep a steady run from the previous mark.
        if drift <= 3 {
            merged.elapsed = old.elapsed
            merged.stamp = old.stamp
        }
        return merged
    }

    private func update(_ new: Track?) {
        // Don't treat position as a change — otherwise we'd notify every few seconds.
        let same = new?.id == track?.id && new?.isPlaying == track?.isPlaying && new?.duration == track?.duration
        track = new
        if !same { onChange?() }
    }

    /// Empty reply: either nothing really plays, or a permission is missing. Per-tab errors in the main query are
    /// swallowed by `try`, so a separate probe without `try` finds out the reason.
    private func classifyEmpty() {
        runner.run(Self.probeScript) { [weak self] _, code in
            guard let self else { return }
            if code == -1743 {
                self.hint = ScriptablePlayer.automationHint("Safari")
                self.setPace(.blocked)      // access blocked — poll rarely
            } else if code != nil {
                // Safari works, Automation is allowed, but do JavaScript is disabled.
                self.hint = Self.javaScriptHint
                self.setPace(.blocked)
            } else {
                self.jsConfirmed = true     // JavaScript works, there's just nothing playing
                self.hint = nil
                self.setPace(.idle)
            }
        }
    }

    // MARK: Control

    func togglePlayPause() { command(Self.controlScript(Self.toggleJS)) }
    func next() { command(Self.controlScript(Self.clickJS(Self.nextSelectors))) }
    func previous() { command(Self.controlScript(Self.clickJS(Self.prevSelectors))) }
    func seek(to position: TimeInterval) {
        command(Self.controlScript("v.currentTime=\(String(format: "%.2f", position));"))
    }
    func activate() { NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate() }
    func loadArtwork(for track: Track, completion: @escaping (NSImage?) -> Void) { completion(nil) }

    private func command(_ script: String) {
        runner.run(script) { _, _ in }
        // The command took effect on the page — re-read quickly instead of waiting for the next poll.
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.poll() }
        }
    }

    // MARK: Scripts

    /// Picks the page's main media element: the longest of the active ones (playing or already started).
    /// This way a pause in Safari reads correctly, and a stray hidden video/ad doesn't pose as the track.
    private static let pickBest = "var L=document.querySelectorAll('video,audio'),v=null,bs=-1;"
        + "for(var i=0;i<L.length;i++){var m=L[i];"
        + "if(!((!m.paused&&!m.ended)||m.currentTime>0))continue;"
        + "var d=m.duration;if(!d||!isFinite(d))d=0.001;if(d>bs){v=m;bs=d;}}"

    /// Reads the page state. No double quotes — so it nests inside an AppleScript string.
    private static let readJS = "(function(){" + pickBest
        + "var ms=navigator.mediaSession,md=ms&&ms.metadata;if(!v&&!md)return '';"
        + "var playing=v?(!v.paused&&!v.ended):(ms&&ms.playbackState==='playing');"
        + "var cur=v?v.currentTime:0,dur=v&&isFinite(v.duration)?v.duration:0;if(!playing&&!(cur>0))return '';"
        + "var art='';if(md&&md.artwork&&md.artwork.length)art=md.artwork[md.artwork.length-1].src;"
        + "var t=md&&md.title?md.title:document.title;"
        + "return JSON.stringify({t:t,a:md&&md.artist?md.artist:'',al:md&&md.album?md.album:'',"
        + "art:art,cur:cur,dur:dur,playing:playing});})()"

    /// Toggles playback only on a tab that has running or already-started media.
    private static let toggleJS = "if(v.paused&&!(v.currentTime>0&&!v.ended))return '';"
        + "if(v.paused){v.play();}else{v.pause();}"

    // Forward/back buttons in the players of popular sites (YouTube, YouTube Music, SoundCloud, Spotify, etc.).
    private static let nextSelectors = [".ytp-next-button", "ytmusic-player-bar .next-button", ".next-button",
                                        "[data-testid=control-button-skip-forward]", ".skipControl__next",
                                        ".playControls__next", ".player-controls__btn_next"]
    private static let prevSelectors = [".ytp-prev-button", "ytmusic-player-bar .previous-button", ".previous-button",
                                        "[data-testid=control-button-skip-back]", ".skipControl__previous",
                                        ".playControls__prev", ".player-controls__btn_prev"]

    /// Clicks the first visible button from the list — but only on a tab with active media.
    private static func clickJS(_ selectors: [String]) -> String {
        let list = selectors.map { "'\($0)'" }.joined(separator: ",")
        return "if(!(v.currentTime>0))return '';var S=[\(list)];"
            + "for(var i=0;i<S.length;i++){var e=document.querySelector(S[i]);"
            + "if(e){var r=e.getBoundingClientRect();if(r.width>0&&r.height>0){e.click();return '1';}}}return '';"
    }

    private static let queryScript = """
        set out to {}
        tell application id "com.apple.Safari"
            repeat with w in windows
                repeat with tb in tabs of w
                    try
                        set r to (do JavaScript "\(readJS)" in tb)
                        if r is not "" and r is not missing value then set end of out to (r as text)
                    end try
                end repeat
            end repeat
        end tell
        return out
        """

    /// The action runs on the first tab where suitable media is found.
    private static func controlScript(_ action: String) -> String {
        let js = "(function(){" + pickBest + "if(!v)return '';\(action)return '1';})()"
        return """
            tell application id "com.apple.Safari"
                repeat with w in windows
                    repeat with tb in tabs of w
                        try
                            if (do JavaScript "\(js)" in tb) is "1" then return
                        end try
                    end repeat
                end repeat
            end tell
            """
    }

    private static let probeScript = """
        tell application id "com.apple.Safari"
            if (count of windows) is 0 then return "nowin"
            return (do JavaScript "1" in current tab of front window) as text
        end tell
        """

    private static let javaScriptHint =
        "For web players, enable in Safari: Develop → Allow JavaScript from Apple Events "
        + "(the Develop menu is turned on in Safari → Settings → Advanced → Show features for web developers)"
}
