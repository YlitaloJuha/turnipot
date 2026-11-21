import Foundation

/// Ignores actions on content that has only just appeared. A permission / question / plan
/// drop-down that springs open (or switches to the next queued request) right where the user was
/// about to click must not turn that click into "Allow": its action buttons (and hot keys) do
/// nothing for `delay` (400 ms) after the content identified by `key` was first shown.
public struct FreshContentGate: Equatable, Sendable {
    public static let defaultDelay: TimeInterval = 0.4

    public let delay: TimeInterval
    public private(set) var key: String?
    public private(set) var shownAt: Date?

    public init(delay: TimeInterval = FreshContentGate.defaultDelay) {
        self.delay = delay
    }

    /// The content on screen is `key` (nil = none). A new key restarts the clock.
    public mutating func show(_ key: String?, at now: Date) {
        guard key != self.key else { return }
        self.key = key
        shownAt = key == nil ? nil : now
    }

    /// May an action on `key` run at `now`? False for content not (yet) registered as shown.
    public func allows(_ key: String, at now: Date) -> Bool {
        guard key == self.key, let shownAt else { return false }
        return now.timeIntervalSince(shownAt) >= delay - 0.000_5   // Date arithmetic rounding
    }

    /// Registers `key` if it isn't the current content yet (then refuses), else `allows`.
    public mutating func attempt(_ key: String, at now: Date) -> Bool {
        if key != self.key {
            show(key, at: now)
            return false
        }
        return allows(key, at: now)
    }
}
