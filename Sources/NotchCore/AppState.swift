import Foundation
import Combine

/// Single source of truth for the UI. All mutation happens on the main actor.
/// Monitors/bridges call the "Inputs" methods; views read the @Published properties
/// and call the "UI actions" methods.
@MainActor
public final class AppState: ObservableObject {

    // MARK: Published state

    /// Live sessions sorted by startedAt (oldest first).
    @Published public private(set) var sessions: [ClaudeSession] = []
    @Published public private(set) var usage: UsageSnapshot = .empty
    /// FIFO; the first element is the one shown in the permission drop-down.
    @Published public private(set) var pendingPermissions: [PermissionRequest] = []
    @Published public private(set) var events: [TransientEvent] = []
    /// Subagents (Agent-tool + workflow agents) per session id; only sessions that have any.
    @Published public private(set) var subagents: [String: SessionSubagents] = [:]
    /// Clock used for the last `updateSubagents` (row lists are built against it so the panel
    /// height and the rendered rows always agree).
    public private(set) var subagentsAsOf = Date()
    /// Current island presentation. Derived by `recomputeMode()`; do not set directly from views —
    /// use expand()/collapse()/setHovering().
    @Published public private(set) var mode: IslandMode = .collapsed
    /// True while the pointer is over the island (hover-expand).
    @Published public private(set) var isHovering: Bool = false
    /// True when the user explicitly expanded the panel by clicking.
    @Published public private(set) var isPinnedExpanded: Bool = false
    /// The near-limit banner was dismissed for the current window/percent bucket.
    @Published public private(set) var nearLimitDismissed: Bool = false

    /// Finished sessions the user hasn't looked at yet: sessionId -> when it went busy -> idle.
    /// Cleared by focus / reply / row hover / "mark all seen" / the session going busy again;
    /// dropped when the session ends. In memory only.
    @Published public private(set) var unseenFinishedAt: [String: Date] = [:]
    /// Last busy -> idle time per live session (kept after it was seen; orders the panel's
    /// highlighted rows while the panel stays open).
    public private(set) var lastFinishedAt: [String: Date] = [:]
    /// Sessions highlighted in the expanded panel: the unseen ones at the moment it opened plus
    /// any that finish while it is open. Frozen while the panel is open so rows don't jump or
    /// shrink under the pointer when one is marked seen; nil while the panel is closed.
    @Published public private(set) var panelHighlight: Set<String>?
    /// Set while the user is away (screen locked, asleep, idle >= 3 min): start of the away period.
    @Published public private(set) var awaySince: Date?
    /// "While you were away" drop-down content (shown until dismissed).
    @Published public private(set) var awaySummary: AwaySummary?
    /// Session whose reply reader is open (mode `.reader`); nil when closed. Pinned: hover-out
    /// doesn't close it; ✕ / esc / back / click outside do.
    @Published public private(set) var readerSessionId: String?
    /// Claude Desktop's session records (titles, side-session parents, which tab it shows).
    public private(set) var desktopSnapshot: ClaudeDesktopSessions.Snapshot = .empty
    /// Latest permission request time per session (for the away summary's "asked you something").
    private var lastAskedAt: [String: Date] = [:]
    /// Sessions whose terminal may be showing Claude's own permission / question / plan dialog
    /// (a request was handed back to the terminal). Quick reply is disabled for them.
    @Published public private(set) var terminalDialogs = TerminalDialogGuard() {
        didSet { if terminalDialogs.sessionIds != oldValue.sessionIds { sendGate?.setBlocked(terminalDialogs.sessionIds) } }
    }
    /// Shared with TerminalBridge so `send` refuses flagged sessions too.
    public var sendGate: TerminalSendGate? {
        didSet { sendGate?.setBlocked(terminalDialogs.sessionIds) }
    }

    // MARK: Dependencies

    public var terminal: TerminalControlling?
    private var permissionResponders: [UUID: (PermissionDecision) -> Void] = [:]
    private var permissionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var eventExpiry: [UUID: Task<Void, Never>] = [:]

    public init(terminal: TerminalControlling? = nil) {
        self.terminal = terminal
    }

    // MARK: Derived

    public var busySessions: [ClaudeSession] { sessions.filter { $0.status == .busy } }
    public var isAnyBusy: Bool { sessions.contains { $0.status == .busy } }
    public var aggregateTokens: TokenTotals { sessions.reduce(.zero) { $0 + $1.tokens } }
    /// Sum of every session's current context window (latest main-chain message).
    public var aggregateContext: Int { sessions.reduce(0) { $0 + $1.tokens.lastContext } }
    public var currentPermission: PermissionRequest? { pendingPermissions.first }
    public var isNearLimit: Bool { usage.nearLimitWindow != nil }

    public func subagents(for sessionId: String) -> SessionSubagents { subagents[sessionId] ?? .empty }
    /// Rows of the expanded panel's subagent list under this session.
    public func subagentRows(for sessionId: String) -> [SessionSubagents.Row] {
        subagents[sessionId]?.rows(now: subagentsAsOf) ?? []
    }

    public func session(id: String) -> ClaudeSession? { sessions.first { $0.sessionId == id } }
    /// Claude may be showing a dialog in this session's terminal: quick reply is unavailable.
    public func terminalDialogMayBeOpen(_ sessionId: String) -> Bool { terminalDialogs.isOpen(sessionId) }
    /// Whether a quick reply can be typed into the session right now (terminal host, no dialog).
    public func canQuickReply(_ sessionId: String) -> Bool {
        guard let s = session(id: sessionId), s.host == .terminal else { return false }
        return !terminalDialogs.isOpen(sessionId)
    }
    public func permission(id: UUID) -> PermissionRequest? { pendingPermissions.first { $0.id == id } }

    /// Most recent finished event still alive.
    public var latestFinishedSessionId: String? {
        for e in events.reversed() {
            if case .sessionFinished(let sid) = e.kind { return sid }
        }
        return nil
    }

    /// needs you > finished drop-down > near limit > working > unseen (happy) > sleeping.
    public var mascotMood: MascotMood {
        if !pendingPermissions.isEmpty { return .shake }
        if latestFinishedSessionId != nil { return .hop }
        if isNearLimit { return .sweat }
        if isAnyBusy { return .bouncing }
        if hasUnseen { return .hop }
        return .sleeping
    }

    // MARK: Derived — unseen

    public var hasUnseen: Bool { !unseenFinishedAt.isEmpty }
    public func isUnseen(_ sessionId: String) -> Bool { unseenFinishedAt[sessionId] != nil }

    /// done / waiting, from the session's current last assistant text.
    public func unseenKind(for sessionId: String) -> UnseenKind {
        AttentionText.classify(session(id: sessionId)?.lastAssistantText)
    }

    /// Unseen sessions, waiting first, then done, newest first.
    public var unseenItems: [UnseenItem] {
        let items = unseenFinishedAt.map { UnseenItem(sessionId: $0.key, finishedAt: $0.value, kind: unseenKind(for: $0.key)) }
        return items.sorted {
            if $0.kind != $1.kind { return $0.kind == .waiting }
            if $0.finishedAt != $1.finishedAt { return $0.finishedAt > $1.finishedAt }
            return $0.sessionId < $1.sessionId
        }
    }
    public var unseenCounts: (waiting: Int, done: Int) {
        let items = unseenItems
        let w = items.filter { $0.kind == .waiting }.count
        return (w, items.count - w)
    }

    /// Sessions highlighted in the panel (see `panelHighlight`; the live unseen set while closed).
    public var panelHighlightIds: Set<String> { panelHighlight ?? Set(unseenFinishedAt.keys) }

    /// Expanded panel rows: highlighted rows first (waiting, then done, newest first), then the
    /// rest; Claude Desktop side sessions follow the session that started them (depth 1, 2, …).
    public var panelRows: [AttentionRules.PanelRow] {
        var map: [String: UnseenItem] = [:]
        for id in panelHighlightIds {
            guard let at = unseenFinishedAt[id] ?? lastFinishedAt[id] else { continue }
            map[id] = UnseenItem(sessionId: id, finishedAt: at, kind: unseenKind(for: id))
        }
        return AttentionRules.groupedBySpawn(AttentionRules.panelOrder(sessions, highlighted: map))
    }

    /// `panelRows` without the depths.
    public var panelSessions: [ClaudeSession] { panelRows.map(\.session) }

    // MARK: Inputs — SessionMonitor

    /// Replace the full set of live sessions. Preserves tokens/model/text already known for
    /// sessions whose incoming value is empty. Emits sessionFinished on busy -> idle,
    /// sessionStarted / sessionEnded on appearance / disappearance.
    public func updateSessions(_ incoming: [ClaudeSession], now: Date = Date()) {
        let old = Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        var merged: [ClaudeSession] = []
        for var s in incoming {
            if s.host == .claudeDesktop {
                s.desktop = desktopSnapshot.info(cliSessionId: s.sessionId) ?? s.desktop ?? old[s.sessionId]?.desktop
            }
            if let prev = old[s.sessionId] {
                if s.tokens == .zero { s.tokens = prev.tokens }
                if s.model == nil { s.model = prev.model }
                if s.lastAssistantText == nil { s.lastAssistantText = prev.lastAssistantText }
                if s.lastAssistantAt == nil { s.lastAssistantAt = prev.lastAssistantAt }
                if s.lastPromptAt == nil { s.lastPromptAt = prev.lastPromptAt }
                if s.transcriptPath == nil { s.transcriptPath = prev.transcriptPath }
                if s.title == nil { s.title = prev.title }
                if s.shellPid == nil { s.shellPid = prev.shellPid }
                if prev.status == .busy && s.status == .idle && readerSessionId == s.sessionId {
                    // Finished while its reader is open: the user is looking at it already.
                    lastFinishedAt[s.sessionId] = now
                } else if prev.status == .busy && s.status == .idle {
                    unseenFinishedAt[s.sessionId] = now
                    lastFinishedAt[s.sessionId] = now
                    panelHighlight?.insert(s.sessionId)
                    // While away the drop-down would play to an empty room: hold it (the session
                    // just stays unseen and shows up in the "While you were away" summary).
                    if awaySince == nil {
                        addEvent(.sessionFinished(sessionId: s.sessionId), lifetime: NotchConstants.finishedDisplayDuration)
                    }
                } else if s.status == .busy && prev.status != .busy {
                    // Continued (e.g. from the terminal): no longer "unseen".
                    markSeenInternal(s.sessionId)
                }
            } else if !old.isEmpty || !sessions.isEmpty {
                addEvent(.sessionStarted(sessionId: s.sessionId), lifetime: 3)
            }
            merged.append(s)
        }
        let incomingIds = Set(incoming.map(\.sessionId))
        if !terminalDialogs.isEmpty {
            var g = terminalDialogs
            for s in incoming { g.status(sessionId: s.sessionId, s.status) }
            g.expire(now: now)
            for id in g.sessionIds where !incomingIds.contains(id) { g.sessionEnded(id) }
            if g != terminalDialogs { terminalDialogs = g }
        }
        for gone in old.keys where !incomingIds.contains(gone) {
            addEvent(.sessionEnded(sessionId: gone), lifetime: 3)
            // A vanished session can no longer answer; drop its finished events.
            events.removeAll { $0.kind == .sessionFinished(sessionId: gone) }
            unseenFinishedAt[gone] = nil
            lastFinishedAt[gone] = nil
            lastAskedAt[gone] = nil
            panelHighlight?.remove(gone)
            if readerSessionId == gone { readerSessionId = nil }
            if let a = awaySummary, a.items.contains(where: { $0.sessionId == gone }) { awaySummary = a.removing(sessionId: gone) }
        }
        merged.sort { $0.startedAt < $1.startedAt }
        if merged != sessions { sessions = merged }
        if subagents.keys.contains(where: { !incomingIds.contains($0) }) {
            subagents = subagents.filter { incomingIds.contains($0.key) }
        }
        recomputeMode()
    }

    // MARK: Inputs — Claude Desktop (via SessionMonitor / the app layer)

    /// Claude Desktop's session records changed (titles, parents). Nothing here marks a session
    /// seen: the done / waiting mark stays until it is cleared in Turnipot.
    public func updateDesktopSessions(_ snapshot: ClaudeDesktopSessions.Snapshot) {
        desktopSnapshot = snapshot
        var next = sessions
        for i in next.indices where next[i].host == .claudeDesktop {
            if let info = snapshot.info(cliSessionId: next[i].sessionId) { next[i].desktop = info }
        }
        if next != sessions { sessions = next }
        recomputeMode()
    }

    // MARK: Inputs — TranscriptReader (via SessionMonitor)

    public func updateTranscript(sessionId: String, summary: TranscriptSummary) {
        guard let i = sessions.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        var s = sessions[i]
        s.tokens = summary.tokens
        if let m = summary.model { s.model = m }
        if let t = summary.lastAssistantText { s.lastAssistantText = t }
        if let d = summary.lastAssistantAt { s.lastAssistantAt = d }
        if let d = summary.lastPromptAt { s.lastPromptAt = d }
        if let t = summary.title { s.title = t }
        s.transcriptPath = summary.transcriptPath
        if s != sessions[i] { sessions[i] = s }
        if terminalDialogs.isOpen(sessionId) {
            let progress = [summary.lastAssistantAt, summary.lastToolResultAt].compactMap { $0 }.max()
            var g = terminalDialogs
            if g.transcriptProgress(sessionId: sessionId, at: progress) { terminalDialogs = g }
        }
    }

    // MARK: Inputs — SubagentScanner (via SessionMonitor)

    /// Replace the subagents of the given sessions (others untouched), keeping only what is
    /// visible at `now` (running, or done / stalled within the last 10 minutes) so an agent
    /// ageing out changes the published value. Empty results and unknown session ids are dropped.
    public func updateSubagents(_ bySession: [String: SessionSubagents], now: Date = Date()) {
        var next = subagents
        for (id, all) in bySession {
            let subs = all.visible(now: now)
            if subs.isEmpty || session(id: id) == nil { next[id] = nil } else { next[id] = subs }
        }
        subagentsAsOf = now
        if next != subagents { subagents = next }
    }

    // MARK: Inputs — UsageMonitor

    public func updateUsage(_ snapshot: UsageSnapshot) {
        let wasNear = usage.nearLimitWindow
        usage = snapshot
        if let w = snapshot.nearLimitWindow {
            if wasNear == nil || (wasNear!.percent / 5) != (w.percent / 5) {
                nearLimitDismissed = false
                addEvent(.usageNearLimit(label: w.label, percent: w.percent), lifetime: 8)
            }
        } else {
            nearLimitDismissed = false
        }
        recomputeMode()
    }

    /// Keep last windows, set stale = true.
    public func markUsageStale() {
        guard !usage.stale else { return }
        usage.stale = true
    }

    // MARK: Inputs — HookServer

    /// Called by HookServer for each hook connection (types "permission", "question", "plan").
    /// Suspends until the user decides, the request is cancelled, or the kind's UI timeout
    /// (`permissionUITimeout` 55 s, `questionUITimeout` 565 s) elapses (-> "ask"). Questions /
    /// plans share the permission queue (oldest first).
    public func handleHookRequest(_ req: HookRequest) async -> HookResponse {
        guard ["permission", "question", "plan"].contains(req.type) else { return PermissionDecision.ask.hookResponse }
        let name = session(id: req.sessionId)?.name
        let pr = PermissionRequest(hook: req, sessionName: name)
        // Questions / plans the notch can't show (malformed input): leave them to the terminal.
        if (pr.kind == .question && pr.questions == nil) || (pr.kind == .plan && pr.plan == nil) {
            noteHandedBack(sessionId: pr.sessionId, requestAt: pr.receivedAt)
            return PermissionDecision.ask.hookResponse
        }
        let id = pr.id
        // If the hook disconnects early (user answered in the terminal, Claude killed the hook),
        // HookServer cancels this task: drop the drop-down instead of waiting for the timeout.
        let decision: PermissionDecision = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                enqueuePermission(pr) { cont.resume(returning: $0) }
                // The hook may have disconnected before we enqueued (onCancel then found nothing).
                if Task.isCancelled { resolvePermission(id: id, decision: .ask) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolvePermission(id: id, decision: .ask) }
        }
        return decision.hookResponse
    }

    /// Lower-level: add a request; `respond` is called exactly once.
    public func enqueuePermission(_ request: PermissionRequest, respond: @escaping (PermissionDecision) -> Void) {
        pendingPermissions.append(request)
        lastAskedAt[request.sessionId] = request.receivedAt
        permissionResponders[request.id] = respond
        let id = request.id
        permissionTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(request.kind.uiTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resolvePermission(id: id, decision: .ask)
        }
        recomputeMode()
    }

    // MARK: UI actions

    /// Answer a pending permission. No-op if already resolved.
    public func resolvePermission(id: UUID, decision: PermissionDecision) {
        permissionTimeouts.removeValue(forKey: id)?.cancel()
        let responder = permissionResponders.removeValue(forKey: id)
        let request = permission(id: id)
        pendingPermissions.removeAll { $0.id == id }
        // Handed back to the terminal (timeout, "Open session", "Answer in terminal", the hook
        // disconnecting): Claude's own dialog may be up there now.
        if let request, responder != nil, case .ask = decision {
            noteHandedBack(sessionId: request.sessionId, requestAt: request.receivedAt)
        }
        responder?(decision)
        recomputeMode()
    }

    private func noteHandedBack(sessionId: String, requestAt: Date) {
        var g = terminalDialogs
        g.handedBack(sessionId: sessionId, requestAt: requestAt, status: session(id: sessionId)?.status)
        terminalDialogs = g
    }

    /// "Open session": answer "ask" (Claude shows its terminal prompt) and focus the terminal.
    public func openPermissionInTerminal(id: UUID) {
        let sid = permission(id: id)?.sessionId
        resolvePermission(id: id, decision: .ask)
        if let sid { focusSession(id: sid) }
    }

    /// Answer every pending request with "ask" (call on app termination).
    public func cancelAllPermissions() {
        for p in pendingPermissions { resolvePermission(id: p.id, decision: .ask) }
    }

    public func focusSession(id: String, now: Date = Date()) {
        markSeen(sessionId: id)
        if terminalDialogs.isOpen(id) {
            var g = terminalDialogs
            g.focused(sessionId: id, at: now)
            terminalDialogs = g
        }
        guard let s = session(id: id), let terminal else { return }
        // Host-aware: Claude Desktop sessions activate Claude Desktop instead of an editor.
        Task { _ = await terminal.show(session: s) }
    }

    /// Quick reply: sends `text` + newline into the session's terminal. Not available for Claude
    /// Desktop sessions (nothing can type into it): the UI shows "Reply in Claude ↗" instead,
    /// which calls focusSession.
    /// Refused (returns false) while Claude may be showing a dialog in that terminal
    /// (`terminalDialogMayBeOpen`): the reply's Enter would pick the dialog's highlighted option.
    @discardableResult
    public func sendReply(sessionId: String, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session(id: sessionId), s.host == .terminal,
              !terminalDialogs.isOpen(sessionId) else { return false }
        markSeen(sessionId: sessionId)
        guard let terminal else { return false }
        Task { _ = await terminal.send(session: s, text: trimmed) }
        dismissFinished(sessionId: sessionId)
        return true
    }

    public func dismissFinished(sessionId: String? = nil) {
        events.removeAll {
            if case .sessionFinished(let sid) = $0.kind { return sessionId == nil || sid == sessionId }
            return false
        }
        recomputeMode()
    }

    // MARK: UI actions — unseen / away

    /// The user looked at this session (focus, reply, row hover, "open" in the away summary).
    public func markSeen(sessionId: String) {
        markSeenInternal(sessionId)
        recomputeMode()
    }

    /// "mark all seen" in the panel header.
    public func markAllSeen() {
        for id in Array(unseenFinishedAt.keys) { markSeenInternal(id) }
        recomputeMode()
    }

    private func markSeenInternal(_ sessionId: String) {
        if unseenFinishedAt[sessionId] != nil { unseenFinishedAt[sessionId] = nil }
        if let a = awaySummary, a.items.contains(where: { $0.sessionId == sessionId }) {
            awaySummary = a.removing(sessionId: sessionId)
        }
    }

    /// Away detection (app layer) says the user left at `since` (lock / sleep / idle; idle is
    /// back-dated to the last input). Finished drop-downs are held until they return.
    public func setAway(since: Date = Date()) {
        guard awaySince == nil else { return }
        awaySince = since
    }

    /// The user is back (unlock / wake / first input after idle): show one "While you were away"
    /// summary if anything finished or asked for permission meanwhile.
    public func setReturned(now: Date = Date()) {
        guard let since = awaySince else { return }
        awaySince = nil
        let live = Set(sessions.map(\.sessionId))
        if let s = AwaySummary.build(awaySince: since, returnedAt: now, unseen: unseenItems,
                                     asked: lastAskedAt, liveSessionIds: live) {
            awaySummary = awaySummary.map { $0.merged(with: s) } ?? s
        }
        recomputeMode()
    }

    public func dismissAwaySummary() {
        guard awaySummary != nil else { return }
        awaySummary = nil
        recomputeMode()
    }

    /// "open ↗" in the summary: focus the session (marks it seen, removing its item).
    public func openAwayItem(sessionId: String) {
        focusSession(id: sessionId)
        if let a = awaySummary { awaySummary = a.removing(sessionId: sessionId) }
        recomputeMode()
    }

    // MARK: UI actions — reply reader

    /// Open the session's reply reader (marks it seen; drops its finished drop-down).
    public func openReader(sessionId: String) {
        guard session(id: sessionId) != nil else { return }
        markSeenInternal(sessionId)
        events.removeAll { $0.kind == .sessionFinished(sessionId: sessionId) }
        readerSessionId = sessionId
        recomputeMode()
    }

    /// ✕ / esc / click outside: close the reader and the panel.
    public func closeReader() {
        guard readerSessionId != nil else { return }
        readerSessionId = nil
        isPinnedExpanded = false
        isHovering = false
        recomputeMode()
    }

    /// "‹ Sessions" / overscroll at the top: back to the (pinned) session list.
    public func readerBack() {
        readerSessionId = nil
        isPinnedExpanded = true
        recomputeMode()
    }

    public func dismissNearLimit() {
        nearLimitDismissed = true
        recomputeMode()
    }

    public func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        recomputeMode()
    }

    public func expand() { isPinnedExpanded = true; recomputeMode() }
    public func collapse() { isPinnedExpanded = false; isHovering = false; readerSessionId = nil; recomputeMode() }
    public func toggleExpanded() { isPinnedExpanded ? collapse() : expand() }

    // MARK: Mode

    /// Priority: permission > reader > away summary > finished > expanded (pinned or hover) > nearLimit > collapsed.
    public func recomputeMode() {
        let newMode: IslandMode
        if let p = pendingPermissions.first {
            newMode = .permission(requestId: p.id)
        } else if let rid = readerSessionId {
            newMode = .reader(sessionId: rid)
        } else if awaySummary != nil {
            newMode = .awaySummary
        } else if let sid = latestFinishedSessionId {
            newMode = .finished(sessionId: sid)
        } else if isPinnedExpanded || isHovering {
            newMode = .expanded
        } else if isNearLimit && !nearLimitDismissed {
            newMode = .nearLimit
        } else {
            newMode = .collapsed
        }
        // Freeze the panel's highlighted rows while it is open.
        if newMode == .expanded && mode != .expanded {
            panelHighlight = Set(unseenFinishedAt.keys)
        } else if newMode != .expanded && panelHighlight != nil {
            panelHighlight = nil
        }
        if newMode != mode { mode = newMode }
    }

    // MARK: Events

    private func addEvent(_ kind: TransientEvent.Kind, lifetime: TimeInterval) {
        let e = TransientEvent(kind: kind, lifetime: lifetime)
        events.append(e)
        let id = e.id
        eventExpiry[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.eventExpiry.removeValue(forKey: id)
            self.events.removeAll { $0.id == id }
            self.recomputeMode()
        }
    }
}
