import SwiftUI
import NotchCore

/// Collapsed pill (mockup states 1, 2, 5): left wing = mascot (+ green dot and busy count while
/// working), center = physical notch (empty), right wing = session usage % + ring while working,
/// red "91% wk" + red ring when near the limit, else the muted session count.
/// While finished sessions are unseen, an orange "2 done" / amber "1 waiting" badge follows the
/// mascot (and the busy count); the wings grow to fit it (PillLayout).
struct CollapsedView: View {
    @ObservedObject var appState: AppState
    let geometry: NotchGeometry
    var wing: CGFloat = NotchGeometry.collapsedWingWidth
    @EnvironmentObject private var ui: NotchUIState

    var body: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: wing, alignment: .leading)
            Color.clear.frame(width: geometry.notchRect.width)
            rightWing
                .frame(width: wing, alignment: .trailing)
        }
        .padding(.horizontal, 0)
        .frame(height: geometry.notchHeight)
        // Numbers roll (numericText), the dot/count and the right-wing variants cross-fade.
        .animation(.snappy(duration: 0.3), value: appState.busySessions.count)
        .animation(.snappy(duration: 0.3), value: appState.sessions.count)
        .animation(.easeInOut(duration: 0.3), value: appState.isAnyBusy)
        .animation(.easeInOut(duration: 0.3), value: rightKey)
        .animation(.snappy(duration: 0.3), value: badge)
        .animation(.snappy(duration: 0.3), value: rightPercent)
    }

    /// Which right-wing variant is showing (drives its cross-fade).
    private var rightKey: Int {
        if appState.usage.nearLimitWindow != nil { return 2 }
        return (appState.isAnyBusy || appState.hasUnseen) && (appState.usage.sessionWindow ?? appState.usage.windows.first) != nil ? 1 : 0
    }

    private var rightPercent: Int {
        (appState.usage.nearLimitWindow ?? appState.usage.sessionWindow ?? appState.usage.windows.first)?.percent ?? 0
    }

    private var badge: PillBadge? { PillLayout.badge(appState: appState, ui: ui) }

    private var mascotPixel: CGFloat { MascotView.pixelSize(forStrip: geometry.notchHeight) }

    private var leftWing: some View {
        // The turnip's frame has a 1-pixel margin on each side (sparkle / "!"), so the dot keeps
        // clear of them.
        HStack(spacing: PillLayout.spacing) {
            // The mascot itself is drawn by IslandView (shared with the expanded panel / reader so
            // it stays put when the pill expands); keep its space here.
            Color.clear.frame(width: PillLayout.mascotWidth(strip: geometry.notchHeight), height: 1)
            if appState.isAnyBusy {
                HStack(spacing: 3) {
                    StatusDot(color: Theme.green, pulse: true)
                    Text("\(appState.busySessions.count)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(value: Double(appState.busySessions.count)))
                }
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            if let badge {
                UnseenBadge(badge: badge)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
            }
        }
        .padding(.leading, PillLayout.leadingPad)
    }

    @ViewBuilder private var rightWing: some View {
        HStack(spacing: 6) {
            if let w = appState.usage.nearLimitWindow {
                Text("\(w.percent)% \(Fmt.usageShortLabel(w.label))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.red)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText(value: Double(w.percent)))
                    .transition(.opacity)
                UsageRing(percent: w.percent, color: Theme.red)
                    .transition(.opacity)
            } else if appState.isAnyBusy || appState.hasUnseen, let w = appState.usage.sessionWindow ?? appState.usage.windows.first {
                Text("\(w.percent)%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(appState.usage.stale ? Theme.muted.opacity(0.6) : Theme.muted)
                    .contentTransition(.numericText(value: Double(w.percent)))
                    .transition(.opacity)
                UsageRing(percent: w.percent, color: Fmt.usageColor(w.percent))
                    .transition(.opacity)
            } else {
                Text("\(appState.sessions.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.numericText(value: Double(appState.sessions.count)))
                    .transition(.opacity)
            }
        }
        .padding(.trailing, 10)
    }
}

/// Pill badge: pulsing orange dot + "2 done", or amber for "waiting" (mockup idea 1 / 5).
struct UnseenBadge: View {
    let badge: PillBadge

    var body: some View {
        let color = badge.waiting ? Theme.amber : Theme.accent
        HStack(spacing: PillLayout.badgeGap) {
            StatusDot(color: color, pulse: true, period: 2.0)
                .scaleEffect(PillLayout.badgeDot / 7)
                .frame(width: PillLayout.badgeDot, height: PillLayout.badgeDot)
            Text(badge.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, PillLayout.badgeHPad)
        .padding(.vertical, 2)
        .background(Capsule().fill(badge.waiting ? Theme.waitingTint : Theme.doneTint))
        .fixedSize()
    }
}
