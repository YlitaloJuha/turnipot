import Foundation
import NotchCore

func registerScrollGestureTests() {
    typealias G = OverscrollBackGesture

    /// Run a sequence of (phase, deltaUp, atTop) and return the outputs.
    func run(_ g: inout G, _ events: [(ScrollGesturePhase, Double, Bool)]) -> [G.Output] {
        events.map { g.handle($0.0, deltaUp: $0.1, atTop: $0.2) }
    }
    func fired(_ out: [G.Output]) -> Bool { out.contains(.back) }

    // MARK: Goes back

    var g = G(threshold: 60)
    var out = run(&g, [(.began, 0, true), (.changed, 20, true), (.changed, 20, true), (.changed, 25, true)])
    check("overscroll at top past threshold goes back", fired(out))
    expectEqual(out.last!, .back, "fires on the event that crosses")
    expectEqual(out[1], .progress(20.0 / 60), "progress while pulling")
    // Only once per gesture.
    out = run(&g, [(.changed, 100, true)])
    check("fires once per gesture", !fired(out))
    _ = g.handle(.ended, deltaUp: 0, atTop: true)

    // The began event's own delta counts.
    g = G(threshold: 60)
    out = run(&g, [(.began, 30, true), (.changed, 31, true)])
    check("began delta counts", fired(out))

    // MARK: Below threshold

    g = G(threshold: 60)
    out = run(&g, [(.began, 0, true), (.changed, 20, true), (.changed, 30, true), (.ended, 0, true)])
    check("short pull at the top doesn't go back", !fired(out))
    expectEqual(out.last!, G.Output.none, "ended hides the cue")
    // Thresholds don't carry over to the next gesture.
    out = run(&g, [(.began, 0, true), (.changed, 30, true)])
    check("overscroll resets between gestures", !fired(out))

    // MARK: The reported bug: scrolling back up through the content

    // Gesture starts below the top (scrolled down earlier), scrolls up to the top and keeps going.
    g = G(threshold: 60)
    out = run(&g, [(.began, 0, false), (.changed, 200, false), (.changed, 200, false),
                   (.changed, 50, true), (.changed, 50, true), (.changed, 50, true), (.changed, 50, true)])
    check("gesture that started below the top never goes back", !fired(out))
    check("no cue for it either", out.allSatisfy { $0 == .none })
    // Momentum carrying past the top afterwards doesn't either.
    out = run(&g, [(.ended, 0, true), (.momentum, 80, true), (.momentum, 80, true)])
    check("momentum never goes back", !fired(out))

    // Starts at the top, scrolls DOWN (moves the content) then back up past the top.
    g = G(threshold: 60)
    out = run(&g, [(.began, 0, true), (.changed, -30, true), (.changed, -40, false),
                   (.changed, 40, false), (.changed, 40, true), (.changed, 80, true)])
    check("gesture that scrolled the content down never goes back", !fired(out))

    // Starts at the top, but the content moved away from the top during the gesture.
    g = G(threshold: 60)
    out = run(&g, [(.began, 10, true), (.changed, 10, false), (.changed, 100, true)])
    check("content moved mid-gesture: no back", !fired(out))

    // Finger jitter downwards within tolerance is fine.
    g = G(threshold: 60, downTolerance: 6)
    out = run(&g, [(.began, 0, true), (.changed, -3, true), (.changed, 30, true), (.changed, 35, true)])
    check("small downward jitter tolerated", fired(out))

    // A gesture we never saw begin (e.g. started before the reader opened) never counts.
    g = G(threshold: 60)
    out = run(&g, [(.changed, 100, true), (.changed, 100, true)])
    check("no began: never fires", !fired(out))

    // Momentum alone never fires, even at the top.
    g = G(threshold: 60)
    out = run(&g, [(.momentum, 100, true), (.momentum, 100, true)])
    check("momentum alone never fires", !fired(out))
    check("began snapshot", { var h = G(); _ = h.handle(.began, deltaUp: 0, atTop: true); return h.atTopAtBegin && !h.disqualified }())
    check("began below the top is disqualified", { var h = G(); _ = h.handle(.began, deltaUp: 0, atTop: false); return !h.atTopAtBegin && h.disqualified }())

    // Mouse wheel: the app sends began for the first tick after a pause, changed for the rest.
    g = G(threshold: 60)
    out = run(&g, [(.began, 8, true), (.changed, 8, true), (.changed, 8, true), (.changed, 8, true),
                   (.changed, 8, true), (.changed, 8, true), (.changed, 8, true), (.changed, 8, true)])
    check("wheel burst at the top goes back", fired(out))

    // MARK: Scroll position (clip view bounds)

    // Flipped document (SwiftUI's HostingScrollView): origin.y = distance scrolled from the top.
    expectEqual(ScrollPosition.distanceFromTop(originY: 0, visibleHeight: 300, documentHeight: 1000, flipped: true), 0, "flipped top")
    expectEqual(ScrollPosition.distanceFromTop(originY: 250, visibleHeight: 300, documentHeight: 1000, flipped: true), 250, "flipped scrolled")
    expectEqual(ScrollPosition.distanceFromTop(originY: -20, visibleHeight: 300, documentHeight: 1000, flipped: true), -20, "flipped rubber band")
    expectEqual(ScrollPosition.distanceFromTop(originY: -12, visibleHeight: 300, documentHeight: 1000, flipped: true, topInset: 12), 0, "flipped with inset")
    expectEqual(ScrollPosition.distanceFromBottom(originY: 700, visibleHeight: 300, documentHeight: 1000, flipped: true), 0, "flipped bottom")
    // Unflipped: origin.y = 0 is the bottom.
    expectEqual(ScrollPosition.distanceFromTop(originY: 700, visibleHeight: 300, documentHeight: 1000, flipped: false), 0, "unflipped top")
    expectEqual(ScrollPosition.distanceFromTop(originY: 0, visibleHeight: 300, documentHeight: 1000, flipped: false), 700, "unflipped bottom")
    expectEqual(ScrollPosition.distanceFromBottom(originY: 0, visibleHeight: 300, documentHeight: 1000, flipped: false), 0, "unflipped at bottom")
    check("at top tolerance", ScrollPosition.isAtTop(distanceFromTop: 1.5) && ScrollPosition.isAtTop(distanceFromTop: -30)
          && !ScrollPosition.isAtTop(distanceFromTop: 3))

    // MARK: Reply field growth

    let lh = 16.0
    expectEqual(ReplyFieldGrowth.lines(contentHeight: 16, lineHeight: lh), 1, "one line")
    expectEqual(ReplyFieldGrowth.lines(contentHeight: 0, lineHeight: lh), 1, "empty = one line")
    expectEqual(ReplyFieldGrowth.lines(contentHeight: 17, lineHeight: lh), 1, "rounding slack")
    expectEqual(ReplyFieldGrowth.lines(contentHeight: 32, lineHeight: lh), 2, "two lines")
    expectEqual(ReplyFieldGrowth.lines(contentHeight: 80, lineHeight: lh), 5, "five lines")
    expectEqual(ReplyFieldGrowth.lines(contentHeight: 200, lineHeight: lh), 5, "capped at five")
    expectEqual(ReplyFieldGrowth.extraHeight(contentHeight: 16, lineHeight: lh), 0, "no extra for one line")
    expectEqual(ReplyFieldGrowth.extraHeight(contentHeight: 48, lineHeight: lh), 32, "extra for three lines")
    expectEqual(ReplyFieldGrowth.extraHeight(contentHeight: 400, lineHeight: lh), 64, "extra capped")
    check("scrolls past five lines", ReplyFieldGrowth.scrolls(contentHeight: 96, lineHeight: lh)
          && !ReplyFieldGrowth.scrolls(contentHeight: 80, lineHeight: lh))
    expectEqual(ReplyFieldGrowth.returnAction(shift: false, option: false, control: false), .send, "return sends")
    expectEqual(ReplyFieldGrowth.returnAction(shift: true, option: false, control: false), .newline, "shift-return newline")
    expectEqual(ReplyFieldGrowth.returnAction(shift: false, option: true, control: false), .newline, "option-return newline")
    expectEqual(ReplyFieldGrowth.returnAction(shift: false, option: false, control: true), .newline, "control-return newline")
}
