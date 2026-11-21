import Foundation
import NotchCore

/// TurnipRig: the turnip sits inside its pot; moods move it relative to the rim; finished
/// springs it out of the pot (stage) or pops it up a row (32pt strips). The only mascot.
func registerTurnipTests() {
    typealias T = TurnipRig
    // Art matches the design grids.
    check("turnip leaves are \(T.columns) wide", (T.leavesUp + T.leavesDroop).allSatisfy { $0.count == T.columns })
    check("turnip bulb rows are \(T.columns) wide", T.bulb.allSatisfy { $0.count == T.columns })
    expectEqual(T.turnipRows, 13, "turnip is 13 rows (4 leaves + 9 bulb)")
    check("pot rows are \(T.potColumns) wide", T.pot.allSatisfy { $0.count == T.potColumns })
    expectEqual(T.frameColumns, 16, "frame = margin + pot + margin")
    expectEqual(T.leftMargin + T.turnipX + T.columns / 2, T.frameColumns / 2, "turnip centred in the frame")
    check("eyes sit on the white bulb", T.eyes.allSatisfy { Array(T.bulb[$0.1 - T.leafRows])[$0.0] == "w" })
    check("blush sits on the bulb", T.blush.allSatisfy { Array(T.bulb[$0.1 - T.leafRows])[$0.0] == "w" })

    // Layouts: compact fits the 32pt strip at 2pt pixels, pot on the bottom rows.
    expectEqual(T.Layout.compact.rows * 2, 32, "compact frame = 32pt strip at 2pt pixels")
    for layout in T.Layout.allCases {
        expectEqual(layout.rimRow + T.potRows, layout.rows, "\(layout): pot sits on the bottom rows")
    }
    expectEqual(T.visibleRows(for: .bouncing) + Double(T.potRows), 14, "working: 9 rows + 5 pot rows")
    check("needs you stays at working height (working fills the strip)", T.visibleRows(for: .shake) == T.visibleRows(for: .bouncing))
    check("near limit sinks lower than working", T.visibleRows(for: .sweat) < T.visibleRows(for: .bouncing))
    check("sleeping shows only leaves + eyes", T.visibleRows(for: .sleeping) < Double(T.eyes[0].1) + 1
          && T.visibleRows(for: .sleeping) > Double(T.leafRows))

    // Frame bounds for every mood incl. loops, leaf motion and effects.
    for mood in MascotMood.allCases {
        let e = T.extent(for: mood, layout: .compact)
        check("\(mood) compact: inside the frame horizontally (\(e.minX)...\(e.maxX))",
              e.minX >= 0 && e.maxX <= Double(T.frameColumns))
        check("\(mood) compact: keeps >= 1pt (half a row) below the strip top (\(e.minY))", e.minY >= 0.5)
        check("\(mood) compact: nothing below the frame", e.maxY <= Double(T.Layout.compact.rows))
        // Working already uses the strip's full height: no other mood may reach higher.
        let w = T.extent(for: .bouncing, layout: .compact)
        check("\(mood) compact: no taller than working (top \(e.minY) vs working \(w.minY))", e.minY >= w.minY - 1e-9)
        check("\(mood) compact: doesn't rest higher than working",
              T.restTop(for: mood, layout: .compact) >= T.restTop(for: .bouncing, layout: .compact))
        let s = T.extent(for: mood, layout: .stage)
        check("\(mood) stage: inside the frame (\(s))",
              s.minX >= 0 && s.maxX <= Double(T.frameColumns) && s.minY >= 0.5 && s.maxY <= Double(T.Layout.stage.rows))
        for layout in T.Layout.allCases {
            expectEqual(T.topRow(for: mood, layout: layout, extension: 1), T.restTop(for: mood, layout: layout),
                        "\(mood) \(layout) extension 1 = rest")
            // Retracted: the turnip's top is at the clip row, i.e. completely behind the pot.
            check("\(mood) \(layout) retracted turnip hidden behind the pot",
                  T.topRow(for: mood, layout: layout, extension: 0) >= Double(layout.clipRow))
        }
    }
    check("clip row is covered by the pot's front (rim + body rows)",
          T.Layout.compact.clipRow - T.Layout.compact.rimRow <= 3)
    // Pot covers every turnip column for the rows between the rim and the clip row.
    let cols = Set(T.bulbRects.map { Int($0.0.x) } + T.leafRects(wilted: false).map { Int($0.0.x) })
    for r in 0..<(T.Layout.compact.clipRow - T.Layout.compact.rimRow) {
        let row = Array(T.pot[r])
        check("pot row \(r) covers the turnip columns", cols.allSatisfy { row[$0] != "." })
    }
    expectEqual(T.potOpacity(extension: 0), 0, "launch start: pot invisible")
    expectEqual(T.potOpacity(extension: 1), 1, "rest: pot opaque")
    expectEqual(T.riseProgress(extension: 0.2), 0, "pot appears before the turnip rises")

    // Finished spring-out (stage): leaves the pot entirely, stays inside the stage frame.
    let stage = T.Layout.stage
    let peak = T.springKeyframes.map(\.pose.dy).min()!
    let bottomAtPeak = T.restTop(for: .hop, layout: stage) + Double(T.turnipRows) + peak
    check("spring-out: the whole turnip clears the rim at the peak (\(bottomAtPeak))", bottomAtPeak <= Double(stage.rimRow))
    for t in stride(from: 0.0, through: T.springPeriod, by: 0.05) {
        let pose = T.finishedPose(at: t, layout: stage)
        let top = T.restTop(for: .hop, layout: stage)
        func corners(_ rects: [TurnipRect], _ pose: T.Pose) -> [(x: Double, y: Double)] {
            rects.flatMap { r in
                [(r.x, r.y), (r.x + r.w, r.y + r.h), (r.x, r.y + r.h), (r.x + r.w, r.y)].map {
                    T.transform($0.0, $0.1, leaf: nil, pose: pose, mood: .hop, top: top)
                }
            }
        }
        let pts = corners(T.leafRects(wilted: false).map(\.0) + T.bulbRects.map(\.0), pose)
            + corners(T.sparkleRects, T.sparklePose(pose, layout: stage))
        let eps = 1e-6
        if !(pts.allSatisfy { $0.y >= 0 && $0.x >= -eps && $0.x <= Double(T.frameColumns) + eps }) {
            check("spring-out frame at t=\(t) inside the stage frame", false)
        }
    }
    check("spring-out rests between jumps", T.finishedPose(at: 3.5, layout: stage) == .identity)
    check("spring-out is airborne mid-jump", T.finishedPose(at: 0.8, layout: stage).dy < -10)
    check("compact hop pops at most 2 rows", T.hopKeyframes.allSatisfy { $0.pose.dy >= -2 })
    check("ease start", abs(T.springEase(0)) < 1e-6)
    check("ease end", abs(T.springEase(1) - 1) < 1e-6)

    // Leaf colour vs weekly usage.
    expectEqual(T.leafColor(forUsagePercent: nil), T.leafFreshHex, "unknown usage: fresh green")
    expectEqual(T.leafColor(forUsagePercent: 0), 0x4ade80, "0%: fresh green")
    expectEqual(T.leafColor(forUsagePercent: T.freshUntilPercent), T.leafFreshHex, "low usage stays fresh")
    expectEqual(T.leafColor(forUsagePercent: T.oliveAtPercent), T.leafOliveHex, "near limit: olive")
    expectEqual(T.leafColor(forUsagePercent: 100), T.leafOliveHex, "clamped above")
    expectEqual(T.leafColor(forUsagePercent: -5), T.leafFreshHex, "clamped below")
    let reds = stride(from: 0, through: 100, by: 5).map { (T.leafColor(forUsagePercent: $0) >> 16) & 0xff }
    check("leaf colour shifts monotonically towards olive", zip(reds, reds.dropFirst()).allSatisfy { $0 <= $1 })
    let mid = T.leafColor(forUsagePercent: 60)
    check("mid usage is between fresh and olive", mid != T.leafFreshHex && mid != T.leafOliveHex)
    check("olive stays green-dominant (subtle)", (T.leafOliveHex >> 8) & 0xff > (T.leafOliveHex >> 16) & 0xff)
    expectEqual(T.mix(0x000000, 0xffffff, 0.5), 0x808080, "mix midpoint")

    // Weekly percent used for the leaf colour.
    let u = UsageSnapshot(windows: [UsageWindow(label: "session", percent: 90, resetsText: ""),
                                    UsageWindow(label: "week (all models)", percent: 42, resetsText: ""),
                                    UsageWindow(label: "week (Fable)", percent: 21, resetsText: "")],
                          fetchedAt: nil, stale: false)
    expectEqual(u.weeklyPercent, 42, "weekly percent = max week window, ignores session")
    expectEqual(UsageSnapshot(windows: [], fetchedAt: nil, stale: false).weeklyPercent, nil, "no week window")
}
