import SwiftUI
import AppKit
import QuartzCore

/// Track artwork; while there's none, a music-note placeholder. A picture that isn't square (a video thumbnail)
/// is shown whole, in the middle of the square slot, neither cropped nor stretched, with its own corners rounded.
struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat

    var body: some View {
        if let image {
            let aspect = max(image.size.width, 1) / max(image.size.height, 1)
            // The fitted picture's size, to round its corners in proportion to its short side (a square gets the
            // same radius as the placeholder).
            let shortSide = size * min(aspect, 1 / aspect)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: shortSide * 0.24, style: .continuous))
                .frame(width: size, height: size)
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.45), Color(red: 0.86, green: 0.15, blue: 0.35)],
                               startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}

/// Equalizer bars: sharp stripes cut out of the track's artwork blurred beyond recognition (it shows through them
/// like color through stained glass). When audio capture is working (`meter.isReactive`), the heights follow
/// the real spectrum of the music; otherwise a smooth fallback animation keeps them from standing still.
struct EqualizerBars: NSViewRepresentable {
    var meter: AudioMeter
    var color: NSColor
    /// The blurred artwork the bars are filled with; without it they take the plain `color`.
    var image: NSImage?
    var isPlaying: Bool

    func makeNSView(context: Context) -> EqualizerBarsView {
        let view = EqualizerBarsView()
        view.meter = meter
        return view
    }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.image = image
        view.color = color
        view.isPlaying = isPlaying
    }
}

final class EqualizerBarsView: NSView {
    static let barCount = AudioMeter.bandCount
    private static let minScale: CGFloat = 0.14

    weak var meter: AudioMeter?
    var color = NSColor.white { didSet { if color != oldValue { restyle() } } }
    var image: NSImage? { didSet { if image !== oldValue { restyle() } } }
    var isPlaying = false { didSet { if isPlaying != oldValue { refresh() } } }

    private let bars = (0..<barCount).map { _ in CALayer() }
    /// The blurred artwork, visible only through the bars: they're its mask.
    private let fill = CALayer()
    private let mask = CALayer()
    private var heights = [CGFloat](repeating: minScale, count: barCount)
    private var phase: CGFloat = 0
    private var ticker: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        fill.contentsGravity = .resize
        fill.magnificationFilter = .linear
        fill.minificationFilter = .trilinear
        fill.mask = mask
        layer?.addSublayer(fill)
        for bar in bars {
            bar.backgroundColor = NSColor.white.cgColor
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)  // grow from the bottom edge
            mask.addSublayer(bar)
        }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let step = bounds.width / CGFloat(Self.barCount)
        let width = max(2, (step * 0.6).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        mask.frame = CGRect(origin: .zero, size: bounds.size)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: step * (CGFloat(index) + 0.5), y: 0)
            bar.cornerRadius = width / 2
            bar.setAffineTransform(CGAffineTransform(scaleX: 1, y: heights[index]))
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            fill.contents = cg
            fill.backgroundColor = nil
        } else {
            fill.contents = nil
            fill.backgroundColor = color.cgColor
        }
        CATransaction.commit()
    }

    /// Starts or stops updates depending on whether music is playing and the window is visible.
    private func refresh() {
        let shouldRun = isPlaying && window != nil
        if shouldRun, ticker == nil {
            let ticker = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            ticker.tolerance = 1.0 / 60
            RunLoop.main.add(ticker, forMode: .common)
            self.ticker = ticker
        } else if !shouldRun, ticker != nil {
            ticker?.invalidate()
            ticker = nil
            settle(toRest: true)
        }
    }

    private func tick() {
        let targets = targetHeights()
        // Fast rise to the peak, gentle fall — like an equalizer stack.
        for i in 0..<Self.barCount {
            let t = targets[i]
            heights[i] += (t - heights[i]) * (t > heights[i] ? 0.6 : 0.22)
        }
        apply()
    }

    /// Target heights: from the spectrum (if capture is running) or from a smooth sine wave (the fallback).
    private func targetHeights() -> [CGFloat] {
        if let meter, meter.isReactive {
            return meter.read().map { Self.minScale + (1 - Self.minScale) * CGFloat(min(max($0, 0), 1)) }
        }
        phase += 0.22
        return (0..<Self.barCount).map { i in
            let wave = sin(phase + CGFloat(i) * 1.1) * 0.5 + 0.5
            let wobble = sin(phase * 0.6 + CGFloat(i) * 2.3) * 0.2
            return min(max(0.3 + wave * 0.6 + wobble, Self.minScale), 1)
        }
    }

    private func settle(toRest: Bool) {
        if toRest { heights = [CGFloat](repeating: Self.minScale, count: Self.barCount) }
        apply(animated: true)
    }

    private func apply(animated: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.25) }
        for (index, bar) in bars.enumerated() {
            bar.setAffineTransform(CGAffineTransform(scaleX: 1, y: heights[index]))
        }
        CATransaction.commit()
    }
}

/// A battery glyph filled to the charge level.
struct BatteryGlyph: View {
    var percent: Int
    var color: Color

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(3, 19 * CGFloat(percent) / 100))
                    .padding(2)
            }
            .frame(width: 23, height: 11.5)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.4))
                .frame(width: 1.5, height: 4)
        }
    }
}

/// A level bar: volume in an alert, track position in the player.
struct LevelBar: View {
    var fraction: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.groove)
                Capsule().fill(Color.white)
                    .frame(width: max(height, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// The timer's remaining time in orange digits.
struct CountdownText: View {
    @ObservedObject var timer: CountdownTimer
    var size: CGFloat

    var body: some View {
        Text(fmtClock(TimeInterval(timer.seconds)))
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(timer.isRunning ? Palette.orange : Palette.orange.opacity(0.5))
            .contentTransition(.numericText(countsDown: true))
            .animation(.default, value: timer.seconds)
    }
}
