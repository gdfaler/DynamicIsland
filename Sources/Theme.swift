import SwiftUI

enum Palette {
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let secondary = Color.white.opacity(0.55)
    static let groove = Color.white.opacity(0.18)
    static let chip = Color.white.opacity(0.12)
}

enum Motion {
    /// Expanding is springy with a slight overshoot; collapsing is calm.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let close = Animation.spring(response: 0.36, dampingFraction: 0.9)
}

/// 75 → "1:15", 3725 → "1:02:05".
func fmtClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
}

/// The island outline: it hangs from the top edge of the screen like the real notch — flush with the edge at the
/// top (straight corners), vertical walls on the sides, and rounded at the bottom with small concave "fillets"
/// at the corners, so the bottom blends into the menu bar instead of looking like a pasted-on rectangle.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    /// Concave fillet at the top sides; 0 = straight vertical walls.
    var topFillet: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topFillet) }
        set {
            bottomRadius = newValue.first
            topFillet = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let bottom = max(0, min(bottomRadius, rect.width / 2, rect.height))
        let fillet = max(0, min(topFillet, (rect.width - 2 * bottom) / 2, rect.height - bottom))
        var path = Path()
        // The top edge — flush with the screen edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // The right side: down, through a concave fillet if needed.
        if fillet > 0 {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - fillet, y: rect.minY + fillet),
                              control: CGPoint(x: rect.maxX - fillet, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - fillet, y: rect.maxY - bottom))
            path.addArc(tangent1End: CGPoint(x: rect.maxX - fillet, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.maxX - fillet - bottom, y: rect.maxY), radius: bottom)
            path.addLine(to: CGPoint(x: rect.minX + fillet + bottom, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: rect.minX + fillet, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX + fillet, y: rect.maxY - bottom), radius: bottom)
            path.addLine(to: CGPoint(x: rect.minX + fillet, y: rect.minY + fillet))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                              control: CGPoint(x: rect.minX + fillet, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.maxX - bottom, y: rect.maxY), radius: bottom)
            path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottom), radius: bottom)
        }
        path.closeSubpath()
        return path
    }
}

/// The island's content appears and disappears by blurring and shrinking slightly.
private struct Dissolve: ViewModifier {
    var hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? 7 : 0)
            .scaleEffect(hidden ? 0.88 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static let islandContent = AnyTransition.modifier(active: Dissolve(hidden: true), identity: Dissolve(hidden: false))
}

struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
