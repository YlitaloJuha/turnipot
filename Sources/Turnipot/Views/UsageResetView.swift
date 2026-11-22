import SwiftUI
import NotchCore

/// "Usage reset" drop-down: a usage window (5h session / weekly) just reset. The turnip on its
/// stage (bottom-left, like the finished drop-down) gets watered and perks up; the text column
/// announces the reset and the window's bar drains from the old percent to the new one.
/// Clicking it opens the panel, × dismisses; it goes away by itself after UsageResetRule.lifetime.
struct UsageResetView: View {
    @ObservedObject var appState: AppState
    let reset: UsageReset
    @EnvironmentObject private var ui: NotchUIState
    @Environment(\.mascotLoopTime) private var loopTime
    /// When the drop-down appeared (live): the bar drains in step with the watering, which
    /// starts once the content has faded in (TurnipNSView.playWater).
    @State private var shownAt: Date?
    static var waterDelay: Double { IslandMotion.contentInDelay + IslandMotion.contentInDuration }

    /// Bigger turnip than the finished drop-down's (3 pt pixels): the watering is the point.
    static let stagePixel: CGFloat = 3
    static let stageLeading: CGFloat = 18
    static let stageBottom: CGFloat = 8
    static var textLeading: CGFloat {
        stageLeading + TurnipMascotView.frameSize(pixelSize: stagePixel, layout: .stage).width + 14
    }

    /// Bar percent `t` seconds into the watering: drains while the drops fall.
    private func barPercent(_ t: Double) -> Int {
        let from = reset.previousPercent, to = reset.window.percent
        let u = min(max((t - 0.5) / 0.7, 0), 1)
        let e = u * u * (3 - 2 * u)
        return Int((Double(from) + Double(to - from) * e).rounded())
    }

    /// Seconds into the watering: renders use the frame time; live counts from appearing.
    private func waterTime(_ now: Date) -> Double {
        if let loopTime { return loopTime }
        guard let shownAt else { return -1 }
        return now.timeIntervalSince(shownAt) - Self.waterDelay
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: loopTime != nil || waterTime(Date()) > 1.4)) { ctx in
            content(percent: barPercent(waterTime(ctx.date)))
        }
        .onAppear { if shownAt == nil { shownAt = Date() } }
    }

    private func content(percent barPercent: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchStrip(height: ui.geometry.notchHeight) {
                EmptyView()
            } trailing: {
                Text("↻ reset")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.green)
                CloseButton { appState.dismissUsageReset() }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(Fmt.usageLabel(reset.window.label)).font(.system(size: 13, weight: .bold))
                    Text("usage reset").font(.system(size: 13))
                    Spacer(minLength: 0)
                    Text("\(barPercent)%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.green)
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                UsageBar(percent: barPercent, color: Theme.green)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .padding(.leading, Self.textLeading)
            .padding(.trailing, 18)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottomLeading) {
            TurnipMascotView(mood: .bouncing, pixelSize: Self.stagePixel, layout: .stage, watering: true)
                .padding(.leading, Self.stageLeading)
                .padding(.bottom, Self.stageBottom)
                .allowsHitTesting(false)
        }
    }

    private var detail: String {
        let next = Fmt.resets(reset.window.resetsText).replacingOccurrences(of: "resets ", with: "")
        return "was \(reset.previousPercent)%" + (next.isEmpty ? "" : " · next reset \(next)")
    }
}
