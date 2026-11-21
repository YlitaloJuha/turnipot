import Foundation

/// A rectangle in sprite pixels (fractions allowed: faces and effects use half pixels).
public struct TurnipRect: Hashable, Sendable {
    public let x: Double, y: Double, w: Double, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

/// Pure layout / motion data for the "Turnip" mascot: a turnip with a face sitting INSIDE a
/// small orange pot. The pot front is drawn over the turnip and the turnip is clipped just
/// below the rim (`clipRow`), so the buried part is hidden; moods move the turnip up and down
/// relative to the rim, and on "finished" it springs out of the pot.
///
/// Coordinates (sprite pixels): horizontally "pot x" (0 = the pot's left column; the turnip's
/// column 0 sits on pot column `turnipX`); the frame adds `leftMargin` columns on the left.
/// Vertically, turnip art is in turnip-local rows (0 = top of the leaves) and is placed so that
/// its top is `topRow(...)` rows below the frame's top. Two frame layouts: `.compact` for the
/// 32pt strips (pot at the bottom of the strip) and `.stage` for the finished drop-down, tall
/// enough for the full spring-out jump. Drawing lives in the app (TurnipView.swift).
public enum TurnipRig {
    // MARK: Art (from the approved design, option A "Turnip in a pot")

    /// Leaves, rows 0-3 of the turnip ("g" leaf, "G" leaf stem / "y" wilted leaf, "Y" wilted stem).
    public static let leavesUp = [".g..g..g..", ".gg.g.gg..", "..ggggg...", "....G....."]
    public static let leavesDroop = ["..........", ".yy....yy.", "..yyY.Yy..", "....Y....."]
    /// Bulb, rows 4-12 ("p" purple shoulder, "w" white bulb, last rows = root tip).
    public static let bulb = ["...pppp...", "..pppppp..", ".wwwwwwww.", ".wwwwwwww.", ".wwwwwwww.",
                              "..wwwwww..", "...wwww...", "....ww....", ".....w...."]
    /// Pot front, 14 wide, rim at its row 0 ("l" rim, "o" pot, "d" dark base).
    public static let pot = ["llllllllllllll", ".oooooooooooo.", ".oooooooooooo.", "..oooooooooo..", "..dddddddddd.."]

    public static let columns = 10
    public static let leafRows = 4
    public static var turnipRows: Int { leafRows + bulb.count }   // 13
    public static let potColumns = 14
    public static var potRows: Int { pot.count }
    /// Turnip column 0 sits on this pot column (turnip is centred in the pot).
    public static let turnipX = 2
    /// Frame: 1 column left (sparkle), the pot, 1 column right ("!" while shaking).
    public static let leftMargin = 1
    public static let rightMargin = 1
    public static var frameColumns: Int { leftMargin + potColumns + rightMargin }

    /// Face (turnip-local columns / rows).
    public static let eyes = [(3, 7), (6, 7)]
    public static let blush = [(2, 8), (7, 8)]
    public static let mouth = (4, 9)

    // MARK: Layouts

    public enum Layout: String, CaseIterable, Sendable {
        /// 32pt strips (pill, drop-down strips, expanded bar): 16 rows, pot on the bottom rows.
        case compact
        /// Finished drop-down: tall frame with the pot at the bottom and room for the jump.
        case stage

        public var rows: Int { self == .compact ? 16 : 30 }
        /// Pot rim row (the pot fills `rimRow ..< rows`).
        public var rimRow: Int { rows - TurnipRig.potRows }
        /// The turnip is drawn only above this row (hidden behind the pot front below the rim).
        public var clipRow: Int { rimRow + 2 }
    }

    /// Rows of the turnip visible above the rim per mood (design `VIS`).
    public static func visibleRows(for mood: MascotMood) -> Double {
        switch mood {
        case .sleeping: return 4.5   // only the leaves and the closed eyes peek out
        case .bouncing: return 9     // peeks out
        case .shake: return 9        // same height as working (working already fills the strip); shake + "!" signal it
        case .hop: return 9
        case .sweat: return 7        // sinking
        }
    }

    public static func restTop(for mood: MascotMood, layout: Layout) -> Double {
        Double(layout.rimRow) - visibleRows(for: mood)
    }

    /// Fully retracted (launch start / quit end): the turnip's top is at the clip row -> nothing shows.
    public static func hiddenTop(layout: Layout) -> Double { Double(layout.clipRow) }

    /// Launch / quit: the pot fades + scales in during the first part of the extension, then
    /// the turnip rises out of the soil (springs may overshoot 1 a little).
    public static func potOpacity(extension e: Double) -> Double { min(max(e / 0.3, 0), 1) }
    public static func potScale(extension e: Double) -> Double { 0.6 + 0.4 * min(max(e / 0.3, 0), 1) }
    public static func riseProgress(extension e: Double) -> Double { min(max((e - 0.25) / 0.75, 0), 1.2) }

    /// Turnip top row at extension `e` (0 = buried, 1 = at the mood's rest height).
    public static func topRow(for mood: MascotMood, layout: Layout, extension e: Double) -> Double {
        let k = riseProgress(extension: e)
        return hiddenTop(layout: layout) + (restTop(for: mood, layout: layout) - hiddenTop(layout: layout)) * k
    }

    // MARK: Cells

    public static func leafRects(wilted: Bool) -> [(TurnipRect, Character)] {
        grid(wilted ? leavesDroop : leavesUp, dy: 0)
    }
    public static var bulbRects: [(TurnipRect, Character)] { grid(bulb, dy: leafRows) }
    /// Pot cells: x in pot columns, y relative to the rim (0 = rim row).
    public static var potRects: [(TurnipRect, Character)] {
        var out: [(TurnipRect, Character)] = []
        for (y, row) in pot.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." { out.append((TurnipRect(Double(x), Double(y), 1, 1), ch)) }
        }
        return out
    }
    /// Turnip grid -> rects in pot x / turnip-local y.
    static func grid(_ rows: [String], dy: Int) -> [(TurnipRect, Character)] {
        var out: [(TurnipRect, Character)] = []
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                out.append((TurnipRect(Double(x + turnipX), Double(y + dy), 1, 1), ch))
            }
        }
        return out
    }

    // MARK: Face per mood (pot x / turnip-local y)

    public enum Face: String, CaseIterable, Sendable { case open, closed, happy, tall, worried }

    public static func face(for mood: MascotMood) -> Face {
        switch mood {
        case .sleeping: return .closed
        case .bouncing: return .open
        case .shake: return .tall
        case .hop: return .happy
        case .sweat: return .worried
        }
    }

    public static func eyeRects(_ face: Face) -> [TurnipRect] {
        var out: [TurnipRect] = []
        for (ex, ey) in eyes {
            let x = Double(ex + turnipX), y = Double(ey)
            switch face {
            case .open: out.append(TurnipRect(x, y, 1, 1))
            case .closed: out.append(TurnipRect(x - 0.1, y + 0.5, 1.2, 0.35))
            case .happy:   // ^
                out += [TurnipRect(x - 0.2, y + 0.2, 0.5, 0.4), TurnipRect(x + 0.25, y - 0.15, 0.5, 0.4),
                        TurnipRect(x + 0.7, y + 0.2, 0.5, 0.4)]
            case .tall: out.append(TurnipRect(x, y - 0.3, 1, 1.4))
            case .worried: out.append(TurnipRect(x, y + 0.3, 1, 0.6))
            }
        }
        return out
    }

    /// Black mouth pixels.
    public static func mouthRects(_ face: Face) -> [TurnipRect] {
        let x = Double(mouth.0 + turnipX), y = Double(mouth.1)
        switch face {
        case .happy: return [TurnipRect(x, y, 2, 0.5)]
        case .tall: return [TurnipRect(x + 0.5, y, 1, 1)]          // "o"
        case .worried: return [TurnipRect(x, y + 0.3, 2, 0.4)]    // flat line
        case .open, .closed: return []
        }
    }
    /// Pink tongue under the happy smile.
    public static func tongueRects(_ face: Face) -> [TurnipRect] {
        face == .happy ? [TurnipRect(Double(mouth.0 + turnipX) + 0.5, Double(mouth.1) + 0.5, 1, 0.5)] : []
    }
    public static func blushRects(_ face: Face) -> [TurnipRect] {
        face == .closed ? [] : blush.map { TurnipRect(Double($0.0 + turnipX), Double($0.1), 1, 0.6) }
    }

    // MARK: Effects

    /// Amber "!" beside the turnip (moves with it).
    public static let bangRects = [TurnipRect(13, 4, 0.8, 2), TurnipRect(13, 6.6, 0.8, 0.8)]
    /// Sweat drop beside the head (drips down 3 rows while fading).
    public static let dropRects = [TurnipRect(11, 5, 0.7, 1)]
    public static let dropFall: Double = 3
    /// Sparkles around the turnip while finished. They follow the turnip's vertical jump in the
    /// stage layout but are not squashed / twisted with it (`sparklePose`); static in the strips.
    public static let sparkleRects = [TurnipRect(-1, -1, 0.8, 0.8), TurnipRect(11.5, 1, 0.8, 0.8), TurnipRect(0, 6, 0.6, 0.6)]
    /// Sleeping "z", relative to the rim (pot x, rows from the rim); drifts (+1, -3) while fading.
    public static let zRects = [TurnipRect(12, -7, 1.6, 0.4), TurnipRect(12.8, -6.6, 0.4, 0.4),
                                TurnipRect(12.4, -6.2, 0.4, 0.4), TurnipRect(12, -5.8, 1.6, 0.4)]
    public static let zDrift = (x: 1.0, y: -3.0)

    // MARK: Motion

    /// Body transform: scale + rotation around `pivot`, then translation (sprite pixels, degrees).
    public struct Pose: Equatable, Sendable {
        public var dx: Double = 0, dy: Double = 0, sx: Double = 1, sy: Double = 1, rot: Double = 0
        public init(dx: Double = 0, dy: Double = 0, sx: Double = 1, sy: Double = 1, rot: Double = 0) {
            self.dx = dx; self.dy = dy; self.sx = sx; self.sy = sy; self.rot = rot
        }
        public static let identity = Pose()

        public func lerp(_ o: Pose, _ t: Double) -> Pose {
            func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            return Pose(dx: m(dx, o.dx), dy: m(dy, o.dy), sx: m(sx, o.sx), sy: m(sy, o.sy), rot: m(rot, o.rot))
        }
    }
    public struct Keyframe: Sendable { public let time: Double; public let pose: Pose }

    /// Body pivot (scale / rotate / squash): centre of the pot at the rim, in pot x / turnip-local y.
    public static func pivot(for mood: MascotMood) -> (x: Double, y: Double) {
        (Double(potColumns) / 2, visibleRows(for: mood))
    }
    /// Leaf pivot (sway / flap): bottom centre of the leaf tuft.
    public static let leafPivot = (x: 4.5 + Double(turnipX), y: Double(leafRows))

    /// The design's "spring" keyframes (finished, stage layout): squash, jump clean out of the
    /// pot, twist left / right in the air, land with a squash, small rebound. CSS timing
    /// cubic-bezier(.3,.8,.4,1) per segment.
    public static let springKeyframes: [Keyframe] = [
        Keyframe(time: 0, pose: .identity),
        Keyframe(time: 0.08, pose: Pose(dy: 1, sx: 1.08, sy: 0.9)),
        Keyframe(time: 0.22, pose: Pose(dy: -12, sx: 0.94, sy: 1.08)),
        Keyframe(time: 0.34, pose: Pose(dy: -13, rot: -8)),
        Keyframe(time: 0.46, pose: Pose(dy: -12, rot: 6)),
        Keyframe(time: 0.58, pose: Pose(dy: 0, sx: 1.1, sy: 0.88)),
        Keyframe(time: 0.66, pose: Pose(dy: -2)),
        Keyframe(time: 0.74, pose: .identity),
        Keyframe(time: 1, pose: .identity),
    ]
    /// Length of one spring in the design (s) and how often it repeats in the drop-down (s).
    public static let springDuration: Double = 2.4
    public static let springPeriod: Double = 4.0
    /// Finished drop-down: wait for the content to fade in before the first jump.
    public static let springDelay: Double = 0.3

    /// Finished in the 32pt strips: the same rhythm, but it only pops up a row and back.
    public static let hopKeyframes: [Keyframe] = [
        Keyframe(time: 0, pose: .identity),
        Keyframe(time: 0.08, pose: Pose(dy: 0.5, sx: 1.08, sy: 0.9)),
        Keyframe(time: 0.22, pose: Pose(dy: -1, sx: 0.96, sy: 1.04)),
        Keyframe(time: 0.34, pose: Pose(dy: -1, rot: -6)),
        Keyframe(time: 0.46, pose: Pose(dy: -1, rot: 5)),
        Keyframe(time: 0.58, pose: Pose(dy: 0, sx: 1.08, sy: 0.9)),
        Keyframe(time: 0.66, pose: Pose(dy: -0.5)),
        Keyframe(time: 0.74, pose: .identity),
        Keyframe(time: 1, pose: .identity),
    ]
    public static let hopDuration: Double = 2.4

    public static func finishedKeyframes(layout: Layout) -> [Keyframe] {
        layout == .stage ? springKeyframes : hopKeyframes
    }

    // Loop amplitudes / periods (design CSS).
    public static let bob: Double = 1             // working: up 1px, 0.9s alternate
    public static let breathe: Double = 0.5       // sleeping: down half a pixel, 2.6s
    public static let shakeX: Double = 1          // needs you: ±1px, 0.24s
    public static let sink = (x: 0.4, y: 0.6)     // near limit: sinks / drifts, 3s
    public static let leafSway: Double = 7        // working / needs you: ±7°, 1.1s alternate
    public static let leafFlap: Double = 0.15     // finished: scaleX 1 ± 0.15, 0.18s alternate

    /// Extreme body poses a mood's loop reaches (for bounds checks).
    public static func loopPoses(for mood: MascotMood, layout: Layout) -> [Pose] {
        switch mood {
        case .sleeping: return [.identity, Pose(dy: breathe)]
        case .bouncing: return [.identity, Pose(dy: -bob)]
        case .shake: return [Pose(dx: -shakeX), Pose(dx: shakeX)]
        case .sweat: return [.identity, Pose(dx: sink.x, dy: sink.y)]
        case .hop:
            let k = finishedKeyframes(layout: layout)
            // Keyframes plus midpoints (poses between keyframes are blends of them).
            return k.map(\.pose) + zip(k, k.dropFirst()).map { $0.pose.lerp($1.pose, 0.5) }
        }
    }

    /// Leaf transforms (rotation degrees, scale x) the mood's leaf loop reaches.
    public static func leafPoses(for mood: MascotMood) -> [(rot: Double, sx: Double)] {
        switch mood {
        case .bouncing, .shake: return [(-leafSway, 1), (leafSway, 1)]
        case .hop: return [(0, 1 + leafFlap), (0, 1 - leafFlap)]
        case .sleeping, .sweat: return [(0, 1)]
        }
    }

    /// Apply a leaf transform then a body pose to a turnip-local point; returns frame coordinates
    /// for a turnip whose top is at `top`.
    public static func transform(_ x: Double, _ y: Double, leaf: (rot: Double, sx: Double)?, pose: Pose,
                                 mood: MascotMood, top: Double) -> (x: Double, y: Double) {
        var px = x, py = y
        if let leaf {
            let a = leaf.rot * .pi / 180
            let rx = (px - leafPivot.x) * leaf.sx, ry = py - leafPivot.y
            px = leafPivot.x + rx * cos(a) - ry * sin(a)
            py = leafPivot.y + rx * sin(a) + ry * cos(a)
        }
        let pv = pivot(for: mood)
        let a = pose.rot * .pi / 180
        let rx = (px - pv.x) * pose.sx, ry = (py - pv.y) * pose.sy
        let qx = pv.x + rx * cos(a) - ry * sin(a) + pose.dx
        let qy = pv.y + rx * sin(a) + ry * cos(a) + pose.dy
        return (qx + Double(leftMargin), qy + top)
    }

    public static func sparklePose(_ pose: Pose, layout: Layout) -> Pose {
        layout == .stage ? Pose(dy: pose.dy) : .identity
    }

    /// Effect rects shown (and moving with the turnip) for a mood (sparkles: see `sparklePose`).
    public static func effectRects(for mood: MascotMood) -> [TurnipRect] {
        switch mood {
        case .shake: return bangRects
        case .sweat: return dropRects.map { TurnipRect($0.x, $0.y + dropFall, $0.w, $0.h) } + dropRects
        default: return []
        }
    }

    /// Bounding box (frame coordinates, sprite pixels) of everything the turnip draws above the
    /// clip row for a mood incl. its loops, leaf motion, effects and the sleeping "z".
    public static func extent(for mood: MascotMood, layout: Layout) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let top = restTop(for: mood, layout: layout)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ r: TurnipRect, leaf: (rot: Double, sx: Double)?, pose: Pose) {
            for (cx, cy) in [(r.x, r.y), (r.x + r.w, r.y), (r.x, r.y + r.h), (r.x + r.w, r.y + r.h)] {
                let p = transform(cx, cy, leaf: leaf, pose: pose, mood: mood, top: top)
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, min(p.y, Double(layout.clipRow)))
            }
        }
        let leaves = leafRects(wilted: mood == .sweat).map(\.0)
        for pose in loopPoses(for: mood, layout: layout) {
            for leaf in leafPoses(for: mood) { for r in leaves { add(r, leaf: leaf, pose: pose) } }
            for (r, _) in bulbRects { add(r, leaf: nil, pose: pose) }
            for r in effectRects(for: mood) { add(r, leaf: nil, pose: pose) }
            if mood == .hop { for r in sparkleRects { add(r, leaf: nil, pose: sparklePose(pose, layout: layout)) } }
        }
        if mood == .sleeping {
            let rim = Double(layout.rimRow), m = Double(leftMargin)
            for r in zRects {
                for (dx, dy) in [(0.0, 1.0), (zDrift.x, zDrift.y)] {
                    minX = min(minX, r.x + m + dx); maxX = max(maxX, r.x + r.w + m + dx)
                    minY = min(minY, rim + r.y + dy); maxY = max(maxY, rim + r.y + r.h + dy)
                }
            }
        }
        return (minX, minY, maxX, maxY)
    }

    /// CSS cubic-bezier(.3,.8,.4,1) used by the spring keyframes (x -> eased progress).
    public static func springEase(_ x: Double) -> Double {
        let (x1, y1, x2, y2) = (0.3, 0.8, 0.4, 1.0)
        func bez(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bez(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, y1, y2)
    }

    /// Body pose of the finished animation at time `t` seconds after it started (static renders).
    /// Stage: one spring every `springPeriod`; compact: the small pop every `hopDuration`.
    public static func finishedPose(at t: Double, layout: Layout) -> Pose {
        let keys = finishedKeyframes(layout: layout)
        let period = layout == .stage ? springPeriod : hopDuration
        let length = layout == .stage ? springDuration : hopDuration
        let local = t.truncatingRemainder(dividingBy: period)
        guard local >= 0, local < length else { return .identity }
        let f = local / length
        for (a, b) in zip(keys, keys.dropFirst()) where f >= a.time && f <= b.time {
            let u = b.time > a.time ? (f - a.time) / (b.time - a.time) : 1
            return a.pose.lerp(b.pose, springEase(u))
        }
        return .identity
    }

    // MARK: Colours (design `C` map)

    public static let leafHex: UInt32 = 0x4ade80        // "g" (follows weekly usage, see leafColor)
    public static let leafStemHex: UInt32 = 0x22a35a    // "G"
    public static let wiltHex: UInt32 = 0xb5a642        // "y"
    public static let wiltStemHex: UInt32 = 0x8a7a2e    // "Y"
    public static let purpleHex: UInt32 = 0xa855f7      // "p"
    public static let whiteHex: UInt32 = 0xf4efe9       // "w"
    public static let eyeHex: UInt32 = 0x141414         // "k"
    public static let blushHex: UInt32 = 0xf9a8b4       // "b" (drawn at 85% opacity)
    public static let tongueHex: UInt32 = 0xe0607a
    public static let rimHex: UInt32 = 0xf0a07f         // "l"
    public static let potHex: UInt32 = 0xd97757         // "o"
    public static let potDarkHex: UInt32 = 0xa85a3e     // "d"
    public static let bangHex: UInt32 = 0xfbbf24
    public static let dropHex: UInt32 = 0x7dd3fc
    public static let sparkleHex: UInt32 = 0xfde68a
    public static let zHex: UInt32 = 0x8a8a8f

    /// Leaf colour at low weekly usage (= `leafHex`).
    public static let leafFreshHex: UInt32 = leafHex
    /// Where the leaves end up at a high weekly usage (subtle olive, still clearly green).
    public static let leafOliveHex: UInt32 = 0x9fbf55
    /// Usage below this keeps the fresh green; at `oliveAtPercent` it's fully olive.
    public static let freshUntilPercent = 30
    public static let oliveAtPercent = NotchConstants.nearLimitPercent

    /// Leaf colour for a weekly usage percent (nil = unknown -> fresh green): fresh green up to
    /// `freshUntilPercent`, then a linear blend towards olive, reached at the near-limit percent.
    public static func leafColor(forUsagePercent percent: Int?) -> UInt32 {
        guard let percent else { return leafFreshHex }
        let span = Double(oliveAtPercent - freshUntilPercent)
        let t = min(max(Double(percent - freshUntilPercent) / span, 0), 1)
        return mix(leafFreshHex, leafOliveHex, t)
    }

    /// Linear blend of two 0xRRGGBB colours.
    public static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ c: UInt32, _ s: UInt32) -> Double { Double((c >> s) & 0xff) }
        var out: UInt32 = 0
        for s: UInt32 in [16, 8, 0] {
            let v = ch(a, s) + (ch(b, s) - ch(a, s)) * t
            out |= UInt32(min(max(v.rounded(), 0), 255)) << s
        }
        return out
    }

    public static func hex(for ch: Character, usage: Int?) -> UInt32 {
        switch ch {
        case "g": return leafColor(forUsagePercent: usage)
        case "G": return leafStemHex
        case "y": return wiltHex
        case "Y": return wiltStemHex
        case "p": return purpleHex
        case "w": return whiteHex
        case "l": return rimHex
        case "o": return potHex
        case "d": return potDarkHex
        default: return 0xff00ff
        }
    }
}

public extension UsageSnapshot {
    /// Highest weekly window percent ("week (all models)", "week (Fable)" ...), if any.
    var weeklyPercent: Int? {
        windows.filter { $0.label.lowercased().hasPrefix("week") }.map(\.percent).max()
    }
}
