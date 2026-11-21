import Foundation
import NotchCore

/// Unseen finished sessions, "waiting for you" classification, panel order, pill badge text,
/// agent sprout pips and the "While you were away" summary (Attention.swift + AppState).
func registerAttentionTests() {
    // MARK: Last sentence / waiting classification
    typealias A = AttentionText
    let pr = "Removed 14 single-use helpers; all 212 tests pass. Want me to open a PR?"
    expectEqual(A.lastSentence(pr), "Want me to open a PR?", "last sentence: question")
    check("waiting: 'Want me to open a PR?'", A.classify(pr) == .waiting)
    let vs = "VS Code support is in. Reload VSCodium to pick up extension 0.1.2."
    expectEqual(A.lastSentence(vs), "Reload VSCodium to pick up extension 0.1.2.", "last sentence keeps version numbers")
    check("done: plain statement", A.classify(vs) == .done)
    expectEqual(A.lastSentence("Done."), "Done.", "last sentence: 'Done.'")
    check("done: 'Done.'", A.classify("Done.") == .done)
    check("done: nil / empty", A.classify(nil) == .done && A.classify("  \n ") == .done)
    expectEqual(A.lastSentence(nil), nil, "last sentence nil")

    // Ends in a code block: the prose before it counts.
    let codeQ = "Here's the fix. Should I apply it to the other handlers too?\n\n```swift\nlet x = try? foo()\n```\n"
    check("waiting: question followed by a code block", A.classify(codeQ) == .waiting)
    expectEqual(A.lastSentence(codeQ), "Should I apply it to the other handlers too?", "last sentence skips code block")
    let codeDone = "Updated the config:\n\n```json\n{\"a\": \"why?\"}\n```"
    check("done: '?' only inside a code block", A.classify(codeDone) == .done)
    expectEqual(A.lastSentence(codeDone), "Updated the config:", "last sentence before trailing code")

    // Markdown, quotes, emoji, trailing whitespace.
    check("waiting: bold markdown", A.classify("All green.\n\n**Want me to push it?**  \n") == .waiting)
    expectEqual(A.lastSentence("All green.\n\n**Want me to push it?**"), "Want me to push it?", "markdown stripped")
    check("waiting: trailing emoji", A.classify("Tests pass. Ready to merge? 🚀") == .waiting)
    check("waiting: trailing quote", A.classify("I'd call it \"done?\"") == .waiting)
    check("waiting: list then question", A.classify("Options:\n- A\n- B\n\nWhich one do you prefer?") == .waiting)
    check("done: question earlier, statement last", A.classify("Should I push? I pushed it anyway.") == .done)
    check("done: list item last", A.classify("Changes:\n- added `foo()`\n- removed bar") == .done)
    expectEqual(A.lastSentence("Changes:\n- added `foo()`"), "added foo()", "bullet + inline code stripped")
    expectEqual(A.lastSentence("See [the docs](https://x.y/z). Then run it."), "Then run it.", "link sentence split")
    expectEqual(A.lastSentence("Use e.g. the helper. it works"), "Use e.g. the helper. it works", "no split before lowercase")
    check("waiting: heading question", A.classify("## Next step?\n") == .waiting)
    check("waiting: fullwidth question mark", A.classify("続けますか？") == .waiting)
    check("done: '?' mid-sentence", A.classify("The `?` operator is now used everywhere.") == .done)

    // MARK: Panel order
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func sess(_ id: String, _ status: SessionStatus = .idle, started: Double = 0, text: String? = nil) -> ClaudeSession {
        ClaudeSession(pid: 1, sessionId: id, cwd: "/tmp/\(id)", name: id, status: status,
                      startedAt: t0.addingTimeInterval(started), updatedAt: t0, lastAssistantText: text)
    }
    let ordered = AttentionRules.panelOrder(
        [sess("a", started: 0), sess("b", started: 1), sess("c", started: 2), sess("d", started: 3)],
        highlighted: [
            "b": UnseenItem(sessionId: "b", finishedAt: t0.addingTimeInterval(10), kind: .done),
            "c": UnseenItem(sessionId: "c", finishedAt: t0.addingTimeInterval(20), kind: .done),
            "d": UnseenItem(sessionId: "d", finishedAt: t0.addingTimeInterval(5), kind: .waiting),
        ])
    expectEqual(ordered.map(\.sessionId), ["d", "c", "b", "a"], "panel order: waiting, then done newest first, then rest")
    expectEqual(AttentionRules.panelOrder([sess("a"), sess("b", started: 1)], highlighted: [:]).map(\.sessionId),
                ["a", "b"], "panel order: unchanged without highlights")

    // MARK: Pill badge
    expectEqual(PillBadge.candidates(waiting: 0, done: 2).map(\.text), ["2 done", "2 new"], "badge: done only")
    expectEqual(PillBadge.candidates(waiting: 1, done: 0).map(\.text), ["1 waiting", "1 new"], "badge: waiting only")
    expectEqual(PillBadge.candidates(waiting: 1, done: 1).map(\.text), ["1 waiting · 1 done", "2 new"], "badge: mixed")
    check("badge: nothing unseen", PillBadge.candidates(waiting: 0, done: 0).isEmpty
          && PillBadge.choose(waiting: 0, done: 0, fits: { _ in true }) == nil)
    expectEqual(PillBadge.choose(waiting: 1, done: 1, fits: { $0.text.count <= 8 }), PillBadge(text: "2 new", waiting: true),
                "badge: falls back to 'N new' (amber if any waiting)")
    expectEqual(PillBadge.choose(waiting: 0, done: 3, fits: { _ in false }), PillBadge(text: "3 new", waiting: false),
                "badge: nothing fits -> most compact")
    expectEqual(PillBadge.choose(waiting: 0, done: 2, fits: { _ in true })?.text, "2 done", "badge: fits -> full text")

    // MARK: Sprout pips
    func pips(_ n: Int) -> [Int] { let l = AgentPips.layout(running: n); return [l.pips, l.overflow] }
    expectEqual(pips(0), [0, 0], "pips: none")
    expectEqual(pips(2), [2, 0], "pips: 2 running")
    expectEqual(pips(3), [3, 0], "pips: 3 = max, no +N")
    expectEqual(pips(4), [3, 1], "pips: 4 -> 3 + '+1'")
    expectEqual(pips(9), [3, 6], "pips: 9 -> 3 + '+6'")
    expectEqual(pips(-1), [0, 0], "pips: negative clamps")
    let subs = SessionSubagents(agents: [
        SubagentInfo(agentId: "1", description: "x", status: .running, startedAt: t0, lastWrite: t0),
        SubagentInfo(agentId: "2", description: "y", status: .done, startedAt: t0, lastWrite: t0),
        SubagentInfo(agentId: "3", description: "z", status: .stalled, startedAt: t0, lastWrite: t0),
    ])
    expectEqual(AgentPips.layout(running: subs.runningCount).pips, 1, "pips: done / stalled agents don't count")

    // MARK: Away summary aggregation
    let away = t0.addingTimeInterval(100), back = t0.addingTimeInterval(100 + 20 * 60)
    let unseen = [
        UnseenItem(sessionId: "before", finishedAt: t0.addingTimeInterval(50), kind: .done),       // before away
        UnseenItem(sessionId: "d1", finishedAt: away.addingTimeInterval(60), kind: .done),
        UnseenItem(sessionId: "d2", finishedAt: away.addingTimeInterval(600), kind: .done),
        UnseenItem(sessionId: "w1", finishedAt: away.addingTimeInterval(300), kind: .waiting),
        UnseenItem(sessionId: "both", finishedAt: away.addingTimeInterval(400), kind: .done),
        UnseenItem(sessionId: "gone", finishedAt: away.addingTimeInterval(400), kind: .done),
    ]
    let asked = ["a1": away.addingTimeInterval(200), "both": away.addingTimeInterval(100),
                 "old": t0.addingTimeInterval(10)]
    let live: Set<String> = ["before", "d1", "d2", "w1", "both", "a1", "old"]
    let sum = AwaySummary.build(awaySince: away, returnedAt: back, unseen: unseen, asked: asked, liveSessionIds: live)
    expectEqual(sum?.items.map(\.sessionId), ["a1", "both", "w1", "d2", "d1"],
                "away: asked first, then waiting, then done newest first; before-away / ended excluded")
    expectEqual(sum?.items.first { $0.sessionId == "both" }?.kind, .asked, "away: asked beats done for one session")
    expectEqual(sum?.awayDuration, 20 * 60, "away: duration")
    expectEqual(sum?.visibleItems.count, 4, "away: at most 4 rows")
    expectEqual(sum?.moreCount, 1, "away: +1 more")
    check("away: nothing happened -> no summary",
          AwaySummary.build(awaySince: away, returnedAt: back, unseen: [unseen[0]], asked: [:], liveSessionIds: live) == nil)
    expectEqual(sum?.removing(sessionId: "a1")?.items.count, 4, "away: removing one item")
    let single = AwaySummary(awaySince: away, returnedAt: back, items: [.init(sessionId: "x", kind: .done, at: away)])
    check("away: removing the last item -> nil", single.removing(sessionId: "x") == nil)

    // MARK: AppState lifecycle
    MainActor.assumeIsolated {
        let app = AppState()
        let now = Date()
        let busyA = sess("A", .busy, started: 0, text: "All 12 tests pass. Want me to open a PR?")
        let busyB = sess("B", .busy, started: 1, text: "Done.")
        let idleC = sess("C", .idle, started: 2)
        app.updateSessions([busyA, busyB, idleC], now: now)
        check("lifecycle: first sighting is never unseen", !app.hasUnseen)
        var a = busyA; a.status = .idle
        var b = busyB; b.status = .idle
        app.updateSessions([a, b, idleC], now: now.addingTimeInterval(60))
        check("lifecycle: busy -> idle marks unseen", app.isUnseen("A") && app.isUnseen("B") && !app.isUnseen("C"))
        expectEqual(app.unseenKind(for: "A"), .waiting, "lifecycle: question -> waiting")
        expectEqual(app.unseenKind(for: "B"), .done, "lifecycle: statement -> done")
        check("lifecycle: counts", app.unseenCounts == (1, 1))
        expectEqual(app.unseenFinishedAt["A"], now.addingTimeInterval(60), "lifecycle: finishedAt recorded")
        check("lifecycle: finished drop-down still fires when present", app.latestFinishedSessionId != nil)
        expectEqual(app.panelSessions.map(\.sessionId), ["A", "B", "C"], "lifecycle: panel order waiting, done, rest")
        app.dismissFinished()
        expectEqual(app.mascotMood, .hop, "mood: happy while unseen and nothing busy")
        app.focusSession(id: "A")
        check("lifecycle: focus marks seen", !app.isUnseen("A") && app.isUnseen("B"))
        app.sendReply(sessionId: "B", text: "thanks")
        check("lifecycle: reply marks seen", !app.isUnseen("B"))
        expectEqual(app.mascotMood, .sleeping, "mood: back to sleeping once seen")

        // busy again / ended / mark all seen
        var a2 = a; a2.status = .busy
        app.updateSessions([a2, b, idleC], now: now.addingTimeInterval(120))
        a2.status = .idle
        app.updateSessions([a2, b, idleC], now: now.addingTimeInterval(180))
        check("lifecycle: finishes again -> unseen again", app.isUnseen("A"))
        var a3 = a2; a3.status = .busy
        app.updateSessions([a3, b, idleC], now: now.addingTimeInterval(200))
        check("lifecycle: busy again -> seen", !app.isUnseen("A"))
        app.dismissFinished()
        expectEqual(app.mascotMood, .bouncing, "mood: working beats unseen")
        a3.status = .idle
        var b2 = b; b2.status = .busy
        app.updateSessions([a3, b2, idleC], now: now.addingTimeInterval(240))
        b2.status = .idle
        app.updateSessions([a3, b2, idleC], now: now.addingTimeInterval(260))
        check("lifecycle: two unseen", app.isUnseen("A") && app.isUnseen("B"))
        app.updateSessions([a3, idleC], now: now.addingTimeInterval(270))
        check("lifecycle: ended session dropped", !app.isUnseen("B") && app.unseenFinishedAt.count == 1)
        app.dismissFinished()
        app.markAllSeen()
        check("lifecycle: mark all seen", !app.hasUnseen)

        // Panel highlight freezes while open.
        var a4 = a3; a4.status = .busy
        app.updateSessions([a4, idleC], now: now.addingTimeInterval(300))
        a4.status = .idle
        app.updateSessions([a4, idleC], now: now.addingTimeInterval(310))
        app.dismissFinished()
        app.expand()
        check("panel: highlight snapshot taken on open", app.panelHighlight == ["A"])
        app.markSeen(sessionId: "A")
        check("panel: seen row stays highlighted while open", app.panelHighlightIds.contains("A") && !app.isUnseen("A"))
        app.collapse()
        check("panel: snapshot cleared on close", app.panelHighlight == nil && app.panelHighlightIds.isEmpty)

        // Away: drop-downs held, summary on return.
        let away = now.addingTimeInterval(400)
        app.setAway(since: away)
        var c = idleC; c.status = .busy
        app.updateSessions([a4, c], now: away.addingTimeInterval(10))
        c.status = .idle
        c.lastAssistantText = "Migrated. Should I delete the old tables?"
        app.updateSessions([a4, c], now: away.addingTimeInterval(600))
        check("away: no finished drop-down while away", app.latestFinishedSessionId == nil)
        check("away: still unseen", app.isUnseen("C"))
        let input: JSONValue = .object(["command": .string("ls")])
        let req = PermissionRequest(sessionId: "A", toolName: "Bash", summary: "ls", toolInput: input, raw: .null,
                                    receivedAt: away.addingTimeInterval(700))
        app.enqueuePermission(req) { _ in }
        if case .permission = app.mode {} else { check("away: permission still shows", false) }
        app.resolvePermission(id: req.id, decision: .ask)
        app.setReturned(now: away.addingTimeInterval(1200))
        expectEqual(app.mode, .awaySummary, "away: summary shown on return")
        expectEqual(app.awaySummary?.items.map(\.sessionId), ["A", "C"], "away: asked + waiting items")
        expectEqual(app.awaySummary?.items.map(\.kind), [.asked, .waiting], "away: kinds")
        expectEqual(app.awaySummary?.awayDuration, 1200, "away: 20m")
        expectEqual(app.mascotMood, .hop, "away: mascot happy")
        // Permission prompts still win over the summary.
        let req2 = PermissionRequest(sessionId: "A", toolName: "Bash", summary: "ls", toolInput: input, raw: .null)
        app.enqueuePermission(req2) { _ in }
        if case .permission = app.mode {} else { check("away: permission beats summary", false) }
        app.resolvePermission(id: req2.id, decision: .ask)
        expectEqual(app.mode, .awaySummary, "away: summary back after the permission")
        app.openAwayItem(sessionId: "C")
        check("away: open marks seen and removes the item", !app.isUnseen("C") && app.awaySummary?.items.map(\.sessionId) == ["A"])
        app.dismissAwaySummary()
        check("away: dismissed", app.awaySummary == nil && app.mode == .collapsed)
        app.setAway(since: away.addingTimeInterval(2000))
        app.setReturned(now: away.addingTimeInterval(2100))
        check("away: nothing new -> no summary", app.awaySummary == nil)
    }
}
