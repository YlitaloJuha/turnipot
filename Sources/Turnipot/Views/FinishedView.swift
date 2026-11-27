import SwiftUI
import NotchCore

/// "Session finished" drop-down (mockup state 3 + interactions C): hopping mascot and "✓ done"
/// in the notch strip; session name, "finished · tokens · age"; the last assistant message
/// (up to 2 lines); quick reply field. Tapping the text focuses the terminal; "Read ⌄" or scrolling
/// down over the message opens the reply reader; the bottom row's "Mark all read" clears every
/// unseen mark and "Close" dismisses. Closes by itself when the session goes busy again
/// (answered in the terminal / Claude Desktop).
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
    /// The "Read ⌄" row at the bottom center (included in NotchGeometry.finishedSize).
    static let readRowTopGap: CGFloat = 6
    static let readRowHeight: CGFloat = 24
    static let readRowBottomPad: CGFloat = 8
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
            }

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    focusAndClose()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(session.displayTitle).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            Text("finished · \(Fmt.tokens(session.tokens)) tokens · \(Fmt.durationPrecise(since: session.startedAt))")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Spacer(minLength: 0)
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
                .help(Fmt.showHelp(session))   // the whole card opens the session

                if session.isClaudeDesktop {
                    DesktopReplyButton { focusAndClose() }
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
            .padding(.bottom, Self.readRowTopGap)
            Spacer(minLength: 0)

            // Bottom row: "Read ⌄" centered like a pull-down handle (the reader opens downward
            // from here); "Mark all read" and "Close" on its right, clear of the turnip's stage.
            ZStack {
                Button {
                    openReader()
                } label: {
                    HStack(spacing: 4) {
                        Text("Read")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.accent.opacity(0.16)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Read the whole reply here (or scroll down over the message)")
                .onHover { ui.setReadTarget(.init(sessionId: session.sessionId, snippet: true), hovering: $0) }

                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    FooterButton(title: "Mark all read", systemName: "checkmark.circle",
                                 help: "Clear every done / waiting mark and close") {
                        appState.markAllSeen()
                        dismiss()
                    }
                    FooterButton(title: "Close", systemName: "xmark", help: "Dismiss") { dismiss() }
                }
                .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.readRowHeight)
            .padding(.bottom, Self.readRowBottomPad)
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

    /// Open the session and close the island: without this the pointer (still over the notch)
    /// hover-expands the session list behind the dismissed drop-down. Like the panel's ✕, no
    /// hover-expand again until the pointer has left the island.
    private func focusAndClose() {
        appState.focusSession(id: session.sessionId)
        ui.suppressHoverUntilExit = true
        dismiss()
        appState.setHovering(false)
    }

    private func dismiss() {
        ui.stickyFinishedId = nil
        if ui.isEditing { ui.releaseKey() }
        appState.dismissFinished(sessionId: session.sessionId)
    }
}

/// Small muted text button for the finished drop-down's bottom row.
private struct FooterButton: View {
    let title: String
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemName).font(.system(size: 9.5, weight: .bold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.white : Theme.muted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
