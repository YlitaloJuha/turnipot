import SwiftUI
import NotchCore

/// Collapsed pill (mockup states 1, 2, 5): left wing = mascot (+ green dot and busy count while
/// working), center = physical notch (empty), right wing = activity-style usage rings (session,
/// week, week per model) while working / unseen / near the limit, else the muted session count
/// (none with no sessions: the pill is one-sided then, PillLayout.oneSided).
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
    private var rightKey: Int { PillLayout.showsRings(appState: appState) ? 1 : 0 }

    private var rightPercent: Int { appState.usage.windows.map(\.percent).reduce(0, +) }

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
        HStack(spacing: 0) {
            if PillLayout.showsRings(appState: appState) {
                UsageRings(percents: appState.usage.windows.map(\.percent))
                    .opacity(appState.usage.stale ? 0.55 : 1)
                    .help(ringsHelp)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            } else if !PillLayout.oneSided(appState: appState) {
                Text("\(appState.sessions.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .contentTransition(.numericText(value: Double(appState.sessions.count)))
                    .transition(.opacity)
            }
        }
        .padding(.trailing, PillLayout.rightTrailingPad)
    }

    private var ringsHelp: String {
        appState.usage.windows.prefix(UsageRings.maxRings)
            .map { "\(Fmt.usageLabel($0.label)) \($0.percent)%" }
            .joined(separator: " · ")
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
