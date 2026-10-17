import SwiftUI

private let uiLocale = Locale(identifier: "en_US")

private func dateFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = uiLocale
    formatter.dateFormat = format
    return formatter
}

/// The expanded island: a status strip beside the notch, the player or clock below it, and the timer at the bottom.
struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(model: model)
            if model.showsMusic, let track = model.media.track {
                MusicPanel(media: model.media, meter: model.meter, track: track)
            } else {
                ClockPanel(hint: model.media.setupHint)
            }
            TimerPanel(timer: model.timer)
        }
        .padding(.horizontal, 20)
        .frame(width: IslandModel.expandedWidth, height: model.expandedHeight, alignment: .top)
    }
}

/// The strip at notch level: the music source on the left, the battery charge on the right.
struct StatusStrip: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        // The notch itself covers the middle of the strip, so the content is pushed to the edges.
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if model.showsMusic {
                    if let icon = model.media.activeIcon {
                        Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                    }
                    Text(model.media.activeName)
                }
            }
            Spacer(minLength: 0)
            if model.power.hasBattery {
                HStack(spacing: 5) {
                    if model.power.isPluggedIn {
                        Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(Palette.green)
                    }
                    Text("\(model.power.percent) %").monospacedDigit()
                    BatteryGlyph(percent: model.power.percent, color: batteryColor)
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Palette.secondary)
        .lineLimit(1)
        .frame(height: model.notch.height)
    }

    private var batteryColor: Color {
        if model.power.isPluggedIn { return Palette.green }
        return model.power.percent <= 20 ? Palette.red : .white
    }
}

struct MusicPanel: View {
    static let height: CGFloat = 146

    @ObservedObject var media: NowPlaying
    var meter: AudioMeter
    var track: Track

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { media.openPlayer() } label: { ArtworkView(image: media.artwork, size: 56) }
                    .buttonStyle(IslandButtonStyle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(track.artist.isEmpty ? track.album : track.artist)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                EqualizerBars(meter: meter, color: media.accent, isPlaying: track.isPlaying)
                    .frame(width: 24, height: 18)
            }
            .padding(.top, 8)

            ProgressRow(media: media, track: track)
                .padding(.top, 12)

            if let hint = media.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(height: 36)
                    .padding(.top, 6)
            } else {
                HStack(spacing: media.canSkip ? 38 : 0) {
                    if media.canSkip { control("backward.fill", size: 18) { media.previous() } }
                    control(track.isPlaying ? "pause.fill" : "play.fill", size: 26) { media.togglePlayPause() }
                    if media.canSkip { control("forward.fill", size: 18) { media.next() } }
                }
                .frame(height: 36)
                .padding(.top, 6)
            }
        }
        .frame(height: Self.height, alignment: .top)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: 40, height: 36)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(IslandButtonStyle())
    }
}

/// The scrubber with elapsed and remaining time.
struct ProgressRow: View {
    @ObservedObject var media: NowPlaying
    var track: Track

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = media.scrubPosition ?? track.position(at: context.date)
            HStack(spacing: 8) {
                Text(fmtClock(position)).frame(width: 40, alignment: .leading)
                scrubber(position)
                Text(track.duration > 0 ? "−" + fmtClock(track.duration - position) : "")
                    .frame(width: 44, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Palette.secondary)
        }
        .frame(height: 16)
    }

    private func scrubber(_ position: TimeInterval) -> some View {
        GeometryReader { geometry in
            LevelBar(fraction: track.duration > 0 ? position / track.duration : 0,
                     height: media.scrubPosition == nil ? 5 : 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: media.scrubPosition == nil)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard track.duration > 0, geometry.size.width > 0 else { return }
                        media.scrubPosition = min(max(drag.location.x / geometry.size.width, 0), 1) * track.duration
                    }
                    .onEnded { _ in
                        if let target = media.scrubPosition { media.seek(to: target) }
                        media.scrubPosition = nil
                    })
        }
    }
}

/// When nothing is playing, the expanded island shows the time and date (and a setup hint if needed).
struct ClockPanel: View {
    static let height: CGFloat = 74
    var hint: String?

    private static let time = dateFormatter("HH:mm")
    private static let weekday = dateFormatter("EEEE")
    private static let day = dateFormatter("d MMMM")

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.everyMinute) { context in
                HStack(alignment: .lastTextBaseline, spacing: 14) {
                    Text(Self.time.string(from: context.date))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.weekday.string(from: context.date).capitalized(with: uiLocale))
                            .foregroundStyle(.white)
                        Text(Self.day.string(from: context.date))
                            .foregroundStyle(Palette.secondary)
                    }
                    .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(height: Self.height, alignment: .top)
    }
}

/// The bottom row: quick-start a timer or control one already running.
struct TimerPanel: View {
    static let height: CGFloat = 48
    private static let presets = [1, 5, 10, 15, 25, 45]

    @ObservedObject var timer: CountdownTimer

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(timer.isActive ? Palette.orange : Palette.secondary)
                if timer.isActive {
                    CountdownText(timer: timer, size: 19)
                    Spacer(minLength: 0)
                    chip("+1 min", width: 62) { timer.add(minutes: 1) }
                    chip(symbol: timer.isRunning ? "pause.fill" : "play.fill") { timer.togglePause() }
                    chip(symbol: "xmark") { timer.cancel() }
                } else {
                    ForEach(Self.presets, id: \.self) { minutes in
                        chip("\(minutes)", width: nil) { timer.start(minutes: minutes) }
                    }
                    Text("min")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(Motion.close, value: timer.isActive)
        }
        .frame(height: Self.height)
    }

    private func chip(_ title: String, width: CGFloat?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: width ?? .infinity)
                .frame(height: 26)
                .background(Palette.chip, in: Capsule())
        }
        .buttonStyle(IslandButtonStyle())
    }

    private func chip(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Palette.chip, in: Circle())
        }
        .buttonStyle(IslandButtonStyle())
    }
}
