import SwiftUI
import AppKit
import Combine
import NotchCore

// MARK: - Layout

/// Reader layout constants and the content-driven height (estimated by measuring the reply's
/// blocks with the same fonts; capped at `NotchGeometry.readerMaxHeight`).
enum ReaderMetrics {
    static let sidePad: CGFloat = 18
    static let promptRow: CGFloat = 26
    static let navRow: CGFloat = 26
    static let replyField: CGFloat = 42
    static let footerGap: CGFloat = 6
    static let bottomPad: CGFloat = 14
    static let scrollTopPad: CGFloat = 4
    static let scrollBottomPad: CGFloat = 12
    static let minHeight: CGFloat = 300
    static let bodySize: CGFloat = 13
    static let lineSpacing: CGFloat = 3.5
    static let blockSpacing: CGFloat = 10
    static let codeSize: CGFloat = 12
    static let workingRow: CGFloat = 24

    static var chrome: CGFloat { promptRow + navRow + replyField + footerGap + bottomPad + scrollTopPad + scrollBottomPad }
    static var textWidth: CGFloat { NotchGeometry.readerWidth - 2 * sidePad }
    /// The footer's reply field: slot and width (footer padding is sidePad - 4 each side).
    static func replySlot(_ sessionId: String) -> String { "reader-\(sessionId)" }
    static var replyFieldWidth: CGFloat { NotchGeometry.readerWidth - 2 * (sidePad - 4) }

    /// Extra footer height while the reply field holds more than one line.
    @MainActor
    static func replyExtra(ui: NotchUIState, sessionId: String) -> CGFloat {
        ui.replyFieldExtra[replySlot(sessionId)] ?? 0
    }

    @MainActor
    static func height(appState: AppState, ui: NotchUIState, sessionId: String) -> CGFloat {
        let strip = ui.geometry.notchHeight
        let maxH = ui.geometry.readerMaxHeight
        guard ui.readerTurnsSessionId == sessionId else { return maxH }   // loading: open fully
        let busy = appState.session(id: sessionId)?.status == .busy
        let turns = ui.readerVisibleTurns(busy: busy)
        guard !turns.isEmpty else { return max(minHeight, min(maxH, strip + chrome + replyExtra(ui: ui, sessionId: sessionId) + 60)) }
        let turn = turns[ui.readerIndex(in: turns)]
        let isNewest = ui.readerIndex(in: turns) == turns.count - 1
        let content = contentHeight(turn.text) + (busy && isNewest ? workingRow : 0)
        return min(maxH, max(minHeight, ceil(strip + chrome + replyExtra(ui: ui, sessionId: sessionId) + content)))
    }

    /// Cache: text -> measured height (bodySize is evaluated on every state change).
    @MainActor private static var cache: [String: CGFloat] = [:]

    @MainActor
    static func contentHeight(_ text: String) -> CGFloat {
        if text.isEmpty { return 20 }
        if let h = cache[text] { return h }
        let blocks = MarkdownBlocks.parse(text)
        var h: CGFloat = 0
        for b in blocks { h += blockHeight(b) }
        h += CGFloat(max(0, blocks.count - 1)) * blockSpacing
        if cache.count > 64 { cache.removeAll() }
        cache[text] = h
        return h
    }

    static func measure(_ s: String, font: NSFont, width: CGFloat, spacing: CGFloat = lineSpacing) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = spacing
        let r = (s as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                             attributes: [.font: font, .paragraphStyle: p])
        return ceil(r.height)
    }

    static func blockHeight(_ b: MDBlock) -> CGFloat {
        let body = NSFont.systemFont(ofSize: bodySize)
        let mono = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        switch b {
        case .heading(let level, let t):
            return measure(t, font: NSFont.boldSystemFont(ofSize: headingSize(level)), width: textWidth) + 4
        case .paragraph(let t): return measure(t, font: body, width: textWidth)
        case .listItem(_, let indent, let t):
            return measure(t, font: body, width: textWidth - 20 - CGFloat(indent) * 16)
        case .code(_, let t): return measure(t, font: mono, width: textWidth - 24, spacing: 2) + 20
        case .quote(let t): return measure(t, font: body, width: textWidth - 14)
        case .table(let t):
            if tableFitsGrid(t) { return measure(t.grid, font: mono, width: textWidth, spacing: 2) }
            let recs = t.records
            return recs.reduce(0) { $0 + measure($1, font: body, width: textWidth) }
                + CGFloat(max(0, recs.count - 1)) * recordDivider
        case .rule: return 9
        }
    }

    /// Height of the divider between table records (padding + 1 pt line).
    static let recordDivider: CGFloat = 17

    /// A table renders as monospaced columns only when its widest line fits without wrapping;
    /// wider tables become one "Header: value" record per row.
    static func tableFitsGrid(_ t: MDTable) -> Bool {
        let mono = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        let charWidth = ("M" as NSString).size(withAttributes: [.font: mono]).width
        return CGFloat(t.gridWidth) * charWidth <= textWidth
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: return 17; case 2: return 15.5; default: return 14 }
    }
}

// MARK: - Loader

/// Loads the open reader's turns off the main thread (ReplyReader actor) and keeps them fresh
/// while the reader is open (1 s poll: a stat when nothing changed, incremental read on growth).
@MainActor
final class ReplyLoader {
    private let appState: AppState
    private let ui: NotchUIState
    private let reader = ReplyReader()
    private var task: Task<Void, Never>?
    private var cancellable: AnyCancellable?

    init(appState: AppState, ui: NotchUIState) {
        self.appState = appState
        self.ui = ui
        cancellable = appState.$readerSessionId
            .removeDuplicates()
            .sink { [weak self] id in
                MainActor.assumeIsolated { self?.follow(id) }
            }
    }

    private func follow(_ sessionId: String?) {
        task?.cancel()
        task = nil
        guard let sessionId else { return }
        if ui.readerTurnsSessionId != sessionId {
            ui.readerTurns = []
            ui.readerTurnsSessionId = nil
        }
        ui.readerTurnId = nil
        ui.readerBackProgress = 0
        if let demo = DemoMode.requestedState {
            ui.readerTurns = DemoMode.readerTurns(working: demo == "reader-working")
            ui.readerTurnsSessionId = sessionId
            return
        }
        let reader = self.reader
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let s = self.appState.session(id: sessionId) else { return }
                let r = await reader.replies(sessionId: s.sessionId, cwd: s.cwd, transcriptPath: s.transcriptPath)
                guard !Task.isCancelled, self.appState.readerSessionId == sessionId else { return }
                let turns = r?.turns ?? []
                if self.ui.readerTurns != turns || self.ui.readerTurnsSessionId != sessionId {
                    // Spring the island to the new height together with the content.
                    withAnimation(.spring(IslandMotion.growSpring)) {
                        self.ui.readerTurns = turns
                        self.ui.readerTurnsSessionId = sessionId
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

// MARK: - View

/// Reply reader (`Presentation.reader`): top bar in the notch row ("‹ Sessions" left; mascot,
/// title, ↗, ✕ right), "You: <prompt> · time", the reply as Markdown in a scroll view (selectable
/// text), a "working…" row while the session is busy, and a footer with earlier / later navigation
/// and the quick-reply field.
struct ReaderView: View {
    @ObservedObject var appState: AppState
    let session: ClaudeSession
    @EnvironmentObject private var ui: NotchUIState
    @Environment(\.notchStaticRender) private var staticRender

    private var busy: Bool { session.status == .busy }

    var body: some View {
        let turns = ui.readerTurnsSessionId == session.sessionId ? ui.readerVisibleTurns(busy: busy) : []
        let index = ui.readerIndex(in: turns)
        let turn = turns.isEmpty ? nil : turns[index]
        let isNewest = index == turns.count - 1

        VStack(alignment: .leading, spacing: 0) {
            topBar
            promptRow(turn)
                .frame(height: ReaderMetrics.promptRow)
                .padding(.horizontal, ReaderMetrics.sidePad)
            ReaderScroll(staticRender: staticRender) {
                VStack(alignment: .leading, spacing: ReaderMetrics.blockSpacing) {
                    if let turn, !turn.text.isEmpty {
                        MarkdownBody(text: turn.text)
                    } else if ui.readerTurnsSessionId != session.sessionId {
                        Text("Loading…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    } else if !(busy && isNewest) {
                        Text("No replies yet").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    if busy && isNewest { WorkingRow() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ReaderMetrics.sidePad)
                .padding(.top, ReaderMetrics.scrollTopPad)
                .padding(.bottom, ReaderMetrics.scrollBottomPad)
            }
            // A new turn starts at its top; growth of the same turn keeps the scroll position.
            .id(turn?.id ?? "none")
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) { backCue }

            footer(turns: turns, index: index)
                .padding(.horizontal, ReaderMetrics.sidePad - 4)
                .padding(.bottom, ReaderMetrics.bottomPad)
        }
    }

    // MARK: Parts

    /// Shown while overscrolling up at the top of the reply: "‹ Sessions" fades in until the
    /// gesture goes back to the list (NotchWindowController drives `readerBackProgress`).
    @ViewBuilder private var backCue: some View {
        let p = ui.readerBackProgress
        if p > 0 {
            Text("‹ Sessions")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(white: 0.13)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35 + 0.5 * p), lineWidth: 1))
                .scaleEffect(0.9 + 0.1 * p)
                .opacity(min(1, p * 1.3))
                .padding(.top, 6)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Notch row: "‹ Sessions" then the pill's mascot (drawn by IslandView, same spot as in the
    /// pill) left of the notch; title, ↗, ⚙ and ✕ right of it (no pin: the reader is always pinned).
    private var topBar: some View {
        let mascotX = IslandView.wingMascotLeading(appState: appState, ui: ui, bodyWidth: NotchGeometry.readerWidth)
        return HStack(spacing: 0) {
            Button {
                ui.releaseKey()
                appState.readerBack()
            } label: {
                Text("‹ Sessions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hapticHover()
            .help("Back to the session list (or scroll up past the top)")
            .frame(width: max(40, mascotX - 20 - 8), alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(session.displayTitle)
                    .padding(.trailing, 2)
                Button {
                    appState.focusSession(id: session.sessionId)
                } label: {
                    Text("↗")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hapticHover()
                .help(Fmt.showHelp(session))
                SettingsMenuButton(appState: appState, ui: ui)
                CloseButton {
                    ui.suppressHoverUntilExit = true
                    ui.resetInteraction()
                    ui.releaseKey()
                    appState.closeReader()
                }
            }
            .frame(width: NotchGeometry.readerWidth / 2 - ui.geometry.notchRect.width / 2 - 26, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: ui.geometry.notchHeight)
    }

    @ViewBuilder private func promptRow(_ turn: ReplyTurn?) -> some View {
        HStack(spacing: 6) {
            if let turn, let p = turn.prompt {
                Text("You:").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
                Text(p)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(p)
                Spacer(minLength: 6)
                if let at = turn.promptAt {
                    Text(Self.timeText(at))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.muted.opacity(0.8))
                        .fixedSize()
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }

    @ViewBuilder private func footer(turns: [ReplyTurn], index: Int) -> some View {
        VStack(spacing: ReaderMetrics.footerGap) {
            HStack(spacing: 8) {
                if let c = ui.confirmation {
                    Text(c.text)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(c.tone == .bad ? Theme.red : Theme.green)
                        .lineLimit(1)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    navButton("‹ earlier", enabled: index > 0) { ui.readerStep(-1, busy: busy) }
                    Text(turns.isEmpty ? "0/0" : "\(index + 1)/\(turns.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                    navButton("later ›", enabled: index < turns.count - 1) { ui.readerStep(1, busy: busy) }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: ReaderMetrics.navRow)
            .animation(.easeInOut(duration: 0.2), value: ui.confirmation)

            if session.isClaudeDesktop {
                DesktopReplyButton { appState.focusSession(id: session.sessionId) }
                    .frame(height: ReaderMetrics.replyField)
            } else {
                ReplyField(slot: ReaderMetrics.replySlot(session.sessionId), placeholder: "Reply to \(session.name)…",
                           disabledReason: ReplyField.disabledReason(appState: appState, sessionId: session.sessionId)) { text in
                    guard appState.sendReply(sessionId: session.sessionId, text: text) else { return }
                    ui.readerTurnId = nil          // follow the new turn
                    ui.confirm("✓ Sent to \(session.name)", detail: "“\(text)”", tone: .ok, duration: 1.6)
                }
                .frame(height: ReaderMetrics.replyField + ReaderMetrics.replyExtra(ui: ui, sessionId: session.sessionId))
            }
        }
    }

    private func navButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(enabled ? Theme.accent : Theme.muted.opacity(0.5))
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hapticHover()
        .disabled(!enabled)
        .help(title.contains("earlier") ? "Earlier reply (←)" : "Later reply (→)")
    }

    static func timeText(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm"
        return f.string(from: d)
    }
}

/// The reader's scroll area. Offscreen renders (ImageRenderer can't draw NSScrollView content)
/// get a clipped top-aligned stack showing the same first screenful.
struct ReaderScroll<Content: View>: View {
    let staticRender: Bool
    @ViewBuilder var content: Content
    /// Static renders only (`--export-media`): simulated scroll position.
    @Environment(\.renderScrollOffset) private var renderScrollOffset

    var body: some View {
        if staticRender {
            // Color.clear takes exactly the leftover height; the content hangs from its top.
            Color.clear
                .overlay(alignment: .top) { content.fixedSize(horizontal: false, vertical: true).offset(y: -renderScrollOffset) }
                .clipped()
        } else {
            // Whether it is at its top is read from the NSScrollView itself (NotchWindowController):
            // on macOS a GeometryReader preference inside a ScrollView isn't updated by scrolling.
            ScrollView(.vertical, showsIndicators: true) { content }
        }
    }
}

/// "● working…" at the end of the reply while the session is busy.
struct WorkingRow: View {
    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: Theme.green, pulse: true, period: 1.2)
            Text("working…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .frame(height: ReaderMetrics.workingRow - 4)
    }
}

// MARK: - Markdown

/// Renders a reply: MarkdownBlocks for block structure, `AttributedString(markdown:)` for inline
/// bold / italic / `code` / links. Every block is selectable.
struct MarkdownBody: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
            block(b)
        }
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let t):
            Text(Self.inline(t))
                .font(.system(size: ReaderMetrics.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .foregroundStyle(.white)
                .padding(.top, 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let t):
            prose(t)
        case .listItem(let marker, let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: ReaderMetrics.bodySize, weight: marker == "•" ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(marker == "•" ? Theme.accent : Theme.muted)
                    .frame(width: 14, alignment: .trailing)
                prose(t)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .code(let lang, let t):
            VStack(alignment: .leading, spacing: 4) {
                if let lang {
                    Text(lang)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.muted.opacity(0.8))
                }
                Text(t)
                    .font(.system(size: ReaderMetrics.codeSize, design: .monospaced))
                    .foregroundStyle(Color(white: 0.88))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.105)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        case .quote(let t):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.muted.opacity(0.5)).frame(width: 2.5)
                prose(t, color: Theme.quote)
            }
        case .table(let t):
            if ReaderMetrics.tableFitsGrid(t) {
                Text(t.grid)
                    .font(.system(size: ReaderMetrics.codeSize, design: .monospaced))
                    .foregroundStyle(Color(white: 0.85))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(t.records.enumerated()), id: \.offset) { k, r in
                        if k > 0 {
                            Rectangle().fill(Color.white.opacity(0.10))
                                .frame(width: 120, height: 1)
                                .padding(.vertical, (ReaderMetrics.recordDivider - 1) / 2)
                        }
                        prose(r)
                    }
                }
            }
        case .rule:
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func prose(_ t: String, color: Color = Color(white: 0.9)) -> some View {
        Text(Self.inline(t))
            .font(.system(size: ReaderMetrics.bodySize))
            .foregroundStyle(color)
            .lineSpacing(ReaderMetrics.lineSpacing)
            .tint(Theme.accent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown (whitespace preserved); `code` spans get a mono font and a subtle tint.
    static func inline(_ s: String) -> AttributedString {
        guard var a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                        failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return AttributedString(s)
        }
        for run in a.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                a[run.range].font = .system(size: ReaderMetrics.bodySize - 1, design: .monospaced)
                a[run.range].foregroundColor = Color(hex: 0xf0b48c)
                a[run.range].backgroundColor = Color.white.opacity(0.07)
            }
        }
        return a
    }
}
