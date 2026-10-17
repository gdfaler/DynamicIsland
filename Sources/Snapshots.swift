import AppKit

/// Layout check: with the ISLAND_SNAPSHOT_DIR variable the island shows each of its states in turn on
/// sample data, saves snapshots of its own window into that folder, and then quits.
enum Snapshots {
    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// A snapshot of its own window as the user sees it (no Screen Recording permission is needed for one's own windows).
    private static let windowImage: WindowImageFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: WindowImageFn.self)
    }()

    static func run(model: IslandModel, panel: NSWindow, into dir: String) {
        let track = Track(title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                          duration: 244, elapsed: 97, stamp: Date(), isPlaying: true)
        var steps: ArraySlice<(name: String, action: () -> Void)> = [
            ("01-idle", {}),
            ("02-music", {
                model.media.present(track)
                model.media.setArtwork(sampleArtwork())
            }),
            ("03-music-timer", { model.timer.start(minutes: 25) }),
            ("04-timer", { model.media.present(nil) }),
            ("05-charging", {
                model.timer.cancel()
                model.show(.charging(percent: 67))
            }),
            ("06-low-battery", { model.show(.lowBattery(percent: 10)) }),
            ("07-volume", { model.show(.volume(level: 0.6, muted: false)) }),
            ("08-device", { model.show(.device(name: "AirPods Pro", symbol: "airpodspro")) }),
            ("09-timer-done", { model.show(.timerDone) }),
            ("10-expanded-music", {
                model.media.present(track)
                model.media.setArtwork(sampleArtwork())
                model.expand()
            }),
            ("11-expanded-timer", {
                model.media.present(nil)
                model.timer.start(minutes: 10)
            }),
            ("12-expanded-clock", { model.timer.cancel() }),
        ]
        func step() {
            guard let (name, action) = steps.popFirst() else { return NSApp.terminate(nil) }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                capture(panel, to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
                step()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        // 8 — this window only, 1 | 8 — without the shadow and at full resolution.
        guard let number = UInt32(exactly: window.windowNumber),
              let image = windowImage?(.null, 8, number, 1 | 8)?.takeRetainedValue(),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // The window is transparent and the island is black — lay down a background it's visible against.
        context.setFillColor(CGColor(red: 0.45, green: 0.55, blue: 0.7, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let flattened = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: flattened).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func sampleArtwork() -> NSImage {
        NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.95, green: 0.35, blue: 0.75, alpha: 1),
                       ending: NSColor(srgbRed: 0.2, green: 0.15, blue: 0.6, alpha: 1))?.draw(in: rect, angle: -60)
            return true
        }
    }
}
