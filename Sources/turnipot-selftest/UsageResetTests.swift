import Foundation
import NotchCore

/// Usage reset detection, the reset drop-down's mode / lifetime, and resets while away
/// (rows of the "While you were away" summary, in time order with finished sessions).
func registerUsageResetTests() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func snap(_ session: Int, _ sReset: String, week: Int = 40, _ wReset: String = "Nov 28 at 9am", at: Date = t0,
              stale: Bool = false) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(label: "session", percent: session, resetsText: sReset),
                                UsageWindow(label: "week (all models)", percent: week, resetsText: wReset)],
                      fetchedAt: at, stale: stale)
    }
    typealias R = UsageResetRule
    // Rule.
    check("reset: first fetch -> none", R.resets(old: nil, new: snap(0, "8pm")).isEmpty)
    check("reset: never fetched -> none", R.resets(old: UsageSnapshot(), new: snap(0, "8pm")).isEmpty)
    let r = R.resets(old: snap(97, "3pm"), new: snap(0, "8pm"), now: t0)
    expectEqual(r.map(\.window.label), ["session"], "reset: session reset detected")
    expectEqual(r.first?.previousPercent, 97, "reset: previous percent")
    check("reset: low use isn't announced", R.resets(old: snap(30, "3pm"), new: snap(0, "8pm")).isEmpty)
    check("reset: same reset time, small drop -> none", R.resets(old: snap(90, "3pm"), new: snap(80, "3pm")).isEmpty)
    check("reset: rising percent -> none", R.resets(old: snap(60, "3pm"), new: snap(70, "8pm")).isEmpty)
    expectEqual(R.resets(old: snap(90, "3pm"), new: snap(2, "3pm")).count, 1, "reset: big drop without new reset time")
    let both = R.resets(old: snap(70, "3pm", week: 95, "Nov 21"), new: snap(1, "8pm", week: 0, "Nov 28"))
    expectEqual(both.map(\.window.label), ["week (all models)", "session"], "reset: highest previous first")

    MainActor.assumeIsolated {
        // Drop-down while present.
        let app = AppState()
        app.updateUsage(snap(97, "3pm"), now: t0)
        check("reset: nothing on the first fetch", app.usageReset == nil)
        app.updateUsage(snap(0, "8pm", at: t0.addingTimeInterval(120)), now: t0.addingTimeInterval(120))
        expectEqual(app.mode, .usageReset, "reset: drop-down shown")
        app.expand()
        expectEqual(app.mode, .expanded, "reset: pinned panel wins")
        app.collapse()
        expectEqual(app.mode, .usageReset, "reset: back after the panel closes")
        app.setHovering(true)
        expectEqual(app.mode, .usageReset, "reset: hover doesn't replace it with the panel")
        app.setHovering(false)
        app.dismissUsageReset()
        check("reset: dismissed", app.usageReset == nil && app.mode == .collapsed)
        // A stale fetch in between: no comparison against old windows.
        app.markUsageStale()
        app.updateUsage(snap(0, "1am", at: t0.addingTimeInterval(240)), now: t0.addingTimeInterval(240))
        check("reset: not after a stale fetch", app.usageReset == nil)

        // While away: no drop-down, a summary row on return, in time order with finished sessions.
        let away = AppState()
        let now = t0
        let s = ClaudeSession(pid: 1, sessionId: "A", cwd: "/x", name: "api", status: .busy, startedAt: now, updatedAt: now)
        away.updateSessions([s], now: now)
        away.updateUsage(snap(97, "3pm", week: 90, "Nov 21"), now: now)
        away.setAway(since: now.addingTimeInterval(60))
        away.updateUsage(snap(0, "8pm", week: 90, "Nov 21", at: now.addingTimeInterval(300)), now: now.addingTimeInterval(300))
        check("away reset: no drop-down while away", away.usageReset == nil && away.mode != .usageReset)
        var done = s; done.status = .idle; done.lastAssistantText = "Done."
        away.updateSessions([done], now: now.addingTimeInterval(600))
        away.updateUsage(snap(5, "8pm", week: 0, "Nov 28", at: now.addingTimeInterval(900)), now: now.addingTimeInterval(900))
        away.setReturned(now: now.addingTimeInterval(1200))
        expectEqual(away.mode, .awaySummary, "away reset: summary on return")
        expectEqual(away.awaySummary?.items.map(\.sessionId),
                    [AwaySummary.Item.resetId("week (all models)"), "A", AwaySummary.Item.resetId("session")],
                    "away reset: rows newest first (week reset 15m, finished 20m, session reset 25m)")
        expectEqual(away.awaySummary?.items.first?.reset?.previousPercent, 90, "away reset: row keeps the old percent")
        check("away reset: no drop-down after return either", away.usageReset == nil)
        away.openAwayItem(sessionId: AwaySummary.Item.resetId("session"))
        expectEqual(away.mode, .expanded, "away reset: clicking a reset row opens the panel")
    }

    // Watering stays inside the stage frame's top (can) and keeps its timeline order.
    for layout in TurnipRig.Layout.allCases {
        let top = TurnipRig.restTop(for: .bouncing, layout: layout)
        check("water: can never above the frame (\(layout))", WaterRig.canOrigin(top: top, layout: layout).y >= 0)
    }
    check("water: drops within the watering", WaterRig.drops.allSatisfy { $0 > 0 && $0 < WaterRig.duration })
    check("water: body ends at rest", WaterRig.bodyKeys(.stage).last?.1 == .identity && WaterRig.bodyKeys(.stage).last?.0 == WaterRig.duration)
}
