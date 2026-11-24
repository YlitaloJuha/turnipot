import AppKit
import SwiftUI
import NotchCore

/// UI-only state that is not part of AppState: geometry (changes with screens), short-lived
/// confirmations, "sticky" finished drop-down while the user interacts with it, the session whose
/// inline reply field is open, and keyboard-focus plumbing for the non-activating panel.
@MainActor
final class NotchUIState: ObservableObject {
    struct Confirmation: Equatable {
        enum Tone { case ok, bad, neutral }
        let id = UUID()
        var text: String
        var detail: String?
        var tone: Tone
        /// Extra explanation lines (setup prompts: what will change, paths).
        var lines: [String] = []
        /// Buttons (setup prompts, update notice); empty = a plain flash.
        var actions: [ConfirmationAction] = []

        var isPrompt: Bool { !actions.isEmpty || !lines.isEmpty }
        static func == (a: Confirmation, b: Confirmation) -> Bool { a.id == b.id }
    }

    struct ConfirmationAction: Identifiable {
        enum Role { case primary, destructive, normal }
        let id = UUID()
        var title: String
        var role: Role = .normal
        /// Runs after the prompt closed (it may show a new confirmation).
        var run: @MainActor () -> Void = {}
    }

    @Published var geometry: NotchGeometry
    @Published var confirmation: Confirmation?
    /// Keep showing this session's finished drop-down after its event expires (user is hovering /
    /// typing a reply in it).
    @Published var stickyFinishedId: String?
    /// Session whose inline reply field is open in the expanded panel.
    @Published var replyTargetId: String?
    /// A ReplyField currently has keyboard focus.
    @Published var isEditing = false
    /// Bumped whenever a ReplyField should grab focus (after the panel became key).
    @Published var focusRequest = 0
    /// Quick-reply drafts by field slot ("reader-<id>", "row-<id>", "finished-<id>"); not
    /// published (the field re-renders itself while typing), kept so a reopened field shows it.
    var replyDrafts: [String: String] = [:]
    /// Height each reply field adds over one line (it wraps up to 5 lines); the containers
    /// (ReaderMetrics, ExpandedMetrics, finished size) add it so the island grows with the field.
    @Published var replyFieldExtra: [String: CGFloat] = [:]
    /// Session row showing its truncated title / last sentence in full (hover-to-reveal).
    @Published private(set) var revealedRowId: String?
    private var rowReveal = RowReveal(delay: ExpandedMetrics.revealDelay)
    private var revealTask: Task<Void, Never>?

    /// SessionRow hover in / out: reveal after `ExpandedMetrics.revealDelay` of resting on it.
    func rowHover(_ id: String, inside: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if inside {
            let due = rowReveal.enter(id, at: now)
            revealTask?.cancel()
            revealTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, due - now) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.applyReveal(self.rowReveal.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        } else {
            rowReveal.leave(id)
            applyReveal(rowReveal.revealed)
        }
    }

    /// Render / demo only.
    func forceReveal(_ id: String?) { revealedRowId = id }

    private func applyReveal(_ id: String?) {
        guard revealedRowId != id else { return }
        // The row (and the island around it) grows on the island's spring, shrinks without bounce.
        let spring = id == nil ? IslandMotion.shrinkSpring : IslandMotion.growSpring
        if reduceMotion { revealedRowId = id } else { withAnimation(.spring(spring)) { revealedRowId = id } }
    }

    /// Reader overscroll-back cue: 0…1 of the way to going back to the list (0 = hidden).
    @Published var readerBackProgress: Double = 0
    /// Set by the panel's close button: ignore hover-expand until the pointer has left the
    /// island once (NotchWindowController clears it on exit), so closing doesn't bounce open.
    var suppressHoverUntilExit = false
    /// The pointer has been over the "While you were away" drop-down: leaving it dismisses it.
    var awaySummaryHovered = false
    /// When the away summary appeared (clicks elsewhere in the first moments don't dismiss it:
    /// the click that ended the idle period would otherwise close it unseen).
    var awaySummaryShownAt: Date?

    // MARK: Questions / plans (AskUserQuestion / ExitPlanMode drop-downs)

    /// In-progress answers of the question drop-down (one request at a time).
    struct QuestionDraft: Equatable {
        var requestId: UUID
        var step = 0
        var selections: [QuestionSelection]
        /// Questions whose "Other…" text field is open.
        var otherOpen: Set<Int> = []

        init(requestId: UUID, count: Int) {
            self.requestId = requestId
            selections = Array(repeating: QuestionSelection(), count: count)
        }
    }
    @Published var questionDraft: QuestionDraft?

    /// The draft for `request` (a fresh one if the stored draft belongs to another request).
    func draft(for request: PermissionRequest) -> QuestionDraft {
        if let d = questionDraft, d.requestId == request.id { return d }
        return QuestionDraft(requestId: request.id, count: request.questions?.count ?? 0)
    }

    func updateDraft(for request: PermissionRequest, _ change: (inout QuestionDraft) -> Void) {
        var d = draft(for: request)
        change(&d)
        questionDraft = d
    }

    /// Plan drop-down: "Keep planning…" feedback field open for this request, and its text.
    @Published var planFeedbackRequestId: UUID?
    @Published var planFeedbackText = ""

    // MARK: Reply reader

    /// Turns loaded for `readerTurnsSessionId` (newest last), filled by ReplyLoader.
    @Published var readerTurns: [ReplyTurn] = []
    @Published var readerTurnsSessionId: String?
    /// Turn being read; nil = follow the newest one (new replies show up as they land).
    @Published var readerTurnId: String?
    /// What a scroll-down under the pointer would open in the reader (set by row / message hover).
    struct ReadTarget: Equatable {
        var sessionId: String
        /// Over a reply snippet / message / read affordance: scrolling there always opens the
        /// reader (never scrolls the session list).
        var snippet: Bool
    }
    var readTarget: ReadTarget?

    func setReadTarget(_ t: ReadTarget?, hovering: Bool) {
        if hovering { readTarget = t } else if readTarget == t { readTarget = nil }
    }

    /// Turns the reader shows: empty turns are hidden, except a newest one while the session works.
    func readerVisibleTurns(busy: Bool) -> [ReplyTurn] {
        var t = readerTurns
        if let last = t.last, last.isEmpty, !busy { t.removeLast() }
        return t
    }

    /// Index into `readerVisibleTurns` of the turn on screen.
    func readerIndex(in turns: [ReplyTurn]) -> Int {
        if let id = readerTurnId, let i = turns.firstIndex(where: { $0.id == id }) { return i }
        return max(0, turns.count - 1)
    }

    /// ← / → and the footer links.
    func readerStep(_ delta: Int, busy: Bool) {
        let turns = readerVisibleTurns(busy: busy)
        guard !turns.isEmpty else { return }
        let i = min(max(readerIndex(in: turns) + delta, 0), turns.count - 1)
        readerTurnId = i == turns.count - 1 ? nil : turns[i].id
    }

    /// Launch / quit / screen-change animation phases (driven by NotchWindowController):
    /// `islandShown == false` tucks the shape into the physical notch; `contentShown` fades the
    /// island's content (staggered after the shape); `islandOpacity` is only used for the
    /// Reduce Motion fade. Defaults are "fully visible" (offscreen renders, demo).
    @Published var islandShown = true
    @Published var contentShown = true
    @Published var islandOpacity: Double = 1
    /// The mascot is pulled up into the notch (launch: it drops down after the pill opened;
    /// quit: it pulls up before the island retracts).
    @Published var mascotRetracted = false

    /// System "Reduce motion": springs and slides become plain fades.
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Set by NotchWindowController.
    var requestKeyHandler: (() -> Void)?
    var releaseKeyHandler: (() -> Void)?

    private var confirmationTask: Task<Void, Never>?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    /// Click / hot-key guard for the needs-you drop-downs: actions on a request do nothing for
    /// 400 ms after it appeared (or the queue advanced to it). Not published.
    private var needsYouGate = FreshContentGate()

    /// The needs-you request on screen (nil = none); NotchWindowController calls this on every change.
    func needsYouShown(_ requestId: UUID?) { needsYouGate.show(requestId?.uuidString, at: Date()) }

    /// May a button / hot key act on this request now? (False within 400 ms of it appearing.)
    func needsYouActionAllowed(_ requestId: UUID) -> Bool {
        needsYouGate.attempt(requestId.uuidString, at: Date())
    }

    /// Setup prompt / notice with explanation lines and buttons; closes after `duration`, a button
    /// or a click elsewhere. Buttons ignore clicks for 400 ms after it appears (FreshContentGate).
    func prompt(_ text: String, detail: String? = nil, lines: [String] = [], tone: Confirmation.Tone = .neutral,
                actions: [ConfirmationAction], duration: TimeInterval = 60) {
        var c = Confirmation(text: text, detail: detail, tone: tone)
        c.lines = lines
        c.actions = actions
        show(c, duration: duration)
        promptGate.show(c.id.uuidString, at: Date())
    }

    private var promptGate = FreshContentGate()

    /// A prompt button was clicked.
    func runPromptAction(_ action: ConfirmationAction, in prompt: Confirmation) {
        guard confirmation?.id == prompt.id, promptGate.attempt(prompt.id.uuidString, at: Date()) else { return }
        confirmationTask?.cancel()
        confirmation = nil
        action.run()
    }

    func dismissPrompt() {
        guard confirmation?.isPrompt == true else { return }
        confirmationTask?.cancel()
        confirmation = nil
    }

    func confirm(_ text: String, detail: String? = nil, tone: Confirmation.Tone, duration: TimeInterval = 1.2) {
        show(Confirmation(text: text, detail: detail, tone: tone), duration: duration)
    }

    private func show(_ c: Confirmation, duration: TimeInterval) {
        confirmation = c
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.confirmation = nil
        }
    }

    func requestKey() { requestKeyHandler?() }
    func releaseKey() { isEditing = false; releaseKeyHandler?() }

    /// End any in-island interaction (reply editing, sticky drop-downs).
    func resetInteraction() {
        stickyFinishedId = nil
        replyTargetId = nil
        if isEditing { releaseKey() }
    }
}

/// What the island is actually showing. Derived from AppState.mode plus NotchUIState.
enum Presentation: Equatable {
    /// Collapsed pill; `wing` = width of each side of the notch (content-driven).
    case collapsed(wing: CGFloat)
    case finished(sessionId: String)
    case awaySummary
    case permission(requestId: UUID)
    case expanded
    case nearLimit
    case usageReset
    case confirmation
    /// Reply reader (AppState.readerSessionId).
    case reader(sessionId: String)

    var isCollapsed: Bool { if case .collapsed = self { return true }; return false }

    /// Stable identity for content transitions.
    var kind: String {
        switch self {
        case .collapsed: return "collapsed"
        case .finished(let s): return "finished-\(s)"
        case .permission(let id): return "permission-\(id)"
        case .expanded: return "expanded"
        case .nearLimit: return "nearLimit"
        case .usageReset: return "usageReset"
        case .confirmation: return "confirmation"
        case .awaySummary: return "awaySummary"
        case .reader(let s): return "reader-\(s)"
        }
    }

    @MainActor
    static func current(appState: AppState, ui: NotchUIState) -> Presentation {
        if case .permission(let id) = appState.mode, appState.permission(id: id) != nil {
            return .permission(requestId: id)
        }
        // The reader is pinned; it shows confirmations inline (no island resize).
        if case .reader(let sid) = appState.mode, appState.session(id: sid) != nil { return .reader(sessionId: sid) }
        if ui.confirmation != nil { return .confirmation }
        if appState.mode == .awaySummary, appState.awaySummary != nil { return .awaySummary }
        if let sid = ui.stickyFinishedId, appState.session(id: sid) != nil {
            return .finished(sessionId: sid)
        }
        switch appState.mode {
        case .finished(let sid) where appState.session(id: sid) != nil:
            return .finished(sessionId: sid)
        case .expanded:
            return .expanded
        case .nearLimit where appState.usage.nearLimitWindow != nil:
            return .nearLimit
        case .usageReset where appState.usageReset != nil:
            return .usageReset
        default:
            return .collapsed(wing: PillLayout.wing(appState: appState, ui: ui))
        }
    }

    /// Right edge pulled in by this much (one-sided idle pill, see PillLayout.oneSided).
    @MainActor
    func rightTrim(appState: AppState) -> CGFloat {
        if case .collapsed(let wing) = self, PillLayout.oneSided(appState: appState) {
            return wing + PillLayout.oneSidedTuck
        }
        return 0
    }

    /// Body size (shoulders excluded).
    @MainActor
    func bodySize(appState: AppState, ui: NotchUIState) -> CGSize {
        let g = ui.geometry
        let strip = g.notchHeight
        switch self {
        case .collapsed(let wing):
            return g.collapsedSize(wing: wing)
        case .awaySummary:
            return CGSize(width: NotchGeometry.awaySummaryWidth,
                          height: strip + AwaySummaryMetrics.bodyHeight(appState.awaySummary))
        case .finished(let sid):
            let s = appState.session(id: sid)
            let hasText = !(s?.lastAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let body = hasText ? NotchGeometry.finishedSize.height : NotchGeometry.finishedSize.height - 42
            let replyExtra = s?.isClaudeDesktop == false ? ui.replyFieldExtra[FinishedView.replySlot(sid)] ?? 0 : 0
            return CGSize(width: NotchGeometry.finishedSize.width, height: strip + body + replyExtra)
        case .permission(let rid):
            if let r = appState.permission(id: rid) {
                switch r.kind {
                case .question where r.questions != nil:
                    return CGSize(width: NotchGeometry.questionWidth, height: QuestionMetrics.height(request: r, ui: ui))
                case .plan where r.plan != nil:
                    return CGSize(width: NotchGeometry.questionWidth, height: PlanMetrics.height(request: r, ui: ui))
                default: break
                }
            }
            return CGSize(width: NotchGeometry.permissionSize.width, height: strip + NotchGeometry.permissionSize.height)
        case .expanded:
            return CGSize(width: NotchGeometry.expandedSize.width,
                          height: ExpandedMetrics.height(appState: appState, ui: ui, strip: strip))
        case .nearLimit:
            return CGSize(width: NotchGeometry.nearLimitSize.width, height: strip + NotchGeometry.nearLimitSize.height)
        case .usageReset:
            return CGSize(width: NotchGeometry.usageResetSize.width, height: strip + NotchGeometry.usageResetSize.height)
        case .reader(let sid):
            return CGSize(width: NotchGeometry.readerWidth,
                          height: ReaderMetrics.height(appState: appState, ui: ui, sessionId: sid))
        case .confirmation:
            if let c = ui.confirmation, c.isPrompt {
                return CGSize(width: NotchGeometry.promptWidth, height: strip + ConfirmationView.promptHeight(c))
            }
            let h = ui.confirmation?.detail == nil ? NotchGeometry.confirmationSize.height : NotchGeometry.confirmationSize.height + 18
            return CGSize(width: NotchGeometry.confirmationSize.width, height: strip + h)
        }
    }

    var bottomRadius: CGFloat {
        switch self {
        case .collapsed: return NotchGeometry.collapsedBottomRadius
        case .confirmation: return 20
        case .finished, .permission, .nearLimit, .usageReset, .awaySummary: return 22
        case .expanded, .reader: return 26
        }
    }
}

/// Fixed row heights so the expanded island height can be computed without measuring.
enum ExpandedMetrics {
    /// Session rows: one line (idle / working), two lines for highlighted (unseen) rows.
    static let rowHeight: CGFloat = 34
    static let unseenRowHeight: CGFloat = 48
    static let replyHeight: CGFloat = 46
    static let header: CGFloat = 24
    static let usageRow: CGFloat = 46
    static let hero: CGFloat = 56
    static let topPad: CGFloat = 4
    static let accountTopInset: CGFloat = 6
    static let bottomPad: CGFloat = 18
    static let maxVisibleRows = 6
    /// Subagent rows under a session row, and the gap after the last one.
    static let subRowHeight: CGFloat = 20
    static let subListBottomPad: CGFloat = 4

    /// Height of one session block: row + its subagent list + open reply field.
    @MainActor
    static func sessionBlockHeight(_ s: ClaudeSession, appState: AppState, ui: NotchUIState) -> CGFloat {
        let sub = CGFloat(appState.subagentRows(for: s.sessionId).count)
        let row = appState.panelHighlightIds.contains(s.sessionId) ? unseenRowHeight : rowHeight
        return row + revealExtra(s, appState: appState, ui: ui) + (sub > 0 ? sub * subRowHeight + subListBottomPad : 0)
            + (ui.replyTargetId == s.sessionId ? replyHeight + replyExtra(s, ui: ui) : 0)
    }

    // Session row columns (fixed widths so a revealed row's text width, and so its height, is
    // known without measuring views): [bar 3] [dot 10] [text …] [spacer ≥4] [context] [≡ ↩] [time].
    static let rowSpacing: CGFloat = 9
    static let rowTrailing: CGFloat = 10
    static let contextWidth: CGFloat = 34
    static let buttonsWidth: CGFloat = 42
    static let timeWidth: CGFloat = 34
    /// Hover-to-reveal: resting on a row this long shows its truncated text in full (max lines).
    static let revealDelay: TimeInterval = RowReveal.defaultDelay
    static let revealMaxLines = 3
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let snippetFont = NSFont.systemFont(ofSize: 11)

    /// Indent per side-session level (Claude Desktop), and the deepest level drawn.
    static let indentStep: CGFloat = 14
    static let maxIndentDepth = 2
    static func indent(depth: Int) -> CGFloat { CGFloat(min(max(depth, 0), maxIndentDepth)) * indentStep }

    /// Width of a row's text column (title + sprouts / last sentence).
    static var rowTextWidth: CGFloat {
        replyFieldWidth - (3 + 10 + 4 + contextWidth + buttonsWidth + timeWidth + 6 * rowSpacing + rowTrailing)
    }

    /// Lines `text` wraps to in `width` (1…revealMaxLines) and the height of one line.
    static func revealLines(_ text: String, font: NSFont, width: CGFloat) -> (lines: Int, lineHeight: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let line = ceil(("Xg" as NSString).boundingRect(with: CGSize(width: 1000, height: 1000), options: opts, attributes: attrs).height)
        let h = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: opts, attributes: attrs).height
        return (RowReveal.lines(textHeight: Double(h), lineHeight: Double(line), maxLines: revealMaxLines), line)
    }

    /// Height a revealed row adds: its title (and an unseen row's last sentence) wrapped.
    @MainActor
    static func revealExtra(_ s: ClaudeSession, appState: AppState, ui: NotchUIState) -> CGFloat {
        guard ui.revealedRowId == s.sessionId else { return 0 }
        let running = appState.subagents(for: s.sessionId).runningCount
        let width = rowTextWidth - indent(depth: appState.panelRows.first { $0.id == s.sessionId }?.depth ?? 0)
        let title = revealLines(s.displayTitle, font: titleFont, width: width - (running > 0 ? 6 + SproutPips.width(running: running) : 0))
        var extra = CGFloat(title.lines - 1) * title.lineHeight
        if appState.panelHighlightIds.contains(s.sessionId) {
            let snip = revealLines(SessionRow.snippet(s), font: snippetFont, width: width)
            extra += CGFloat(snip.lines - 1) * snip.lineHeight
        }
        return extra
    }

    /// The row's quick-reply slot, its width (the sessions column) and its extra height while
    /// it holds more than one line.
    static func replySlot(_ sessionId: String) -> String { "row-\(sessionId)" }
    static var replyFieldWidth: CGFloat { NotchGeometry.expandedSize.width - 2 * 20 - 22 - 190 }
    @MainActor
    static func replyExtra(_ s: ClaudeSession, ui: NotchUIState) -> CGFloat {
        s.isClaudeDesktop ? 0 : ui.replyFieldExtra[replySlot(s.sessionId)] ?? 0
    }

    /// Unclipped height of the whole sessions list.
    @MainActor
    static func sessionsContentHeight(appState: AppState, ui: NotchUIState) -> CGFloat {
        guard !appState.sessions.isEmpty else { return rowHeight }
        return appState.sessions.reduce(0) { $0 + sessionBlockHeight($1, appState: appState, ui: ui) }
    }

    /// Tallest the sessions list may get before it scrolls (the panel's max height minus chrome).
    static func sessionsViewportMax(strip: CGFloat) -> CGFloat {
        NotchGeometry.expandedSize.height - strip - topPad - bottomPad
    }

    @MainActor
    static func height(appState: AppState, ui: NotchUIState, strip: CGFloat) -> CGFloat {
        // "Sessions" header lives in the notch row.
        let sessionsH = min(sessionsContentHeight(appState: appState, ui: ui), sessionsViewportMax(strip: strip))
        let windows = CGFloat(max(appState.usage.windows.count, 1))
        let usageH = accountTopInset + windows * usageRow   // headers live in the notch row
        let h = strip + topPad + max(sessionsH, usageH) + bottomPad
        return min(max(h, 180), NotchGeometry.expandedSize.height)
    }
}

// MARK: - Formatting helpers shared by views

enum Fmt {
    /// Tooltip of the ↗ buttons: where clicking takes you.
    static func showHelp(_ s: ClaudeSession?) -> String {
        s?.host == .claudeDesktop ? "Show in Claude Desktop" : "Open in the terminal"
    }

    /// Tokens shown in the UI: input + cache writes + output (cache reads excluded — they are
    /// re-reads of the same context and would dwarf everything else).
    static func tokens(_ t: TokenTotals) -> String {
        TokenTotals.format(t.input + t.cacheCreation + t.output)
    }

    /// Current context window, compact: "84k", "8.4k", "1.2M", "512"; "—" when unknown (0).
    static func context(_ n: Int) -> String {
        switch n {
        case ..<1: return "—"
        case ..<1_000: return "\(n)"
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1_000)
        case ..<1_000_000: return "\(Int((Double(n) / 1_000).rounded()))k"
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func duration(since date: Date, now: Date = Date()) -> String {
        duration(seconds: now.timeIntervalSince(date))
    }

    static func duration(seconds: TimeInterval) -> String {
        let secs = max(0, Int(seconds))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }

    static func durationPrecise(since date: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return duration(since: date, now: now)
    }

    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// "Opus 5.5" from "opus-5-5" style short model names.
    static func modelName(_ s: ClaudeSession) -> String? {
        guard let m = s.shortModel else { return nil }
        let parts = m.split(separator: "-")
        guard let family = parts.first else { return m }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// Usage window label as in the mockup: "Session (5h)", "Week · all", "Week · Fable".
    static func usageLabel(_ label: String) -> String {
        let l = label.lowercased()
        if l == "session" { return "Session (5h)" }
        if l.hasPrefix("week") {
            if let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"), open < close {
                var inner = String(label[label.index(after: open)..<close])
                if inner.lowercased() == "all models" { inner = "all" }
                return "Week · \(inner)"
            }
            return "Week"
        }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Short suffix for the collapsed pill: "wk", "5h", ...
    static func usageShortLabel(_ label: String) -> String {
        let l = label.lowercased()
        if l == "session" { return "5h" }
        if l.hasPrefix("week") {
            if let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"), open < close {
                let inner = label[label.index(after: open)..<close]
                if inner.lowercased() != "all models" { return "wk " + inner.prefix(5).lowercased() }
            }
            return "wk"
        }
        return String(l.prefix(4))
    }

    /// "resets Nov 20 at 9pm (America/Los_Angeles)" -> "resets Nov 20 at 9pm".
    static func resets(_ text: String) -> String {
        var t = text
        if let r = t.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) { t.removeSubrange(r) }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "" }
        return t.lowercased().hasPrefix("resets") ? t : "resets " + t
    }

    static func usageColor(_ percent: Int) -> Color {
        if percent >= NotchConstants.nearLimitPercent { return Theme.red }
        if percent >= 70 { return Theme.amber }
        return Theme.accent
    }
}

// MARK: - Collapsed pill layout

/// Wing width of the collapsed pill and the unseen badge that fits in it. Text widths are
/// measured with the same fonts the view uses, so the pill grows exactly as much as needed
/// (and never past `NotchGeometry.maxCollapsedWingWidth`: the badge then falls back to "N new").
@MainActor
enum PillLayout {
    static let leadingPad: CGFloat = 8          // 10 - the mascot frame's 1-pixel margin
    static let spacing: CGFloat = 4
    static let trailingPad: CGFloat = 6
    static let badgeHPad: CGFloat = 6
    static let badgeDot: CGFloat = 6
    static let badgeGap: CGFloat = 4
    static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    static func mascotWidth(strip: CGFloat) -> CGFloat {
        TurnipMascotView.frameSize(pixelSize: MascotView.pixelSize(forStrip: strip), layout: .compact).width
    }

    static func badgeWidth(_ b: PillBadge) -> CGFloat {
        badgeHPad * 2 + badgeDot + badgeGap + textWidth(b.text, font: badgeFont)
    }

    /// Green dot + busy count.
    static func busyWidth(_ count: Int) -> CGFloat {
        7 + 3 + textWidth("\(count)", font: countFont)
    }

    static func leftWidth(appState: AppState, ui: NotchUIState, badge: PillBadge?) -> CGFloat {
        var w = leadingPad + mascotWidth(strip: ui.geometry.notchHeight)
        if appState.isAnyBusy { w += spacing + busyWidth(appState.busySessions.count) }
        if let badge { w += spacing + badgeWidth(badge) }
        return w + trailingPad
    }

    /// Right wing: usage text + ring (CollapsedView.rightWing), e.g. "100% 5h" near the limit.
    static let usageGap: CGFloat = 6
    static let ringSize: CGFloat = 18
    static let rightTrailingPad: CGFloat = 10
    /// Clearance between the physical notch and the right wing's text: the notch's rounded bottom
    /// corner (and any rounding in the measured notch width) otherwise clips its first digit.
    static let rightLeadingPad: CGFloat = 8
    static let usageFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    static func rightWidth(appState: AppState) -> CGFloat {
        let text: String, font: NSFont
        if let w = appState.usage.nearLimitWindow {
            text = "\(w.percent)% \(Fmt.usageShortLabel(w.label))"; font = countFont
        } else if appState.isAnyBusy || appState.hasUnseen,
                  let w = appState.usage.sessionWindow ?? appState.usage.windows.first {
            text = "\(w.percent)%"; font = usageFont
        } else {
            return 0   // session count only: always fits
        }
        return rightLeadingPad + textWidth(text, font: font) + usageGap + ringSize + rightTrailingPad
    }

    static func badge(appState: AppState, ui: NotchUIState) -> PillBadge? {
        let c = appState.unseenCounts
        return PillBadge.choose(waiting: c.waiting, done: c.done) {
            leftWidth(appState: appState, ui: ui, badge: $0) <= NotchGeometry.maxCollapsedWingWidth
        }
    }

    /// Idle with no sessions: the right wing would only show a muted "0", so the pill drops it
    /// and is one-sided (mascot wing only; the right edge tucks under the physical notch).
    static func oneSided(appState: AppState) -> Bool {
        appState.usage.nearLimitWindow == nil && !appState.isAnyBusy && !appState.hasUnseen
            && appState.sessions.isEmpty
    }

    /// How far the right edge of a one-sided pill moves in: the whole right wing plus enough to
    /// hide the right shoulder and bottom-right corner under the notch (clear of its own rounded
    /// bottom corner).
    static let oneSidedTuck: CGFloat = 20

    static func wing(appState: AppState, ui: NotchUIState) -> CGFloat {
        let wide = appState.isAnyBusy || appState.isNearLimit || appState.hasUnseen
        // Both wings share one width: wide enough for the badge on the left and the usage text
        // on the right (a 3-digit "100% 5h" doesn't fit the default).
        var width = max(wide ? NotchGeometry.collapsedWingWidth : NotchGeometry.idleWingWidth,
                        ceil(rightWidth(appState: appState)))
        if let b = badge(appState: appState, ui: ui) {
            width = max(width, ceil(leftWidth(appState: appState, ui: ui, badge: b)))
        }
        return width
    }
}

// MARK: - Away summary layout

enum AwaySummaryMetrics {
    static let topPad: CGFloat = 2
    static let title: CGFloat = 24
    static let row: CGFloat = 26
    static let more: CGFloat = 22
    static let bottomPad: CGFloat = 12

    static func bodyHeight(_ s: AwaySummary?) -> CGFloat {
        let rows = CGFloat(s?.visibleItems.count ?? 0)
        let more = (s?.moreCount ?? 0) > 0 ? Self.more : 0
        return topPad + title + rows * row + more + bottomPad
    }
}
