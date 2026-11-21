import SwiftUI
import NotchCore

/// "Session finished" drop-down (mockup state 3 + interactions C): hopping mascot and "✓ done"
/// in the notch strip; session name, "finished · tokens · age"; the last assistant message
/// (up to 2 lines); quick reply field. Tapping the text focuses the terminal; "Read ›" or scrolling
/// down over the message opens the reply reader; × dismisses.
struct FinishedView: View {
    @ObservedObject var appState: AppState
    let session: ClaudeSession
    @EnvironmentObject private var ui: NotchUIState

    /// The turnip gets its own tall "stage" at the bottom-left of the drop-down (instead of the
    /// strip) so the full spring-out jump plays inside the island.
    static let stagePixel: CGFloat = 2
    static let stageLeading: CGFloat = 14
    static let stageBottom: CGFloat = 10
    static func replySlot(_ sessionId: String) -> String { "finished-\(sessionId)" }
    /// Width of the reply field (the text column).
    static var replyFieldWidth: CGFloat {
        NotchGeometry.finishedSize.width - stageTextLeading - 18
    }

    /// Text column starts right of the stage.
    static var stageTextLeading: CGFloat {
        stageLeading + TurnipMascotView.frameSize(pixelSize: stagePixel, layout: .stage).width + 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchStrip(height: ui.geometry.notchHeight) {
                EmptyView()
            } trailing: {
                Text("✓ done")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.green)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                    // Scrolling down over the message opens the reader (click still focuses).
                    .onHover { ui.setReadTarget(.init(sessionId: session.sessionId, snippet: true), hovering: $0) }
                }
                .buttonStyle(.plain)
                .hapticHover()
                .help("Dismiss")
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    appState.focusSession(id: session.sessionId)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(session.displayTitle).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            Text("finished · \(Fmt.tokens(session.tokens)) tokens · \(Fmt.durationPrecise(since: session.startedAt))")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                openReader()
                            } label: {
                                Text("Read ›")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Read the whole reply here (or scroll down over the message)")
                            .onHover { ui.setReadTarget(.init(sessionId: session.sessionId, snippet: true), hovering: $0) }
                            .hapticHover()
                            Text("open ↗").font(.system(size: 11)).foregroundStyle(Theme.accent)
                                .help(Fmt.showHelp(session))
                        }
                        if let text = lastText {
                            Text("“\(text)”")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .lineSpacing(3)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hapticHover()

                if session.isClaudeDesktop {
                    DesktopReplyButton {
                        appState.focusSession(id: session.sessionId)
                        dismiss()
                    }
                    .padding(.top, 4)
                } else {
                    ReplyField(slot: Self.replySlot(session.sessionId), placeholder: "Reply…", target: session.name,
                               disabledReason: ReplyField.disabledReason(appState: appState, sessionId: session.sessionId)) { text in
                        guard appState.sendReply(sessionId: session.sessionId, text: text) else { return }
                        ui.stickyFinishedId = nil
                        ui.releaseKey()
                        ui.confirm("✓ Sent to \(session.name)", detail: "“\(text)”", tone: .ok, duration: 1.3)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.leading, Self.stageTextLeading)
            .padding(.trailing, 18)
            .padding(.top, 2)
            .padding(.bottom, 14)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottomLeading) {
            TurnipMascotView(mood: .hop, pixelSize: Self.stagePixel, layout: .stage)
                .padding(.leading, Self.stageLeading)
                .padding(.bottom, Self.stageBottom)
                .allowsHitTesting(false)
        }
    }

    private var lastText: String? {
        guard let t = session.lastAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "\n", with: " ")
    }

    private func openReader() {
        ui.stickyFinishedId = nil
        appState.openReader(sessionId: session.sessionId)
    }

    private func dismiss() {
        ui.stickyFinishedId = nil
        if ui.isEditing { ui.releaseKey() }
        appState.dismissFinished(sessionId: session.sessionId)
    }
}
