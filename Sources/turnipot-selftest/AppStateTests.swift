import Foundation
import NotchCore

// Owned by the AppState implementer. Use check(_:_:) / expectEqual(_:_:_:) from main.swift.
func registerAppStateTests() {
    func request(_ hookJSON: String) -> PermissionRequest {
        let raw = (try? JSONDecoder().decode(JSONValue.self, from: Data(hookJSON.utf8))) ?? .null
        let hook = HookRequest(type: "permission", sessionId: "s", cwd: "/tmp",
                               toolName: raw["tool_name"]?.stringValue ?? "",
                               toolInput: raw["tool_input"] ?? .null, hookInput: raw)
        return PermissionRequest(hook: hook, sessionName: nil)
    }
    // Claude's own suggestion wins.
    let suggested = request(#"{"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}]}"#)
    expectEqual(suggested.suggestedAlwaysRule, "Bash(rm -rf node_modules)", "permission: uses permission_suggestions")
    // No suggestion from Claude: never a guessed prefix (exact command only).
    let simple = request(#"{"tool_name":"Bash","tool_input":{"command":"npm test --watch"}}"#)
    expectEqual(simple.suggestedAlwaysRule, "Bash(npm test --watch)", "permission: no suggestion -> exact command")
    let rm = request(#"{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#)
    expectEqual(rm.suggestedAlwaysRule, "Bash(rm -rf build)", "permission: rm -rf never becomes a prefix rule")
    let wrapper = request(#"{"tool_name":"Bash","tool_input":{"command":"bash -c 'curl x'"}}"#)
    expectEqual(wrapper.suggestedAlwaysRule, "Bash(bash -c 'curl x')", "permission: bash -c never becomes a prefix rule")
    let glob = request(#"{"tool_name":"Bash","tool_input":{"command":"rm *.log"}}"#)
    expectEqual(glob.suggestedAlwaysRule, nil, "permission: command with * (rule wildcard) -> no always rule")
    let empty = request(#"{"tool_name":"Bash","tool_input":{}}"#)
    expectEqual(empty.suggestedAlwaysRule, nil, "permission: Bash without command -> no always rule (never bare Bash)")
    let edit = request(#"{"tool_name":"Edit","tool_input":{"file_path":"/x/a.swift"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}"#)
    expectEqual(edit.suggestedAlwaysRule, nil, "permission: Edit without a rule suggestion -> no bare Edit rule")
    let fetch = request(#"{"tool_name":"WebFetch","tool_input":{"url":"https://a.b"}}"#)
    expectEqual(fetch.suggestedAlwaysRule, nil, "permission: WebFetch without suggestion -> no bare rule")
    let fetchSuggested = request(#"{"tool_name":"WebFetch","tool_input":{"url":"https://a.b"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"WebFetch","ruleContent":"domain:a.b"}],"behavior":"allow","destination":"localSettings"}]}"#)
    expectEqual(fetchSuggested.suggestedAlwaysRule, "WebFetch(domain:a.b)", "permission: WebFetch uses Claude's domain rule")
    let compound = request(#"{"tool_name":"Bash","tool_input":{"command":"cd x && rm -rf y"}}"#)
    expectEqual(compound.suggestedAlwaysRule, "Bash(cd x && rm -rf y)", "permission: compound command -> exact rule")
    let mcp = request(#"{"tool_name":"mcp__gh__get_issue","tool_input":{}}"#)
    expectEqual(mcp.suggestedAlwaysRule, "mcp__gh__get_issue", "permission: non-Bash -> tool name")

    // Near-limit banner: hovering keeps it (reaching for "Got it" must not open the panel).
    MainActor.assumeIsolated {
        let app = AppState()
        app.updateUsage(UsageSnapshot(windows: [UsageWindow(label: "session", percent: 90, resetsText: "")],
                                      fetchedAt: Date(), stale: false))
        expectEqual(app.mode, .nearLimit, "near limit: banner shown")
        app.setHovering(true)
        expectEqual(app.mode, .nearLimit, "near limit: hover keeps the banner")
        app.expand()
        expectEqual(app.mode, .expanded, "near limit: clicking the banner opens the panel")
        app.collapse()
        app.setHovering(true)
        app.dismissNearLimit()
        expectEqual(app.mode, .expanded, "near limit: after Got it, hover opens the panel again")
    }

    // Near-limit banner: once per level, remembered until the window resets.
    MainActor.assumeIsolated {
        func snap(_ p: Int, _ label: String = "week") -> UsageSnapshot {
            UsageSnapshot(windows: [UsageWindow(label: label, percent: p, resetsText: "")], fetchedAt: Date(), stale: false)
        }
        expectEqual(NearLimitRule.level(84), nil, "near-limit level: under 85")
        expectEqual(NearLimitRule.level(88), 0, "near-limit level: 85")
        expectEqual(NearLimitRule.level(97), 1, "near-limit level: 95")
        expectEqual(NearLimitRule.level(100), 2, "near-limit level: 100")
        let app = AppState()
        var saved: [String: Int]?
        app.onNearLimitAckedChange = { saved = $0 }
        app.updateUsage(snap(86))
        expectEqual(app.mode, .nearLimit, "near limit: shown at 86%")
        app.dismissNearLimit()
        expectEqual(saved, ["week": 0], "near limit: Got it is saved")
        for p in [87, 89, 91, 94] {
            app.updateUsage(snap(p))
            expectEqual(app.mode, .collapsed, "near limit: no repeat at \(p)%")
        }
        app.updateUsage(snap(95))
        expectEqual(app.mode, .nearLimit, "near limit: shown again at 95%")
        app.dismissNearLimit()
        app.updateUsage(snap(10))
        expectEqual(saved, [:], "near limit: reset clears the acknowledgement")
        app.dismissUsageReset()
        app.updateUsage(snap(86))
        expectEqual(app.mode, .nearLimit, "near limit: next period shows it again")
        let restarted = AppState()
        restarted.nearLimitAcked = ["week": 0]
        restarted.updateUsage(snap(90))
        expectEqual(restarted.mode, .collapsed, "near limit: acknowledged before a restart stays quiet")
    }

    // Answered outside the notch (terminal / Claude Desktop): the drop-down closes itself.
    do {
        let iso = ISO8601DateFormatter()
        let asked = iso.date(from: "2026-11-27T10:00:10Z")!
        let q = PermissionRequest(sessionId: "s", toolName: "AskUserQuestion", summary: "q",
                                  toolInput: .object(["questions": .array([.object(["question": .string("Which?")])])]),
                                  raw: .null, receivedAt: asked)
        func parsed(_ lines: [Substring]) -> TranscriptSummary {
            var st = TranscriptReader.ParseState()
            TranscriptReader.parse(lines: lines, into: &st)
            return st.summary
        }
        let use: Substring = #"{"type":"assistant","timestamp":"2026-11-27T10:00:09.000Z","message":{"id":"m1","model":"claude-x","content":[{"type":"tool_use","id":"tq","name":"AskUserQuestion","input":{"questions":[{"question":"Which?"}]}}]}}"#
        let result: Substring = #"{"type":"user","timestamp":"2026-11-27T10:00:30.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tq","content":"A"}]}}"#
        let pending = parsed([use])
        expectEqual(pending.recentToolCalls.map(\.id), ["tq"], "elsewhere: tool_use recorded")
        check("elsewhere: no result yet -> still pending", !AppState.answeredElsewhere(q, summary: pending))
        let answered = parsed([use, result])
        expectEqual(answered.recentToolCalls.first?.resultAt, iso.date(from: "2026-11-27T10:00:30Z"), "elsewhere: result time")
        check("elsewhere: result after the request -> answered", AppState.answeredElsewhere(q, summary: answered))
        let otherUse: Substring = #"{"type":"assistant","timestamp":"2026-11-27T10:00:09.000Z","message":{"id":"m2","model":"claude-x","content":[{"type":"tool_use","id":"tq","name":"AskUserQuestion","input":{"questions":[{"question":"Other?"}]}}]}}"#
        check("elsewhere: different input -> not this request", !AppState.answeredElsewhere(q, summary: parsed([otherUse, result])))
        let early: Substring = #"{"type":"user","timestamp":"2026-11-27T09:59:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tq","content":"A"}]}}"#
        check("elsewhere: older identical call -> not this request", !AppState.answeredElsewhere(q, summary: parsed([use, early])))
        var prompted = pending
        prompted.lastPromptAt = iso.date(from: "2026-11-27T10:00:40Z")
        check("elsewhere: new prompt since -> answered", AppState.answeredElsewhere(q, summary: prompted))

        MainActor.assumeIsolated {
            let app = AppState()
            let t0 = asked.addingTimeInterval(-60)
            app.updateSessions([ClaudeSession(pid: 1, sessionId: "s", cwd: "/x", name: "s", status: .busy, startedAt: t0, updatedAt: t0)])
            var got: PermissionDecision?
            app.enqueuePermission(q) { got = $0 }
            app.updateTranscript(sessionId: "s", summary: pending)
            expectEqual(app.pendingPermissions.count, 1, "elsewhere: drop-down stays while unanswered")
            app.updateTranscript(sessionId: "s", summary: answered)
            check("elsewhere: drop-down closed", app.pendingPermissions.isEmpty)
            check("elsewhere: hook told ask", { if case .ask? = got { return true }; return false }())
            check("elsewhere: quick reply not blocked", !app.terminalDialogMayBeOpen("s"))

            // A finished drop-down goes away when the session continues (answered elsewhere).
            app.updateSessions([ClaudeSession(pid: 1, sessionId: "s", cwd: "/x", name: "s", status: .idle, startedAt: t0, updatedAt: t0)])
            expectEqual(app.mode, .finished(sessionId: "s"), "continue: finished drop-down shown")
            app.updateSessions([ClaudeSession(pid: 1, sessionId: "s", cwd: "/x", name: "s", status: .busy, startedAt: t0, updatedAt: t0)])
            expectEqual(app.mode, .collapsed, "continue: busy again closes the finished drop-down")
            check("continue: no longer unseen", !app.hasUnseen)

            // Sessions finishing a moment apart stack oldest first (a new card lands below).
            func sess(_ id: String, _ st: SessionStatus) -> ClaudeSession {
                ClaudeSession(pid: 1, sessionId: id, cwd: "/x", name: id, status: st, startedAt: t0, updatedAt: t0)
            }
            app.updateSessions([sess("a", .busy), sess("b", .busy), sess("c", .busy)])
            app.updateSessions([sess("a", .busy), sess("b", .idle), sess("c", .busy)])
            app.updateSessions([sess("a", .idle), sess("b", .idle), sess("c", .busy)])
            expectEqual(app.finishedSessionIds, ["b", "a"], "stack: oldest first")
            app.updateSessions([sess("a", .idle), sess("b", .busy), sess("c", .idle)])
            expectEqual(app.finishedSessionIds, ["a", "c"], "stack: continued session leaves, newcomer appended")
            app.dismissFinished()
            check("stack: Close clears every card", app.finishedSessionIds.isEmpty)
        }
    }
}
