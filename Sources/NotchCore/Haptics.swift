import Foundation

// Pure haptic timing for the app's trackpad feedback (the app performs the patterns with
// NSHapticFeedbackManager, see Sources/Turnipot/Haptics.swift). Everything here is clock-free:
// callers pass monotonic seconds, so it is self-tested in HapticsTests.swift.

/// The three NSHapticFeedbackManager patterns (same names).
public enum HapticPattern: String, Sendable, CaseIterable {
    case generic, alignment, levelChange
}

/// One tap of a sequence, `offset` seconds after the sequence starts.
public struct HapticStep: Equatable, Sendable, CustomStringConvertible {
    public let offset: Double
    public let pattern: HapticPattern
    public init(_ offset: Double, _ pattern: HapticPattern) { self.offset = offset; self.pattern = pattern }
    public var description: String { String(format: "%.3fs %@", offset, pattern.rawValue) }
}

/// Which finished animation a turn-end burst follows.
public enum FinishedHapticStyle: String, Sendable, CaseIterable {
    /// Turnip in the finished drop-down: the full spring out of the pot (`springKeyframes`, after `springDelay`).
    case turnipSpring
    /// Turnip in a 32pt strip (pill / panel / reader): the small pop (`hopKeyframes`, no delay).
    case turnipHop

    /// The drop-down's stage or a strip / pill mascot.
    public static func turnip(dropDown: Bool) -> FinishedHapticStyle {
        dropDown ? .turnipSpring : .turnipHop
    }
}

/// Event-driven haptic sequences.
public enum HapticCue: Equatable, Sendable {
    /// The panel / a drop-down springs open: one soft tap.
    case open
    /// A permission / question / plan drop-down appears: two firm taps.
    case needsYou
    /// A turn ended: launch / top / landing taps synced to the mascot's first jump.
    case finished(FinishedHapticStyle)
}

public enum HapticBursts {
    /// Gap between the two "needs you" taps.
    public static let needsYouGap: Double = 0.12

    public static func steps(for cue: HapticCue) -> [HapticStep] {
        switch cue {
        case .open: return [HapticStep(0, .levelChange)]
        case .needsYou: return [HapticStep(0, .levelChange), HapticStep(needsYouGap, .levelChange)]
        case .finished(let style): return finished(style)
        }
    }

    /// Launch (.generic) as the mascot leaves its crouch, a quick .alignment at the top, a firmer
    /// .levelChange as it lands. Derived from the same keyframes the views animate, so retiming the
    /// animation retimes the taps.
    public static func finished(_ style: FinishedHapticStyle) -> [HapticStep] {
        let t: (launch: Double, top: Double, land: Double)
        switch style {
        case .turnipSpring:
            let k = turnipMoments(TurnipRig.springKeyframes)
            let d = TurnipRig.springDuration, delay = TurnipRig.springDelay
            t = (delay + k.launch * d, delay + k.top * d, delay + k.land * d)
        case .turnipHop:
            let k = turnipMoments(TurnipRig.hopKeyframes)
            let d = TurnipRig.hopDuration
            t = (k.launch * d, k.top * d, k.land * d)
        }
        return [HapticStep(t.launch, .generic), HapticStep(t.top, .alignment), HapticStep(t.land, .levelChange)]
    }

    /// Normalized keyframe times of a Turnip jump: launch = the crouch (first keyframe squashed
    /// below the rest line, dy > 0) it springs up from; top = the first keyframe at the highest
    /// point (smallest dy); land = the first keyframe after the top that is back on the rim (dy >= 0).
    public static func turnipMoments(_ keys: [TurnipRig.Keyframe]) -> (launch: Double, top: Double, land: Double) {
        let launch = keys.first { $0.pose.dy > 0 }?.time ?? 0
        let minDy = keys.map(\.pose.dy).min() ?? 0
        let top = keys.first { $0.pose.dy == minDy }?.time ?? launch
        let land = keys.first { $0.time > top && $0.pose.dy >= 0 }?.time ?? top
        return (launch, top, land)
    }
}

/// Throttling / gating state for the app's haptics. Hover ticks: at most one every
/// `minHoverInterval`, `sweepHoverInterval` while the pointer crosses targets in quick
/// succession (sweeping a list), never the same target twice in a row, and none while an event
/// sequence plays (`quietUntil`). Everything returns nothing while disabled.
public struct HapticScheduler: Sendable {
    public var enabled: Bool
    /// Minimum time between two hover ticks.
    public var minHoverInterval: Double = 0.06
    /// A hover request this soon after the previous one (ticked or not) means the pointer is
    /// sweeping across targets...
    public var sweepWindow: Double = 0.12
    /// ...and then ticks are spaced at least this far apart.
    public var sweepHoverInterval: Double = 0.15
    /// Hover ticks stay quiet this long after an event sequence's last tap.
    public var quietAfterCue: Double = 0.2

    public private(set) var lastTickAt: Double = -.infinity
    public private(set) var lastTarget: String?
    public private(set) var lastRequestAt: Double = -.infinity
    public private(set) var quietUntil: Double = -.infinity

    public init(enabled: Bool = true) { self.enabled = enabled }

    /// The pointer moved onto `target` at `now`: the pattern to perform, or nil (throttled).
    public mutating func hover(target: String, at now: Double) -> HapticPattern? {
        let previousRequest = lastRequestAt
        lastRequestAt = now
        guard enabled, now >= quietUntil, target != lastTarget else { return nil }
        let sweeping = now - previousRequest < sweepWindow
        let interval = sweeping ? sweepHoverInterval : minHoverInterval
        guard now - lastTickAt >= interval else { return nil }
        lastTickAt = now
        lastTarget = target
        return .alignment
    }

    /// The pointer left the island (or new content opened): the next target may tick again even
    /// if it is the last one.
    public mutating func resetHover() {
        lastTarget = nil
    }

    /// Steps to perform for `cue` starting at `now` (empty while disabled). Hover ticks pause
    /// until the sequence is over.
    public mutating func cue(_ cue: HapticCue, at now: Double) -> [HapticStep] {
        guard enabled else { return [] }
        let steps = HapticBursts.steps(for: cue)
        let end = now + (steps.last?.offset ?? 0)
        quietUntil = max(quietUntil, end + quietAfterCue)
        lastTickAt = max(lastTickAt, now)
        lastTarget = nil
        return steps
    }

    /// The remaining taps of a sequence were cancelled (its drop-down closed): hover ticks may resume.
    public mutating func cancelCue(at now: Double) {
        quietUntil = min(quietUntil, now)
    }
}

/// What the island shows, as far as haptics care (mirrors the app's `Presentation`).
public enum HapticSurface: Hashable, Sendable {
    /// Tucked into the notch (launch / quit / screen change).
    case hidden
    case pill
    case panel
    case reader
    case finished(sessionId: String)
    case needsYou(requestId: UUID)
    case awaySummary
    case nearLimit
    case confirmation

    /// Surfaces whose notch row carries the shared (pill) mascot, which hops in its strip.
    public var showsStripMascot: Bool {
        switch self {
        case .pill, .panel, .reader: return true
        default: return false
        }
    }

    /// The panel or a drop-down that springs open out of the pill (finished / needs-you have
    /// their own sequences).
    public var opensWithTap: Bool {
        switch self {
        case .panel, .reader, .awaySummary, .nearLimit: return true
        default: return false
        }
    }

    /// Pending taps belong to this group: they are cancelled when the island leaves it.
    var group: String {
        switch self {
        case .pill, .panel, .reader: return "strip"
        case .finished(let s): return "finished-\(s)"
        case .needsYou(let id): return "needsYou-\(id)"
        default: return "\(self)"
        }
    }
}

/// Decides which event sequence (if any) a state change plays. Pure: the app feeds it the
/// current surface and the ids of the live "session finished" events.
/// - needs you: the first time a request's drop-down shows (not when it re-appears);
/// - turn ended: a NEW finished event whose drop-down is now showing -> the drop-down's jump
///   (Turnip: the stage spring), or, if it can't drop down (reader open), the strip mascot's hop;
///   one burst per event, i.e. only for the first jump (not the 4 s repeats);
/// - open: pill -> panel / reader / away summary / near-limit banner (nothing on close);
/// - the first update only records the state (nothing plays at launch).
public struct HapticDirector: Sendable {
    public struct Decision: Equatable, Sendable {
        public var cue: HapticCue?
        /// Cancel the taps still pending from an earlier sequence (its drop-down went away).
        public var cancelPending = false
        /// New content under the pointer: the next hover may tick even on the last target.
        public var resetHover = false
    }

    public private(set) var surface: HapticSurface?
    private var seenFinished: Set<UUID> = []
    private var announcedRequests: Set<UUID> = []
    private var pendingGroup: String?

    public init() {}

    public mutating func update(surface new: HapticSurface, finishedEvents: Set<UUID>) -> Decision {
        var d = Decision()
        defer {
            surface = new
            seenFinished = finishedEvents
        }
        guard let old = surface else {
            if case .needsYou(let id) = new { announcedRequests.insert(id) }
            return d
        }
        let changed = old != new
        let newFinished = !finishedEvents.subtracting(seenFinished).isEmpty
        if changed {
            d.resetHover = true
            if let g = pendingGroup, g != new.group {
                d.cancelPending = true
                pendingGroup = nil
            }
        }
        switch new {
        case .needsYou(let id) where !announcedRequests.contains(id):
            announcedRequests.insert(id)
            d.cue = .needsYou
        case .finished where newFinished && changed:
            d.cue = .finished(.turnip(dropDown: true))
        default:
            if newFinished && new.showsStripMascot {
                d.cue = .finished(.turnip(dropDown: false))
            } else if changed && old == .pill && new.opensWithTap {
                d.cue = .open
            }
        }
        if let cue = d.cue, cue != .open { pendingGroup = new.group }
        return d
    }
}
