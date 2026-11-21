import Foundation
import NotchCore

func registerHapticsTests() {
    func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
    func patterns(_ s: [HapticStep]) -> [HapticPattern] { s.map(\.pattern) }

    // MARK: Turn-end bursts follow the mascot keyframes

    let spring = HapticBursts.finished(.turnipSpring)
    expectEqual(patterns(spring), [.generic, .alignment, .levelChange], "spring burst patterns")
    let sk = TurnipRig.springKeyframes, sd = TurnipRig.springDuration, delay = TurnipRig.springDelay
    // Launch = the crouch keyframe (0.08), top = the highest keyframe (0.34, dy -13), land = the
    // landing squash (0.58); all after springDelay.
    check("spring launch = crouch keyframe", near(spring[0].offset, delay + sk[1].time * sd))
    check("spring top = highest keyframe", near(spring[1].offset, delay + sk[3].time * sd))
    check("spring land = landing keyframe", near(spring[2].offset, delay + sk[5].time * sd))
    check("spring timings", near(spring[0].offset, 0.492) && near(spring[1].offset, 1.116) && near(spring[2].offset, 1.692))
    // Cross-check against the pose the view draws at those moments (stage layout).
    let launchPose = TurnipRig.finishedPose(at: spring[0].offset - delay, layout: .stage)
    let topPose = TurnipRig.finishedPose(at: spring[1].offset - delay, layout: .stage)
    let landPose = TurnipRig.finishedPose(at: spring[2].offset - delay, layout: .stage)
    let minDy = sk.map(\.pose.dy).min()!
    check("launch tap: crouched (squashed, below rest)", launchPose.dy > 0 && launchPose.sy < 1)
    check("top tap: at the highest point", near(topPose.dy, minDy, 1e-6))
    check("land tap: back on the rim, squashed", near(landPose.dy, 0, 1e-6) && landPose.sy < 1)
    check("spring burst inside the first jump", spring.last!.offset < delay + sd)
    check("spring burst before the first repeat", spring.last!.offset < delay + TurnipRig.springPeriod)

    let hop = HapticBursts.finished(.turnipHop)
    let hk = TurnipRig.hopKeyframes, hd = TurnipRig.hopDuration
    check("turnip hop: no delay, keyframes", near(hop[0].offset, hk[1].time * hd) && near(hop[1].offset, hk[2].time * hd)
          && near(hop[2].offset, hk[5].time * hd))
    check("turnip hop top pose at the top", near(TurnipRig.finishedPose(at: hop[1].offset, layout: .compact).dy,
                                                  hk.map(\.pose.dy).min()!, 1e-6))

    let moments = HapticBursts.turnipMoments(sk)
    check("turnip moments", near(moments.launch, 0.08) && near(moments.top, 0.34) && near(moments.land, 0.58))

    for style in FinishedHapticStyle.allCases {
        let s = HapticBursts.finished(style)
        expectEqual(patterns(s), [.generic, .alignment, .levelChange], "\(style) patterns")
        check("\(style) taps ordered, >= 60 ms apart", zip(s, s.dropFirst()).allSatisfy { $1.offset - $0.offset >= 0.06 })
    }
    expectEqual(FinishedHapticStyle.turnip(dropDown: true), .turnipSpring, "style drop-down")
    expectEqual(FinishedHapticStyle.turnip(dropDown: false), .turnipHop, "style strip")

    // Needs you: two firm taps 120 ms apart; open: one soft tap.
    expectEqual(HapticBursts.steps(for: .needsYou), [HapticStep(0, .levelChange), HapticStep(0.12, .levelChange)], "needs-you taps")
    expectEqual(HapticBursts.steps(for: .open), [HapticStep(0, .levelChange)], "open tap")
    check("needs-you differs from the finished burst", HapticBursts.steps(for: .needsYou) != spring)

    // MARK: Hover throttle

    var s = HapticScheduler()
    expectEqual(s.hover(target: "row:a", at: 10), .alignment, "first hover ticks")
    expectEqual(s.hover(target: "row:b", at: 10.03), nil, "within 60 ms: no tick")
    expectEqual(s.hover(target: "row:a", at: 10.5), nil, "same target twice in a row: no tick")
    expectEqual(s.hover(target: "row:b", at: 11.5), .alignment, "after a pause: ticks")
    expectEqual(s.hover(target: "row:a", at: 12), .alignment, "back to the previous target: ticks")
    s.resetHover()
    expectEqual(s.hover(target: "row:a", at: 13), .alignment, "after leaving the island the same target ticks again")

    // A slow, deliberate move (250 ms per target) ticks every time.
    var slow = HapticScheduler()
    var slowTicks = 0
    for i in 0..<8 where slow.hover(target: "row:\(i)", at: 100 + Double(i) * 0.25) != nil { slowTicks += 1 }
    expectEqual(slowTicks, 8, "slow move: one tick per row")

    // Sweeping fast across the list (a row every 30 ms) doesn't buzz.
    var fast = HapticScheduler()
    var fastTimes: [Double] = []
    for i in 0..<20 {
        let t = 200 + Double(i) * 0.03
        if fast.hover(target: "row:\(i)", at: t) != nil { fastTimes.append(t) }
    }
    check("fast sweep: few ticks (\(fastTimes.count))", fastTimes.count <= 5 && fastTimes.count >= 2)
    check("fast sweep: ticks >= sweep interval apart",
          zip(fastTimes, fastTimes.dropFirst()).allSatisfy { $1 - $0 >= fast.sweepHoverInterval - 1e-9 })
    // A medium sweep (a row every 70 ms) is also capped by the sweep interval, never above ~7/s.
    var medium = HapticScheduler()
    var mediumTimes: [Double] = []
    for i in 0..<15 {
        let t = 300 + Double(i) * 0.07
        if medium.hover(target: "row:\(i)", at: t) != nil { mediumTimes.append(t) }
    }
    check("medium sweep: spaced >= 150 ms", zip(mediumTimes, mediumTimes.dropFirst()).allSatisfy { $1 - $0 >= 0.15 - 1e-9 })
    check("medium sweep: still ticks", mediumTimes.count >= 4)

    // MARK: Cues, quiet window, setting gate

    var c = HapticScheduler()
    let steps = c.cue(.finished(.turnipSpring), at: 50)
    expectEqual(steps, spring, "cue returns the burst")
    expectEqual(c.hover(target: "btn", at: 50.5), nil, "no hover ticks while the burst plays")
    expectEqual(c.hover(target: "btn2", at: 50 + spring.last!.offset + 0.1), nil, "quiet right after the burst")
    expectEqual(c.hover(target: "btn3", at: 50 + spring.last!.offset + 0.3), .alignment, "hover resumes after the burst")
    var c2 = HapticScheduler()
    _ = c2.cue(.finished(.turnipSpring), at: 50)
    c2.cancelCue(at: 50.4)
    expectEqual(c2.hover(target: "btn", at: 50.5), .alignment, "cancelled burst: hover resumes")

    var off = HapticScheduler(enabled: false)
    expectEqual(off.hover(target: "row:a", at: 1), nil, "disabled: no hover tick")
    expectEqual(off.cue(.needsYou, at: 1), [], "disabled: no needs-you taps")
    expectEqual(off.cue(.finished(.turnipHop), at: 1), [], "disabled: no burst")
    off.enabled = true
    expectEqual(off.hover(target: "row:a", at: 2), .alignment, "re-enabled: ticks")

    // MARK: Director (which state change plays what)

    var d = HapticDirector()
    let e1 = UUID(), e2 = UUID(), e3 = UUID(), r1 = UUID(), r2 = UUID()
    expectEqual(d.update(surface: .hidden, finishedEvents: []).cue, nil, "launch: nothing")
    expectEqual(d.update(surface: .pill, finishedEvents: []).cue, nil, "island appears: nothing")
    let open = d.update(surface: .panel, finishedEvents: [])
    expectEqual(open.cue, .open, "pill -> panel: open tap")
    check("open resets hover", open.resetHover)
    expectEqual(d.update(surface: .reader, finishedEvents: []).cue, nil, "panel -> reader: no tap")
    expectEqual(d.update(surface: .pill, finishedEvents: []).cue, nil, "close: no tap")
    let fin = d.update(surface: .finished(sessionId: "s1"), finishedEvents: [e1])
    expectEqual(fin.cue, .finished(.turnipSpring), "turn ends: drop-down spring burst")
    expectEqual(d.update(surface: .finished(sessionId: "s1"), finishedEvents: [e1]).cue, nil,
                "same drop-down: no repeat (4 s re-springs are silent)")
    let gone = d.update(surface: .pill, finishedEvents: [])
    expectEqual(gone.cue, nil, "drop-down closes: nothing")
    check("drop-down closes: pending taps cancelled", gone.cancelPending)
    expectEqual(d.update(surface: .finished(sessionId: "s1"), finishedEvents: []).cue, nil,
                "sticky re-show without a new event: nothing")
    _ = d.update(surface: .reader, finishedEvents: [])
    expectEqual(d.update(surface: .reader, finishedEvents: [e2]).cue, .finished(.turnipHop),
                "finish while the reader is open: strip hop burst")
    expectEqual(d.update(surface: .pill, finishedEvents: [e2, e3]).cue, .finished(.turnipHop),
                "pill strip hop")
    expectEqual(d.update(surface: .finished(sessionId: "s2"), finishedEvents: [e2, e3, UUID()]).cue,
                .finished(.turnipSpring), "drop-down spring")
    expectEqual(d.update(surface: .needsYou(requestId: r1), finishedEvents: []).cue, .needsYou,
                "permission drop-down: needs-you taps")
    expectEqual(d.update(surface: .needsYou(requestId: r1), finishedEvents: []).cue, nil, "same request: once")
    _ = d.update(surface: .confirmation, finishedEvents: [])
    expectEqual(d.update(surface: .needsYou(requestId: r1), finishedEvents: []).cue, nil,
                "request re-shown after a confirmation: not again")
    expectEqual(d.update(surface: .needsYou(requestId: r2), finishedEvents: []).cue, .needsYou,
                "next queued request: taps")
    expectEqual(d.update(surface: .pill, finishedEvents: []).cue, nil, "back to pill")
    expectEqual(d.update(surface: .awaySummary, finishedEvents: []).cue, .open, "away summary drops down: open tap")

    var first = HapticDirector()
    expectEqual(first.update(surface: .needsYou(requestId: r1), finishedEvents: [e1]).cue, nil,
                "first update only records (no taps at launch)")
    expectEqual(first.update(surface: .needsYou(requestId: r1), finishedEvents: [e1]).cue, nil,
                "request already showing at launch stays silent")
}
