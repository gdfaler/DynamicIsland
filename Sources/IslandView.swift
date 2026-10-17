import SwiftUI

/// The whole island: the black shape pinned to the top edge of the window, and its content.
struct IslandView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let layout = model.layout
        ZStack(alignment: .top) {
            switch model.presentation {
            case .expanded:
                ExpandedView(model: model).transition(.islandContent)
            case .alert(let alert):
                AlertRow(alert: alert, height: model.notch.height)
                    .id(alert.slot)
                    .transition(.islandContent)
            case .compact:
                CompactRow(model: model).transition(.islandContent)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(bottomRadius: layout.bottomRadius, topFillet: layout.topFillet))
        .shadow(color: .black.opacity(layout.isExpanded ? 0.4 : 0), radius: 12, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { model.expand() }
        .animation(layout.isExpanded ? Motion.open : Motion.close, value: layout)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

/// A row the height of the notch: one element on each side of the cutout.
struct EarRow<Leading: View, Trailing: View>: View {
    var inset: CGFloat
    var height: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, inset)
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

/// The collapsed island with what's going on: track artwork on the left, equalizer or timer on the right.
struct CompactRow: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        EarRow(inset: 15, height: model.notch.height) {
            if model.musicIsLive {
                ArtworkView(image: model.media.artwork, size: 20)
            } else {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.orange)
            }
        } trailing: {
            if model.timer.isActive {
                CountdownText(timer: model.timer, size: 13)
            } else {
                EqualizerBars(meter: model.meter, color: model.media.accent,
                              isPlaying: model.media.track?.isPlaying ?? false)
                    .frame(width: 20, height: 15)
            }
        }
    }
}

/// A brief alert: charging, volume, a new audio device, or a finished timer.
struct AlertRow: View {
    var alert: IslandAlert
    var height: CGFloat

    var body: some View {
        EarRow(inset: 17, height: height) { leading } trailing: { trailing }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    @ViewBuilder private var leading: some View {
        switch alert.kind {
        case .charging:
            Text("Charging")
        case .lowBattery:
            Text("Low battery")
        case .volume(let level, let muted):
            Image(systemName: muted ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill"
                    : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, alignment: .leading)
        case .device(_, let symbol):
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
        case .timerDone:
            Image(systemName: "bell.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.orange)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch alert.kind {
        case .charging(let percent):
            battery(percent, Palette.green)
        case .lowBattery(let percent):
            battery(percent, percent <= 10 ? Palette.red : Palette.orange)
        case .volume(let level, let muted):
            LevelBar(fraction: muted ? 0 : level)
                .frame(width: 46)
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: level)
        case .device(let name, _):
            Text(name)
        case .timerDone:
            Text("Timer").foregroundStyle(Palette.orange)
        }
    }

    private func battery(_ percent: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text("\(percent) %").foregroundStyle(color).monospacedDigit()
            BatteryGlyph(percent: percent, color: color)
        }
    }
}
