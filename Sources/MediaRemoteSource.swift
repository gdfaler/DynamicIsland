// EXPERIMENTAL — "Now Playing from any app" through the private MediaRemote framework.
//
// This is the one place the app steps outside documented APIs, which is why it is off by default and labelled
// experimental. Since macOS 15.4 MediaRemote answers only Apple-signed processes, so the app never calls it itself:
// it starts /usr/bin/perl (an Apple binary that is allowed to) and loads Resources/libmrbridge.dylib into it
// (Bridge/mrbridge.c). The bridge prints a JSON line whenever the now-playing state changes; commands go through a
// short-lived second perl. If any of that stops working on a future macOS the source just goes quiet.

import AppKit

final class MediaRemoteSource: MediaSource {
    let id = "system.mediaremote"
    private(set) var displayName = "Now Playing"
    private(set) var icon: NSImage?
    let canSkip = true
    private(set) var track: Track?
    private(set) var hint: String?
    var onChange: (() -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var artwork: NSImage?
    private var enabled = false
    private var restarts = 0

    private static let bridge = Bundle.main.url(forResource: "libmrbridge", withExtension: "dylib")
    /// The perl one-liner that loads the bridge and calls one of its functions.
    private static func script(_ function: String) -> String {
        "use DynaLoader; my $h = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1; "
            + "my $s = DynaLoader::dl_find_symbol($h, '\(function)') or exit 2; "
            + "my $x = DynaLoader::dl_install_xsub('main::f', $s); &$x();"
    }

    func setRunning(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        on ? start() : stop()
    }

    // MARK: - Stream

    func start() {
        guard process == nil, let bridge = Self.bridge else {
            hint = Self.bridge == nil ? L("The experimental Now Playing bridge is missing from this build.") : nil
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.script("adapter_stream"), bridge.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.update(nil)
                // Restart a couple of times; after that it's not going to work on this system.
                if self.enabled, self.restarts < 3 {
                    self.restarts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        if self?.enabled == true { self?.start() }
                    }
                } else if self.enabled {
                    self.hint = L("Now Playing from any app isn't available on this macOS version.")
                }
            }
        }
        do {
            try process.run()
            self.process = process
            hint = nil
        } catch {
            hint = L("Now Playing from any app isn't available on this macOS version.")
        }
    }

    func stop() {
        let finished = process
        process = nil
        (finished?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        finished?.terminationHandler = nil
        finished?.terminate()
        buffer.removeAll()
        restarts = 0
        update(nil)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        restarts = 0
        if object["none"] != nil { return update(nil) }
        guard let title = object["title"] as? String, !title.isEmpty else { return update(nil) }

        if let bundle = object["bundle"] as? String { identify(bundle) }
        if let encoded = object["art"] as? String, let data = Data(base64Encoded: encoded) {
            artwork = NSImage(data: data)
        } else if object["art"] == nil, track?.title != title {
            artwork = nil
        }
        update(Track(title: title, artist: object["artist"] as? String ?? "", album: object["album"] as? String ?? "",
                     duration: object["duration"] as? Double ?? 0, elapsed: object["elapsed"] as? Double ?? 0,
                     stamp: Date(), isPlaying: object["playing"] as? Bool ?? false))
    }

    /// The name and icon of the app that's playing. Browsers play audio from a helper process.
    private func identify(_ bundle: String) {
        let resolved = bundle.hasPrefix("com.apple.WebKit") ? "com.apple.Safari" : bundle
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: resolved) {
            displayName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            displayName = "Now Playing"
            icon = nil
        }
        sourceBundle = resolved
    }
    private var sourceBundle: String?

    private func update(_ new: Track?) {
        let same = new == track
        track = new
        if !same { onChange?() }
    }

    // MARK: - Control

    func togglePlayPause() { send("toggle") }
    func next() { send("next") }
    func previous() { send("previous") }
    func seek(to position: TimeInterval) { send("seek:" + String(format: "%.2f", position)) }
    func activate() {
        guard let sourceBundle else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: sourceBundle).first?.activate()
    }
    func loadArtwork(for track: Track, completion: @escaping (NSImage?) -> Void) { completion(artwork) }

    private func send(_ command: String) {
        guard let bridge = Self.bridge else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.script("adapter_send"), bridge.path]
        process.environment = ["MR_CMD": command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
