import Foundation
import NotchCore

func registerRowTests() {
    // MARK: Compact relative time

    expectEqual(RelativeTime.compact(seconds: 0), "now", "0s = now")
    expectEqual(RelativeTime.compact(seconds: 59), "now", "59s = now")
    expectEqual(RelativeTime.compact(seconds: -5), "now", "future = now")
    expectEqual(RelativeTime.compact(seconds: 60), "1m", "1m")
    expectEqual(RelativeTime.compact(seconds: 3 * 60 + 40), "3m", "3m")
    expectEqual(RelativeTime.compact(seconds: 22 * 60), "22m", "22m")
    expectEqual(RelativeTime.compact(seconds: 59 * 60 + 59), "59m", "59m")
    expectEqual(RelativeTime.compact(seconds: 66 * 60), "1h 6m", "1h 6m")
    expectEqual(RelativeTime.compact(seconds: 5 * 3600), "5h", "whole hours")
    expectEqual(RelativeTime.compact(seconds: 23 * 3600 + 59 * 60), "23h 59m", "23h 59m")
    expectEqual(RelativeTime.compact(seconds: 2 * 86400 + 5 * 3600), "2d", "days")
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    expectEqual(RelativeTime.compact(since: t0, now: t0.addingTimeInterval(180)), "3m", "since")

    // MARK: Last interaction = newest of the four times

    let u = t0, a = t0.addingTimeInterval(60), p = t0.addingTimeInterval(120), st = t0.addingTimeInterval(30)
    expectEqual(ClaudeSession.lastInteraction(assistantAt: a, promptAt: p, statusUpdatedAt: st, updatedAt: u), p, "prompt newest")
    expectEqual(ClaudeSession.lastInteraction(assistantAt: p, promptAt: a, statusUpdatedAt: st, updatedAt: u), p, "assistant newest")
    expectEqual(ClaudeSession.lastInteraction(assistantAt: nil, promptAt: nil, statusUpdatedAt: st, updatedAt: u), st, "status newest")
    expectEqual(ClaudeSession.lastInteraction(assistantAt: nil, promptAt: nil, statusUpdatedAt: nil, updatedAt: u), u, "falls back to updatedAt")
    expectEqual(ClaudeSession.lastInteraction(assistantAt: u.addingTimeInterval(-500), promptAt: nil, statusUpdatedAt: nil, updatedAt: u), u,
                "older transcript times don't win")
    var s = ClaudeSession(pid: 1, sessionId: "x", cwd: "/", name: "x", status: .idle, startedAt: u, updatedAt: u, statusUpdatedAt: st)
    s.lastAssistantAt = a
    expectEqual(s.lastInteractionAt, a, "session property")

    func iso(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }
    // Transcript: real prompts set lastPromptAt; tool results don't.
    var ps = TranscriptReader.ParseState()
    TranscriptReader.parse(lines: [
        #"{"type":"user","uuid":"u1","timestamp":"2026-11-19T10:00:00.000Z","message":{"role":"user","content":"fix the bug"}}"#,
        #"{"type":"assistant","uuid":"a1","timestamp":"2026-11-19T10:01:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"text","text":"Done."}]}}"#,
        #"{"type":"user","uuid":"u2","timestamp":"2026-11-19T10:02:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
    ].map { Substring($0) }, into: &ps)
    expectEqual(ps.summary.lastPromptAt, iso("2026-11-19T10:00:00Z"), "lastPromptAt from the real prompt")
    expectEqual(ps.summary.lastAssistantAt, iso("2026-11-19T10:01:00Z"), "lastAssistantAt")
    check("assistant text still parsed", ps.summary.lastAssistantText == "Done.")

    // MARK: Hover-to-reveal

    var r = RowReveal(delay: 1.5)
    expectEqual(r.enter("a", at: 10), 11.5, "due time")
    expectEqual(r.tick(at: 11.0), nil, "not before the delay")
    expectEqual(r.tick(at: 11.5), "a", "revealed after the delay")
    r.leave("a")
    expectEqual(r.revealed, nil, "leaving hides it")
    expectEqual(r.tick(at: 20), nil, "stays hidden after leaving")

    // Fast sweep across rows: nothing reveals.
    r = RowReveal(delay: 1.5)
    r.enter("a", at: 0); r.leave("a")
    r.enter("b", at: 0.3); r.leave("b")
    r.enter("c", at: 0.6)
    expectEqual(r.tick(at: 1.5), nil, "sweep: a/b never revealed, c not yet")
    expectEqual(r.tick(at: 2.1), "c", "only the row the pointer rests on")

    // Enter B before A's leave arrives (SwiftUI hover order): B's clock is what counts.
    r = RowReveal(delay: 1.5)
    r.enter("a", at: 0)
    _ = r.tick(at: 2)
    r.enter("b", at: 2.5)
    expectEqual(r.revealed, nil, "moving to another row hides the revealed one")
    r.leave("a")
    expectEqual(r.hovered, "b", "late leave of the old row is ignored")
    expectEqual(r.tick(at: 3.9), nil, "b not yet")
    expectEqual(r.tick(at: 4.0), "b", "b after its own delay")

    // Re-entering the same row doesn't restart the clock (hover events can repeat).
    r = RowReveal(delay: 1.5)
    r.enter("a", at: 0)
    r.enter("a", at: 1.0)
    expectEqual(r.tick(at: 1.5), "a", "repeated enter keeps the original time")
    r.reset()
    check("reset", r.revealed == nil && r.hovered == nil)
    // Scrolling hides the reveal; rows scrolled under a still pointer never reveal.
    r = RowReveal(delay: 1.5)
    r.enter("a", at: 0)
    expectEqual(r.tick(at: 1.5), "a", "revealed before scrolling")
    r.scrolled()
    expectEqual(r.revealed, nil, "scroll hides the reveal")
    r.enter("b", at: 2)
    expectEqual(r.tick(at: 10), nil, "no reveal while parked after a scroll")
    expectEqual(r.pointerMoved(at: 10), 11.5, "pointer move restarts the clock")
    expectEqual(r.tick(at: 11), nil, "not before the delay after moving")
    expectEqual(r.tick(at: 11.5), "b", "revealed after resting post-move")
    expectEqual(r.pointerMoved(at: 12), nil, "moves without a scroll schedule nothing")

    expectEqual(RowReveal.defaultDelay, 1.5, "reveal delay")

    // Wrapped line counts (capped at 3).
    expectEqual(RowReveal.lines(textHeight: 16, lineHeight: 16), 1, "one line")
    expectEqual(RowReveal.lines(textHeight: 48, lineHeight: 16), 3, "three lines")
    expectEqual(RowReveal.lines(textHeight: 96, lineHeight: 16), 3, "capped at three")
}
