import Foundation
import NotchCore

/// Safety guards: no quick reply into a terminal dialog (TerminalDialogGuard + AppState +
/// TerminalBridge), and no actions on a needs-you drop-down that just appeared (FreshContentGate).
func registerGuardTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: TerminalDialogGuard (pure)
    var g = TerminalDialogGuard()
    check("dialog: nothing flagged", !g.isOpen("s") && g.isEmpty)
    g.handedBack(sessionId: "s", requestAt: t0, status: .busy)
    check("dialog: handed back -> open", g.isOpen("s"))
    check("dialog: other session unaffected", !g.isOpen("x"))
    check("dialog: older assistant message is no progress", !g.transcriptProgress(sessionId: "s", at: t0.addingTimeInterval(-3)))
    check("dialog: same-time line is no progress", !g.transcriptProgress(sessionId: "s", at: t0))
    check("dialog: nil progress ignored", !g.transcriptProgress(sessionId: "s", at: nil))
    check("dialog: still open", g.isOpen("s"))
    check("dialog: newer transcript line clears", g.transcriptProgress(sessionId: "s", at: t0.addingTimeInterval(1)))
    check("dialog: cleared", !g.isOpen("s"))

    // idle -> busy -> idle (flag set while busy: needs an idle first, then busy, then idle)
    g.handedBack(sessionId: "s", requestAt: t0, status: .busy)
    g.status(sessionId: "s", .busy)
    check("dialog: still busy -> open", g.isOpen("s"))
    g.status(sessionId: "s", .idle)
    check("dialog: busy -> idle alone keeps it", g.isOpen("s"))
    g.status(sessionId: "s", .busy)
    check("dialog: idle -> busy keeps it", g.isOpen("s"))
    check("dialog: idle -> busy -> idle clears", g.status(sessionId: "s", .idle) && !g.isOpen("s"))
    // Flag set while idle: busy then idle clears.
    g.handedBack(sessionId: "s", requestAt: t0, status: .idle)
    g.status(sessionId: "s", .idle)
    check("dialog: idle while flagged stays", g.isOpen("s"))
    g.status(sessionId: "s", .unknown)
    g.status(sessionId: "s", .busy)
    check("dialog: busy then idle clears", g.status(sessionId: "s", .idle))

    // Focus + 2 minutes
    g.handedBack(sessionId: "s", requestAt: t0, status: .busy)
    check("dialog: no focus -> never expires by time", !g.expire(now: t0.addingTimeInterval(3600)) && g.isOpen("s"))
    g.focused(sessionId: "s", at: t0.addingTimeInterval(10))
    g.focused(sessionId: "s", at: t0.addingTimeInterval(100))   // the first focus counts
    check("dialog: < 2 min after focus -> open", !g.expire(now: t0.addingTimeInterval(129)) && g.isOpen("s"))
    check("dialog: 2 min after focus -> cleared", g.expire(now: t0.addingTimeInterval(130)) && !g.isOpen("s"))
    g.focused(sessionId: "s", at: t0)
    check("dialog: focus while not flagged does nothing", !g.isOpen("s"))
    // A newer hand-back resets the focus clock and moves the request time forward.
    g.handedBack(sessionId: "s", requestAt: t0, status: .busy)
    g.focused(sessionId: "s", at: t0)
    g.handedBack(sessionId: "s", requestAt: t0.addingTimeInterval(50), status: .busy)
    check("dialog: re-flag resets focus", !g.expire(now: t0.addingTimeInterval(200)) && g.isOpen("s"))
    check("dialog: progress must be newer than the newest request", !g.transcriptProgress(sessionId: "s", at: t0.addingTimeInterval(20)))
    g.sessionEnded("s")
    check("dialog: session ended -> cleared", !g.isOpen("s"))

    // MARK: TerminalSendGate
    let gate = TerminalSendGate()
    gate.setBlocked(["a"])
    check("send gate: blocked", gate.isBlocked("a") && !gate.isBlocked("b"))

    // MARK: AppState integration
    MainActor.assumeIsolated {
        let mock = MockTerminal()
        let app = AppState(terminal: mock)
        let sendGate = TerminalSendGate()
        app.sendGate = sendGate
        let now = Date()
        func session(_ id: String, _ status: SessionStatus) -> ClaudeSession {
            ClaudeSession(pid: 900, shellPid: 899, sessionId: id, cwd: "/x/\(id)", name: id,
                          status: status, startedAt: now, updatedAt: now)
        }
        app.updateSessions([session("T", .busy), session("U", .idle)], now: now)
        check("app dialog: quick reply available at first", app.canQuickReply("T"))

        // Timeout / "Answer in terminal" / disconnect all resolve with .ask.
        let req = PermissionRequest(sessionId: "T", toolName: "Bash", summary: "ls", toolInput: .null, raw: .null,
                                    receivedAt: now)
        app.enqueuePermission(req) { _ in }
        app.resolvePermission(id: req.id, decision: .ask)
        check("app dialog: ask -> flagged", app.terminalDialogMayBeOpen("T"))
        check("app dialog: quick reply unavailable", !app.canQuickReply("T"))
        check("app dialog: other session still available", app.canQuickReply("U"))
        check("app dialog: send gate synced", sendGate.isBlocked("T") && !sendGate.isBlocked("U"))
        check("app dialog: sendReply refused", !app.sendReply(sessionId: "T", text: "yes please"))
        check("app dialog: sendReply to other session ok", app.sendReply(sessionId: "U", text: "hi"))

        // An answer from the notch doesn't flag.
        let ok = PermissionRequest(sessionId: "U", toolName: "Bash", summary: "ls", toolInput: .null, raw: .null)
        app.enqueuePermission(ok) { _ in }
        app.resolvePermission(id: ok.id, decision: .allow)
        check("app dialog: allow doesn't flag", !app.terminalDialogMayBeOpen("U"))
        // Resolving twice (already answered) doesn't flag either.
        app.resolvePermission(id: ok.id, decision: .ask)
        check("app dialog: stale ask doesn't flag", !app.terminalDialogMayBeOpen("U"))

        // Transcript progress clears it.
        var summary = TranscriptSummary(lastAssistantAt: now.addingTimeInterval(-5))
        app.updateTranscript(sessionId: "T", summary: summary)
        check("app dialog: older assistant message keeps it", app.terminalDialogMayBeOpen("T"))
        summary.lastToolResultAt = now.addingTimeInterval(2)
        app.updateTranscript(sessionId: "T", summary: summary)
        check("app dialog: newer tool_result clears", !app.terminalDialogMayBeOpen("T"))
        check("app dialog: send gate cleared", !sendGate.isBlocked("T"))

        // "Open session": flagged + focused; clears 2 minutes later on a poll.
        let req2 = PermissionRequest(sessionId: "T", toolName: "Bash", summary: "ls", toolInput: .null, raw: .null,
                                     receivedAt: now.addingTimeInterval(10))
        app.enqueuePermission(req2) { _ in }
        app.openPermissionInTerminal(id: req2.id)
        check("app dialog: open session -> flagged", app.terminalDialogMayBeOpen("T"))
        app.updateSessions([session("T", .busy), session("U", .idle)], now: Date().addingTimeInterval(60))
        check("app dialog: 1 min after focus -> still flagged", app.terminalDialogMayBeOpen("T"))
        app.updateSessions([session("T", .busy), session("U", .idle)], now: Date().addingTimeInterval(121))
        check("app dialog: 2 min after focus -> cleared", !app.terminalDialogMayBeOpen("T"))

        // idle -> busy -> idle via polls.
        let req3 = PermissionRequest(sessionId: "U", toolName: "Bash", summary: "ls", toolInput: .null, raw: .null)
        app.enqueuePermission(req3) { _ in }
        app.resolvePermission(id: req3.id, decision: .ask)
        app.updateSessions([session("T", .busy), session("U", .busy)], now: now)
        check("app dialog: busy keeps it", app.terminalDialogMayBeOpen("U"))
        app.updateSessions([session("T", .busy), session("U", .idle)], now: now)
        check("app dialog: idle -> busy -> idle clears", !app.terminalDialogMayBeOpen("U"))

        // Session gone.
        let req4 = PermissionRequest(sessionId: "U", toolName: "Bash", summary: "ls", toolInput: .null, raw: .null)
        app.enqueuePermission(req4) { _ in }
        app.resolvePermission(id: req4.id, decision: .ask)
        app.updateSessions([session("T", .busy)], now: now)
        check("app dialog: ended session dropped", !app.terminalDialogMayBeOpen("U") && !sendGate.isBlocked("U"))

        // Malformed question handed straight back also flags.
        var bad: HookResponse?
        let bReq = HookRequest(type: "question", sessionId: "T", cwd: nil, toolName: "AskUserQuestion",
                               toolInput: .object([:]), hookInput: .null)
        Task { @MainActor in bad = await app.handleHookRequest(bReq) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expectEqual(bad?.decision, "ask", "app dialog: malformed question -> ask")
        check("app dialog: malformed question flags the session", app.terminalDialogMayBeOpen("T"))

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check("app dialog: refused reply never reached the terminal", !mock.calls.contains { $0.hasPrefix("send:T") })
        check("app dialog: allowed reply reached the terminal", mock.calls.contains("send:U:hi"))
    }

    // MARK: TerminalBridge.send refuses flagged sessions before touching anything
    let bridgeGate = TerminalSendGate()
    bridgeGate.setBlocked(["B"])
    let rt = URL(fileURLWithPath: "/tmp/notch-guard-\(getpid())", isDirectory: true)
    let bridge = TerminalBridge(runtimeDir: rt, sendGate: bridgeGate, desktopActivator: {}, locator: { _ in nil })
    let me = ClaudeSession(pid: getpid(), shellPid: getppid(), sessionId: "B", cwd: "/x", name: "b",
                           status: .idle, startedAt: Date(), updatedAt: Date())
    let done = DispatchSemaphore(value: 0)
    let result = ResultBox()
    Task.detached { result.set(await bridge.send(session: me, text: "1")); done.signal() }
    _ = done.wait(timeout: .now() + 3)
    check("bridge: send refused while a dialog may be open", result.get() == false)

    // MARK: TranscriptReader records tool_result times (main chain only)
    var st = TranscriptReader.ParseState()
    let lines: [Substring] = [
        #"{"type":"assistant","timestamp":"2026-11-19T10:00:00.000Z","message":{"id":"m1","model":"claude-x","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#,
        #"{"type":"user","isSidechain":true,"timestamp":"2026-11-19T10:00:09.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":"x"}]}}"#,
        #"{"type":"user","timestamp":"2026-11-19T10:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
    ]
    TranscriptReader.parse(lines: lines, into: &st)
    let iso = ISO8601DateFormatter()
    expectEqual(st.summary.lastToolResultAt, iso.date(from: "2026-11-19T10:00:05Z"), "transcript: main-chain tool_result time")
    expectEqual(st.summary.lastAssistantAt, iso.date(from: "2026-11-19T10:00:00Z"), "transcript: assistant time unchanged")

    // MARK: FreshContentGate (needs-you click / hot-key guard)
    var fg = FreshContentGate()
    check("fresh: nothing shown -> refuse", !fg.allows("A", at: t0))
    fg.show("A", at: t0)
    check("fresh: click at once -> ignored", !fg.allows("A", at: t0.addingTimeInterval(0.05)))
    check("fresh: click at 399 ms -> ignored", !fg.allows("A", at: t0.addingTimeInterval(0.399)))
    check("fresh: click at 400 ms -> allowed", fg.allows("A", at: t0.addingTimeInterval(0.4)))
    fg.show("A", at: t0.addingTimeInterval(5))
    check("fresh: same content re-shown keeps its clock", fg.allows("A", at: t0.addingTimeInterval(5.1)))
    // Queue advances to the next request: the clock restarts.
    fg.show("B", at: t0.addingTimeInterval(6))
    check("fresh: next request at once -> ignored", !fg.allows("B", at: t0.addingTimeInterval(6.1)))
    check("fresh: old request's key refused", !fg.allows("A", at: t0.addingTimeInterval(7)))
    check("fresh: next request after 400 ms -> allowed", fg.allows("B", at: t0.addingTimeInterval(6.45)))
    fg.show(nil, at: t0.addingTimeInterval(8))
    check("fresh: dismissed -> refuse", !fg.allows("B", at: t0.addingTimeInterval(9)))
    // attempt(): content not registered yet (UI update still pending) registers it and refuses.
    var fa = FreshContentGate()
    check("fresh: attempt on unseen content -> refused", !fa.attempt("C", at: t0))
    check("fresh: attempt again too soon -> refused", !fa.attempt("C", at: t0.addingTimeInterval(0.2)))
    check("fresh: attempt later -> allowed", fa.attempt("C", at: t0.addingTimeInterval(0.41)))
    // The hot-key path: queue advance under a resting pointer re-gates (HotKeyGate key = request).
    var hk = HotKeyGate()
    _ = hk.update(key: "permission-A", pointerX: 0, pointerY: 0, inside: false)
    check("hotkeys: armed after entering", hk.update(key: "permission-A", pointerX: 10, pointerY: 10, inside: true))
    check("hotkeys: queue advanced -> disarmed until the pointer moves",
          !hk.update(key: "permission-B", pointerX: 10, pointerY: 10, inside: true))
    check("hotkeys: moved -> armed again", hk.update(key: "permission-B", pointerX: 20, pointerY: 10, inside: true))
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}
