import SwiftUI
import NotchCore

/// Near-limit banner (mockup state 5, dropped down): sweating mascot, "91% wk" + red ring in the
/// strip, the window's bar and reset time, and a "Got it" button -> dismissNearLimit().
struct NearLimitView: View {
    @ObservedObject var appState: AppState
    let window: UsageWindow
    @EnvironmentObject private var ui: NotchUIState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchStrip(height: ui.geometry.notchHeight) {
                MascotView(mood: .sweat, pixelSize: MascotView.pixelSize(forStrip: ui.geometry.notchHeight))
            } trailing: {
                Text("\(window.percent)% \(Fmt.usageShortLabel(window.label))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.red)
                UsageRing(percent: window.percent, color: Theme.red)
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("\(Fmt.usageLabel(window.label))").font(.system(size: 13, weight: .bold))
                        Text("usage at \(window.percent)%").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    UsageBar(percent: window.percent, color: Theme.red)
                    Text(Fmt.resets(window.resetsText))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Button("Got it") { appState.dismissNearLimit() }
                    .buttonStyle(NotchButtonStyle(hPad: 12, vPad: 6, radius: 9))
            }
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, 12)
            Spacer(minLength: 0)
        }
    }
}

/// Brief result flash after a decision / reply ("✓ Allowed", "✓ Sent to api-refactor").
struct ConfirmationView: View {
    let confirmation: NotchUIState.Confirmation
    let mood: MascotMood
    @EnvironmentObject private var ui: NotchUIState

    /// Prompt layout (title, detail, lines, buttons); NotchUIState sizes the island with it.
    static let promptTitle: CGFloat = 22
    static let promptDetail: CGFloat = 18
    static let promptLine: CGFloat = 17
    static let promptButtons: CGFloat = 44
    static let promptBottom: CGFloat = 14

    static func promptHeight(_ c: NotchUIState.Confirmation) -> CGFloat {
        promptTitle + (c.detail == nil ? 0 : promptDetail) + CGFloat(c.lines.count) * promptLine
            + (c.actions.isEmpty ? 0 : promptButtons) + promptBottom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchStrip(height: ui.geometry.notchHeight) {
                MascotView(mood: .bouncing, pixelSize: MascotView.pixelSize(forStrip: ui.geometry.notchHeight))
            } trailing: {
                StatusDot(color: confirmation.isPrompt ? color : Theme.green, pulse: !confirmation.isPrompt)
            }
            if confirmation.isPrompt {
                prompt
                Spacer(minLength: 0)
            } else {
                flash
            }
        }
    }

    /// Setup prompt / update notice: title, detail, explanation lines and buttons.
    private var prompt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(confirmation.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(height: Self.promptTitle, alignment: .leading)
            if let d = confirmation.detail {
                Text(d).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(height: Self.promptDetail, alignment: .leading)
            }
            ForEach(Array(confirmation.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(height: Self.promptLine, alignment: .leading)
                    .help(line)
            }
            if !confirmation.actions.isEmpty {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(confirmation.actions) { a in
                        Button { ui.runPromptAction(a, in: confirmation) } label: { Text(a.title) }
                            .buttonStyle(NotchButtonStyle(background: background(for: a.role), hPad: 12, vPad: 6, radius: 9))
                            .hapticHover("prompt:\(a.title)")
                    }
                }
                .frame(height: Self.promptButtons, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 2)
    }

    private func background(for role: NotchUIState.ConfirmationAction.Role) -> Color {
        switch role {
        case .primary: return Theme.accent
        case .destructive: return Color(hex: 0x5b2323)
        case .normal: return Color(hex: 0x2a2a30)
        }
    }

    private var flash: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(confirmation.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                if let d = confirmation.detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
    }

    private var color: Color {
        switch confirmation.tone {
        case .ok: return Theme.green
        case .bad: return Theme.red
        case .neutral: return Theme.accent
        }
    }
}
