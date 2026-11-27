import Foundation

// Pure pieces of the expanded panel's session rows (self-tested in RowTests.swift).

/// Compact "time since": "now" (under a minute), "3m", "22m", "1h 6m", "5h", "2d".
public enum RelativeTime {
    public static func compact(seconds: TimeInterval) -> String {
        let secs = max(0, Int(seconds))
        if secs < 60 { return "now" }
        let m = secs / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d" }
        if h > 0 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
        return "\(m)m"
    }

    public static func compact(since date: Date, now: Date) -> String {
        compact(seconds: now.timeIntervalSince(date))
    }
}

/// Hover-to-reveal for session rows: after the pointer rests on one row for `delay` seconds,
/// that row shows its truncated text in full; leaving it (or moving to another row) hides it
/// again. A fast sweep never reveals anything: every enter restarts the clock and only the
/// row still hovered when the delay has passed is revealed. Scrolling the list hides any reveal
/// and parks it: rows sliding under a still pointer never reveal; the clock only starts once
/// the pointer itself moves again. Clock-free (callers pass times).
public struct RowReveal: Equatable, Sendable {
    public static let defaultDelay: TimeInterval = 1.5

    public var delay: TimeInterval
    /// Row under the pointer and since when.
    public private(set) var hovered: String?
    public private(set) var hoveredSince: TimeInterval = 0
    /// Row currently shown in full.
    public private(set) var revealed: String?
    /// The list scrolled since the pointer last moved: nothing reveals until it moves.
    public private(set) var parked = false

    public init(delay: TimeInterval = RowReveal.defaultDelay) { self.delay = delay }

    /// Pointer entered `id` at `now`. Returns when to call `tick` (now + delay).
    @discardableResult
    public mutating func enter(_ id: String, at now: TimeInterval) -> TimeInterval {
        if hovered != id {
            hovered = id
            hoveredSince = now
            if revealed != id { revealed = nil }
        }
        return hoveredSince + delay
    }

    /// Pointer left `id` (ignored if another row was entered since).
    public mutating func leave(_ id: String) {
        if hovered == id { hovered = nil }
        if revealed == id { revealed = nil }
    }

    /// The list scrolled: hide the reveal and wait for the pointer to move.
    public mutating func scrolled() {
        parked = true
        revealed = nil
    }

    /// The pointer moved at `now`. After a scroll this restarts the clock on the hovered row and
    /// returns when to call `tick`; otherwise nil (hover enters already scheduled it).
    @discardableResult
    public mutating func pointerMoved(at now: TimeInterval) -> TimeInterval? {
        guard parked else { return nil }
        parked = false
        hoveredSince = now
        return hovered == nil ? nil : now + delay
    }

    /// Re-evaluate at `now`; returns the row to reveal (nil = none).
    @discardableResult
    public mutating func tick(at now: TimeInterval) -> String? {
        if !parked, let h = hovered, now - hoveredSince >= delay - 1e-9 { revealed = h }
        return revealed
    }

    /// Lines a revealed text takes: laid-out height / line height, 1…maxLines.
    public static func lines(textHeight: Double, lineHeight: Double, maxLines: Int = 3) -> Int {
        ReplyFieldGrowth.lines(contentHeight: textHeight, lineHeight: lineHeight, maxLines: maxLines)
    }

    /// Panel closed / list changed: forget everything.
    public mutating func reset() {
        hovered = nil
        revealed = nil
        parked = false
    }
}
