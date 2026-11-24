import SwiftUI
import AppKit
import NotchCore

/// Expanded panel (mockup state 6 + interactions B + trimmed rows). Left: session list, unseen
/// (finished, not looked at) rows first — accent bar, tinted background, Claude's last sentence
/// and the time since it finished; other rows are one line: status dot, title + agent sprouts,
/// current context size (the dot shows working / idle / needs you). Name / path / context / total
/// tokens / model are in the row's tooltip.
/// Hover shows ≡ read, reply and ↗ (hovering an unseen row ~1s marks it seen); click a row to focus
/// its terminal; ≡ or scrolling down over a row opens its reply reader; the reply button opens an
/// inline quick-reply field.
/// Notch row: "SESSIONS N" header + the pill's mascot left of the notch; ⚙ / pin / ✕ right of it.
/// Right column (190pt): account usage bars (no header; stale marker sits in the notch row).
struct ExpandedView: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var ui: NotchUIState
    @Environment(\.notchStaticRender) private var staticRender

    var body: some View {
        VStack(spacing: 0) {
            // Top bar (notch row): left of the notch the "SESSIONS N · mark all seen" header and
            // the pill's mascot (drawn by IslandView at the pill's exact position); right of the
            // notch only icon buttons: stale-usage marker, ⚙ settings menu, pin, ✕.
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    // "SESSIONS N", or just "N" when the pill's mascot leaves no room for the word.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { sessionsLabel; countLabel }
                        countLabel
                    }
                    if appState.hasUnseen && markAllSeenFitsInHeader {
                        Button {
                            appState.markAllSeen()
                        } label: {
                            Text("· mark all seen")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                                .fixedSize()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Clear the highlight on every finished session")
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: appState.hasUnseen)
                .frame(width: headerWidth, alignment: .leading)
                .clipped()

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    if let staleText {
                        // Usage data is old (the Account header is gone).
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.amber)
                            .frame(width: 18, height: 20)
                            .help("Account usage \(staleText)")
                    }
                    if appState.hasUnseen && !markAllSeenFitsInHeader {
                        // No room beside the mascot: "mark all seen" as an icon.
                        BarIconButton(systemName: "checkmark.circle", help: "Mark all seen") { appState.markAllSeen() }
                    }
                    SettingsMenuButton(appState: appState, ui: ui)
                    BarIconButton(systemName: appState.isPinnedExpanded ? "pin.fill" : "pin",
                                  active: appState.isPinnedExpanded,
                                  help: appState.isPinnedExpanded ? "Unpin" : "Keep open") {
                        appState.toggleExpanded()
                    }
                    CloseButton {
                        // Mirrors Esc (NotchWindowController), plus: don't hover-expand again until
                        // the pointer has left the island once.
                        ui.suppressHoverUntilExit = true
                        ui.resetInteraction()
                        appState.collapse()
                    }
                }
            }
            .padding(.horizontal, 20)
            .frame(height: ui.geometry.notchHeight)

            HStack(alignment: .top, spacing: 22) {
                sessionsColumn
                accountColumn
                    .frame(width: 190)
                    .padding(.top, ExpandedMetrics.accountTopInset)   // align first bar label with first session name
            }
            .padding(.horizontal, 20)
            .padding(.top, ExpandedMetrics.topPad)
            .padding(.bottom, ExpandedMetrics.bottomPad)
            Spacer(minLength: 0)
        }
    }

    // MARK: Sessions

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.sessions.isEmpty {
                Text("No Claude Code sessions running")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(height: ExpandedMetrics.rowHeight, alignment: .leading)
            } else {
                let rows = VStack(spacing: 0) {
                    ForEach(appState.panelRows) { row in
                        let s = row.session
                        SessionRow(appState: appState, session: s,
                                   needsYou: appState.pendingPermissions.contains { $0.sessionId == s.sessionId },
                                   depth: row.depth)
                        let subRows = appState.subagentRows(for: s.sessionId)
                        if !subRows.isEmpty {
                            SubagentList(appState: appState, sessionId: s.sessionId, rows: subRows)
                                .padding(.bottom, ExpandedMetrics.subListBottomPad)
                        }
                        if ui.replyTargetId == s.sessionId, s.isClaudeDesktop {
                            DesktopReplyButton { appState.focusSession(id: s.sessionId); ui.replyTargetId = nil }
                                .frame(height: ExpandedMetrics.replyHeight - 6)
                                .padding(.bottom, 6)
                        } else if ui.replyTargetId == s.sessionId {
                            ReplyField(slot: ExpandedMetrics.replySlot(s.sessionId), placeholder: "Reply to \(s.name)…", autoFocus: true,
                                       disabledReason: ReplyField.disabledReason(appState: appState, sessionId: s.sessionId)) { text in
                                guard appState.sendReply(sessionId: s.sessionId, text: text) else { return }
                                ui.replyTargetId = nil
                                ui.releaseKey()
                                ui.confirm("✓ Sent to \(s.name)", detail: "“\(text)”", tone: .ok, duration: 1.3)
                            }
                            .frame(height: ExpandedMetrics.replyHeight - 6 + ExpandedMetrics.replyExtra(s, ui: ui))
                            .padding(.bottom, 6)
                        }
                    }
                }
                let viewport = ExpandedMetrics.sessionsViewportMax(strip: ui.geometry.notchHeight)
                let content = ExpandedMetrics.sessionsContentHeight(appState: appState, ui: ui)
                if content > viewport && staticRender {
                    // Offscreen renders (ImageRenderer can't draw NSScrollView content): the top.
                    Color.clear
                        .overlay(alignment: .top) { rows.fixedSize(horizontal: false, vertical: true) }
                        .clipped()
                        .frame(height: viewport)
                } else if staticRender {
                    rows
                } else {
                    // Always the same ScrollView (scrolling disabled while the list fits): switching
                    // between a ScrollView and the bare rows when a revealed row or a growing reply
                    // field crosses the viewport recreated every row (onDisappear un-revealed the
                    // hovered row, the reply field lost its text view mid-typing).
                    // NotchWindowController reads the scroll position from the NSScrollView.
                    ScrollView(.vertical, showsIndicators: false) { rows }
                        .scrollDisabled(content <= viewport)
                        .frame(height: min(content, viewport), alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Account

    private var accountColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.usage.windows.isEmpty {
                Text(appState.usage.stale ? "Usage unavailable" : "Loading usage…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .frame(height: ExpandedMetrics.usageRow, alignment: .topLeading)
            } else {
                ForEach(appState.usage.windows) { w in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(Fmt.usageLabel(w.label)).font(.system(size: 13)).foregroundStyle(.white)
                            Spacer()
                            Text("\(w.percent)%")
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(w.isNearLimit ? Theme.red : .white)
                        }
                        .lineLimit(1)
                        UsageBar(percent: w.percent, color: Fmt.usageColor(w.percent))
                            .padding(.top, 4)
                            .padding(.bottom, 2)
                        Text(Fmt.resets(w.resetsText))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    .frame(height: ExpandedMetrics.usageRow, alignment: .top)
                    .opacity(appState.usage.stale ? 0.7 : 1)
                }
            }
        }
    }

    private var sessionsLabel: some View {
        Text("SESSIONS")
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.66)
            .foregroundStyle(Theme.muted)
            .fixedSize()
    }

    private var countLabel: some View {
        Text("\(appState.sessions.count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .contentTransition(.numericText())
            .fixedSize()
            .help("\(appState.sessions.count) sessions")
    }

    /// "SESSIONS N · mark all seen" fits left of the mascot (else ✓ goes to the right side).
    private var markAllSeenFitsInHeader: Bool {
        let semibold = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let w = PillLayout.textWidth("SESSIONS", font: semibold) + 6
            + PillLayout.textWidth("\(appState.sessions.count)", font: semibold)
            + PillLayout.textWidth("· mark all seen", font: NSFont.systemFont(ofSize: 11)) + 12
        return w <= headerWidth
    }

    /// Room for the header between the left padding and the shared mascot.
    private var headerWidth: CGFloat {
        let mascotX = IslandView.wingMascotLeading(appState: appState, ui: ui, bodyWidth: NotchGeometry.expandedSize.width)
        return max(40, mascotX - 20 - 8)
    }

    private var staleText: String? {
        guard appState.usage.stale else { return nil }
        if let at = appState.usage.fetchedAt { return "stale · \(Fmt.duration(since: at)) ago" }
        return "stale"
    }
}

/// One session row (trimmed): [accent bar] dot  title + sprouts / last sentence  context  ≡ ↩  time
/// (time = since the last interaction, muted; unseen rows: since it finished, orange / amber).
/// Resting on a row for `ExpandedMetrics.revealDelay` shows its truncated title / last sentence
/// in full (up to 3 lines each); the row grows (heights from ExpandedMetrics.revealExtra).
/// No status chip: the dot says it (green pulsing = working, grey = idle, amber = needs you).
/// Click = focus the terminal (Claude Desktop sessions: activate Claude Desktop; their ↩ opens a
/// "Reply in Claude ↗" button instead of the reply field); ≡ or scrolling down over the row = open the reply reader.
struct SessionRow: View {
    @ObservedObject var appState: AppState
    let session: ClaudeSession
    let needsYou: Bool
    /// Claude Desktop side session nesting (0 = top level): the row is indented under its parent.
    var depth: Int = 0
    @EnvironmentObject private var ui: NotchUIState
    @StateObject private var hovering = LocalState(false)
    @StateObject private var seenTask = LocalState<Task<Void, Never>?>(nil)

    /// Seconds of hover after which an unseen row counts as seen.
    static let hoverSeenDelay: Double = 1.0

    private var id: String { session.sessionId }
    /// Two-line layout (frozen while the panel is open, see AppState.panelHighlight).
    private var highlighted: Bool { appState.panelHighlightIds.contains(id) }
    private var unseen: Bool { appState.isUnseen(id) }
    private var waiting: Bool { unseen && appState.unseenKind(for: id) == .waiting }
    private var accent: Color { waiting ? Theme.amber : Theme.accent }
    private var revealed: Bool { ui.revealedRowId == id }
    private var indent: CGFloat { ExpandedMetrics.indent(depth: depth) }

    /// The unseen row's second line.
    static func snippet(_ s: ClaudeSession) -> String { AttentionText.lastSentence(s.lastAssistantText) ?? "Finished" }

    var body: some View {
        let extra = ExpandedMetrics.revealExtra(session, appState: appState, ui: ui)
        let lines = revealed ? ExpandedMetrics.revealMaxLines : 1
        HStack(spacing: ExpandedMetrics.rowSpacing) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(unseen ? accent : Color.clear)
                .frame(width: 3, height: (highlighted ? 30 : 18) + extra)
            StatusDot(color: dotColor, pulse: session.status == .busy || needsYou || (unseen && !waiting),
                      period: needsYou ? 0.9 : unseen ? 2.0 : 1.4)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(lines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: revealed)
                        .layoutPriority(2)      // truncates last
                    let running = appState.subagents(for: id).runningCount
                    if running > 0 {
                        SproutPips(running: running)
                            .help(running == 1 ? "1 subagent running" : "\(running) subagents running")
                    }
                }
                if highlighted {
                    Text(Self.snippet(session))
                        .font(.system(size: 11))
                        .foregroundStyle(unseen ? Theme.quote : Theme.muted)
                        .lineLimit(lines)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: revealed)
                        // Scrolling over the snippet always opens the reader (never the list).
                        .onHover { ui.setReadTarget(.init(sessionId: id, snippet: true), hovering: $0) }
                }
            }
            // Revealed: exactly the width ExpandedMetrics measured the wrapped text with.
            .frame(width: revealed ? ExpandedMetrics.rowTextWidth - indent : nil, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 4)
            // Current context window (drops after /compact), not the cumulative total.
            Text(Fmt.context(session.tokens.lastContext))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .frame(width: ExpandedMetrics.contextWidth, alignment: .trailing)
            HStack(spacing: 2) {
                Button {
                    appState.openReader(sessionId: id)
                } label: {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Read reply (or scroll)")
                .onHover { ui.setReadTarget(.init(sessionId: id, snippet: true), hovering: $0) }
                let dialogOpen = appState.terminalDialogMayBeOpen(id)
                Button {
                    // Claude may be showing a dialog in the terminal: the reply's Enter would answer it.
                    if dialogOpen { if ui.replyTargetId == id { ui.replyTargetId = nil }; return }
                    ui.replyTargetId = ui.replyTargetId == id ? nil : id
                } label: {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(ui.replyTargetId == id ? Theme.accent : Theme.muted)
                        .opacity(dialogOpen ? 0.35 : 1)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Claude Desktop sessions: the slot below holds "Reply in Claude ↗", not a field.
                .help(dialogOpen ? ReplyField.terminalDialogHelp
                      : session.isClaudeDesktop ? "Reply in Claude Desktop" : "Quick reply")
            }
            .frame(width: ExpandedMetrics.buttonsWidth)
            .opacity(hovering.value || ui.replyTargetId == id ? 1 : 0.3)
            timeLabel
                .frame(width: ExpandedMetrics.timeWidth, alignment: .trailing)
        }
        .padding(.trailing, ExpandedMetrics.rowTrailing)
        .frame(height: (highlighted ? ExpandedMetrics.unseenRowHeight : ExpandedMetrics.rowHeight) - 4 + extra)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background))
        .animation(.easeInOut(duration: 0.25), value: unseen)
        .contentShape(Rectangle())
        // Side session: indented under the session that started it, with a thin guide line.
        .padding(.leading, indent)
        .overlay(alignment: .leading) {
            if depth > 0 {
                Rectangle()
                    .fill(Theme.muted.opacity(0.35))
                    .frame(width: 1)
                    .padding(.leading, indent - ExpandedMetrics.indentStep / 2)
                    .padding(.vertical, -2)
            }
        }
        .onHover { inside in
            hovering.value = inside
            ui.rowHover(id, inside: inside)
            ui.setReadTarget(.init(sessionId: id, snippet: false), hovering: inside)
            seenTask.value?.cancel()
            seenTask.value = nil
            guard inside, unseen else { return }
            let app = appState, sid = id
            seenTask.value = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.hoverSeenDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                app.markSeen(sessionId: sid)
            }
        }
        .onDisappear {
            seenTask.value?.cancel()
            ui.rowHover(id, inside: false)
        }
        .onTapGesture {
            appState.focusSession(id: id)
        }
        .padding(.vertical, 2)
        .help(tooltip)
    }

    /// Time since the last interaction ("now", "3m", "1h 6m", "2d"), muted; unseen rows show the
    /// time since they finished instead, in their accent colour (never both). Ticks every 30 s.
    private var timeLabel: some View {
        let unseenAt = unseen ? appState.unseenFinishedAt[id] : nil
        let at = unseenAt ?? session.lastInteractionAt
        return TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Text(RelativeTime.compact(since: at, now: ctx.date))
                .font(.system(size: unseenAt != nil ? 11.5 : 11, weight: unseenAt != nil ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(unseenAt != nil ? accent : Theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .help(unseenAt != nil ? "Finished \(Fmt.duration(since: at)) ago" : "Last activity \(Fmt.duration(since: at)) ago")
    }

    private var background: Color {
        if hovering.value { return unseen ? (waiting ? Theme.waitingRow : Theme.doneRow).opacity(0.75) : Theme.rowHover }
        if unseen { return waiting ? Theme.waitingRow : Theme.doneRow }
        return .clear
    }

    private var dotColor: Color {
        if needsYou { return Theme.amber }
        if session.status == .busy { return Theme.green }
        if unseen { return accent }
        return Theme.muted
    }

    /// "Click: open the terminal · scroll down or ≡: read the reply" + name, path, context, total, model.
    private var tooltip: String {
        var parts = [session.name, Fmt.abbreviatePath(session.cwd),
                     "context \(Fmt.context(session.tokens.lastContext)) · \(Fmt.tokens(session.tokens)) tokens total"]
        if let m = Fmt.modelName(session) { parts.append(m) }
        if session.isClaudeDesktop {
            // "Claude Desktop · ~/code/acme-api · context 69k · …"
            parts[0] = "Claude Desktop"
            let parent = session.desktop?.parentTitle.map { "\nSide session of “\($0)”" } ?? ""
            return "Click to show in Claude Desktop · scroll down (or ≡) to read Claude's reply\n"
                + parts.joined(separator: " · ") + "\n" + session.name + parent
        }
        return "Click to open the terminal · scroll down (or ≡) to read Claude's reply\n" + parts.joined(separator: " · ")
    }
}

/// Option D "tiny sprouts": one 5x5 pixel sprout (2pt pixels) per running subagent, at most
/// `AgentPips.maxPips`, then "+N" in small orange text. They pulse in a gentle wave (static with
/// Reduce Motion and in offscreen renders).
struct SproutPips: View {
    let running: Int
    @Environment(\.notchStaticRender) private var staticRender

    static let pixel: CGFloat = 2
    static var size: CGFloat { pixel * 5 }
    static let gap: CGFloat = 2

    /// Laid-out width (pips + "+N").
    static func width(running: Int) -> CGFloat {
        let l = AgentPips.layout(running: running)
        var w = CGFloat(l.pips) * size + CGFloat(max(0, l.pips - 1)) * gap
        if l.overflow > 0 {
            let t = ("+\(l.overflow)" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)])
            w += 3 + ceil(t.width)
        }
        return w
    }

    var body: some View {
        let l = AgentPips.layout(running: running)
        HStack(spacing: 3) {
            if staticRender || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                HStack(spacing: Self.gap) {
                    ForEach(0..<l.pips, id: \.self) { _ in
                        Canvas { ctx, _ in SproutPipArt.draw(in: &ctx, p: Self.pixel) }
                            .frame(width: Self.size, height: Self.size)
                    }
                }
            } else {
                SproutPipsLayerView(count: l.pips)
                    .frame(width: CGFloat(l.pips) * Self.size + CGFloat(max(0, l.pips - 1)) * Self.gap, height: Self.size)
            }
            if l.overflow > 0 {
                Text("+\(l.overflow)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }
}

/// The sprout pip sprite (see trim-rows.html): two leaves on a stem, 5x5.
enum SproutPipArt {
    static let leaf: UInt32 = 0x4ade80
    static let stem: UInt32 = 0x22a35a
    /// (x, y, w, h, colour) in sprite pixels.
    static let rects: [(CGFloat, CGFloat, CGFloat, CGFloat, UInt32)] = [
        (0, 0, 2, 1, leaf), (3, 0, 2, 1, leaf), (1, 1, 3, 1, leaf), (2, 2, 1, 3, stem),
    ]

    static func draw(in ctx: inout GraphicsContext, p: CGFloat) {
        for r in rects {
            ctx.fill(Path(CGRect(x: r.0 * p, y: r.1 * p, width: r.2 * p, height: r.3 * p)), with: .color(Color(hex: r.4)))
        }
    }
}

/// Live pips: Core Animation layers with a staggered opacity pulse (no SwiftUI redraws).
struct SproutPipsLayerView: NSViewRepresentable {
    let count: Int
    func makeNSView(context: Context) -> SproutPipsNSView { SproutPipsNSView(count: count) }
    func updateNSView(_ v: SproutPipsNSView, context: Context) { v.configure(count: count) }
}

final class SproutPipsNSView: NSView {
    private var count = -1
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        configure(count: count)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int) {
        guard count != self.count, let root = layer else { return }
        self.count = count
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let p = SproutPips.pixel, size = SproutPips.size
        let now = CACurrentMediaTime()
        for i in 0..<count {
            let pip = CALayer()
            pip.frame = CGRect(x: CGFloat(i) * (size + SproutPips.gap), y: 0, width: size, height: size)
            for r in SproutPipArt.rects {
                let px = CALayer()
                // Layer coordinates here are flipped by the view (isFlipped): y grows downward.
                px.frame = CGRect(x: r.0 * p, y: r.1 * p, width: r.2 * p, height: r.3 * p)
                px.backgroundColor = NSColor(Color(hex: r.4)).cgColor
                pip.addSublayer(px)
            }
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.35
            a.duration = 0.6
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.beginTime = now + Double(i) * 0.2      // the wave
            a.fillMode = .backwards
            a.isRemovedOnCompletion = false
            pip.add(a, forKey: "wave")
            root.addSublayer(pip)
        }
    }
}

/// Small "×" in the notch row, styled like the pin button: closes the panel even when pinned.
struct CloseButton: View {
    let action: () -> Void
    @StateObject private var hovering = LocalState(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering.value ? Color.white : Theme.muted)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .help("Close")
    }
}

// MARK: - Subagents

/// Compact list of a session's subagents under its row: Agent-tool subagents and workflow runs
/// (header + their running agents), at most `SubagentRules.maxRowsPerSession` rows + "+N more".
/// Rows have a fixed height (`ExpandedMetrics.subRowHeight`) so the panel height is computable.
struct SubagentList: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var ui: NotchUIState
    let sessionId: String
    let rows: [SessionSubagents.Row]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                // No hover highlight / haptic tick: clicking focuses the session, scrolling reads it.
                SubagentRowView(row: row) { appState.focusSession(id: sessionId) }
                    .onHover { ui.setReadTarget(.init(sessionId: sessionId, snippet: false), hovering: $0) }
            }
        }
        // Align the glyph column under the session's text (bar 3 + 9 + dot 10 + 9, minus the
        // sub-row's own 6pt padding).
        .padding(.leading, 25)
    }
}

struct SubagentRowView: View {
    let row: SessionSubagents.Row
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: ExpandedMetrics.subRowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private var content: some View {
        switch row {
        case .agent(let a, let nested):
            if nested { Color.clear.frame(width: 10) }
            glyph(a.status)
            Text(a.description)
                .foregroundStyle(a.status == .stalled ? Theme.muted : Color.white.opacity(0.88))
                .truncationMode(.tail)
                // Fixed width so the last-action column lines up (nested rows are indented by 16).
                .frame(width: nested ? 134 : 150, alignment: .leading)
            if let action = a.lastAction {
                Text(action)
                    .foregroundStyle(Theme.muted.opacity(0.85))
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            ElapsedText(running: a.status == .running, startedAt: a.startedAt, fixed: a.elapsed(now: Date()))
        case .workflow(let w):
            Image(systemName: "gearshape.fill")
                .font(.system(size: 8.5))
                .foregroundStyle(w.status == .running ? Theme.accent : Theme.muted)
                .frame(width: 10)
            Text(w.name)
                .foregroundStyle(Color.white.opacity(0.88))
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(workflowDetail(w))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .truncationMode(.tail)
            if w.status == .done { glyph(.done) }
            Spacer(minLength: 4)
            ElapsedText(running: w.status == .running, startedAt: w.startedAt, fixed: w.elapsed(now: Date()))
        case .more(let n):
            Color.clear.frame(width: 10)
            Text("+\(n) more").foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
    }

    private func workflowDetail(_ w: WorkflowInfo) -> String {
        var parts: [String] = []
        if let p = w.phase { parts.append(p) }
        parts.append("\(w.doneCount)/\(w.totalCount)")
        return "· " + parts.joined(separator: " · ")
    }

    @ViewBuilder private func glyph(_ status: SubagentStatus) -> some View {
        switch status {
        case .running:
            StatusDot(color: Theme.accent, pulse: true, period: 1.0)
                .scaleEffect(0.85)
                .frame(width: 10)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.green)
                .frame(width: 10)
        case .stalled:
            Text("–")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 10)
        }
    }
}

/// Right-aligned elapsed time: ticks every second while running, fixed total otherwise.
struct ElapsedText: View {
    let running: Bool
    let startedAt: Date
    let fixed: TimeInterval

    var body: some View {
        Group {
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Fmt.duration(seconds: ctx.date.timeIntervalSince(startedAt)))
                }
            } else {
                Text(Fmt.duration(seconds: fixed))
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(Theme.muted)
        .fixedSize()
    }
}
