import Foundation

/// A usage window that just reset (announced by the "usage reset" drop-down).
public struct UsageReset: Equatable, Sendable {
    public var window: UsageWindow          // the window after the reset (new percent / reset time)
    public var previousPercent: Int
    public var at: Date
    public init(window: UsageWindow, previousPercent: Int, at: Date) {
        self.window = window; self.previousPercent = previousPercent; self.at = at
    }
}

public enum UsageResetRule {
    /// Only announce resets of windows that had been used this much (a 5h window that reset at 3%
    /// is not news).
    public static let minPreviousPercent = 50
    /// How long the drop-down stays (unless hovered / dismissed).
    public static let lifetime: TimeInterval = 7
    /// After the pointer leaves it.
    public static let afterHoverLifetime: TimeInterval = 3

    /// Windows of `new` that reset since `old`: same label, the reset time moved on and the
    /// percent dropped (or, if the reset text didn't change / can't be compared, the percent fell
    /// by at least 40 points to <= 10%). `old` must be a fresh (non-stale) snapshot; nil on the
    /// first fetch -> nothing. Highest previous percent first.
    public static func resets(old: UsageSnapshot?, new: UsageSnapshot, now: Date = Date()) -> [UsageReset] {
        guard let old, old.fetchedAt != nil, !new.windows.isEmpty else { return [] }
        var out: [UsageReset] = []
        for w in new.windows {
            guard let prev = old.windows.first(where: { $0.label == w.label }) else { continue }
            guard prev.percent >= minPreviousPercent, w.percent < prev.percent else { continue }
            let movedOn = !prev.resetsText.isEmpty && w.resetsText != prev.resetsText
            let bigDrop = prev.percent - w.percent >= 40 && w.percent <= 10
            if movedOn || bigDrop { out.append(UsageReset(window: w, previousPercent: prev.percent, at: now)) }
        }
        return out.sorted { $0.previousPercent > $1.previousPercent }
    }
}

/// Pure motion data for the "turnip gets watered" animation (usage reset drop-down). Times in
/// seconds from the start of the watering; positions in sprite pixels like TurnipRig.
public enum WaterRig {
    public static let duration: Double = 1.5

    /// Watering can, spout on the left ("S" rose, "s" spout, "c" body, "h" handle, "d" base,
    /// "l" rim highlight).
    public static let can = ["......hhh.",
                             "S....h...h",
                             ".s.lllllch",
                             "..scccccc.",
                             "...dddddd."]
    public static let canHex: [Character: UInt32] = ["S": 0xdde5ee, "s": 0x9aa8b8, "c": 0x9aa8b8, "l": 0xc9d3de,
                                                     "h": 0x6e7b8b, "d": 0x6e7b8b]
    public static let canPivot = (x: 5.5, y: 3.0)
    public static let tilt: Double = -36
    /// Rose centre (can-local).
    public static let spout = (x: 0.5, y: 1.5)

    /// Turnip ducks into the pot while showered.
    public static let duck: Double = 1.5

    /// Body keyframes: duck + squash while showered, spring up stretched (perk), rebound, settle.
    public static func bodyKeys(_ layout: TurnipRig.Layout) -> [(Double, TurnipRig.Pose)] {
        typealias P = TurnipRig.Pose
        let jump = layout == .stage ? -4.0 : -1.2
        return [(0, .identity), (0.3, .identity),
                (0.48, P(dy: duck, sx: 1.04, sy: 0.95)),
                (0.98, P(dy: duck, sx: 1.06, sy: 0.93)),
                (1.12, P(dy: jump, sx: 0.95, sy: 1.08)),
                (1.26, P(dy: 0.3, sx: 1.05, sy: 0.94)),
                (1.38, P(dy: -0.3)),
                (1.5, .identity)]
    }
    /// Leaf vertical scale around the tuft base: flatten under the water, perk up tall.
    public static let leafKeys: [(Double, Double)] = [(0, 1), (0.42, 1), (0.56, 0.82), (0.98, 0.85),
                                                      (1.12, 1.35), (1.26, 0.92), (1.38, 1.06), (1.5, 1)]
    /// Drops leave the rose at these times; x jitter; landing variation.
    public static let drops: [Double] = [0.5, 0.58, 0.66, 0.74, 0.82, 0.9]
    public static let dropJitter: [Double] = [0, -0.5, 0.4, -0.2, 0.3, -0.4]
    public static let gravity: Double = 120
    public static let dropV0: Double = 3
    /// Eyes shut while showered, happy from the perk on.
    public static let eyesShut = (from: 0.42, to: 1.06)

    /// Can offset (slides in from the top right / out) and tilt at `t`.
    public static func canMotion(at t: Double) -> (dx: Double, dy: Double, rot: Double) {
        func seg(_ a: Double, _ b: Double) -> Double { min(max((t - a) / (b - a), 0), 1) }
        let inn = 1 - pow(1 - seg(0, 0.3), 3), out = pow(seg(1.1, 1.38), 3)
        func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
        let rot = tilt * (ease(seg(0.28, 0.46)) - ease(seg(0.98, 1.14)))
        return (8 * (1 - inn) + 9 * out, -8 * (1 - inn) - 9 * out, rot)
    }

    /// Can grid origin at rest (frame coordinates): the tipped rose ends `fall` rows above the
    /// ducked leaves, over the tuft; never above the frame.
    public static func canOrigin(top: Double, layout: TurnipRig.Layout) -> (x: Double, y: Double) {
        let fall = layout == .stage ? 5.0 : 2.4
        let tip = rotated(spout, by: tilt)
        let x = (layout == .stage ? 5.0 : 6.5) + Double(TurnipRig.leftMargin) - tip.x
        let y = max(0, top + duck - fall - tip.y)
        return (x, y)
    }

    /// Can-local point rotated around `canPivot` (y down, degrees).
    public static func rotated(_ pt: (x: Double, y: Double), by deg: Double) -> (x: Double, y: Double) {
        let a = deg * .pi / 180
        let vx = pt.x - canPivot.x, vy = pt.y - canPivot.y
        return (canPivot.x + vx * cos(a) - vy * sin(a), canPivot.y + vx * sin(a) + vy * cos(a))
    }

    /// Rose centre (frame coordinates) at `t`.
    public static func rose(at t: Double, top: Double, layout: TurnipRig.Layout) -> (x: Double, y: Double) {
        let o = canOrigin(top: top, layout: layout), m = canMotion(at: t)
        let r = rotated(spout, by: m.rot)
        return (o.x + m.dx + r.x, o.y + m.dy + r.y)
    }

    /// Drop `i` at `t` (frame coordinates): the falling drop (nil once landed / before it
    /// leaves the rose) and its splash specks with their opacity.
    public static func drop(_ i: Int, at t: Double, top: Double, layout: TurnipRig.Layout)
        -> (drop: TurnipRect?, splash: [TurnipRect], splashAlpha: Double) {
        let t0 = drops[i]
        guard t >= t0 else { return (nil, [], 0) }
        let dt = t - t0
        let (sx, sy) = rose(at: t0, top: top, layout: layout)
        let x = sx + dropJitter[i] * 0.6 - 1.0 * dt
        let y = sy + 0.4 + dropV0 * dt + 0.5 * gravity * dt * dt
        let land = top + interp(bodyKeys(layout), t0 + 0.2).dy + 0.8 + Double(i % 2) * 0.7
        if y < land { return (TurnipRect(x - 0.3, y - 0.6, 0.6, 1), [], 0) }
        let tl = min((y - land) / (dropV0 + gravity * dt) / 0.14, 1)
        guard tl < 1 else { return (nil, [], 0) }
        let yy = land - 0.5 - 0.7 * sin(tl * .pi)
        return (nil, [TurnipRect(x - 0.25 - 1.1 * tl, yy, 0.5, 0.5), TurnipRect(x - 0.25 + 1.1 * tl, yy, 0.5, 0.5)], 1 - tl * 0.6)
    }

    /// Sparkles on the perked leaves (turnip-top relative: add the body's top + dy) and their opacity.
    public static let sparkleRects = [TurnipRect(1.6, -0.6, 0.8, 0.8), TurnipRect(10.6, 1.0, 0.7, 0.7), TurnipRect(0.6, 3.2, 0.6, 0.6)]
    public static func sparkleAlpha(at t: Double) -> Double {
        min(max((t - 1.14) / 0.1, 0), 1) * (1 - min(max((t - 1.36) / 0.14, 0), 1))
    }

    /// Face while watered: eyes shut under the shower, happy from the perk on.
    public static let happyFrom = eyesShut.to - 0.12
    public static func face(_ base: TurnipRig.Face, at t: Double) -> TurnipRig.Face {
        if t >= happyFrom { return .happy }
        if t >= eyesShut.from { return .closed }
        return base
    }

    public static func interp(_ keys: [(Double, TurnipRig.Pose)], _ t: Double) -> TurnipRig.Pose {
        for (a, b) in zip(keys, keys.dropFirst()) where t >= a.0 && t <= b.0 {
            return a.1.lerp(b.1, TurnipRig.springEase((t - a.0) / (b.0 - a.0)))
        }
        return .identity
    }
    public static func interp(_ keys: [(Double, Double)], _ t: Double) -> Double {
        for (a, b) in zip(keys, keys.dropFirst()) where t >= a.0 && t <= b.0 {
            return a.1 + (b.1 - a.1) * TurnipRig.springEase((t - a.0) / (b.0 - a.0))
        }
        return keys.last!.1
    }
}
