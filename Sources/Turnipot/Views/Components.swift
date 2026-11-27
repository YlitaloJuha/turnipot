import SwiftUI
import NotchCore

/// 7pt status dot with optional glow + pulse (mockup `.dot`, `.dot.g`, `.dot.a`).
struct StatusDot: View {
    var color: Color
    var pulse: Bool = false
    var period: Double = 1.4

    @Environment(\.notchStaticRender) private var staticRender

    var body: some View {
        if pulse && !staticRender {
            PulseDotLayerView(color: NSColor(color), period: period)
                .frame(width: 7, height: 7)
        } else {
            dot
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .animation(.easeInOut(duration: 0.25), value: color)
            .frame(width: 7, height: 7)
            .shadow(color: pulse ? color : .clear, radius: 3)
    }
}

/// Conic usage ring (mockup `.ring`): 18pt, 3pt track.
struct UsageRing: View {
    var percent: Int
    var color: Color = Theme.accent
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(Color(hex: 0x333333), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size - 3, height: size - 3)
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.4), value: percent)
    }
}

/// Activity-style concentric rings, one per usage window (outermost = first window: session,
/// then the weekly ones), each in its own tone of the pot's orange (`Theme.ringColor`) over a dim track. Up to `maxRings`.
struct UsageRings: View {
    var percents: [Int]
    var size: CGFloat = PillLayout.ringsSize
    var lineWidth: CGFloat = 2.6
    var gap: CGFloat = 0.9
    static let maxRings = 3

    var body: some View {
        ZStack {
            ForEach(Array(percents.prefix(Self.maxRings).enumerated()), id: \.offset) { i, pct in
                let color = Theme.ringColor(i)
                let d = size - lineWidth - CGFloat(i) * 2 * (lineWidth + gap)
                ZStack {
                    Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
                    Circle()
                        .trim(from: 0, to: max(0.001, min(CGFloat(max(pct, 0)) / 100, 1)))
                        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.5), value: pct)
                }
                .frame(width: max(d, 1), height: max(d, 1))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Small rounded label (mockup `.chip`, `.chip.g`, `.chip.a`).
struct Chip: View {
    enum Style { case neutral, green, amber }
    var text: String
    var style: Style = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
            .fixedSize()
    }

    private var fg: Color {
        switch style { case .neutral: return Color(white: 0.85); case .green: return Theme.green; case .amber: return Theme.amber }
    }
    private var bg: Color {
        switch style { case .neutral: return Theme.chip; case .green: return Color(hex: 0x15301f); case .amber: return Color(hex: 0x3a2e10) }
    }
}

/// Usage bar (mockup `.bar`).
struct UsageBar: View {
    var percent: Int
    var color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.barTrack)
                Capsule().fill(color)
                    .frame(width: max(percent > 0 ? 3 : 0, g.size.width * CGFloat(min(max(percent, 0), 100)) / 100))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: percent)
    }
}

/// Mockup `button`: rounded, bold, brightens on hover, shrinks when pressed.
struct NotchButtonStyle: ButtonStyle {
    var background: Color = Color(hex: 0x2a2a30)
    var foreground: Color = .white
    var hPad: CGFloat = 14
    var vPad: CGFloat = 8
    var radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        HoverWrapper { hovering in
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(background))
                .brightness(hovering ? 0.12 : 0)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .contentShape(Rectangle())
        }
        .hapticHover()
    }
}

/// Tracks hover for its content (substitute for @State-based hover flags).
struct HoverWrapper<Content: View>: View {
    @StateObject private var hovering = LocalState(false)
    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) { self.content = content }

    var body: some View {
        content(hovering.value)
            .onHover { hovering.value = $0 }
    }
}

/// Mockup `h4`: small uppercase section header.
struct SectionHeader: View {
    var text: String
    var trailing: String? = nil
    var trailingColor: Color = Theme.muted

    var body: some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.66)
                .foregroundStyle(Theme.muted)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(trailingColor)
            }
            Spacer(minLength: 0)
        }
        .frame(height: ExpandedMetrics.header, alignment: .top)
    }
}

/// The top strip of every drop-down: items sit left/right of the physical notch.
struct NotchStrip<Leading: View, Trailing: View>: View {
    let height: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: height)
    }
}
