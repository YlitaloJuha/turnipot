import Foundation

/// "Claude may be showing a prompt in the terminal" per session.
///
/// When a permission request / question / plan is handed back to the terminal (decision "ask":
/// timeout, "Open session", "Answer in terminal", the hook disconnecting without an answer, or a
/// question / plan the notch can't show), Claude Code's own dialog may be up in that terminal. A
/// quick reply typed into it would end with Enter, which picks the dialog's highlighted option
/// (e.g. "Yes"). While a session is flagged, quick reply is disabled for it and the bridge refuses
/// to type into it.
///
/// The flag clears when:
/// - the transcript shows progress after the request (a main-chain assistant message or a
///   tool_result line newer than the request: the dialog was answered),
/// - the session is seen going idle -> busy -> idle after the flag was set,
/// - the user focused the session's terminal and `focusGrace` (2 min) has passed since,
/// - the session ends.
public struct TerminalDialogGuard: Equatable, Sendable {
    public static let focusGrace: TimeInterval = 120

    /// Status progress since the flag was set (idle -> busy -> idle clears it).
    enum Phase: Equatable, Sendable { case needIdle, needBusy, needIdleAgain }

    struct Entry: Equatable, Sendable {
        var requestAt: Date
        var phase: Phase
        var focusedAt: Date?
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Sessions currently flagged.
    public var sessionIds: Set<String> { Set(entries.keys) }
    public func isOpen(_ sessionId: String) -> Bool { entries[sessionId] != nil }
    public var isEmpty: Bool { entries.isEmpty }

    /// A request for `sessionId` (received at `requestAt`) ended without an answer from the notch.
    /// `status` = the session's status right now (starts the idle -> busy -> idle tracking).
    public mutating func handedBack(sessionId: String, requestAt: Date, status: SessionStatus?) {
        let newest = max(requestAt, entries[sessionId]?.requestAt ?? .distantPast)
        entries[sessionId] = Entry(requestAt: newest,
                                   phase: status == .busy ? .needIdle : .needBusy,
                                   focusedAt: nil)
    }

    /// Newest main-chain assistant message / tool_result time seen in the transcript.
    /// Returns true if the flag was cleared.
    @discardableResult
    public mutating func transcriptProgress(sessionId: String, at: Date?) -> Bool {
        guard let at, let e = entries[sessionId], at > e.requestAt else { return false }
        entries[sessionId] = nil
        return true
    }

    /// The session's current status (call on every poll). Returns true if the flag was cleared.
    @discardableResult
    public mutating func status(sessionId: String, _ status: SessionStatus) -> Bool {
        guard var e = entries[sessionId] else { return false }
        switch (e.phase, status) {
        case (.needIdle, .idle): e.phase = .needBusy
        case (.needBusy, .busy): e.phase = .needIdleAgain
        case (.needIdleAgain, .idle):
            entries[sessionId] = nil
            return true
        default: break
        }
        entries[sessionId] = e
        return false
    }

    /// The user brought the session's terminal forward (row click, "Open session", …).
    public mutating func focused(sessionId: String, at: Date) {
        guard var e = entries[sessionId] else { return }
        if e.focusedAt == nil { e.focusedAt = at }
        entries[sessionId] = e
    }

    /// Drop flags whose terminal was focused at least `focusGrace` ago. Returns true if any changed.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        let before = entries.count
        entries = entries.filter { _, e in
            guard let f = e.focusedAt else { return true }
            return now.timeIntervalSince(f) < Self.focusGrace
        }
        return entries.count != before
    }

    public mutating func sessionEnded(_ sessionId: String) { entries[sessionId] = nil }
}

/// Thread-safe copy of the flagged sessions for `TerminalBridge.send` (which runs off the main
/// actor). AppState keeps it in sync with its `TerminalDialogGuard`.
public final class TerminalSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: Set<String> = []

    public init() {}

    public func setBlocked(_ ids: Set<String>) {
        lock.lock(); blocked = ids; lock.unlock()
    }

    public func isBlocked(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blocked.contains(sessionId)
    }
}
