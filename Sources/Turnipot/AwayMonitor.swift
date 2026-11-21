import AppKit
import CoreGraphics
import NotchCore

/// Detects when the user is away from the Mac and when they come back, and tells AppState
/// (`setAway(since:)` / `setReturned()`), which holds finished drop-downs meanwhile and shows one
/// "While you were away" summary on return.
///
/// Away = any of: screen locked (`com.apple.screenIsLocked`), system asleep (willSleep), displays
/// asleep (screensDidSleep), or no input for `idleThreshold` (CGEventSource idle time, polled; no
/// Accessibility permission needed — it only reads the seconds since the last HID event).
/// Back = all reasons cleared: unlock, wake, first input after idle.
@MainActor
final class AwayMonitor {
    enum Reason: Hashable { case locked, sleeping, screensAsleep, idle }

    static let idleThreshold: TimeInterval = 180
    /// Poll interval while present (detects going idle) and while idle (detects the first input).
    static let presentPoll: TimeInterval = 10
    static let idlePoll: TimeInterval = 1

    private let appState: AppState
    private(set) var reasons: Set<Reason> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    init(appState: AppState) { self.appState = appState }

    /// Seconds since the last keyboard / mouse / trackpad event in this login session.
    static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType (~0): any input event type.
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        add(dnc, "com.apple.screenIsLocked") { $0.insert(.locked) }
        add(dnc, "com.apple.screenIsUnlocked") { $0.remove(.locked) }
        let wnc = NSWorkspace.shared.notificationCenter
        add(wnc, NSWorkspace.willSleepNotification.rawValue) { $0.insert(.sleeping) }
        add(wnc, NSWorkspace.didWakeNotification.rawValue) { $0.remove(.sleeping) }
        add(wnc, NSWorkspace.screensDidSleepNotification.rawValue) { $0.insert(.screensAsleep) }
        add(wnc, NSWorkspace.screensDidWakeNotification.rawValue) { $0.remove(.screensAsleep) }
        schedule(Self.presentPoll)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (nc, o) in observers { nc.removeObserver(o) }
        observers.removeAll()
    }

    private func add(_ nc: NotificationCenter, _ name: String, _ change: @escaping @MainActor (inout Set<Reason>) -> Void) {
        let o = nc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var r = self.reasons
                change(&r)
                self.update(r, since: Date())
            }
        }
        observers.append((nc, o))
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let idle = Self.secondsSinceLastInput()
        var r = reasons
        if idle >= Self.idleThreshold { r.insert(.idle) } else { r.remove(.idle) }
        // Idle counts from the last input, not from when the poll noticed it.
        update(r, since: Date().addingTimeInterval(-idle))
    }

    private func update(_ new: Set<Reason>, since: Date) {
        let wasAway = !reasons.isEmpty
        let wasIdle = reasons.contains(.idle)
        reasons = new
        if !wasAway && !new.isEmpty {
            appState.setAway(since: since)
        } else if wasAway && new.isEmpty {
            appState.setReturned()
        }
        if wasIdle != new.contains(.idle) {
            schedule(new.contains(.idle) ? Self.idlePoll : Self.presentPoll)
        }
    }
}
