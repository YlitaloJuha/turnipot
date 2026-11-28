import SwiftUI
import NotchCore

/// "Session finished" drop-down (mockup state 3 + interactions C): hopping mascot and "✓ done"
/// in the notch strip; per finished session a card with its name, "finished · tokens · age", the
/// last assistant message (up to 2 lines) and a quick reply field. Tapping a card's text focuses
/// that terminal; "Read ⌄" (or scrolling down over it) opens the reply reader; the bottom row's
/// "Mark all read" clears every unseen mark and "Close" dismisses. A card closes by itself when its
/// session goes busy again (answered in the terminal / Claude Desktop).
///
/// Sessions that finish close together stack (oldest on top, at most
/// `NotchConstants.finishedStackLimit`): a new card is added at the bottom, so the cards already
/// there never move. While the pointer is on the drop-down the stack is frozen (see
/// `NotchUIState.stickyFinishedIds`) and a newcomer only shows as "+1 more" in the strip; buttons
/// ignore clicks for 400 ms after the stack changes.
struct FinishedView: View {
    @ObservedObject var appState: AppState
    let sessions: [ClaudeSession]
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
    static var bottomRowHeight: CGFloat { readRowHeight + readRowBottomPad }
    /// Extra space above every card after the first (with a hairline in it).
    static let cardGap: CGFloat = 10
    /// Height of the last-message lines (and their spacing) in a card.
    static let messageHeight: CGFloat = 42
    /// Width of the reply field (the text column).
    static var replyFieldWidth: CGFloat {
        NotchGeometry.finishedSize.width - stageTextLeading - 18
    }

    /// Text column starts right of the stage.
    static var stageTextLeading: CGFloat {
        stageLeading + TurnipMascotView.frameSize(pixelSize: stagePixel, layout: .stage).width + 10
    }

    /// A card's fixed height (fixed so the island's size is known without measuring views); one
    /// card plus the bottom row is NotchGeometry.finishedSize.
    @MainActor
    static func cardHeight(_ session: ClaudeSession?, index: Int, ui: NotchUIState) -> CGFloat {
        let base = NotchGeometry.finishedSize.height - bottomRowHeight
        let text = lastText(session) == nil ? base - messageHeight : base
        let reply = session.map { $0.isClaudeDesktop ? 0 : ui.replyFieldExtra[replySlot($0.sessionId)] ?? 0 } ?? 0
        return text + reply + (index > 0 ? cardGap : 0)
    }

    static func lastText(_ session: ClaudeSession?) -> String? {
        guard let t = session?.lastAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t.replacingOccurrences(of: "\n", with: " ")
    }

    private var ids: [String] { sessions.map(\.sessionId) }
    private var stacked: Bool { sessions.count > 1 }

    /// Finished sessions not shown as a card (arrived while frozen, or past the stack limit).
    private var moreCount: Int {
        appState.finishedSessionIds.filter { !ids.contains($0) && appState.session(id: $0) != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchStrip(height: ui.geometry.notchHeight) {
                EmptyView()
            } trailing: {
                HStack(spacing: 8) {
                    if moreCount > 0 {
                        Text("+\(moreCount) more")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .help("More sessions finished: they're marked in the session list")
                    }
                    Text(stacked ? "✓ \(sessions.count) done" : "✓ done")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.green)
                }
            }

            ForEach(Array(sessions.enumerated()), id: \.element.sessionId) { index, session in
                card(session, index: index)
                    .frame(height: Self.cardHeight(session, index: index, ui: ui), alignment: .top)
            }
            Spacer(minLength: 0)

            // Bottom row: "Read ⌄" centered like a pull-down handle (the reader opens downward
            // from here; stacked cards each have their own); "Mark all read" and "Close" on its
            // right, clear of the turnip's stage.
            ZStack {
                if !stacked, let only = sessions.first {
                    Button {
                        openReader(only)
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
                    .help("Read the whole reply here (or scroll down over this button)")
                    .onHover { ui.setReadTarget(.init(sessionId: only.sessionId, snippet: true), hovering: $0) }
                }

                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    FooterButton(title: "Mark all read", systemName: "checkmark.circle",
                                 help: "Clear every done / waiting mark and close") {
                        guard ui.finishedActionAllowed(ids) else { return }
                        appState.markAllSeen()
                        dismiss()
                    }
                    FooterButton(title: "Close", systemName: "xmark", help: stacked ? "Dismiss all" : "Dismiss") {
                        guard ui.finishedActionAllowed(ids) else { return }
                        dismiss()
                    }
                }
                .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.readRowHeight)
            .padding(.bottom, Self.readRowBottomPad)
        }
        // A card leaving slides the rest up on the island's shrink curve (in step with the outline).
        .animation(.spring(IslandMotion.shrinkSpring), value: ids)
        .overlay(alignment: .bottomLeading) {
            TurnipMascotView(mood: .hop, pixelSize: Self.stagePixel, layout: .stage)
                .padding(.leading, Self.stageLeading)
                .padding(.bottom, Self.stageBottom)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func card(_ session: ClaudeSession, index: Int) -> some View {
        // Kept in place while frozen even though it's working again (answered elsewhere).
        let busy = session.status == .busy
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    guard ui.finishedActionAllowed(ids) else { return }
                    appState.focusSession(id: session.sessionId)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(session.displayTitle).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .lineLimit(1)
                            Text(busy ? "working again"
                                      : "finished · \(Fmt.tokens(session.tokens)) tokens · \(Fmt.durationPrecise(since: session.startedAt))")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        if let text = Self.lastText(session) {
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

                if stacked {
                    FooterButton(title: "Read", systemName: "chevron.down",
                                 help: "Read the whole reply here (or scroll down over this button)") {
                        guard ui.finishedActionAllowed(ids) else { return }
                        openReader(session)
                    }
                    .onHover { ui.setReadTarget(.init(sessionId: session.sessionId, snippet: true), hovering: $0) }
                }
            }

            if session.isClaudeDesktop {
                DesktopReplyButton {
                    guard ui.finishedActionAllowed(ids) else { return }
                    appState.focusSession(id: session.sessionId)
                    dismiss()
                }
                .padding(.top, 4)
            } else {
                ReplyField(slot: Self.replySlot(session.sessionId), placeholder: "Reply…", target: session.name,
                           disabledReason: ReplyField.disabledReason(appState: appState, sessionId: session.sessionId)) { text in
                    guard appState.sendReply(sessionId: session.sessionId, text: text) else { return }
                    ui.unstickFinished(session.sessionId)
                    ui.releaseKey()
                    ui.confirm("✓ Sent to \(session.name)", detail: "“\(text)”", tone: .ok, duration: 1.3)
                }
                .padding(.top, 4)
            }
        }
        .opacity(busy ? 0.55 : 1)
        .padding(.leading, Self.stageTextLeading)
        .padding(.trailing, 18)
        .padding(.top, 2 + (index > 0 ? Self.cardGap : 0))
        .padding(.bottom, Self.readRowTopGap)
        .overlay(alignment: .top) {
            if index > 0 {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.leading, Self.stageTextLeading)
                    .padding(.trailing, 18)
                    .padding(.top, Self.cardGap / 2)
            }
        }
    }

    private func openReader(_ session: ClaudeSession) {
        ui.stickyFinishedIds = nil
        appState.openReader(sessionId: session.sessionId)
    }

    /// Close the drop-down (every card) and the island (Close, Mark all read, opening a session):
    /// the pointer is still over the notch, so without dropping the hover the session list would
    /// open behind it. Like the panel's ✕, no hover-expand until the pointer has left. The other
    /// cards' sessions stay marked in the list.
    private func dismiss() {
        ui.stickyFinishedIds = nil
        if ui.isEditing { ui.releaseKey() }
        ui.suppressHoverUntilExit = true
        appState.dismissFinished()
        appState.setHovering(false)
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
